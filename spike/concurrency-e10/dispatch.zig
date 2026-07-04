//! E10 spike benchmark (concurrency campaign, job S0.4).
//!
//! THROWAWAY SPIKE CODE — see README.md. Quantifies the hot-path cost of
//! allocation *dispatch* to validate the manager-monomorphization hybrid
//! (`zap-concurrency-research.md` §2.3): hot allocating paths must be
//! monomorphized; cold paths may dispatch through the process's manager
//! vtable. The allocator under test is a few-instruction bump allocator over
//! a pre-reserved, never-growing buffer (reset on exhaustion) — the same
//! cost class as Zap's real alloc fast path. The SAME allocation function
//! body is reached through three call mechanisms:
//!
//!   1. `inlined` — comptime-known allocator, callee inlined at the call
//!      site (today's-Zap monomorphized shape).
//!   2. `direct`  — the same function behind `noinline`, direct call
//!      (isolates call overhead from inlining loss).
//!   3. `vtable`  — load the process pointer from a threadlocal (simulating
//!      `current_process()`), load the manager vtable pointer from the
//!      process, load the alloc fn pointer from the vtable, indirect call —
//!      the §2.3 cold-path dispatch shape.
//!
//! Two workload shapes: `pure` (Shape A — tight loop of 16-byte allocations,
//! maximally dispatch-sensitive) and `mix` (Shape B — allocate 32-byte nodes,
//! write 3 fields each, build 8-node lists, traverse, discard: dispatch
//! diluted by real work).
//!
//! A decoy second manager (selectable at runtime via argv, never selected in
//! recorded runs) makes the vtable and fn-pointer loads non-constant so LLVM
//! cannot devirtualize the indirect call. Asm verification of all six timed
//! loops is recorded in README.md.
//!
//! Build (FIXED fork compiler from S0.3, clobber-translation fix `74c0b87fe5`):
//!   ~/projects/zig/zig-out/bin/zig build-exe --zig-lib-dir ~/projects/zig/lib \
//!       -OReleaseFast -femit-asm=dispatch.s dispatch.zig
//! Run (one measurement at a time, `uptime` recorded before each):
//!   ./dispatch <pure|mix> <inlined|direct|vtable> [ops] [reps] [manager]

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Shape = enum { pure, mix };
const Variant = enum { inlined, direct, vtable };

const default_op_count = 100_000_000;
const default_repetitions = 5;

/// Pre-reserved bump buffer. 1 MiB keeps the working set L2-resident so the
/// measurement stays about dispatch cost, not memory bandwidth; at the
/// default op counts the buffer wraps thousands of times per rep (resets are
/// asserted after the timed region) and never grows.
const buffer_capacity: usize = 1 << 20;

/// Shape A allocation size (tight 16-byte allocations).
const pure_alloc_size: usize = 16;

/// Shape B node: three written fields (`next`, `value`, `tag`).
const Node = struct {
    next: ?*Node,
    value: u64,
    tag: u32,
};

/// Shape B allocation size, rounded up so every bump offset stays 16-aligned.
const node_alloc_size: usize = std.mem.alignForward(usize, @sizeOf(Node), 16);

/// Shape B builds (and then discards) lists of this many nodes per iteration.
const nodes_per_list: usize = 8;

/// Io-independent monotonic nanosecond clock (CLOCK_UPTIME_RAW), same
/// convention as the E1/E9 spikes.
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// --------------------------------------------------------------------------
// The allocation function under test (one body, three call mechanisms)
// --------------------------------------------------------------------------

const BumpState = struct {
    buffer: [*]u8,
    capacity: usize,
    offset: usize,
    reset_count: usize,
};

/// The single global manager state all three variants allocate from. The
/// monomorphized variants reach it by comptime-known address (today's-Zap
/// shape: the manager is a statically-known singleton); the vtable variant
/// reaches the same state through the process's `*anyopaque` manager context.
var bump_state: BumpState = undefined;

/// The few-instruction allocation hot path shared verbatim by all three call
/// variants: limit check with reset-on-exhaustion (the buffer never grows),
/// bump, return. This is the cost class of Zap's real alloc fast path.
inline fn bumpAllocBody(state: *BumpState, size: usize) [*]u8 {
    var offset = state.offset;
    if (offset + size > state.capacity) {
        offset = 0;
        state.reset_count += 1;
    }
    state.offset = offset + size;
    return state.buffer + offset;
}

/// Variant 2 callee: the same allocation function forced out-of-line.
noinline fn bumpAllocOutlined(state: *BumpState, size: usize) [*]u8 {
    return bumpAllocBody(state, size);
}

/// Variant 3 callee: the same allocation function behind the manager-vtable
/// ABI signature (opaque context pointer, runtime size).
fn bumpAllocVtable(context: *anyopaque, size: usize) [*]u8 {
    const state: *BumpState = @ptrCast(@alignCast(context));
    return bumpAllocBody(state, size);
}

// --------------------------------------------------------------------------
// Process / manager-vtable plumbing (the §2.3 cold-path dispatch shape)
// --------------------------------------------------------------------------

const ManagerVTable = struct {
    alloc: *const fn (context: *anyopaque, size: usize) [*]u8,
};

/// Stand-in for the process control block: carries the manager context and
/// vtable pointer, exactly the fields the plan puts on the PCB (§2.3 point 3:
/// "resolve once at spawn, then indirect-call").
const Process = struct {
    manager_context: *anyopaque,
    manager_vtable: *const ManagerVTable,
};

/// Simulates the runtime's `current_process()` lookup: the scheduler thread's
/// current process, read through a threadlocal on every dispatch.
threadlocal var current_process: *Process = undefined;

/// Decoy-manager observable side effect (printed after the timed region so
/// the decoy path cannot be discarded).
var decoy_alloc_count: usize = 0;

/// Decoy second manager: a genuinely different alloc function, registered in
/// a second vtable that argv can select at runtime. Its existence makes both
/// the vtable pointer and the fn pointer non-provable constants, so LLVM
/// cannot devirtualize the benchmarked indirect call. Never selected in
/// recorded measurement runs.
fn decoyCountingAllocVtable(context: *anyopaque, size: usize) [*]u8 {
    decoy_alloc_count += 1;
    const state: *BumpState = @ptrCast(@alignCast(context));
    return bumpAllocBody(state, size);
}

const bump_manager_vtable: ManagerVTable = .{ .alloc = bumpAllocVtable };
const decoy_manager_vtable: ManagerVTable = .{ .alloc = decoyCountingAllocVtable };

var bump_process: Process = undefined;
var decoy_process: Process = undefined;

/// The three call mechanisms under test. `size` is passed at runtime through
/// the outlined/vtable ABIs; at the inlined call site it constant-folds, as
/// it does in real monomorphized Zap code.
inline fn allocDispatch(comptime variant: Variant, size: usize) [*]u8 {
    return switch (variant) {
        .inlined => bumpAllocBody(&bump_state, size),
        .direct => bumpAllocOutlined(&bump_state, size),
        .vtable => blk: {
            const process = current_process;
            break :blk process.manager_vtable.alloc(process.manager_context, size);
        },
    };
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

/// Shape A — pure alloc loop: N 16-byte allocations, nothing else. Each
/// returned pointer is sunk through an empty register-constraint asm so the
/// allocation cannot be elided (and the loop cannot be vectorized/collapsed).
inline fn pureLoop(comptime variant: Variant, op_count: usize) Sample {
    const start_ns = nowNanoseconds();
    var index: usize = 0;
    while (index < op_count) : (index += 1) {
        const allocation = allocDispatch(variant, pure_alloc_size);
        std.mem.doNotOptimizeAway(@intFromPtr(allocation));
    }
    return .{ .total_ns = nowNanoseconds() - start_ns, .alloc_count = op_count };
}

/// Shape B — realistic mix: build an 8-node singly-linked list (one dispatch
/// per node, three field writes each), traverse it accumulating a checksum,
/// discard it (bump memory is reclaimed by the periodic reset, arena-style).
/// Dispatch cost is diluted by real pointer-chasing work.
inline fn mixLoop(comptime variant: Variant, op_count: usize) Sample {
    var checksum: u64 = 0;
    const start_ns = nowNanoseconds();
    var allocated: usize = 0;
    var iteration: u64 = 0;
    while (allocated < op_count) : (iteration += 1) {
        var head: ?*Node = null;
        var node_index: u64 = 0;
        while (node_index < nodes_per_list) : (node_index += 1) {
            const node: *Node = @ptrCast(@alignCast(allocDispatch(variant, node_alloc_size)));
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
// symbol in the emitted asm for the README's inlining/indirection evidence.
noinline fn runPureInlined(op_count: usize) Sample {
    return pureLoop(.inlined, op_count);
}
noinline fn runPureDirect(op_count: usize) Sample {
    return pureLoop(.direct, op_count);
}
noinline fn runPureVtable(op_count: usize) Sample {
    return pureLoop(.vtable, op_count);
}
noinline fn runMixInlined(op_count: usize) Sample {
    return mixLoop(.inlined, op_count);
}
noinline fn runMixDirect(op_count: usize) Sample {
    return mixLoop(.direct, op_count);
}
noinline fn runMixVtable(op_count: usize) Sample {
    return mixLoop(.vtable, op_count);
}

fn runBenchmark(shape: Shape, variant: Variant, op_count: usize) Sample {
    return switch (shape) {
        .pure => switch (variant) {
            .inlined => runPureInlined(op_count),
            .direct => runPureDirect(op_count),
            .vtable => runPureVtable(op_count),
        },
        .mix => switch (variant) {
            .inlined => runMixInlined(op_count),
            .direct => runMixDirect(op_count),
            .vtable => runMixVtable(op_count),
        },
    };
}

fn usageAndExit() noreturn {
    std.debug.print(
        "usage: dispatch <pure|mix> <inlined|direct|vtable> [ops] [reps] [manager(0|1)]\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // `Init.Minimal` hands over argv without start.zig constructing an
    // implicit Io instance — this spike uses no Io at all.
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
    // Runtime manager selection (default 0 = the real bump manager). The mere
    // possibility of selecting the decoy defeats devirtualization; recorded
    // runs always use manager 0.
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
    bump_process = .{
        .manager_context = @ptrCast(&bump_state),
        .manager_vtable = &bump_manager_vtable,
    };
    decoy_process = .{
        .manager_context = @ptrCast(&bump_state),
        .manager_vtable = &decoy_manager_vtable,
    };
    current_process = switch (manager_index) {
        0 => &bump_process,
        1 => &decoy_process,
        else => usageAndExit(),
    };

    std.debug.print(
        "bench shape={s} variant={s} ops={d} reps={d} manager={d} buffer_bytes={d} alloc_bytes={d}\n",
        .{
            @tagName(shape),                       @tagName(variant), op_count, repetitions,
            manager_index,                         buffer_capacity,
            switch (shape) {
                .pure => pure_alloc_size,
                .mix => node_alloc_size,
            },
        },
    );

    // Warmup: one unrecorded pass at a tenth of the workload (covers the
    // buffer many times over, so every reset path and page is hot).
    _ = runBenchmark(shape, variant, @max(op_count / 10, 1_000_000));

    var per_alloc_samples: [64]f64 = undefined;
    std.debug.assert(repetitions <= per_alloc_samples.len);
    for (0..repetitions) |rep| {
        const resets_before = bump_state.reset_count;
        const sample = runBenchmark(shape, variant, op_count);
        // Prove the allocator really cycled during the timed region (the
        // default workload wraps the 1 MiB buffer thousands of times).
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
