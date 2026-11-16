# Real-time scheduling for the calling thread. On macOS the Mach time-constraint policy: the thread
# says how often it runs and how much of each period it needs, and the scheduler puts it ahead of
# ordinary threads and keeps it on a performance core. On Linux SCHED_FIFO, which needs a real-time
# priority allowance (`ulimit -r`, or CAP_SYS_NICE). Elsewhere the request is refused.

"""
    Realtime(; period, compute = period / 2, constraint = period)

A real-time scheduling request, in seconds: the thread wakes every `period`, needs `compute` of
CPU time in each one, and must have it within `constraint` of waking. On Linux only the request
itself matters: the thread runs under SCHED_FIFO at `priority` (1–99).
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
        return ccall(:sched_setscheduler, Cint, (Cint, Cint, Ref{Cint}), 0, 1, Cint(rt.priority)) == 0   # SCHED_FIFO
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
        return ccall(:sched_getscheduler, Cint, (Cint,), 0) == 1
    end
    return false
end
