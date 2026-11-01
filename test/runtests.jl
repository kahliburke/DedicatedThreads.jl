using Test
using ImprovedJuliaThreadPools
using ImprovedJuliaThreadPools: owning_pool, cached_threads
using Base.ScopedValues: ScopedValue, @with
using Serialization

fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
pfib(n) = n < 15 ? fib(n) : (t = spawn(() -> pfib(n - 2)); pfib(n - 1) + fetch(t))

const TAG = ScopedValue(:unset)

builtin_threads() =Threads.nthreads(:interactive) + Threads.nthreads(:default)

@testset "ImprovedJuliaThreadPools" begin
    @testset "threads are created outside the built-in pools" begin
        ThreadPool(3; name = :basic) do pool
            tids = threadids(pool)
            @test length(unique(tids)) == 3
            @test all(>(builtin_threads()), tids)
            @test Threads.nthreads(pool) == 3
            @test all(t -> owning_pool(t) === pool, tids)
            @test isopen(pool)
            @test sprint(show, pool) == "ThreadPool(:basic, 3 threads, open, 0 queued)"
        end
    end

    @testset "tasks run on pool threads" begin
        ThreadPool(4) do pool
            tids = threadids(pool)
            ts = [spawn(Threads.threadid, pool) for _ in 1:1000]
            @test all(in(tids), fetch.(ts))
        end
    end

    @testset "results and exceptions" begin
        ThreadPool(2) do pool
            @test fetch(spawn(() -> 41 + 1, pool)) == 42
            t = spawn(() -> error("boom"), pool)
            @test_throws TaskFailedException fetch(t)
            # The pool keeps working after a task fails.
            @test fetch(spawn(() -> :ok, pool)) === :ok
        end
    end

    @testset "work spreads across all threads" begin
        # Each task spins until all have started, which only succeeds if they run in parallel
        # on distinct threads.
        n = 4
        ThreadPool(n) do pool
            started = Threads.Atomic{Int}(0)
            ts = map(1:n) do _
                spawn(pool) do
                    Threads.atomic_add!(started, 1)
                    deadline = time() + 10
                    while started[] < n && time() < deadline
                        GC.safepoint()
                    end
                    (Threads.threadid(), started[] == n)
                end
            end
            rs = fetch.(ts)
            @test all(last, rs)
            @test length(unique(first.(rs))) == n
        end
    end

    @testset "blocked tasks free their thread" begin
        ThreadPool(2) do pool
            gate = Threads.Event()
            m = 20
            waiting = Threads.Atomic{Int}(0)
            ts = map(1:m) do _
                spawn(pool) do
                    Threads.atomic_add!(waiting, 1)
                    wait(gate)
                    Threads.threadid()
                end
            end
            @test timedwait(() -> waiting[] == m, 10) === :ok
            notify(gate)
            @test all(in(threadids(pool)), fetch.(ts))
        end
    end

    @testset "queued tasks run while every thread stays busy" begin
        # Spinners keep each thread's local queue non-empty indefinitely (they yield between
        # bursts); a newly queued task must still get a turn.
        ThreadPool(2) do pool
            stop = Threads.Atomic{Bool}(false)
            spinners = map(1:4) do _
                spawn(pool) do
                    deadline = time() + 30
                    while !stop[] && time() < deadline
                        burst_end = time() + 0.01
                        while time() < burst_end
                            GC.safepoint()
                        end
                        yield()
                    end
                end
            end
            sleep(0.1)
            probe = spawn(() -> :ran, pool)
            @test timedwait(() -> istaskdone(probe), 5) === :ok
            @test !istaskdone(first(spinners))
            stop[] = true
            foreach(wait, spinners)
        end
    end

    @testset "tasks stay on their thread across blocking" begin
        ThreadPool(3) do pool
            ch = Channel{Int}(Inf)
            ts = map(1:50) do i
                spawn(pool) do
                    before = Threads.threadid()
                    sleep(0.002)
                    put!(ch, i)
                    yield()
                    before == Threads.threadid()
                end
            end
            @test all(fetch.(ts))
        end
    end

    @testset "children inherit the pool" begin
        ThreadPool(2; name = :outer) do pool
            tids = threadids(pool)
            r = fetch(spawn(pool) do
                child = spawn(() -> (Threads.threadid(), current_pool()))
                grandchild = spawn(() -> fetch(spawn(Threads.threadid)))
                async_child = @async Threads.threadid()
                (; pool = current_pool(), child = fetch(child), grandchild = fetch(grandchild),
                   async_child = fetch(async_child), me = Threads.threadid())
            end)
            @test r.pool === pool
            @test r.child[1] in tids
            @test r.child[2] === pool
            @test r.grandchild in tids
            @test r.async_child == r.me
        end
    end

    @testset "caller's scoped values reach pool tasks" begin
        ThreadPool(2) do pool
            @test fetch(spawn(() -> (TAG[], current_pool() === pool), pool)) == (:unset, true)
            @with TAG => :outer begin
                @test fetch(spawn(() -> (TAG[], current_pool() === pool), pool)) == (:outer, true)
                inner = fetch(spawn(pool) do
                    @with TAG => :inner fetch(spawn(() -> TAG[]))
                end)
                @test inner === :inner
            end
        end
    end

    @testset "spawn without a pool" begin
        @test current_pool() === nothing
        @test fetch(spawn(Threads.threadpool)) === :default
        ThreadPool(2) do pool
            with_pool(pool) do
                @test current_pool() === pool
                @test fetch(spawn(Threads.threadid)) in threadids(pool)
            end
            @test current_pool() === nothing
        end
    end

    @testset "with_pool(nothing) leaves the pool" begin
        ThreadPool(2) do pool
            r = fetch(spawn(pool) do
                with_pool(nothing) do
                    (current_pool(), Threads.threadpool(fetch(spawn(Threads.threadid))))
                end
            end)
            @test r == (nothing, :default)
            # The task itself still runs on the pool; only its default for `spawn` changed.
            @test fetch(spawn(() -> with_pool(Threads.threadid, nothing), pool)) in threadids(pool)
        end
    end

    @testset "pools nest" begin
        ThreadPool(2; name = :a) do a
            ThreadPool(2; name = :b) do b
                @test isempty(intersect(threadids(a), threadids(b)))
                r = fetch(spawn(a) do
                    fetch(spawn(b) do
                        (current_pool(), fetch(spawn(Threads.threadid)))
                    end)
                end)
                @test r[1] === b
                @test r[2] in threadids(b)
            end
        end
    end

    @testset "nested fan-out" begin
        ThreadPool(4) do pool
            @test fetch(spawn(() -> pfib(24), pool)) == fib(24)
        end
    end

    @testset "many tasks" begin
        ThreadPool(4) do pool
            n = 10_000
            ts = map(1:n) do i
                spawn(pool) do
                    isodd(i) && yield()
                    i % 97 == 0 && sleep(0.001)
                    i
                end
            end
            @test sum(fetch.(ts)) == n * (n + 1) ÷ 2
        end
    end

    @testset "GC under load" begin
        ThreadPool(4) do pool
            ts = map(1:16) do _
                spawn(pool) do
                    s = 0
                    for i in 1:200
                        v = [rand() for _ in 1:1000]
                        s += length(v)
                        i % 50 == 0 && GC.gc(false)
                    end
                    s
                end
            end
            @test all(==(200_000), fetch.(ts))
        end
    end

    @testset "close drains, rejects new work, and recycles threads" begin
        pool = ThreadPool(2)
        done = Threads.Atomic{Int}(0)
        for _ in 1:100
            spawn(pool) do
                sleep(0.001)
                Threads.atomic_add!(done, 1)
            end
        end
        close(pool)
        @test done[] == 100
        @test !isopen(pool)
        @test_throws InvalidStateException spawn(() -> 1, pool)
        close(pool)
        tids = threadids(pool)
        @test all(t -> owning_pool(t) === nothing, tids)
        @test cached_threads() >= 2
        maxtid = Threads.maxthreadid()
        ThreadPool(2) do reused
            @test sort(threadids(reused)) == sort(tids)
        end
        @test Threads.maxthreadid() == maxtid
    end

    @testset "concurrent close calls all wait" begin
        pool = ThreadPool(1)
        gate = Threads.Event()
        spawn(() -> wait(gate), pool)
        c1 = @async close(pool)
        c2 = @async close(pool)
        sleep(0.05)
        @test !istaskdone(c1) && !istaskdone(c2)
        notify(gate)
        @test timedwait(() -> istaskdone(c1) && istaskdone(c2), 10) === :ok
        @test !isopen(pool)
    end

    @testset "closing from inside the pool throws" begin
        ThreadPool(1) do pool
            t = spawn(() -> close(pool), pool)
            err = try
                fetch(t)
                nothing
            catch e
                e
            end
            @test err isa TaskFailedException
            @test err.task.exception isa ArgumentError
            @test isopen(pool)
        end
    end

    @testset "pools cannot be serialized" begin
        ThreadPool(1; name = :local_only) do pool
            @test_throws ArgumentError Serialization.serialize(IOBuffer(), pool)
            @test_throws ArgumentError Serialization.serialize(IOBuffer(), (; data = 1, pool))
        end
    end

    @testset "process exits with live pools" begin
        code = """
            using ImprovedJuliaThreadPools
            closed = ThreadPool(2)
            fetch(spawn(() -> 1, closed))
            close(closed)
            leaked = ThreadPool(2)
            fetch(spawn(() -> sleep(0.01), leaked))
            """
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
        p = run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        @test timedwait(() -> process_exited(p), 120) === :ok
        process_running(p) && kill(p)
        @test success(p)
    end
end
