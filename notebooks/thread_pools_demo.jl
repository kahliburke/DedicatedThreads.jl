try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro title
@md"""
# User-defined thread pools in Julia

Julia has two thread pools, `:default` and `:interactive`, and both are sized once at startup with `-t`. You can't create another pool, resize one, or keep a latency-sensitive workload away from a busy one.

`DedicatedThreads` adds pools that you create, size, and close from Julia code on a stock runtime. Each pool owns dedicated OS threads, which are created at runtime and adopted by Julia. This notebook shows:

1. where pool threads sit next to Julia's built-in pools
2. how tasks are spread across a pool
3. **isolation**: a dedicated pool stays responsive while the default pool is saturated
4. blocking tasks free their thread
5. children inherit the pool, so library code runs wherever its caller chose
6. resizing at runtime without restarting Julia
7. closing pools and recycling their threads
"""

#%% code id=setup
using DedicatedThreads
using DedicatedThreads: owning_pool, cached_threads

(; julia = VERSION, interactive = Threads.nthreads(:interactive), default = Threads.nthreads(:default),
   maxthreadid = Threads.maxthreadid())

#%% md id=s1_md
@md"""
## 1. Pool threads next to the built-in pools

`DedicatedPool(n; name)` starts `n` OS threads, or reuses idle ones from earlier pools. Julia adopts each thread on entry, which gives it a thread id after the built-in pools and the GC threads. Julia's own `Threads.threadpool` reports these threads as `:foreign`; `owning_pool` says which user pool owns one.

The `:slate` and `:slate_ui` pools belong to the notebook worker itself. `:slate` serves its control requests (status, cancel, the hub heartbeat) and background loops; `:slate_ui` serves what keeps the page live, including cells re-run by a reactive push like the chart in section 8. Both keep working while notebook code saturates `:default`.
"""

#%% code id=layout resource
io_pool = DedicatedPool(2; name = :io)
compute_pool = DedicatedPool(3; name = :compute)
# Pools are live handles on this process's threads, so this cell is tagged `resource`: it
# re-runs on every open instead of being restored from Slate's cache. Re-running closes the old
# pools first, returning their threads to the cache.
slate_on_cleanup(() -> (close(io_pool); close(compute_pool)))

thread_layout = map(1:Threads.maxthreadid()) do tid
    owner = owning_pool(tid)
    builtin = Threads.threadpool(tid)
    role = owner !== nothing ? "user pool :$(owner.name)" :
           builtin === :foreign ? "GC / other" : "built-in :$builtin"
    (; tid, julia_threadpool = String(builtin), role)
end
slate_table(thread_layout)

#%% md id=s2_md
@md"""
## 2. Where tasks run

`spawn(f, pool)` returns an ordinary `Task`. Each pool thread runs a small dispatcher that takes queued tasks only when its thread has nothing else to run, so work goes to idle threads. Here 3000 small tasks run on the 3-thread `:compute` pool, and none of them lands outside it.
"""

#%% code id=distribution
function busy_work(n)
    s = 0.0
    for i in 1:n
        s += sin(i)
    end
    return s
end

ran_on = fetch.([spawn(() -> (busy_work(20_000); Threads.threadid()), compute_pool) for _ in 1:3000])
counts = [count(==(tid), ran_on) for tid in threadids(compute_pool)]
outside = count(!in(threadids(compute_pool)), ran_on)

echart(:bar, ["thread $t" for t in threadids(compute_pool)], counts;
       title = "3000 tasks on :compute ($outside ran elsewhere)", height = 320)

#%% md id=s3_md
@md"""
## 3. Isolation from a saturated default pool

Julia tasks are cooperative. If CPU-bound tasks occupy every `:default` thread, a new `Threads.@spawn` task waits until one of them finishes. Below, twice as many spinning tasks as there are default threads saturate the default pool. Meanwhile a probe loop running on the `:io` pool submits a tiny task every 25 ms to three places and records how long each waited before it started:

- `Threads.@spawn`: the `:default` pool, which is saturated
- `Threads.@spawn :interactive`: Julia's latency pool, one thread fixed at startup and shared with the REPL and event loop
- `spawn(f, compute_pool)`: a user pool with its own threads
"""

#%% code id=isolation
function measure_isolation(probe_pool, user_pool; spin_seconds = 2.5, probe_seconds = 2.0, interval = 0.025)
    nbusy = 2 * Threads.nthreads(:default)
    spinners = map(1:nbusy) do _
        Threads.@spawn begin
            t_end = time() + spin_seconds
            while time() < t_end
                GC.safepoint()   # never yields, but lets GC proceed
            end
        end
    end
    # Latency = time from submission until the task starts running.
    probe(submit) = (t0 = time_ns(); submit(() -> (time_ns() - t0) / 1e6))
    samples = fetch(spawn(probe_pool) do
        at = Float64[]
        default, interactive, user = Task[], Task[], Task[]
        start = time()
        while time() - start < probe_seconds
            push!(at, time() - start)
            push!(default, probe(f -> Threads.@spawn f()))
            push!(interactive, probe(f -> Threads.@spawn :interactive f()))
            push!(user, probe(f -> spawn(f, user_pool)))
            sleep(interval)
        end
        (; at, default, interactive, user)
    end)
    foreach(wait, spinners)
    return (; nbusy, at = samples.at, default_ms = fetch.(samples.default),
            interactive_ms = fetch.(samples.interactive), user_ms = fetch.(samples.user))
end

iso = measure_isolation(io_pool, compute_pool)

echart(series(:scatter, iso.at, iso.default_ms; name = "Threads.@spawn (:default, saturated)"),
       series(:scatter, iso.at, iso.interactive_ms; name = "Threads.@spawn :interactive"),
       series(:scatter, iso.at, iso.user_ms; name = "spawn(f, compute_pool)");
       title = "Wait before a tiny task starts, while $(iso.nbusy) spinners saturate :default",
       xAxis = (name = "probe time (s)", type = :value),
       yAxis = (name = "wait (ms)", type = :log),
       height = 420)

#%% code id=isolation_table
using Statistics

slate_table([
    (; target = name, median_ms = median(v), p99_ms = quantile(v, 0.99), max_ms = maximum(v))
    for (name, v) in ("Threads.@spawn (:default)" => iso.default_ms,
                      "Threads.@spawn :interactive" => iso.interactive_ms,
                      "spawn(f, compute_pool)" => iso.user_ms)
]; format = (median_ms = (kind = :fixed, digits = 3), p99_ms = (kind = :fixed, digits = 3),
             max_ms = (kind = :fixed, digits = 3)))

#%% md id=isolation_md
@md"""
On the saturated default pool, the median wait was {{ round(median(iso.default_ms); digits = 0) }} ms. On the user pool it was {{ round(1000 * median(iso.user_ms); digits = 1) }} µs. The interactive pool isolates too, but it is a single thread fixed at startup and shared with the REPL and event loop. A user pool can be as large as the workload needs, and you can have as many as you like, each sized and named for its job.
"""

#%% md id=s4_md
@md"""
## 4. Blocking tasks free their thread

Pool threads run ordinary Julia tasks, so a task that waits on IO, a lock, a channel, or `sleep` frees its thread for other work in the pool. When it wakes, it resumes on the same thread. Here 40 tasks each sleep for 250 ms on the 2-thread `:io` pool. If every sleep held a thread, this would take 5 s.
"""

#%% code id=blocking
blocking = let
    t0 = time()
    tasks = map(1:40) do _
        spawn(io_pool) do
            before = Threads.threadid()
            sleep(0.25)
            before == Threads.threadid()
        end
    end
    same_thread = fetch.(tasks)
    (; tasks = 40, pool_threads = Threads.nthreads(io_pool), elapsed_s = round(time() - t0; digits = 3),
       held_threads_would_take_s = 40 * 0.25 / Threads.nthreads(io_pool),
       all_resumed_on_same_thread = all(same_thread))
end

#%% md id=s5_md
@md"""
## 5. Children inherit the pool

`spawn(f)` without a pool submits to the **current pool**: the one set by `with_pool`, or the one the calling task belongs to. Outside any pool it falls back to Julia's `:default` pool. A library written against `spawn` therefore never chooses a pool itself; the application decides where its work runs.

`library_map` below stands in for a library function: it fans out with `spawn(f)` and never names a pool.
"""

#%% code id=inheritance
# A "library" function: fans out with `spawn(f)` and never names a pool.
library_map(f, xs) = fetch.([spawn(() -> f(x)) for x in xs])

where_am_i(_) = (owner = owning_pool(); owner === nothing ? ":$(Threads.threadpool())" : ":$(owner.name)")
ran_in(callsite) = join(sort(unique(callsite())), ", ")

slate_table([
    (; caller = "top level", tasks_ran_in = ran_in(() -> library_map(where_am_i, 1:50))),
    (; caller = "with_pool(io_pool)", tasks_ran_in = ran_in(() -> with_pool(() -> library_map(where_am_i, 1:50), io_pool))),
    (; caller = "a task on compute_pool", tasks_ran_in = ran_in(() -> fetch(spawn(() -> library_map(where_am_i, 1:50), compute_pool)))),
    (; caller = "a task on io_pool calling into compute_pool", tasks_ran_in =
        ran_in(() -> fetch(spawn(() -> fetch(spawn(() -> library_map(where_am_i, 1:50), compute_pool)), io_pool)))),
    (; caller = "@async inside a compute_pool task", tasks_ran_in =
        ran_in(() -> fetch(spawn(() -> fetch(@async library_map(where_am_i, 1:50)), compute_pool)))),
    (; caller = "Threads.@spawn inside a compute_pool task (limitation)", tasks_ran_in =
        ran_in(() -> fetch(spawn(() -> fetch.([Threads.@spawn where_am_i(0) for _ in 1:50]), compute_pool)))),
])

#%% md id=inheritance_md
@md"""
!!! note "Base constructs don't know about user pools"
    `Threads.@spawn` (including `:samepool`) and `Threads.@threads` always target Julia's built-in pools, so inside a user pool they escape to `:default`. Code meant to run in a user pool should use `spawn`. `@async` stays on the current pool thread.
"""

#%% md id=s6_md
@md"""
## 6. Sizing pools at runtime

This notebook's worker was started with `-t 4,1`, so the `:default` pool has 4 threads for the life of the process. A user pool can be any size and can be resized by creating a new one, without restarting Julia. Below, the same CPU-bound workload runs on pools of 1 to 8 threads, alongside Julia's 4-thread default pool for reference. The slider after the chart creates a pool of any size, up to this machine's {{ Sys.CPU_THREADS }} hardware threads.
"""

#%% code id=scaling
max_pool = min(8, Sys.CPU_THREADS)
chunk_work = 1_000_000
nchunks = 168   # divisible by 1–8, so every size gets an even split

time_on(spawner) = (t0 = time(); foreach(wait, [spawner(() -> busy_work(chunk_work)) for _ in 1:nchunks]); time() - t0)
best_of(spawner; reps = 3) = minimum(time_on(spawner) for _ in 1:reps)

time_on(f -> spawn(f, compute_pool))   # warm up
pool_times = map(1:max_pool) do n
    DedicatedPool(n; name = Symbol("sized", n)) do pool
        best_of(f -> spawn(f, pool))
    end
end
default_time = best_of(f -> Threads.@spawn f())

echart(series(:line, collect(1:max_pool), pool_times[1] ./ pool_times; name = "user pool", symbolSize = 8),
       series(:scatter, [Threads.nthreads(:default)], [pool_times[1] / default_time]; name = "Julia :default pool (fixed at 4)", symbolSize = 14);
       title = "Speedup over a 1-thread pool ($nchunks chunks of CPU work, best of 3)",
       xAxis = (name = "threads", type = :value, min = 1, max = max_pool),
       yAxis = (name = "speedup",), height = 380)

#%% code id=live_size
@bind live_size Slider(1:Sys.CPU_THREADS; default = 4, label = "pool threads")

live_run = let
    used = Set{Int}()
    lk = ReentrantLock()
    elapsed = DedicatedPool(live_size; name = :live) do pool
        time_on(f -> spawn(pool) do
            f()
            @lock lk push!(used, Threads.threadid())
        end)
    end
    # The pool is closed here; its threads are back in the cache for the next run.
    (; pool_threads = live_size, threads_used = length(used), elapsed_s = round(elapsed; digits = 3),
       speedup_vs_1_thread = round(pool_times[1] / elapsed; digits = 2),
       maxthreadid = Threads.maxthreadid(), cached_threads = cached_threads())
end

#%% md id=s7_md
@md"""
## 7. Closing pools and recycling threads

`close(pool)` stops accepting work, waits for every task already spawned (including queued ones), then returns the pool's threads to a process-wide cache. Julia never reuses a thread id, so threads are recycled rather than destroyed: the next pool takes cached threads before starting new ones. Creating and closing pools in a loop therefore leaves `Threads.maxthreadid()` unchanged.
"""

#%% code id=lifecycle
lifecycle = let
    maxtid_before = Threads.maxthreadid()

    # close() drains queued work before returning.
    pool = DedicatedPool(2; name = :short_lived)
    finished = Threads.Atomic{Int}(0)
    for _ in 1:200
        spawn(pool) do
            sleep(0.001)
            Threads.atomic_add!(finished, 1)
        end
    end
    close(pool)
    rejected = try
        spawn(() -> 1, pool)
        false
    catch e
        e isa InvalidStateException
    end

    # 50 more pools of 4 threads, created and closed in turn.
    t0 = time()
    for i in 1:50
        DedicatedPool(p -> fetch(spawn(() -> i, p)), 4)
    end
    per_pool_ms = 1000 * (time() - t0) / 50

    (; tasks_finished_before_close_returned = finished[], spawn_after_close_rejected = rejected,
       pools_created = 51, maxthreadid_before = maxtid_before, maxthreadid_after = Threads.maxthreadid(),
       create_spawn_close_ms_per_pool = round(per_pool_ms; digits = 2))
end

#%% md id=s8_md
@md"""
## 8. Live: isolation you can poke

The sliders start and stop CPU-bound spinner tasks, either on Julia's `:default` pool or on the user pool `:compute`. Each spinner holds its thread for 250 ms bursts and yields briefly between them. A monitor running on its own 1-thread `:monitor` pool probes each target every 100 ms and records how long a tiny task has waited to start, while it waits. It pushes the readings to a `reactive` value, and each push re-runs the chart cell on the worker's `:slate_ui` threads, so the chart keeps updating even while `:default` is saturated (its title says where it was redrawn).

Push either slider past that pool's thread count ({{ Threads.nthreads(:default) }} for `:default`, {{ Threads.nthreads(compute_pool) }} for `:compute`). Only the loaded pool's line climbs; the others stay flat. Spinners stop by themselves 60 s after they start.

!!! note "Why the spinners yield"
    Cells you run, including this one when a slider moves, still run on `:default`. Spinners that never yielded would leave no thread for those runs, so moving a slider back would wait until the spinners stopped by themselves. The control plane and the live chart would keep working, on `:slate` and `:slate_ui`.
"""

#%% code id=live_load
@bind default_load Slider(0:12; default = 0, label = "spinners on :default")
@bind compute_load Slider(0:12; default = 0, label = "spinners on :compute")

# CPU-bound work in 250 ms bursts. Each burst holds its thread without yielding; between bursts
# the spinner yields once, so a saturated pool still makes progress on other tasks, slowly.
# (A spinner that never yielded would also starve this notebook's own machinery, which runs on
# `:default`.)
function spinner(stop::Threads.Atomic{Bool})
    deadline = time() + 60
    while !stop[] && time() < deadline
        burst_end = time() + 0.25
        while time() < burst_end
            GC.safepoint()
        end
        yield()
    end
end

function start_spinners(n, submit)
    flags = [Threads.Atomic{Bool}(false) for _ in 1:n]
    foreach(stop -> submit(() -> spinner(stop)), flags)
    return flags
end

# Moving a slider re-runs this cell: the cleanup stops the previous spinners first.
spinner_flags = vcat(start_spinners(default_load, f -> Threads.@spawn f()),
                     start_spinners(compute_load, f -> spawn(f, compute_pool)))
slate_on_cleanup(() -> foreach(stop -> stop[] = true, spinner_flags))
(; default_spinners = default_load, compute_spinners = compute_load)

#%% code id=live_monitor resource
monitor_pool = DedicatedPool(1; name = :monitor)
monitor_running = Threads.Atomic{Bool}(true)
slate_on_cleanup(() -> (monitor_running[] = false; close(monitor_pool)))

@reactive latency = (t = Float64[], default = Float64[], interactive = Float64[], compute = Float64[])

# One probe in flight per target. Its wait is the time since submission, which keeps growing
# while the task hasn't started, so a blocked pool shows up immediately.
launch_probe(submit) = (started = Threads.Atomic{UInt64}(0); t0 = time_ns();
                        submit(() -> (started[] = time_ns(); nothing)); (; t0, started))
probe_started(p) = p.started[] != 0
probe_wait_ms(p) = max(((probe_started(p) ? p.started[] : time_ns()) - p.t0) / 1e6, 1e-3)

monitor_task = spawn(monitor_pool) do
    targets = (default = f -> Threads.@spawn(f()),
               interactive = f -> Threads.@spawn(:interactive, f()),
               compute = f -> spawn(f, compute_pool))
    inflight = map(launch_probe, targets)
    window = 200   # 20 s at 100 ms
    t, d, i, c = Float64[], Float64[], Float64[], Float64[]
    start = time()
    while monitor_running[]
        waits = map(probe_wait_ms, inflight)
        inflight = map((p, submit) -> probe_started(p) ? launch_probe(submit) : p, inflight, targets)
        push!(t, time() - start); push!(d, waits.default); push!(i, waits.interactive); push!(c, waits.compute)
        if length(t) > window
            foreach(v -> popfirst!(v), (t, d, i, c))
        end
        latency[] = (; t = copy(t), default = copy(d), interactive = copy(i), compute = copy(c))
        sleep(0.1)
    end
end;

#%% code id=live_chart controls=default_load,compute_load
let lat = latency[]
    t_lo = isempty(lat.t) ? 0.0 : first(lat.t)
    # Which pool redrew this chart: a reactive push re-runs it on the worker's `:slate_ui` threads.
    owner = owning_pool()
    ran_on = owner === nothing ? string(Threads.threadpool()) : string(owner.name)
    echart(series(:line, lat.t, lat.default; name = "Threads.@spawn (:default)", showSymbol = false),
           series(:line, lat.t, lat.interactive; name = "Threads.@spawn :interactive", showSymbol = false),
           series(:line, lat.t, lat.compute; name = "spawn(f, compute_pool)", showSymbol = false);
           title = "Current wait before a probe task starts · redrawn on :$ran_on",
           xAxis = (name = "s", type = :value, min = round(t_lo; digits = 1), max = round(t_lo + 20; digits = 1)),
           yAxis = (name = "wait (ms)", type = :log, min = 0.001, max = 100_000),
           animation = false, height = 420)
end

#%% md id=summary_md
@md"""
## How it works, and its limits

- **Threads:** raw OS threads entering Julia through a `@cfunction`, which adopts them. All use of runtime internals is in `src/runtime.jl`.
- **Scheduling:** each pool thread runs a dispatcher. It takes a queued task when its thread is idle, pins the task to that thread, and hands it to Julia's own scheduler.
- **Inheritance:** the current pool is a `ScopedValue`, so tasks a pool runs, and their children, see the same pool.

Limitations:

- A task stays on the thread that first ran it. Tasks are balanced across threads only when they start, never mid-run.
- `Threads.@spawn` and `Threads.@threads` don't know about user pools (section 5).
- A blocking `ccall` holds its thread, as on any Julia thread.
- `close` never cancels anything, so a task that never yields keeps it waiting.

The README and `notes/landscape.md` in the repository cover the design survey and how this relates to upstream work on Julia's scheduler.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   threads = 4,1
#   docid = c86f06a0-4eb4-4c60-9fba-1ed66da3e57c
# ╚═╡
