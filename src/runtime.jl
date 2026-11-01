# Every use of Julia runtime internals is confined to this file, so the package's dependency on
# unstable interfaces is explicit and in one place.

"""
    create_os_thread(entry::Ptr{Cvoid}, arg::Ptr{Cvoid})

Start a detached OS thread running the C function `entry(arg)`. When `entry` is a
`@cfunction`, the thread is adopted by the Julia runtime on entry.
"""
function create_os_thread(entry::Ptr{Cvoid}, arg::Ptr{Cvoid})
    # uv_thread_t is pthread_t or a HANDLE; reserve enough room for either.
    handle = Ref{NTuple{32,UInt8}}(ntuple(_ -> 0x00, Val(32)))
    err = ccall(:uv_thread_create, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), handle, entry, arg)
    err == 0 || Base.uv_error("uv_thread_create", err)
    ccall(:uv_thread_detach, Cint, (Ptr{Cvoid},), handle)
    return nothing
end

"""
    pin!(t::Task, tid::Integer)

Bind an unstarted task to thread `tid`. The scheduler will only run it there, and every wakeup
(after a lock, IO, `sleep`, ...) returns it to that thread's local queue.
"""
function pin!(t::Task, tid::Integer)
    t.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1) == 1 ||
        error("task is already bound to thread $(Threads.threadid(t))")
    return t
end

"""
    current_scope()

The calling task's dynamic scope (the chain of `ScopedValue` bindings), or `nothing`.
"""
current_scope() = Core.current_scope()

"""
    set_scope!(t::Task, scope)

Replace an unstarted task's dynamic scope. Equivalent to creating the task inside a `with`
block for `scope`, without entering the scope on the calling task.
"""
function set_scope!(t::Task, scope::Union{Nothing,Scope})
    t.scope = scope
    return t
end

"""
    local_queue_empty(tid::Integer)

Whether thread `tid` has no runnable tasks pinned to it.
"""
local_queue_empty(tid::Integer) = isempty(Base.workqueue_for(Int(tid)))

const HAS_TASK_SWITCHING_OPT_IN = Ref(false)

function detect_runtime_features()
    HAS_TASK_SWITCHING_OPT_IN[] = try
        cglobal(:jl_thread_allow_task_switching) != C_NULL
    catch
        false
    end
    return nothing
end

"""
    allow_task_switching()

Declare the calling adopted thread as donated to the scheduler, so it may run tasks other than
the one that entered Julia. Runtimes that deny task switching on adopted threads by default
provide `jl_thread_allow_task_switching`; on runtimes without it switching is always allowed.
"""
function allow_task_switching()
    if HAS_TASK_SWITCHING_OPT_IN[]
        ccall(:jl_thread_allow_task_switching, Cint, (Cint,), 1)
    end
    return nothing
end

"""
    set_thread_name(name::AbstractString)

Name the calling OS thread for profilers and debuggers. Best effort: names are truncated to
the platform limit and unsupported platforms are ignored.
"""
function set_thread_name(name::AbstractString)
    # Linux limits names to 15 bytes plus the terminator; macOS allows 63.
    limit = Sys.islinux() ? 15 : 63
    s = String(first(name, limit))
    if Sys.isapple()
        ccall(:pthread_setname_np, Cint, (Cstring,), s)
    elseif Sys.islinux()
        ccall(:pthread_setname_np, Cint, (UInt, Cstring), ccall(:pthread_self, UInt, ()), s)
    end
    return nothing
end
