# A record of the times a loop with a deadline (an audio block, a frame) overran it, and how much of
# each overrun the garbage collector accounts for. Recording costs no allocation, so it can stay on
# in the loop it watches.

"""
    Overrun

One overrun in a [`DeadlineLog`](@ref): when the iteration began (`time_ns()`), how long it took,
its budget, and the garbage-collection time that fell inside it.
"""
struct Overrun
    at_ns::UInt64
    elapsed_ns::UInt64
    budget_ns::UInt64
    gc_ns::UInt64
end

function Base.show(io::IO, o::Overrun)
    ms(x) = round(x / 1e6; digits = 2)
    print(io, "Overrun(", ms(o.elapsed_ns), " ms of ", ms(o.budget_ns), " ms, gc ", ms(o.gc_ns), " ms)")
end

"""
    DeadlineLog(; capacity = 256)

Keeps the last `capacity` overruns of a loop. Each iteration calls [`begin_iteration`](@ref) and
then [`end_iteration!`](@ref) with its budget; read the overruns from any thread with
[`overruns`](@ref). One thread records.
"""
mutable struct DeadlineLog
    const ring::Vector{Overrun}
    @atomic count::Int                         # overruns recorded, ever
    @atomic iterations::Int
    @atomic worst_ns::UInt64
end

DeadlineLog(; capacity::Integer = 256) = DeadlineLog(Vector{Overrun}(undef, capacity), 0, 0, 0)

"""
    begin_iteration(log) -> token

The start of an iteration: the time and the garbage collector's running total, to pass to
[`end_iteration!`](@ref).
"""
begin_iteration(::DeadlineLog) = (time_ns(), gc_total_ns())

"""
    end_iteration!(log, token, budget_ns) -> Bool

Close the iteration begun with `token`; records an [`Overrun`](@ref) when it took longer than
`budget_ns`, and returns whether it did.
"""
function end_iteration!(log::DeadlineLog, token::Tuple{UInt64,UInt64}, budget_ns::Integer)
    t0, gc0 = token
    el = time_ns() - t0
    @atomic log.iterations += 1
    el > @atomic(log.worst_ns) && @atomic(log.worst_ns = el)
    el <= budget_ns && return false
    n = @atomic log.count
    @inbounds log.ring[n % length(log.ring) + 1] = Overrun(t0, el, UInt64(budget_ns), gc_total_ns() - gc0)
    @atomic log.count = n + 1
    return true
end

"""
    overruns(log) -> Vector{Overrun}

The overruns kept, oldest first.
"""
function overruns(log::DeadlineLog)
    n = @atomic log.count; c = length(log.ring); k = min(n, c)
    [log.ring[(n - k + i) % c + 1] for i in 0:k-1]
end

"""
    deadline_stats(log)

Iterations seen, overruns, how many of them overlapped a garbage collection, and the slowest
iteration in milliseconds.
"""
function deadline_stats(log::DeadlineLog)
    os = overruns(log)
    (iterations = @atomic(log.iterations), overruns = @atomic(log.count), with_gc = count(o -> o.gc_ns > 0, os),
     worst_ms = @atomic(log.worst_ns) / 1e6)
end
