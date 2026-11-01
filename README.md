# ImprovedJuliaThreadPools.jl

[![CI](https://github.com/kahliburke/ImprovedJuliaThreadPools.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/kahliburke/ImprovedJuliaThreadPools.jl/actions/workflows/CI.yml)

User-defined thread pools for Julia, created at runtime.

Julia ships two fixed pools, `:default` and `:interactive`, sized at startup with `-t`. This
package adds pools of dedicated OS threads that you create, size, and close from Julia code, on
a stock Julia runtime.

```julia
using ImprovedJuliaThreadPools

ThreadPool(4; name = :io) do pool
    t = spawn(pool) do
        # Runs on one of the pool's 4 threads. Blocking (IO, locks, sleep) frees the thread
        # for other pool tasks.
        sum(fetch.([spawn(() -> i^2) for i in 1:10]))   # children inherit the pool
    end
    fetch(t)
end
```

## API

| | |
|---|---|
| `ThreadPool(n; name)` | Create a pool of `n` threads. The do-block form closes it afterwards. |
| `spawn(f, pool)` | Run `f()` on the pool; returns a `Task`. |
| `spawn(f)` | Run `f()` on the current pool, or on Julia's `:default` pool if there is none. |
| `with_pool(f, pool)` | Make `pool` current for `f()` and every task it creates. |
| `with_pool(f, nothing)` | Run `f()` outside any pool, so its `spawn` calls go to `:default`; for hosting other code on a pool. |
| `current_pool()` | The pool `spawn(f)` submits to, or `nothing`. |
| `close(pool)` | Stop accepting work, wait for all spawned tasks, release the threads. |
| `threadids(pool)`, `Threads.nthreads(pool)` | The pool's Julia thread ids and size. |

Library code that calls `spawn(f)` without naming a pool runs wherever its caller chose: inside a
pool task or `with_pool` block it uses that pool, otherwise the default pool.

## How it works

- **Threads.** Each pool thread is a raw OS thread entering Julia through a `@cfunction`, which
  adopts it into the runtime. Adopted threads get thread ids after the built-in pools (they report
  `Threads.threadpool() == :foreign`).
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
- **Blocking C calls hold the thread.** A `ccall` that blocks occupies its pool thread for the
  duration, as on any Julia thread.
- **`close` waits for every task.** It does not cancel anything, and it throws if called from
  one of the pool's own tasks. A task that never yields keeps `close` from returning.
- **Upstream change.** JuliaLang/julia#62501 (open) would deny task switching on adopted threads
  unless they opt in. Workers call `jl_thread_allow_task_switching` when the runtime provides it.

See `notes/landscape.md` for the survey behind this design.
