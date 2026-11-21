# Real-time scheduling for the calling thread. On macOS the Mach time-constraint policy: the thread
# says how often it runs and how much of each period it needs, and the scheduler puts it ahead of
# ordinary threads and keeps it on a performance core. On Linux SCHED_FIFO, which needs a real-time
# priority allowance (`ulimit -r`, or CAP_SYS_NICE); without one, RealtimeKit, the desktop's broker for
# real-time priority, is asked instead (see `rtkit_realtime!`). On Windows the thread joins MMCSS's
# Pro Audio task (see `mmcss_realtime!`). Elsewhere the request is refused.

"""
    Realtime(; period, compute = period / 2, constraint = period)

A real-time scheduling request, in seconds: the thread wakes every `period`, needs `compute` of
CPU time in each one, and must have it within `constraint` of waking. On Linux only the request
itself matters: the thread runs under SCHED_FIFO at `priority` (1–99), or, granted by RealtimeKit,
under SCHED_RR at the highest priority it allows if that is lower. On Windows MMCSS sets the
priority from its Pro Audio task, so the request's figures go unused.
"""
struct Realtime
    period_ns::UInt64
    compute_ns::UInt64
    constraint_ns::UInt64
    priority::Int
    function Realtime(period_ns::Integer, compute_ns::Integer, constraint_ns::Integer, priority::Integer)
        0 < compute_ns <= constraint_ns <= period_ns ||
            throw(ArgumentError("need 0 < compute ≤ constraint ≤ period, got $compute_ns, $constraint_ns, $period_ns ns"))
        1 <= priority <= 99 || throw(ArgumentError("a real-time priority is 1–99, got $priority"))
        new(period_ns, compute_ns, constraint_ns, priority)
    end
end

ns(s::Real) = round(UInt64, s * 1e9)
Realtime(; period::Real, compute::Real = period / 2, constraint::Real = period, priority::Integer = 80) =
    Realtime(ns(period), ns(compute), ns(constraint), priority)

function Base.show(io::IO, rt::Realtime)
    ms(x) = round(x / 1e6; digits = 3)
    print(io, "Realtime(period = ", ms(rt.period_ns), " ms, compute = ", ms(rt.compute_ns),
          " ms, constraint = ", ms(rt.constraint_ns), " ms)")
end

# Mach: thread_policy flavors and their sizes in natural_t words.
const THREAD_STANDARD_POLICY = Cint(1)
const THREAD_TIME_CONSTRAINT_POLICY = Cint(2)
const THREAD_TIME_CONSTRAINT_POLICY_COUNT = UInt32(4)

mach_thread_self() = ccall(:pthread_mach_thread_np, UInt32, (UInt,), ccall(:pthread_self, UInt, ()))

function mach_ticks_per_ns()
    tb = Ref{NTuple{2,UInt32}}((0, 0))
    ccall(:mach_timebase_info, Cint, (Ref{NTuple{2,UInt32}},), tb)
    numer, denom = tb[]
    return denom / numer                       # ticks = ns × denom / numer
end

"""
    realtime!(rt::Realtime) -> Bool
    realtime!(nothing) -> Bool

Put the calling OS thread under real-time scheduling, or return it to the ordinary policy.
Returns whether the system granted the change; a refusal leaves the thread as it was.
"""
function realtime!(rt::Realtime)
    if Sys.isapple()
        k = mach_ticks_per_ns()
        ticks(x) = UInt32(min(round(UInt64, x * k), typemax(UInt32)))
        policy = UInt32[ticks(rt.period_ns), ticks(rt.compute_ns), ticks(rt.constraint_ns), 1]   # preemptible
        r = ccall(:thread_policy_set, Cint, (UInt32, Cint, Ptr{UInt32}, UInt32),
                  mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT)
        return r == 0
    elseif Sys.islinux()
        ccall(:sched_setscheduler, Cint, (Cint, Cint, Ref{Cint}), 0, 1, Cint(rt.priority)) == 0 && return true   # SCHED_FIFO
        return rtkit_realtime!(rt.priority)
    elseif Sys.iswindows()
        return mmcss_realtime!()
    end
    return false
end

function realtime!(::Nothing)
    if Sys.isapple()
        r = ccall(:thread_policy_set, Cint, (UInt32, Cint, Ptr{UInt32}, UInt32),
                  mach_thread_self(), THREAD_STANDARD_POLICY, Ref(UInt32(0)), 0)
        return r == 0
    elseif Sys.islinux()
        return ccall(:sched_setscheduler, Cint, (Cint, Cint, Ref{Cint}), 0, 0, Cint(0)) == 0          # SCHED_OTHER
    elseif Sys.iswindows()
        return mmcss_revert!()
    end
    return true
end

"""
    isrealtime() -> Bool

Whether the calling OS thread is under real-time scheduling.
"""
function isrealtime()
    if Sys.isapple()
        policy = zeros(UInt32, 4); count = Ref(THREAD_TIME_CONSTRAINT_POLICY_COUNT); default = Ref{Cint}(0)
        r = ccall(:thread_policy_get, Cint, (UInt32, Cint, Ptr{UInt32}, Ref{UInt32}, Ref{Cint}),
                  mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, policy, count, default)
        return r == 0 && default[] == 0
    elseif Sys.islinux()
        return (ccall(:sched_getscheduler, Cint, (Cint,), 0) & ~SCHED_RESET_ON_FORK) in (1, 2)   # SCHED_FIFO, SCHED_RR
    elseif Sys.iswindows()
        return lock(() -> haskey(MMCSS_TASKS, win_thread_id()), MMCSS_LOCK)
    end
    return false
end

# Windows: the Multimedia Class Scheduler Service (MMCSS) raises a thread registered in its "Pro Audio" task
# into the real-time priority range for as long as it stays registered; no privilege is needed. The task's
# handle is kept per thread to leave it again.

const MMCSS_TASK = "Pro Audio"
const AVRT_PRIORITY_CRITICAL = Cint(2)
"Each OS thread registered with MMCSS, by its thread id: the handle that leaves it."
const MMCSS_TASKS = Dict{UInt32,Ptr{Cvoid}}()
const MMCSS_LOCK = Threads.SpinLock()

win_thread_id() = ccall((:GetCurrentThreadId, "kernel32"), UInt32, ())

"Register the calling thread with MMCSS's Pro Audio task at critical priority: whether it was taken."
function mmcss_realtime!()
    id = win_thread_id(); lock(() -> haskey(MMCSS_TASKS, id), MMCSS_LOCK) && return true
    idx = Ref{UInt32}(0)
    h = ccall((:AvSetMmThreadCharacteristicsW, "avrt"), Ptr{Cvoid}, (Cwstring, Ref{UInt32}), MMCSS_TASK, idx)
    h == C_NULL && return false
    ccall((:AvSetMmThreadPriority, "avrt"), Cint, (Ptr{Cvoid}, Cint), h, AVRT_PRIORITY_CRITICAL)
    lock(() -> (MMCSS_TASKS[id] = h), MMCSS_LOCK)
    return true
end

"Take the calling thread out of MMCSS, if it is in: whether it is out."
function mmcss_revert!()
    h = lock(() -> pop!(MMCSS_TASKS, win_thread_id(), C_NULL), MMCSS_LOCK)
    h == C_NULL && return true
    return ccall((:AvRevertMmThreadCharacteristics, "avrt"), Cint, (Ptr{Cvoid},), h) != 0
end

# RealtimeKit, on the system D-Bus: it grants a thread of a process real-time scheduling (SCHED_RR, at a
# modest priority) when the process caps the CPU time its real-time threads may take without blocking
# (RLIMIT_RTTIME; past it the kernel signals and then kills the process, so a real-time thread must sleep
# now and then). Asked through libdbus directly, so the thread asking neither yields nor spawns a process.

const SCHED_RESET_ON_FORK = Cint(0x40000000)
const RLIMIT_RTTIME = Cint(15)
const LIBDBUS = "libdbus-1.so.3"
const RTKIT_NAME = "org.freedesktop.RealtimeKit1"
const RTKIT_PATH = "/org/freedesktop/RealtimeKit1"
const DBUS_BUS_SYSTEM = Cint(1)
const DBUS_TIMEOUT_MS = Cint(1000)

"The calling OS thread's kernel id."
function gettid()
    nr = Sys.ARCH === :x86_64 ? 186 : Sys.ARCH === :aarch64 ? 178 : Sys.ARCH === :i686 ? 224 : -1
    nr < 0 ? Int(ccall(:gettid, Cint, ())) : Int(ccall(:syscall, Clong, (Clong,), nr))
end

dbus_error() = (e = zeros(UInt8, 64); ccall((:dbus_error_init, LIBDBUS), Cvoid, (Ptr{UInt8},), e); e)   # a DBusError, room to spare
dbus_error_free(e) = ccall((:dbus_error_free, LIBDBUS), Cvoid, (Ptr{UInt8},), e)
dbus_iter() = zeros(UInt8, 128)                                                                     # a DBusMessageIter, room to spare

dbus_append(it, t::Char, v::AbstractString) =
    (s = String(v); GC.@preserve s ccall((:dbus_message_iter_append_basic, LIBDBUS), Cuint, (Ptr{UInt8}, Cint, Ref{Ptr{UInt8}}), it, Cint(t), pointer(s)) != 0)
dbus_append(it, t::Char, v::T) where {T<:Integer} =
    ccall((:dbus_message_iter_append_basic, LIBDBUS), Cuint, (Ptr{UInt8}, Cint, Ref{T}), it, Cint(t), v) != 0

"""
    rtkit_send(conn, iface, method, args...) -> reply or C_NULL

Call RealtimeKit's `iface.method` with `args` (each a D-Bus type character and a value) and wait for
the reply (to be unreferenced by the caller), or C_NULL when it fails or refuses.
"""
function rtkit_send(conn, iface, method, args...)
    msg = ccall((:dbus_message_new_method_call, LIBDBUS), Ptr{Cvoid}, (Cstring, Cstring, Cstring, Cstring), RTKIT_NAME, RTKIT_PATH, iface, method)
    msg == C_NULL && return C_NULL
    it = dbus_iter(); ccall((:dbus_message_iter_init_append, LIBDBUS), Cvoid, (Ptr{Cvoid}, Ptr{UInt8}), msg, it)
    ok = all(a -> dbus_append(it, a...), args)
    err = dbus_error()
    reply = ok ? ccall((:dbus_connection_send_with_reply_and_block, LIBDBUS), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Ptr{UInt8}),
                       conn, msg, DBUS_TIMEOUT_MS, err) : C_NULL
    dbus_error_free(err); ccall((:dbus_message_unref, LIBDBUS), Cvoid, (Ptr{Cvoid},), msg)
    reply
end

"RealtimeKit's property `name`, of D-Bus type `t` read as `T`, or nothing."
function rtkit_property(conn, name, t::Char, ::Type{T}) where {T}
    reply = rtkit_send(conn, "org.freedesktop.DBus.Properties", "Get", ('s', RTKIT_NAME), ('s', name))
    reply == C_NULL && return nothing
    try
        it = dbus_iter(); sub = dbus_iter()
        ccall((:dbus_message_iter_init, LIBDBUS), Cuint, (Ptr{Cvoid}, Ptr{UInt8}), reply, it) == 0 && return nothing
        ccall((:dbus_message_iter_get_arg_type, LIBDBUS), Cint, (Ptr{UInt8},), it) == Cint('v') || return nothing
        ccall((:dbus_message_iter_recurse, LIBDBUS), Cvoid, (Ptr{UInt8}, Ptr{UInt8}), it, sub)
        ccall((:dbus_message_iter_get_arg_type, LIBDBUS), Cint, (Ptr{UInt8},), sub) == Cint(t) || return nothing
        v = Ref{T}(zero(T)); ccall((:dbus_message_iter_get_basic, LIBDBUS), Cvoid, (Ptr{UInt8}, Ref{T}), sub, v)
        v[]
    finally
        ccall((:dbus_message_unref, LIBDBUS), Cvoid, (Ptr{Cvoid},), reply)
    end
end

"The process's real-time CPU time capped at `usec` (RLIMIT_RTTIME, soft and hard) if it is not already within it: whether it is."
function rttime_cap!(usec::Integer)
    lim = Ref{NTuple{2,UInt64}}((0, 0))
    ccall(:getrlimit, Cint, (Cint, Ref{NTuple{2,UInt64}}), RLIMIT_RTTIME, lim) == 0 || return false
    cur, hard = lim[]; c = UInt64(usec)
    cur <= c && hard <= c && return true
    ccall(:setrlimit, Cint, (Cint, Ref{NTuple{2,UInt64}}), RLIMIT_RTTIME, (min(cur, c), min(hard, c))) == 0
end

"""
    rtkit_realtime!(priority) -> Bool

Ask RealtimeKit to put the calling thread under real-time scheduling at `priority`, or at the highest it
allows if that is lower, capping the process's real-time CPU time as it requires. Whether it was granted:
false where there is no libdbus, no RealtimeKit, or it refuses.
"""
function rtkit_realtime!(priority::Integer)
    Sys.islinux() && Base.Libc.Libdl.dlopen_e(LIBDBUS) != C_NULL || return false
    err = dbus_error()
    conn = ccall((:dbus_bus_get, LIBDBUS), Ptr{Cvoid}, (Cint, Ptr{UInt8}), DBUS_BUS_SYSTEM, err)
    dbus_error_free(err); conn == C_NULL && return false
    try
        top = rtkit_property(conn, "MaxRealtimePriority", 'i', Int32); top === nothing && return false
        cap = rtkit_property(conn, "RTTimeUSecMax", 'x', Int64); cap === nothing && return false
        rttime_cap!(cap) || return false
        reply = rtkit_send(conn, RTKIT_NAME, "MakeThreadRealtime", ('t', UInt64(gettid())), ('u', UInt32(clamp(priority, 1, max(top, 1)))))
        reply == C_NULL && return false
        ccall((:dbus_message_unref, LIBDBUS), Cvoid, (Ptr{Cvoid},), reply)
        return true
    finally
        ccall((:dbus_connection_unref, LIBDBUS), Cvoid, (Ptr{Cvoid},), conn)
    end
end

# Quality of service: on macOS a thread's class tells the scheduler how much its work matters to the
# user. The higher classes run on the performance cores and ahead of lower ones; `:utility` and
# `:background` drift to the efficiency cores. Elsewhere there are no classes.

"The quality-of-service classes, highest first, by name (macOS's `qos_class_t` values)."
const QOS_CLASSES = (interactive = 0x21, initiated = 0x19, default = 0x15, utility = 0x11, background = 0x09)

"""
    qos!(class::Symbol) -> Bool

Put the calling OS thread in quality-of-service class `class` (one of `keys(QOS_CLASSES)`). Returns
whether the system took it: always `false` off macOS, where there are no classes.
"""
function qos!(class::Symbol)
    c = get(QOS_CLASSES, class, nothing)
    c === nothing && throw(ArgumentError("a quality-of-service class is one of $(join(keys(QOS_CLASSES), ", ")), got $class"))
    Sys.isapple() || return false
    return ccall(:pthread_set_qos_class_self_np, Cint, (UInt32, Cint), c, 0) == 0
end

"""
    qos() -> Symbol

The calling OS thread's quality-of-service class (see [`qos!`](@ref)): `:unspecified` for a thread
never given one, and off macOS.
"""
function qos()
    Sys.isapple() || return :unspecified
    c = Ref{UInt32}(0); rel = Ref{Cint}(0)
    ccall(:pthread_get_qos_class_np, Cint, (UInt, Ref{UInt32}, Ref{Cint}), ccall(:pthread_self, UInt, ()), c, rel)
    for (k, v) in pairs(QOS_CLASSES); v == c[] && return k; end
    return :unspecified
end
