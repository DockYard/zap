//! Expect-panic tests for the concurrency kernel's invariant-enforcing
//! panic guards.
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

const testing = std.testing;

const StackPool = stack_pool.StackPool;

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
