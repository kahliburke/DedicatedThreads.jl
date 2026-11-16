# Waiting for a word of memory to change, parked in the OS rather than spinning: macOS's
# os_sync_wait_on_address, Linux's futex. The wait is a GC-safe foreign call, so a garbage
# collection proceeds without the parked thread, which matters for threads that wait most of the
# time. With `shared`, the word may live in memory mapped by several processes.

const HAS_OS_SYNC = Ref(false)

function detect_address_wait()
    HAS_OS_SYNC[] = Sys.isapple() && try
        cglobal(:os_sync_wait_on_address_with_timeout) != C_NULL
    catch
        false
    end
    return nothing
end

const ETIMEDOUT = Sys.isapple() ? 60 : 110
const OS_CLOCK_MACH_ABSOLUTE_TIME = UInt32(32)
const FUTEX_WAIT, FUTEX_WAKE, FUTEX_PRIVATE_FLAG = Cint(0), Cint(1), Cint(128)
const SYS_FUTEX = Sys.ARCH === :x86_64 ? Clong(202) : Clong(98)        # aarch64

"""
    wait_on_address(p::Ptr{UInt32}, expected::UInt32; timeout = Inf, shared = false) -> Symbol

Park the calling thread while the word at `p` holds `expected`. Returns `:changed` when the word
differs (on entry, or after [`wake_address`](@ref)), or `:timeout` after `timeout` seconds. Wakeups
can be spurious, so callers re-check the word. The caller keeps the memory alive.

The thread is parked in a GC-safe call: a garbage collection does not wait for it.
"""
function wait_on_address(p::Ptr{UInt32}, expected::UInt32; timeout::Real = Inf, shared::Bool = false)
    unsafe_load(p, :acquire) == expected || return :changed
    tns = isfinite(timeout) ? max(round(UInt64, timeout * 1e9), UInt64(1)) : UInt64(0)
    if HAS_OS_SYNC[]
        flags = UInt32(shared ? 1 : 0)
        r = isfinite(timeout) ?
            @ccall(gc_safe = true, os_sync_wait_on_address_with_timeout(p::Ptr{UInt32}, UInt64(expected)::UInt64, 4::Csize_t,
                   flags::UInt32, OS_CLOCK_MACH_ABSOLUTE_TIME::UInt32, tns::UInt64)::Cint) :
            @ccall(gc_safe = true, os_sync_wait_on_address(p::Ptr{UInt32}, UInt64(expected)::UInt64, 4::Csize_t, flags::UInt32)::Cint)
        return r < 0 && Libc.errno() == ETIMEDOUT ? :timeout : :changed
    elseif Sys.islinux()
        op = shared ? FUTEX_WAIT : FUTEX_WAIT | FUTEX_PRIVATE_FLAG
        ts = Ref((Int64(tns ÷ 1_000_000_000), Int64(tns % 1_000_000_000)))
        r = isfinite(timeout) ?
            @ccall(gc_safe = true, syscall(SYS_FUTEX::Clong; p::Ptr{UInt32}, op::Cint, expected::UInt32, ts::Ref{Tuple{Int64,Int64}}, C_NULL::Ptr{Cvoid}, 0::Cint)::Clong) :
            @ccall(gc_safe = true, syscall(SYS_FUTEX::Clong; p::Ptr{UInt32}, op::Cint, expected::UInt32, C_NULL::Ptr{Cvoid}, C_NULL::Ptr{Cvoid}, 0::Cint)::Clong)
        return r < 0 && Libc.errno() == ETIMEDOUT ? :timeout : :changed
    end
    # No address wait on this platform: nap and look again.
    deadline = isfinite(timeout) ? time_ns() + tns : typemax(UInt64)
    while unsafe_load(p, :acquire) == expected
        time_ns() >= deadline && return :timeout
        @ccall gc_safe = true usleep(100::Cuint)::Cint
    end
    return :changed
end

"""
    wake_address(p::Ptr{UInt32}; all = true, shared = false)

Wake threads parked in [`wait_on_address`](@ref) on `p`: all of them, or one. Store the new
value before waking; `shared` must match the waiters'.
"""
function wake_address(p::Ptr{UInt32}; all::Bool = true, shared::Bool = false)
    if HAS_OS_SYNC[]
        flags = UInt32(shared ? 1 : 0)
        all ? ccall(:os_sync_wake_by_address_all, Cint, (Ptr{UInt32}, Csize_t, UInt32), p, 4, flags) :
              ccall(:os_sync_wake_by_address_any, Cint, (Ptr{UInt32}, Csize_t, UInt32), p, 4, flags)
    elseif Sys.islinux()
        op = shared ? FUTEX_WAKE : FUTEX_WAKE | FUTEX_PRIVATE_FLAG
        @ccall syscall(SYS_FUTEX::Clong; p::Ptr{UInt32}, op::Cint, (all ? typemax(Cint) : Cint(1))::Cint)::Clong
    end
    return nothing
end

"""
    Parker()

A wakeup for one waiting thread, parked by [`park`](@ref) in the OS (GC-safe, see
[`wait_on_address`](@ref)) and released by [`unpark`](@ref). An `unpark` that lands before the
`park` is kept, so none is lost.
"""
mutable struct Parker
    @atomic word::UInt32
end
Parker() = Parker(0)

word_ptr(p::Parker) = Ptr{UInt32}(pointer_from_objref(p))     # `word` is the first field

"""
    park(p::Parker; timeout = Inf) -> Bool

Wait until `p` is unparked, consuming the wakeup; `false` if `timeout` seconds passed first.
"""
function park(p::Parker; timeout::Real = Inf)
    deadline = isfinite(timeout) ? time_ns() + round(UInt64, timeout * 1e9) : typemax(UInt64)
    GC.@preserve p while true
        (@atomicswap p.word = UInt32(0)) == 1 && return true
        left = deadline == typemax(UInt64) ? Inf : (Int64(deadline) - Int64(time_ns())) / 1e9
        left <= 0 && return false
        wait_on_address(word_ptr(p), UInt32(0); timeout = left)
    end
end

"""
    unpark(p::Parker)

Wake the thread parked on `p`, or let its next [`park`](@ref) return at once.
"""
function unpark(p::Parker)
    GC.@preserve p begin
        @atomic p.word = UInt32(1)
        wake_address(word_ptr(p); all = false)
    end
    return nothing
end
