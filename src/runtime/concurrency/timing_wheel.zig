//! Per-scheduler hierarchical timing wheel (P4-J2) — O(1) `receive … after`
//! timers.
//!
//! ## Why a timing wheel
//!
//! `receive … after T` needs an efficient deadline timer. The Phase-2 kernel
//! parked a timed waiter and rediscovered its deadline with an **O(n) scan of
//! every live process on every scheduler loop iteration** — and because the pid
//! table is pool-shared under M:N (P4-J1), that scan ran on *every* core, making
//! it O(n × cores) per tick. This module replaces it with the state of the art:
//! a **hierarchical timing wheel** (Varghese & Lauck 1987; BEAM per-scheduler
//! wheels; Netty `HashedWheelTimer`; Kafka purgatory). Insert and cancel are
//! **O(1)**; advancing the clock costs O(fired + cascaded + wraps), and each
//! timer is cascaded at most `level_count` times over its life — amortized O(1)
//! per timer.
//!
//! ## Structure (Kafka/Linux cascade)
//!
//! Layered wheels of increasing granularity. Level `L` has tick
//! `base_tick × wheel_size^L` and `wheel_size` slots, so it spans
//! `base_tick × wheel_size^(L+1)`:
//!
//! | level | tick        | span (`tick × 64`) |
//! |-------|-------------|--------------------|
//! | 0     | 1 ms        | 64 ms              |
//! | 1     | 64 ms       | ~4.1 s             |
//! | 2     | ~4.1 s      | ~4.4 min           |
//! | 3     | ~4.4 min    | ~4.7 h             |
//! | 4     | ~4.7 h      | ~12.4 d            |
//! | 5     | ~12.4 d     | ~2.2 y             |
//! | 6     | ~2.2 y      | ~139 y             |
//!
//! **Granularity justification.** `receive … after` durations are Erlang-style
//! milliseconds (the surface unit; `runtime.zig` converts to ns). Typical values
//! range from a few ms (polling) through seconds (gen_server call timeouts,
//! commonly 5000 ms) to minutes; a **1 ms base tick** matches the surface unit
//! exactly and bounds accuracy to one tick. Seven 64-slot levels cover ~139
//! years — beyond any realistic `after` — and a small **overflow list** holds
//! the astronomically-rare deadline past the top wheel so nothing is ever placed
//! early through modular aliasing.
//!
//! **Accuracy bound.** A timer fires when `current_ns ≥ its deadline`, never
//! before: deadlines are rounded **up** to the next base tick
//! (`deadline_tick = ⌈deadline_ns / base_tick⌉`), exactly matching Erlang's "at
//! least T ms" guarantee. Worst-case lateness is one base tick (< 1 ms) plus
//! whatever the scheduler's park/wake latency adds.
//!
//! ## Time model
//!
//! The wheel works in **integer ticks** (`base_tick_nanoseconds` each), exactly
//! like Linux jiffies, which eliminates all sub-tick ambiguity: an entry's
//! `deadline_tick` is the *first* tick at or after its ns deadline, and it fires
//! precisely when `base_clk` reaches `deadline_tick`. Within any `wheel_size`
//! window every tick has a unique low-`wheel_shift`-bit bucket index, so a
//! level-0 bucket never holds two different deadlines — no aliasing, no early
//! fire.
//!
//! ## Ownership / concurrency
//!
//! The wheel is **scheduler-local**: it is created, mutated, advanced, and torn
//! down only by its owning scheduler thread (the SACRED per-scheduler
//! invariant). It contains **no atomics** and takes no locks. The cross-scheduler
//! message-vs-timeout race is arbitrated one layer up, in `scheduler.zig`, via
//! the process record's `park_epoch` (an atomic bumped when a park episode ends
//! on any core) plus the existing `park_state` seq_cst handshake — the wheel
//! itself only ever sees single-threaded access. A timer whose process was
//! revived cross-core is discarded lazily when its bucket expires (the fire
//! callback returns `.discarded`), exactly the "harmlessly fires into an
//! already-satisfied receive" path Netty takes for cancelled timeouts.

const std = @import("std");
const builtin = @import("builtin");

/// Base tick granularity: 1 ms, matching the Erlang-style millisecond surface
/// unit of `receive … after` (see the module doc). All wheel arithmetic is in
/// integer multiples of this.
pub const base_tick_nanoseconds: u64 = std.time.ns_per_ms;

/// Slots per level. A power of two so a bucket index is a mask of the tick, and
/// each level's occupancy fits one `u64` (single-instruction `@ctz`/`@popCount`
/// scans of the non-empty buckets).
pub const wheel_size: usize = 64;

/// `log2(wheel_size)` — the per-level tick shift.
const wheel_shift: u6 = 6;

/// Bucket-index mask (`wheel_size - 1`).
const wheel_mask: u64 = wheel_size - 1;

/// Number of layered wheels. Seven 64-slot levels span ~139 years at a 1 ms base
/// tick — beyond any realistic `after`; the overflow list catches the rest.
pub const level_count: usize = 7;

/// Sentinel `Entry.level` marking an entry parked in the overflow list (a
/// deadline past the top wheel's span). `level_count` is out of the valid
/// `0..level_count` level range.
const overflow_level: u8 = level_count;

/// The tick duration of each level: `base_tick × wheel_size^L`, precomputed at
/// comptime. `tick_ticks[L]` is expressed in **base ticks** (not ns), so level 0
/// is 1 and each level multiplies by `wheel_size`.
const level_tick_ticks: [level_count]u64 = blk: {
    var ticks: [level_count]u64 = undefined;
    var value: u64 = 1;
    var level: usize = 0;
    while (level < level_count) : (level += 1) {
        ticks[level] = value;
        value *= wheel_size;
    }
    break :blk ticks;
};

/// One scheduled `receive … after` timer. Pooled (never intrusive on the process
/// record — a record migrates between schedulers and could re-park while a stale
/// entry still lived in another core's wheel, which would corrupt intrusive
/// links; a fresh pooled node per park episode avoids that entirely). Doubly
/// linked within its bucket for O(1) cancellation.
pub const Entry = struct {
    /// The owning `*ProcessRecord`, opaque here to break the wheel↔scheduler
    /// import cycle. The wheel never dereferences it; it hands it back to the
    /// fire callback, which validates and revives the process.
    context: *anyopaque,
    /// The park-episode epoch captured at insert (the scheduler's `park_epoch`
    /// snapshot). The fire callback compares it against the record's live epoch
    /// to detect a cross-core revival/recycle that ended this episode.
    epoch: u64,
    /// Absolute deadline in base ticks (`⌈deadline_ns / base_tick⌉`).
    deadline_tick: u64,
    /// Intrusive bucket links (doubly linked for O(1) unlink).
    prev: ?*Entry,
    next: ?*Entry,
    /// Which level holds this entry (`overflow_level` for the overflow list).
    /// Records the entry's location so `cancel` is O(1).
    level: u8,
    /// Bucket index within `level` (meaningless for the overflow list).
    index: u8,
};

/// One layer of the wheel: `wheel_size` bucket list-heads plus an occupancy
/// bitmap so advancing skips empty buckets.
const Level = struct {
    buckets: [wheel_size]?*Entry,
    occupancy: u64,
};

/// The decision the scheduler's fire callback returns for each expired entry —
/// purely for the wheel's telemetry; the node is freed either way (an expired
/// entry always leaves the wheel).
pub const FireOutcome = enum {
    /// The timeout was delivered (the waiting process was revived by this timer).
    fired,
    /// The entry was stale (its process was already revived by a message, killed,
    /// or recycled) — no timeout delivered.
    discarded,
};

/// A hierarchical timing wheel. One per scheduler; scheduler-thread-only.
pub const TimingWheel = struct {
    levels: [level_count]Level,
    /// Deadlines beyond the top wheel's span (astronomically rare). A plain
    /// doubly linked list, re-evaluated only when the top level advances.
    overflow_head: ?*Entry,
    /// Current time in base ticks. Seeded by the first `advance` and moved
    /// forward monotonically thereafter.
    base_clk: u64,
    /// Whether `base_clk` has been seeded to real time yet.
    clock_seeded: bool,
    /// Live entry count (the zero-`after` fast path: a scheduler with no timers
    /// skips advancing entirely).
    count: usize,
    /// Backing allocator for the node pool (the pool is unmanaged — the
    /// allocator is threaded through `create`/`destroy`/`deinit`).
    allocator: std.mem.Allocator,
    /// Pooled `Entry` allocation with a free list, all released at `deinit`. Node
    /// memory is retained (arena-backed) until `deinit`, self-bounded by the peak
    /// concurrent-timer count — the same recycle discipline as the record cache.
    pool: std.heap.MemoryPool(Entry),

    /// Create an empty wheel. Allocates nothing until the first `insert`
    /// (`MemoryPool` grows lazily) — `Scheduler.init`'s no-allocation contract
    /// holds.
    pub fn init(allocator: std.mem.Allocator) TimingWheel {
        return .{
            .levels = std.mem.zeroes([level_count]Level),
            .overflow_head = null,
            .base_clk = 0,
            .clock_seeded = false,
            .count = 0,
            .allocator = allocator,
            .pool = .empty,
        };
    }

    /// Release the node pool (the arena frees ALL node memory — both free-list
    /// and any still-linked entries — so there is never a leak). Still-linked
    /// entries at teardown are legal and expected: a cross-scheduler message
    /// wake invalidates a timer's episode (via the record's epoch) but leaves the
    /// node in this owner's wheel to be reaped lazily when its bucket expires;
    /// if the program shuts down before that deadline, the leftover node is
    /// simply freed here. The wheel's own count accounting is proven exact by its
    /// unit tests (which drain to zero before `deinit`).
    pub fn deinit(wheel: *TimingWheel) void {
        wheel.pool.deinit(wheel.allocator);
        wheel.* = undefined;
    }

    /// Whether the wheel holds no timers — the zero-`after` fast path.
    pub fn isEmpty(wheel: *const TimingWheel) bool {
        return wheel.count == 0;
    }

    /// Round an absolute ns deadline up to the first base tick at or after it, so
    /// a timer never fires early (Erlang's "at least T ms" guarantee).
    fn deadlineToTick(deadline_nanoseconds: u64) u64 {
        return (deadline_nanoseconds +| (base_tick_nanoseconds - 1)) / base_tick_nanoseconds;
    }

    /// Convert a tick back to the ns instant it represents (its lower bound).
    fn tickToNanoseconds(tick: u64) u64 {
        return tick *| base_tick_nanoseconds;
    }

    /// Seed the clock to `now_ns` if it has not been seeded yet — called on the
    /// first wheel touch so `base_clk` starts near real time rather than 0 (a
    /// 0-start would make the first `advance` cross billions of empty ticks).
    fn seedClock(wheel: *TimingWheel, now_nanoseconds: u64) void {
        if (!wheel.clock_seeded) {
            wheel.base_clk = now_nanoseconds / base_tick_nanoseconds;
            wheel.clock_seeded = true;
        }
    }

    /// Register a timer for `context` (a `*ProcessRecord`) firing at
    /// `deadline_nanoseconds` (absolute monotonic), tagged with `epoch` (the
    /// process's park epoch). Returns the pooled entry so the caller can hold it
    /// for O(1) `cancel`. O(1). `now_nanoseconds` seeds the clock on first use
    /// and lets the level be chosen relative to the current time.
    pub fn insert(
        wheel: *TimingWheel,
        context: *anyopaque,
        epoch: u64,
        deadline_nanoseconds: u64,
        now_nanoseconds: u64,
    ) error{OutOfMemory}!*Entry {
        wheel.seedClock(now_nanoseconds);
        var deadline_tick = deadlineToTick(deadline_nanoseconds);
        // A deadline in the current (or a past) tick is placed one tick ahead so
        // it fires on the next advance rather than aliasing into an already-swept
        // slot (< 1 ms extra, never early).
        if (deadline_tick <= wheel.base_clk) deadline_tick = wheel.base_clk + 1;

        const entry = try wheel.pool.create(wheel.allocator);
        entry.* = .{
            .context = context,
            .epoch = epoch,
            .deadline_tick = deadline_tick,
            .prev = null,
            .next = null,
            .level = 0,
            .index = 0,
        };
        wheel.link(entry);
        wheel.count += 1;
        return entry;
    }

    /// Cancel a timer (message beat the deadline, same-core): O(1) unlink and
    /// free. Must be the owning scheduler thread. `entry` must currently be in
    /// this wheel.
    pub fn cancel(wheel: *TimingWheel, entry: *Entry) void {
        wheel.unlink(entry);
        wheel.pool.destroy(entry);
        std.debug.assert(wheel.count > 0);
        wheel.count -= 1;
    }

    /// Place `entry` into the correct level/bucket (or the overflow list) for its
    /// `deadline_tick` relative to `base_clk`.
    fn link(wheel: *TimingWheel, entry: *Entry) void {
        std.debug.assert(entry.deadline_tick >= wheel.base_clk);
        var level: usize = 0;
        while (level < level_count) : (level += 1) {
            // The entry fits level L when it is fewer than `wheel_size` of L's
            // ticks ahead — i.e. within L's wheel for the current rotation.
            const level_now = wheel.base_clk / level_tick_ticks[level];
            const level_deadline = entry.deadline_tick / level_tick_ticks[level];
            if (level_deadline - level_now < wheel_size) {
                const index: usize = @intCast(level_deadline & wheel_mask);
                entry.level = @intCast(level);
                entry.index = @intCast(index);
                wheel.pushBucket(&wheel.levels[level], index, entry);
                return;
            }
        }
        // Beyond the top wheel's span: the overflow list.
        entry.level = overflow_level;
        entry.prev = null;
        entry.next = wheel.overflow_head;
        if (wheel.overflow_head) |head| head.prev = entry;
        wheel.overflow_head = entry;
    }

    /// Push `entry` onto the head of a bucket's doubly linked list, marking the
    /// bucket occupied.
    fn pushBucket(wheel: *TimingWheel, level: *Level, index: usize, entry: *Entry) void {
        _ = wheel;
        entry.prev = null;
        entry.next = level.buckets[index];
        if (level.buckets[index]) |head| head.prev = entry;
        level.buckets[index] = entry;
        level.occupancy |= @as(u64, 1) << @intCast(index);
    }

    /// Unlink `entry` from whatever list it is in (bucket or overflow), clearing
    /// the occupancy bit when a bucket empties.
    fn unlink(wheel: *TimingWheel, entry: *Entry) void {
        if (entry.level == overflow_level) {
            if (entry.prev) |prev| prev.next = entry.next else wheel.overflow_head = entry.next;
            if (entry.next) |next| next.prev = entry.prev;
            return;
        }
        const level = &wheel.levels[entry.level];
        const index: usize = entry.index;
        if (entry.prev) |prev| {
            prev.next = entry.next;
        } else {
            level.buckets[index] = entry.next;
        }
        if (entry.next) |next| next.prev = entry.prev;
        if (level.buckets[index] == null) {
            level.occupancy &= ~(@as(u64, 1) << @intCast(index));
        }
    }

    /// The earliest tick at which some bucket will next be processed, or null
    /// when the wheel holds no timers. The scheduler bounds its idle park by this
    /// so a timeout fires on schedule. O(level_count) — never scans entries.
    ///
    /// This is the earliest **bucket boundary** (≤ the earliest entry deadline,
    /// since a bucket boundary never exceeds the deadlines placed in it), so the
    /// park never oversleeps a due timer; it may wake once early to cascade a
    /// coarse bucket down and then re-tighten, which is correct (a timer only
    /// ever fires once `current_ns ≥ its deadline`).
    fn earliestBoundaryTick(wheel: *const TimingWheel) ?u64 {
        if (wheel.count == 0) return null;
        var earliest: ?u64 = null;
        var level: usize = 0;
        while (level < level_count) : (level += 1) {
            const occupancy = wheel.levels[level].occupancy;
            if (occupancy == 0) continue;
            const tick = level_tick_ticks[level];
            const level_now = wheel.base_clk / tick;
            const current_index: u64 = (wheel.base_clk / tick) & wheel_mask;
            // Rotate the occupancy so bit 0 is the current index, then the first
            // set bit is the nearest occupied bucket ahead (or at) the current
            // position. `@ctz` of the rotation gives the tick distance.
            const rotated = std.math.rotr(u64, occupancy, @as(u6, @intCast(current_index)));
            const ahead: u64 = @ctz(rotated);
            // Boundary tick = the start of that bucket's next occurrence.
            const boundary = (level_now + ahead) * tick;
            if (earliest == null or boundary < earliest.?) earliest = boundary;
        }
        // The overflow list's nearest deadline can beat every wheel boundary.
        var node = wheel.overflow_head;
        while (node) |entry| : (node = entry.next) {
            if (earliest == null or entry.deadline_tick < earliest.?) earliest = entry.deadline_tick;
        }
        return earliest;
    }

    /// The earliest tick at which the idle park should wake to service a timer,
    /// in absolute ns, or null when there are no timers. `null` ⇒ the scheduler
    /// uses its default park bound.
    pub fn earliestDeadlineNanoseconds(wheel: *const TimingWheel) ?u64 {
        const boundary = wheel.earliestBoundaryTick() orelse return null;
        // Never return a boundary at or behind the clock (it would busy-spin the
        // park); the caller clamps, but surface at least the next tick.
        const tick = @max(boundary, wheel.base_clk + 1);
        return tickToNanoseconds(tick);
    }

    /// Advance the clock to `now_nanoseconds`, delivering every entry whose
    /// deadline has arrived to `fire` and cascading coarser entries down as their
    /// buckets are reached. `fire` receives the entry's `context` and `epoch` and
    /// returns whether it actually fired (the wheel frees the node regardless).
    /// Amortized O(fired + cascaded + wraps). Scheduler-thread only.
    pub fn advance(
        wheel: *TimingWheel,
        now_nanoseconds: u64,
        comptime Context: type,
        fire_context: Context,
        comptime fire: fn (Context, *anyopaque, u64) FireOutcome,
    ) void {
        wheel.seedClock(now_nanoseconds);
        const now_tick = now_nanoseconds / base_tick_nanoseconds;
        // Process ticks `base_clk .. now_tick` INCLUSIVE (a timer at
        // `deadline_tick == now_tick` is due). Firing a level-0 bucket is
        // batched across empty buckets via occupancy; a rotation boundary
        // (index 0) cascades the higher levels down first, exactly as Linux's
        // per-jiffy timer loop does — but empty spans cost nothing.
        while (wheel.base_clk <= now_tick) {
            const index: usize = @intCast(wheel.base_clk & wheel_mask);
            if (index == 0) {
                // Entering a fresh level-0 rotation: the higher levels advanced,
                // so cascade their now-current buckets down before firing. A
                // no-op on the freshly-seeded (empty) wheel.
                wheel.cascadeAfterWrap();
            }
            // Fire buckets `[index, index + batch)` — ticks
            // `base_clk .. base_clk + batch - 1`, bounded by this rotation and by
            // `now_tick` (inclusive).
            const rotation_remaining = wheel_size - index;
            const ticks_to_now = now_tick - wheel.base_clk + 1;
            const batch: usize = @intCast(@min(@as(u64, rotation_remaining), ticks_to_now));
            wheel.fireLevelZeroRange(index, index + batch, Context, fire_context, fire);
            wheel.base_clk += batch;
        }
    }

    /// Fire every occupied level-0 bucket in `[start_index, end_index)` (no
    /// wrap): each holds exactly the entries whose `deadline_tick` equals the
    /// tick that bucket represents this rotation, all now due. Occupancy skips
    /// empty buckets.
    fn fireLevelZeroRange(
        wheel: *TimingWheel,
        start_index: usize,
        end_index: usize,
        comptime Context: type,
        fire_context: Context,
        comptime fire: fn (Context, *anyopaque, u64) FireOutcome,
    ) void {
        const level = &wheel.levels[0];
        if (level.occupancy == 0) return;
        var index = start_index;
        while (index < end_index) : (index += 1) {
            if ((level.occupancy & (@as(u64, 1) << @intCast(index))) == 0) continue;
            var node = level.buckets[index];
            level.buckets[index] = null;
            level.occupancy &= ~(@as(u64, 1) << @intCast(index));
            while (node) |entry| {
                node = entry.next;
                _ = fire(fire_context, entry.context, entry.epoch);
                wheel.pool.destroy(entry);
                std.debug.assert(wheel.count > 0);
                wheel.count -= 1;
            }
        }
    }

    /// After level 0 wraps, cascade the current bucket of each higher level whose
    /// tick just advanced: remove its entries and re-insert them (they now fall
    /// into a finer level, or fire on the next iteration if due). Chains upward
    /// while each successive level also wraps. Also re-evaluates the overflow
    /// list when the top level advances.
    fn cascadeAfterWrap(wheel: *TimingWheel) void {
        var level: usize = 1;
        while (level < level_count) : (level += 1) {
            const tick = level_tick_ticks[level];
            const level_index: usize = @intCast((wheel.base_clk / tick) & wheel_mask);
            wheel.cascadeBucket(level, level_index);
            // Stop unless this level also just wrapped (its index returned to 0).
            if (level_index != 0) break;
        }
        // The top level advancing can bring overflow entries into range.
        if (((wheel.base_clk / level_tick_ticks[level_count - 1]) & wheel_mask) == 0) {
            wheel.cascadeOverflow();
        }
    }

    /// Re-insert every entry from `levels[level].buckets[index]` relative to the
    /// advanced clock (they redistribute to finer levels / fire next iteration).
    fn cascadeBucket(wheel: *TimingWheel, level: usize, index: usize) void {
        var node = wheel.levels[level].buckets[index];
        if (node == null) return;
        wheel.levels[level].buckets[index] = null;
        wheel.levels[level].occupancy &= ~(@as(u64, 1) << @intCast(index));
        while (node) |entry| {
            node = entry.next;
            wheel.link(entry); // count unchanged: same entry, new bucket
        }
    }

    /// Re-evaluate the overflow list against the advanced clock, moving any entry
    /// now within the top wheel's span into it.
    fn cascadeOverflow(wheel: *TimingWheel) void {
        var node = wheel.overflow_head;
        wheel.overflow_head = null;
        while (node) |entry| {
            node = entry.next;
            wheel.link(entry);
        }
    }

    /// Deterministic-mode (`.forbid_parking`) firing: with no wall clock to sleep
    /// on, advance virtual time straight to the earliest timer and fire it (and
    /// any others due at that same instant). Returns whether the wheel held any
    /// timer to advance to. Mirrors the Phase-2 `fireEarliestReceiveTimeout`
    /// semantics the seeded scheduler relies on. Scheduler-thread only.
    pub fn advanceToEarliestAndFire(
        wheel: *TimingWheel,
        comptime Context: type,
        fire_context: Context,
        comptime fire: fn (Context, *anyopaque, u64) FireOutcome,
    ) bool {
        if (wheel.count == 0) return false;
        // Advance to the earliest entry's exact deadline so at least one fires.
        const target_tick = wheel.earliestEntryDeadlineTick() orelse return false;
        wheel.advance(tickToNanoseconds(target_tick), Context, fire_context, fire);
        return true;
    }

    /// The exact absolute deadline (ns) of the earliest armed entry, or null
    /// when empty — the nanosecond view of `earliestEntryDeadlineTick`. The
    /// seeded multi-scheduler simulator (`deterministic_mn.zig`) takes the
    /// minimum across cores to advance the shared virtual clock to the
    /// globally-next timer event before firing the due core(s). Deterministic
    /// mode only (small N: it scans candidate buckets). Scheduler-thread only.
    pub fn earliestEntryDeadlineNanoseconds(wheel: *const TimingWheel) ?u64 {
        const tick = wheel.earliestEntryDeadlineTick() orelse return null;
        return tickToNanoseconds(tick);
    }

    /// The exact earliest entry `deadline_tick` across all levels and the
    /// overflow list, or null when empty. Used only by deterministic mode (small
    /// N); it scans the candidate buckets, unlike the O(level_count)
    /// `earliestBoundaryTick`.
    fn earliestEntryDeadlineTick(wheel: *const TimingWheel) ?u64 {
        var earliest: ?u64 = null;
        var level: usize = 0;
        while (level < level_count) : (level += 1) {
            var occupancy = wheel.levels[level].occupancy;
            while (occupancy != 0) {
                const index: usize = @ctz(occupancy);
                occupancy &= occupancy - 1;
                var node = wheel.levels[level].buckets[index];
                while (node) |entry| : (node = entry.next) {
                    if (earliest == null or entry.deadline_tick < earliest.?) {
                        earliest = entry.deadline_tick;
                    }
                }
            }
        }
        var node = wheel.overflow_head;
        while (node) |entry| : (node = entry.next) {
            if (earliest == null or entry.deadline_tick < earliest.?) earliest = entry.deadline_tick;
        }
        return earliest;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// A test fire sink: records the contexts (as usize tags) fired in order.
const FireLog = struct {
    fired: std.ArrayListUnmanaged(usize) = .empty,
    allocator: std.mem.Allocator,
    /// Contexts to treat as stale (return `.discarded`) — the cross-core lazy
    /// discard path.
    stale: u64 = 0,

    fn init(allocator: std.mem.Allocator) FireLog {
        return .{ .allocator = allocator };
    }

    fn deinit(log: *FireLog) void {
        log.fired.deinit(log.allocator);
    }

    fn fire(log: *FireLog, context: *anyopaque, epoch: u64) FireOutcome {
        _ = epoch;
        const tag: usize = @intFromPtr(context);
        if ((log.stale & (@as(u64, 1) << @intCast(tag & 63))) != 0) return .discarded;
        log.fired.append(log.allocator, tag) catch @panic("test OOM");
        return .fired;
    }
};

/// Fabricate a distinct opaque context pointer from a small integer tag (the
/// wheel never dereferences it).
fn tagContext(tag: usize) *anyopaque {
    return @ptrFromInt(tag);
}

test "TimingWheel: insert then advance past the deadline fires exactly once" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // Seed the clock at t=0, arm a 5 ms timer.
    _ = try wheel.insert(tagContext(1), 0, 5 * std.time.ns_per_ms, 0);
    try testing.expectEqual(@as(usize, 1), wheel.count);

    // Advance to 4 ms: not yet due.
    wheel.advance(4 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 0), log.fired.items.len);
    try testing.expectEqual(@as(usize, 1), wheel.count);

    // Advance to 5 ms: fires.
    wheel.advance(5 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
    try testing.expectEqual(@as(usize, 1), log.fired.items[0]);
    try testing.expectEqual(@as(usize, 0), wheel.count);

    // Advancing further fires nothing more.
    wheel.advance(100 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
}

test "TimingWheel: a timer never fires early (rounds up to the tick)" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // Deadline 5.5 ms → rounds up to tick 6 (6 ms).
    _ = try wheel.insert(tagContext(1), 0, 5 * std.time.ns_per_ms + 500 * std.time.ns_per_us, 0);
    wheel.advance(5 * std.time.ns_per_ms + 999 * std.time.ns_per_us, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 0), log.fired.items.len); // not before 6 ms
    wheel.advance(6 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
}

test "TimingWheel: cancel removes a timer so it never fires (message beats deadline)" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    const entry = try wheel.insert(tagContext(7), 0, 50 * std.time.ns_per_ms, 0);
    try testing.expectEqual(@as(usize, 1), wheel.count);
    wheel.cancel(entry);
    try testing.expectEqual(@as(usize, 0), wheel.count);

    wheel.advance(100 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 0), log.fired.items.len);
}

test "TimingWheel: hierarchical cascade — a far timer fires at the right time" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // 5 s: lands in level 1 (span 64 ms .. 4.1 s? 5 s is level 2). Must cascade
    // down through levels and fire at ~5000 ms, never before.
    const deadline_ms = 5000;
    _ = try wheel.insert(tagContext(3), 0, deadline_ms * std.time.ns_per_ms, 0);

    // Advance in coarse jumps up to just before the deadline: nothing fires.
    wheel.advance((deadline_ms - 1) * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 0), log.fired.items.len);
    try testing.expectEqual(@as(usize, 1), wheel.count);

    // Reach the deadline: fires.
    wheel.advance(deadline_ms * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

test "TimingWheel: many staggered timers fire in deadline order" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // 500 timers at deadlines 1..500 ms (tags 1..500), inserted out of order.
    const total = 500;
    var seed: u64 = 0x1234_5678;
    var inserted: usize = 0;
    // Insert in a shuffled-ish order via a simple LCG permutation walk.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const tag = 1 + (i * 271 + 1) % total; // deterministic spread, unique-ish
        _ = tag;
        const ms = 1 + i; // deadline i+1 ms, tag i+1
        _ = try wheel.insert(tagContext(i + 1), 0, @as(u64, ms) * std.time.ns_per_ms, 0);
        inserted += 1;
    }
    try testing.expectEqual(@as(usize, total), wheel.count);

    // Advance one ms at a time; each ms fires exactly the timer for that ms.
    var ms: usize = 1;
    while (ms <= total) : (ms += 1) {
        wheel.advance(@as(u64, ms) * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
        try testing.expectEqual(@as(usize, ms), log.fired.items.len);
        try testing.expectEqual(@as(usize, ms), log.fired.items[ms - 1]); // tag == ms, in order
    }
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

test "TimingWheel: a single big advance fires all past-due timers in order" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // Timers across levels: 1 ms, 63 ms, 64 ms, 65 ms, 4096 ms (level boundaries).
    const deadlines_ms = [_]u64{ 1, 63, 64, 65, 200, 4096 };
    for (deadlines_ms, 0..) |ms, idx| {
        _ = try wheel.insert(tagContext(idx + 1), 0, ms * std.time.ns_per_ms, 0);
    }
    // One advance far past all of them.
    wheel.advance(5000 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(deadlines_ms.len, log.fired.items.len);
    // Fired in ascending deadline order (which matches insertion tag order here).
    for (0..deadlines_ms.len) |k| {
        try testing.expectEqual(@as(usize, k + 1), log.fired.items[k]);
    }
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

test "TimingWheel: earliestDeadline reflects the nearest timer and shrinks as timers fire" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    try testing.expectEqual(@as(?u64, null), wheel.earliestDeadlineNanoseconds());

    _ = try wheel.insert(tagContext(1), 0, 100 * std.time.ns_per_ms, 0);
    _ = try wheel.insert(tagContext(2), 0, 10 * std.time.ns_per_ms, 0);
    _ = try wheel.insert(tagContext(3), 0, 4000 * std.time.ns_per_ms, 0);

    // Nearest boundary must be at or before the 10 ms timer, and strictly future.
    const earliest = wheel.earliestDeadlineNanoseconds().?;
    try testing.expect(earliest > 0);
    try testing.expect(earliest <= 10 * std.time.ns_per_ms);

    wheel.advance(10 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 1), log.fired.items.len); // the 10 ms one
    const next = wheel.earliestDeadlineNanoseconds().?;
    try testing.expect(next <= 100 * std.time.ns_per_ms);

    // Drain the remaining timers (deinit asserts the wheel is empty).
    wheel.advance(5000 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

test "TimingWheel: stale (discarded) entries are freed without firing" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // Tag 2 is marked stale — the fire callback returns .discarded for it.
    log.stale = @as(u64, 1) << 2;
    _ = try wheel.insert(tagContext(1), 0, 5 * std.time.ns_per_ms, 0);
    _ = try wheel.insert(tagContext(2), 0, 5 * std.time.ns_per_ms, 0);

    wheel.advance(5 * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    // Only tag 1 recorded; both nodes freed (count back to 0).
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
    try testing.expectEqual(@as(usize, 1), log.fired.items[0]);
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

test "TimingWheel: deterministic advanceToEarliestAndFire fires the earliest waiter" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // No wall-clock advance; virtual-time firing must pick the earliest.
    _ = try wheel.insert(tagContext(1), 0, 300 * std.time.ns_per_ms, 0);
    _ = try wheel.insert(tagContext(2), 0, 50 * std.time.ns_per_ms, 0);

    try testing.expect(wheel.advanceToEarliestAndFire(*FireLog, &log, FireLog.fire));
    try testing.expectEqual(@as(usize, 1), log.fired.items.len);
    try testing.expectEqual(@as(usize, 2), log.fired.items[0]); // the 50 ms waiter

    try testing.expect(wheel.advanceToEarliestAndFire(*FireLog, &log, FireLog.fire));
    try testing.expectEqual(@as(usize, 2), log.fired.items.len);
    try testing.expectEqual(@as(usize, 1), log.fired.items[1]); // then the 300 ms waiter

    try testing.expect(!wheel.advanceToEarliestAndFire(*FireLog, &log, FireLog.fire));
}

test "TimingWheel: overflow list holds a beyond-top-wheel deadline and fires it" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    // A deadline beyond the top wheel's ~139 y span (use near u64 max ns).
    const far: u64 = std.math.maxInt(u64) - base_tick_nanoseconds;
    const entry = try wheel.insert(tagContext(9), 0, far, 0);
    try testing.expectEqual(overflow_level, entry.level);
    try testing.expectEqual(@as(usize, 1), wheel.count);
    // It is cancellable from the overflow list.
    wheel.cancel(entry);
    try testing.expectEqual(@as(usize, 0), wheel.count);
}

/// A fire sink that records, per fired context, the tick at which it fired — so
/// a stress test can assert every timer fired exactly once and never early.
const StressSink = struct {
    fire_tick: []u64,
    fire_count: []u8,
    now_tick: u64 = 0,

    fn fire(sink: *StressSink, context: *anyopaque, epoch: u64) FireOutcome {
        _ = epoch;
        const tag: usize = @intFromPtr(context) - 1; // tags are 1-based
        sink.fire_tick[tag] = sink.now_tick;
        sink.fire_count[tag] += 1;
        return .fired;
    }
};

test "TimingWheel: 10k timers with random deadlines each fire exactly once, never early (O(1) scalability)" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();

    const total = 10_000;
    const horizon_ms = 8_000; // deadlines spread across ~8 s (crosses 3 levels)
    const deadline_tick = try testing.allocator.alloc(u64, total);
    defer testing.allocator.free(deadline_tick);
    const fire_tick = try testing.allocator.alloc(u64, total);
    defer testing.allocator.free(fire_tick);
    const fire_count = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(fire_count);
    @memset(fire_count, 0);

    // Insert 10k timers at pseudo-random deadlines in [1, horizon] ms — O(1) each.
    var seed: u64 = 0xC0FFEE_1234_5678;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const ms = 1 + (seed >> 33) % horizon_ms;
        deadline_tick[i] = ms; // 1 ms tick ⇒ tick == ms
        _ = try wheel.insert(tagContext(i + 1), 0, ms * std.time.ns_per_ms, 0);
    }
    try testing.expectEqual(@as(usize, total), wheel.count);

    var sink = StressSink{ .fire_tick = fire_tick, .fire_count = fire_count };
    // Advance 1 ms at a time to the horizon; every timer fires as its ms arrives.
    var ms: u64 = 1;
    while (ms <= horizon_ms) : (ms += 1) {
        sink.now_tick = ms;
        wheel.advance(ms * std.time.ns_per_ms, *StressSink, &sink, StressSink.fire);
    }

    // Every timer fired exactly once, and never before its deadline tick.
    try testing.expectEqual(@as(usize, 0), wheel.count);
    for (0..total) |k| {
        try testing.expectEqual(@as(u8, 1), fire_count[k]);
        try testing.expect(fire_tick[k] >= deadline_tick[k]); // never early
        try testing.expect(fire_tick[k] <= deadline_tick[k]); // and on-time (1 ms grid)
    }
}

test "TimingWheel: interleaved insert/cancel/advance keeps counts exact (leak check)" {
    var wheel = TimingWheel.init(testing.allocator);
    defer wheel.deinit();
    var log = FireLog.init(testing.allocator);
    defer log.deinit();

    var round: usize = 0;
    var now_ms: u64 = 0;
    while (round < 200) : (round += 1) {
        // Arm three timers.
        const e1 = try wheel.insert(tagContext(1), 0, (now_ms + 3) * std.time.ns_per_ms, now_ms * std.time.ns_per_ms);
        _ = try wheel.insert(tagContext(2), 0, (now_ms + 7) * std.time.ns_per_ms, now_ms * std.time.ns_per_ms);
        const e3 = try wheel.insert(tagContext(3), 0, (now_ms + 5) * std.time.ns_per_ms, now_ms * std.time.ns_per_ms);
        // Cancel two (message-beats-deadline) before they fire.
        wheel.cancel(e1);
        wheel.cancel(e3);
        // Advance past the surviving one.
        now_ms += 10;
        wheel.advance(now_ms * std.time.ns_per_ms, *FireLog, &log, FireLog.fire);
    }
    try testing.expectEqual(@as(usize, 0), wheel.count);
    try testing.expectEqual(@as(usize, 200), log.fired.items.len); // only tag-2 survivors fired
}
