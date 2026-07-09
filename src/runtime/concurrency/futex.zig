//! OS futex wait/wake over a 32-bit eventcount word — the concurrency
//! kernel's shared low-level parking primitive.
//!
//! Extracted (P4-J3) from the scheduler's idle-parking implementation so the
//! two thread-pool families that must block an OS thread until signalled — the
//! M:N core schedulers (`scheduler.zig`, idle parking) and the blocking /
//! dirty-scheduler pool (`blocking_pool.zig`, worker parking) — share ONE
//! OS-portable futex surface rather than duplicating the Darwin/Linux syscall
//! wrappers. Leaf module: it imports only `std`/`builtin`, so both callers may
//! depend on it with no import cycle.
//!
//! ## Semantics
//!
//! `waitBounded(word, expected, timeout)` blocks the calling thread while
//! `word == expected`, returning when the value changes, a waker fires, the
//! timeout elapses, or spuriously — the caller ALWAYS re-checks its condition
//! in a loop (an eventcount protocol: the waiter samples an epoch, re-checks
//! its work sources, then waits on that epoch; a producer bumps the epoch and
//! wakes, so a wake that races the wait is never lost). Waits are always
//! time-bounded (defense-in-depth) and may return early.
//!
//! `wakeOne(word)` wakes at most one thread parked on `word`. A wake with no
//! waiter is a cheap no-op (the desired behaviour — the epoch bump the caller
//! pairs with it already published the work).
//!
//! ## OS mapping (module doc, "Darwin futex mapping")
//!
//! Darwin: `os_sync_*` (macOS ≥ 14.4 minimum-target) or `__ulock_*` (the
//! fork's own `Io.Threaded` primitive pair), comptime-gated on the minimum
//! targeted OS version exactly as the fork's `Io.Threaded` gates its own
//! `__ulock_wait2`. Linux: `futex(2)`. Other OSes are a compile error until
//! their Phase 4/7 port lands — the same posture the scheduler has always had.

const std = @import("std");
const builtin = @import("builtin");

/// Block the calling thread while `word == expected`, for at most
/// `timeout_nanoseconds`. Returns on a value change, a `wakeOne`, the timeout,
/// or spuriously; the caller re-checks its condition. See the module doc.
pub fn waitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
    switch (comptime builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => {
            darwinWaitBounded(word, expected, timeout_nanoseconds);
        },
        .linux => linuxWaitBounded(word, expected, timeout_nanoseconds),
        else => @compileError(
            "concurrency futex parking is not implemented for this OS (Phase 4/7 ports)",
        ),
    }
}

/// Wake at most one thread parked on `word`. A wake with no waiter is a no-op.
pub fn wakeOne(word: *std.atomic.Value(u32)) void {
    switch (comptime builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => darwinWakeOne(word),
        .linux => linuxWakeOne(word),
        else => @compileError(
            "concurrency futex parking is not implemented for this OS (Phase 4/7 ports)",
        ),
    }
}

// -- Darwin -------------------------------------------------------------------

/// Whether the minimum targeted Darwin version has the public
/// `os_sync_wait_on_address` family (macOS 14.4). Gated at comptime on
/// `builtin.os.version_range` exactly as the fork's `Io.Threaded` gates
/// `__ulock_wait2` (macOS 11).
const darwin_minimum_target_has_os_sync = darwin_gate: {
    if (!builtin.os.tag.isDarwin()) break :darwin_gate false;
    const minimum = builtin.os.version_range.semver.min;
    break :darwin_gate minimum.order(.{ .major = 14, .minor = 4, .patch = 0 }) != .lt;
};

/// See the fork's `Io/Threaded.zig` `darwin_supports_ulock_wait2`.
const darwin_minimum_target_has_ulock_wait2 = darwin_gate: {
    if (!builtin.os.tag.isDarwin()) break :darwin_gate false;
    break :darwin_gate builtin.os.version_range.semver.min.major >= 11;
};

/// `OS_SYNC_WAIT_ON_ADDRESS_NONE` / `OS_SYNC_WAKE_BY_ADDRESS_NONE`
/// from `<os/os_sync_wait_on_address.h>`.
const os_sync_flags_none: u32 = 0;
/// `OS_CLOCK_MACH_ABSOLUTE_TIME` from `<os/clock.h>` — the only clock
/// id the os_sync timeout API accepts as of macOS 14.4.
const os_clock_mach_absolute_time: u32 = 32;

extern "c" fn os_sync_wait_on_address_with_timeout(
    addr: *anyopaque,
    value: u64,
    size: usize,
    flags: u32,
    clockid: u32,
    timeout_ns: u64,
) c_int;
extern "c" fn os_sync_wake_by_address_any(addr: *anyopaque, size: usize, flags: u32) c_int;

const darwin_ulock_flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };

fn darwinWaitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
    // Timeout 0 means "infinite" to both APIs; the caller always
    // bounds the wait, and a zero bound degenerates to a re-check.
    const bounded_timeout = @max(timeout_nanoseconds, 1);
    if (comptime darwin_minimum_target_has_os_sync) {
        const return_code = os_sync_wait_on_address_with_timeout(
            &word.raw,
            expected,
            @sizeOf(u32),
            os_sync_flags_none,
            os_clock_mach_absolute_time,
            bounded_timeout,
        );
        if (return_code >= 0) return;
        switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
            // Spurious return, paged-out word, or timeout: the caller
            // re-checks its condition either way.
            .INTR, .FAULT, .TIMEDOUT => {},
            else => unreachable, // misuse of the futex word — kernel bug
        }
        return;
    }
    const status = if (comptime darwin_minimum_target_has_ulock_wait2)
        std.c.__ulock_wait2(darwin_ulock_flags, &word.raw, expected, bounded_timeout, 0)
    else
        std.c.__ulock_wait(
            darwin_ulock_flags,
            &word.raw,
            expected,
            @max(std.math.lossyCast(u32, bounded_timeout / std.time.ns_per_us), 1),
        );
    if (status >= 0) return;
    switch (@as(std.c.E, @enumFromInt(-status))) {
        .INTR, .FAULT, .TIMEDOUT => {},
        else => unreachable, // misuse of the futex word — kernel bug
    }
}

fn darwinWakeOne(word: *std.atomic.Value(u32)) void {
    if (comptime darwin_minimum_target_has_os_sync) {
        const return_code = os_sync_wake_by_address_any(&word.raw, @sizeOf(u32), os_sync_flags_none);
        if (return_code >= 0) return;
        switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
            .NOENT => {}, // nobody parked — the desired no-op
            else => unreachable,
        }
        return;
    }
    while (true) {
        const status = std.c.__ulock_wake(darwin_ulock_flags, &word.raw, 0);
        if (status >= 0) return;
        switch (@as(std.c.E, @enumFromInt(-status))) {
            .INTR, .CANCELED => continue,
            .NOENT => return, // nobody parked — the desired no-op
            else => unreachable,
        }
    }
}

// -- Linux --------------------------------------------------------------------

fn linuxWaitBounded(word: *std.atomic.Value(u32), expected: u32, timeout_nanoseconds: u64) void {
    const linux = std.os.linux;
    const timeout = linux.timespec{
        .sec = @intCast(timeout_nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(timeout_nanoseconds % std.time.ns_per_s),
    };
    const return_code = linux.futex_4arg(
        &word.raw,
        .{ .cmd = .WAIT, .private = true },
        expected,
        &timeout,
    );
    switch (linux.errno(return_code)) {
        // Woken, raced (word already changed), interrupted, or timed
        // out: the caller re-checks its condition either way.
        .SUCCESS, .AGAIN, .INTR, .TIMEDOUT => {},
        else => unreachable, // misuse of the futex word — kernel bug
    }
}

fn linuxWakeOne(word: *std.atomic.Value(u32)) void {
    const linux = std.os.linux;
    _ = linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, 1);
}
