//! Expect-panic tests for the concurrency kernel's invariant-enforcing
//! panic guards.
//!
//! Two guard families are pinned here.
//!
//! Four guards protect the fiber-stack-lifetime invariant and the fiber
//! lifecycle state machine by panicking in (all but one case) every
//! build mode:
//!
//! 1. `fiber_context.resumeFiber` — resuming a fiber that is not
//!    resumable (running/finished/reclaimed);
//! 2. `fiber_context.reclaimWithoutResume` — reclaiming a fiber that has
//!    not provably left its stack (running/finished/reclaimed);
//! 3. `StackPool.release` — releasing the stack the caller is currently
//!    executing on (the frame-address backstop);
//! 4. `StackPool.assertNotAlreadyCached` — double release (Debug-only by
//!    design: it rides the poison-on-release machinery).
//!
//! Five guards pin the signal-delivery OOM posture (plan item 7.5,
//! P7-J1): signal delivery is GUARANTEED-OR-PANIC — an allocation
//! failure on any signal-delivery path must panic with a diagnostic
//! naming the failed allocation, never silently drop the signal (a
//! dropped exit/`DOWN` converts memory pressure into an unbounded
//! supervision hang — the S1 class). Each scenario injects an OOM
//! through a production seam (the payload seam returning null, or a
//! failing backing allocator under the envelope pool / signal-node
//! pool) and asserts the child dies with the exact diagnostic exported
//! by `scheduler.zig`:
//!
//! 5. exit-signal propagation at teardown — payload-block OOM
//!    (`pushSignalMessage`, trapped `{'EXIT', …}` delivery);
//! 6. monitor `DOWN` delivery at teardown — payload-block OOM
//!    (`pushSignalMessage`, `deliverDownTo`);
//! 7. signal-envelope OOM (`pushSignalMessage`, the sender's envelope
//!    handle cannot grow);
//! 8. link-set node OOM (`signalLink` — a silently unestablished link
//!    forfeits exit propagation);
//! 9. monitor-set node OOM (`signalMonitor` — a silently uninstalled
//!    monitor never fires its `DOWN`).
//!
//! A panic cannot be observed in-process (the kernel's panics abort), so
//! each guard is pinned through a CHILD process: the parent test
//! re-executes its own test binary with `ZAP_PANIC_GUARD_SCENARIO` set,
//! and the child runs the matching scenario — which must die with the
//! guard's exact panic message on stderr. If a guard is ever removed,
//! the child either survives or dies with a different message, and the
//! parent test fails.
//!
//! ## Dispatch discipline (how a child finds its scenario)
//!
//! Every guard test checks the environment variable FIRST: in a child it
//! either runs the matching scenario (and never returns) or passes
//! instantly, so the child reaches its target scenario no matter where
//! the test runner ordered these tests — preceding kernel tests simply
//! run and pass. This file is referenced first from `concurrency.zig`'s
//! test block so the guard tests sit at the front of the suite and a
//! child pays effectively no prefix cost; that placement is a speed
//! optimization, not a correctness requirement.
//!
//! ## Toolchain
//!
//! The scenarios resume fibers, so the kernel-wide fork-compiler
//! requirement for optimized builds applies (see `concurrency.zig`).
//! The harness itself is OS-gated exactly like the scheduler's parking
//! futex (Darwin + Linux); other OSes skip.

const std = @import("std");
const builtin = @import("builtin");
const fiber_context = @import("fiber_context.zig");
const stack_pool = @import("stack_pool.zig");
const scheduler_module = @import("scheduler.zig");
const scheduler_pool_module = @import("scheduler_pool.zig");
const process_module = @import("process.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const signal_module = @import("signal.zig");

const testing = std.testing;

const StackPool = stack_pool.StackPool;
const SchedulerPool = scheduler_pool_module.SchedulerPool;
const ProcessContext = scheduler_module.ProcessContext;
const PidTable = pid_table_module.PidTable;
const Pid = pid_table_module.Pid;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const SignalRuntime = signal_module.SignalRuntime;
const SignalPayload = signal_module.SignalPayload;

/// Environment variable selecting the scenario a guard CHILD process
/// runs. Unset in the parent test run.
const scenario_environment_variable = "ZAP_PANIC_GUARD_SCENARIO";

/// Upper bound on one guard child's lifetime. A healthy child dies in
/// well under a second (it panics at its first guard test); the bound
/// only exists so a hypothetical guard-removed hang fails loudly instead
/// of wedging the suite.
const child_timeout_seconds = 120;

/// Cap on collected child stderr. A guard child's stderr is a panic
/// message plus a stack trace (a few KiB); the cap only bounds the
/// pathological case.
const child_stderr_limit_bytes = 4 * 1024 * 1024;

/// The pinned guard scenarios. Tag names are the environment-variable
/// vocabulary.
const GuardScenario = enum {
    resume_after_finish,
    reclaim_running_fiber,
    release_from_own_stack,
    double_release,
    signal_exit_payload_oom,
    signal_down_payload_oom,
    signal_envelope_oom,
    signal_link_node_oom,
    signal_monitor_node_oom,
};

/// Whether this OS can run the child-process harness (same support set
/// as the scheduler's parking futex).
const harness_supported = builtin.os.tag.isDarwin() or builtin.os.tag == .linux;

// -- guard tests ----------------------------------------------------------------

test "PanicGuard: resumeFiber panics on a finished (reclaimed) fiber in every build mode" {
    try expectGuardPanic(
        .resume_after_finish,
        "resumeFiber: fiber is not resumable (running, finished, or reclaimed)",
    );
}

test "PanicGuard: reclaimWithoutResume panics on a running fiber in every build mode" {
    try expectGuardPanic(
        .reclaim_running_fiber,
        "reclaimWithoutResume: fiber is not reclaimable without resume (running, finished, or reclaimed)",
    );
}

test "PanicGuard: StackPool.release panics when called from a frame on the released stack" {
    try expectGuardPanic(
        .release_from_own_stack,
        "StackPool.release called from a frame on the stack being released",
    );
}

test "PanicGuard: StackPool double release panics under the Debug poison machinery" {
    // The double-release guard (`assertNotAlreadyCached`) rides the
    // poison-on-release machinery, which is Debug-only BY DESIGN
    // (`stack_pool.zig`): optimized builds do not walk the free list on
    // release. Skip where the guard structurally does not exist.
    if (!stack_pool.poison_on_release) return error.SkipZigTest;
    try expectGuardPanic(.double_release, "StackPool: stack released twice");
}

test "PanicGuard: exit-signal propagation payload OOM panics instead of dropping the signal (plan 7.5)" {
    try expectGuardPanic(
        .signal_exit_payload_oom,
        scheduler_module.signal_payload_oom_panic_message,
    );
}

test "PanicGuard: monitor DOWN delivery payload OOM panics instead of dropping the signal (plan 7.5)" {
    try expectGuardPanic(
        .signal_down_payload_oom,
        scheduler_module.signal_payload_oom_panic_message,
    );
}

test "PanicGuard: signal-envelope OOM panics instead of dropping the signal (plan 7.5)" {
    try expectGuardPanic(
        .signal_envelope_oom,
        scheduler_module.signal_envelope_oom_panic_message,
    );
}

test "PanicGuard: link-set node OOM panics instead of silently forfeiting exit propagation (plan 7.5)" {
    try expectGuardPanic(
        .signal_link_node_oom,
        scheduler_module.link_node_oom_panic_message,
    );
}

test "PanicGuard: monitor-set node OOM panics instead of silently disarming the DOWN (plan 7.5)" {
    try expectGuardPanic(
        .signal_monitor_node_oom,
        scheduler_module.monitor_node_oom_panic_message,
    );
}

// -- scenario bodies (run in the CHILD; each must panic) --------------------------

fn noopEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    _ = execution;
    _ = argument;
}

fn reclaimSelfEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    _ = argument;
    // The fiber is `.running` — reclaiming it now would release the very
    // stack this frame executes on. The guard must panic.
    fiber_context.reclaimWithoutResume(execution.kernel_fiber);
}

fn releaseOwnStackEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    const pool: *StackPool = @ptrCast(@alignCast(argument.?));
    // Smuggled-pool self-release: fiber-side code bypassing the kernel
    // API. The frame-address backstop must panic in every build mode.
    pool.release(execution.kernel_fiber.stack);
}

// -- signal-delivery OOM scenarios (plan item 7.5) ---------------------------------

/// An allocator whose every allocation fails — the OOM injector for the
/// pool-backed signal-delivery allocation paths (envelope pages and
/// signal-set node blocks). Resize/remap refuse and free is a no-op, so
/// it is a well-formed `std.mem.Allocator` that simply has no memory.
const failing_backing_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &failing_backing_allocator_vtable,
};

const failing_backing_allocator_vtable = std.mem.Allocator.VTable{
    .alloc = failingAlloc,
    .resize = failingResize,
    .remap = failingRemap,
    .free = failingFree,
};

fn failingAlloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return null;
}

fn failingResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn failingRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn failingFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

/// A payload seam whose `allocate` always reports exhaustion — the OOM
/// injector for the exit/`DOWN` payload-block path (`pushSignalMessage`
/// allocates through exactly this production seam).
const failing_payload_seam = signal_module.PayloadSeam{
    .context = null,
    .allocate = failingPayloadAllocate,
    .free = null,
};

fn failingPayloadAllocate(_: ?*anyopaque, _: usize) callconv(.c) ?[*]u8 {
    return null;
}

/// A working page-backed payload seam for the scenarios whose injected
/// failure lies elsewhere (envelope / node-pool OOM) — the payload leg
/// must succeed so the scenario reaches its intended allocation site.
const page_payload_seam = signal_module.PayloadSeam{
    .context = null,
    .allocate = pagePayloadAllocate,
    .free = pagePayloadFree,
};

fn pagePayloadAllocate(_: ?*anyopaque, byte_length: usize) callconv(.c) ?[*]u8 {
    const slice = std.heap.page_allocator.alignedAlloc(u8, .of(SignalPayload), byte_length) catch return null;
    return slice.ptr;
}

fn pagePayloadFree(_: ?*anyopaque, body: [*]const u8, byte_length: usize) callconv(.c) void {
    const raw: [*]align(@alignOf(SignalPayload)) u8 = @alignCast(@constCast(body));
    std.heap.page_allocator.free(raw[0..byte_length]);
}

/// A no-op per-process manager for the scenario processes (their bodies
/// allocate nothing from the process heap) — the same shape
/// `signal_stress.zig` uses.
const NoOpManager = struct {
    fn managerContext() process_module.ManagerContext {
        return .{ .manager_state = null, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
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

/// What the watcher process does once it resolves the target's pid —
/// selects which signal-delivery allocation site the scenario drives
/// into its injected OOM.
const SignalOomWatcherAction = enum {
    /// Trap exits, link the target, then kill it with an abnormal exit
    /// signal: the target's teardown must deliver a trapped
    /// `{'EXIT', …}` through `pushSignalMessage` (the payload leg).
    trap_link_then_exit_signal,
    /// Monitor the target, then kill it with an abnormal exit signal:
    /// the target's teardown must deliver a `DOWN` through
    /// `pushSignalMessage` (payload or envelope leg, per the wiring).
    monitor_then_exit_signal,
    /// Just link a live target — drives `signalLink`'s node allocation.
    link_only,
    /// Just monitor a live target — drives `signalMonitor`'s node
    /// allocation.
    monitor_only,
};

/// State shared between the scenario's two processes.
const SignalOomShared = struct {
    /// The target's raw pid bits, published by the target at startup.
    target_pid_bits: std.atomic.Value(u64) = .init(0),
    /// The watcher's selected action.
    action: SignalOomWatcherAction,
};

/// An arbitrary non-zero abnormal reason term for the scenarios (the
/// kernel treats reason terms as opaque).
const signal_oom_reason_term: u64 = 0xBEEF;

/// Bound on the watcher's signal wait in the guard-REMOVED (red) state:
/// with the drop behavior back, no signal ever arrives, and the timed
/// wait lets the child quiesce and reach the trailing
/// "guard was removed" panic instead of hanging to the harness timeout.
const signal_oom_wait_nanoseconds: u64 = 200 * std.time.ns_per_ms;

/// The target: publish its pid, then park in `receive` until the
/// watcher's exit signal tears it down (the call never returns).
fn signalOomTargetBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const shared: *SignalOomShared = @ptrCast(@alignCast(argument.?));
    shared.target_pid_bits.store(context.selfPid().toBits(), .release);
    _ = context.receive();
}

/// The watcher: resolve the target's pid, then run the scenario action.
/// Under the pinned guards the injected OOM panics inside the action (or
/// inside the target's subsequent teardown propagation); if the guard
/// were removed, every branch still terminates so the child quiesces and
/// fails through the trailing "guard was removed" panic.
fn signalOomWatcherBody(context: *ProcessContext, argument: ?*anyopaque) void {
    const shared: *SignalOomShared = @ptrCast(@alignCast(argument.?));
    var target_bits = shared.target_pid_bits.load(.acquire);
    while (target_bits == 0) {
        context.yieldNow();
        target_bits = shared.target_pid_bits.load(.acquire);
    }
    const target = Pid.fromBits(target_bits);
    switch (shared.action) {
        .trap_link_then_exit_signal => {
            _ = context.setTrapExit(true);
            _ = context.link(target);
            _ = context.exitSignal(target, .abnormal, signal_oom_reason_term);
            _ = context.awaitSignalTimeout(signal_oom_wait_nanoseconds);
        },
        .monitor_then_exit_signal => {
            _ = context.monitor(target);
            _ = context.exitSignal(target, .abnormal, signal_oom_reason_term);
            _ = context.awaitSignalTimeout(signal_oom_wait_nanoseconds);
        },
        .link_only => {
            _ = context.link(target);
            // Reached only if the node-OOM guard were removed: unblock
            // the parked target so the child run quiesces and fails
            // through the trailing "guard was removed" panic.
            _ = context.killUntrappable(target);
        },
        .monitor_only => {
            _ = context.monitor(target);
            _ = context.killUntrappable(target);
        },
    }
}

/// Run one signal-delivery OOM scenario on a real two-core scheduler
/// pool: a parked target and a watcher whose action drives the injected
/// allocation failure. `signal_node_backing` backs the signal-node pool,
/// `envelope_backing` backs the envelope pool, and `payload_seam` is the
/// signal runtime's payload seam — each scenario injects its OOM through
/// exactly one of them and keeps the others functional.
fn runSignalOomScenario(
    action: SignalOomWatcherAction,
    signal_node_backing: std.mem.Allocator,
    envelope_backing: std.mem.Allocator,
    payload_seam: signal_module.PayloadSeam,
) void {
    const structure_allocator = std.heap.page_allocator;

    var pid_table = PidTable.init(structure_allocator, .{ .capacity = 256 }) catch
        @panic("panic-guard harness: pid table init failed");
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(envelope_backing, .{});
    defer envelope_pool.deinit();

    var signal_runtime = SignalRuntime.init(signal_node_backing);
    defer signal_runtime.deinit();
    signal_runtime.payload_seam = payload_seam;
    signal_runtime.reason_atoms.set(0xA1, 0xA2, 0xA3);

    var shared = SignalOomShared{ .action = action };

    var pool: SchedulerPool = undefined;
    SchedulerPool.init(&pool, structure_allocator, &pid_table, &envelope_pool, .{
        .scheduler_count = 2,
        .core_options = .{ .signal_runtime = &signal_runtime },
    }) catch @panic("panic-guard harness: scheduler pool init failed");
    defer pool.deinit();

    _ = pool.primaryCore().spawn(.{
        .entry = signalOomTargetBody,
        .argument = &shared,
        .manager = NoOpManager.managerContext(),
        .model = .refcounted,
    }) catch @panic("panic-guard harness: target spawn failed");
    _ = pool.primaryCore().spawn(.{
        .entry = signalOomWatcherBody,
        .argument = &shared,
        .manager = NoOpManager.managerContext(),
        .model = .refcounted,
    }) catch @panic("panic-guard harness: watcher spawn failed");

    pool.runUntilQuiescent();
}

/// Run the panicking shape of `scenario`. Never returns normally: either
/// the guard under test panics (expected) or the trailing panic reports
/// the guard as missing — with a message the parent's fragment assertion
/// will NOT match, so the removal still fails the test.
fn runGuardScenario(scenario: GuardScenario) void {
    switch (scenario) {
        .resume_after_finish => {
            var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
            var kernel_fiber = fiber_context.init(&pool, noopEntry, null) catch
                @panic("panic-guard harness: stack acquisition failed");
            var scheduler = fiber_context.SchedulerContext{};
            if (fiber_context.resumeFiber(&scheduler, &kernel_fiber) != .finished) {
                @panic("panic-guard harness: fiber did not run to completion");
            }
            // `.reclaimed` now — resuming again must hit the entry guard.
            _ = fiber_context.resumeFiber(&scheduler, &kernel_fiber);
        },
        .reclaim_running_fiber => {
            var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
            var kernel_fiber = fiber_context.init(&pool, reclaimSelfEntry, null) catch
                @panic("panic-guard harness: stack acquisition failed");
            var scheduler = fiber_context.SchedulerContext{};
            _ = fiber_context.resumeFiber(&scheduler, &kernel_fiber);
        },
        .release_from_own_stack => {
            var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
            var kernel_fiber = fiber_context.init(&pool, releaseOwnStackEntry, &pool) catch
                @panic("panic-guard harness: stack acquisition failed");
            var scheduler = fiber_context.SchedulerContext{};
            _ = fiber_context.resumeFiber(&scheduler, &kernel_fiber);
        },
        .double_release => {
            var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
            const stack = pool.acquire() catch
                @panic("panic-guard harness: stack acquisition failed");
            pool.release(stack);
            pool.release(stack);
        },
        // Signal-delivery OOM guards (plan item 7.5): each wires exactly
        // one injected-OOM leg — everything else functional — so the
        // panic under test is the only reachable failure.
        .signal_exit_payload_oom => runSignalOomScenario(
            .trap_link_then_exit_signal,
            std.heap.page_allocator,
            std.heap.page_allocator,
            failing_payload_seam,
        ),
        .signal_down_payload_oom => runSignalOomScenario(
            .monitor_then_exit_signal,
            std.heap.page_allocator,
            std.heap.page_allocator,
            failing_payload_seam,
        ),
        .signal_envelope_oom => runSignalOomScenario(
            .monitor_then_exit_signal,
            std.heap.page_allocator,
            failing_backing_allocator,
            page_payload_seam,
        ),
        .signal_link_node_oom => runSignalOomScenario(
            .link_only,
            failing_backing_allocator,
            std.heap.page_allocator,
            page_payload_seam,
        ),
        .signal_monitor_node_oom => runSignalOomScenario(
            .monitor_only,
            failing_backing_allocator,
            std.heap.page_allocator,
            page_payload_seam,
        ),
    }
    @panic("panic-guard scenario ran to completion — the guard under test was removed");
}

// -- harness ---------------------------------------------------------------------

/// Parent side: spawn a guard child for `scenario` and assert it died
/// with `expected_panic_fragment` on stderr. Child side: run the
/// matching scenario (never returns) or pass through for a different
/// scenario's child.
fn expectGuardPanic(scenario: GuardScenario, expected_panic_fragment: []const u8) !void {
    if (selectedChildScenario()) |active_scenario| {
        if (active_scenario == scenario) runGuardScenario(scenario);
        return;
    }
    if (comptime !harness_supported) return error.SkipZigTest;

    var self_exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe_path = try selfExecutablePath(&self_exe_buffer);

    var child_environ_map = try inheritedEnvironMap(testing.allocator);
    defer child_environ_map.deinit();
    try child_environ_map.put(scenario_environment_variable, @tagName(scenario));

    const run_result = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{self_exe_path},
        .environ_map = &child_environ_map,
        .stderr_limit = .limited(child_stderr_limit_bytes),
        .stdout_limit = .limited(child_stderr_limit_bytes),
        .timeout = .{ .duration = .{
            .raw = .fromSeconds(child_timeout_seconds),
            .clock = .awake,
        } },
    });
    defer testing.allocator.free(run_result.stdout);
    defer testing.allocator.free(run_result.stderr);

    const child_died_abnormally = switch (run_result.term) {
        .exited => |exit_code| exit_code != 0,
        .signal, .stopped, .unknown => true,
    };
    const stderr_names_the_guard =
        std.mem.indexOf(u8, run_result.stderr, expected_panic_fragment) != null;

    if (!child_died_abnormally or !stderr_names_the_guard) {
        std.debug.print(
            "guard scenario '{t}' did not die with the expected panic\n" ++
                "  term: {any}\n" ++
                "  expected stderr fragment: \"{s}\"\n" ++
                "  child stderr:\n{s}\n",
            .{ scenario, run_result.term, expected_panic_fragment, run_result.stderr },
        );
        return error.GuardPanicMissing;
    }
}

/// The scenario selected for this process by the guard environment
/// variable, or null when this process is a parent test run.
fn selectedChildScenario() ?GuardScenario {
    const raw_value = std.c.getenv(scenario_environment_variable) orelse return null;
    const value_slice = std.mem.span(raw_value);
    return std.meta.stringToEnum(GuardScenario, value_slice) orelse
        @panic("unrecognized ZAP_PANIC_GUARD_SCENARIO value");
}

/// Absolute path of the currently running test binary, for self-exec.
/// OS-gated like the scheduler's parking futex; unsupported OSes never
/// reach this (the caller skips first).
fn selfExecutablePath(buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        var buffer_length: u32 = @intCast(buffer.len);
        if (std.c._NSGetExecutablePath(buffer, &buffer_length) != 0) {
            return error.SelfExePathTooLong;
        }
        return std.mem.sliceTo(buffer, 0);
    }
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const readlink_result = linux.readlink("/proc/self/exe", buffer, buffer.len);
        if (linux.E.init(readlink_result) != .SUCCESS) return error.SelfExePathUnavailable;
        return buffer[0..readlink_result];
    }
    comptime unreachable; // harness_supported gates the callers
}

/// A copy of this process's environment as an `Environ.Map` the caller
/// may extend (the spawn API replaces the child environment wholesale;
/// there is no inherit-plus-add option). Reads the libc `environ` block —
/// the same libc dependency `adversarial_stress.zig`'s knob already has.
fn inheritedEnvironMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var environ_map = std.process.Environ.Map.init(allocator);
    errdefer environ_map.deinit();
    var environ_cursor = std.c.environ;
    while (environ_cursor[0]) |entry| : (environ_cursor += 1) {
        const entry_span = std.mem.span(entry);
        const equals_index = std.mem.indexOfScalar(u8, entry_span, '=') orelse continue;
        try environ_map.put(entry_span[0..equals_index], entry_span[equals_index + 1 ..]);
    }
    return environ_map;
}
