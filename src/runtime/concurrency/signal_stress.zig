//! Cross-core signal-vs-teardown race proof for the kernel signal primitives
//! (P5-J1, `signal.zig`; plan §5.1). Drives the REAL M:N work-stealing scheduler
//! (`SchedulerPool`): many "signaller" processes concurrently `link`, `monitor`,
//! and `exit_signal` a shared "target" process across cores WHILE that target is
//! being torn down (killed by the first signal to reach it). This is exactly the
//! deliverable's race — a signal to a concurrently-exiting linked process on
//! another core — and it must be TSan-clean: every delivery either lands or
//! silently no-ops (never leaks a set node / payload, never double-delivers),
//! because signal delivery rides the SAME `beginSend`/`isAlive`/`closeAndQuiesce`
//! grace period (P4-R1) the copy send proved race-free, plus the per-PCB signal
//! spinlock and the cross-core `pending_kill` + `reviveIfParked` handshake.
//!
//! Like `mn_refcount_stress.zig`, this RUNS under ThreadSanitizer: the fiber
//! context switches are `__tsan_switch_to_fiber`-annotated, so TSan tracks each
//! process's happens-before across stack switches and core migration, and any
//! missing scheduler fence on a signal path surfaces here as a real race.
//! `ZAP_SIGNAL_STRESS_*` scale it into a soak.
//!
//! The leak-exactness oracle after quiescence: zero live processes, zero live
//! signal-set nodes (every `link`/`monitor` entry drained at teardown), zero live
//! envelope pages, and a balanced signal-payload seam (every synthesized `DOWN`
//! payload freed — delivered-and-consumed, or drained at the receiver's death).

const std = @import("std");
const builtin = @import("builtin");
const scheduler_module = @import("scheduler.zig");
const scheduler_pool_module = @import("scheduler_pool.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const signal_module = @import("signal.zig");

const SchedulerPool = scheduler_pool_module.SchedulerPool;
const ProcessContext = scheduler_module.ProcessContext;
const ManagerContext = process_module.ManagerContext;
const ManagerVTable = process_module.ManagerVTable;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const Pid = pid_table_module.Pid;
const SignalRuntime = signal_module.SignalRuntime;
const SignalPayload = signal_module.SignalPayload;

/// A no-op per-process manager: the stress bodies allocate nothing, so this
/// satisfies the PCB's manager binding with zero heap traffic. Shared by every
/// process (teardown is a no-op, so calling it once per process is fine).
const NoOpManager = struct {
    fn managerContext() ManagerContext {
        return .{ .manager_state = null, .vtable = &vtable };
    }

    const vtable = ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(_: ?*anyopaque, _: usize, _: std.mem.Alignment) ?[*]u8 {
        return null;
    }
    fn deallocateThunk(_: ?*anyopaque, _: [*]u8, _: usize, _: std.mem.Alignment) void {}
    fn teardownThunk(_: ?*anyopaque) void {}
    fn heapByteCountThunk(_: ?*anyopaque) usize {
        return 0;
    }
};

const payload_alignment = @alignOf(SignalPayload);

/// A tracked signal-payload seam for the test: page-backed (thread-safe — any
/// core allocates a `DOWN` payload, any core frees it at a receiver's teardown),
/// with a live counter that MUST return to zero (payload leak-exactness).
const TestPayloadSeam = struct {
    live: std.atomic.Value(usize) = .init(0),

    fn allocate(context: ?*anyopaque, byte_length: usize) callconv(.c) ?[*]u8 {
        const seam: *TestPayloadSeam = @ptrCast(@alignCast(context.?));
        const slice = std.heap.page_allocator.alignedAlloc(u8, .of(SignalPayload), byte_length) catch return null;
        _ = seam.live.fetchAdd(1, .monotonic);
        return slice.ptr;
    }

    fn free(context: ?*anyopaque, body: [*]const u8, byte_length: usize) callconv(.c) void {
        const seam: *TestPayloadSeam = @ptrCast(@alignCast(context.?));
        const raw: [*]align(payload_alignment) u8 = @alignCast(@constCast(body));
        std.heap.page_allocator.free(raw[0..byte_length]);
        _ = seam.live.fetchSub(1, .monotonic);
    }
};

/// Shared state threaded to every stress process.
const Shared = struct {
    /// The target's raw pid bits, published once by the target when it starts.
    target_pid_bits: std.atomic.Value(u64) = .init(0),
    /// The abnormal reason the signallers deliver.
    reason_term: u64,
};

/// The target: publish its pid, then block forever. The first signaller's
/// `exit_signal` kills it; every other signaller's `link`/`monitor`/`exit_signal`
/// then races its teardown.
fn targetBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const shared: *Shared = @ptrCast(@alignCast(argument.?));
    shared.target_pid_bits.store(context.selfPid().toBits(), .release);
    // Blocks until an incoming exit signal marks `pending_kill` and the receive
    // loop tears the process down — the call never returns.
    _ = context.receive();
}

/// A signaller: wait for the target's pid, then `link` + `monitor` + `exit_signal`
/// it. Whichever signaller's `exit_signal` reaches the LIVE target kills it;
/// links established before then cascade the death back (killing this signaller),
/// and a `link`/`monitor` that arrives after the target is gone silently
/// no-procs. Either way this process dies abnormally (a linked cascade, a noproc,
/// or — for a signaller that never linked in time — a normal return whose
/// `pending_kill` was set by the cascade). No path leaks or hangs.
fn signallerBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const shared: *Shared = @ptrCast(@alignCast(argument.?));
    var target_bits = shared.target_pid_bits.load(.acquire);
    while (target_bits == 0) {
        context.yieldNow();
        target_bits = shared.target_pid_bits.load(.acquire);
    }
    const target = Pid.fromBits(target_bits);
    _ = context.link(target);
    _ = context.monitor(target);
    _ = context.exitSignal(target, .abnormal, shared.reason_term);
}

fn runSignalTeardownStorm(signaller_count: usize) !void {
    const allocator = std.testing.allocator;

    var pid_table = try PidTable.init(allocator, .{ .capacity = 4096 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(allocator, .{});
    defer envelope_pool.deinit();

    var seam = TestPayloadSeam{};
    var signal_runtime = SignalRuntime.init(allocator);
    defer signal_runtime.deinit();
    signal_runtime.payload_seam = .{
        .context = &seam,
        .allocate = TestPayloadSeam.allocate,
        .free = TestPayloadSeam.free,
    };
    // Register distinct test reason atoms so synthesized reasons (noproc, etc.)
    // carry non-zero terms exactly as in production.
    signal_runtime.reason_atoms.set(0xA1, 0xA2, 0xA3);

    var shared = Shared{ .reason_term = 0xBEEF };

    var pool: SchedulerPool = undefined;
    try SchedulerPool.init(&pool, allocator, &pid_table, &envelope_pool, .{
        .core_options = .{ .signal_runtime = &signal_runtime },
    });
    defer pool.deinit();

    // Target first (so signallers can resolve its pid), then the signaller storm
    // onto core 0 — stolen across cores as the run proceeds.
    _ = try pool.primaryCore().spawn(.{
        .entry = targetBody,
        .argument = &shared,
        .manager = NoOpManager.managerContext(),
        .model = .refcounted,
    });
    var spawned: usize = 0;
    while (spawned < signaller_count) : (spawned += 1) {
        _ = try pool.primaryCore().spawn(.{
            .entry = signallerBody,
            .argument = &shared,
            .manager = NoOpManager.managerContext(),
            .model = .refcounted,
        });
    }

    pool.runUntilQuiescent();

    // Leak-exact: every process gone, every signal-set node freed, every envelope
    // page returned, and every synthesized signal payload freed.
    try std.testing.expectEqual(@as(i64, 0), pool.liveProcessCount());
    try std.testing.expectEqual(@as(u32, 0), pid_table.statistics().live_process_count);
    try std.testing.expectEqual(@as(usize, 0), signal_runtime.node_pool.liveNodeCount());
    try std.testing.expectEqual(@as(u32, 0), envelope_pool.statistics().live_page_count);
    try std.testing.expectEqual(@as(u32, 0), envelope_pool.statistics().abandoned_page_count);
    try std.testing.expectEqual(@as(usize, 0), seam.live.load(.monotonic));
}

fn envValue(name: [*:0]const u8, default_value: usize) usize {
    // libc `getenv` by kernel convention (`concurrency.zig`, "Portability
    // tracking"), the same seam the other stress knobs read through.
    const raw = std.c.getenv(name) orelse return default_value;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch default_value;
}

test "SignalStress: cross-core link/monitor/exit-signal races a target's teardown, leak-exact and TSan-clean" {
    const signaller_count = envValue("ZAP_SIGNAL_STRESS_SIGNALLERS", 256);
    try runSignalTeardownStorm(signaller_count);
}
