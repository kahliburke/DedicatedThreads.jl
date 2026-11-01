module DedicatedThreads

using Base.ScopedValues: ScopedValue, Scope, @with
using Serialization: Serialization, AbstractSerializer

export DedicatedPool, spawn, with_pool, current_pool, threadids

include("runtime.jl")
include("worker.jl")
include("pool.jl")

function __init__()
    detect_runtime_features()
end

end # module DedicatedThreads
