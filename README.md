# DedicatedThreads.jl

[![CI](https://github.com/kahliburke/DedicatedThreads.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/kahliburke/DedicatedThreads.jl/actions/workflows/CI.yml)

Thread pools for Julia, created at runtime.

Julia has two thread pools, `:default` and `:interactive`, and both are sized at startup with
`-t`. When `:default` is full of long-running work, every new `Threads.@spawn` waits for a thread
to free up. `:interactive` avoids that, but it is one small pool shared with the REPL and
everything else that uses it.

DedicatedThreads lets you create pools from Julia code while the program runs. Each pool has its
own OS threads, so its tasks start right away no matter how busy `:default` is. You choose how
many pools to create, how many threads each gets, and what runs on them.

## Installation

```julia
pkg> add DedicatedThreads
```

Requires Julia 1.12 or later. It works with any `-t` setting, including `-t 1`.

## Quick start

```julia
using DedicatedThreads

pool = DedicatedPool(2; name = :workers)   # start 2 new OS threads

t = spawn(pool) do
    # Runs on one of the pool's threads.
    sum(abs2, 1:10)
end
fetch(t)        # 385

close(pool)     # wait for the pool's tasks, then release its threads
```

`spawn` returns an ordinary `Task`, so `fetch`, `wait`, `istaskdone` and `errormonitor` work as
usual. The do-block form of `DedicatedPool` closes the pool when the block ends:

```julia
DedicatedPool(2; name = :workers) do pool
    fetch(spawn(() -> sum(abs2, 1:10), pool))
end
```

## Examples

### Keep a control task responsive

A task on a pool doesn't wait for `:default`. Here every `:default` thread is busy for 2
seconds:

```julia
using DedicatedThreads

control = DedicatedPool(1; name = :control)

# One spinning task per :default thread. GC.safepoint() lets garbage collection run.
busy = [Threads.@spawn begin
            t_end = time() + 2
            while time() < t_end
                GC.safepoint()
            end
        end
        for _ in 1:Threads.nthreads(:default)]

# Each task returns how long it waited to start.
t0 = time()
fetch(spawn(() -> time() - t0, control))   # starts right away
fetch(Threads.@spawn time() - t0)          # about 2 s: waits for a :default thread

foreach(wait, busy)
close(control)
```

Use this for status reporting, cancellation, heartbeats and anything else that must answer while
the program is busy.

### Choose a pool for library code

`spawn(f)` without a pool runs `f` on the *current* pool. Inside a pool task, the current pool is
that task's pool, and every task it creates inherits it. Outside any pool, `spawn(f)` behaves
like `Threads.@spawn`. A library that parallelizes with `spawn(f)` therefore runs wherever its
caller decides:

```julia
using DedicatedThreads

# Library code: parallel map with spawn instead of Threads.@spawn.
pmap_sum(f, xs) = sum(fetch, [spawn(() -> f(x)) for x in xs])

pmap_sum(abs2, 1:100)                       # on :default

DedicatedPool(4; name = :analysis) do pool
    with_pool(pool) do
        pmap_sum(abs2, 1:100)               # on the pool's 4 threads
    end
end
```

`with_pool(f, pool)` makes `pool` current for `f()` and every task it starts, from any task.
`current_pool()` returns the current pool, or `nothing` outside one.

### Blocking tasks share threads

Pool threads run ordinary Julia tasks. A task that waits on IO, a lock, a `Channel` or `sleep`
frees its thread for the pool's other tasks, and resumes on the same thread when it wakes:

```julia
DedicatedPool(2; name = :io) do pool
    @time foreach(wait, [spawn(() -> sleep(0.5), pool) for _ in 1:20])
    # about 0.5 s on 2 threads, not 5 s
end
```

### Run other code on a pool without giving it the pool

A pool task that runs code it doesn't own, such as a request handler or a user callback, may not
want that code's `spawn` calls to land on the pool. `with_pool(f, nothing)` runs `f()` outside any
pool, so its `spawn(f)` calls go to `:default`:

```julia
using DedicatedThreads

server = DedicatedPool(1; name = :server)

# Run a callback on the server pool, keeping the callback's own spawn calls off it.
function run_callback(f, pool)
    spawn(pool) do
        # Code here runs on the pool, and its spawn calls go to the pool.
        with_pool(f, nothing)
    end
end

t = run_callback(server) do
    fetch(spawn(() -> Threads.threadpool()))
end
fetch(t)        # :default

close(server)
```

### Long-lived pools

A pool can live for the whole program. Create it once, keep it in a `const`, and spawn onto it
from anywhere:

```julia
module MyService

using DedicatedThreads

const POOL = Ref{DedicatedPool}()

__init__() = POOL[] = DedicatedPool(2; name = :myservice)

submit(f) = spawn(f, POOL[])

end
```

Create pools in `__init__`, not at the top level of a module. A pool belongs to the threads of
the running process, so a pool saved during precompilation would have no threads.

`close(pool)` waits for every task, queued ones included, and returns the threads to a
process-wide cache. Later pools take threads from the cache before starting new ones.

### Loops with deadlines

An audio block, a video frame or a control tick has to finish on time, every time. Three things
get in its way, and the package handles each:

- **Other processes.** `realtime = Realtime(period = …)` puts the pool's threads under real-time
  scheduling: the Mach time-constraint policy on macOS, `SCHED_FIFO` on Linux (which needs a
  real-time allowance). Threads go back to the ordinary policy when the pool closes.
  `realtime_granted(pool)` says whether the system agreed.
- **Waiting.** `wait_on_address(p, expected)` parks the thread in the OS until the word at `p`
  changes, and `wake_address(p)` wakes it. The thread is parked in a GC-safe call, so a garbage
  collection never waits for it. With `shared = true` the word can live in memory shared with
  another process. `Parker` wraps this as a park/unpark pair for one waiting thread.
- **Knowing why one was late.** A `DeadlineLog` records each iteration that overran its budget,
  with the garbage-collection time inside it. Recording doesn't allocate.

```julia
using DedicatedThreads

block = 512 / 48_000                                   # seconds per audio block
audio = DedicatedPool(1; name = :audio, realtime = Realtime(period = block))
log = DeadlineLog()
ready = Parker()

spawn(audio) do
    while true
        park(ready)                                    # until a block is wanted
        tk = begin_iteration(log)
        render_block()
        end_iteration!(log, tk, round(Int, 0.8block * 1e9))
    end
end

unpark(ready)                                          # from wherever blocks are requested
deadline_stats(log)    # (iterations = …, overruns = …, with_gc = …, worst_ms = …)
```

A collection still stops every thread running Julia code, real-time or not. A loop that must never
miss renders ahead of its deadline, and the log shows how much margin it needs.

## API

| | |
|---|---|
| `DedicatedPool(n; name)` | Create a pool of `n` threads. `name` is a `Symbol` used when printing the pool. |
| `DedicatedPool(f, n; name)` | Create a pool, call `f(pool)`, and close the pool afterwards. |
| `spawn(f, pool)` | Run `f()` on `pool` and return its `Task`. |
| `spawn(f)` | Run `f()` on the current pool, or on `:default` when there is none. |
| `with_pool(f, pool)` | Make `pool` current for `f()` and every task it creates. |
| `with_pool(f, nothing)` | Run `f()` outside any pool, so its `spawn(f)` calls go to `:default`. |
| `current_pool()` | The current pool, or `nothing`. |
| `close(pool)` | Stop accepting work, wait for all tasks, and release the threads. |
| `isopen(pool)` | Whether the pool still accepts work. |
| `threadids(pool)` | The pool's Julia thread ids. |
| `Threads.nthreads(pool)` | The number of threads in the pool. |
| `DedicatedPool(n; realtime = Realtime(period, compute, constraint))` | A pool whose threads run under real-time scheduling. |
| `realtime_granted(pool)` | For each thread, whether the system granted the real-time request. |
| `realtime!(rt)`, `realtime!(nothing)`, `isrealtime()` | Real-time scheduling for the calling thread, on or off, and whether it has it. |
| `wait_on_address(p, expected; timeout, shared)` | Park until the word at `p` differs from `expected`, GC-safe. |
| `wake_address(p; all, shared)` | Wake threads parked on `p`. |
| `Parker()`, `park(p; timeout)`, `unpark(p)` | Park one thread until another wakes it; an early wakeup is kept. |
| `DeadlineLog()`, `begin_iteration`, `end_iteration!` | Record a loop's overruns and the GC time inside them, without allocating. |
| `overruns(log)`, `deadline_stats(log)` | The overruns kept, and a summary. |

## Performance

Measured on an Apple M3 Max with Julia 1.13.3.

**Start latency under load.** With `-t 4,1`, eight spinning tasks filled the four `:default`
threads while a probe submitted a trivial task every 25 ms and timed how long it took to start.
Median over three runs of 74 probes each:

| | median wait |
|---|---|
| `Threads.@spawn` | 1.5 to 1.65 s |
| `Threads.@spawn :interactive` | about 5 µs |
| `spawn(f, pool)` | 13 to 14 µs |

The `:interactive` thread had no other work during the test. The measurement is
`measure_isolation` in `notebooks/thread_pools_demo.jl`.

**Spawn cost.** With `-t 4`, spawning and fetching 100,000 trivial tasks, best of 5, on a 4-thread
pool (`julia -t 4 --project bench/spawn_overhead.jl`):

| | ns per task |
|---|---|
| `Threads.@spawn` | 452 |
| `spawn(f)` inside a pool task | 701 |
| `spawn(f)` inside `with_pool` | 705 |
| `spawn(f, pool)` from outside the pool | 987 |

## How it works

- **Threads.** Each pool thread is an OS thread that enters Julia through a `@cfunction`, which
  adopts it into the runtime. Adopted threads get thread ids after the built-in pools.
- **Thread cache.** Julia never reuses a thread id, so threads are never destroyed. `close`
  returns them to a process-wide cache, and new pools take from the cache before starting
  threads.
- **Scheduling.** Each thread runs a dispatcher as its root task. It takes a queued task only when
  its thread has nothing else runnable, pins the task to the thread, and yields to it. Julia's own
  scheduler then runs the task, including resuming it on that thread after it blocks.
- **Pool inheritance.** The current pool is a `ScopedValue`, so tasks created inside a pool
  task (by `spawn`, `@async`, or `Task`) see the same pool.
- **Runtime internals.** All uses of unexported runtime functions are in `src/runtime.jl`.

## Limitations

- **No migration.** A task stays on the thread that first ran it. Balancing happens only when a
  task starts, so tasks that block and later wake together on one thread can't spread to idle
  threads.
- **Base constructs don't know about these pools.** `Threads.@spawn` (including `:samepool`)
  and `Threads.@threads` inside a pool task use the `:default` pool. Use `spawn` instead.
  `@async` stays on the current pool thread.
- **Pool threads are `:foreign` to Base.** `Threads.threadpool()` reports `:foreign` on a pool
  thread, and `Threads.nthreads()` does not count pool threads.
- **Threads are never destroyed.** `Threads.maxthreadid()` grows to the largest number of pool
  threads held at once.
- **Blocking C calls hold the thread.** A `ccall` that blocks occupies its pool thread for the
  duration, as on any Julia thread. `wait_on_address` and `park` block the same way, but in a
  GC-safe call, so collections don't wait for them.
- **`close` waits for every task.** It does not cancel anything, and it throws if called from
  one of the pool's own tasks. A task that never yields keeps `close` from returning.
- **Runtime internals.** The package uses unexported runtime functions (`jl_set_task_tid`,
  `Base.workqueue_for`, the `Task.scope` field) that a Julia release can change.
- **Upstream change.** [JuliaLang/julia#62501](https://github.com/JuliaLang/julia/pull/62501)
  (open) would deny task switching on adopted threads unless they opt in. Pool threads call
  `jl_thread_allow_task_switching` when the runtime provides it.

See [`notes/landscape.md`](notes/landscape.md) for the survey of prior work behind this design.
