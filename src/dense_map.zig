//! Dense, insertion-ordered, open-addressed Map.
//!
//! This is the new Map implementation that will eventually replace the
//! HAMT-backed `Map(K, V)` in `runtime.zig`. It is built in isolation here so
//! the existing Map can keep running unchanged until the new layout is fully
//! validated and a single swap commit flips the public name.
//!
//! Layout (single contiguous allocation, ankerl::unordered_dense style):
//!
//!   [ Header          (24 bytes packed: len, capacity, entry_cap, hash_seed) ]
//!   [ buckets[capacity] of Bucket (8 bytes each)                              ]
//!   [ entries[entry_cap] of Entry { hash, key, value }                        ]
//!
//! Empty map representation is a `null` `*const DenseMap(K, V)` — no allocation
//! at all until the first `put`. Initial capacity is 8.
//!
//! Probing is Robin Hood with a `(dist << 8) | fingerprint` packed metric.
//! Empty bucket sentinel is `0xFFFFFFFF`. Occupied buckets always have
//! `dist >= 1` so the home slot occupancy is unambiguous against the sentinel
//! for non-pathological capacities.
//!
//! Scope of THIS sub-deliverable (1.2 + 1.3 of the dense-map plan):
//!   * Buffer alloc / clone / release helpers.
//!   * `put`, `get`, `hasKey`, `size`, debug entry walker.
//!   * Robin Hood probing with backshift on swap (no delete yet).
//!   * Resize on load-factor breach.
//!   * NO rc-1 fast path: every `put` allocates a fresh buffer (the rc-1
//!     fast path lands in 1.6 alongside the ARC integration in 1.8).
//!   * NO ARC, NO retain/release, NO deep-release of K or V.
//!   * NO `delete`, `merge`, `keys`, `values`, `next`. Those are 1.4 / 1.7.
//!
//! Backing allocator: `std.heap.page_allocator` for now. Swapping to the
//! ARC-managed allocator happens in 1.8.

const std = @import("std");
const wyhash = @import("wyhash.zig");

/// Empty bucket sentinel. Any `Bucket.dist_and_fingerprint` equal to this means
/// "no occupant". Chosen to match the layout described in the plan.
pub const EMPTY: u32 = 0xFFFFFFFF;

/// Distance increment encoded into `dist_and_fingerprint`. Each step of the
/// probe chain adds one increment to the dist field (the high 24 bits of the
/// 32-bit composite). The home slot (first probe) has `dist = 1`, leaving 0
/// effectively unused so naive bit patterns can never collide with sentinel-
/// adjacent values.
pub const DIST_INC: u32 = 0x100;

/// Mask for extracting the 8-bit fingerprint (low byte of `dist_and_fingerprint`).
pub const FINGERPRINT_MASK: u32 = 0xFF;

/// Initial capacity chosen at first allocation. Power of 2.
pub const INITIAL_CAPACITY: u32 = 8;

/// Load factor numerator. We resize when `len + 1 > capacity * 7 / 8`.
pub const LOAD_NUM: u32 = 7;
pub const LOAD_DEN: u32 = 8;

/// Bucket — 8 bytes total, packed.
///
///   * `dist_and_fingerprint`: high 24 bits = dist (steps from home slot, +1
///     so the home slot reads `1`), low 8 bits = high byte of the 64-bit hash.
///     `EMPTY` (0xFFFFFFFF) means the slot is unoccupied.
///   * `entry_idx`: index into the entries[] array of this bucket's entry.
pub const Bucket = extern struct {
    dist_and_fingerprint: u32,
    entry_idx: u32,
};

comptime {
    std.debug.assert(@sizeOf(Bucket) == 8);
}

/// Header lives at the start of the buffer.
///
///   * `len`: number of populated entries (also the cursor for the next
///     entry). Always equals number of non-EMPTY buckets.
///   * `capacity`: number of buckets (always a power of 2, >= 8).
///   * `entry_cap`: number of entry slots (>= len; resizes when load factor
///     would exceed 7/8).
///   * `hash_seed`: per-instance random seed sampled from `wyhash.nextSeed`
///     at construction time. Used for every hash so resize is deterministic.
pub const Header = extern struct {
    len: u32,
    capacity: u32,
    entry_cap: u32,
    hash_seed: u64,
};

/// Compute the byte offset of the buckets array within a buffer of the given
/// capacity. Stable across allocations of the same shape.
inline fn bucketsOffset() usize {
    // Header is 24 bytes (4+4+4+8 with no padding because Header is extern
    // and aligned to 8). Buckets need 4-byte alignment which is satisfied.
    return std.mem.alignForward(usize, @sizeOf(Header), @alignOf(Bucket));
}

/// Compute the byte offset of the entries array.
inline fn entriesOffset(comptime EntryT: type, capacity: u32) usize {
    const after_buckets = bucketsOffset() + @as(usize, capacity) * @sizeOf(Bucket);
    return std.mem.alignForward(usize, after_buckets, @alignOf(EntryT));
}

/// Total buffer size for a (capacity, entry_cap) pair.
inline fn bufferSize(comptime EntryT: type, capacity: u32, entry_cap: u32) usize {
    return entriesOffset(EntryT, capacity) + @as(usize, entry_cap) * @sizeOf(EntryT);
}

/// Maximum alignment we ever need on a buffer: max of Header / Bucket /
/// Entry alignments. Used as the alignment passed to the allocator.
inline fn bufferAlignment(comptime EntryT: type) std.mem.Alignment {
    const a_header = std.mem.Alignment.of(Header);
    const a_bucket = std.mem.Alignment.of(Bucket);
    const a_entry = std.mem.Alignment.of(EntryT);
    return a_header.max(a_bucket).max(a_entry);
}

// -----------------------------------------------------------------------------
// DenseMap type
// -----------------------------------------------------------------------------

pub fn DenseMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        /// Entry stored densely in insertion order.
        ///
        ///   * `hash` is the full 64-bit hash, cached here so resize and
        ///     bucket comparison both run without rehashing the key.
        ///   * `key` and `value` are stored by value.
        ///
        /// Plain (non-extern) struct so K and V can be slices, optionals,
        /// tagged unions, etc. We compute layout/alignment manually.
        pub const Entry = struct {
            hash: u64,
            key: K,
            value: V,
        };

        /// Backing buffer pointer. The `DenseMap` cell is a thin handle.
        /// Callers communicate the empty map via `?*const Self == null`.
        buf: [*]align(@max(@alignOf(Header), @max(@alignOf(Bucket), @alignOf(Entry)))) u8,

        // -------------------------------------------------------------------
        // Buffer accessors
        // -------------------------------------------------------------------

        /// Read-only header reference.
        pub inline fn header(self: *const Self) *const Header {
            return @as(*const Header, @ptrCast(@alignCast(self.buf)));
        }

        /// Mutable header reference. Only safe for the unique owner.
        inline fn headerMut(self: *Self) *Header {
            return @as(*Header, @ptrCast(@alignCast(self.buf)));
        }

        /// Pointer to the first bucket. Valid for `header().capacity` slots.
        inline fn bucketsPtr(self: *const Self) [*]Bucket {
            return @as([*]Bucket, @ptrCast(@alignCast(self.buf + bucketsOffset())));
        }

        /// Pointer to the first entry. Valid for `header().entry_cap` slots
        /// (only `header().len` are live).
        inline fn entriesPtr(self: *const Self) [*]Entry {
            return @as([*]Entry, @ptrCast(@alignCast(self.buf + entriesOffset(Entry, self.header().capacity))));
        }

        /// Indexed bucket accessor (mutable).
        inline fn bucketAt(self: *Self, idx: u32) *Bucket {
            std.debug.assert(idx < self.header().capacity);
            return &self.bucketsPtr()[idx];
        }

        /// Indexed entry accessor (mutable).
        inline fn entryAt(self: *Self, idx: u32) *Entry {
            std.debug.assert(idx < self.header().len);
            return &self.entriesPtr()[idx];
        }

        /// Read-only entry accessor.
        pub inline fn entryAtConst(self: *const Self, idx: u32) *const Entry {
            std.debug.assert(idx < self.header().len);
            return &self.entriesPtr()[idx];
        }

        /// Number of live entries (also the next-insert cursor).
        pub inline fn size(self: *const Self) u32 {
            return self.header().len;
        }

        // -------------------------------------------------------------------
        // Buffer alloc / clone / release
        // -------------------------------------------------------------------

        /// Allocate a freshly-zeroed buffer for the given capacity (which
        /// determines both `capacity` and `entry_cap` since we keep them in
        /// lockstep at 1:1 in this iteration of the design).
        ///
        /// All bucket slots are initialized to EMPTY. `len` is 0. The seed is
        /// drawn from `wyhash.nextSeed` so two maps with the same insertions
        /// don't share a hash seed.
        fn bufferAlloc(capacity: u32, seed: u64) error{OutOfMemory}!*Self {
            std.debug.assert(std.math.isPowerOfTwo(capacity));
            const total = bufferSize(Entry, capacity, capacity);
            const allocator = std.heap.page_allocator;
            const align_v = comptime bufferAlignment(Entry);
            const raw = try allocator.alignedAlloc(u8, align_v, total);
            // Initialize the header.
            const hdr_ptr: *Header = @ptrCast(@alignCast(raw.ptr));
            hdr_ptr.* = .{
                .len = 0,
                .capacity = capacity,
                .entry_cap = capacity,
                .hash_seed = seed,
            };
            // Initialize all buckets to EMPTY. We fill via byte-wise memset.
            const buckets_byte_off = bucketsOffset();
            const buckets_ptr: [*]Bucket = @ptrCast(@alignCast(raw.ptr + buckets_byte_off));
            for (0..capacity) |i| {
                buckets_ptr[i] = .{ .dist_and_fingerprint = EMPTY, .entry_idx = 0 };
            }
            // Entries are uninitialized — only the first `len` are read.
            const self_ptr = try allocator.create(Self);
            self_ptr.* = .{ .buf = @alignCast(raw.ptr) };
            return self_ptr;
        }

        /// Release the buffer (and the handle). No-op for null.
        pub fn release(maybe_self: ?*Self) void {
            const self = maybe_self orelse return;
            const allocator = std.heap.page_allocator;
            const cap = self.header().capacity;
            const total = bufferSize(Entry, cap, self.header().entry_cap);
            const align_v = comptime bufferAlignment(Entry);
            const raw_slice = @as([*]align(align_v.toByteUnits()) u8, @alignCast(self.buf))[0..total];
            allocator.free(raw_slice);
            allocator.destroy(self);
        }

        /// Clone the buffer into a new buffer, possibly with a larger capacity.
        ///
        /// If `new_capacity == old.capacity` we copy buckets+entries verbatim.
        /// Otherwise we allocate at the new capacity, copy entries verbatim
        /// (preserving insertion order), and rebucket by re-probing each
        /// entry's cached hash.
        fn bufferClone(self: *const Self, new_capacity: u32) error{OutOfMemory}!*Self {
            std.debug.assert(std.math.isPowerOfTwo(new_capacity));
            const old = self;
            const old_hdr = old.header();
            std.debug.assert(new_capacity >= old_hdr.len);

            const fresh = try bufferAlloc(new_capacity, old_hdr.hash_seed);
            // Set len after we copy entries so size() during construction is
            // accurate even if anyone is watching.
            const fresh_hdr = fresh.headerMut();

            // Copy entries verbatim — preserves insertion order.
            const old_entries = old.entriesPtr();
            const new_entries = fresh.entriesPtr();
            for (0..old_hdr.len) |i| {
                new_entries[i] = old_entries[i];
            }
            fresh_hdr.len = old_hdr.len;

            if (new_capacity == old_hdr.capacity) {
                // Same capacity: copy buckets verbatim (entry indices stay valid).
                const old_buckets = old.bucketsPtr();
                const new_buckets = fresh.bucketsPtr();
                for (0..old_hdr.capacity) |i| {
                    new_buckets[i] = old_buckets[i];
                }
            } else {
                // Different capacity: rebucket by re-probing.
                fresh.rebucketAll();
            }
            return fresh;
        }

        /// Re-place every live entry into the bucket array via Robin Hood
        /// probing. Assumes the bucket array is currently all-EMPTY (as fresh
        /// from `bufferAlloc`).
        fn rebucketAll(self: *Self) void {
            const len = self.header().len;
            const seed = self.header().hash_seed;
            _ = seed; // we use cached entry.hash, not the seed
            for (0..len) |i| {
                const entry_idx: u32 = @intCast(i);
                const entry = self.entryAt(entry_idx);
                self.installBucket(entry.hash, entry_idx);
            }
        }

        // -------------------------------------------------------------------
        // Hash / probe helpers
        // -------------------------------------------------------------------

        /// Hash a key using the per-instance seed. Comptime-dispatches on K.
        inline fn hashKey(self: *const Self, key: K) u64 {
            return wyhash.hash(self.header().hash_seed, key);
        }

        /// Compute the initial probe (`dist=1, fingerprint=hash>>56`).
        inline fn initialProbe(hash: u64) u32 {
            const fp: u32 = @intCast(hash >> 56);
            return DIST_INC | fp;
        }

        /// Compute the home slot for `hash`.
        inline fn homeSlot(self: *const Self, hash: u64) u32 {
            const mask: u32 = self.header().capacity - 1;
            return @as(u32, @truncate(hash)) & mask;
        }

        /// Step the slot index by 1 modulo capacity.
        inline fn nextSlot(self: *const Self, slot: u32) u32 {
            const mask: u32 = self.header().capacity - 1;
            return (slot + 1) & mask;
        }

        // -------------------------------------------------------------------
        // Lookup / containment
        // -------------------------------------------------------------------

        /// Find the entry matching `key` if any. Returns its entry index, or
        /// null if not present.
        pub fn findEntry(maybe_self: ?*const Self, key: K) ?u32 {
            const self = maybe_self orelse return null;
            if (self.header().len == 0) return null;
            const hash = self.hashKey(key);
            var probe = initialProbe(hash);
            var slot = self.homeSlot(hash);
            const buckets = self.bucketsPtr();
            const entries = self.entriesPtr();
            while (true) {
                const b = buckets[slot];
                if (b.dist_and_fingerprint == EMPTY) return null;
                if (b.dist_and_fingerprint < probe) return null;
                if (b.dist_and_fingerprint == probe) {
                    const e = &entries[b.entry_idx];
                    if (e.hash == hash and keysEqual(e.key, key)) return b.entry_idx;
                }
                probe += DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        /// Whether `key` is in the map.
        pub fn hasKey(maybe_self: ?*const Self, key: K) bool {
            return findEntry(maybe_self, key) != null;
        }

        /// Get the value for `key`, or `default_value` if absent.
        pub fn get(maybe_self: ?*const Self, key: K, default_value: V) V {
            const self = maybe_self orelse return default_value;
            const idx = findEntry(self, key) orelse return default_value;
            return self.entryAtConst(idx).value;
        }

        // -------------------------------------------------------------------
        // Insert (no rc-1 fast path yet — always allocates a fresh buffer)
        // -------------------------------------------------------------------

        /// Insert or update `(key, value)`. Returns a fresh buffer; the input
        /// (if any) is left untouched but should be released by the caller
        /// after switching the live handle.
        ///
        /// In this sub-deliverable we deliberately have no rc-1 fast path:
        /// every `put` clones the buffer. The fast path is wired in at 1.6.
        pub fn put(maybe_self: ?*const Self, key: K, value: V) error{OutOfMemory}!*Self {
            // Step 1: figure out whether the key already exists in the input
            // map. If so the new map is a same-size clone with the matching
            // entry's value overwritten.
            if (maybe_self) |self| {
                if (findEntry(self, key)) |existing_idx| {
                    const fresh = try bufferClone(self, self.header().capacity);
                    fresh.entryAt(existing_idx).value = value;
                    return fresh;
                }
            }

            // Step 2: this is a true insert. Decide the target capacity.
            const old_len: u32 = if (maybe_self) |s| s.header().len else 0;
            const old_cap: u32 = if (maybe_self) |s| s.header().capacity else 0;
            const new_cap: u32 = pickCapacity(old_cap, old_len + 1);

            // Step 3: allocate the destination. Either clone (same capacity)
            // or fresh + rebucket (resize).
            var fresh: *Self = if (maybe_self) |s|
                try bufferClone(s, new_cap)
            else
                try bufferAlloc(new_cap, wyhash.nextSeed());

            // Step 4: append the new entry, install its bucket via Robin Hood.
            const hash = fresh.hashKey(key);
            const fresh_hdr = fresh.headerMut();
            const new_idx: u32 = fresh_hdr.len;
            std.debug.assert(new_idx < fresh_hdr.entry_cap);
            const entries = fresh.entriesPtr();
            entries[new_idx] = .{ .hash = hash, .key = key, .value = value };
            fresh_hdr.len = new_idx + 1;

            fresh.installBucket(hash, new_idx);
            return fresh;
        }

        // -------------------------------------------------------------------
        // Delete (swap-remove + Robin Hood backshift)
        // -------------------------------------------------------------------

        /// Remove `key` from the map. Returns a fresh buffer (the contract
        /// matches `put`: every mutating op clones in this iteration; the
        /// rc-1 fast path lands in 1.6). The input buffer is left untouched
        /// and must be released by the caller.
        ///
        /// Behavior:
        ///   * `map == null` -> returns null (the empty map is closed under
        ///     delete).
        ///   * `key` absent -> returns a fresh same-shape clone with identical
        ///     contents (matches the persistent-map contract: callers can
        ///     always rely on getting a fresh handle back).
        ///   * `key` present -> swap-remove: swap `entries[entry_idx]` with
        ///     `entries[len-1]` (if not already the tail), patch the bucket
        ///     that pointed at `len-1` to point at `entry_idx`, decrement
        ///     `len`, then backshift the bucket array starting from the
        ///     deleted slot until we hit either an empty slot or a bucket
        ///     already at its ideal position (`dist == 1`).
        pub fn delete(maybe_map: ?*const Self, key: K) ?*const Self {
            const map = maybe_map orelse return null;

            // Always allocate a fresh buffer. We mutate the clone, never the
            // original — the caller still owns the input.
            const fresh = bufferClone(map, map.header().capacity) catch return null;

            const found_entry_idx = findEntry(fresh, key) orelse return fresh;

            const fresh_hdr = fresh.headerMut();
            const old_len = fresh_hdr.len;
            std.debug.assert(old_len > 0);

            // Locate the bucket that currently owns `key` so we can clear it
            // and start backshifting from there.
            const target_hash = fresh.entryAtConst(found_entry_idx).hash;
            const deleted_slot = fresh.findBucketSlotForEntry(target_hash, found_entry_idx);

            // Swap-remove on the entries array.
            if (found_entry_idx != old_len - 1) {
                const tail_idx: u32 = old_len - 1;
                const tail_entry = fresh.entryAt(tail_idx).*;

                // Find the bucket that points at `tail_idx` and repoint it at
                // `found_entry_idx`. Re-probe with the tail entry's cached
                // hash + key — Robin Hood lookup will land on it.
                const tail_slot = fresh.findBucketSlotForEntry(tail_entry.hash, tail_idx);
                fresh.bucketAt(tail_slot).entry_idx = found_entry_idx;

                // Move the tail entry into the freed slot.
                fresh.entryAt(found_entry_idx).* = tail_entry;
            }

            // Decrement len. The previous tail entry slot is now logically
            // dead (its contents are stale but unreferenced).
            fresh_hdr.len = old_len - 1;

            // Backshift buckets starting at `deleted_slot`. Walk forward;
            // while the next slot is occupied AND its dist > 1, move it back
            // and decrement its dist by one. Stop on empty or dist == 1.
            const buckets = fresh.bucketsPtr();
            buckets[deleted_slot] = .{ .dist_and_fingerprint = EMPTY, .entry_idx = 0 };
            var cur = deleted_slot;
            while (true) {
                const nxt = fresh.nextSlot(cur);
                const nxt_dnf = buckets[nxt].dist_and_fingerprint;
                if (nxt_dnf == EMPTY) break;
                const nxt_dist = nxt_dnf >> 8;
                if (nxt_dist <= 1) break;
                // Shift the next bucket back into `cur`, decrementing its dist.
                const fp = nxt_dnf & FINGERPRINT_MASK;
                const new_dist = nxt_dist - 1;
                buckets[cur] = .{
                    .dist_and_fingerprint = (new_dist << 8) | fp,
                    .entry_idx = buckets[nxt].entry_idx,
                };
                buckets[nxt] = .{ .dist_and_fingerprint = EMPTY, .entry_idx = 0 };
                cur = nxt;
            }

            return fresh;
        }

        /// Find the bucket slot that currently references `entry_idx` for the
        /// given cached hash. Used by `delete` both to locate the deleted
        /// key's bucket and to re-locate the tail entry's bucket after
        /// swap-remove. The lookup is a Robin Hood probe filtered on
        /// `entry_idx` (rather than key-equality) since the entry's key may
        /// be a slice that's expensive to compare and the entry_idx is
        /// already unique.
        fn findBucketSlotForEntry(self: *Self, hash: u64, entry_idx: u32) u32 {
            var probe = initialProbe(hash);
            var slot = self.homeSlot(hash);
            const buckets = self.bucketsPtr();
            while (true) {
                const b = buckets[slot];
                std.debug.assert(b.dist_and_fingerprint != EMPTY);
                std.debug.assert(b.dist_and_fingerprint >= probe);
                if (b.dist_and_fingerprint == probe and b.entry_idx == entry_idx) {
                    return slot;
                }
                probe += DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        /// Place a single bucket record for `(hash, entry_idx)` into the
        /// bucket array via Robin Hood probing. Assumes the entry is already
        /// stored in `entries[entry_idx]`.
        ///
        /// Loop invariant: at the head of each iteration, `probe` and
        /// `slot` describe where the *currently-being-placed* bucket wants
        /// to go; `cur_entry_idx` is its entry's index.
        fn installBucket(self: *Self, hash: u64, entry_idx: u32) void {
            var probe = initialProbe(hash);
            var slot = self.homeSlot(hash);
            var cur_entry_idx = entry_idx;
            const buckets = self.bucketsPtr();
            while (true) {
                const dnf = buckets[slot].dist_and_fingerprint;
                if (dnf == EMPTY) {
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    return;
                }
                if (dnf < probe) {
                    // Robin Hood swap: the current resident is "richer" (smaller
                    // probe distance). Take its slot and re-place the displaced
                    // record from here.
                    const displaced = buckets[slot];
                    buckets[slot] = .{ .dist_and_fingerprint = probe, .entry_idx = cur_entry_idx };
                    probe = displaced.dist_and_fingerprint;
                    cur_entry_idx = displaced.entry_idx;
                }
                probe += DIST_INC;
                slot = self.nextSlot(slot);
            }
        }

        /// Pick the capacity for a buffer that must hold at least
        /// `target_len` entries under the 7/8 load factor. Always a power of
        /// 2, never less than `INITIAL_CAPACITY`, never less than the input
        /// capacity (we never shrink in this design).
        fn pickCapacity(old_cap: u32, target_len: u32) u32 {
            var cap: u32 = if (old_cap == 0) INITIAL_CAPACITY else old_cap;
            while (target_len * LOAD_DEN > cap * LOAD_NUM) {
                cap *= 2;
            }
            return cap;
        }

        // -------------------------------------------------------------------
        // Key equality
        // -------------------------------------------------------------------

        inline fn keysEqual(a: K, b: K) bool {
            const ti = @typeInfo(K);
            return switch (ti) {
                .int, .comptime_int, .bool => a == b,
                .pointer => |p| if (p.size == .slice and p.child == u8)
                    std.mem.eql(u8, a, b)
                else
                    a == b,
                else => @compileError("DenseMap: unsupported key type " ++ @typeName(K)),
            };
        }

        // -------------------------------------------------------------------
        // Debug iterator (entries in insertion order).
        // -------------------------------------------------------------------

        /// Walk all live entries in insertion order. The slice is a view into
        /// the live buffer — do not retain it past the next `put`.
        pub fn debugEntriesSlice(self: *const Self) []const Entry {
            const len = self.header().len;
            return self.entriesPtr()[0..len];
        }

        /// Walk all bucket records (even empty ones) for tests that need to
        /// inspect Robin Hood invariants.
        pub fn debugBucketsSlice(self: *const Self) []const Bucket {
            const cap = self.header().capacity;
            return self.bucketsPtr()[0..cap];
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "DenseMap put + get on a small map" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    m = try M.put(m, 1, 100);
    m = try M.put(m, 2, 200);
    m = try M.put(m, 3, 300);

    try testing.expectEqual(@as(u64, 100), M.get(m, 1, 0));
    try testing.expectEqual(@as(u64, 200), M.get(m, 2, 0));
    try testing.expectEqual(@as(u64, 300), M.get(m, 3, 0));
    try testing.expectEqual(@as(u32, 3), m.?.size());
}

test "DenseMap get returns default for absent key" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    m = try M.put(m, 1, 100);
    try testing.expectEqual(@as(u64, 999), M.get(m, 7, 999));
}

test "DenseMap hasKey on absent key returns false" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    m = try M.put(m, 42, 1);
    try testing.expect(M.hasKey(m, 42));
    try testing.expect(!M.hasKey(m, 43));
    try testing.expect(!M.hasKey(null, 0));
}

test "DenseMap put updates existing key (size doesn't grow)" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    m = try M.put(m, 5, 50);
    const m_after_first = m.?;
    try testing.expectEqual(@as(u32, 1), m_after_first.size());

    // Update the value.
    const m_new = try M.put(m, 5, 500);
    M.release(m); // release prior buffer
    m = m_new;

    try testing.expectEqual(@as(u32, 1), m.?.size());
    try testing.expectEqual(@as(u64, 500), M.get(m, 5, 0));
}

test "DenseMap insertion order preserved" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    const ks = [_]u64{ 7, 3, 11, 5, 9 };
    for (ks) |k| {
        const next = try M.put(m, k, k * 10);
        M.release(m);
        m = next;
    }

    const entries = m.?.debugEntriesSlice();
    try testing.expectEqual(@as(usize, 5), entries.len);
    for (entries, ks) |e, expected_k| {
        try testing.expectEqual(expected_k, e.key);
        try testing.expectEqual(expected_k * 10, e.value);
    }
}

test "DenseMap put 100 random integer keys, retrieve all" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    var prng = std.Random.DefaultPrng.init(0xCAFEF00D);
    const random = prng.random();

    var keys: [100]u64 = undefined;
    for (&keys) |*k| {
        k.* = random.int(u64) | 1; // avoid 0 collisions for clarity
    }
    // Dedupe to avoid update-vs-insert ambiguity.
    var unique: [100]u64 = undefined;
    var unique_count: usize = 0;
    outer: for (keys) |k| {
        for (unique[0..unique_count]) |u| {
            if (u == k) continue :outer;
        }
        unique[unique_count] = k;
        unique_count += 1;
    }

    for (unique[0..unique_count]) |k| {
        const next = try M.put(m, k, k +% 7);
        M.release(m);
        m = next;
    }

    try testing.expectEqual(@as(u32, @intCast(unique_count)), m.?.size());
    for (unique[0..unique_count]) |k| {
        try testing.expectEqual(k +% 7, M.get(m, k, 0));
        try testing.expect(M.hasKey(m, k));
    }
}

test "DenseMap forced collisions at small capacity" {
    // Insert 6 keys that all share the same (hash & 7) home slot. Capacity
    // starts at 8 so they all collide. We verify all 6 are findable and the
    // load factor stays under threshold (6 < 8 * 7/8 == 7).
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    // We don't know the seed up front, so build the map first to learn it,
    // then craft colliding keys via brute force. The test stays deterministic
    // because we just need *some* set of 6 colliding keys.
    m = try M.put(m, 1, 1);
    const seed = m.?.header().hash_seed;
    M.release(m);
    m = null;

    // Find 6 keys with the same (hash & 7).
    var collide: [6]u64 = undefined;
    var found: usize = 0;
    var probe_key: u64 = 1;
    const target_home = wyhash.hash(seed, @as(u64, 1)) & 7;
    while (found < collide.len) : (probe_key += 1) {
        const h = wyhash.hash(seed, probe_key);
        if ((h & 7) == target_home) {
            collide[found] = probe_key;
            found += 1;
        }
    }

    // Re-create a fresh map with the same seed by inserting the same first key.
    // Note: each fresh allocation gets a new seed via wyhash.nextSeed, so we
    // need to build the map up via puts and live with whatever seed we get;
    // but our colliding-keys enumeration above used the seed we extracted
    // from the *previous* map, which was discarded. We can't bind a new map's
    // seed to a known value through the public API. So instead: build the
    // colliding set lazily — for any seed, pick keys whose hash & (cap-1)
    // matches the first key's home slot.
    m = try M.put(m, collide[0], collide[0]);
    const new_seed = m.?.header().hash_seed;
    if (new_seed != seed) {
        // Reseed-driven: rebuild the collide set against the new seed.
        const new_home = wyhash.hash(new_seed, collide[0]) & 7;
        var refound: usize = 1;
        var pk: u64 = collide[0] + 1;
        while (refound < collide.len) : (pk += 1) {
            const h = wyhash.hash(new_seed, pk);
            if ((h & 7) == new_home) {
                collide[refound] = pk;
                refound += 1;
            }
        }
    }

    for (collide[1..]) |k| {
        const next = try M.put(m, k, k);
        M.release(m);
        m = next;
    }
    try testing.expectEqual(@as(u32, 6), m.?.size());
    for (collide) |k| {
        try testing.expectEqual(k, M.get(m, k, 0));
    }
    // Capacity must have stayed at 8 (load factor 6/8 = 0.75 < 0.875).
    try testing.expectEqual(@as(u32, 8), m.?.header().capacity);
}

test "DenseMap resize doubles capacity at load factor breach" {
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    // Capacity starts at 8. At 7 entries we are at 7/8 load — the 8th insert
    // forces a resize because (8 * 8) > (8 * 7).
    var i: u64 = 0;
    while (i < 7) : (i += 1) {
        const next = try M.put(m, i, i * 11);
        M.release(m);
        m = next;
    }
    try testing.expectEqual(@as(u32, 8), m.?.header().capacity);
    try testing.expectEqual(@as(u32, 7), m.?.size());

    // 8th insert triggers resize.
    const next = try M.put(m, 7, 77);
    M.release(m);
    m = next;
    try testing.expectEqual(@as(u32, 16), m.?.header().capacity);
    try testing.expectEqual(@as(u32, 8), m.?.size());

    // All keys still findable.
    i = 0;
    while (i < 8) : (i += 1) {
        const expected: u64 = if (i == 7) 77 else i * 11;
        try testing.expectEqual(expected, M.get(m, i, 999));
    }
}

test "DenseMap Robin Hood invariant after adversarial inserts" {
    // The Robin Hood invariant: walking the bucket array, no occupied bucket
    // has a probe distance greater than its successor's, *unless* the
    // successor is empty or has a smaller home slot index that wraps past it.
    //
    // We can simplify by checking the local rule: for every non-empty slot
    // i, if slot (i+1)&mask is also non-empty, then dist(i) >= dist(i+1) - 1.
    // Equivalently: dist(i+1) <= dist(i) + 1. This holds because Robin Hood
    // ensures consecutive probes can only differ by at most 1 in distance.
    const M = DenseMap(u64, u64);
    var m: ?*M = null;
    defer M.release(m);

    var prng = std.Random.DefaultPrng.init(0x1234567890ABCDEF);
    const random = prng.random();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const k = random.int(u64);
        const next = try M.put(m, k, k);
        M.release(m);
        m = next;
    }

    const cap = m.?.header().capacity;
    const buckets = m.?.debugBucketsSlice();
    var idx: u32 = 0;
    while (idx < cap) : (idx += 1) {
        const a = buckets[idx];
        const b = buckets[(idx + 1) & (cap - 1)];
        if (a.dist_and_fingerprint == EMPTY or b.dist_and_fingerprint == EMPTY) continue;
        const dist_a = a.dist_and_fingerprint >> 8;
        const dist_b = b.dist_and_fingerprint >> 8;
        // Robin Hood local invariant: dist_b <= dist_a + 1.
        try testing.expect(dist_b <= dist_a + 1);
    }
}

test "DenseMap byte-slice keys" {
    const M = DenseMap([]const u8, u64);
    var m: ?*M = null;
    defer M.release(m);

    m = try M.put(m, "alpha", 1);
    {
        const next = try M.put(m, "beta", 2);
        M.release(m);
        m = next;
    }
    {
        const next = try M.put(m, "gamma", 3);
        M.release(m);
        m = next;
    }

    try testing.expectEqual(@as(u64, 1), M.get(m, "alpha", 0));
    try testing.expectEqual(@as(u64, 2), M.get(m, "beta", 0));
    try testing.expectEqual(@as(u64, 3), M.get(m, "gamma", 0));
    try testing.expect(!M.hasKey(m, "delta"));
}

test "DenseMap u32 (Atom-like) keys" {
    const M = DenseMap(u32, u64);
    var m: ?*M = null;
    defer M.release(m);

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const next = try M.put(m, i, @as(u64, i) * 100);
        M.release(m);
        m = next;
    }
    try testing.expectEqual(@as(u32, 20), m.?.size());
    i = 0;
    while (i < 20) : (i += 1) {
        try testing.expectEqual(@as(u64, i) * 100, M.get(m, i, 0));
    }
}

test "DenseMap empty map operations" {
    const M = DenseMap(u64, u64);
    try testing.expect(!M.hasKey(null, 0));
    try testing.expectEqual(@as(u64, 42), M.get(null, 0, 42));
    try testing.expectEqual(@as(?u32, null), M.findEntry(null, 0));
}

// =============================================================================
// 1.4 — delete with swap-remove
// =============================================================================

test "DenseMap delete: swap-remove of middle entry preserves other keys" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    // Insert 5 keys (1,2,3,4,5).
    var i: u64 = 1;
    while (i <= 5) : (i += 1) {
        const next = try M.put(m, i, i * 10);
        M.release(@constCast(m));
        m = next;
    }
    try testing.expectEqual(@as(u32, 5), m.?.size());

    // Delete the 2nd-inserted key (key=2). With swap-remove, entries[1] should
    // be replaced by what was previously at entries[4] (key=5). The expected
    // entry order becomes [1, 5, 3, 4].
    const after = M.delete(m, 2);
    M.release(@constCast(m));
    m = after;
    try testing.expect(m != null);
    try testing.expectEqual(@as(u32, 4), m.?.size());

    // Key 2 must no longer be present.
    try testing.expect(!M.hasKey(m, 2));

    // The remaining keys must still be findable.
    try testing.expectEqual(@as(u64, 10), M.get(m, 1, 0));
    try testing.expectEqual(@as(u64, 30), M.get(m, 3, 0));
    try testing.expectEqual(@as(u64, 40), M.get(m, 4, 0));
    try testing.expectEqual(@as(u64, 50), M.get(m, 5, 0));

    // Insertion-order walk must reflect swap-remove: [1, 5, 3, 4].
    const entries = m.?.debugEntriesSlice();
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].key);
    try testing.expectEqual(@as(u64, 5), entries[1].key);
    try testing.expectEqual(@as(u64, 3), entries[2].key);
    try testing.expectEqual(@as(u64, 4), entries[3].key);
}

test "DenseMap delete: last entry needs no swap" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    var i: u64 = 1;
    while (i <= 4) : (i += 1) {
        const next = try M.put(m, i, i);
        M.release(@constCast(m));
        m = next;
    }

    // Delete the last-inserted key — no swap necessary.
    const after = M.delete(m, 4);
    M.release(@constCast(m));
    m = after;

    try testing.expectEqual(@as(u32, 3), m.?.size());
    try testing.expect(!M.hasKey(m, 4));
    const entries = m.?.debugEntriesSlice();
    try testing.expectEqual(@as(u64, 1), entries[0].key);
    try testing.expectEqual(@as(u64, 2), entries[1].key);
    try testing.expectEqual(@as(u64, 3), entries[2].key);
}

test "DenseMap delete: only entry yields empty (len=0) map" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    m = try M.put(m, 7, 70);
    const after = M.delete(m, 7);
    M.release(@constCast(m));
    m = after;
    try testing.expect(m != null); // still a valid (empty) buffer
    try testing.expectEqual(@as(u32, 0), m.?.size());
    try testing.expect(!M.hasKey(m, 7));
}

test "DenseMap delete: absent key returns fresh clone with same contents" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    var i: u64 = 1;
    while (i <= 3) : (i += 1) {
        const next = try M.put(m, i, i * 5);
        M.release(@constCast(m));
        m = next;
    }
    const original = m.?;

    const after = M.delete(m, 999); // not present
    try testing.expect(after != null);
    try testing.expect(after.? != original); // fresh allocation
    try testing.expectEqual(@as(u32, 3), after.?.size());
    try testing.expectEqual(@as(u64, 5), M.get(after, 1, 0));
    try testing.expectEqual(@as(u64, 10), M.get(after, 2, 0));
    try testing.expectEqual(@as(u64, 15), M.get(after, 3, 0));

    M.release(@constCast(m));
    m = after;
}

test "DenseMap delete: null map returns null (no-op)" {
    const M = DenseMap(u64, u64);
    const result = M.delete(null, 42);
    try testing.expectEqual(@as(?*const M, null), result);
}

test "DenseMap delete: with forced collisions, remaining keys still findable" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    // Insert one key to learn the seed.
    m = try M.put(m, 1, 1);
    const seed = m.?.header().hash_seed;

    // Find 4 keys (including key=1) sharing the same home slot at cap=8.
    var collide: [4]u64 = undefined;
    collide[0] = 1;
    var found: usize = 1;
    const home0 = wyhash.hash(seed, @as(u64, 1)) & 7;
    var probe_key: u64 = 2;
    while (found < collide.len) : (probe_key += 1) {
        if ((wyhash.hash(seed, probe_key) & 7) == home0) {
            collide[found] = probe_key;
            found += 1;
        }
    }

    for (collide[1..]) |k| {
        const next = try M.put(m, k, k);
        M.release(@constCast(m));
        m = next;
    }
    try testing.expectEqual(@as(u32, 4), m.?.size());

    // Delete the middle (chronologically 2nd) of the colliding keys.
    const victim = collide[1];
    const after = M.delete(m, victim);
    M.release(@constCast(m));
    m = after;

    try testing.expectEqual(@as(u32, 3), m.?.size());
    try testing.expect(!M.hasKey(m, victim));
    try testing.expect(M.hasKey(m, collide[0]));
    try testing.expect(M.hasKey(m, collide[2]));
    try testing.expect(M.hasKey(m, collide[3]));
}

test "DenseMap delete: backshift compacts displaced buckets" {
    // Force a long probe chain by inserting keys whose home slot is the same.
    // After deleting the home-slot occupant, the displaced buckets must be
    // shifted back so they all sit at smaller probe distances.
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    m = try M.put(m, 1, 1);
    const seed = m.?.header().hash_seed;

    // Find 5 keys all sharing the same home slot at cap=8.
    var collide: [5]u64 = undefined;
    collide[0] = 1;
    var found: usize = 1;
    const home0 = wyhash.hash(seed, @as(u64, 1)) & 7;
    var probe_key: u64 = 2;
    while (found < collide.len) : (probe_key += 1) {
        if ((wyhash.hash(seed, probe_key) & 7) == home0) {
            collide[found] = probe_key;
            found += 1;
        }
    }
    for (collide[1..]) |k| {
        const next = try M.put(m, k, k);
        M.release(@constCast(m));
        m = next;
    }
    try testing.expectEqual(@as(u32, 5), m.?.size());

    // Snapshot dist counts before delete.
    const cap = m.?.header().capacity;
    const before_buckets = m.?.debugBucketsSlice();
    var before_total_dist: u32 = 0;
    for (before_buckets[0..cap]) |b| {
        if (b.dist_and_fingerprint != EMPTY) {
            before_total_dist += b.dist_and_fingerprint >> 8;
        }
    }

    // Delete the home-slot occupant (the first inserted key).
    const after = M.delete(m, collide[0]);
    M.release(@constCast(m));
    m = after;
    try testing.expectEqual(@as(u32, 4), m.?.size());

    // After backshift, the total displacement across remaining buckets must
    // strictly decrease (each survivor moved closer to its home slot).
    const after_buckets = m.?.debugBucketsSlice();
    var after_total_dist: u32 = 0;
    for (after_buckets[0..m.?.header().capacity]) |b| {
        if (b.dist_and_fingerprint != EMPTY) {
            after_total_dist += b.dist_and_fingerprint >> 8;
        }
    }
    try testing.expect(after_total_dist < before_total_dist);

    // All remaining keys still findable.
    for (collide[1..]) |k| {
        try testing.expect(M.hasKey(m, k));
    }
}

test "DenseMap delete: Robin Hood invariant holds after deletion" {
    const M = DenseMap(u64, u64);
    var m: ?*const M = null;
    defer M.release(@constCast(m));

    var prng = std.Random.DefaultPrng.init(0xDEADBEEFCAFEBABE);
    const random = prng.random();

    // Insert 30 random keys.
    var inserted: [30]u64 = undefined;
    var n: usize = 0;
    while (n < inserted.len) {
        const k = random.int(u64);
        // Skip dupes.
        var dup = false;
        for (inserted[0..n]) |existing| {
            if (existing == k) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const next = try M.put(m, k, k);
        M.release(@constCast(m));
        m = next;
        inserted[n] = k;
        n += 1;
    }

    // Delete every 3rd key.
    var i: usize = 0;
    while (i < inserted.len) : (i += 3) {
        const next = M.delete(m, inserted[i]);
        M.release(@constCast(m));
        m = next;
    }

    // Verify Robin Hood local invariant: dist[i+1] <= dist[i] + 1 between
    // consecutive non-empty buckets.
    const cap = m.?.header().capacity;
    const buckets = m.?.debugBucketsSlice();
    var idx: u32 = 0;
    while (idx < cap) : (idx += 1) {
        const a = buckets[idx];
        const b = buckets[(idx + 1) & (cap - 1)];
        if (a.dist_and_fingerprint == EMPTY or b.dist_and_fingerprint == EMPTY) continue;
        const dist_a = a.dist_and_fingerprint >> 8;
        const dist_b = b.dist_and_fingerprint >> 8;
        try testing.expect(dist_b <= dist_a + 1);
    }
}
