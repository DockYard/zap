//! A.4 OQ1 spike (P3-J1): the cost of resolving the CURRENT-PROCESS private
//! manager context on the per-process allocation hot path.
//!
//! Phase 3 gives every process its OWN ARC manager instance (a private heap),
//! so a `List`/`Map`/box a process allocates must reach THAT process's context.
//! Appendix A.4 OQ1 asks how the hot path should obtain it. This spike prices
//! the same few-instruction bump allocation reached through three resolution
//! mechanisms — the E10 methodology (`spike/concurrency-e10`), reframed from
//! "how to DISPATCH the alloc" to "how to RESOLVE the context the alloc needs":
//!
//!   1. `register`  — the context is resolved ONCE (per scheduling quantum in
//!      the real runtime) and carried in a register/local across the loop; the
//!      alloc reads it for free. This is the ceiling the J2 monomorphization /
//!      parameter-threading arm targets (A.4 rules out a globally reserved
//!      register on aarch64 — x18 is Darwin-reserved — so this stands in for
//!      "resolved once, threaded as a parameter").
//!   2. `published` — the context is read from a PUBLISHED GLOBAL on every
//!      allocation (the P3-J1 ship: the scheduler writes the running process's
//!      context to `zap_proc_active_arc_context` at quantum entry; the runtime
//!      reads it in `currentManagerContext`). Modelled as an atomic-monotonic
//!      load (aarch64 `LDR`, one cycle) so it is not hoisted out of the loop —
//!      exactly what the real cross-TU extern var, reloaded across the opaque
//!      manager call, costs: one load per allocation.
//!   3. `ambient`   — the context is resolved by a `zap_proc_current()`-style
//!      out-of-line call on every allocation (the Phase-2 shape: an extern C
//!      call that checks the runtime-initialized flag, reads the scheduler's
//!      current process, and returns its manager context). One call per alloc.
//!
//! The bump allocation body is byte-identical and inlined in all three, so the
//! ONLY variable is the resolution mechanism — the number this decision turns
//! on. Two shapes as in E10: `pure` (tight alloc, maximally resolution-
//! sensitive) and `mix` (alloc + real pointer-chasing work, resolution cost
//! diluted). A decoy context selectable at runtime via argv keeps the ambient
//! call and the published load non-constant (no const-fold / hoist of the real
//! path); it is never selected in recorded runs (`decoy_allocs=0` proves it).
//!
//! Build + run (fork compiler, ReleaseFast, matching the E10 protocol):
//!
//!   ~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib \
//!       -OReleaseFast -femit-asm=resolve.s resolve.zig
//!   ./resolve <pure|mix> <register|published|ambient> [ops] [reps] [manager]

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Shape = enum { pure, mix };
const Variant = enum { register, published, ambient };

const default_op_count = 100_000_000;
const default_repetitions = 5;

/// Pre-reserved bump buffer. 1 MiB keeps the working set L2-resident so the
/// measurement stays about resolution cost, not memory bandwidth; at the
/// default op counts the buffer wraps thousands of times per rep (resets are
/// asserted after the timed region) and never grows. Same as E10.
const buffer_capacity: usize = 1 << 20;

/// Shape A allocation size (tight 16-byte allocations).
const pure_alloc_size: usize = 16;

/// Shape B node: three written fields.
const Node = struct {
    next: ?*Node,
    value: u64,
    tag: u32,
};

/// Shape B allocation size, 16-aligned.
const node_alloc_size: usize = std.mem.alignForward(usize, @sizeOf(Node), 16);

/// Shape B builds (and then discards) lists of this many nodes per iteration.
const nodes_per_list: usize = 8;

/// Io-independent monotonic nanosecond clock (`CLOCK_UPTIME_RAW`), same
/// convention as the E1/E9/E10 spikes.
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// --------------------------------------------------------------------------
// The allocation body under test (one body; the CONTEXT is resolved three ways)
// --------------------------------------------------------------------------

const BumpState = struct {
    buffer: [*]u8,
    capacity: usize,
    offset: usize,
    reset_count: usize,
};

/// The process's private manager state (the ARC context / slab pool analog).
var bump_state: BumpState = undefined;

/// A second, genuinely-distinct context selectable via argv. Its existence
/// keeps `published_context` and the ambient lookup's process pointer
/// non-provable constants, so the compiler cannot fold the real path away.
/// Never selected in recorded runs.
var decoy_state: BumpState = undefined;
var decoy_alloc_count: usize = 0;

/// The few-instruction allocation hot path shared verbatim by all three
/// resolution variants: limit check with reset-on-exhaustion, bump, return.
/// This is the cost class of Zap's real alloc fast path (the manager's slab
/// bump). Inlined into every variant so only the resolution mechanism differs.
inline fn bumpAllocBody(state: *BumpState, size: usize) [*]u8 {
    var offset = state.offset;
    if (offset + size > state.capacity) {
        offset = 0;
        state.reset_count += 1;
    }
    state.offset = offset + size;
    return state.buffer + offset;
}

// --------------------------------------------------------------------------
// (2) `published` — the P3-J1 mechanism: a scheduler-published global read.
// --------------------------------------------------------------------------

/// Stand-in for `src/runtime/concurrency/process.zig`'s
/// `zap_proc_active_arc_context`: the running process's private context,
/// written by the scheduler at quantum entry and read by the runtime's
/// `currentManagerContext` on every allocation. Read via an atomic-monotonic
/// load so it is not hoisted out of the loop, matching the real cross-TU
/// extern var reloaded across the opaque manager call (one `LDR` per alloc).
var published_context: *BumpState = undefined;

inline fn publishedContext() *BumpState {
    return @atomicLoad(*BumpState, &published_context, .monotonic);
}

// --------------------------------------------------------------------------
// (3) `ambient` — the Phase-2 mechanism: a `zap_proc_current()`-style call.
// --------------------------------------------------------------------------

const Process = struct {
    manager_context: *BumpState,
};

/// The scheduler's current process (the `Scheduler.current_process` analog),
/// selected at setup. Read by the ambient lookup on every alloc.
var ambient_current_process: *Process = undefined;
var ambient_runtime_live: bool = false;

/// Models the runtime's `zap_proc_current()` intrinsic: an out-of-line C-ABI
/// call that checks the runtime-initialized flag, reads the scheduler's
/// current process, and returns its manager context. `noinline` + `callconv(.c)`
/// so it lands as a real, non-inlined call per allocation — the Phase-2 cost.
noinline fn ambientCurrentContext() callconv(.c) *anyopaque {
    if (!ambient_runtime_live) unreachable;
    const process = ambient_current_process;
    return @ptrCast(process.manager_context);
}

// --------------------------------------------------------------------------
// (1) `register` — the ceiling: resolve once, carry across the loop.
// --------------------------------------------------------------------------

/// The "resolve once per scheduling quantum" resolution. Uses the SAME work as
/// the ambient lookup (fairest ceiling: the resolution happens, just once), and
/// the result is then carried in a local/register for the whole loop.
inline fn resolveOncePerQuantum() *BumpState {
    return @ptrCast(@alignCast(ambientCurrentContext()));
}

// --------------------------------------------------------------------------
// Workload shapes
// --------------------------------------------------------------------------

const Sample = struct {
    total_ns: u64,
    alloc_count: usize,

    fn perAllocNs(sample: Sample) f64 {
        return @as(f64, @floatFromInt(sample.total_ns)) /
            @as(f64, @floatFromInt(sample.alloc_count));
    }
};

/// Resolve the per-process context for one allocation under `variant`. For
/// `register` the caller has already hoisted it (passed as `hoisted`); for
/// `published`/`ambient` it is resolved here, per allocation.
inline fn resolveContext(comptime variant: Variant, hoisted: *BumpState) *BumpState {
    return switch (variant) {
        .register => hoisted,
        .published => publishedContext(),
        .ambient => @ptrCast(@alignCast(ambientCurrentContext())),
    };
}

/// Shape A — pure alloc loop: N 16-byte allocations, nothing else. The pointer
/// is sunk through `doNotOptimizeAway` so the allocation cannot be elided.
inline fn pureLoop(comptime variant: Variant, op_count: usize) Sample {
    const hoisted: *BumpState = if (variant == .register) resolveOncePerQuantum() else undefined;
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < op_count) : (index += 1) {
        const context = resolveContext(variant, hoisted);
        const allocation = bumpAllocBody(context, pure_alloc_size);
        std.mem.doNotOptimizeAway(@intFromPtr(allocation));
    }
    return .{ .total_ns = nowNanoseconds() - start_ns, .alloc_count = op_count };
}

/// Shape B — realistic mix: build an 8-node singly-linked list (one alloc per
/// node, three field writes each), traverse it accumulating a checksum, discard
/// it. Resolution cost is diluted by real pointer-chasing work.
inline fn mixLoop(comptime variant: Variant, op_count: usize) Sample {
    const hoisted: *BumpState = if (variant == .register) resolveOncePerQuantum() else undefined;
    var checksum: u64 = 0;
    const start_ns = nowNanoseconds();
    var allocated: usize = 0;
    var iteration: u64 = 0;
    while (allocated < op_count) : (iteration += 1) {
        var head: ?*Node = null;
        var node_index: u64 = 0;
        while (node_index < nodes_per_list) : (node_index += 1) {
            const context = resolveContext(variant, hoisted);
            const node: *Node = @ptrCast(@alignCast(bumpAllocBody(context, node_alloc_size)));
            node.* = .{
                .next = head,
                .value = iteration +% node_index,
                .tag = @truncate(node_index),
            };
            head = node;
        }
        allocated += nodes_per_list;
        var cursor = head;
        while (cursor) |node| : (cursor = node.next) checksum +%= node.value +% node.tag;
    }
    const total_ns = nowNanoseconds() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    if (checksum == 0)
        std.debug.panic("mix checksum is zero: the workload was elided", .{});
    return .{ .total_ns = total_ns, .alloc_count = allocated };
}

// Named noinline wrappers so each shape x variant loop lands under a readable
// symbol in the emitted asm for the README's evidence.
noinline fn runPureRegister(op_count: usize) Sample {
    return pureLoop(.register, op_count);
}
noinline fn runPurePublished(op_count: usize) Sample {
    return pureLoop(.published, op_count);
}
noinline fn runPureAmbient(op_count: usize) Sample {
    return pureLoop(.ambient, op_count);
}
noinline fn runMixRegister(op_count: usize) Sample {
    return mixLoop(.register, op_count);
}
noinline fn runMixPublished(op_count: usize) Sample {
    return mixLoop(.published, op_count);
}
noinline fn runMixAmbient(op_count: usize) Sample {
    return mixLoop(.ambient, op_count);
}

fn runBenchmark(shape: Shape, variant: Variant, op_count: usize) Sample {
    return switch (shape) {
        .pure => switch (variant) {
            .register => runPureRegister(op_count),
            .published => runPurePublished(op_count),
            .ambient => runPureAmbient(op_count),
        },
        .mix => switch (variant) {
            .register => runMixRegister(op_count),
            .published => runMixPublished(op_count),
            .ambient => runMixAmbient(op_count),
        },
    };
}

fn usageAndExit() noreturn {
    std.debug.print(
        "usage: resolve <pure|mix> <register|published|ambient> [ops] [reps] [manager(0|1)]\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args_iterator: std.process.Args.Iterator = .init(init.args);
    _ = args_iterator.next(); // program name

    const shape_arg = args_iterator.next() orelse usageAndExit();
    const shape = std.meta.stringToEnum(Shape, shape_arg) orelse usageAndExit();
    const variant_arg = args_iterator.next() orelse usageAndExit();
    const variant = std.meta.stringToEnum(Variant, variant_arg) orelse usageAndExit();

    const op_count = if (args_iterator.next()) |ops_arg|
        try std.fmt.parseInt(usize, ops_arg, 10)
    else
        default_op_count;
    const repetitions = if (args_iterator.next()) |reps_arg|
        try std.fmt.parseInt(usize, reps_arg, 10)
    else
        default_repetitions;
    // Runtime context selection (default 0 = the real bump context). The mere
    // possibility of selecting the decoy defeats const-folding / hoisting of
    // the real published-load and ambient-call; recorded runs always use 0.
    const manager_index = if (args_iterator.next()) |manager_arg|
        try std.fmt.parseInt(usize, manager_arg, 10)
    else
        0;

    // Pre-reserve the bump buffer once and fault every page in before any
    // timed region; the buffer never grows or remaps during timing.
    const buffer_mapping = try posix.mmap(
        null,
        buffer_capacity,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(buffer_mapping);
    @memset(buffer_mapping, 0);

    bump_state = .{
        .buffer = buffer_mapping.ptr,
        .capacity = buffer_capacity,
        .offset = 0,
        .reset_count = 0,
    };
    // The decoy shares the same backing buffer (it is never selected in
    // recorded runs; it exists only to keep the real path non-constant).
    decoy_state = bump_state;

    const selected: *BumpState = switch (manager_index) {
        0 => &bump_state,
        1 => &decoy_state,
        else => usageAndExit(),
    };
    published_context = selected;
    var process_storage: Process = .{ .manager_context = selected };
    ambient_current_process = &process_storage;
    ambient_runtime_live = true;

    std.debug.print(
        "bench shape={s} variant={s} ops={d} reps={d} manager={d} buffer_bytes={d} alloc_bytes={d}\n",
        .{
            @tagName(shape), @tagName(variant), op_count, repetitions,
            manager_index,   buffer_capacity,
            switch (shape) {
                .pure => pure_alloc_size,
                .mix => node_alloc_size,
            },
        },
    );

    // Warmup: one unrecorded pass at a tenth of the workload.
    _ = runBenchmark(shape, variant, @max(op_count / 10, 1_000_000));

    var per_alloc_samples: [64]f64 = undefined;
    std.debug.assert(repetitions <= per_alloc_samples.len);
    for (0..repetitions) |rep| {
        const resets_before = bump_state.reset_count;
        const sample = runBenchmark(shape, variant, op_count);
        if (bump_state.reset_count <= resets_before)
            std.debug.panic("no buffer resets during rep {d}: allocation was elided", .{rep + 1});
        per_alloc_samples[rep] = sample.perAllocNs();
        std.debug.print(
            "  rep {d}: total_ns={d} allocs={d} per_alloc_ns={d:.3}\n",
            .{ rep + 1, sample.total_ns, sample.alloc_count, sample.perAllocNs() },
        );
    }

    const timed = per_alloc_samples[0..repetitions];
    std.mem.sort(f64, timed, {}, std.sort.asc(f64));
    const median = if (repetitions % 2 == 1)
        timed[repetitions / 2]
    else
        (timed[repetitions / 2 - 1] + timed[repetitions / 2]) / 2.0;
    std.debug.print(
        "RESULT shape={s} variant={s} median_per_alloc_ns={d:.3} min_per_alloc_ns={d:.3} resets={d} decoy_allocs={d}\n",
        .{ @tagName(shape), @tagName(variant), median, timed[0], bump_state.reset_count, decoy_alloc_count },
    );
}
