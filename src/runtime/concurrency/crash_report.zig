//! Crash reports for the Zap concurrency kernel.
//!
//! Phase 1 item 1.6 of `docs/concurrency-implementation-plan.md` (job
//! P1-J5), implementing research.md §6.9's "crash reports with native
//! stacktraces": every process teardown — normal exit, kill, or the Phase
//! 1 simulated crash (which IS a kill; `scheduler.zig`, "Exit and crash
//! teardown") — can produce a structured `CrashReport` carrying the pid,
//! the exit reason, the process state and (approximate) mailbox depth at
//! the instant teardown began, and a native stack trace of the fiber from
//! its LAST SUSPEND POINT.
//!
//! ## Why the trace is from the last suspend point
//!
//! A Phase 1 teardown never runs while the victim is on a CPU: a killed
//! process is torn down either before its first quantum (`.ready` fiber —
//! no frames exist), or parked mid-`yield` (`.suspended` fiber — its cpu
//! state was saved by its final context switch and its stack is intact
//! until teardown step 7 releases it), and a normally-exited process has
//! already run to completion (`.reclaimed` fiber — its stack went back to
//! the pool BEFORE teardown, so there is nothing left to walk; the report
//! says so honestly instead of fabricating frames). The suspend point is
//! therefore exactly where the process died from its own point of view,
//! the same place a BEAM crash report's `current_function`/stacktrace
//! comes from. Phase 2's trap/panic entry into the teardown path will add
//! genuinely-crashed register states through the same capture seam.
//!
//! ## How the trace is captured: a bounded frame-pointer walk
//!
//! The walk starts from the saved {pc, fp} of the fiber's last context
//! switch (`fiber_context.savedRegisters`) and follows the standard
//! aarch64/x86_64 frame records — `{previous fp, return address}` at
//! `fp[0]`/`fp[1]` — until the fiber root's `{fp: 0, ra: 0}` terminator
//! (the unwind-safe-root design of `fiber_context.zig`). Every step is
//! validated BEFORE dereferencing: the record must lie inside the fiber's
//! own stack mapping, be pointer-aligned, and ascend strictly (frames
//! grow downward, so records ascend); a record that fails validation ends
//! the walk with `trace_truncated = true` rather than faulting. The walk
//! is therefore memory-safe in every build mode with no signal handling —
//! the kernel knows the exact stack bounds, which no general-purpose
//! unwinder does. Frame pointers are available by construction: the Zig
//! compiler keeps them in every optimize mode except x86-less
//! ReleaseSmall shapes (`Package/Module.zig`), and the kernel's supported
//! fiber architectures (aarch64, x86_64) both use the
//! `{fp, ra}`-at-`fp` record layout (`std.debug`'s `fp_to_bp_offset`/
//! `fp_to_ra_offset` are 0 and `@sizeOf(usize)` for both).
//!
//! ## Fork MachO unwinder adjudication (P1-J5 required verdict)
//!
//! The fork std's Darwin/aarch64 compact-unwind `.FRAME` rule reads saved
//! x-register pairs ASCENDING from `fp - 8` where Apple's layout stores
//! them DESCENDING below fp (`lib/std/debug/SelfInfo/MachO.zig`,
//! `x_reg_pairs` loop — the J1-documented fork-std bug). Kernel crash
//! reports DO NOT route through that path: the walk above never invokes
//! `SelfInfo.unwindFrame`, and rendering (`CrashReport.render`) only
//! SYMBOLIZES addresses via debug info — symbolization never unwinds.
//! Measured on real suspended-fiber frames (2026-07, Debug and
//! ReleaseFast, Apple Silicon): the kernel FP walk and the fork's
//! `SelfInfo` unwinder (exercised via
//! `std.debug.captureCurrentStackTrace` with a reconstructed
//! `cpu_context` over the same saved {pc, fp, sp}) produce IDENTICAL
//! return-address chains — 8/8 frames in Debug, 7/7 in ReleaseFast, no
//! divergence, no truncation, zero di→fp fallbacks (so the compact-unwind
//! rules themselves were genuinely exercised, not skipped), both
//! terminating cleanly at the fiber root and symbolizing down through
//! `receive`/entry/`fiberMain`. The buggy `x_reg_pairs` reads corrupt
//! only the restored x19..x28 *unwind register state* (never consulted
//! by the frame-record ip/fp chain these traces follow) and over-read up
//! to `fp + 0x38`, which stays inside the mapping thanks to J1's
//! `stack_top_unwind_headroom`. The bug therefore does NOT degrade Phase
//! 1 kernel crash reports; it remains a real fork-std defect for unwind
//! consumers that trust restored callee-saved registers (DWARF expression
//! rules, profilers) and stays on the fork-hygiene track
//! (`fiber_context.zig`, `stack_top_unwind_headroom` doc).
//!
//! ## The report sink seam (Phase 1 posture)
//!
//! `scheduler.Scheduler` exposes `crash_report_hook`/`crash_report_context`
//! options mirroring the trace seam: null (production default) costs one
//! branch per teardown and captures nothing; a hook receives every
//! teardown's report synchronously on the scheduler thread, borrowed for
//! the duration of the call. Rendering to text (`CrashReport.render`) is
//! the caller's choice — Phase 1 ships the buffer renderer used by tests;
//! wiring reports into logging/telemetry is a later-phase concern
//! (plan 6.5).
//!
//! ## Toolchain
//!
//! Exercised through the scheduler (fiber switches), so the kernel-wide
//! fork-compiler requirement for optimized builds applies (see
//! `concurrency.zig`).

const std = @import("std");
const builtin = @import("builtin");
const fiber_context = @import("fiber_context.zig");
const stack_pool_module = @import("stack_pool.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const mailbox_module = @import("mailbox.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const scheduler_module = @import("scheduler.zig");

const ProcessControlBlock = process_module.ProcessControlBlock;
const ExitReason = scheduler_module.ExitReason;

comptime {
    // The frame-record walk assumes the {previous fp, return address}
    // record layout at fp[0]/fp[1] — true for both kernel fiber
    // architectures (see the module doc). A new fiber architecture must
    // extend the walk, not silently inherit it.
    switch (builtin.cpu.arch) {
        .aarch64, .x86_64 => {},
        else => |arch| @compileError(
            "crash-report frame walk not implemented for " ++ @tagName(arch),
        ),
    }
}

/// Maximum number of return addresses captured per report. Reports are
/// fixed-size values (no allocation on the teardown path); deeper stacks
/// set `trace_truncated`. 32 frames is far beyond any Phase 1 kernel
/// call depth and matches the fiber-root unwind test's buffer.
pub const max_trace_frames = 32;

/// Whether (and why not) a report carries a suspend-point stack trace.
pub const TraceStatus = enum(u8) {
    /// The fiber was suspended with its stack intact; `trace()` holds the
    /// walked return-address chain from the last suspend point.
    captured,
    /// The process was killed before its first quantum ever ran: no code
    /// executed on its stack, so no frames exist.
    never_ran,
    /// The process ran to completion (normal exit): its stack was
    /// released back to the pool before teardown began, so there is no
    /// suspend point left to walk.
    ran_to_completion,
};

/// One process teardown, captured at the instant teardown began — before
/// the pid was unregistered or any resource was torn down. A plain
/// fixed-size value: safe to copy, store, and render after the process
/// is gone.
pub const CrashReport = struct {
    /// The dead process's pid (raw bits; `Pid.fromBits` reconstructs).
    pid_bits: u64,
    /// Why the teardown ran (normal exit vs kill — the Phase 1 simulated
    /// crash is a kill).
    reason: ExitReason,
    /// The process's scheduling state at the instant teardown began
    /// (`.waiting` for a kill-while-suspended, `.runnable` for a kill
    /// before the next quantum, `.running` for a normal exit or a kill
    /// consumed at a safepoint).
    state_at_death: process_module.ProcessState,
    /// Mailbox depth at the instant teardown began — the number of
    /// undelivered envelopes about to be dead-lettered. APPROXIMATE by
    /// the mailbox's documented counter semantics (`mailbox.zig`); exact
    /// in the single-scheduler Phase 1 contract, where no producer can
    /// race teardown.
    mailbox_depth_at_death: usize,
    /// Whether `trace()` is populated, and why not when it is not.
    trace_status: TraceStatus,
    /// The saved program counter of the last suspend point (0 unless
    /// `trace_status == .captured`).
    suspend_program_counter: usize,
    /// The saved frame pointer of the last suspend point (0 unless
    /// `trace_status == .captured`).
    suspend_frame_pointer: usize,
    /// Backing storage for `trace()`.
    return_address_buffer: [max_trace_frames]usize,
    /// Number of valid entries in `return_address_buffer`.
    return_address_count: usize,
    /// True when the frame walk ended before reaching the fiber root —
    /// either the report buffer filled, or a frame record failed
    /// validation (out of the stack bounds, misaligned, or non-ascending;
    /// the walk stops rather than faulting).
    trace_truncated: bool,

    /// The captured return-address chain, innermost first. The first
    /// entry is the suspend program counter itself (stored +1 so
    /// renderers that subtract the standard return-address call offset
    /// land on the suspend instruction, mirroring `std.debug`'s handling
    /// of context-derived first frames); subsequent entries are genuine
    /// return addresses. Empty unless `trace_status == .captured`.
    pub fn trace(report: *const CrashReport) []const usize {
        return report.return_address_buffer[0..report.return_address_count];
    }

    /// Render the report as human-readable text: the structured header
    /// plus the symbolized stack trace (via the binary's own debug info —
    /// symbolization only, no unwinding; see the module doc's
    /// adjudication note). Degrades gracefully when debug info or stack
    /// tracing is unavailable (`std.debug.writeStackTrace` prints its
    /// diagnostic instead of frames).
    pub fn render(report: *const CrashReport, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "process crash report\n" ++
                "  pid:              0x{x:0>16}\n" ++
                "  reason:           {t}\n" ++
                "  state at death:   {t}\n" ++
                "  mailbox depth:    {d} (approximate)\n",
            .{
                report.pid_bits,
                report.reason,
                report.state_at_death,
                report.mailbox_depth_at_death,
            },
        );
        switch (report.trace_status) {
            .captured => {
                try writer.print(
                    "  last suspend:     pc 0x{x} fp 0x{x}\n" ++
                        "  stack trace (from the last suspend point):\n",
                    .{ report.suspend_program_counter, report.suspend_frame_pointer },
                );
                // `writeStackTrace` takes a mutable address slice; the
                // report is borrowed const, so render from a local copy.
                var addresses: [max_trace_frames]usize = undefined;
                const count = report.return_address_count;
                @memcpy(addresses[0..count], report.return_address_buffer[0..count]);
                const stack_trace: std.debug.StackTrace = .{
                    .return_addresses = addresses[0..count],
                    .skipped = if (report.trace_truncated) .unknown else .none,
                };
                try std.debug.writeStackTrace(&stack_trace, .{ .writer = writer, .mode = .no_color });
            },
            .never_ran => try writer.writeAll(
                "  stack trace:      none — killed before the first quantum (no code ever ran)\n",
            ),
            .ran_to_completion => try writer.writeAll(
                "  stack trace:      none — ran to completion (stack released before teardown)\n",
            ),
        }
    }
};

/// Report sink callback (the Phase 1 sink seam; module doc): invoked
/// synchronously on the scheduler thread at the START of every teardown,
/// before any resource is torn down. `report` is borrowed for the call —
/// copy it to keep it. Must not call back into the scheduler.
pub const ReportHook = *const fn (report_context: ?*anyopaque, report: *const CrashReport) void;

/// Capture a teardown report from a process whose teardown is about to
/// begin. Must run BEFORE any teardown mutation: the pid must still be
/// registered, the state not yet `.exiting`, and — for a suspended fiber
/// — the stack not yet released (the scheduler's teardown path calls
/// this first; see `scheduler.zig`).
pub fn captureForTeardown(pcb: *const ProcessControlBlock, reason: ExitReason) CrashReport {
    var report = CrashReport{
        .pid_bits = pcb.pid.toBits(),
        .reason = reason,
        .state_at_death = pcb.state,
        .mailbox_depth_at_death = pcb.mailbox.depth(),
        .trace_status = undefined,
        .suspend_program_counter = 0,
        .suspend_frame_pointer = 0,
        .return_address_buffer = undefined,
        .return_address_count = 0,
        .trace_truncated = false,
    };
    switch (pcb.fiber.lifecycle_state) {
        .ready => report.trace_status = .never_ran,
        .suspended => {
            report.trace_status = .captured;
            // Non-null by the `.suspended` check just made.
            const saved = fiber_context.savedRegisters(&pcb.fiber).?;
            report.suspend_program_counter = saved.program_counter;
            report.suspend_frame_pointer = saved.frame_pointer;
            walkSavedFrames(&report, saved, pcb.fiber.stack);
        },
        .reclaimed => report.trace_status = .ran_to_completion,
        // Teardown never observes these: a `.running` fiber's quantum has
        // always returned before teardown, and `.finished` becomes
        // `.reclaimed` inside resumeFiber before it returns
        // (`scheduler.zig`, teardown step 7).
        .running, .finished => unreachable,
    }
    return report;
}

/// The bounded frame-pointer walk (module doc): append the suspend pc,
/// then follow validated {previous fp, return address} records until the
/// fiber root's {fp: 0, ra: 0} terminator, the report buffer fills, or a
/// record fails validation.
fn walkSavedFrames(
    report: *CrashReport,
    saved: fiber_context.SavedRegisters,
    stack: stack_pool_module.Stack,
) void {
    // First frame: the suspend point itself, +1 per the render contract
    // (`CrashReport.trace` doc).
    report.return_address_buffer[0] = saved.program_counter +| 1;
    report.return_address_count = 1;

    const usable_bytes = stack.usable();
    const walk_low = @intFromPtr(usable_bytes.ptr);
    const walk_high = stack.top();
    const frame_record_byte_length = 2 * @sizeOf(usize);

    var frame_pointer = saved.frame_pointer;
    while (frame_pointer != 0) {
        const record_valid = frame_pointer >= walk_low and
            frame_pointer <= walk_high - frame_record_byte_length and
            std.mem.isAligned(frame_pointer, @alignOf(usize));
        if (!record_valid) {
            report.trace_truncated = true;
            return;
        }
        const frame_record: *const [2]usize = @ptrFromInt(frame_pointer);
        const previous_frame_pointer = frame_record[0];
        const return_address = frame_record[1];
        // The fiber root's record reads {fp: 0, ra: 0}; a return address
        // of 0/1 is the walk terminator either way (std's convention).
        if (return_address <= 1) return;
        if (report.return_address_count == max_trace_frames) {
            report.trace_truncated = true;
            return;
        }
        report.return_address_buffer[report.return_address_count] = return_address;
        report.return_address_count += 1;
        // Frames grow downward, so records must ascend strictly; anything
        // else is a malformed chain the walk must not follow.
        if (previous_frame_pointer != 0 and previous_frame_pointer <= frame_pointer) {
            report.trace_truncated = true;
            return;
        }
        frame_pointer = previous_frame_pointer;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Scheduler = scheduler_module.Scheduler;
const ProcessContext = scheduler_module.ProcessContext;
const PidTable = pid_table_module.PidTable;
const Pid = pid_table_module.Pid;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const ManagerContext = process_module.ManagerContext;

/// Byte-accounting arena manager (the standard Phase 1 test-manager
/// shape; see `scheduler.zig`).
const ReportTestManager = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    fn init(backing_allocator: std.mem.Allocator) ReportTestManager {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    fn deinitBacking(manager: *ReportTestManager) void {
        manager.arena.deinit();
    }

    fn managerContext(manager: *ReportTestManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *ReportTestManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *ReportTestManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *ReportTestManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *ReportTestManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};

/// Test sink: copies every report (the seam contract — reports are
/// borrowed for the hook call only).
const TestReportLog = struct {
    reports: [16]CrashReport = undefined,
    count: usize = 0,

    fn hook(report_context: ?*anyopaque, report: *const CrashReport) void {
        const log: *TestReportLog = @ptrCast(@alignCast(report_context.?));
        if (log.count == log.reports.len) @panic("TestReportLog overflow");
        log.reports[log.count] = report.*;
        log.count += 1;
    }

    fn byPid(log: *TestReportLog, pid: Pid) ?*const CrashReport {
        for (log.reports[0..log.count]) |*report| {
            if (report.pid_bits == pid.toBits()) return report;
        }
        return null;
    }
};

/// One deterministic (forbid-parking) kernel wired with the report sink.
const ReportTestKernel = struct {
    pid_table: PidTable,
    envelope_pool: EnvelopePool,
    scheduler: Scheduler,
    report_log: TestReportLog,

    fn init(kernel: *ReportTestKernel) !void {
        kernel.report_log = .{};
        kernel.pid_table = try PidTable.init(testing.allocator, .{ .capacity = 64 });
        kernel.envelope_pool = EnvelopePool.init(testing.allocator, .{ .envelopes_per_page = 8 });
        kernel.scheduler = Scheduler.init(testing.allocator, &kernel.pid_table, &kernel.envelope_pool, .{
            .stack_usable_size = 64 * 1024,
            .preemption_budget = 16,
            .idle_strategy = .forbid_parking,
            .crash_report_hook = TestReportLog.hook,
            .crash_report_context = &kernel.report_log,
        });
    }

    fn deinit(kernel: *ReportTestKernel) void {
        kernel.scheduler.deinit();
        kernel.envelope_pool.deinit();
        kernel.pid_table.deinit();
    }

    fn expectExactAccounting(kernel: *ReportTestKernel) !void {
        try testing.expectEqual(@as(u32, 0), kernel.pid_table.statistics().live_process_count);
        const envelope_stats = kernel.envelope_pool.statistics();
        try testing.expectEqual(@as(u32, 0), envelope_stats.live_page_count);
        try testing.expectEqual(@as(u32, 0), envelope_stats.abandoned_page_count);
        try testing.expectEqual(@as(u32, 0), kernel.scheduler.stackPoolStatistics().live_stack_count);
        try testing.expectEqual(@as(u32, 0), kernel.scheduler.statistics().live_process_count);
    }
};

// -- process bodies -------------------------------------------------------------

fn blockForMessageEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    _ = context.receive();
    @panic("blockForMessageEntry: received a message nobody should have sent");
}

fn immediateExitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    _ = argument;
}

fn yieldCheckForeverEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = argument;
    while (true) context.yieldCheck();
}

const SendBurstProbe = struct {
    target: Pid,
    envelope_count: usize,
    kill_target_after_send: bool = false,
};

fn sendBurstEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *SendBurstProbe = @ptrCast(@alignCast(argument.?));
    var sent: usize = 0;
    while (sent < probe.envelope_count) : (sent += 1) {
        const outcome = context.send(probe.target, .{ .payload_byte_length = sent }) catch
            @panic("sendBurstEntry: envelope allocation failed");
        if (outcome != .delivered) @panic("sendBurstEntry: send dead-lettered unexpectedly");
    }
    if (probe.kill_target_after_send) _ = context.kill(probe.target);
}

const ReceiveOneProbe = struct {
    received_payload_length: usize = 0,
};

fn receiveOneThenExitEntry(context: *ProcessContext, argument: ?*anyopaque) void {
    const probe: *ReceiveOneProbe = @ptrCast(@alignCast(argument.?));
    const envelope = context.receive();
    probe.received_payload_length = envelope.fragment.payload_byte_length;
    envelope_pool_module.free(envelope);
}

// -- kill while waiting: the non-cooperative teardown point ----------------------

test "CrashReport: kill while waiting captures reason, state, depth, and a suspend-point trace" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = blockForMessageEntry,
        .manager = manager.managerContext(),
    });

    // Run until the victim parks in receive: the deterministic idle
    // outcome (nothing else is runnable).
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());

    // Ground truth for the report's suspend registers, read while the
    // victim is still alive and suspended.
    const victim_pcb = kernel.pid_table.lookup(victim_pid).?;
    try testing.expectEqual(process_module.ProcessState.waiting, victim_pcb.state);
    const saved = fiber_context.savedRegisters(&victim_pcb.fiber).?;

    try testing.expectEqual(scheduler_module.KillOutcome.killed, kernel.scheduler.kill(victim_pid));
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 1), kernel.report_log.count);
    const report = kernel.report_log.byPid(victim_pid).?;
    try testing.expectEqual(ExitReason.killed, report.reason);
    try testing.expectEqual(process_module.ProcessState.waiting, report.state_at_death);
    try testing.expectEqual(@as(usize, 0), report.mailbox_depth_at_death);
    try testing.expectEqual(TraceStatus.captured, report.trace_status);
    try testing.expectEqual(saved.program_counter, report.suspend_program_counter);
    try testing.expectEqual(saved.frame_pointer, report.suspend_frame_pointer);

    // Trace shape: the suspend pc (+1) first, then real return addresses,
    // terminating at the fiber root without truncation.
    const trace = report.trace();
    try testing.expect(trace.len >= 2);
    try testing.expect(!report.trace_truncated);
    try testing.expectEqual(saved.program_counter +| 1, trace[0]);
    for (trace) |return_address| try testing.expect(return_address > 1);

    try testing.expectEqual(@as(usize, 1), manager.teardown_count);
    try kernel.expectExactAccounting();
}

// -- normal exit: no suspend point remains ----------------------------------------

test "CrashReport: normal exit reports ran_to_completion with no trace" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const pid = try kernel.scheduler.spawn(.{
        .entry = immediateExitEntry,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 1), kernel.report_log.count);
    const report = kernel.report_log.byPid(pid).?;
    try testing.expectEqual(ExitReason.normal, report.reason);
    try testing.expectEqual(process_module.ProcessState.running, report.state_at_death);
    try testing.expectEqual(TraceStatus.ran_to_completion, report.trace_status);
    try testing.expectEqual(@as(usize, 0), report.trace().len);
    try testing.expectEqual(@as(usize, 0), report.suspend_program_counter);
    try kernel.expectExactAccounting();
}

// -- kill before the first quantum: no frames exist --------------------------------

test "CrashReport: kill before the first quantum reports never_ran" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const pid = try kernel.scheduler.spawn(.{
        .entry = immediateExitEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectEqual(scheduler_module.KillOutcome.kill_pending, kernel.scheduler.kill(pid));
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 1), kernel.report_log.count);
    const report = kernel.report_log.byPid(pid).?;
    try testing.expectEqual(ExitReason.killed, report.reason);
    try testing.expectEqual(process_module.ProcessState.runnable, report.state_at_death);
    try testing.expectEqual(TraceStatus.never_ran, report.trace_status);
    try testing.expectEqual(@as(usize, 0), report.trace().len);
    try kernel.expectExactAccounting();
}

// -- kill at a safepoint: the yieldCheck suspend point ------------------------------

test "CrashReport: kill consumed at a safepoint captures the yieldCheck suspend point" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = yieldCheckForeverEntry,
        .manager = manager.managerContext(),
    });
    var killer_probe = SendBurstProbe{
        .target = victim_pid,
        .envelope_count = 0,
        .kill_target_after_send = true,
    };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendBurstEntry,
        .argument = &killer_probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    try testing.expectEqual(@as(usize, 2), kernel.report_log.count);
    const report = kernel.report_log.byPid(victim_pid).?;
    try testing.expectEqual(ExitReason.killed, report.reason);
    try testing.expectEqual(TraceStatus.captured, report.trace_status);
    try testing.expect(report.trace().len >= 2);
    try testing.expect(!report.trace_truncated);
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
    try kernel.expectExactAccounting();
}

// -- mailbox depth at death ----------------------------------------------------------

test "CrashReport: mailbox depth at death counts the undelivered envelopes" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = yieldCheckForeverEntry,
        .manager = manager.managerContext(),
    });
    var sender_probe = SendBurstProbe{
        .target = victim_pid,
        .envelope_count = 3,
        .kill_target_after_send = true,
    };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendBurstEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    const report = kernel.report_log.byPid(victim_pid).?;
    try testing.expectEqual(ExitReason.killed, report.reason);
    try testing.expectEqual(@as(usize, 3), report.mailbox_depth_at_death);
    try testing.expectEqual(TraceStatus.captured, report.trace_status);
    // Teardown drained the three undelivered envelopes back to their
    // origin pages — every page accounted.
    try kernel.expectExactAccounting();
}

test "CrashReport: normal exit with a populated mailbox reports the leftover depth" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    var receive_probe = ReceiveOneProbe{};
    const receiver_pid = try kernel.scheduler.spawn(.{
        .entry = receiveOneThenExitEntry,
        .argument = &receive_probe,
        .manager = manager.managerContext(),
    });
    var sender_probe = SendBurstProbe{ .target = receiver_pid, .envelope_count = 3 };
    _ = try kernel.scheduler.spawn(.{
        .entry = sendBurstEntry,
        .argument = &sender_probe,
        .manager = manager.managerContext(),
    });
    try kernel.scheduler.runUntilQuiescent();

    // The receiver consumed exactly one envelope and exited normally
    // with two still queued.
    try testing.expectEqual(@as(usize, 0), receive_probe.received_payload_length);
    const report = kernel.report_log.byPid(receiver_pid).?;
    try testing.expectEqual(ExitReason.normal, report.reason);
    try testing.expectEqual(@as(usize, 2), report.mailbox_depth_at_death);
    try testing.expectEqual(TraceStatus.ran_to_completion, report.trace_status);
    try kernel.expectExactAccounting();
}

// -- rendering ------------------------------------------------------------------------

test "CrashReport: render produces the structured header and a symbolized trace" {
    var kernel: ReportTestKernel = undefined;
    try kernel.init();
    defer kernel.deinit();
    var manager = ReportTestManager.init(testing.allocator);
    defer manager.deinitBacking();

    const victim_pid = try kernel.scheduler.spawn(.{
        .entry = blockForMessageEntry,
        .manager = manager.managerContext(),
    });
    try testing.expectError(error.AllProcessesWaiting, kernel.scheduler.runUntilQuiescent());
    try testing.expectEqual(scheduler_module.KillOutcome.killed, kernel.scheduler.kill(victim_pid));
    try kernel.scheduler.runUntilQuiescent();

    const report = kernel.report_log.byPid(victim_pid).?;
    var render_buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&render_buffer);
    try report.render(&writer);
    const rendered = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, rendered, "process crash report") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "reason:           killed") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "state at death:   waiting") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "stack trace (from the last suspend point):") != null);
    // Symbolization quality is asserted only where debug info is
    // structurally present (unstripped Debug test binaries); optimized
    // builds may inline through the kernel receive path.
    if (builtin.mode == .Debug and std.options.allow_stack_tracing) {
        try testing.expect(std.mem.indexOf(u8, rendered, "blockForMessageEntry") != null);
    }
    try kernel.expectExactAccounting();
}

test "CrashReport: render reports the no-trace statuses honestly" {
    var report = CrashReport{
        .pid_bits = 0x123,
        .reason = .killed,
        .state_at_death = .runnable,
        .mailbox_depth_at_death = 0,
        .trace_status = .never_ran,
        .suspend_program_counter = 0,
        .suspend_frame_pointer = 0,
        .return_address_buffer = undefined,
        .return_address_count = 0,
        .trace_truncated = false,
    };
    var render_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&render_buffer);
    try report.render(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "killed before the first quantum") != null);

    report.trace_status = .ran_to_completion;
    report.reason = .normal;
    report.state_at_death = .running;
    writer = std.Io.Writer.fixed(&render_buffer);
    try report.render(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "ran to completion") != null);
}

// -- the walk's validation bounds ----------------------------------------------------

test "CrashReport: frame walk rejects an out-of-bounds frame pointer instead of faulting" {
    var pool = stack_pool_module.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    const stack = try pool.acquire();
    defer pool.release(stack);

    var report = CrashReport{
        .pid_bits = 0,
        .reason = .killed,
        .state_at_death = .waiting,
        .mailbox_depth_at_death = 0,
        .trace_status = .captured,
        .suspend_program_counter = 0x1000,
        .suspend_frame_pointer = 0,
        .return_address_buffer = undefined,
        .return_address_count = 0,
        .trace_truncated = false,
    };

    // A frame pointer outside the stack mapping must terminate the walk
    // as truncated after the suspend pc, never dereference.
    walkSavedFrames(&report, .{
        .program_counter = 0x1000,
        .frame_pointer = 0xDEAD0000,
        .stack_pointer = 0,
    }, stack);
    try testing.expectEqual(@as(usize, 1), report.return_address_count);
    try testing.expect(report.trace_truncated);

    // A misaligned in-range frame pointer is equally rejected.
    report.return_address_count = 0;
    report.trace_truncated = false;
    walkSavedFrames(&report, .{
        .program_counter = 0x1000,
        .frame_pointer = @intFromPtr(stack.usable().ptr) + 3,
        .stack_pointer = 0,
    }, stack);
    try testing.expectEqual(@as(usize, 1), report.return_address_count);
    try testing.expect(report.trace_truncated);
}

test "CrashReport: frame walk follows a synthetic record chain to the root terminator" {
    var pool = stack_pool_module.StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();
    const stack = try pool.acquire();
    defer pool.release(stack);

    // Build three ascending frame records on the real stack mapping,
    // ending in the {fp: 0, ra: 0} root terminator the kernel guarantees.
    const usable_bytes = stack.usable();
    const base = std.mem.alignForward(usize, @intFromPtr(usable_bytes.ptr) + 512, 16);
    const inner: *[2]usize = @ptrFromInt(base);
    const middle: *[2]usize = @ptrFromInt(base + 64);
    const root: *[2]usize = @ptrFromInt(base + 128);
    inner.* = .{ base + 64, 0xAAA0 };
    middle.* = .{ base + 128, 0xBBB0 };
    root.* = .{ 0, 0 };

    var report = CrashReport{
        .pid_bits = 0,
        .reason = .killed,
        .state_at_death = .waiting,
        .mailbox_depth_at_death = 0,
        .trace_status = .captured,
        .suspend_program_counter = 0,
        .suspend_frame_pointer = 0,
        .return_address_buffer = undefined,
        .return_address_count = 0,
        .trace_truncated = false,
    };
    walkSavedFrames(&report, .{
        .program_counter = 0x9990,
        .frame_pointer = base,
        .stack_pointer = base,
    }, stack);

    try testing.expect(!report.trace_truncated);
    const trace = report.trace();
    try testing.expectEqual(@as(usize, 3), trace.len);
    try testing.expectEqual(@as(usize, 0x9991), trace[0]);
    try testing.expectEqual(@as(usize, 0xAAA0), trace[1]);
    try testing.expectEqual(@as(usize, 0xBBB0), trace[2]);
}
