# Per-task cost of spawning and fetching trivial tasks: pool vs. Julia's default pool.
#
#   julia -t 4 --project bench/spawn_overhead.jl

using ImprovedJuliaThreadPools

function ns_per_task(spawner, n)
    GC.gc()
    t0 = time_ns()
    ts = [spawner(i) for i in 1:n]
    s = sum(fetch, ts)
    s == n * (n + 1) ÷ 2 || error("wrong result")
    return (time_ns() - t0) / n
end

best(spawner; n = 100_000, reps = 5) = (ns_per_task(spawner, 10_000); minimum(ns_per_task(spawner, n) for _ in 1:reps))

nt = Threads.nthreads(:default)
results = ThreadPool(nt; name = :bench) do pool
    (
        pool_from_outside = best(i -> spawn(() -> i, pool)),
        pool_from_with_pool = with_pool(() -> best(i -> spawn(() -> i)), pool),
        pool_from_inside = fetch(spawn(() -> best(i -> spawn(() -> i)), pool)),
        threads_spawn = best(i -> Threads.@spawn(i)),
    )
end

println("ns per spawn+fetch, $nt pool threads vs $nt default threads")
for (k, v) in pairs(results)
    println(rpad(k, 22), round(v; digits = 0))
end
