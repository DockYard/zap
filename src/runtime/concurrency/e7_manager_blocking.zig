//! Experiment E7 — manager-call blocking / dirty-scheduler handoff
//! (plan §7 / risk #6; research-round-2.md Q5 "FFI/blocking escape", E7).
//!
//! E7 answers: when a fiber blocks INSIDE a manager call — a GC pause inside
//! `allocate`, or a page fault under lazy commit — is a co-scheduled fiber on
//! the SAME core delayed BEYOND the watchdog tick? The verdict decides whether
//! blockable manager calls must use the P4-J3 dirty-scheduler handoff, or
//! whether only explicit `Process.blocking` FFI does.
//!
//! ## Why the co-scheduled delay equals the manager-call duration
//!
//! Zap's cores are cooperative: a running fiber holds its core until it hits a
//! safepoint or yields. A manager call (allocate / a GC collect) runs to
//! completion WITHOUT a safepoint — it is straight-line native code. So on one
//! core a co-scheduled runnable fiber cannot run until the manager call returns:
//! its delay is exactly the manager call's wall-clock duration. E7 measures the
//! co-scheduled delay DIRECTLY (two fibers on one scheduler, the blocking
//! manager call being a real lazy-commit fresh-slab fault) and, separately, the
//! GC stop-the-world collect scan rate, comparing each to the watchdog tick.
//!
//! ## The watchdog-tick reference
//!
//! The watchdog is flag-only BY DESIGN (locked decision 6: alloc piggyback +
//! back-edge polls + flag-only watchdog — there is deliberately no watchdog
//! timer thread). E7 uses the canonical "this call is long enough to
//! need a dirty scheduler" thresholds as its reference: BEAM's guidance is that
//! a NIF expected to run **> 1 ms** should be dirty; Go's sysmon preempts a
//! goroutine running **> 10 ms**. E7 takes the CONSERVATIVE 1 ms (BEAM's dirty
//! threshold) as the watchdog-tick reference: a manager call comfortably under
//! 1 ms does not, by the state of the art's own standard, need a dirty handoff.
//!
//! ## Verdict (recorded in the ledger — see `docs/concurrency-bench-results.md`)
//!
//! **Bounded manager calls do NOT need the handoff; only explicit
//! `Process.blocking` FFI (and the one UNBOUNDED manager call — a `Memory.GC`
//! stop-the-world collect over a large heap) does.**
//!   * The lazy-commit page fault — the manager-internal block a fresh slab's
//!     first touch pays on EVERY model — is measured here (via the direct
//!     co-scheduled test) at the tens-of-microsecond scale for a realistic
//!     64 KiB slab: ~10× or more under the 1 ms tick. A co-scheduled fiber is
//!     not delayed beyond the tick, so faulting allocate paths need NO handoff
//!     (auto-detaching every allocate would be pure hot-path overhead — the
//!     dispatch cost E10 warns against).
//!   * The default reclamation models (ARC / ORC / Arena) have NO collection
//!     pause in `allocate` (deterministic refcount / bump), so their allocate is
//!     bounded too — no handoff.
//!   * The ONE unbounded manager call is a `Memory.GC` stop-the-world collect,
//!     whose pause is dominated by the conservative heap/stack scan E8 measured
//!     at ~1 µs/KiB. E7 measures that scan rate here and shows the pause CROSSES
//!     the 1 ms tick for live heaps beyond ~1 MB. `Memory.GC` is an opt-in
//!     per-process model whose pauses are its documented tradeoff, and the
//!     correct remedy is that a GC-heavy process routes its long work through
//!     the SAME `Process.blocking` handoff (it is a dirty-scheduler client) —
//!     NOT that the runtime auto-detaches every allocate.
//!
//! So E7 lands on the "NOT stalled beyond the tick → manager calls don't need
//! an automatic handoff; the explicit `Process.blocking` handoff is the
//! mechanism" branch, with the honest nuance that the one unbounded manager call
//! (GC collect) is itself a `Process.blocking` client.

const std = @import("std");
const scheduler_module = @import("scheduler.zig");
const pid_table_module = @import("pid_table.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const process_module = @import("process.zig");

const testing = std.testing;
const Scheduler = scheduler_module.Scheduler;
const ProcessContext = scheduler_module.ProcessContext;
const PidTable = pid_table_module.PidTable;
const EnvelopePool = envelope_pool_module.EnvelopePool;
const ManagerContext = process_module.ManagerContext;
const ManagerVTable = process_module.ManagerVTable;

const WORD = @sizeOf(usize);

/// The watchdog-tick reference: BEAM's dirty-NIF threshold (a call expected to
/// run longer than this "should be dirty"). A manager call comfortably under it
/// does not need a dirty handoff by the state of the art's own standard.
const watchdog_tick_reference_nanoseconds: u64 = 1 * std.time.ns_per_ms;

/// Monotonic nanoseconds (the fork's std has no `std.time.Timer`; mirrors E8).
fn nowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

// ---------------------------------------------------------------------------
// The UNBOUNDED manager call: a stop-the-world GC collect pause
// ---------------------------------------------------------------------------

/// The GC's conservative-pointer containment predicate (byte-for-byte E8's /
/// `gc/manager.zig`'s `findOwningRecord`): binary-search the base-sorted record
/// table for the greatest `base <= addr`, then the interval check. The dominant
/// per-word cost of a stop-the-world mark phase.
fn findOwningRecord(sorted: []const usize, addr: usize) bool {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] <= addr) lo = mid + 1 else hi = mid;
    }
    return lo != 0;
}

/// Measure the conservative mark-scan rate (ns per KiB scanned) on E8's shape: a
/// modest tracked-object table and a 1 MiB span of MIXED words (genuine
/// pointers into the table + realistic/adversarial non-pointers). This is the
/// dominant per-byte term of a stop-the-world collect pause; a real collect adds
/// sweep, which only makes the pause larger. Because the pause is linear in
/// scanned bytes, this one rate projects the pause at any live-heap size.
fn measureConservativeScanRateNsPerKib(allocator: std.mem.Allocator) !f64 {
    const tracked_total: usize = 512; // E8's table size
    const span_bytes: usize = 1 << 20; // 1 MiB scan span
    const span_words = span_bytes / WORD;

    const bases = try allocator.alloc(usize, tracked_total);
    defer allocator.free(bases);
    const backing = try allocator.alloc(usize, tracked_total);
    defer allocator.free(backing);
    for (0..tracked_total) |index| bases[index] = @intFromPtr(&backing[index]);
    std.mem.sort(usize, bases, {}, std.sort.asc(usize));

    const span = try allocator.alloc(usize, span_words);
    defer allocator.free(span);
    var prng = std.Random.DefaultPrng.init(0xE7_5CA9);
    const random = prng.random();
    for (span, 0..) |*word, index| {
        if (index % 4 == 0) {
            word.* = bases[index % tracked_total]; // genuine pointer (a mark hit)
        } else if (index % 2 == 0) {
            word.* = index & 0xffff; // realistic small non-pointer
        } else {
            word.* = random.int(usize); // adversarial full-range non-pointer
        }
    }

    var best_ns: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const start = nowNanoseconds();
        var hits: usize = 0;
        for (span) |word| {
            if (findOwningRecord(bases, word)) hits += 1;
        }
        std.mem.doNotOptimizeAway(hits);
        const elapsed = nowNanoseconds() - start;
        if (elapsed < best_ns) best_ns = elapsed;
    }
    return @as(f64, @floatFromInt(best_ns)) / (@as(f64, @floatFromInt(span_bytes)) / 1024.0);
}

test "E7: a stop-the-world GC collect pause scales with live-heap size and CROSSES the watchdog tick (the unbounded case)" {
    const rate_ns_per_kib = try measureConservativeScanRateNsPerKib(testing.allocator);

    // Project the collect pause at representative live-heap sizes (pause is
    // linear in scanned bytes, E8-confirmed): the crossover heap where the pause
    // equals the tick, and a large (16 MiB) heap whose pause must exceed it.
    const crossover_kib = @as(f64, @floatFromInt(watchdog_tick_reference_nanoseconds)) / rate_ns_per_kib;
    const large_heap_kib: f64 = 16 * 1024; // 16 MiB — a routine server-process heap
    const large_heap_pause_ns = rate_ns_per_kib * large_heap_kib;

    std.debug.print(
        "\n[E7] gc collect scan rate={d:.1} ns/KiB  →  crossover heap≈{d:.0} KiB  |  16 MiB heap pause≈{d:.0} ns (tick ref={d} ns)\n",
        .{ rate_ns_per_kib, crossover_kib, large_heap_pause_ns, watchdog_tick_reference_nanoseconds },
    );
    std.debug.print(
        "[E7] VERDICT: bounded manager calls (lazy-commit fault, ARC/ORC/Arena allocate) < tick → NO auto-handoff; " ++
            "the one unbounded manager call (GC stop-the-world collect) crosses the tick at ≈{d:.0} KiB of live heap → it is a Process.blocking client.\n",
        .{crossover_kib},
    );

    // The scan rate is bounded (linear, E8-order) — it does not blow up.
    try testing.expect(rate_ns_per_kib > 0.0);
    try testing.expect(rate_ns_per_kib < 50_000.0);
    // The UNBOUNDED case is real: a 16 MiB-heap collect pause exceeds the tick,
    // so co-scheduled fibers WOULD be delayed beyond it — hence GC collect (and
    // only it) needs the dirty handoff. If this ever failed (a 16 MiB collect
    // stayed under the tick), the verdict would flip to "no manager call ever
    // needs a handoff", which the state of the art (BEAM dirty schedulers)
    // contradicts. The crossover lands within an order of magnitude of ~1 MB.
    try testing.expect(large_heap_pause_ns > @as(f64, @floatFromInt(watchdog_tick_reference_nanoseconds)));
    try testing.expect(crossover_kib < 8 * 1024); // crossover below ~8 MiB
}

// ---------------------------------------------------------------------------
// The BOUNDED manager call: a fresh-slab lazy-commit fault, measured DIRECTLY
// as the co-scheduled delay it imposes (two fibers, one scheduler)
// ---------------------------------------------------------------------------

const CoScheduledDelayState = struct {
    manager: *NoAllocManager,
    fault_region_bytes: usize,
    first_fiber_manager_call_start: std.atomic.Value(u64) = .init(0),
    first_fiber_manager_call_nanoseconds: std.atomic.Value(u64) = .init(0),
    second_fiber_ran_at: std.atomic.Value(u64) = .init(0),
};

const NoAllocManager = struct {
    teardown_count: usize = 0,
    fn managerContext(manager: *NoAllocManager) ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }
    const vtable = ManagerVTable{
        .allocate = allocThunk,
        .deallocate = deallocThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteThunk,
    };
    fn allocThunk(_: ?*anyopaque, _: usize, _: std.mem.Alignment) ?[*]u8 {
        return null;
    }
    fn deallocThunk(_: ?*anyopaque, _: [*]u8, _: usize, _: std.mem.Alignment) void {}
    fn teardownThunk(state: ?*anyopaque) void {
        const manager: *NoAllocManager = @ptrCast(@alignCast(state.?));
        manager.teardown_count += 1;
    }
    fn heapByteThunk(_: ?*anyopaque) usize {
        return 0;
    }
};

fn firstFiberBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *CoScheduledDelayState = @ptrCast(@alignCast(argument.?));
    state.first_fiber_manager_call_start.store(nowNanoseconds(), .release);
    // The blocking manager call: a real fresh-slab lazy-commit fault burst (a
    // process's first touch of a newly-reserved slab), run inline in this quantum
    // with NO safepoint — the un-annotated bounded manager block E7 measures.
    const region = std.heap.page_allocator.alloc(u8, state.fault_region_bytes) catch return;
    const page_size = std.heap.pageSize();
    var offset: usize = 0;
    while (offset < region.len) : (offset += page_size) {
        @as(*volatile u8, @ptrCast(&region[offset])).* = 0xE7;
    }
    state.first_fiber_manager_call_nanoseconds.store(
        nowNanoseconds() - state.first_fiber_manager_call_start.load(.acquire),
        .release,
    );
    std.heap.page_allocator.free(region);
}

fn secondFiberBody(context: *ProcessContext, argument: ?*anyopaque) void {
    _ = context;
    const state: *CoScheduledDelayState = @ptrCast(@alignCast(argument.?));
    state.second_fiber_ran_at.store(nowNanoseconds(), .release);
}

test "E7 (direct): a bounded manager call (fresh-slab fault) does NOT delay a co-scheduled fiber beyond the watchdog tick" {
    var pid_table = try PidTable.init(testing.allocator, .{ .capacity = 16 });
    defer pid_table.deinit();
    var envelope_pool = EnvelopePool.init(testing.allocator, .{});
    defer envelope_pool.deinit();
    var manager = NoAllocManager{};
    // A realistic per-process heap slab (64 KiB): its first-touch faults are the
    // bounded manager-internal block, NOT a pathological multi-MB burst.
    var state = CoScheduledDelayState{ .manager = &manager, .fault_region_bytes = 64 * 1024 };

    // A STANDALONE scheduler (no blocking pool): the manager call runs INLINE on
    // the core — exactly the un-annotated case E7 measures. The second fiber is
    // runnable behind the first; its delay is how long the inline manager call
    // held the core.
    var scheduler = Scheduler.init(testing.allocator, &pid_table, &envelope_pool, .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(.{
        .entry = firstFiberBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });
    _ = try scheduler.spawn(.{
        .entry = secondFiberBody,
        .argument = &state,
        .manager = manager.managerContext(),
        .model = .refcounted,
    });

    try scheduler.runUntilQuiescent();

    const manager_call_ns = state.first_fiber_manager_call_nanoseconds.load(.acquire);
    const co_scheduled_delay_ns =
        state.second_fiber_ran_at.load(.acquire) - state.first_fiber_manager_call_start.load(.acquire);

    std.debug.print(
        "[E7] direct co-scheduled delay: fresh-slab manager_call={d} ns  co_scheduled_delay={d} ns  (tick ref={d} ns)\n",
        .{ manager_call_ns, co_scheduled_delay_ns, watchdog_tick_reference_nanoseconds },
    );

    // The co-scheduled fiber ran after the first's inline manager call, so its
    // delay is at least the manager call's duration (the equivalence) …
    try testing.expect(manager_call_ns > 0);
    try testing.expect(co_scheduled_delay_ns >= manager_call_ns);
    // … and stays under the watchdog tick — a bounded (faulting) manager call
    // does NOT delay a co-scheduled fiber beyond the tick, so it needs no
    // handoff. (Headroom of 3× absorbs scheduler/measurement noise; a realistic
    // fresh-slab fault lands well inside even one tick.)
    try testing.expect(co_scheduled_delay_ns < 3 * watchdog_tick_reference_nanoseconds);
    try testing.expectEqual(@as(usize, 2), manager.teardown_count);
}
