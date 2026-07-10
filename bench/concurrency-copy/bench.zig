//! E6 copy-crossover benchmark: message-copy latency vs payload size.
//!
//! Phase-2 exit-gate job P2-J9 of `docs/concurrency-implementation-plan.md`
//! (plan item 2.8, "copy-p99-vs-size harness"; the reserved **E6** section
//! of `docs/concurrency-bench-results.md`). It measures the cost of the
//! deep-copy message send the P2-J5 walker realizes as *serialize-to-blob*
//! (`src/runtime.zig`, `serializeMessage`/`deserializeMessage`) — the plan's
//! **two copies** (sender serialize + receiver reconstruct) — as a function
//! of payload size from 64 B to 1 MB, to find the **crossover**: the size at
//! which copy cost stops being negligible against the ~44 ns same-scheduler
//! RTT floor (E1, P1-J6) and starts to dominate. That number drives the
//! Phase-3 prioritization of the `Blob` tier + the O(1) region-move path
//! (risks R4/R5): an early crossover makes them urgent, a late one lets them
//! be deferred.
//!
//! ## What it measures — the REAL walker, not a synthetic memcpy
//!
//! The harness links `src/runtime.zig` (the real runtime) against the real
//! production **ARC manager** (`src/memory/arc/manager.zig`, whose
//! `zap_memory_section` the runtime's weak extern binds), so the values it
//! copies are real refcounted `List`/`Map`/`String` ARC cells
//! (`refcount_v1_active == true`) and the two copies are the exact walker
//! passes `Process.send`/`receive` run:
//!
//!   * **serialize** (`serializeMessage`, Copy A) — walk the source graph,
//!     allocate a flat blob from `c_allocator` (the exact allocator
//!     `send_message` uses), `writeValue` the bytes in;
//!   * **reconstruct** (`deserializeMessage`, Copy C) — allocate FRESH rc=1
//!     ARC cells from the process manager and copy the bytes back out.
//!
//! Per size it reports the round-trip (Copy A + Copy C = the plan's two-copy
//! cost, the E6 metric) as median/min/p99, AND the serialize-vs-reconstruct
//! split (the attribution). It also characterizes, in `clock` mode, the two
//! costs the walker bench deliberately excludes so the ledger can state the
//! full end-to-end picture honestly:
//!
//!   * the harness's own per-op clock-read floor (`CLOCK_UPTIME_RAW` quantizes
//!     to ~42 ns on Apple Silicon — E9), so sub-tick small-size costs are read
//!     off the clock-overhead-free floor (`rt_floor_ns`, the min per-op over
//!     small timed sub-batches), not the sampled median;
//!   * a bare `@memcpy` of the blob (the kernel transport copy, Copy B: the
//!     size-proportional `@memcpy` `zap_proc_send` does into the mailbox
//!     ledger, `src/runtime/concurrency/abi.zig`) — the third size-dependent
//!     memcpy a full send→receive pays on top of the two walker copies, plus
//!     the payload-independent ~44 ns mailbox RTT E1 already measured.
//!
//! ## Protocol (E1/E9/E10 ledger conventions)
//!
//! One measurement at a time, foreground. Timing via `CLOCK_UPTIME_RAW`
//! directly in the harness (never through the walker under test). Per size:
//! an unrecorded warmup, then `reps` (default 7, ≥5 per the ledger) timed
//! repetitions each collecting a per-op latency sample; the samples are
//! pooled across reps and reported as median / min / p99. A separate
//! clock-overhead-free floor (`rt_floor_ns`) times the round trip in small
//! sub-batches and keeps the MIN per-op across every group and rep — the
//! un-preempted group is the true cost the sub-tick small sizes need.
//! Anti-elision:
//! every reconstructed value's element count is asserted (forces the copy to
//! run) and a checksum of touched bytes is `doNotOptimizeAway`n and printed.
//! Record `uptime` immediately before every invocation (the runner's job).
//!
//! ## Substrate honesty note
//!
//! This is the Phase-2 reality: ONE binary-wide ARC instance (plan item 3.1
//! makes managers per-process). The reconstruct path allocates through the
//! production ARC slab pool, so the cell-allocation cost is representative;
//! `String` reconstruction lands in the shared `runtime_arena`, which the
//! harness resets per op (untimed) to keep it bounded.
//!
//! ## Toolchain
//!
//! MUST be compiled with the Zap Zig fork — this bench uses NO fibers, so the
//! fork's x30-clobber fix is not strictly required here, but the fork is the
//! ledger convention for the concurrency series and provides the
//! `std.process.Init.Minimal` entry the E1 bench uses. See README for the
//! exact module-graph build command.

const std = @import("std");
const builtin = @import("builtin");
const zap = @import("zapruntime");

// The REAL production ARC manager is bound as the `zap_active_manager` source
// module with `RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT` rewritten to true (see
// `run-copy-bench.sh`) — the exact binding every compiler-driven user binary
// uses. This replaced the original weak-linker-symbol binding when the
// manager's `zap_memory_section` export became `.Obj`-gated (P3-J3 per-spawn
// managers; docs in `src/memory/arc/manager.zig`): an `.Exe` build like this
// bench no longer emits the symbol, so the source-module DECL binding is the
// one production path.

// -- harness clock (CLOCK_UPTIME_RAW, never through the walker) ------------------------------

/// Io-independent monotonic nanosecond clock (`CLOCK_UPTIME_RAW`), so timing
/// never routes through runtime code under test (E1/E9 convention).
fn nowNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.UPTIME_RAW, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// -- configuration ---------------------------------------------------------------------------

const default_repetition_count: usize = 7;

/// Blob-byte size targets spanning the plan's 64 B → 1 MB range. The actual
/// blob is sized as close to each target as the element grammar allows (each
/// row reports its real blob byte count).
const size_targets = [_]usize{ 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576 };

/// Per-op sample count for one repetition, tiered by blob size so the small
/// sizes get a dense distribution (cheap) while the 1 MB size stays tractable
/// (each op is hundreds of µs). Pooled across reps for the reported p99.
fn sampleCountForBlobBytes(blob_bytes: usize) usize {
    if (blob_bytes <= 1024) return 30_000;
    if (blob_bytes <= 16_384) return 12_000;
    if (blob_bytes <= 65_536) return 5_000;
    if (blob_bytes <= 262_144) return 2_000;
    return 800;
}

/// A pooled latency distribution: the sorted per-op nanosecond samples across
/// every repetition, plus the per-rep medians for a run-to-run stability band.
const Distribution = struct {
    samples: []u64,
    filled: usize = 0,
    rep_medians: [default_repetition_count]u64 = [_]u64{0} ** default_repetition_count,
    rep_count: usize = 0,

    fn push(dist: *Distribution, value: u64) void {
        dist.samples[dist.filled] = value;
        dist.filled += 1;
    }

    /// Close one repetition: record its median from the samples appended
    /// since the previous call (they are not yet globally sorted).
    fn closeRepetition(dist: *Distribution, rep_start: usize) void {
        const rep_slice = dist.samples[rep_start..dist.filled];
        std.mem.sort(u64, rep_slice, {}, std.sort.asc(u64));
        dist.rep_medians[dist.rep_count] = rep_slice[rep_slice.len / 2];
        dist.rep_count += 1;
        // Un-sort is unnecessary: the caller pools every sample and sorts the
        // whole array once at the end, and a per-rep sort does not change the
        // pooled multiset.
    }

    fn median(dist: *Distribution) u64 {
        return dist.samples[0..dist.filled][dist.filled / 2];
    }
    fn min(dist: *Distribution) u64 {
        return dist.samples[0];
    }
    fn max(dist: *Distribution) u64 {
        return dist.samples[dist.filled - 1];
    }
    fn percentile(dist: *Distribution, per_mille: usize) u64 {
        const index = (dist.filled * per_mille) / 1000;
        return dist.samples[@min(index, dist.filled - 1)];
    }
    /// Sort the whole pooled array — call once before reading percentiles.
    fn finalize(dist: *Distribution) void {
        std.mem.sort(u64, dist.samples[0..dist.filled], {}, std.sort.asc(u64));
    }
    fn repMedianSpread(dist: *Distribution) struct { low: u64, high: u64 } {
        var low: u64 = std.math.maxInt(u64);
        var high: u64 = 0;
        for (dist.rep_medians[0..dist.rep_count]) |m| {
            low = @min(low, m);
            high = @max(high, m);
        }
        return .{ .low = low, .high = high };
    }
};

/// Anti-elision accumulator: every measured op folds a touched byte in here,
/// and `main` prints the final value so no serialize/reconstruct can be
/// optimized away as dead.
var elision_sink: u64 = 0;

// ============================================================================================
// Shape drivers
//
// Each shape exposes the same interface to `runOneSize`: build a source value
// of ~`blob_bytes`, report the element count, serialize it (Copy A) into a
// caller-freed `c_allocator` blob, and reconstruct it (Copy C) from a blob
// into a caller-released copy. The three shapes exercise the three walker arms
// that matter for the R4/R5 verdict: flat scalars (cheapest — pure memcpy),
// map entries (hashing on reconstruct), and strings (one arena allocation per
// element on reconstruct — the allocation-heavy worst case).
// ============================================================================================

const ScalarListShape = struct {
    const Cell = zap.List(i64);
    const MessageType = ?*const Cell;

    fn elementsForBlobBytes(blob_bytes: usize) usize {
        // blob = u32 count (4) + n * i64 (8).
        return if (blob_bytes <= 4) 1 else (blob_bytes - 4) / 8;
    }

    fn build(element_count: usize) MessageType {
        var list: MessageType = Cell.new_empty(@intCast(element_count));
        var index: usize = 0;
        while (index < element_count) : (index += 1) {
            list = Cell.push(list, @intCast(index));
        }
        return list;
    }

    fn serialize(source: MessageType) []u8 {
        return zap.serializeMessage(MessageType, source, std.heap.c_allocator) catch
            @panic("e6: serialize out of memory");
    }

    fn reconstruct(blob: []const u8) MessageType {
        return zap.deserializeMessage(MessageType, blob) catch @panic("e6: reconstruct failed");
    }

    fn elementCount(value: MessageType) usize {
        return if (value) |list| list.len else 0;
    }

    fn touch(value: MessageType) u64 {
        if (value) |list| {
            if (list.len == 0) return 0;
            return @bitCast(Cell.get(value, @intCast(list.len / 2)));
        }
        return 0;
    }

    fn release(value: MessageType) void {
        Cell.release(value);
    }
    fn releaseSource(value: MessageType) void {
        Cell.release(value);
    }
    fn resetArena() void {}
};

const IntMapShape = struct {
    const Cell = zap.Map(i64, i64);
    const MessageType = ?*const Cell;

    fn elementsForBlobBytes(blob_bytes: usize) usize {
        // blob = u32 count (4) + n * (i64 key + i64 value = 16).
        return if (blob_bytes <= 4) 1 else (blob_bytes - 4) / 16;
    }

    fn build(entry_count: usize) MessageType {
        var map: MessageType = null;
        var index: usize = 0;
        while (index < entry_count) : (index += 1) {
            map = Cell.put(map, @intCast(index), @intCast(index * 3));
        }
        return map;
    }

    fn serialize(source: MessageType) []u8 {
        return zap.serializeMessage(MessageType, source, std.heap.c_allocator) catch
            @panic("e6: serialize out of memory");
    }

    fn reconstruct(blob: []const u8) MessageType {
        return zap.deserializeMessage(MessageType, blob) catch @panic("e6: reconstruct failed");
    }

    fn elementCount(value: MessageType) usize {
        return if (value) |map| map.len else 0;
    }

    fn touch(value: MessageType) u64 {
        if (value) |map| {
            if (map.len == 0) return 0;
            return @bitCast(Cell.get(value, @intCast(map.len / 2), -1));
        }
        return 0;
    }

    fn release(value: MessageType) void {
        Cell.release(value);
    }
    fn releaseSource(value: MessageType) void {
        Cell.release(value);
    }
    fn resetArena() void {}
};

const StringListShape = struct {
    const Cell = zap.List([]const u8);
    const MessageType = ?*const Cell;

    /// Fixed 16-byte element payload; every source element aliases it (the
    /// copy cost is byte-count driven, not aliasing driven — the walker copies
    /// each element's bytes into the blob on serialize and into a fresh arena
    /// allocation on reconstruct regardless).
    const element_bytes: []const u8 = "zap-msg-16-bytes";

    fn elementsForBlobBytes(blob_bytes: usize) usize {
        // blob = u32 count (4) + n * (u32 length prefix (4) + 16 bytes).
        return if (blob_bytes <= 4) 1 else (blob_bytes - 4) / (4 + element_bytes.len);
    }

    fn build(element_count: usize) MessageType {
        var list: MessageType = Cell.new_empty(@intCast(element_count));
        var index: usize = 0;
        while (index < element_count) : (index += 1) {
            list = Cell.push(list, element_bytes);
        }
        return list;
    }

    fn serialize(source: MessageType) []u8 {
        return zap.serializeMessage(MessageType, source, std.heap.c_allocator) catch
            @panic("e6: serialize out of memory");
    }

    fn reconstruct(blob: []const u8) MessageType {
        return zap.deserializeMessage(MessageType, blob) catch @panic("e6: reconstruct failed");
    }

    fn elementCount(value: MessageType) usize {
        return if (value) |list| list.len else 0;
    }

    fn touch(value: MessageType) u64 {
        if (value) |list| {
            if (list.len == 0) return 0;
            const element = Cell.get(value, @intCast(list.len / 2));
            return if (element.len > 0) element[0] else 0;
        }
        return 0;
    }

    fn release(value: MessageType) void {
        Cell.release(value);
    }
    fn releaseSource(value: MessageType) void {
        Cell.release(value);
    }
    /// Reconstructed strings land in the shared `runtime_arena`; reset it
    /// (retain the backing) so many reconstruct ops do not grow it unbounded.
    /// Untimed — called after the copy and its anti-elision read.
    fn resetArena() void {
        zap.resetAllocator();
    }
};

// -- one (shape, size) measurement -----------------------------------------------------------

fn runOneSize(
    comptime Shape: type,
    shape_name: []const u8,
    harness_allocator: std.mem.Allocator,
    blob_target_bytes: usize,
    repetition_count: usize,
) !void {
    const element_count = Shape.elementsForBlobBytes(blob_target_bytes);
    const source = Shape.build(element_count);
    defer Shape.releaseSource(source);

    // A stable reference blob for the deserialize-only phase, plus the actual
    // blob byte count for the row, plus a fidelity+anti-elision check.
    const reference_blob = Shape.serialize(source);
    defer std.heap.c_allocator.free(reference_blob);
    const blob_bytes = reference_blob.len;

    {
        const check_copy = Shape.reconstruct(reference_blob);
        if (Shape.elementCount(check_copy) != element_count) {
            std.debug.print(
                "e6 FIDELITY FAILED: shape={s} target={d} rebuilt {d} elems, expected {d}\n",
                .{ shape_name, blob_target_bytes, Shape.elementCount(check_copy), element_count },
            );
            return error.CopyFidelityBroken;
        }
        elision_sink +%= Shape.touch(check_copy);
        Shape.release(check_copy);
        Shape.resetArena();
    }

    const sample_count = sampleCountForBlobBytes(blob_bytes);
    const pooled_capacity = sample_count * repetition_count;

    var round_trip = Distribution{ .samples = try harness_allocator.alloc(u64, pooled_capacity) };
    defer harness_allocator.free(round_trip.samples);
    var serialize_only = Distribution{ .samples = try harness_allocator.alloc(u64, pooled_capacity) };
    defer harness_allocator.free(serialize_only.samples);
    var reconstruct_only = Distribution{ .samples = try harness_allocator.alloc(u64, pooled_capacity) };
    defer harness_allocator.free(reconstruct_only.samples);

    // Warmup (unrecorded): one short pass of each phase warms the ARC slab
    // pool, the c_allocator arenas, and the instruction/data caches.
    {
        const warm = @max(sample_count / 10, 64);
        var index: usize = 0;
        while (index < warm) : (index += 1) {
            const blob = Shape.serialize(source);
            const copy = Shape.reconstruct(blob);
            elision_sink +%= Shape.touch(copy);
            Shape.release(copy);
            std.heap.c_allocator.free(blob);
            Shape.resetArena();
        }
    }

    // Clock-overhead-free floor: the round trip is timed in small sub-batches
    // (one clock pair per group), and the MIN per-op across every group and
    // rep is kept. The minimum group is the one that ran without scheduler
    // preemption, so it is the true serialize+reconstruct cost with neither
    // the ~42 ns per-op clock tick (amortized over the group) nor load in it —
    // the load-robust floor the ledger's discipline prescribes, and the number
    // the sub-tick small sizes need (the per-op sampled median cannot resolve
    // below one clock tick).
    const group_size = @min(@as(usize, 512), sample_count);
    var floor_per_op_ns: f64 = std.math.floatMax(f64);

    var rep: usize = 0;
    while (rep < repetition_count) : (rep += 1) {
        // --- per-op sampled: round trip (serialize + reconstruct) ---
        const rt_start = round_trip.filled;
        var index: usize = 0;
        while (index < sample_count) : (index += 1) {
            const t0 = nowNanoseconds();
            const blob = Shape.serialize(source);
            const copy = Shape.reconstruct(blob);
            const t1 = nowNanoseconds();
            round_trip.push(t1 - t0);
            elision_sink +%= Shape.touch(copy);
            Shape.release(copy);
            std.heap.c_allocator.free(blob);
            Shape.resetArena();
        }
        round_trip.closeRepetition(rt_start);

        // --- per-op sampled: serialize only (Copy A) ---
        const ser_start = serialize_only.filled;
        index = 0;
        while (index < sample_count) : (index += 1) {
            const t0 = nowNanoseconds();
            const blob = Shape.serialize(source);
            const t1 = nowNanoseconds();
            serialize_only.push(t1 - t0);
            elision_sink +%= blob[blob.len / 2];
            std.heap.c_allocator.free(blob);
        }
        serialize_only.closeRepetition(ser_start);

        // --- per-op sampled: reconstruct only (Copy C) ---
        const de_start = reconstruct_only.filled;
        index = 0;
        while (index < sample_count) : (index += 1) {
            const t0 = nowNanoseconds();
            const copy = Shape.reconstruct(reference_blob);
            const t1 = nowNanoseconds();
            reconstruct_only.push(t1 - t0);
            elision_sink +%= Shape.touch(copy);
            Shape.release(copy);
            Shape.resetArena();
        }
        reconstruct_only.closeRepetition(de_start);

        // --- clock-overhead-free floor: grouped round trip, keep the min ---
        var group_done: usize = 0;
        while (group_done < sample_count) : (group_done += group_size) {
            const this_group = @min(group_size, sample_count - group_done);
            const group_start = nowNanoseconds();
            var group_index: usize = 0;
            while (group_index < this_group) : (group_index += 1) {
                const blob = Shape.serialize(source);
                const copy = Shape.reconstruct(blob);
                elision_sink +%= Shape.touch(copy);
                Shape.release(copy);
                std.heap.c_allocator.free(blob);
                Shape.resetArena();
            }
            const group_ns = nowNanoseconds() - group_start;
            const per_op = @as(f64, @floatFromInt(group_ns)) / @as(f64, @floatFromInt(this_group));
            floor_per_op_ns = @min(floor_per_op_ns, per_op);
        }
    }

    round_trip.finalize();
    serialize_only.finalize();
    reconstruct_only.finalize();

    const rt_spread = round_trip.repMedianSpread();
    std.debug.print(
        "RESULT shape={s} target={d} blob_bytes={d} elems={d} samples={d}x{d}" ++
            " rt_median_ns={d} rt_min_ns={d} rt_p99_ns={d} rt_p999_ns={d} rt_max_ns={d}" ++
            " rt_repmed_ns={d}..{d} rt_floor_ns={d:.1}" ++
            " ser_median_ns={d} ser_min_ns={d} ser_p99_ns={d}" ++
            " de_median_ns={d} de_min_ns={d} de_p99_ns={d}\n",
        .{
            shape_name,                     blob_target_bytes,
            blob_bytes,                     element_count,
            repetition_count,               sample_count,
            round_trip.median(),            round_trip.min(),
            round_trip.percentile(990),     round_trip.percentile(999),
            round_trip.max(),               rt_spread.low,
            rt_spread.high,                 floor_per_op_ns,
            serialize_only.median(),        serialize_only.min(),
            serialize_only.percentile(990), reconstruct_only.median(),
            reconstruct_only.min(),         reconstruct_only.percentile(990),
        },
    );
}

// -- clock / transport calibration -----------------------------------------------------------

/// Report the harness's per-op clock-read floor and, per size, a bare
/// `@memcpy` of a blob-sized buffer — the kernel transport copy (Copy B) the
/// walker bench excludes. Lets the ledger state the full end-to-end memcpy
/// picture (serialize + transport + reconstruct) without pretending the
/// transport is free.
fn runClockCalibration(harness_allocator: std.mem.Allocator, repetition_count: usize) !void {
    // Empty clock-read cost: time N back-to-back reads, per-op = total/N.
    {
        const iterations: usize = 2_000_000;
        var best: f64 = std.math.floatMax(f64);
        var rep: usize = 0;
        while (rep < repetition_count) : (rep += 1) {
            const t0 = nowNanoseconds();
            var index: usize = 0;
            var acc: u64 = 0;
            while (index < iterations) : (index += 1) acc +%= nowNanoseconds();
            const total = nowNanoseconds() - t0;
            elision_sink +%= acc;
            best = @min(best, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iterations)));
        }
        std.debug.print("RESULT clock read_per_op_ns={d:.2} (per-op sampling floor)\n", .{best});
    }

    // Bare memcpy of each blob size (transport Copy B proxy). Median/min per-op
    // over a batch, both buffers touched to defeat elision.
    for (size_targets) |bytes| {
        const source = try harness_allocator.alloc(u8, bytes);
        defer harness_allocator.free(source);
        const destination = try harness_allocator.alloc(u8, bytes);
        defer harness_allocator.free(destination);
        @memset(source, 0xA5);

        const iterations: usize = if (bytes <= 4096) 200_000 else if (bytes <= 65_536) 40_000 else 4_000;
        var best: f64 = std.math.floatMax(f64);
        var rep: usize = 0;
        while (rep < repetition_count) : (rep += 1) {
            const t0 = nowNanoseconds();
            var index: usize = 0;
            while (index < iterations) : (index += 1) {
                @memcpy(destination, source);
                elision_sink +%= destination[index % bytes];
            }
            const total = nowNanoseconds() - t0;
            best = @min(best, @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iterations)));
        }
        std.debug.print("RESULT transport bytes={d} memcpy_per_op_ns={d:.1}\n", .{ bytes, best });
    }
}

// -- entry -----------------------------------------------------------------------------------

const Mode = enum { list, map, string, clock, all };

fn runShapeSweep(
    comptime Shape: type,
    shape_name: []const u8,
    harness_allocator: std.mem.Allocator,
    repetition_count: usize,
) !void {
    for (size_targets) |target| {
        // The string shape's reconstruct allocates one arena string per
        // element; cap its sweep so wall time stays bounded (the scalar/map
        // sweeps carry the full 64 B–1 MB crossover).
        if (Shape == StringListShape and target > 65_536) continue;
        try runOneSize(Shape, shape_name, harness_allocator, target, repetition_count);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    zap.ensureMemoryStartup();

    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const harness_allocator = debug_allocator.allocator();

    var arguments: std.process.Args.Iterator = .init(init.args);
    _ = arguments.next(); // program name
    const mode_text = arguments.next() orelse "all";
    const mode = std.meta.stringToEnum(Mode, mode_text) orelse {
        std.debug.print("usage: bench <list|map|string|clock|all> [reps]\n", .{});
        return error.UnknownMode;
    };
    const repetition_count = if (arguments.next()) |reps_text|
        try std.fmt.parseInt(usize, reps_text, 10)
    else
        default_repetition_count;
    if (repetition_count == 0 or repetition_count > default_repetition_count) {
        std.debug.print(
            "reps must be in 1..={d} (the per-rep median buffer is fixed at compile time)\n",
            .{default_repetition_count},
        );
        return error.BadRepetitionCount;
    }

    std.debug.print(
        "mode={s} reps={d} build={s} refcount_active={} sizes=64B..1MB\n",
        .{ mode_text, repetition_count, @tagName(builtin.mode), zap.refcount_v1_active },
    );

    switch (mode) {
        .list => try runShapeSweep(ScalarListShape, "list", harness_allocator, repetition_count),
        .map => try runShapeSweep(IntMapShape, "map", harness_allocator, repetition_count),
        .string => try runShapeSweep(StringListShape, "string", harness_allocator, repetition_count),
        .clock => try runClockCalibration(harness_allocator, repetition_count),
        .all => {
            try runClockCalibration(harness_allocator, repetition_count);
            try runShapeSweep(ScalarListShape, "list", harness_allocator, repetition_count);
            try runShapeSweep(IntMapShape, "map", harness_allocator, repetition_count);
            try runShapeSweep(StringListShape, "string", harness_allocator, repetition_count);
        },
    }

    // Anti-elision: print the sink so the optimizer cannot drop any copy.
    std.debug.print("elision_sink={d}\n", .{elision_sink});
    std.mem.doNotOptimizeAway(elision_sink);
}
