# User-defined thread pools in Julia: landscape survey

Surveyed 2026-11-01 against Julia v1.13.3 and master (`d202a0a1fd`).

## Why there are only two pools

### History

- **#42302** (jpsamaroo → kpamnany, merged 2022-04, Julia 1.9) introduced threadpools. Early
  versions allowed creating pools at runtime, motivated by latency/IO (GPU hostcalls, GUI event
  loops) rather than compute. https://github.com/JuliaLang/julia/pull/42302
  - Main objection was composability: per-library pools oversubscribe cores and break nested
    parallelism (tkf, DilumAluthge, chriselrod, vchuravy, KristofferC).
  - `nthreads()` being constant was treated as a hard requirement (per-thread buffers allocated in
    `__init__`, e.g. LinearAlgebra).
  - 2022-01-05 multithreading call: pools statically sized at startup, not created/resized at
    runtime. A `Threads.Control` design (application maps named pools, libraries `assign!` tasks
    to names, fallback to default) was sketched but never implemented.
  - vtjnash argued `nthreads()` should become dynamic and pools a separate grouping; the PR was
    instead cut down to the fixed `:default`/`:interactive` pair.
- **#45447** (support foreign threads + adding threads at runtime) broke PkgEval (FFTW, HTTP,
  Parsers) by removing `nthreads`; reduced to **#46609** (`jl_adopt_thread`, `maxthreadid()`, 1.9).
- **#50912** put adopted threads in the `:foreign` pool. vchuravy: "long-term we may want to make
  pools resizable, but that's a bigger more complicated change."
- **#53915** (2024, open, no maintainer response): startup-named custom pools,
  `--threadpools=interactive,default,foo -t1,2,3`.
- **#43649** (tkf, closed): multi-scheduler RFC. Schedulers written in Julia over a minimal C
  worker-thread API; `Task` points to its scheduler; only the application configures schedulers.
- **#57109** `@spawn :samepool` (1.12); **#57087** one interactive thread by default (1.12).
- **#59936** (open): manually non-sticky tasks stay in their parent's pool; no public API to bind a
  task to a pool outside `@spawn`. **#53056** (open): `schedule(t; threadpool=…)`.
- **#53422**: dedicated IO thread capability — creates a thread at runtime via `uv_thread_create`
  + `@cfunction` adoption (now `Base.Experimental.make_io_thread`).
- **#62501** (Keno, open, 2026-07): deny task switching on adopted threads by default; donated
  threads opt in via `jl_allow_adopted_task_switching`. **Directly affects the adopted-thread
  approach below.**
- **#56475** (gbaraldi, open): split `Base.Scheduler` interface (`enqueue!`, `dequeue!`,
  `checktaskempty`) from partr. **#62285** (open): work-stealing backend with per-pool injection
  queues, selected at build time.

Blockers maintainers have named: constant `nthreads()`/`threadid()` assumptions in the ecosystem;
composability/oversubscription; no fairness or preemption (co-opted threads may never return); GC
assumptions about a startup-fixed thread set; pool/stickiness semantics hidden behind `@spawn`.

### Runtime structure (v1.13.3, read from source)

- **Pool membership is derived from tid ranges.** `jl_threadpoolid` (`src/threading.c`) walks
  `jl_n_threads_per_pool` over a contiguous layout: interactive, default, GC threads, then
  adopted threads (pool -1). A pool cannot grow without renumbering, and a new pool has no range.
- `jl_tls_states_t.threadpoolid` exists but is never assigned.
- `jl_task_t.threadpoolid` is inherited from the parent at task creation (`src/task.c`);
  `@spawn` overrides it to `:default` unless `:interactive`/`:samepool` is given.
- **Scheduler queues are Julia code** (`base/partr.jl`): `heaps` is a per-pool vector of task
  heaps, already resized on demand by `multiq_size`. Sticky tasks use per-thread
  `Workqueues` (`OncePerThread`, grows with `maxthreadid`).
- The C side (`jl_task_get_next`, `src/scheduler.c`) handles spin/sleep/wake and calls back into
  Julia (`trypoptask`, `checktaskempty`).
- `jl_init_threadtls(-1)` appends a thread and reallocates `jl_all_tls_states`; adoption already
  uses this, so the thread table grows at runtime.
- Sites assuming contiguous pool tid ranges: `threadpooltids`, `threading_run` (`:static` offset),
  `enq_work` (single-thread pool routing), `jl_threadpoolid`, `jl_wakeup_threadpool`,
  `jl_start_threads` (affinity), `InteractiveUtils.versioninfo`, `jl_uv.c` (handoff check).
- GC worker threads (`--gcthreads`) occupy tids after the default pool and report as `:foreign`.

## Experiment: runtime-created threads as task hosts

`experiments/adopted_thread_probe.jl`. A raw OS thread enters Julia via `@cfunction` (auto-adopted),
its root task parks in `wait()`, and tasks are pinned to it with `sticky = true` +
`jl_set_task_tid`.

| Probe | Result |
|---|---|
| tid / pool | new tid beyond startup `maxthreadid`, `:foreign` |
| `sleep` in task | resumes on the adopted thread |
| `@async` child | runs on the adopted thread |
| `@spawn` / `@spawn :samepool` child | goes to `:default` |
| `GC.gc()` | works |

Non-sticky tasks cannot target the adopted thread: `enq_work` routes `:foreign`-pool tasks to the
first default thread, and `multiq_deletemin` returns nothing on foreign threads. Pinning is the
only route without Base changes. Calling closures newer than the `@cfunction` world requires
`invokelatest`.

## Ecosystem

All of these partition the startup threads with sticky pinning; none adds threads, and isolation
is advisory (partr can still place unrelated tasks on "reserved" threads).

- ThreadPools.jl — `@bthreads`, `@qthreads`, `@tspawnat`. https://github.com/tro3/ThreadPools.jl
- StableTasks.jl — `@spawnat tid`, type-stable results. https://github.com/JuliaFolds2/StableTasks.jl
- OhMyThreads.jl — schedulers + chunking; `threadpool` limited to `:default`/`:interactive`.
  Issue #75 asks for real pools. https://github.com/JuliaFolds2/OhMyThreads.jl
- Polyester.jl / ThreadingUtilities.jl — one pinned spinning task per thread; poor nesting with
  `@threads`. https://github.com/JuliaSIMD/Polyester.jl
- ThreadPinning.jl — OS affinity; orthogonal, complements pools.
  https://github.com/carstenbauer/ThreadPinning.jl
- Dagger.jl — `ThreadProc` processors, scopes; source has `# TODO: ThreadGroupProc?`.
- ConcurrentUtilities.jl — `@samethreadpool_spawn` (upstreamed as `:samepool`), pinned worker
  pool over `Channel{Task}`. https://github.com/JuliaServices/ConcurrentUtilities.jl
- TaskGroups.jl — bounded worker pools for fairness/ordering, not isolation.
  https://github.com/kpamnany/TaskGroups.jl
- Actors.jl — `spawn(f; thrd=n)`.

### Prior art: threads created at runtime

Found via GitHub code search for `uv_thread_create` / `jl_adopt_thread` / `make_io_thread` in
Julia code (default branches only, so not exhaustive). All are single-purpose; none hosts general
Julia tasks with scheduling.

- `Base.Experimental.make_io_thread` (1.12+) — one adopted thread that takes over the libuv loop
  (`jl_set_io_loop_tid`) and parks in `wait()`.
- GPUToolbox.jl `src/synchronization.jl` — bounded pool (4 + overflow) of adopted threads for
  blocking GPU driver waits. Lazily created, LIFO idle reuse, one request per worker, results via
  `invokelatest`, finalizers disabled on worker threads (`jl_gc_disable_finalizers_internal`)
  because they may block, uninterruptible handoff. Workers block in `Base.wait(::Event)`, so they
  task-switch on adopted threads and are also affected by #62501.
- Reseau.jl (JuliaServices) — IO poller threads via `uv_thread_create`.
- Nitro.jl — calls `make_io_thread` to move the event loop off thread 1.
- `Base.@threadcall` — runs C functions on libuv's threadpool; cannot run Julia code.

## Other languages

- **Rust rayon**: `ThreadPoolBuilder` + `pool.install(..)`; nested parallelism inherits the
  current pool via thread-local registry.
- **Rust tokio**: multiple runtimes; tasks bound to the spawning runtime (`Handle::current()`);
  separate elastic blocking pool.
- **Java**: `ForkJoinPool`; `ManagedBlocker` compensation; Loom custom virtual-thread schedulers
  are prototype-only and deliberately not inherited.
  https://github.com/openjdk/loom/blob/fibers/loom-docs/CustomSchedulers.md
- **.NET**: `TaskScheduler`; ambient `TaskScheduler.Current` inherited by children (a known
  pitfall); `ConcurrentExclusiveSchedulerPair` for limits.
- **Kotlin**: `Dispatchers.Default`/`IO` share threads; `limitedParallelism(n)` creates a
  concurrency-limited view without new threads; dispatcher inherited via `CoroutineContext`.
- **Swift SE-0417**: task executor *preference*, inherited by structured children but not
  unstructured `Task {}`, never overrides actor isolation.
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md
- **Go**: single scheduler, no pools; a goroutine blocked in a syscall releases its P so
  parallelism is preserved; `GOMAXPROCS` updates at runtime since 1.25.
- **OCaml 5**: domainslib explicit pool values; Picos as a scheduler-agnostic interface.
  https://github.com/ocaml-multicore/picos
- **GHC**: `setNumCapabilities` at runtime; `forkOn`; safe FFI calls release the capability.
- **C++26 `std::execution`**: schedulers as values propagated through the receiver environment;
  `parallel_scheduler` with a link-time replaceable backend (P2079).

Recurring patterns: an ambient pool inherited by children; blocking handled by elastic pools or
compensation; a shared global pool with a replaceable backend to avoid fragmenting libraries;
runtime resizing is normal elsewhere.

## Paths

- **A. Package-only (chosen for now).** Pools of adopted OS threads; dispatch by pinning; current
  pool carried in a `ScopedValue` so nested spawns stay in the pool. Limits: no migration after
  first run, balancing only at dispatch, `@spawn`/`@threads`/`threadpool()` unaware of pools,
  #62501 would require the opt-in call.
- **B. Runtime patch.** Store pool id on ptls, dynamic pool table, `jl_threadpool_create` /
  add-threads via the adoption path, `ThreadPool` objects in Base, inherit-by-default `@spawn`.
  Aligns with #56475/#62285 (scheduler backend per pool).
- **C. Composability model.** Application owns pools; libraries express a preference; children
  inherit; pools can be concurrency-limited views of other pools.

Plan: build A as an API prototype whose interface would carry over to B.
