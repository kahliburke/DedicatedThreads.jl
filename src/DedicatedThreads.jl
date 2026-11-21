module DedicatedThreads

using Base.ScopedValues: ScopedValue, Scope, @with
using Serialization: Serialization, AbstractSerializer

export DedicatedPool, spawn, with_pool, current_pool, threadids
export Realtime, realtime!, isrealtime, realtime_granted, qos!, qos, qos_granted
export wait_on_address, wake_address, Parker, park, unpark
export DeadlineLog, Overrun, begin_iteration, end_iteration!, overruns, deadline_stats

include("runtime.jl")
include("realtime.jl")
include("addresswait.jl")
include("deadline.jl")
include("worker.jl")
include("pool.jl")

function __init__()
    detect_runtime_features()
    detect_address_wait()
end

end # module DedicatedThreads
