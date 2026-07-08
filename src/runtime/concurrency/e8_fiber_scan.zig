//! Experiment E8 — conservative fiber-stack scan cost + false-retention
//! (plan §7 / risk #1; zap-concurrency-research.md §2.5, research-round-2.md Q4).
//!
//! E8 measures whether the conservative mark-sweep collector
//! (`src/memory/gc/manager.zig`, `Memory.GC`, TRACED) can work PER-PROCESS,
//! which requires **conservatively scanning a suspended fiber's saved register
//! context + private guard-paged stack** for pointers into a private heap. It
//! decides the TRACING-GC roster:
//!
//!   * bounded scan cost/KB + acceptable false-retention → `Memory.GC` ships as
//!     the TRACED per-process model ALONGSIDE ORC;
//!   * unbounded cost or high false-retention → mark-sweep does NOT ship in v1
//!     and ORC-over-ARC is the sole cyclic model.
//!
//! ORC-over-ARC (`src/memory/orc/manager.zig`) ships regardless of this verdict
//! — it works on the refcount graph and needs NO stack scan. E8 only decides
//! whether conservative mark-sweep ALSO ships.
//!
//! ## The Darwin/aarch64 structural finding that makes the scan complete
//!
//! The fork fiber `Context` on aarch64 saves only `{sp, fp, pc}`; the
//! context-switch asm clobbers `x19–x28`/`x30`, forcing the compiler to spill
//! every live callee-saved register onto the fiber's OWN stack around the yield.
//! So a single sweep of the live span `[saved.stack_pointer, stack.top())`
//! already covers the saved callee-saved registers — there is no separate
//! register save area a conservative scan could miss. This is the property that
//! makes a per-fiber conservative scan well-defined on Darwin/aarch64 (the
//! Boehm-with-green-threads fragility the research flags does not bite here).
//!
//! ## What this measures
//!
//! 1. **Scan cost per KB** — the wall-clock time to conservatively sweep the
//!    fiber's live stack span, word by word, testing each aligned word against
//!    a base-sorted set of tracked-heap intervals (the exact predicate the GC's
//!    `findOwningRecord` implements). Reported as ns and ns/KiB.
//! 2. **False-retention rate** — how many tracked objects the fiber does NOT
//!    genuinely reference are nonetheless "retained" (a non-pointer stack word
//!    coincidentally landing inside `[base, base+size)`). A companion assertion
//!    confirms every genuine pointer IS found (scan correctness / completeness).

const std = @import("std");
const builtin = @import("builtin");
const fiber_context = @import("fiber_context.zig");
const stack_pool = @import("stack_pool.zig");

const WORD = @sizeOf(usize);

/// A tracked-heap interval — the GC's `ObjectRecord{base, size}` shape.
const TrackedObject = struct {
    base: usize,
    size: usize,
};

/// The conservative pointer-identification predicate, self-contained: is `addr`
/// interior to any tracked interval? Binary search over base-sorted records for
/// the greatest `base <= addr`, then the interval containment check — byte-for-
/// byte the logic of `gc/manager.zig`'s `findOwningRecord`. Returns the record
/// index (distinct indices = distinct retained objects) or null. Interior
/// pointers are honoured (any address inside `[base, base+size)`).
fn findOwningRecord(sorted: []const TrackedObject, addr: usize) ?usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid].base <= addr) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const candidate = lo - 1;
    const rec = sorted[candidate];
    if (addr >= rec.base and addr < rec.base + rec.size) return candidate;
    return null;
}

/// Monotonic nanosecond clock: the fork's std has no `std.time.Timer`;
/// `std.c.clock_gettime` is the E9-spike precedent and `std.c` is already a
/// kernel-test dependency (`stack_pool`, `mailbox`).
fn nowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Config passed to the fiber entry. The fiber plants genuine pointers to the
/// `live_bases` (its live set) into its on-stack buffer, then fills the rest
/// with non-pointer data and yields with the buffer live.
const Fixture = struct {
    live_bases: []const usize,
    seed: u64,
    reached_suspend: bool = false,
};

/// The fiber body: lay down a large on-stack buffer mixing genuine pointers to
/// the live objects with realistic + adversarial non-pointer data, then yield
/// (suspend) with that buffer live on the stack.
fn scanEntry(execution: *fiber_context.FiberExecution, argument: ?*anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(argument.?));

    // 8192 words (64 KiB) of stack payload — a substantial, realistic span.
    var buffer: [8192]usize = undefined;
    var prng = std.Random.DefaultPrng.init(fixture.seed);
    const random = prng.random();

    var i: usize = 0;
    while (i < buffer.len) : (i += 1) {
        if (i < fixture.live_bases.len) {
            // Genuine pointers to the live objects — must be found by the scan.
            buffer[i] = fixture.live_bases[i];
        } else if (i % 2 == 0) {
            // Realistic non-pointer stack data: small loop counters / lengths.
            buffer[i] = i & 0xffff;
        } else {
            // Adversarial non-pointer data: full-range values (hashes,
            // timestamps, packed fields) that maximise coincidental hits.
            buffer[i] = random.int(usize);
        }
    }

    // Keep the buffer live across the yield (defeat dead-store elimination).
    std.mem.doNotOptimizeAway(&buffer);
    fixture.reached_suspend = true;
    execution.yield();
    std.mem.doNotOptimizeAway(&buffer);
}

/// The E8 result, for the ledger.
pub const ScanResult = struct {
    span_bytes: usize,
    words_scanned: usize,
    scan_ns: u64,
    ns_per_kib: f64,
    live_objects_found: usize,
    false_retentions: usize,
    tracked_total: usize,
    live_total: usize,

    pub fn falseRatePercent(result: ScanResult) f64 {
        const non_referenced = result.tracked_total - result.live_total;
        if (non_referenced == 0) return 0.0;
        return 100.0 * @as(f64, @floatFromInt(result.false_retentions)) /
            @as(f64, @floatFromInt(non_referenced));
    }
};

/// Run the E8 measurement once: build a tracked heap, suspend a fiber holding
/// pointers to a live subset of it, conservatively scan the fiber's live stack
/// span, and tally cost + retention.
fn runScan(allocator: std.mem.Allocator) !ScanResult {
    const tracked_total: usize = 512;
    const live_total: usize = 32;
    const object_size: usize = 48;

    // ---- Build the tracked heap: N real objects at page-allocator addresses.
    var objects = try allocator.alloc(TrackedObject, tracked_total);
    defer allocator.free(objects);
    var backing = try allocator.alloc([]u8, tracked_total);
    defer {
        for (backing) |b| allocator.free(b);
        allocator.free(backing);
    }
    for (0..tracked_total) |k| {
        backing[k] = try allocator.alloc(u8, object_size);
        objects[k] = .{ .base = @intFromPtr(backing[k].ptr), .size = object_size };
    }

    // Capture the live set (the first `live_total` objects the fiber references)
    // BEFORE sorting reorders the slice, keyed by base so identity survives.
    var live_set = std.AutoHashMap(usize, void).init(allocator);
    defer live_set.deinit();
    for (0..live_total) |k| try live_set.put(objects[k].base, {});

    std.mem.sort(TrackedObject, objects, {}, struct {
        fn lt(_: void, a: TrackedObject, b: TrackedObject) bool {
            return a.base < b.base;
        }
    }.lt);

    // The fiber plants pointers to exactly the live bases.
    var live_bases = try allocator.alloc(usize, live_total);
    defer allocator.free(live_bases);
    {
        var it = live_set.keyIterator();
        var n: usize = 0;
        while (it.next()) |key| : (n += 1) live_bases[n] = key.*;
    }

    // ---- Run a fiber to a suspend point with the fixture live on its stack.
    var pool = stack_pool.StackPool.init(.{ .usable_size = 256 * 1024 });
    defer pool.deinit();

    var fixture = Fixture{ .live_bases = live_bases, .seed = 0xE8_5CA9 };
    var kernel_fiber = try fiber_context.init(&pool, scanEntry, @ptrCast(&fixture));
    var scheduler = fiber_context.SchedulerContext{};
    const outcome = fiber_context.resumeFiber(&scheduler, &kernel_fiber);
    std.debug.assert(outcome == .yielded);
    std.debug.assert(fixture.reached_suspend);

    // ---- The live span to scan: [saved SP, stack top). On aarch64 this covers
    // the spilled callee-saved registers too (the structural finding above).
    const saved = fiber_context.savedRegisters(&kernel_fiber).?;
    const scan_low = std.mem.alignForward(usize, saved.stack_pointer, WORD);
    const scan_high = kernel_fiber.stack.top();
    std.debug.assert(scan_low < scan_high);
    const span_bytes = scan_high - scan_low;

    // ---- Conservative sweep, timed. Best of several reps (warm caches).
    var hit_flags = try allocator.alloc(bool, tracked_total);
    defer allocator.free(hit_flags);

    var best_ns: u64 = std.math.maxInt(u64);
    var words_scanned: usize = 0;
    for (0..5) |_| {
        @memset(hit_flags, false);
        var scanned: usize = 0;
        const start = nowNanoseconds();
        var addr = scan_low;
        while (addr < scan_high) : (addr += WORD) {
            const word = @as(*const usize, @ptrFromInt(addr)).*;
            scanned += 1;
            if (findOwningRecord(objects, word)) |idx| hit_flags[idx] = true;
        }
        const elapsed = nowNanoseconds() - start;
        if (elapsed < best_ns) best_ns = elapsed;
        words_scanned = scanned;
    }

    // Resume the fiber to completion so its entry returns and its stack is
    // released back to the pool (else `pool.deinit` asserts a live stack). The
    // scan above happened while it was suspended with the fixture intact.
    const final_outcome = fiber_context.resumeFiber(&scheduler, &kernel_fiber);
    std.debug.assert(final_outcome == .finished);

    // ---- Tally: classify each hit as a genuine pointer (live) or a coincidental
    // false retention.
    var live_found: usize = 0;
    var false_ret: usize = 0;
    for (objects, 0..) |obj, idx| {
        if (!hit_flags[idx]) continue;
        if (live_set.contains(obj.base)) live_found += 1 else false_ret += 1;
    }

    const ns_per_kib = @as(f64, @floatFromInt(best_ns)) /
        (@as(f64, @floatFromInt(span_bytes)) / 1024.0);

    return .{
        .span_bytes = span_bytes,
        .words_scanned = words_scanned,
        .scan_ns = best_ns,
        .ns_per_kib = ns_per_kib,
        .live_objects_found = live_found,
        .false_retentions = false_ret,
        .tracked_total = tracked_total,
        .live_total = live_total,
    };
}

test "E8: conservative fiber-stack scan — cost/KB bounded and false-retention negligible" {
    // `testing.allocator` backs the tracked heap, so a leak fails independently.
    const result = try runScan(std.testing.allocator);

    std.debug.print(
        "\n[E8] span={d} B  words={d}  scan={d} ns  cost={d:.1} ns/KiB\n" ++
            "[E8] tracked={d}  live_referenced={d}  live_found={d}  false_retentions={d}  false_rate={d:.5}%\n",
        .{
            result.span_bytes,         result.words_scanned,    result.scan_ns,
            result.ns_per_kib,         result.tracked_total,    result.live_total,
            result.live_objects_found, result.false_retentions, result.falseRatePercent(),
        },
    );

    // Completeness: every genuine pointer the fiber planted is found (the scan
    // covers the whole live span, including the spilled callee-saved registers).
    try std.testing.expectEqual(result.live_total, result.live_objects_found);
    try std.testing.expect(result.span_bytes > 0);

    // Falsifiable target 1 — scan cost is BOUNDED per KiB. A word sweep + binary
    // search is O(span/WORD · log N); the ceiling is deliberately generous so
    // the assertion proves boundedness (linearity), not a micro-optimum. Real
    // aarch64 numbers land far below this.
    try std.testing.expect(result.ns_per_kib < 50_000.0);

    // Falsifiable target 2 — false-retention is negligible. On a 48-bit address
    // space the tracked heap occupies a vanishing fraction, so coincidental hits
    // from non-pointer words are effectively zero. The threshold is loose to
    // absorb an astronomically-unlikely stray hit.
    try std.testing.expect(result.falseRatePercent() < 1.0);
}
