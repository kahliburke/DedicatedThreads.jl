# Worker threads and the process-wide cache of idle ones.
#
# Workers are OS threads created at runtime and adopted by Julia. They never exit: the runtime
# never reuses a thread id, and per-thread state (`jl_all_tls_states`, `OncePerThread` values)
# grows with `maxthreadid()`, so destroying and recreating threads would leak slots. A closed
# pool hands its workers back to the cache and the next pool takes them from there.

mutable struct Worker
    @atomic tid::Int
    # Pool assignments; the worker serves one pool at a time.
    const assignments::Channel{Any}
    # Wakes the dispatcher when work arrives or its pool closes. Auto-reset, so a notify that
    # lands before the dispatcher parks is not lost.
    const wake::Threads.Event
    const started::Threads.Event
    @atomic pool::Any
end

Worker() = Worker(0, Channel{Any}(1), Threads.Event(true), Threads.Event(), nothing)

const CACHE_LOCK = ReentrantLock()
# Every worker ever created. Threads hold raw pointers to their Worker, so this keeps them rooted.
const ALL_WORKERS = Worker[]
# Workers not owned by any pool. Taken from the end, so recently used threads are reused first.
const IDLE_WORKERS = Worker[]
const WORKER_BY_TID = Dict{Int,Worker}()

function worker_entry(arg::Ptr{Cvoid})::Ptr{Cvoid}
    w = unsafe_pointer_to_objref(arg)::Worker
    try
        # The entry point was compiled in an older world than the pools it will serve.
        Base.invokelatest(worker_main, w)
    catch err
        # Nothing above this frame can handle an exception.
        Core.println("ImprovedJuliaThreadPools: worker thread failed: ", sprint(showerror, err))
    end
    return C_NULL
end

function worker_main(w::Worker)
    allow_task_switching()
    tid = Threads.threadid()
    @atomic w.tid = tid
    @lock CACHE_LOCK WORKER_BY_TID[tid] = w
    notify(w.started)
    for (pool, index) in w.assignments
        set_thread_name(string(pool.name, '-', index))
        dispatch(pool, w)
        @atomic w.pool = nothing
        set_thread_name("jlpool-idle")
        @lock CACHE_LOCK push!(IDLE_WORKERS, w)
        worker_released!(pool)
    end
end

function spawn_worker()
    w = Worker()
    @lock CACHE_LOCK push!(ALL_WORKERS, w)
    entry = @cfunction(worker_entry, Ptr{Cvoid}, (Ptr{Cvoid},))
    create_os_thread(entry, pointer_from_objref(w))
    wait(w.started)
    return w
end

"""Take `n` workers from the cache, starting new threads for any shortfall."""
function acquire_workers(n::Int)
    workers = @lock CACHE_LOCK begin
        k = min(n, length(IDLE_WORKERS))
        [pop!(IDLE_WORKERS) for _ in 1:k]
    end
    while length(workers) < n
        push!(workers, spawn_worker())
    end
    return workers
end

"""
    owning_pool(tid::Integer = Threads.threadid())

The pool currently owning thread `tid`, or `nothing` if the thread is not a pool worker or is
idle in the cache.
"""
function owning_pool(tid::Integer = Threads.threadid())
    w = @lock CACHE_LOCK get(WORKER_BY_TID, Int(tid), nothing)
    return w === nothing ? nothing : @atomic(w.pool)
end

"""
    cached_threads()

Number of worker threads idle in the process-wide cache, available to new pools.
"""
cached_threads() = @lock CACHE_LOCK length(IDLE_WORKERS)
