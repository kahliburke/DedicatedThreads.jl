# Real-time pools, waiting on an address, and deadline logs.

# Inside a function, as a loop would record: at top level the log is a global and dispatch allocates.
function record_allocs(log)
    end_iteration!(log, begin_iteration(log), 0)
    @allocated end_iteration!(log, begin_iteration(log), 0)
end

@testset "real-time pools" begin
    rt = Realtime(period = 0.005)
    rt_tids = DedicatedPool(2; name = :rt, realtime = rt) do pool
        if Sys.isapple() || Sys.islinux()
            granted = realtime_granted(pool)
            # Linux grants SCHED_FIFO only with a real-time allowance; macOS always does.
            Sys.isapple() && @test all(granted)
            @test all(fetch.([spawn(isrealtime, pool) for _ in 1:20]) .== granted[1])
        end
        threadids(pool)
    end
    @test !isrealtime()                                    # the caller's thread is untouched
    # The same threads, back from the cache for a pool without a request, run ordinarily.
    DedicatedPool(2; name = :plain) do pool
        @test sort(threadids(pool)) == sort(rt_tids)
        @test !any(realtime_granted(pool))
        @test !any(fetch.([spawn(isrealtime, pool) for _ in 1:20]))
    end
    @test_throws ArgumentError Realtime(period = 0.001, compute = 0.002)
    @test_throws ArgumentError Realtime(period = 0.001, priority = 0)
end

@testset "waiting on an address" begin
    v = zeros(UInt32, 1)
    GC.@preserve v begin
        p = pointer(v)
        @test wait_on_address(p, UInt32(1)) === :changed          # already different
        t0 = time_ns()
        @test wait_on_address(p, UInt32(0); timeout = 0.05) === :timeout
        @test time_ns() - t0 >= 40_000_000
        DedicatedPool(1) do pool
            t = spawn(() -> wait_on_address(p, UInt32(0); timeout = 10), pool)
            sleep(0.1)
            unsafe_store!(p, UInt32(1), :release); wake_address(p)
            @test timedwait(() -> istaskdone(t), 5) === :ok
            @test fetch(t) === :changed
        end
    end
end

@testset "a parked thread doesn't hold up a collection" begin
    v = zeros(UInt32, 1)
    GC.@preserve v begin
        p = pointer(v)
        DedicatedPool(1) do pool
            t = spawn(() -> wait_on_address(p, UInt32(0); timeout = 30), pool)
            sleep(0.1)
            @test !istaskdone(t)
            # A thread blocked outside a GC-safe region would hold this collection for 30 s.
            @test (@elapsed GC.gc()) < 5
            unsafe_store!(p, UInt32(1), :release); wake_address(p)
            @test fetch(t) === :changed
        end
    end
end

@testset "waiting across processes" begin
    if Sys.isapple() || Sys.islinux()
        name = "/dt-test-$(getpid())"
        fd = @ccall shm_open(name::Cstring, (Sys.isapple() ? 0x0202 : 0x0042)::Cint; 0o600::Cuint)::Cint   # O_RDWR | O_CREAT
        @test fd >= 0
        @ccall ftruncate(fd::Cint, 4096::Int64)::Cint
        p = @ccall mmap(C_NULL::Ptr{Cvoid}, 4096::Csize_t, 3::Cint, 1::Cint, fd::Cint, 0::Int64)::Ptr{UInt32}
        @ccall close(fd::Cint)::Cint
        unsafe_store!(p, UInt32(0))
        # The child parks on the shared word and reports what woke it.
        code = """
            using DedicatedThreads
            fd = @ccall shm_open("$name"::Cstring, 0x0002::Cint; 0::Cuint)::Cint
            p = @ccall mmap(C_NULL::Ptr{Cvoid}, 4096::Csize_t, 3::Cint, 1::Cint, fd::Cint, 0::Int64)::Ptr{UInt32}
            unsafe_store!(p + 4, UInt32(1), :release)                     # ready
            exit(wait_on_address(p, UInt32(0); timeout = 60, shared = true) === :changed ? 0 : 1)
            """
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
        child = run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        try
            @test timedwait(() -> unsafe_load(p + 4, :acquire) == 1 || process_exited(child), 120) === :ok
            sleep(0.2)                                                    # let it park
            @test process_running(child)
            unsafe_store!(p, UInt32(1), :release); wake_address(p; shared = true)
            @test timedwait(() -> process_exited(child), 10) === :ok
            @test success(child)
        finally
            process_running(child) && kill(child)
            @ccall munmap(p::Ptr{UInt32}, 4096::Csize_t)::Cint
            @ccall shm_unlink(name::Cstring)::Cint
        end
    end
end

@testset "parkers keep an early wakeup" begin
    pk = Parker()
    unpark(pk)
    @test park(pk; timeout = 0)                            # the wakeup came first
    @test !park(pk; timeout = 0.02)                        # and was used up
    DedicatedPool(1) do pool
        t = spawn(() -> park(pk; timeout = 10), pool)
        sleep(0.05)
        unpark(pk)
        @test fetch(t)
    end
end

@testset "deadline logs" begin
    log = DeadlineLog(capacity = 4)
    for _ in 1:3
        @test !end_iteration!(log, begin_iteration(log), 1_000_000_000)
    end
    tk = begin_iteration(log); sleep(0.01)
    @test end_iteration!(log, tk, 1_000_000)
    tk = begin_iteration(log); GC.gc()
    @test end_iteration!(log, tk, 1)
    os = overruns(log)
    @test length(os) == 2
    @test os[1].elapsed_ns >= 10_000_000 && os[1].budget_ns == 1_000_000
    @test os[2].gc_ns > 0                                  # the collection is accounted to it
    s = deadline_stats(log)
    @test s.iterations == 5 && s.overruns == 2 && s.with_gc >= 1 && s.worst_ms >= 10
    for _ in 1:10
        end_iteration!(log, begin_iteration(log), 0)
    end
    @test length(overruns(log)) == 4                       # the newest, within capacity
    @test deadline_stats(log).overruns == 12
    @test record_allocs(log) == 0
end
