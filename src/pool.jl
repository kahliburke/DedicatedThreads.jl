@enum PoolState::UInt8 OPEN CLOSING CLOSED

"""
    ThreadPool(n::Integer; name::Symbol)
    ThreadPool(f, n::Integer; name::Symbol)

A pool of `n` dedicated OS threads, created at runtime and separate from Julia's `:default` and
`:interactive` pools. Run work on it with [`spawn`](@ref); tasks it runs, and their children,
spawn into the same pool. Call `close(pool)` when done; the do-block form closes automatically.

Threads are taken from a process-wide cache of threads released by closed pools before new ones
are started.

A task starts on whichever pool thread is free and then stays on that thread for its lifetime;
blocking operations (locks, IO, `sleep`, `wait`) free the thread for other pool tasks.
"""
mutable struct ThreadPool
    const name::Symbol
    const workers::Vector{Worker}
    # Guards `queue`, `idle`, and writes to `state`. Critical sections are a few instructions and
    # never block, so a spin lock beats parking on contention.
    const lock::Threads.SpinLock
    # Spawned tasks no worker has started yet.
    const queue::Vector{Task}
    # `length(queue)`, written under `lock` and readable without it.
    @atomic queued::Int
    # Dispatchers parked waiting for work, most recently parked last.
    const idle::Vector{Worker}
    # Spawned tasks that have not finished. Incremented under `lock` (with the state check);
    # decremented without it.
    @atomic outstanding::Int
    @atomic state::PoolState
    # Set once the pool is closing and `outstanding` reaches zero.
    const drained::Threads.Event
    # One item per worker handed back to the thread cache.
    const released::Channel{Nothing}
    const closed::Threads.Event
    # Scope binding `current_pool()` to this pool, for tasks spawned from an empty scope.
    root_scope::Scope

    function ThreadPool(n::Integer; name::Symbol = default_pool_name())
        n >= 1 || throw(ArgumentError("a thread pool needs at least one thread, got $n"))
        pool = new(name, Worker[], Threads.SpinLock(), Task[], 0, Worker[], 0, OPEN,
                   Threads.Event(), Channel{Nothing}(n), Threads.Event())
        pool.root_scope = Scope(nothing, CURRENT_POOL => pool)
        append!(pool.workers, acquire_workers(Int(n)))
        for (index, w) in enumerate(pool.workers)
            @atomic w.pool = pool
            put!(w.assignments, (pool, index))
        end
        return pool
    end
end

function ThreadPool(f, n::Integer; kwargs...)
    pool = ThreadPool(n; kwargs...)
    try
        return f(pool)
    finally
        close(pool)
    end
end

const POOL_COUNTER = Threads.Atomic{Int}(0)
default_pool_name() = Symbol("pool", Threads.atomic_add!(POOL_COUNTER, 1) + 1)

const CURRENT_POOL = ScopedValue{Union{Nothing,ThreadPool}}(nothing)

"""
    current_pool()

The pool that [`spawn`](@ref) without an explicit pool submits to: set by [`with_pool`](@ref)
and inherited by every task a pool runs. `nothing` outside any pool.
"""
current_pool() = CURRENT_POOL[]

"""
    with_pool(f, pool::ThreadPool)
    with_pool(f, nothing)

Call `f()` with `pool` as the [`current_pool`](@ref), so `spawn` calls made by `f` and by tasks
it creates go to `pool`. With `nothing`, `f()` runs outside any pool and its `spawn` calls go to
Julia's `:default` pool, even when called from a pool task; for code that hosts other code on a
pool without making that pool the guest's default.
"""
with_pool(f, pool::Union{Nothing,ThreadPool}) = @with CURRENT_POOL => pool f()

# Wraps a spawned function to account for its completion, and marks the task as belonging to
# `pool` (read back through `current_task().code`).
struct PoolJob{F}
    f::F
    pool::ThreadPool
end

function (job::PoolJob)()
    try
        return job.f()
    finally
        task_done!(job.pool)
    end
end

"""
    spawn(f, pool::ThreadPool) -> Task
    spawn(f) -> Task

Run `f()` on a thread of `pool` and return its `Task`; `fetch` it for the result. Without a pool,
submit to [`current_pool`](@ref), or to Julia's `:default` pool if there is none, so code written
against `spawn` runs in whichever pool its caller chose.
"""
function spawn(f, pool::ThreadPool)
    task = Task(PoolJob(f, pool))
    if CURRENT_POOL[] !== pool
        parent = current_scope()
        set_scope!(task, parent === nothing ? pool.root_scope : Scope(parent, CURRENT_POOL => pool))
    end
    submit!(pool, task)
    return task
end

function spawn(f)
    pool = CURRENT_POOL[]
    return pool === nothing ? Threads.@spawn(f()) : spawn(f, pool)
end

function submit!(pool::ThreadPool, task::Task)
    w = @lock pool.lock begin
        if @atomic(pool.state) != OPEN
            :closed
        else
            @atomic pool.outstanding += 1
            push!(pool.queue, task)
            @atomic pool.queued = length(pool.queue)
            isempty(pool.idle) ? nothing : pop!(pool.idle)
        end
    end
    w === :closed && throw(InvalidStateException("thread pool $(pool.name) is closed", :closed))
    w === nothing || notify(w.wake)
    return task
end

function task_done!(pool::ThreadPool)
    # `close` stores CLOSING before reading `outstanding`, and this decrements before reading
    # `state`, so at least one side sees the pool drained.
    remaining = @atomic pool.outstanding -= 1
    remaining == 0 && @atomic(pool.state) == CLOSING && notify(pool.drained)
    return nothing
end

# Runs as the root task of each worker thread while it belongs to `pool`. A thread with nothing
# else runnable takes the next queued task. A busy thread leaves queued tasks for idle threads,
# but takes one per turn when no thread in the pool is idle, so new tasks share busy threads
# round-robin instead of waiting for the load to end. A taken task is pinned to this thread and
# runs once the dispatcher yields.
function dispatch(pool::ThreadPool, w::Worker)
    tid = @atomic w.tid
    while true
        @atomic(pool.state) == CLOSED && return
        busy = !local_queue_empty(tid)
        if busy && @atomic(pool.queued) == 0
            yield()
            continue
        end
        next = @lock pool.lock begin
            if @atomic(pool.state) == CLOSED
                :closed
            elseif isempty(pool.queue)
                busy || push!(pool.idle, w)
                busy ? :busy : :idle
            elseif busy && !isempty(pool.idle)
                :busy
            else
                task = popfirst!(pool.queue)
                @atomic pool.queued = length(pool.queue)
                task
            end
        end
        if next === :closed
            return
        elseif next === :busy
            yield()
        elseif next === :idle
            # Woken by `submit!` or `close`.
            @atomic(pool.state) == CLOSED || wait(w.wake)
        else
            schedule(pin!(next::Task, tid))
            yield()
        end
    end
end

worker_released!(pool::ThreadPool) = put!(pool.released, nothing)

"""
    close(pool::ThreadPool)

Stop accepting work, wait for every spawned task to finish (including queued ones), then return
the pool's threads to the cache. Closing from one of the pool's own tasks throws, since it would
wait for itself.
"""
function Base.close(pool::ThreadPool)
    ct = current_task()
    # Root tasks (the main task, a thread's initial task) have no `code`.
    job = isdefined(ct, :code) ? ct.code : nothing
    if job isa PoolJob && job.pool === pool
        throw(ArgumentError("cannot close thread pool $(pool.name) from one of its own tasks"))
    end
    first_closer = @lock pool.lock begin
        opening = @atomic(pool.state) == OPEN
        opening && @atomic pool.state = CLOSING
        opening
    end
    if !first_closer
        wait(pool.closed)
        return nothing
    end
    @atomic(pool.outstanding) == 0 && notify(pool.drained)
    wait(pool.drained)
    idle = @lock pool.lock begin
        @atomic pool.state = CLOSED
        parked = copy(pool.idle)
        empty!(pool.idle)
        parked
    end
    foreach(w -> notify(w.wake), idle)
    for _ in pool.workers
        take!(pool.released)
    end
    notify(pool.closed)
    return nothing
end

# A pool is bound to OS threads in this process. A deserialized copy (from a cache, or another
# process) would accept tasks that no thread ever runs, so refuse to serialize one.
function Serialization.serialize(::AbstractSerializer, pool::ThreadPool)
    throw(ArgumentError("ThreadPool :$(pool.name) is bound to this process's threads and cannot be serialized"))
end

Base.isopen(pool::ThreadPool) = @atomic(pool.state) == OPEN

"""
    Threads.nthreads(pool::ThreadPool)

Number of threads in `pool`.
"""
Threads.nthreads(pool::ThreadPool) = length(pool.workers)

"""
    threadids(pool::ThreadPool)

Julia thread ids of the threads in `pool`.
"""
threadids(pool::ThreadPool) = [@atomic(w.tid) for w in pool.workers]

function Base.show(io::IO, pool::ThreadPool)
    state = lowercase(string(@atomic pool.state))
    queued = @lock pool.lock length(pool.queue)
    print(io, "ThreadPool(:", pool.name, ", ", length(pool.workers), " threads, ", state,
          ", ", queued, " queued)")
end
