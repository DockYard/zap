//! Kernel fiber lifecycle over the fork's `std.Io.fiber` context-switch
//! primitive.
//!
//! Phase 1 item 1.1 of `docs/concurrency-implementation-plan.md` (job
//! P1-J1). This module owns create / resume / yield / finish for kernel
//! fibers and is the ONLY place a fiber stack returns to its pool. It
//! builds directly on `std.Io.fiber.Context`/`contextSwitch` (the substrate
//! chosen by the Appendix A scheduler decision) with the same stack layout
//! and naked entry trampoline the fork's `Io/Dispatch.zig` and the E9
//! measurement spike (`spike/concurrency-e9/fiber_switch.zig`) use:
//! an entry frame at the top of the stack, a naked trampoline that forwards
//! the stack pointer as the first parameter, and `fp = 0` to terminate
//! frame-pointer walks.
//!
//! ## The fiber-stack-lifetime invariant (structural enforcement)
//!
//! From the G2 triage of the Dispatch backend's fiber-lifetime race
//! (`spike/concurrency-e1/triage/README.md`, plan Appendix A.4 item 4):
//! **a finished fiber's stack may not be freed or recycled until the
//! finishing fiber has provably left it.** The Dispatch bug freed a fiber
//! allocation from `await` while the finishing task was still executing
//! `yield`/`contextSwitch` on that fiber's stack.
//!
//! This module makes the invariant impossible to violate through its API:
//!
//! * A fiber cannot release its own stack. The entry function returns into
//!   `fiberMain`, whose final act is marking the fiber `.finished` and
//!   switching AWAY to the scheduler context. No release path is reachable
//!   from fiber-side code (`FiberExecution` exposes only `yield`), and
//!   `StackPool.release` independently panics if called from a frame that
//!   lives inside the stack being released.
//! * The stack is released to its pool ONLY by scheduler-side code, and
//!   only once the fiber has provably left it. There are exactly two
//!   release sites: `resumeFiber`'s post-switch path (the FINISH path —
//!   strictly AFTER the finishing fiber's final context switch has
//!   returned control to the scheduler, i.e. after the finishing fiber
//!   has provably left the stack: its cpu state was saved by that final
//!   switch and will never be restored) and `reclaimWithoutResume` (the
//!   KILL path, P1-J4 — legal only for `.ready` fibers, whose stack no
//!   code has ever touched, and `.suspended` fibers, whose cpu state was
//!   saved by their last yield switch and, by that call's contract, is
//!   never restored).
//!
//! Phase 1 runs a single scheduler; the same discipline extends to Phase 4
//! multicore because a fiber is owned by exactly one scheduler at a time,
//! so the resume-observes-finish edge and the release always happen on the
//! owning scheduler's thread.
//!
//! ## Fiber roots are unwind-safe
//!
//! Native stack unwinds reach fiber roots routinely — Debug-allocator
//! allocation traces, panic reports, the Phase 1.6 crash reporter,
//! external profilers. Two structural properties make that safe:
//!
//! 1. **Termination:** the root frame (`fiberMain`) carries a {fp: 0,
//!    return address: 0} frame record — fp from the initial context, the
//!    return address zeroed by the trampoline (aarch64 `mov x30, xzr`) or
//!    the entry-frame writer (x86_64 return-address slot). Without it the
//!    unwinder walks into a stale "caller" address.
//! 2. **Headroom:** the entry frame sits `stack_top_unwind_headroom`
//!    bytes below the mapping's end, so unwinders that probe memory
//!    around the root frame record stay inside the mapping (see the
//!    constant's doc for the concrete fork-std overread this absorbs —
//!    observed as a SIGSEGV in `MachO.unwindFrameInner` followed by a
//!    self-deadlock of std's segfault handler on the module mutex).
//!
//! ## Toolchain requirement
//!
//! `std.Io.fiber.contextSwitch` declares an aarch64 `.x30` clobber that
//! ONLY the Zap Zig fork at or after commit `6a425dbaeb` (which subsumes
//! `74c0b87fe5`) translates to LLVM's `~{lr}`. Stock Zig 0.16.0 silently
//! drops the clobber, and LLVM then keeps live values in x30 across the
//! switch — every OPTIMIZED build of this module miscompiles (E9 "FORK
//! BUG" section of `docs/concurrency-bench-results.md`). Build the kernel
//! with the fork compiler. The miscompilation canary test in this file
//! fails loudly under an unfixed compiler at ReleaseFast; the `test-kernel`
//! build step runs it in ReleaseFast for exactly that reason.

const std = @import("std");
const builtin = @import("builtin");
const fork_fiber = std.Io.fiber;
const stack_pool = @import("stack_pool.zig");

const StackPool = stack_pool.StackPool;
const Stack = stack_pool.Stack;

comptime {
    if (!fork_fiber.supported) {
        @compileError("the Zap concurrency kernel requires stackful fiber support (aarch64/x86_64/riscv64)");
    }
}

/// A kernel fiber's entry point. Runs on the fiber's own stack; receives
/// the yield capability and the opaque argument passed to `init`.
/// Returning from this function finishes the fiber.
pub const EntryFunction = *const fn (execution: *FiberExecution, argument: ?*anyopaque) void;

/// Lifecycle of a kernel fiber. Transitions are owned by this module:
/// `init` → `.ready`; `resumeFiber` → `.running`; `FiberExecution.yield`
/// → `.suspended`; entry return → `.finished` (set on the fiber's stack,
/// immediately before its final switch away); `resumeFiber`'s post-switch
/// path → `.reclaimed` (stack returned to the pool; terminal).
pub const LifecycleState = enum(u8) {
    /// Created, never resumed. The `KernelFiber` value may still be moved.
    ready,
    /// Executing on its own stack right now.
    running,
    /// Yielded; waiting for the next `resumeFiber`.
    suspended,
    /// Entry function returned; the fiber is executing (or has executed)
    /// its final switch back to the scheduler and will never run again.
    finished,
    /// The scheduler observed `.finished` and released the stack back to
    /// the pool. Terminal.
    reclaimed,
};

/// Outcome of one `resumeFiber` call.
pub const ResumeOutcome = enum {
    /// The fiber suspended via `FiberExecution.yield`; resume it again
    /// later.
    yielded,
    /// The fiber's entry function returned; its stack has been released
    /// back to its pool and the fiber is `.reclaimed`.
    finished,
};

/// Saved scheduler-side cpu state while a fiber runs. One per scheduler
/// quantum driver; lives on the scheduler's stack or in scheduler state,
/// never on a fiber stack.
pub const SchedulerContext = struct {
    /// Where the running fiber's yield/finish switches return to. Filled
    /// by the context switch inside `resumeFiber`.
    resume_context: fork_fiber.Context = undefined,
};

/// The kernel fiber object: cpu context + pooled stack + lifecycle state.
/// Embedded by value in the process control block (`process.zig`).
///
/// MOVE SEMANTICS: the value may be moved freely while `.ready` (the entry
/// frame pointer is written at first resume); from the first `resumeFiber`
/// onward its address must be stable, because the fiber's own stack holds
/// pointers into it across suspensions.
pub const KernelFiber = struct {
    /// Saved cpu state while the fiber is not running.
    switch_context: fork_fiber.Context,
    /// The pooled stack backing this fiber.
    stack: Stack,
    /// Pool the stack was acquired from — the only place it may return to.
    origin_stack_pool: *StackPool,
    /// See `LifecycleState`.
    lifecycle_state: LifecycleState,
    /// Entry point run on the fiber's stack.
    entry_function: EntryFunction,
    /// Opaque argument forwarded to `entry_function`.
    entry_argument: ?*anyopaque,
    /// The scheduler currently (or last) driving this fiber; set by
    /// `resumeFiber` before every switch-in so yield/finish know where to
    /// switch back to.
    scheduler: ?*SchedulerContext,
};

/// The capability handed to a fiber's entry function. Deliberately narrow:
/// fiber-side code can suspend itself, and nothing else — in particular it
/// has no path to the stack pool, which is what makes the stack-lifetime
/// invariant structural (see the module doc).
pub const FiberExecution = struct {
    kernel_fiber: *KernelFiber,

    /// Suspend the calling fiber and return control to the scheduler that
    /// resumed it. `resumeFiber` returns `.yielded` there. When the fiber
    /// is next resumed, this call returns.
    pub fn yield(execution: *FiberExecution) void {
        const kernel_fiber = execution.kernel_fiber;
        std.debug.assert(kernel_fiber.lifecycle_state == .running);
        kernel_fiber.lifecycle_state = .suspended;
        switchOneWay(&kernel_fiber.switch_context, &kernel_fiber.scheduler.?.resume_context);
        // Resumed: resumeFiber restored `.running` before switching in.
        std.debug.assert(kernel_fiber.lifecycle_state == .running);
    }
};

/// Create a kernel fiber: acquire a stack from `pool` and prepare the
/// initial cpu context so the first `resumeFiber` enters `entry_function`
/// on that stack via the naked trampoline. No code runs on the fiber stack
/// until the first resume.
pub fn init(
    pool: *StackPool,
    entry_function: EntryFunction,
    entry_argument: ?*anyopaque,
) stack_pool.AcquireError!KernelFiber {
    const stack = try pool.acquire();
    return .{
        .switch_context = initialContext(stack),
        .stack = stack,
        .origin_stack_pool = pool,
        .lifecycle_state = .ready,
        .entry_function = entry_function,
        .entry_argument = entry_argument,
        .scheduler = null,
    };
}

/// Run `kernel_fiber` until it yields or finishes. Must be called on the
/// scheduler's own stack (never from another fiber in Phase 1).
///
/// This function is the ONLY release site for fiber stacks, and the
/// release happens strictly after the finishing fiber's final context
/// switch has returned control here — the structural enforcement of the
/// stack-lifetime invariant (module doc). The state check on entry is
/// active in all build modes: resuming a `.running`/`.finished`/
/// `.reclaimed` fiber is a scheduler bug that must fail loudly, and the
/// check costs one predictable compare on the resume path.
pub fn resumeFiber(scheduler: *SchedulerContext, kernel_fiber: *KernelFiber) ResumeOutcome {
    switch (kernel_fiber.lifecycle_state) {
        // First resume: pin the KernelFiber address into the entry frame
        // at the top of the fiber stack (see `KernelFiber` move
        // semantics); the naked trampoline forwards that frame to
        // `fiberMain`.
        .ready => writeEntryFrame(kernel_fiber),
        .suspended => {},
        .running, .finished, .reclaimed => @panic(
            "resumeFiber: fiber is not resumable (running, finished, or reclaimed)",
        ),
    }
    kernel_fiber.scheduler = scheduler;
    kernel_fiber.lifecycle_state = .running;
    switchOneWay(&scheduler.resume_context, &kernel_fiber.switch_context);

    // Control is back on the scheduler's stack. The fiber either yielded
    // (state `.suspended`, set on the fiber stack before its switch) or
    // finished (state `.finished`, set as its final act before the switch
    // that brought us here).
    switch (kernel_fiber.lifecycle_state) {
        .suspended => return .yielded,
        .finished => {
            // THE stack-lifetime invariant's release site (module doc):
            // the finishing fiber's cpu state was saved by the switch
            // above and will never be restored — it has provably left the
            // stack, and we are executing on the scheduler's stack, so the
            // release is safe. `StackPool.release` independently re-checks
            // that this frame is not on the released stack.
            kernel_fiber.origin_stack_pool.release(kernel_fiber.stack);
            kernel_fiber.lifecycle_state = .reclaimed;
            return .finished;
        },
        // No fiber-side path switches back while `.running`/`.ready`, and
        // `.reclaimed` is only ever set on this side of the switch.
        .running, .ready, .reclaimed => unreachable,
    }
}

/// Reclaim a fiber that will NEVER be resumed — the kill path (P1-J4,
/// plan item 1.4: exit/crash teardown of a process that is not currently
/// running). Releases the fiber's stack back to its pool and marks the
/// fiber `.reclaimed` (terminal).
///
/// Legal ONLY for:
///
/// * `.ready` fibers — no code has ever executed on the stack (the entry
///   frame is not even written until the first resume), so nothing can
///   still be "on" it; and
/// * `.suspended` fibers — the fiber's cpu state was saved by its last
///   yield's context switch, and because this call's contract is that the
///   fiber is never resumed, that state is never restored: the fiber has
///   provably left the stack, which is exactly the stack-lifetime
///   invariant's release condition (module doc). The abandoned frames on
///   the stack are NOT unwound — kernel teardown reclaims process-owned
///   resources through the drop-list and the manager's wholesale free
///   (plan §5.3), never through stack unwinding.
///
/// `.running` is forbidden (the caller would be releasing a stack that is
/// executing — precisely the Dispatch-backend bug the invariant exists to
/// prevent; `StackPool.release` independently panics on it), `.finished`
/// is forbidden (the finish path's release belongs to `resumeFiber`, which
/// always runs it before returning), and `.reclaimed` is a double release.
/// All are kernel bugs and panic in every build mode.
pub fn reclaimWithoutResume(kernel_fiber: *KernelFiber) void {
    switch (kernel_fiber.lifecycle_state) {
        .ready, .suspended => {},
        .running, .finished, .reclaimed => @panic(
            "reclaimWithoutResume: fiber is not reclaimable without resume (running, finished, or reclaimed)",
        ),
    }
    kernel_fiber.origin_stack_pool.release(kernel_fiber.stack);
    kernel_fiber.lifecycle_state = .reclaimed;
}

// ---------------------------------------------------------------------------
// Stack layout, entry trampoline, and context-switch plumbing.
// ---------------------------------------------------------------------------

/// Placed near the top of every fiber stack (16-byte aligned, below the
/// unwind headroom; the fiber's frames grow downward from it) — the same
/// layout `Io/Dispatch.zig` uses for its `AsyncClosure` and the E9 spike
/// for its `FiberArgs`. Written on the FIRST resume so the `KernelFiber`
/// value may move while `.ready`.
const EntryFrame = extern struct {
    kernel_fiber: *KernelFiber,
};

/// ABI-required stack alignment for the entry frame / initial stack
/// pointer (AAPCS64 and x86_64 SysV both require 16).
const entry_frame_alignment = 16;

/// Mapped headroom kept ABOVE the entry frame, inside the stack mapping.
///
/// Unwinders probe memory AROUND a frame record, not only below it, and
/// the fiber root's frame pointer would otherwise sit within a few dozen
/// bytes of the mapping's end. Concretely: the fork std's MachO
/// compact-unwind aarch64 `.FRAME` rule (`lib/std/debug/SelfInfo/
/// MachO.zig`, the `x_reg_pairs` loop) reads saved-register slots
/// ASCENDING from `fp - 8` (`reg_addr += 8`) even though Apple's frame
/// layout stores them DESCENDING below fp (Apple libunwind's
/// `CompactUnwinder_arm64` decrements) — so unwinding a root frame that
/// saves all five x-register pairs reads up to `fp + 0x38`, i.e. past the
/// top of a tightly-mapped stack, and SEGFAULTs the unwinder (after which
/// std's segfault handler self-deadlocks re-entering the module mutex it
/// already holds). The fork's Dispatch backend never faults on this only
/// because its fiber "stack top" has more of the same heap allocation
/// above it.
///
/// That ascending walk is a fork-std bug to be fixed on the fork-hygiene
/// track (it also restores garbage into x19..x28 unwind state on every
/// arm64 FRAME step), but mapped headroom above the root frame is correct
/// kernel design regardless: it keeps ANY unwinder that over-probes the
/// root vicinity — std, libunwind, external profilers sampling fiber
/// stacks — inside the mapping, turning a crash into (at worst) a
/// harmless garbage register in a walk that still terminates at the
/// root's {fp: 0, ra: 0} record. 256 bytes is ~5× the currently-known
/// worst overread and costs 0.1% of the default stack.
const stack_top_unwind_headroom: usize = 256;

/// Address of the entry frame near the top of `stack`, below the unwind
/// headroom.
fn entryFramePointer(stack: Stack) *EntryFrame {
    const frame_address = std.mem.alignBackward(
        usize,
        stack.top() - stack_top_unwind_headroom - @sizeOf(EntryFrame),
        entry_frame_alignment,
    );
    std.debug.assert(frame_address >= @intFromPtr(stack.usable().ptr));
    return @ptrFromInt(frame_address);
}

/// Populate the entry frame for the first switch-in. On x86_64 this also
/// zeroes the return-address slot the trampoline leaves below the frame:
/// `fiberMain`'s frame record must read {fp: 0, ra: 0} so native stack
/// unwinds terminate at the fiber root instead of walking off the stack
/// top (the aarch64 counterpart is the trampoline's `mov x30, xzr`; see
/// `fiberEntryTrampoline`).
fn writeEntryFrame(kernel_fiber: *KernelFiber) void {
    const frame = entryFramePointer(kernel_fiber.stack);
    frame.kernel_fiber = kernel_fiber;
    if (builtin.cpu.arch == .x86_64) {
        const return_address_slot: *usize = @ptrFromInt(@intFromPtr(frame) - 8);
        return_address_slot.* = 0;
    }
}

/// Initial cpu context for a created fiber: pc at the naked trampoline,
/// sp at the entry frame (x86_64 leaves the 8-byte return-address slot the
/// trampoline compensates for), fp zeroed to terminate frame-pointer
/// walks. Mirrors `Io/Dispatch.zig` `concurrent` and the E9 spike.
fn initialContext(stack: Stack) fork_fiber.Context {
    const frame = entryFramePointer(stack);
    return switch (builtin.cpu.arch) {
        .aarch64 => .{
            .sp = @intFromPtr(frame),
            .fp = 0,
            .pc = @intFromPtr(&fiberEntryTrampoline),
        },
        .x86_64 => .{
            .rsp = @intFromPtr(frame) - 8,
            .rbp = 0,
            .rip = @intFromPtr(&fiberEntryTrampoline),
        },
        else => |arch| @compileError("kernel fiber entry trampoline not implemented for " ++ @tagName(arch)),
    };
}

/// First-switch trampoline (mirrors `Io/Dispatch.zig` `AsyncClosure.entry`
/// and the E9 spike's `fiberEntry`): a created fiber's context points here
/// with sp = the entry frame, so the trampoline moves sp into the first
/// parameter register and branches to `fiberMain`; the switch that resumed
/// this fiber leaves its `*const Switch` message in the second parameter
/// register (x1 / rsi).
///
/// The aarch64 trampoline additionally ZEROES the link register. At first
/// entry x30 holds a stale scheduler-side code address (the context switch
/// does not define it), and `fiberMain`'s prologue would store it as this
/// frame's return address — sending every native stack unwind that reaches
/// the fiber root (Debug-allocator allocation traces, panic reports, the
/// Phase 1.6 crash reporter) onward into a bogus "caller" whose unwind
/// rule dereferences the zeroed frame pointer and SEGFAULTS inside the
/// unwinder. With lr = 0, the fiber root's frame record is {fp: 0, ra: 0}
/// and `std.debug.StackIterator` terminates cleanly (`ret_addr <= 1` /
/// fp-sentinel). See `writeEntryFrame` for the x86_64 counterpart.
fn fiberEntryTrampoline() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ mov x30, xzr
            \\ b %[call]
            :
            : [call] "X" (&fiberMain),
        ),
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[call:P]
            :
            : [call] "X" (&fiberMain),
        ),
        else => |arch| @compileError("kernel fiber entry trampoline not implemented for " ++ @tagName(arch)),
    }
}

/// First function executing on a fresh fiber stack. Runs the entry
/// function, then finishes the fiber: marks `.finished` and — as the final
/// act on this stack — switches away to the scheduler. The stack is
/// released by `resumeFiber` AFTER that switch returns control there,
/// never here (the stack-lifetime invariant; module doc).
fn fiberMain(
    frame: *EntryFrame,
    first_message: *const fork_fiber.Switch,
) callconv(.withStackAlign(.c, entry_frame_alignment)) noreturn {
    _ = first_message;
    const kernel_fiber = frame.kernel_fiber;
    var execution = FiberExecution{ .kernel_fiber = kernel_fiber };
    kernel_fiber.entry_function(&execution, kernel_fiber.entry_argument);

    kernel_fiber.lifecycle_state = .finished;
    while (true) {
        // Final act: leave this stack for good. Control re-entering this
        // loop would mean the scheduler resumed a finished fiber —
        // `resumeFiber`'s entry check panics before that can happen; the
        // loop is the last-resort guard (a stray resume re-parks instead
        // of running off the stack into freed memory, matching the E9
        // spike's defensive shape).
        switchOneWay(&kernel_fiber.switch_context, &kernel_fiber.scheduler.?.resume_context);
    }
}

/// One-way switch: save the current cpu state into `save_into` and restore
/// `restore_from`.
inline fn switchOneWay(save_into: *fork_fiber.Context, restore_from: *fork_fiber.Context) void {
    const message: fork_fiber.Switch = .{ .old = save_into, .new = restore_from };
    _ = fork_fiber.contextSwitch(&message);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const CounterProbe = struct {
    entered: bool = false,
    iterations_completed: usize = 0,
    local_accumulator_result: u64 = 0,
    yield_budget: usize,
};

fn countingEntry(execution: *FiberExecution, argument: ?*anyopaque) void {
    const probe: *CounterProbe = @ptrCast(@alignCast(argument.?));
    probe.entered = true;
    // Local state that must survive on the fiber stack across every yield.
    var local_accumulator: u64 = 1;
    var iteration: usize = 0;
    while (iteration < probe.yield_budget) : (iteration += 1) {
        execution.yield();
        local_accumulator = local_accumulator *% 31 +% iteration;
        probe.iterations_completed = iteration + 1;
    }
    probe.local_accumulator_result = local_accumulator;
}

fn expectedCountingAccumulator(yield_budget: usize) u64 {
    var local_accumulator: u64 = 1;
    var iteration: usize = 0;
    while (iteration < yield_budget) : (iteration += 1) {
        local_accumulator = local_accumulator *% 31 +% iteration;
    }
    return local_accumulator;
}

test "FiberContext: run-to-completion fiber finishes and reclaims its stack" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    var probe = CounterProbe{ .yield_budget = 0 };
    var kernel_fiber = try init(&pool, countingEntry, &probe);
    try testing.expectEqual(LifecycleState.ready, kernel_fiber.lifecycle_state);
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_stack_count);

    var scheduler = SchedulerContext{};
    try testing.expectEqual(ResumeOutcome.finished, resumeFiber(&scheduler, &kernel_fiber));
    try testing.expect(probe.entered);
    try testing.expectEqual(LifecycleState.reclaimed, kernel_fiber.lifecycle_state);

    // The stack went back to the pool (released by the scheduler side).
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
    try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
}

test "FiberContext: yield suspends and locals survive across resumes" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    const yield_budget = 5;
    var probe = CounterProbe{ .yield_budget = yield_budget };
    var kernel_fiber = try init(&pool, countingEntry, &probe);
    var scheduler = SchedulerContext{};

    var resume_count: usize = 0;
    while (true) {
        const outcome = resumeFiber(&scheduler, &kernel_fiber);
        resume_count += 1;
        if (outcome == .finished) break;
        try testing.expectEqual(LifecycleState.suspended, kernel_fiber.lifecycle_state);
        // After the k-th yield the fiber has completed k-1 post-yield
        // iterations (it yields at the top of each loop pass).
        try testing.expectEqual(resume_count - 1, probe.iterations_completed);
    }
    // One resume enters the fiber; each of the `yield_budget` yields needs
    // one more.
    try testing.expectEqual(@as(usize, yield_budget + 1), resume_count);
    try testing.expectEqual(@as(usize, yield_budget), probe.iterations_completed);
    // The fiber-stack-resident accumulator survived every switch.
    try testing.expectEqual(expectedCountingAccumulator(yield_budget), probe.local_accumulator_result);
    try testing.expectEqual(LifecycleState.reclaimed, kernel_fiber.lifecycle_state);
}

test "FiberContext: two fibers interleave on one scheduler" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    const yield_budget = 4;
    var first_probe = CounterProbe{ .yield_budget = yield_budget };
    var second_probe = CounterProbe{ .yield_budget = yield_budget };
    var first_fiber = try init(&pool, countingEntry, &first_probe);
    var second_fiber = try init(&pool, countingEntry, &second_probe);
    var scheduler = SchedulerContext{};

    // Strict round-robin until both finish; interleaving must not corrupt
    // either fiber's stack-resident state.
    var first_done = false;
    var second_done = false;
    while (!first_done or !second_done) {
        if (!first_done and resumeFiber(&scheduler, &first_fiber) == .finished) first_done = true;
        if (!second_done and resumeFiber(&scheduler, &second_fiber) == .finished) second_done = true;
    }
    try testing.expectEqual(expectedCountingAccumulator(yield_budget), first_probe.local_accumulator_result);
    try testing.expectEqual(expectedCountingAccumulator(yield_budget), second_probe.local_accumulator_result);
    try testing.expectEqual(@as(u32, 0), pool.statistics().live_stack_count);
}

test "FiberContext: spawn-floor shape — sequential spawns reuse one pooled stack" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    var scheduler = SchedulerContext{};
    var reused_base: ?[*]u8 = null;
    var spawn_index: usize = 0;
    while (spawn_index < 1000) : (spawn_index += 1) {
        var probe = CounterProbe{ .yield_budget = 0 };
        var kernel_fiber = try init(&pool, countingEntry, &probe);
        if (reused_base) |expected_base| {
            // LIFO pool: every spawn after the first reuses the same
            // reservation — the plan A.2.1 "no mmap on the spawn hot
            // path" property, asserted structurally.
            try testing.expectEqual(expected_base, kernel_fiber.stack.mapping.ptr);
        } else {
            reused_base = kernel_fiber.stack.mapping.ptr;
        }
        try testing.expectEqual(ResumeOutcome.finished, resumeFiber(&scheduler, &kernel_fiber));
        try testing.expect(probe.entered);
    }
    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
    try testing.expectEqual(@as(u32, 1), stats.live_stack_peak);
    try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
}

const LifetimeProbe = struct {
    pool: *StackPool,
    sentinel_address: ?usize = null,
    sentinel_length: usize = 0,
    live_count_seen_on_stack: u32 = 0,
    cached_count_seen_on_stack: u32 = 0,
};

const lifetime_sentinel_byte: u8 = 0x5A;

fn lifetimeProbeEntry(execution: *FiberExecution, argument: ?*anyopaque) void {
    _ = execution;
    const probe: *LifetimeProbe = @ptrCast(@alignCast(argument.?));
    // While this code runs on the fiber's stack, the stack must still be
    // live in the pool's accounting (not yet released or cached).
    const stats = probe.pool.statistics();
    probe.live_count_seen_on_stack = stats.live_stack_count;
    probe.cached_count_seen_on_stack = stats.cached_stack_count;

    // Last act on this stack: write a sentinel into a stack-local buffer
    // through a volatile pointer (cannot be elided). Last-writer-wins then
    // proves ordering: if the pool's Debug poison fill (the release-side
    // write) lands AFTER this write — the correct order — the bytes read
    // back as poison once the fiber is reclaimed. If release ran while the
    // fiber was still on its stack (the Dispatch bug), this sentinel would
    // overwrite the poison and remain visible.
    var sentinel_buffer: [64]u8 = undefined;
    const sentinel_pointer: [*]volatile u8 = @ptrCast(&sentinel_buffer);
    for (0..sentinel_buffer.len) |index| sentinel_pointer[index] = lifetime_sentinel_byte;
    probe.sentinel_address = @intFromPtr(&sentinel_buffer);
    probe.sentinel_length = sentinel_buffer.len;
}

test "FiberContext: stack-lifetime invariant — poison lands only after the final switch" {
    if (!stack_pool.poison_on_release) return error.SkipZigTest;

    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    var probe = LifetimeProbe{ .pool = &pool };
    var kernel_fiber = try init(&pool, lifetimeProbeEntry, &probe);
    // Capture the usable range before reclamation invalidates the handle.
    const usable_bytes = kernel_fiber.stack.usable();

    var scheduler = SchedulerContext{};
    try testing.expectEqual(ResumeOutcome.finished, resumeFiber(&scheduler, &kernel_fiber));
    try testing.expectEqual(LifecycleState.reclaimed, kernel_fiber.lifecycle_state);

    // While the fiber body ran on the stack, the stack was still live.
    try testing.expectEqual(@as(u32, 1), probe.live_count_seen_on_stack);
    try testing.expectEqual(@as(u32, 0), probe.cached_count_seen_on_stack);

    // The stack must now be cached (peak 1 → cap = floor 2), so its bytes
    // are still mapped and inspectable.
    try testing.expectEqual(@as(u32, 1), pool.statistics().cached_stack_count);

    // The sentinel the fiber wrote as its final act must have been
    // OVERWRITTEN by the poison fill: poison-after-sentinel proves the
    // release-side write happened after the fiber's last on-stack write,
    // i.e. after the final switch.
    const sentinel_address = probe.sentinel_address.?;
    const usable_start = @intFromPtr(usable_bytes.ptr);
    try testing.expect(sentinel_address >= usable_start);
    try testing.expect(sentinel_address + probe.sentinel_length <= usable_start + usable_bytes.len);
    const sentinel_bytes: [*]const volatile u8 = @ptrFromInt(sentinel_address);
    for (0..probe.sentinel_length) |index| {
        try testing.expectEqual(stack_pool.poison_byte, sentinel_bytes[index]);
    }
}

const UnwindProbe = struct {
    frames_captured: usize = 0,
};

fn unwindProbeEntry(execution: *FiberExecution, argument: ?*anyopaque) void {
    _ = execution;
    const probe: *UnwindProbe = @ptrCast(@alignCast(argument.?));
    // Capture a native stack trace FROM the fiber stack. This pins both
    // unwind-safety properties of the module doc: termination at the
    // fiber root (fiberMain's {fp: 0, ra: 0} frame record) and the mapped
    // headroom above the root frame (`stack_top_unwind_headroom`) that
    // absorbs the std unwinder's over-reads around the record. The
    // capture either returns normally — success — or the unwinder crashes
    // the test loudly (observed pre-fix as SIGSEGV + handler deadlock).
    var address_buffer: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &address_buffer);
    probe.frames_captured = trace.return_addresses.len;
}

test "FiberContext: native stack unwinding terminates at the fiber root" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    var probe = UnwindProbe{};
    var kernel_fiber = try init(&pool, unwindProbeEntry, &probe);
    var scheduler = SchedulerContext{};
    try testing.expectEqual(ResumeOutcome.finished, resumeFiber(&scheduler, &kernel_fiber));

    // Stack tracing may be compiled out (`std.options.allow_stack_tracing`
    // false) — then the capture legitimately returns zero frames and the
    // test only proves the call did not crash. When tracing is on, the
    // walk must have produced at least one frame and stopped on its own.
    if (std.options.allow_stack_tracing) {
        try testing.expect(probe.frames_captured > 0);
        try testing.expect(probe.frames_captured <= 32);
    }
}

test "FiberContext: reclaimWithoutResume releases a never-run fiber's stack" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    var probe = CounterProbe{ .yield_budget = 0 };
    var kernel_fiber = try init(&pool, countingEntry, &probe);
    try testing.expectEqual(LifecycleState.ready, kernel_fiber.lifecycle_state);
    try testing.expectEqual(@as(u32, 1), pool.statistics().live_stack_count);

    // Kill path (P1-J4): the fiber never runs — no code ever touched its
    // stack — so the scheduler may reclaim it directly.
    reclaimWithoutResume(&kernel_fiber);
    try testing.expectEqual(LifecycleState.reclaimed, kernel_fiber.lifecycle_state);
    try testing.expect(!probe.entered);

    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
    try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
}

test "FiberContext: reclaimWithoutResume releases a suspended fiber's stack after its last switch away" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    const yield_budget = 3;
    var probe = CounterProbe{ .yield_budget = yield_budget };
    var kernel_fiber = try init(&pool, countingEntry, &probe);
    var scheduler = SchedulerContext{};

    // Run the fiber into its first suspension: its stack now holds live
    // frames, and its cpu state was saved by the yield's context switch.
    try testing.expectEqual(ResumeOutcome.yielded, resumeFiber(&scheduler, &kernel_fiber));
    try testing.expectEqual(LifecycleState.suspended, kernel_fiber.lifecycle_state);
    try testing.expect(probe.entered);

    // Kill path (P1-J4): the suspended fiber will never be resumed, so it
    // has provably left its stack — the invariant's suspension analogue.
    reclaimWithoutResume(&kernel_fiber);
    try testing.expectEqual(LifecycleState.reclaimed, kernel_fiber.lifecycle_state);
    // The entry function never completed (it was abandoned mid-yield).
    try testing.expect(probe.iterations_completed < yield_budget);

    const stats = pool.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_stack_count);
    try testing.expectEqual(@as(u32, 1), stats.cached_stack_count);
}

// ---------------------------------------------------------------------------
// Miscompilation canary.
//
// Guards against building the kernel with a compiler that silently drops
// the aarch64 `.x30` clobber of `std.Io.fiber.contextSwitch` (stock Zig
// 0.16.0; fixed in the fork at 74c0b87fe5/6a425dbaeb — see the E9 "FORK
// BUG" section of docs/concurrency-bench-results.md). Under such a
// compiler at ReleaseFast, LLVM treats x30 as call-preserved across the
// switch asm; since the asm clobbers every other general-purpose register,
// the register allocator preferentially parks values that live across the
// switch in x30 — and a resumed fiber then observes whatever a DIFFERENT
// context left there (E9 observed fiberMain's argument pointer arriving as
// garbage). This test keeps several values live across many interleaved
// switches between two fibers and checks exact results, so a dropped
// clobber produces a loud checksum mismatch or a crash rather than silent
// corruption. It passes trivially in Debug; the `test-kernel` step runs it
// at ReleaseFast, where it bites.
// ---------------------------------------------------------------------------

const CanaryWorkload = struct {
    salt: u64,
    yield_budget: usize,
    resumes_observed: usize = 0,
    final_checksum: u64 = 0,
};

fn canaryEntry(execution: *FiberExecution, argument: ?*anyopaque) void {
    const workload: *CanaryWorkload = @ptrCast(@alignCast(argument.?));
    // All three of `workload` (a pointer), `local_checksum`, and
    // `remaining` are live across every switch below — prime candidates
    // for x30 under a clobber-dropping compiler.
    var local_checksum: u64 = workload.salt;
    var remaining: usize = workload.yield_budget;
    while (remaining > 0) : (remaining -= 1) {
        execution.yield();
        workload.resumes_observed += 1;
        local_checksum = local_checksum *% 6364136223846793005 +% workload.salt;
    }
    workload.final_checksum = local_checksum;
}

fn expectedCanaryChecksum(salt: u64, yield_budget: usize) u64 {
    var checksum: u64 = salt;
    var remaining: usize = yield_budget;
    while (remaining > 0) : (remaining -= 1) {
        checksum = checksum *% 6364136223846793005 +% salt;
    }
    return checksum;
}

test "FiberContext: miscompilation canary — live values across many switches (x30/lr clobber)" {
    var pool = StackPool.init(.{ .usable_size = 64 * 1024 });
    defer pool.deinit();

    const yield_budget = 10_000;
    var first_workload = CanaryWorkload{ .salt = 0x9E3779B97F4A7C15, .yield_budget = yield_budget };
    var second_workload = CanaryWorkload{ .salt = 0xD1B54A32D192ED03, .yield_budget = yield_budget };
    var first_fiber = try init(&pool, canaryEntry, &first_workload);
    var second_fiber = try init(&pool, canaryEntry, &second_workload);
    var scheduler = SchedulerContext{};

    // Alternate the two fibers so every switch-in restores a context whose
    // registers another fiber's execution has since replaced.
    var first_done = false;
    var second_done = false;
    while (!first_done or !second_done) {
        if (!first_done and resumeFiber(&scheduler, &first_fiber) == .finished) first_done = true;
        if (!second_done and resumeFiber(&scheduler, &second_fiber) == .finished) second_done = true;
    }

    try testing.expectEqual(@as(usize, yield_budget), first_workload.resumes_observed);
    try testing.expectEqual(@as(usize, yield_budget), second_workload.resumes_observed);
    try testing.expectEqual(
        expectedCanaryChecksum(first_workload.salt, yield_budget),
        first_workload.final_checksum,
    );
    try testing.expectEqual(
        expectedCanaryChecksum(second_workload.salt, yield_budget),
        second_workload.final_checksum,
    );
}
