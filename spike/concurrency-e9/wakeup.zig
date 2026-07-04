//! E9 spike benchmark (concurrency campaign, job S0.3).
//!
//! THROWAWAY SPIKE CODE — see README.md. Measures cross-thread wakeup
//! latency on Darwin — the cost the bespoke Zap scheduler pays to wake a
//! parked scheduler thread — one mechanism at a time:
//!
//!   spin     userspace spin handoff (atomic generation counter, both
//!            threads busy) — the no-syscall floor for an awake scheduler
//!   ulock    __ulock_wait2/__ulock_wake COMPARE_AND_WAIT via std.c — the
//!            exact syscall pair the fork's Io.Threaded futexWait/futexWake
//!            uses on Darwin (the fork has no std.Thread.Futex)
//!   os-sync  os_sync_wait_on_address_with_timeout /
//!            os_sync_wake_by_address_any — Apple's public futex API
//!            (macOS 14.4+), declared extern here
//!   kqueue   EVFILT_USER: kevent NOTE_TRIGGER -> kevent wait return
//!   gcd-sem  dispatch_semaphore_signal -> dispatch_semaphore_wait return
//!
//! Protocol per iteration: the main thread records t0, signals the worker's
//! channel, then parks on its own channel; the worker (parked on its
//! channel) wakes, records t1, and echoes back. Only the main -> worker
//! direction is timed: delta = t1 - t0, from wake-request to
//! woken-thread-running, both timestamps on the same CLOCK_UPTIME_RAW
//! clock. Between iterations the main thread busy-waits `delay_ns`
//! (default 20 us) so the worker is reliably parked again before the next
//! wake — without it, wakes race with the worker still draining the
//! previous iteration and measure the no-park fast path instead.
//!
//! Build (asdf zig 0.16.0 binary against the fork's std):
//!   zig build-exe --zig-lib-dir $HOME/projects/zig/lib -OReleaseFast wakeup.zig
//! Run (one measurement at a time):
//!   ./wakeup <spin|ulock|os-sync|kqueue|gcd-sem> [ops] [reps] [warmup] [delay_ns]

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!builtin.os.tag.isDarwin()) @compileError("E9 wakeup benchmark is Darwin-specific");
}

const default_wakeups = 100_000;
const default_repetitions = 5;
/// Post-echo busy-wait on the main thread so the worker is parked again
/// before the next timed wake (see the protocol note above).
const default_repark_delay_ns = 20_000;
/// Every blocking wait is bounded; a hit means a lost wakeup — a finding to
/// report, never to hack around.
const wait_timeout_ns: u64 = 5 * std.time.ns_per_s;

const Mechanism = enum { spin, ulock, @"os-sync", kqueue, @"gcd-sem" };

/// Io-independent monotonic nanosecond clock (CLOCK_UPTIME_RAW, i.e.
/// mach_absolute_time), valid for same-clock deltas across threads. On
/// Apple Silicon its granularity is ~41.7 ns (24 MHz counter).
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// --- os_sync_* (public Darwin futex API, macOS 14.4+; not yet in std.c) ---

/// OS_SYNC_WAIT_ON_ADDRESS_NONE / OS_SYNC_WAKE_BY_ADDRESS_NONE from
/// <os/os_sync_wait_on_address.h>.
const os_sync_flags_none: u32 = 0;
/// OS_CLOCK_MACH_ABSOLUTE_TIME from <os/clock.h> — the only clock id the
/// os_sync timeout API accepts as of macOS 14.4.
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

fn errnoValue() std.c.E {
    return @enumFromInt(std.c._errno().*);
}

// --- One-direction wake channels, one per mechanism ---
// Every channel exposes `init() !Channel`, `signal(target)` and
// `wait(target)` where `target` is a monotonically increasing iteration
// generation; the kqueue and gcd-sem channels carry no payload and ignore
// it (their kernel objects latch the wake themselves).

const SpinChannel = struct {
    generation: std.atomic.Value(u64) = .init(0),

    fn init() !SpinChannel {
        return .{};
    }

    fn signal(channel: *SpinChannel, target: u64) void {
        channel.generation.store(target, .release);
    }

    fn wait(channel: *SpinChannel, target: u64) void {
        var spin_count: usize = 0;
        while (channel.generation.load(.acquire) != target) {
            std.atomic.spinLoopHint();
            spin_count += 1;
            // Bounded even for the spin case: ~every million spins, check a
            // 5 s deadline equivalent by panicking after ~2^32 spins.
            if (spin_count == 1 << 32) std.debug.panic("spin wait exceeded 2^32 spins: lost store", .{});
        }
    }
};

/// The exact Darwin syscall pair `Io.Threaded` uses internally for its
/// futex (`futexWait`/`futexWake` in `Io/Threaded.zig`): 32-bit
/// COMPARE_AND_WAIT with NO_ERRNO status returns.
const UlockChannel = struct {
    generation: std.atomic.Value(u32) = .init(0),

    const flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };

    fn init() !UlockChannel {
        return .{};
    }

    fn signal(channel: *UlockChannel, target: u64) void {
        channel.generation.store(@truncate(target), .release);
        while (true) {
            const status = std.c.__ulock_wake(flags, &channel.generation.raw, 0);
            if (status >= 0) return;
            switch (@as(std.c.E, @enumFromInt(-status))) {
                .INTR, .CANCELED => continue,
                .NOENT => return, // no waiter parked; it will observe the store
                else => |err| std.debug.panic("__ulock_wake: {t}", .{err}),
            }
        }
    }

    fn wait(channel: *UlockChannel, target: u64) void {
        const target_generation: u32 = @truncate(target);
        while (true) {
            const observed = channel.generation.load(.acquire);
            if (observed == target_generation) return;
            const status = std.c.__ulock_wait2(flags, &channel.generation.raw, observed, wait_timeout_ns, 0);
            if (status >= 0) continue;
            switch (@as(std.c.E, @enumFromInt(-status))) {
                .INTR, .FAULT => continue,
                .TIMEDOUT => std.debug.panic("ulock wait timed out (>5s): lost wakeup", .{}),
                else => |err| std.debug.panic("__ulock_wait2: {t}", .{err}),
            }
        }
    }
};

/// Apple's public futex API. Wait blocks only while `*addr == value`;
/// success returns >= 0 (remaining-waiter count), failure returns -1 with
/// errno set.
const OsSyncChannel = struct {
    generation: std.atomic.Value(u64) = .init(0),

    fn init() !OsSyncChannel {
        return .{};
    }

    fn signal(channel: *OsSyncChannel, target: u64) void {
        channel.generation.store(target, .release);
        const rc = os_sync_wake_by_address_any(&channel.generation.raw, @sizeOf(u64), os_sync_flags_none);
        if (rc == 0) return;
        const err = errnoValue();
        if (err != .NOENT) std.debug.panic("os_sync_wake_by_address_any: {t}", .{err});
    }

    fn wait(channel: *OsSyncChannel, target: u64) void {
        while (true) {
            const observed = channel.generation.load(.acquire);
            if (observed == target) return;
            const rc = os_sync_wait_on_address_with_timeout(
                &channel.generation.raw,
                observed,
                @sizeOf(u64),
                os_sync_flags_none,
                os_clock_mach_absolute_time,
                wait_timeout_ns,
            );
            if (rc >= 0) continue;
            switch (errnoValue()) {
                .INTR, .FAULT => continue,
                .TIMEDOUT => std.debug.panic("os_sync wait timed out (>5s): lost wakeup", .{}),
                else => |err| std.debug.panic("os_sync_wait_on_address_with_timeout: {t}", .{err}),
            }
        }
    }
};

/// One kqueue per direction with a single registered EVFILT_USER event;
/// EV_CLEAR resets the triggered state each time the event is retrieved.
/// A trigger latches until consumed, so a signal racing ahead of the wait
/// is never lost.
const KqueueChannel = struct {
    kq: c_int,

    fn init() !KqueueChannel {
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueCreateFailed;
        var change = [1]std.c.Kevent{.{
            .ident = 0,
            .filter = std.c.EVFILT.USER,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var events: [1]std.c.Kevent = undefined;
        if (std.c.kevent(kq, &change, 1, &events, 0, null) < 0)
            return error.KqueueRegisterFailed;
        return .{ .kq = kq };
    }

    fn signal(channel: *KqueueChannel, target: u64) void {
        _ = target;
        var change = [1]std.c.Kevent{.{
            .ident = 0,
            .filter = std.c.EVFILT.USER,
            .flags = 0,
            .fflags = std.c.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        var events: [1]std.c.Kevent = undefined;
        if (std.c.kevent(channel.kq, &change, 1, &events, 0, null) < 0)
            std.debug.panic("kevent trigger: {t}", .{errnoValue()});
    }

    fn wait(channel: *KqueueChannel, target: u64) void {
        _ = target;
        while (true) {
            var events: [1]std.c.Kevent = undefined;
            var change: [1]std.c.Kevent = undefined;
            const timeout: std.c.timespec = .{
                .sec = @intCast(wait_timeout_ns / std.time.ns_per_s),
                .nsec = @intCast(wait_timeout_ns % std.time.ns_per_s),
            };
            const rc = std.c.kevent(channel.kq, &change, 0, &events, 1, &timeout);
            if (rc == 1) return;
            if (rc == 0) std.debug.panic("kqueue wait timed out (>5s): lost wakeup", .{});
            switch (errnoValue()) {
                .INTR => continue,
                else => |err| std.debug.panic("kevent wait: {t}", .{err}),
            }
        }
    }
};

/// The cheapest GCD wake: a dispatch semaphore per direction. The
/// semaphore value returns to zero every iteration, so leaking the object
/// at process exit is safe (libdispatch aborts only when a semaphore is
/// destroyed below its creation value).
const GcdSemChannel = struct {
    semaphore: std.c.dispatch.semaphore_t,

    fn init() !GcdSemChannel {
        const semaphore = std.c.dispatch.semaphore_create(0) orelse
            return error.SemaphoreCreateFailed;
        return .{ .semaphore = semaphore };
    }

    fn signal(channel: *GcdSemChannel, target: u64) void {
        _ = target;
        _ = std.c.dispatch.semaphore_signal(channel.semaphore);
    }

    fn wait(channel: *GcdSemChannel, target: u64) void {
        _ = target;
        const deadline = std.c.dispatch.time(.NOW, @intCast(wait_timeout_ns));
        if (std.c.dispatch.semaphore_wait(channel.semaphore, deadline) != 0)
            std.debug.panic("dispatch semaphore wait timed out (>5s): lost wakeup", .{});
    }
};

// --- Generic two-thread harness ---

fn WakeupBench(comptime Channel: type) type {
    return struct {
        const Shared = struct {
            /// Separate cache lines so the two directions' state never
            /// false-shares (only matters for the userspace channels).
            to_worker: Channel align(std.atomic.cache_line),
            to_main: Channel align(std.atomic.cache_line),
            wake_timestamps: []u64,
            iterations: usize,
        };

        fn workerMain(shared: *Shared) void {
            var iteration: u64 = 1;
            while (iteration <= shared.iterations) : (iteration += 1) {
                shared.to_worker.wait(iteration);
                shared.wake_timestamps[iteration - 1] = nowNanoseconds();
                shared.to_main.signal(iteration);
            }
        }

        /// One repetition: spawn a fresh worker, run `iterations` timed
        /// wakeups, join. `signal_timestamps[i]`/`wake_timestamps[i]` are
        /// filled with t0/t1 per iteration.
        fn run(
            iterations: usize,
            repark_delay_ns: u64,
            signal_timestamps: []u64,
            wake_timestamps: []u64,
        ) !void {
            var shared: Shared = .{
                .to_worker = try Channel.init(),
                .to_main = try Channel.init(),
                .wake_timestamps = wake_timestamps,
                .iterations = iterations,
            };
            const worker = try std.Thread.spawn(.{}, workerMain, .{&shared});
            var iteration: u64 = 1;
            while (iteration <= iterations) : (iteration += 1) {
                const t0 = nowNanoseconds();
                signal_timestamps[iteration - 1] = t0;
                shared.to_worker.signal(iteration);
                shared.to_main.wait(iteration);
                // Give the worker time to park again before the next wake.
                const resume_deadline = nowNanoseconds() + repark_delay_ns;
                while (nowNanoseconds() < resume_deadline) std.atomic.spinLoopHint();
            }
            worker.join();
        }
    };
}

const RepStats = struct {
    median_ns: u64,
    min_ns: u64,
    p99_ns: u64,
    max_ns: u64,
};

/// Sorts `deltas` in place and reads off the order statistics.
fn computeStats(deltas: []u64) RepStats {
    std.debug.assert(deltas.len > 0);
    std.mem.sort(u64, deltas, {}, std.sort.asc(u64));
    return .{
        .median_ns = deltas[deltas.len / 2],
        .min_ns = deltas[0],
        .p99_ns = deltas[@min((deltas.len * 99) / 100, deltas.len - 1)],
        .max_ns = deltas[deltas.len - 1],
    };
}

fn runMechanism(
    comptime Channel: type,
    mechanism: Mechanism,
    op_count: usize,
    repetitions: usize,
    warmup_ops: usize,
    repark_delay_ns: u64,
) !void {
    const allocator = std.heap.page_allocator;
    const signal_timestamps = try allocator.alloc(u64, op_count);
    defer allocator.free(signal_timestamps);
    const wake_timestamps = try allocator.alloc(u64, op_count);
    defer allocator.free(wake_timestamps);
    const deltas = try allocator.alloc(u64, op_count);
    defer allocator.free(deltas);

    const Bench = WakeupBench(Channel);

    if (warmup_ops > 0) {
        try Bench.run(
            warmup_ops,
            repark_delay_ns,
            signal_timestamps[0..warmup_ops],
            wake_timestamps[0..warmup_ops],
        );
    }

    var rep_medians: [64]u64 = undefined;
    var rep_mins: [64]u64 = undefined;
    std.debug.assert(repetitions <= rep_medians.len);
    for (0..repetitions) |rep| {
        try Bench.run(op_count, repark_delay_ns, signal_timestamps, wake_timestamps);
        for (deltas, signal_timestamps, wake_timestamps) |*delta, t0, t1| {
            delta.* = t1 -| t0;
        }
        const stats = computeStats(deltas);
        rep_medians[rep] = stats.median_ns;
        rep_mins[rep] = stats.min_ns;
        std.debug.print(
            "  rep {d}: median_ns={d} min_ns={d} p99_ns={d} max_ns={d}\n",
            .{ rep + 1, stats.median_ns, stats.min_ns, stats.p99_ns, stats.max_ns },
        );
    }

    const medians = rep_medians[0..repetitions];
    std.mem.sort(u64, medians, {}, std.sort.asc(u64));
    const min_of_mins = std.mem.min(u64, rep_mins[0..repetitions]);
    std.debug.print(
        "RESULT mechanism={s} median_ns={d} min_ns={d}\n",
        .{ @tagName(mechanism), medians[repetitions / 2], min_of_mins },
    );
}

fn usageAndExit() noreturn {
    std.debug.print(
        "usage: wakeup <spin|ulock|os-sync|kqueue|gcd-sem> [ops] [reps] [warmup] [delay_ns]\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `Init.Minimal` hands over argv without start.zig constructing an
    // implicit Io instance — this spike drives threads and kernel wake
    // primitives directly.
    var args_iterator: std.process.Args.Iterator = .init(init.args);
    _ = args_iterator.next(); // program name

    const mechanism_arg = args_iterator.next() orelse usageAndExit();
    const mechanism = std.meta.stringToEnum(Mechanism, mechanism_arg) orelse usageAndExit();

    const op_count = if (args_iterator.next()) |ops_arg|
        try std.fmt.parseInt(usize, ops_arg, 10)
    else
        default_wakeups;
    const repetitions = if (args_iterator.next()) |reps_arg|
        try std.fmt.parseInt(usize, reps_arg, 10)
    else
        default_repetitions;
    const warmup_ops = if (args_iterator.next()) |warmup_arg|
        try std.fmt.parseInt(usize, warmup_arg, 10)
    else
        @max(op_count / 10, 1000);
    const repark_delay_ns = if (args_iterator.next()) |delay_arg|
        try std.fmt.parseInt(u64, delay_arg, 10)
    else
        default_repark_delay_ns;

    std.debug.print(
        "mechanism={s} ops={d} reps={d} warmup={d} delay_ns={d}\n",
        .{ @tagName(mechanism), op_count, repetitions, warmup_ops, repark_delay_ns },
    );

    switch (mechanism) {
        .spin => try runMechanism(SpinChannel, mechanism, op_count, repetitions, warmup_ops, repark_delay_ns),
        .ulock => try runMechanism(UlockChannel, mechanism, op_count, repetitions, warmup_ops, repark_delay_ns),
        .@"os-sync" => try runMechanism(OsSyncChannel, mechanism, op_count, repetitions, warmup_ops, repark_delay_ns),
        .kqueue => try runMechanism(KqueueChannel, mechanism, op_count, repetitions, warmup_ops, repark_delay_ns),
        .@"gcd-sem" => try runMechanism(GcdSemChannel, mechanism, op_count, repetitions, warmup_ops, repark_delay_ns),
    }
}
