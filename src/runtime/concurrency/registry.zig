//! The local process registry — the atomic name→pid table over which
//! `Process.register`/`whereis`/`unregister` and send-by-name are written in
//! pure Zap (`docs/concurrency-implementation-plan.md` Stage 2; research.md
//! §6.7, job P5-J2). A genuine runtime primitive, and a SIBLING of the pid
//! table (`pid_table.zig`): where the pid table maps a generational pid to its
//! control block, this maps an interned NAME (an atom id) to a generational
//! pid. It is deliberately a pure `u64`→`u64` map with an INJECTED liveness
//! predicate (`Liveness`) — it never imports the pid table, so it is a
//! self-contained, unit-testable leaf. The scheduler composes it with
//! `PidTable.isAlive` (`scheduler.zig`) to give registration and lookup their
//! generation validation.
//!
//! ## Names are interned strings (atom ids)
//!
//! A registered name is an atom id — a `u64` in the binary-global atom table
//! (`lib/process.zap`). Atoms ARE Zap's interned strings, so "register a name"
//! is "register an interned string", exactly Elixir's `Process.register/2`
//! (whose names are atoms). The registry never interprets the id; it is an
//! opaque key. Zero is reserved as the "no name" sentinel by the Zap surface
//! (a process's `registered_name` is 0 when unregistered), but the table itself
//! keys on the slot's `state`, never on `name == 0`, so no atom id is special.
//!
//! ## One name per process (Erlang/Elixir semantics)
//!
//! A process may hold AT MOST ONE registered name (Erlang `register/2` fails if
//! the pid already has a name). This is why auto-unregister-on-teardown needs
//! only a single owner-only `registered_name` field on the PCB (`process.zig`),
//! not a per-process list: on teardown the scheduler releases that one name.
//! This resolves the classic register-then-crash race (research.md §6.7): a
//! process that registers a name then crashes releases the name at teardown, so
//! it becomes re-registrable — and, until teardown runs, the name resolving to
//! a now-dead pid is a lookup MISS (generation-validated), never a stale hit.
//!
//! ## Concurrency posture — lock-free reads, serialized writes (M:N-safe)
//!
//! * **`whereis` takes NO lock** (the pid-table lock-free-read discipline): it
//!   probes the open-addressed table reading each slot through a per-slot
//!   SEQLOCK (`readSlotConsistent`), so a concurrent register/unregister can
//!   never make it observe a torn `{state, name, pid}`. All slot fields are
//!   atomics, so the read races no plain memory — ThreadSanitizer-clean.
//! * **`register`/`unregister` hold ONE spinlock** (`write_lock`). A hash-map
//!   "find-or-claim" has an unavoidable linearization point (two registrations
//!   of the same name that probe to different empty slots would otherwise both
//!   insert — a duplicate), so writers serialize on a single lock. Writes are
//!   RARE (a server registers once at start-up), so this lock is uncontended;
//!   it is not on the hot `whereis`/send-by-name path. The lock makes the
//!   register-then-race atomic: of two concurrent `register(:name, …)` calls
//!   exactly one wins and the other sees `.name_taken`.
//!
//! ## Open addressing (fixed capacity, like the pid table)
//!
//! Linear-probing open addressing over a fixed, power-of-two slot array
//! (allocated once at `init`, exactly like the pid table's eager slot
//! allocation). Deletion tombstones a slot (`unregister`) rather than emptying
//! it, so a probe chain is never broken; `register` reuses the first tombstone
//! it passes, bounding tombstone growth. There is nothing to free PER ENTRY — a
//! registration is a slot-state transition, not a heap node — so leak-exactness
//! is the invariant "`liveEntryCount` returns to zero once every name is
//! unregistered or released at teardown", asserted at `deinit`. Registration
//! fails with `error.RegistryFull` only when every slot is occupied by a
//! DISTINCT live name (the documented fixed-capacity policy, mirroring the pid
//! table's `ProcessTableExhausted`).

const std = @import("std");

/// A pid-liveness predicate injected by the caller (the scheduler wraps
/// `PidTable.isAlive`). Keeping liveness out of the table makes it a pure,
/// self-contained map that unit-tests without a scheduler or pid table (tests
/// pass a mock). `whereis` returns a name's pid ONLY if it is still alive
/// (generation-validated), and `register` RECLAIMS a name whose holder has died
/// — both consult this predicate.
pub const Liveness = struct {
    /// Opaque context threaded to `is_alive` (the scheduler passes its
    /// `*PidTable`).
    context: ?*anyopaque = null,
    /// Whether the process addressed by `pid_bits` is still live. The default
    /// treats every pid as alive — for the registry's own unit tests, which
    /// exercise the map mechanics without a pid table.
    is_alive: *const fn (context: ?*anyopaque, pid_bits: u64) bool = alwaysAlive,

    fn alwaysAlive(context: ?*anyopaque, pid_bits: u64) bool {
        _ = context;
        _ = pid_bits;
        return true;
    }

    inline fn isAlive(liveness: Liveness, pid_bits: u64) bool {
        return liveness.is_alive(liveness.context, pid_bits);
    }
};

/// The outcome of `register`: the name was claimed for the caller, or it is
/// already held by a still-LIVE process (research.md §6.7 — registering a taken
/// name fails). A name held only by a now-DEAD process is not "taken": it is
/// reclaimed and reported as `.registered`.
pub const RegisterOutcome = enum {
    /// The name is now registered to the given pid (freshly claimed, or a dead
    /// holder's stale entry reclaimed).
    registered,
    /// The name is held by another LIVE process — registration fails (Erlang
    /// `register/2` badarg on a taken name).
    name_taken,
};

/// Table lifecycle state of a slot. Distinct from the pid table's `SlotState`;
/// here `tombstone` is a deleted entry that keeps its probe-chain position so a
/// concurrent lock-free `whereis` never terminates early on it.
const SlotState = enum(u2) {
    /// Never held a registration — terminates a probe (the name is absent).
    empty = 0,
    /// Holds a live registration; `name`/`pid_bits` are meaningful.
    occupied = 1,
    /// Held a registration since unregistered — a probe SKIPS it and continues.
    tombstone = 2,
};

/// Per-slot control word, packed so the seqlock version, the write-in-progress
/// flag, and the slot state are ONE atomic unit — the pid-table `SlotMetadata`
/// discipline. A lock-free reader snapshots this before and after reading
/// `name`/`pid_bits` and retries on any change (`readSlotConsistent`), so it
/// never observes a torn slot. Only a writer (holding `write_lock`) mutates a
/// slot, so the version has a single incrementer and can never race itself.
const SlotControl = packed struct(u64) {
    /// A writer is mid-update; a reader spins and retries (seqlock).
    writing: bool = false,
    /// The slot's lifecycle state.
    state: SlotState = .empty,
    /// Bumped on every completed write — a reader that sees an unchanged
    /// version across its read proves no write intervened.
    version: u61 = 0,
};

/// One registry slot. All fields atomic so the lock-free `whereis` read races
/// no plain memory (ThreadSanitizer-clean).
const Slot = struct {
    /// Packed `{writing, state, version}` — see `SlotControl`.
    control: std.atomic.Value(u64) = .init(@bitCast(SlotControl{})),
    /// The interned name (atom id); meaningful iff `state == .occupied`.
    name: std.atomic.Value(u64) = .init(0),
    /// The registered process's raw pid bits; meaningful iff `.occupied`.
    pid_bits: std.atomic.Value(u64) = .init(0),
};

/// One internally consistent observation of a slot.
const SlotObservation = struct {
    state: SlotState,
    name: u64,
    pid_bits: u64,
};

/// Registry sizing. Kernel-internal; the capacity is fixed for the registry's
/// life (like the pid table's).
pub const Config = struct {
    /// Number of slots (= maximum concurrently registered names). MUST be a
    /// power of two (the probe index masks with `capacity - 1`).
    capacity: u32 = default_capacity,
};

/// Default registry capacity: 16,384 name slots (a power of two). Open
/// addressing stays fast to well past ten thousand live names — far beyond any
/// realistic named-process count (Erlang systems register hundreds to low
/// thousands) — while the eager backing (24 B/slot → 384 KiB, allocated once
/// for the shared registry in a gated-on binary) mirrors the pid table's
/// boot-time allocation. Non-spawning binaries never initialize the kernel, so
/// the zero-cost gate is unaffected.
pub const default_capacity: u32 = 16_384;

/// The local process registry: a fixed, lock-free-read, write-serialized
/// open-addressing name→pid table. All public operations are safe for
/// concurrent use across M:N scheduler cores.
pub const ProcessRegistry = struct {
    /// Slot storage, `config.capacity` entries, allocated at `init`.
    slots: []Slot,
    /// Serializes `register`/`unregister` (find-or-claim atomicity). NOT taken
    /// by `whereis`. A spinlock, matching the kernel's libc-free convention.
    write_lock: std.atomic.Mutex = .unlocked,
    /// Live (occupied) registrations — the leak oracle. Maintained under
    /// `write_lock`, read lock-free for observability.
    live_entry_count: std.atomic.Value(usize) = .init(0),
    /// Allocator that owns `slots`.
    allocator: std.mem.Allocator,

    /// Errors from `init`.
    pub const InitError = error{
        /// `Config.capacity` is zero or not a power of two.
        InvalidCapacity,
        /// Slot-storage allocation failed.
        OutOfMemory,
    };

    /// Errors from `register`.
    pub const RegisterError = error{
        /// Every slot is occupied by a distinct live name — the documented
        /// fixed-capacity failure mode (see the module doc).
        RegistryFull,
    };

    /// Allocate a registry of `config.capacity` empty slots.
    pub fn init(allocator: std.mem.Allocator, config: Config) InitError!ProcessRegistry {
        if (config.capacity == 0 or !std.math.isPowerOfTwo(config.capacity)) {
            return error.InvalidCapacity;
        }
        const slots = try allocator.alloc(Slot, config.capacity);
        for (slots) |*slot| slot.* = .{};
        return .{ .slots = slots, .allocator = allocator };
    }

    /// Release the slot storage. Every registration must have been unregistered
    /// or released at teardown first (`liveEntryCount == 0`) — the leak oracle.
    pub fn deinit(registry: *ProcessRegistry) void {
        std.debug.assert(registry.live_entry_count.load(.monotonic) == 0);
        registry.allocator.free(registry.slots);
        registry.* = undefined;
    }

    fn acquire(registry: *ProcessRegistry) void {
        while (!registry.write_lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Register `pid_bits` under `name` (atomic — the register-then-race
    /// resolves to exactly one winner). Returns `.registered` on success, or
    /// `.name_taken` when the name is held by another LIVE process. A name held
    /// only by a now-DEAD process is reclaimed (its stale entry overwritten) and
    /// reported `.registered` — defense in depth against a name whose owner's
    /// teardown has not yet released it. Fails with `error.RegistryFull` only
    /// when the table is saturated with distinct live names.
    pub fn register(
        registry: *ProcessRegistry,
        name: u64,
        pid_bits: u64,
        liveness: Liveness,
    ) RegisterError!RegisterOutcome {
        registry.acquire();
        defer registry.write_lock.unlock();

        const mask = registry.slots.len - 1;
        var index = slotHash(name, mask);
        // The first tombstone/empty slot in the probe chain, where a fresh
        // registration is placed once the name is proven absent (a truly-empty
        // slot). Reusing a tombstone bounds tombstone accumulation.
        var first_reusable: ?usize = null;
        var probes: usize = 0;
        while (probes < registry.slots.len) : ({
            index = (index + 1) & mask;
            probes += 1;
        }) {
            const slot = &registry.slots[index];
            const control: SlotControl = @bitCast(slot.control.load(.monotonic));
            switch (control.state) {
                .empty => {
                    // A truly-empty slot ends the chain: the name is absent.
                    const target = first_reusable orelse index;
                    writeSlot(&registry.slots[target], .occupied, name, pid_bits);
                    _ = registry.live_entry_count.fetchAdd(1, .monotonic);
                    return .registered;
                },
                .tombstone => {
                    if (first_reusable == null) first_reusable = index;
                },
                .occupied => {
                    if (slot.name.load(.monotonic) == name) {
                        const holder = slot.pid_bits.load(.monotonic);
                        if (liveness.isAlive(holder)) return .name_taken;
                        // The holder is dead: reclaim its entry in place (an
                        // occupied→occupied rewrite, so the live count is
                        // unchanged).
                        writeSlot(slot, .occupied, name, pid_bits);
                        return .registered;
                    }
                    // A different name (hash collision): keep probing.
                },
            }
        }
        return error.RegistryFull;
    }

    /// Unregister `name` if it is registered to `expected_bits`, tombstoning the
    /// slot. Returns whether an entry was removed. The `expected_bits` guard is
    /// what makes teardown-release and explicit unregister safe under races: a
    /// stale releaser (whose name was already re-registered to a DIFFERENT pid)
    /// finds a mismatch and removes nothing, so it never clobbers a successor's
    /// registration.
    pub fn unregister(registry: *ProcessRegistry, name: u64, expected_bits: u64) bool {
        registry.acquire();
        defer registry.write_lock.unlock();

        const mask = registry.slots.len - 1;
        var index = slotHash(name, mask);
        var probes: usize = 0;
        while (probes < registry.slots.len) : ({
            index = (index + 1) & mask;
            probes += 1;
        }) {
            const slot = &registry.slots[index];
            const control: SlotControl = @bitCast(slot.control.load(.monotonic));
            switch (control.state) {
                .empty => return false, // name absent — probe ends
                .tombstone => {}, // skip and continue
                .occupied => {
                    if (slot.name.load(.monotonic) == name) {
                        // The name is present exactly here (names are unique).
                        // Remove it only if it is still `expected_bits`.
                        if (slot.pid_bits.load(.monotonic) != expected_bits) return false;
                        writeSlot(slot, .tombstone, 0, 0);
                        std.debug.assert(registry.live_entry_count.load(.monotonic) > 0);
                        _ = registry.live_entry_count.fetchSub(1, .monotonic);
                        return true;
                    }
                    // A different name: keep probing.
                },
            }
        }
        return false;
    }

    /// Resolve `name` to the raw pid bits of its LIVE registrant, or null when
    /// the name is unregistered or resolves to a dead/reused pid
    /// (generation-validated through `liveness`). Lock-free — no `write_lock` —
    /// so it scales across cores exactly like `PidTable.lookup`.
    pub fn whereis(registry: *ProcessRegistry, name: u64, liveness: Liveness) ?u64 {
        const mask = registry.slots.len - 1;
        var index = slotHash(name, mask);
        var probes: usize = 0;
        while (probes < registry.slots.len) : ({
            index = (index + 1) & mask;
            probes += 1;
        }) {
            const observation = readSlotConsistent(&registry.slots[index]);
            switch (observation.state) {
                .empty => return null, // name absent — probe ends
                .tombstone => {}, // skip and continue
                .occupied => {
                    if (observation.name == name) {
                        return if (liveness.isAlive(observation.pid_bits)) observation.pid_bits else null;
                    }
                },
            }
        }
        return null;
    }

    /// Live (occupied) registrations — the leak oracle (must reach zero once
    /// every name is unregistered or released at teardown). Advisory under
    /// concurrent mutation, exact at quiescence.
    pub fn liveEntryCount(registry: *const ProcessRegistry) usize {
        return registry.live_entry_count.load(.monotonic);
    }
};

/// Murmur3 64-bit finalizer, masked to the (power-of-two) slot space — a strong
/// integer mix so atom ids (often small and dense) do not cluster.
fn slotHash(name: u64, mask: usize) usize {
    var h = name;
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return @as(usize, @intCast(h & @as(u64, mask)));
}

/// Seqlock write (writer holds `write_lock`, so the version has one
/// incrementer): announce the write (set `writing`, so readers retry), publish
/// `name`/`pid_bits`, then commit the new `state` and bump the version. Every
/// store is `.release`, pairing with the reader's `.acquire` control loads.
fn writeSlot(slot: *Slot, new_state: SlotState, name: u64, pid_bits: u64) void {
    const before: SlotControl = @bitCast(slot.control.load(.monotonic));
    slot.control.store(@bitCast(SlotControl{
        .writing = true,
        .state = before.state,
        .version = before.version,
    }), .release);
    slot.name.store(name, .release);
    slot.pid_bits.store(pid_bits, .release);
    slot.control.store(@bitCast(SlotControl{
        .writing = false,
        .state = new_state,
        .version = before.version +% 1,
    }), .release);
}

/// Seqlock-consistent slot read (the pid-table `readSlotConsistent` discipline):
/// control (acquire) → name/pid (acquire) → control (acquire); accept only when
/// no write was in progress and the control word is unchanged, so the observed
/// `{state, name, pid}` is a single coherent slot state. Each retry observes a
/// strictly newer version; a retry only happens under a concurrent write.
fn readSlotConsistent(slot: *Slot) SlotObservation {
    while (true) {
        const before: SlotControl = @bitCast(slot.control.load(.acquire));
        if (before.writing) {
            std.atomic.spinLoopHint();
            continue;
        }
        const name = slot.name.load(.acquire);
        const pid_bits = slot.pid_bits.load(.acquire);
        const after = slot.control.load(.acquire);
        if (@as(u64, @bitCast(before)) == after) {
            return .{ .state = before.state, .name = name, .pid_bits = pid_bits };
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A mock liveness predicate: every pid is alive except those in `dead`.
const MockLiveness = struct {
    dead: []const u64 = &.{},

    fn isAliveThunk(context: ?*anyopaque, pid_bits: u64) bool {
        const self: *const MockLiveness = @ptrCast(@alignCast(context.?));
        for (self.dead) |dead_pid| {
            if (dead_pid == pid_bits) return false;
        }
        return true;
    }

    fn liveness(self: *const MockLiveness) Liveness {
        return .{ .context = @constCast(self), .is_alive = isAliveThunk };
    }
};

test "ProcessRegistry: register / whereis / unregister round-trips, leak-exact" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 64 });
    defer registry.deinit();
    const alive = Liveness{};

    try testing.expectEqual(@as(usize, 0), registry.liveEntryCount());
    try testing.expectEqual(@as(?u64, null), registry.whereis(0xF00, alive));

    try testing.expectEqual(RegisterOutcome.registered, try registry.register(0xF00, 0xAAAA, alive));
    try testing.expectEqual(@as(usize, 1), registry.liveEntryCount());
    try testing.expectEqual(@as(?u64, 0xAAAA), registry.whereis(0xF00, alive));

    try testing.expect(registry.unregister(0xF00, 0xAAAA));
    try testing.expectEqual(@as(usize, 0), registry.liveEntryCount());
    try testing.expectEqual(@as(?u64, null), registry.whereis(0xF00, alive));
}

test "ProcessRegistry: registering a name held by a LIVE process fails" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 64 });
    defer registry.deinit();
    const alive = Liveness{};

    try testing.expectEqual(RegisterOutcome.registered, try registry.register(0xF00, 0xAAAA, alive));
    // A second registration of the same name, holder still alive, is refused.
    try testing.expectEqual(RegisterOutcome.name_taken, try registry.register(0xF00, 0xBBBB, alive));
    // The original registration is intact.
    try testing.expectEqual(@as(?u64, 0xAAAA), registry.whereis(0xF00, alive));
    try testing.expectEqual(@as(usize, 1), registry.liveEntryCount());

    try testing.expect(registry.unregister(0xF00, 0xAAAA));
}

test "ProcessRegistry: whereis of a dead holder misses; register reclaims it" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 64 });
    defer registry.deinit();

    // 0xAAAA registers :foo, then dies (the mock reports it dead).
    try testing.expectEqual(RegisterOutcome.registered, try registry.register(0xF00, 0xAAAA, Liveness{}));
    var mock = MockLiveness{ .dead = &.{0xAAAA} };
    const with_dead = mock.liveness();

    // whereis validates liveness: a dead holder resolves to null (not a stale hit).
    try testing.expectEqual(@as(?u64, null), registry.whereis(0xF00, with_dead));
    // register RECLAIMS the dead holder's name for a fresh, live process.
    try testing.expectEqual(RegisterOutcome.registered, try registry.register(0xF00, 0xBBBB, with_dead));
    // The live count is unchanged (reclaim overwrites in place).
    try testing.expectEqual(@as(usize, 1), registry.liveEntryCount());
    try testing.expectEqual(@as(?u64, 0xBBBB), registry.whereis(0xF00, Liveness{}));

    try testing.expect(registry.unregister(0xF00, 0xBBBB));
}

test "ProcessRegistry: unregister with the wrong pid does not clobber a successor" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 64 });
    defer registry.deinit();
    const alive = Liveness{};

    try testing.expectEqual(RegisterOutcome.registered, try registry.register(0xF00, 0xBBBB, alive));
    // A stale releaser holding the OLD pid removes nothing (guarded by expected).
    try testing.expect(!registry.unregister(0xF00, 0xAAAA));
    try testing.expectEqual(@as(?u64, 0xBBBB), registry.whereis(0xF00, alive));
    try testing.expectEqual(@as(usize, 1), registry.liveEntryCount());

    try testing.expect(registry.unregister(0xF00, 0xBBBB));
}

test "ProcessRegistry: hash collisions probe correctly and tombstones are reused" {
    // Capacity 8 forces collisions across many names.
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 8 });
    defer registry.deinit();
    const alive = Liveness{};

    // Register six names, each pid = name * 0x10.
    var name: u64 = 1;
    while (name <= 6) : (name += 1) {
        try testing.expectEqual(RegisterOutcome.registered, try registry.register(name, name * 0x10, alive));
    }
    try testing.expectEqual(@as(usize, 6), registry.liveEntryCount());
    // All six resolve despite probing.
    name = 1;
    while (name <= 6) : (name += 1) {
        try testing.expectEqual(@as(?u64, name * 0x10), registry.whereis(name, alive));
    }

    // Unregister a middle name, then re-register it — reuses the tombstone.
    try testing.expect(registry.unregister(3, 3 * 0x10));
    try testing.expectEqual(@as(?u64, null), registry.whereis(3, alive));
    try testing.expectEqual(RegisterOutcome.registered, try registry.register(3, 0x999, alive));
    try testing.expectEqual(@as(?u64, 0x999), registry.whereis(3, alive));
    // The other names still resolve through the tombstone-then-reused chain.
    try testing.expectEqual(@as(?u64, 5 * 0x10), registry.whereis(5, alive));

    // Drain.
    name = 1;
    while (name <= 6) : (name += 1) {
        const expected: u64 = if (name == 3) 0x999 else name * 0x10;
        try testing.expect(registry.unregister(name, expected));
    }
    try testing.expectEqual(@as(usize, 0), registry.liveEntryCount());
}

test "ProcessRegistry: a table full of distinct live names reports RegistryFull" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 4 });
    defer registry.deinit();
    const alive = Liveness{};

    // Fill every slot with a distinct live name.
    var name: u64 = 1;
    while (name <= 4) : (name += 1) {
        try testing.expectEqual(RegisterOutcome.registered, try registry.register(name, name, alive));
    }
    // A fifth distinct name has nowhere to go.
    try testing.expectError(error.RegistryFull, registry.register(99, 99, alive));
    // But re-registering an EXISTING name's dead holder still works (no new slot).
    var mock = MockLiveness{ .dead = &.{2} };
    try testing.expectEqual(RegisterOutcome.registered, try registry.register(2, 0x1234, mock.liveness()));

    name = 1;
    while (name <= 4) : (name += 1) {
        const expected: u64 = if (name == 2) 0x1234 else name;
        try testing.expect(registry.unregister(name, expected));
    }
}

test "ProcessRegistry: init rejects a non-power-of-two capacity" {
    try testing.expectError(error.InvalidCapacity, ProcessRegistry.init(testing.allocator, .{ .capacity = 0 }));
    try testing.expectError(error.InvalidCapacity, ProcessRegistry.init(testing.allocator, .{ .capacity = 100 }));
}

/// A worker that hammers the registry concurrently — the cross-core race the
/// M:N production scheduler exposes, exercised here under ThreadSanitizer.
const StressWorker = struct {
    registry: *ProcessRegistry,
    base_name: u64,
    iterations: usize,

    fn run(worker: *StressWorker) void {
        const alive = Liveness{};
        var i: usize = 0;
        while (i < worker.iterations) : (i += 1) {
            const name = worker.base_name + (i % 16);
            const pid = worker.base_name * 0x1_0000 + i + 1; // never 0
            // register → whereis → unregister; concurrent workers race the same
            // names, so register may be taken and unregister may miss — all valid.
            if ((try registry_register(worker.registry, name, pid, alive)) == .registered) {
                _ = worker.registry.whereis(name, alive);
                _ = worker.registry.unregister(name, pid);
            } else {
                // Someone else holds it; just probe (lock-free read under races).
                _ = worker.registry.whereis(name, alive);
            }
        }
    }

    fn registry_register(registry: *ProcessRegistry, name: u64, pid: u64, alive: Liveness) !RegisterOutcome {
        return registry.register(name, pid, alive) catch |err| switch (err) {
            error.RegistryFull => .name_taken, // treat as contention, keep looping
        };
    }
};

test "ProcessRegistry: concurrent register/whereis/unregister is race-free (TSan)" {
    var registry = try ProcessRegistry.init(testing.allocator, .{ .capacity = 256 });
    defer registry.deinit();

    const worker_count = 4;
    var workers: [worker_count]StressWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (&workers, 0..) |*worker, w| {
        worker.* = .{
            .registry = &registry,
            // Overlapping name ranges so workers contend on shared names.
            .base_name = 1 + @as(u64, w % 2) * 8,
            .iterations = 2000,
        };
    }
    for (&threads, 0..) |*thread, w| {
        thread.* = try std.Thread.spawn(.{}, StressWorker.run, .{&workers[w]});
    }
    for (&threads) |thread| thread.join();

    // Every worker unregisters what it registers, so at quiescence nothing is
    // left registered — leak-exact even after adversarial contention.
    try testing.expectEqual(@as(usize, 0), registry.liveEntryCount());
}
