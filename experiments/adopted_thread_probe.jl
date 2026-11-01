# Probe: can an OS thread created at runtime host ordinary Julia tasks?
#
# A raw thread enters Julia through a @cfunction, which adopts it (tid > maxthreadid at
# startup, pool :foreign). Its root task parks in `wait()` like any other worker thread, so
# tasks pinned to it (sticky + tid) are run there, and blocking operations resume there.

module AdoptProbe

const JOBS = Channel{Any}(Inf)

function worker_main(::Ptr{Cvoid})::Ptr{Cvoid}
    try
        # Parks the adopted thread's root task; pinned tasks run while it waits.
        for f in JOBS
            f === nothing && break
            Base.invokelatest(f)
        end
    catch
    end
    return C_NULL
end

"""Create an OS thread, adopt it into the Julia runtime, and return its Julia tid."""
function spawn_adopted_thread()
    ready = Channel{Int}(1)
    cf = @cfunction(worker_main, Ptr{Cvoid}, (Ptr{Cvoid},))
    th = Ref{UInt}(0)
    rc = ccall(:uv_thread_create, Cint, (Ptr{UInt}, Ptr{Cvoid}, Ptr{Cvoid}), th, cf, C_NULL)
    rc == 0 || error("uv_thread_create failed: $rc")
    put!(JOBS, () -> put!(ready, Threads.threadid()))
    return take!(ready)
end

"""Run `f` on thread `tid` by pinning a sticky task to it."""
function run_on(tid::Integer, f)
    t = Task(f)
    t.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1)
    schedule(t)
    return t
end

end

using .AdoptProbe

tid = AdoptProbe.spawn_adopted_thread()
probe(f) = fetch(AdoptProbe.run_on(tid, f))

results = (
    plain = probe(() -> (Threads.threadid(), Threads.threadpool())),
    after_sleep = probe(() -> (sleep(0.1); Threads.threadid())),
    async_child = probe(() -> fetch(@async (sleep(0.05); Threads.threadid()))),
    spawn_child = probe(() -> Threads.threadpool(fetch(Threads.@spawn Threads.threadid()))),
    samepool_child = probe(() -> Threads.threadpool(fetch(Threads.@spawn :samepool Threads.threadid()))),
    gc = probe(() -> (GC.gc(); Threads.threadid())),
)
