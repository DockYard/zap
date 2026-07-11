//! `Zap.Blob` — THE one sanctioned share tier of the Zap isolation model.
//!
//! Phase 6 item 6.2 of `docs/concurrency-implementation-plan.md` (job
//! P6-J2): the atomically-refcounted, deeply immutable, opaque byte
//! buffer that research.md §6.4 (regime 2) and
//! `zap-concurrency-research.md` §2.4/§5.4 sanction as the ONE exception
//! to "no shared value crosses a process boundary". Every production
//! actor system converged on exactly this escape hatch (Erlang refc
//! binaries, Pony `val` under ORCA, BEAM literal areas /
//! `persistent_term`); Zap adopts it in its most bounded form:
//!
//! * **Deeply immutable, opaque bytes.** A blob's payload is written
//!   exactly once, at creation (copy-IN), and never mutated afterward —
//!   there is no mutation API of any kind. Immutability is what makes
//!   the sharing safe: no cross-process write can exist, so no data race
//!   on the payload can exist.
//! * **Shared BY POINTER across processes.** A send of a blob bit-copies
//!   the handle and atomically increments the share count — no byte is
//!   copied, no manager heap is touched, no copy stub or message walker
//!   runs. The payload is model-independent (§2.4: "the one payload that
//!   never touches the stub matrix"), so the same share works
//!   same-model and cross-model.
//! * **Its own allocation domain.** Blob payloads live off EVERY process
//!   heap — page-allocator-backed allocations owned by the blob domain
//!   itself, exactly like the envelope pool is the message system's own
//!   domain (`envelope_pool.zig`, the third-allocation-domain
//!   precedent). A process's manager never sees a blob byte, so per-spawn
//!   managers, wholesale teardown frees, and the copy walker are all
//!   untouched by blobs.
//! * **Lifetime outlives any single process.** The share count is the
//!   only owner: a crashed process's teardown merely decrements (its
//!   blob ledger drains — `BlobLedger`), never corrupting another heap.
//!   Sender dies → receiver's blob stays valid; last holder dies → the
//!   payload is freed, leak-exactly.
//! * **NO sub-blob aliasing (v1).** `slice` COPIES OUT into a fresh blob
//!   — never an aliasing view into the parent. This is a deliberate,
//!   evidence-backed exclusion: Erlang's sub-binaries pinning huge refc
//!   binaries is the original "binary leak" pathology, Java shared
//!   substring backing until JDK-4513622 forced the 7u6 copy-out change
//!   (one deployment dropped ~60 GB → ~24 MB), and Swift's
//!   `String`/`Substring` split (SE-0163) enforces copy-out at the type
//!   level citing the Java reversal. Zap defeats the pin pathology by
//!   construction (rev-2 §5.4 resolution 1); an explicit opt-in aliasing
//!   view is the documented FOLLOW-ON (resolution 4), not the default.
//!
//! ## The Blob-backed String tier (P6-J3, plan item 6.3)
//!
//! Large `String` values ride this domain so a cross-process string send
//! is a zero-copy handle share instead of the deep-copy walker's
//! byte-copy (rev-2 §5.4). The domain provides the MECHANISM only —
//! policy (the promotion threshold, when a send promotes) lives in the
//! runtime (`src/runtime.zig`). Three mechanisms:
//!
//! * **Recognition by layout, not by type** (`resolveWholePayloadView`).
//!   A Zap `String` is a bare `[]const u8` — there is no room in the
//!   value for a handle — so a blob-backed string is recognized from its
//!   pointer: every payload sits at exactly `header_byte_length` bytes
//!   past a page boundary (the page allocator returns page-aligned
//!   blocks), so a candidate pointer at any other page offset is
//!   rejected without touching memory, and a pointer AT that offset has
//!   its 24 preceding same-page bytes read as a `BlobHeader` whose
//!   handle must round-trip through the slot table back to this exact
//!   payload address. A false positive is therefore impossible: the
//!   probe accepts only pointers whose preceding header IS a live slot's
//!   real header. The probe accepts only the WHOLE-payload view
//!   (`length == byte_length`) — a prefix or interior slice NEVER
//!   shares (it re-copies at the boundary), which is what makes the
//!   copy-out-slices law airtight cross-process: no small view can pin
//!   a large payload in another process.
//! * **Capacity slack + `createFromParts`.** Every payload allocation is
//!   rounded up to whole pages (free real-memory-wise under the page
//!   allocator) and the slack recorded as `payload_capacity`, so a
//!   string-backing blob has append room. `createFromParts` builds a
//!   promoted concat result (`base ++ extra`) in one copy with a
//!   caller-chosen minimum capacity (the geometric-growth hook).
//! * **rc==1 in-place append** (`tryAppendInPlace`) — the Erlang
//!   writable-binary optimization. When the share count is EXACTLY 1 and
//!   the caller owns that one reference, no other holder exists anywhere
//!   — no process, no in-flight envelope, no registry entry — so
//!   appending within capacity mutates nothing any other holder can
//!   observe: immutability is OBSERVATIONALLY absolute for every holder
//!   that is not the sole owner. The append writes only at the frontier
//!   (`[byte_length, byte_length+extra)`), so even same-process aliases
//!   (whose extent is ≤ the frontier by construction) see unchanged
//!   bytes. Once shared (count > 1) the payload is frozen forever from
//!   the appender's point of view — the caller copies instead.
//!
//! ## Constraint 3 — the atomic confinement contract
//!
//! Zap's ordinary ARC is NON-atomic by sacred invariant (every
//! refcounted cell is strictly scheduler-local). The blob tier is the
//! ONE place cross-thread refcounting exists, and its atomicity is
//! confined to exactly this module's structures:
//!
//! | atomic | op / ordering | why |
//! |---|---|---|
//! | `BlobSlot.state` (packed `{share_count, generation}`) | retain: gen-validated CAS `.acq_rel`; release: CAS `.acq_rel` (the 1→0 winner bumps the generation IN THE SAME CAS); reads: `.acquire` | the count is mutated from any scheduler thread; packing count+generation into ONE word makes validate-and-mutate a single atomic decision, so a stale handle can never resurrect a freed blob and the 1→0 transition has exactly one winner |
//! | domain spinlock (`std.atomic.Mutex`) | slot acquire/release (create/destroy), segment growth, statistics | cold path — once per blob LIFETIME, never per retain/release/read; kernel spinlock convention (O(1) critical sections, no libc threading) |
//! | registry spinlock (`std.atomic.Mutex`) | `registryPut` writers | writers serialize (find-or-claim needs a linearization point — the `registry.zig` precedent); `registryGet` takes NO lock |
//! | registry slot fields (`key_and_state`, `handle_bits`) | seqlock-flavored publish/read | lock-free `registryGet` (see below) |
//!
//! **Never atomic:** the payload bytes (immutable after the publishing
//! `.release` store of the slot state), `BlobSlot.header`/`byte_length`
//! (written only while the slot is privately held — before publication
//! or after winning the freeing CAS — with the spinlock's release/acquire
//! edge ordering one slot life against the next; PLUS the one sanctioned
//! sole-owner mutation: `tryAppendInPlace` writes them when the share
//! count is exactly 1 and the caller owns that reference, so no
//! concurrent access can exist, and any LATER cross-thread reader is
//! ordered behind the append by the flight-retain CAS release/acquire
//! edge the share must cross first), every per-process `BlobLedger`
//! (owner-only, like all PCB state), and everything outside this module
//! — ordinary Zap ARC stays non-atomic, which the Constraint 3 audit
//! greps for.
//!
//! ## Why the count lives in the SLOT, not the payload header
//!
//! Handles are `{slot, generation}` pairs into a segmented slot table
//! whose memory is TYPE-STABLE (segments are never freed while the
//! domain lives; slots are reused, never unmapped). Every validate/
//! retain/release touches ONLY that stable slot word, never the payload
//! allocation — so even a stale or forged handle can never fault or
//! corrupt memory: it either fails the generation check (clean panic at
//! the surface) or legally references a still-live blob. The payload
//! header (`BlobHeader`) carries only immutable back-references
//! (handle bits + byte length) so the in-flight message path can resolve
//! a payload pointer back to its slot. This is the pid-table discipline
//! (`pid_table.zig`) applied to the share tier.
//!
//! ## The persistent-term registry
//!
//! `registryPut`/`registryGet` are the BEAM `persistent_term` analogue
//! (research-round-2 "missing capabilities #2" — the pressure-relief
//! valve so read-mostly config/lookup tables are not abused through
//! message passing): a global, runtime-owned atom-key → blob map.
//!
//! * **`registryGet` is a lock-free read + atomic retain**: a
//!   seqlock-consistent slot read followed by `tryRetain` — the
//!   generation-validated count CAS. If a concurrent `registryPut`
//!   replaces the entry between the read and the CAS, the CAS fails
//!   cleanly (the registry's own +1 died with the swap) and the probe
//!   retries, observing the replacement. No lock, no hazard pointers, no
//!   grace period — the type-stable slot table plus the gen-validated
//!   CAS deliver what Erlang needs engine-level thread progress for.
//! * **`registryPut` replaces**: the registry holds its own +1 per
//!   stored value; a replacing put swaps the handle under the write lock
//!   and releases the OLD value's +1 AFTER publication — the old blob
//!   dies when its last outside reader drops, exactly the
//!   "no copy-out-on-update complexity" the plan promises (immutable +
//!   counted makes replacement trivially safe).
//! * **No erase in v1** — config keys are put/replaced, not deleted
//!   (matching `persistent_term`'s read-mostly posture). Erase is an
//!   additive follow-on; the registry releases every held +1 at
//!   `deinit` (runtime shutdown), leak-exactly.
//!
//! ## Ownership bookkeeping — the per-process blob ledger
//!
//! The Zap-surface handle (`lib/blob.zap`'s `Blob`) is a plain one-word
//! value (like a pid), NOT an ARC cell — copying it inside a process is
//! free and count-neutral. What the count tracks is ACQUISITIONS: each
//! `create`/adopted receive/`registryGet` grants the calling process one
//! owned reference, recorded in its `BlobLedger` (a PCB field). The
//! ledger is the research.md §6.5 drop-list discipline applied to the
//! share tier: `Blob.release` drops an entry early; process teardown
//! drains whatever remains (`releaseAllOwned`), so a crashed process
//! leaks nothing and a receiver outlives a dead sender by construction.
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so
//! this file has no special compiler requirement; see `concurrency.zig`
//! for the kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");

/// Backing allocator for segments, payload allocations, registry slots,
/// and ledger storage. The page allocator is deliberate — OS-direct
/// (mmap), no C-runtime init-order dependency, kernel memory kept apart
/// from user-code allocators (the `abi.zig` convention; since 7.1a the
/// kernel object compiles with `link_libc = true`, so this is a design
/// choice, not a libc constraint).
const backing_allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Handle encoding
// ---------------------------------------------------------------------------

/// A blob handle: `{slot, generation}` packed into one `u64` — the value
/// the Zap surface carries in its reserved `zap_blob_handle` field. Slot
/// occupies the LOW 32 bits (extraction on the hot path is a single
/// mask); generation the high 32. Generation 0 is reserved never-issued,
/// so the all-zero word is the canonical INVALID handle (mirroring
/// `Pid.invalid`).
pub const BlobHandle = packed struct(u64) {
    slot: u32,
    generation: u32,

    /// The never-issued invalid handle (all-zero bits).
    pub const invalid = BlobHandle{ .slot = 0, .generation = 0 };

    pub fn toBits(handle: BlobHandle) u64 {
        return @bitCast(handle);
    }

    pub fn fromBits(bits: u64) BlobHandle {
        return @bitCast(bits);
    }
};

/// Reserved generation marking a retired slot (never reissued): a slot
/// whose generation would wrap is retired instead — the pid-table
/// discipline that makes handle-reuse ABA structurally impossible rather
/// than merely improbable.
const retired_generation: u32 = std.math.maxInt(u32);

/// The packed per-slot atomic word: share count + generation, observed
/// and mutated together so every retain/release decision is one atomic
/// operation (module doc, "Why the count lives in the SLOT").
const SlotState = packed struct(u64) {
    share_count: u32,
    generation: u32,
};

// ---------------------------------------------------------------------------
// Payload layout
// ---------------------------------------------------------------------------

/// Header of one blob payload allocation: `[BlobHeader | bytes]` in a
/// single page-allocator allocation. `handle_bits` and
/// `payload_capacity` are IMMUTABLE after creation; `byte_length` is
/// mutable ONLY by the sole-owner in-place append (`tryAppendInPlace` —
/// module doc, "The Blob-backed String tier"). The header exists so the
/// in-flight message path (which carries only the payload pointer
/// through a moved envelope) can resolve back to the owning slot
/// (`handle_bits`) and so the free path knows the allocation length
/// without touching the slot.
pub const BlobHeader = struct {
    /// The owning handle's bits — written once at create, read by
    /// `handleForPayloadPointer` (the moved-envelope reclaim/adopt path).
    handle_bits: u64,
    /// Payload byte length (excluding this header). Grows — never
    /// shrinks — under `tryAppendInPlace`'s sole-owner discipline.
    byte_length: usize,
    /// Payload byte CAPACITY of the allocation (excluding this header):
    /// the page-rounding slack plus any extra the creator requested
    /// (`createFromParts`'s `minimum_capacity`). `byte_length ≤
    /// payload_capacity` always; the free path computes the allocation
    /// length from THIS field, never from `byte_length`.
    payload_capacity: usize,

    /// First payload byte (carved from the same allocation). Pure
    /// pointer arithmetic — never dereferences the header — so it is
    /// also safe on a header pointer read from a slot mid-probe.
    pub fn payloadPointer(header: *const BlobHeader) [*]const u8 {
        const raw: [*]const u8 = @ptrCast(header);
        return raw + header_byte_length;
    }

    /// Recover the header from the payload pointer the envelope carries.
    pub fn fromPayloadPointer(payload: [*]const u8) *const BlobHeader {
        return @ptrCast(@alignCast(payload - header_byte_length));
    }
};

/// Header bytes preceding the payload, rounded so the payload starts at
/// the header's alignment boundary (byte payloads need no more). This is
/// also the payload's fixed PAGE OFFSET (allocations are page-aligned
/// and page-rounded), which `resolveWholePayloadView`'s memory-safe
/// probe rests on; `payloadPageOffset` exports it across the C ABI.
const header_byte_length = std.mem.alignForward(usize, @sizeOf(BlobHeader), @alignOf(BlobHeader));

/// The fixed page offset of every blob payload (see `header_byte_length`)
/// — the runtime side caches it at startup for its inline pre-filter on
/// the string-concat hot path.
pub fn payloadPageOffset() usize {
    return header_byte_length;
}

// ---------------------------------------------------------------------------
// Slot table geometry
// ---------------------------------------------------------------------------

/// Slots per segment. Segments are allocated on demand under the domain
/// lock and never freed until `deinit`, so slot addresses are stable for
/// the domain's lifetime (the type-stability the lock-free retain/release
/// discipline rests on).
const slots_per_segment: u32 = 1024;

/// Maximum number of segments (fixed pointer array in the domain). The
/// ceiling is 1024 × 1024 ≈ 1M simultaneously-live blobs — far beyond
/// any real working set of LARGE shared buffers; exceeding it fails
/// `create` loudly (`error.BlobTableExhausted`), never silently.
const max_segment_count: u32 = 1024;

/// One slot of the blob table. `state` carries the retain/release
/// protocol; `header_address` and `byte_length` are ATOMIC WORDS (loads/
/// stores only, no RMW) because the string-tier probe
/// (`resolveWholePayloadView`) may legally read them for a blob the
/// caller does NOT own — a garbage candidate pointer whose preceding
/// bytes happen to name a live foreign slot — racing that owner's
/// create/append/free. The atomicity keeps that read formally race-free;
/// a stale value is harmless (the probe's validation chain rejects it,
/// and every USE of a resolved handle re-validates through its own
/// generation-checked CAS). They are written only while the slot is
/// privately held (before the publishing state store, or after winning
/// the freeing CAS) or by the sole-owner append (module doc).
const BlobSlot = struct {
    /// Packed `{share_count, generation}` — see `SlotState`.
    state: std.atomic.Value(u64),
    /// Address of the payload allocation's `BlobHeader`, 0 while the
    /// slot is vacant. See `headerPointer`.
    header_address: std.atomic.Value(usize),
    /// Payload byte length mirror (advisory reads — `byteLength` — read
    /// it after a generation validation without touching the header;
    /// grown by the sole-owner append in lockstep with the header's).
    byte_length: std.atomic.Value(usize),
    /// Intrusive free-list link (slot index; guarded by the domain lock).
    next_free: u32,

    /// The payload header this slot currently owns, or null when vacant.
    /// Callers must have validated the slot state first (the publishing
    /// `.release`/`.acquire` pair is what makes the pointee visible).
    fn headerPointer(slot: *const BlobSlot) ?*BlobHeader {
        const address = slot.header_address.load(.monotonic);
        if (address == 0) return null;
        return @ptrFromInt(address);
    }
};

/// Free-list terminator for `BlobSlot.next_free`.
const no_free_slot: u32 = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
// Registry geometry
// ---------------------------------------------------------------------------

/// Registry slots (open addressing, power of two, fixed at init — the
/// `registry.zig` fixed-capacity policy). 4096 distinct persistent keys
/// is generous for read-mostly config tables; exhaustion fails
/// `registryPut` loudly.
const registry_capacity: u32 = 4096;

/// Registry slot states, packed with the key into one atomic word so a
/// lock-free reader observes `{state, key}` consistently in one load.
const RegistrySlotState = enum(u32) {
    /// Never used. Probes stop here.
    empty = 0,
    /// Holds a live `{key → handle}` entry.
    occupied = 1,
};

/// One registry slot. `key_and_state` packs `{key: u32, state: u32}`;
/// `handle_bits` is published with `.release` BEFORE the occupying
/// `key_and_state` store and re-read under a seqlock-flavored double
/// check by lock-free readers (`registryGet`). Replacement rewrites
/// `handle_bits` in place (state stays `.occupied`); the reader's
/// `tryRetain` CAS is what makes a torn read harmless — a handle
/// observed from a superseded entry fails its generation/count CAS and
/// the probe retries.
const RegistrySlot = struct {
    key_and_state: std.atomic.Value(u64),
    handle_bits: std.atomic.Value(u64),

    fn packKeyState(key: u32, state: RegistrySlotState) u64 {
        return (@as(u64, key) << 32) | @intFromEnum(state);
    }
};

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/// Domain statistics snapshot (tests + observability). Taken under the
/// domain lock for a consistent `{live, peak}` pair.
pub const Statistics = struct {
    /// Blobs currently alive (created, not yet fully released).
    live_blob_count: u32,
    /// High-watermark of `live_blob_count`.
    live_blob_peak: u32,
    /// Live registry entries.
    registry_entry_count: u32,
};

// ---------------------------------------------------------------------------
// The domain
// ---------------------------------------------------------------------------

/// The blob allocation domain: the segmented generational slot table,
/// the payload allocations, and the persistent-term registry. One per
/// runtime (owned by `abi.zig`'s `RuntimeState`, torn down leak-exactly
/// at `zap_proc_runtime_deinit`); kernel tests create standalone
/// instances. Must not move once handles are issued (slots are reached
/// through the embedded segment pointer array).
pub const BlobDomain = struct {
    /// Guards slot acquire/release, segment growth, the free list, and
    /// the statistics counters. Cold path only (once per blob lifetime).
    domain_lock: std.atomic.Mutex,
    /// Segment pointer array (segments allocated on demand, stable once
    /// created). Written under `domain_lock`; read lock-free by
    /// `slotPointer`, ordered by the `initialized_slot_count`
    /// release/acquire pair (a slot index is only admitted after the
    /// acquire load observes a count that the segment write preceded).
    segments: [max_segment_count]?[*]BlobSlot,
    /// Number of segments currently allocated.
    segment_count: u32,
    /// Slots ever carved (bump cursor). Atomic because `slotPointer`
    /// reads it WITHOUT the domain lock: the `.release` store (under the
    /// lock, after the slot and its segment are fully initialized) pairs
    /// with the lock-free `.acquire` load so an admitted index always
    /// resolves to initialized memory.
    initialized_slot_count: std.atomic.Value(u32),
    /// Head of the vacant-slot free list (slot index), `no_free_slot`
    /// when empty. Guarded by `domain_lock`.
    free_list_head: u32,
    /// Live blob count. Guarded by `domain_lock`.
    live_blob_count: u32,
    /// High-watermark of `live_blob_count`. Guarded by `domain_lock`.
    live_blob_peak: u32,

    /// Guards registry WRITES (`registryPut` — find-or-claim needs one
    /// linearization point, the `registry.zig` precedent). Reads take no
    /// lock.
    registry_lock: std.atomic.Mutex,
    /// Open-addressed registry slots, allocated at `init`.
    registry_slots: []RegistrySlot,
    /// Live registry entries. Guarded by `registry_lock`.
    registry_entry_count: u32,

    pub const CreateError = error{
        /// The backing allocator could not provide the payload or a
        /// table segment.
        OutOfMemory,
        /// Every table slot is live (the documented fixed ceiling).
        BlobTableExhausted,
    };

    pub const RegistryPutError = error{
        /// Every registry slot holds a distinct live key.
        RegistryFull,
        /// The stored blob handle is stale (caller bug — putting a blob
        /// the caller does not own).
        StaleBlobHandle,
    };

    /// Create an empty domain. Allocates the fixed registry slot array;
    /// the slot table grows on demand.
    pub fn init() error{OutOfMemory}!BlobDomain {
        const registry_slots = try backing_allocator.alloc(RegistrySlot, registry_capacity);
        for (registry_slots) |*slot| {
            slot.key_and_state = .init(RegistrySlot.packKeyState(0, .empty));
            slot.handle_bits = .init(BlobHandle.invalid.toBits());
        }
        return .{
            .domain_lock = .unlocked,
            .segments = @splat(null),
            .segment_count = 0,
            .initialized_slot_count = .init(0),
            .free_list_head = no_free_slot,
            .live_blob_count = 0,
            .live_blob_peak = 0,
            .registry_lock = .unlocked,
            .registry_slots = registry_slots,
            .registry_entry_count = 0,
        };
    }

    /// Tear the domain down: release every registry-held reference, then
    /// assert the leak-exactness gate — no blob may still be alive (all
    /// process ledgers and in-flight envelopes must have drained first),
    /// exactly the envelope pool's "every page accounted" discipline —
    /// and free the segments and registry storage.
    pub fn deinit(domain: *BlobDomain) void {
        // Release the registry's own +1 per stored value. At shutdown no
        // reader races this (the runtime tears down after every process
        // exited), but the release path is the ordinary atomic one, so
        // ordering is safe regardless.
        for (domain.registry_slots) |*slot| {
            const key_state = slot.key_and_state.load(.acquire);
            const state: RegistrySlotState = @enumFromInt(@as(u32, @truncate(key_state)));
            if (state != .occupied) continue;
            _ = domain.release(BlobHandle.fromBits(slot.handle_bits.load(.acquire)));
            slot.key_and_state.store(RegistrySlot.packKeyState(0, .empty), .release);
            slot.handle_bits.store(BlobHandle.invalid.toBits(), .release);
            domain.registry_entry_count -= 1;
        }
        std.debug.assert(domain.registry_entry_count == 0);
        // The leak-exactness gate: every acquisition was balanced by a
        // ledger drain, an explicit release, a flight release, or the
        // registry sweep above.
        std.debug.assert(domain.live_blob_count == 0);
        backing_allocator.free(domain.registry_slots);
        for (domain.segments[0..domain.segment_count]) |segment| {
            backing_allocator.free(@as([]BlobSlot, segment.?[0..slots_per_segment]));
        }
        domain.* = undefined;
    }

    /// Snapshot the domain counters (tests + observability).
    pub fn statistics(domain: *BlobDomain) Statistics {
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        return .{
            .live_blob_count = domain.live_blob_count,
            .live_blob_peak = domain.live_blob_peak,
            .registry_entry_count = domain.registry_entry_count,
        };
    }

    // -- creation / destruction --------------------------------------------

    /// Create a blob by COPYING `bytes` into a fresh payload allocation
    /// owned by this domain (the one copy of a blob's life — zero-copy
    /// forever after). The new blob's share count is 1: the caller owns
    /// that reference (the surface records it in the calling process's
    /// ledger).
    pub fn create(domain: *BlobDomain, bytes: []const u8) CreateError!BlobHandle {
        return domain.createFromParts(bytes, &.{}, 0);
    }

    /// Create a blob whose payload is `first ++ second` (one copy each —
    /// the promoted-concat constructor of the Blob-backed String tier;
    /// `create` is the `second`-empty special case), with a payload
    /// capacity of at least `minimum_capacity` bytes (the geometric-
    /// growth hook for the append path). The allocation is rounded up to
    /// whole pages — free in real memory under the page allocator — and
    /// the whole rounded size is recorded as `payload_capacity`, so
    /// every blob carries its natural append slack.
    pub fn createFromParts(
        domain: *BlobDomain,
        first: []const u8,
        second: []const u8,
        minimum_capacity: usize,
    ) CreateError!BlobHandle {
        const byte_length = std.math.add(usize, first.len, second.len) catch
            return error.OutOfMemory;
        const requested_capacity = @max(byte_length, minimum_capacity);
        const padded_byte_length = std.math.add(usize, header_byte_length, requested_capacity) catch
            return error.OutOfMemory;
        const allocation_byte_length = std.mem.alignForward(
            usize,
            padded_byte_length,
            std.heap.pageSize(),
        );
        const allocation = backing_allocator.alignedAlloc(
            u8,
            .of(BlobHeader),
            allocation_byte_length,
        ) catch return error.OutOfMemory;
        errdefer backing_allocator.free(allocation);
        // The probe precondition (`resolveWholePayloadView`): the page
        // allocator returns page-aligned blocks, so every payload sits at
        // page offset `header_byte_length`.
        std.debug.assert(@intFromPtr(allocation.ptr) % std.heap.pageSize() == 0);
        const header: *BlobHeader = @ptrCast(@alignCast(allocation.ptr));
        header.byte_length = byte_length;
        header.payload_capacity = allocation_byte_length - header_byte_length;
        @memcpy(allocation[header_byte_length..][0..first.len], first);
        @memcpy(allocation[header_byte_length + first.len ..][0..second.len], second);

        const acquired = try domain.acquireSlot();
        header.handle_bits = acquired.handle.toBits();
        acquired.slot.header_address.store(@intFromPtr(header), .monotonic);
        acquired.slot.byte_length.store(byte_length, .monotonic);
        // Publish: count 1, this generation. `.release` orders the
        // header/payload writes above before any acquire-load of the
        // state — a reader that validates the generation is guaranteed
        // to see the payload bytes.
        acquired.slot.state.store(@bitCast(SlotState{
            .share_count = 1,
            .generation = acquired.handle.generation,
        }), .release);
        return acquired.handle;
    }

    /// Atomically add one owned reference to a live blob. Returns false
    /// when the handle is stale (generation mismatch or count already
    /// zero) — the caller surfaces that as the use-after-release panic
    /// or, on the registry get path, as a retry. Never touches payload
    /// memory, so a stale handle can never fault (module doc).
    pub fn tryRetain(domain: *BlobDomain, handle: BlobHandle) bool {
        const slot = domain.slotPointer(handle) orelse return false;
        var observed = slot.state.load(.acquire);
        while (true) {
            const state: SlotState = @bitCast(observed);
            if (state.generation != handle.generation or state.share_count == 0) return false;
            std.debug.assert(state.share_count != std.math.maxInt(u32));
            observed = slot.state.cmpxchgWeak(
                observed,
                @bitCast(SlotState{
                    .share_count = state.share_count + 1,
                    .generation = state.generation,
                }),
                .acq_rel,
                .acquire,
            ) orelse return true;
        }
    }

    /// Whether releasing dropped the last reference (the blob was freed).
    pub const ReleaseOutcome = enum { still_shared, freed };

    /// Atomically drop one owned reference. The 1→0 winner bumps the
    /// slot generation IN THE SAME CAS (no stale retain can resurrect),
    /// frees the payload allocation, and returns the slot to the free
    /// list. Panics on a stale handle — releasing a reference that does
    /// not exist is a bookkeeping bug in every caller (ledger, registry,
    /// flight), never a legal program state.
    pub fn release(domain: *BlobDomain, handle: BlobHandle) ReleaseOutcome {
        const slot = domain.slotPointer(handle) orelse unreachableStaleRelease();
        var observed = slot.state.load(.acquire);
        while (true) {
            const state: SlotState = @bitCast(observed);
            if (state.generation != handle.generation or state.share_count == 0) {
                unreachableStaleRelease();
            }
            const next: SlotState = if (state.share_count == 1) .{
                // The freeing transition: count → 0 AND generation bump,
                // atomically. Retirement of a wrapped generation happens
                // below (the bumped value may equal `retired_generation`,
                // which is never issued — see `acquireSlot`).
                .share_count = 0,
                .generation = state.generation + 1,
            } else .{
                .share_count = state.share_count - 1,
                .generation = state.generation,
            };
            observed = slot.state.cmpxchgWeak(
                observed,
                @bitCast(next),
                .acq_rel,
                .acquire,
            ) orelse {
                if (state.share_count != 1) return .still_shared;
                domain.destroyPayloadAndRecycleSlot(handle.slot, slot);
                return .freed;
            };
        }
    }

    // -- reads (caller must own a reference — module doc) --------------------

    /// Payload byte length, or null when the handle is stale. Reads only
    /// the type-stable slot (never the payload allocation).
    pub fn byteLength(domain: *BlobDomain, handle: BlobHandle) ?usize {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        return slot.byte_length.load(.monotonic);
    }

    /// A BORROWED view of the payload bytes, or null when the handle is
    /// stale. The view is valid for as long as the caller holds an owned
    /// reference (which pins the count above zero — the ownership
    /// discipline every read path rides).
    pub fn bytesView(domain: *BlobDomain, handle: BlobHandle) ?[]const u8 {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        const header = slot.headerPointer().?;
        return header.payloadPointer()[0..header.byte_length];
    }

    /// Current share count (advisory — exact only at quiescence), or
    /// null when stale. Test/observability surface.
    pub fn shareCount(domain: *BlobDomain, handle: BlobHandle) ?u32 {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        return state.share_count;
    }

    /// Payload byte capacity (allocation slack included), or null when
    /// the handle is stale. The append path's growth arithmetic and the
    /// capacity tests read this.
    pub fn payloadCapacity(domain: *BlobDomain, handle: BlobHandle) ?usize {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        return slot.headerPointer().?.payload_capacity;
    }

    // -- the Blob-backed String tier (P6-J3) ----------------------------------

    /// The rc==1 in-place append (module doc, "The Blob-backed String
    /// tier"): when the blob is live, the share count is EXACTLY 1, the
    /// caller's view is the current frontier (`frontier_length ==
    /// byte_length` — appending behind the frontier would clobber bytes
    /// a longer same-process alias may still read), and the capacity has
    /// room, copy `extra` in at the frontier and grow `byte_length`.
    /// Returns false — mutating NOTHING — when any condition fails; the
    /// caller then copies (the shared/full path).
    ///
    /// CALLER CONTRACT: the caller must OWN the single reference (the
    /// ABI layer verifies the handle against the calling process's
    /// ledger first). That ownership is what makes the non-atomic header
    /// mutation sound: with count == 1 and the 1 provably ours, no other
    /// process, envelope, or registry entry holds the blob, and no
    /// concurrent retain can exist (every retain must be rooted in an
    /// existing owned reference). Immutability stays observationally
    /// absolute for any holder that is not the sole owner — a holder
    /// that could observe the mutation cannot exist while it happens,
    /// and any holder that comes into existence LATER (a share) is
    /// ordered behind it by the flight-retain CAS edge.
    pub fn tryAppendInPlace(
        domain: *BlobDomain,
        handle: BlobHandle,
        frontier_length: usize,
        extra: []const u8,
    ) bool {
        const slot = domain.slotPointer(handle) orelse return false;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count != 1) return false;
        const header = slot.headerPointer().?;
        if (header.byte_length != frontier_length) return false;
        if (header.payload_capacity - header.byte_length < extra.len) return false;
        const destination: [*]u8 = @constCast(header.payloadPointer());
        // `extra` may alias a prefix of this very payload (`s <> s.slice`):
        // the destination starts at the frontier and every legal alias
        // ends at or before it, so source and destination are disjoint.
        @memcpy(destination[frontier_length .. frontier_length + extra.len], extra);
        header.byte_length = frontier_length + extra.len;
        slot.byte_length.store(header.byte_length, .monotonic);
        return true;
    }

    /// Recognize a `{pointer, length}` pair as the WHOLE-payload view of
    /// a live blob — the string-tier probe (module doc, "Recognition by
    /// layout"). Returns the owning handle, or null for anything else.
    ///
    /// Memory safety of the probe: bytes are only ever read at
    /// `pointer - header_byte_length` AFTER the page-offset filter
    /// proves that address lies on the SAME page as `pointer` (a mapped
    /// page, since the caller's slice is readable), so a non-blob
    /// candidate can never fault. Correctness: a garbage header can
    /// only be accepted if its handle bits resolve to a live slot WHOSE
    /// OWN header sits exactly `header_byte_length` bytes before
    /// `pointer` — in which case the bytes read ARE that blob's real
    /// header and the recognition is true, not a false positive.
    ///
    /// Only the exact whole view (`length == byte_length`) resolves:
    /// a prefix alias re-copies at every boundary (the copy-out-slices
    /// law — a short view must never pin a long payload in another
    /// process). Racing frees (possible only for a probe on a blob the
    /// caller does NOT own) fail the generation validation or the
    /// address round-trip and return null — and every USE of a resolved
    /// handle (flight retain, append) re-validates through its own
    /// generation-checked CAS anyway.
    pub fn resolveWholePayloadView(
        domain: *BlobDomain,
        pointer: [*]const u8,
        length: usize,
    ) ?BlobHandle {
        // A zero-length slice's pointer may dangle (Zig's `&.{}`), so the
        // "same mapped page" premise below needs length ≥ 1. Zero-length
        // strings are never blob-backed anyway.
        if (length == 0) return null;
        const address = @intFromPtr(pointer);
        if (address % std.heap.pageSize() != header_byte_length) return null;
        const header: *const BlobHeader = @ptrFromInt(address - header_byte_length);
        const handle = BlobHandle.fromBits(header.handle_bits);
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        const slot_header = slot.headerPointer() orelse return null;
        if (@intFromPtr(slot_header) + header_byte_length != address) return null;
        if (slot.byte_length.load(.monotonic) != length) return null;
        return handle;
    }

    // -- the in-flight (moved-envelope) seam ---------------------------------

    /// The payload pointer for a live blob the caller owns, or null when
    /// stale. This is what a blob send carries through the moved-envelope
    /// fragment (the pointer doubles as the pointer-identity witness the
    /// zero-copy tests assert on).
    pub fn payloadPointer(domain: *BlobDomain, handle: BlobHandle) ?[*]const u8 {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.generation != handle.generation or state.share_count == 0) return null;
        return slot.headerPointer().?.payloadPointer();
    }

    /// Recover the handle from a payload pointer (the receive/adopt and
    /// envelope-reclaim path — the header stores its own handle bits).
    pub fn handleForPayloadPointer(payload: [*]const u8) BlobHandle {
        return BlobHandle.fromBits(BlobHeader.fromPayloadPointer(payload).handle_bits);
    }

    // -- persistent-term registry --------------------------------------------

    /// Store `handle` under atom `key`, retaining one reference FOR THE
    /// REGISTRY (the caller keeps its own). A put on an existing key
    /// REPLACES: the new handle is published first, the OLD value's
    /// registry reference is released after — its payload dies when the
    /// last outside holder drops (module doc). The caller must own
    /// `handle` (stale handles panic at the surface via
    /// `StaleBlobHandle`).
    pub fn registryPut(domain: *BlobDomain, key: u32, handle: BlobHandle) RegistryPutError!void {
        // Retain the registry's +1 BEFORE taking the write lock: the
        // caller owns a reference, so the count is pinned above zero and
        // this cannot race a free.
        if (!domain.tryRetain(handle)) return error.StaleBlobHandle;

        domain.lockRegistry();
        const mask = registry_capacity - 1;
        var probe: u32 = hashRegistryKey(key) & mask;
        var probed: u32 = 0;
        while (probed < registry_capacity) : (probed += 1) {
            const slot = &domain.registry_slots[probe];
            const key_state = slot.key_and_state.load(.acquire);
            const state: RegistrySlotState = @enumFromInt(@as(u32, @truncate(key_state)));
            const slot_key: u32 = @truncate(key_state >> 32);
            switch (state) {
                .empty => {
                    // Claim: publish the handle BEFORE the occupying
                    // key/state store so a lock-free reader that observes
                    // `.occupied` is guaranteed a real handle underneath.
                    slot.handle_bits.store(handle.toBits(), .release);
                    slot.key_and_state.store(RegistrySlot.packKeyState(key, .occupied), .release);
                    domain.registry_entry_count += 1;
                    domain.registry_lock.unlock();
                    return;
                },
                .occupied => {
                    if (slot_key == key) {
                        // Replace: swap the handle in place; release the
                        // old registry reference AFTER unlocking (the
                        // release path takes the domain lock on a free —
                        // never nest the two).
                        const old_bits = slot.handle_bits.load(.acquire);
                        slot.handle_bits.store(handle.toBits(), .release);
                        domain.registry_lock.unlock();
                        _ = domain.release(BlobHandle.fromBits(old_bits));
                        return;
                    }
                },
            }
            probe = (probe + 1) & mask;
        }
        domain.registry_lock.unlock();
        // Undo the pre-retained registry reference — nothing stored it.
        _ = domain.release(handle);
        return error.RegistryFull;
    }

    /// Look up atom `key` and, when present, atomically retain one owned
    /// reference for the caller. LOCK-FREE: a seqlock-consistent slot
    /// read plus the generation-validated `tryRetain` CAS; a concurrent
    /// replacing put makes the CAS fail cleanly and the probe retries,
    /// observing the replacement (module doc). Returns null when the key
    /// has never been put.
    pub fn registryGet(domain: *BlobDomain, key: u32) ?BlobHandle {
        const mask = registry_capacity - 1;
        retry: while (true) {
            var probe: u32 = hashRegistryKey(key) & mask;
            var probed: u32 = 0;
            while (probed < registry_capacity) : (probed += 1) {
                const slot = &domain.registry_slots[probe];
                const key_state = slot.key_and_state.load(.acquire);
                const state: RegistrySlotState = @enumFromInt(@as(u32, @truncate(key_state)));
                const slot_key: u32 = @truncate(key_state >> 32);
                switch (state) {
                    // v1 has no erase, so an empty slot ends every probe
                    // chain: the key is absent.
                    .empty => return null,
                    .occupied => {
                        if (slot_key == key) {
                            const handle = BlobHandle.fromBits(slot.handle_bits.load(.acquire));
                            if (domain.tryRetain(handle)) return handle;
                            // A replacing put superseded the observed
                            // handle between the read and the CAS; the
                            // registry's reference to it is gone. Retry —
                            // the re-probe observes the replacement.
                            continue :retry;
                        }
                    },
                }
                probe = (probe + 1) & mask;
            }
            return null;
        }
    }

    // -- internal ------------------------------------------------------------

    const AcquiredSlot = struct {
        handle: BlobHandle,
        slot: *BlobSlot,
    };

    /// Acquire a vacant slot (free list first, then bump-carve, growing
    /// by one segment when exhausted) and mint its next-generation
    /// handle. The returned slot is privately held: its state word still
    /// reads `{0, old generation}` so every concurrent stale probe fails;
    /// the caller publishes the new state after wiring the payload.
    fn acquireSlot(domain: *BlobDomain) CreateError!AcquiredSlot {
        domain.lockDomain();

        while (domain.free_list_head != no_free_slot) {
            const slot_index = domain.free_list_head;
            const slot = domain.slotPointerUnchecked(slot_index);
            domain.free_list_head = slot.next_free;
            slot.next_free = no_free_slot;
            const state: SlotState = @bitCast(slot.state.load(.monotonic));
            std.debug.assert(state.share_count == 0);
            if (state.generation == retired_generation) {
                // A slot whose generation wrapped is retired — never
                // reissued (module doc). Fall through to the next free
                // slot or a fresh carve.
                continue;
            }
            domain.noteBlobCreatedLocked();
            domain.domain_lock.unlock();
            return .{
                .handle = .{ .slot = slot_index, .generation = state.generation },
                .slot = slot,
            };
        }

        // Bump-carve from the last segment; grow when exhausted.
        const segment_capacity = domain.segment_count * slots_per_segment;
        const carved_count = domain.initialized_slot_count.load(.monotonic);
        if (carved_count == segment_capacity) {
            if (domain.segment_count == max_segment_count) {
                domain.domain_lock.unlock();
                return error.BlobTableExhausted;
            }
            const segment = backing_allocator.alloc(BlobSlot, slots_per_segment) catch {
                domain.domain_lock.unlock();
                return error.OutOfMemory;
            };
            domain.segments[domain.segment_count] = segment.ptr;
            domain.segment_count += 1;
        }
        const slot_index = carved_count;
        const slot = domain.slotPointerUnchecked(slot_index);
        slot.* = .{
            // Generation 1 is the first issued generation (0 is the
            // reserved invalid — a zero handle never validates).
            .state = .init(@bitCast(SlotState{ .share_count = 0, .generation = 1 })),
            .header_address = .init(0),
            .byte_length = .init(0),
            .next_free = no_free_slot,
        };
        // Publish the carve AFTER the slot (and its segment pointer) are
        // fully initialized: the lock-free `slotPointer` acquire-load
        // pairing makes an admitted index safe to dereference.
        domain.initialized_slot_count.store(slot_index + 1, .release);
        domain.noteBlobCreatedLocked();
        domain.domain_lock.unlock();
        return .{
            .handle = .{ .slot = slot_index, .generation = 1 },
            .slot = slot,
        };
    }

    /// The 1→0 winner's cleanup: free the payload allocation and return
    /// the slot to the free list. The winning CAS already bumped the
    /// generation, so no retain can validate; the domain lock's
    /// release/acquire edge orders this slot life's plain-field reads
    /// before the next life's writes.
    fn destroyPayloadAndRecycleSlot(domain: *BlobDomain, slot_index: u32, slot: *BlobSlot) void {
        const header = slot.headerPointer().?;
        const allocation_length = header_byte_length + header.payload_capacity;
        const raw: [*]align(@alignOf(BlobHeader)) u8 = @ptrCast(@alignCast(header));
        backing_allocator.free(raw[0..allocation_length]);

        domain.lockDomain();
        slot.header_address.store(0, .monotonic);
        slot.byte_length.store(0, .monotonic);
        slot.next_free = domain.free_list_head;
        domain.free_list_head = slot_index;
        std.debug.assert(domain.live_blob_count > 0);
        domain.live_blob_count -= 1;
        domain.domain_lock.unlock();
    }

    fn noteBlobCreatedLocked(domain: *BlobDomain) void {
        domain.live_blob_count += 1;
        if (domain.live_blob_count > domain.live_blob_peak) {
            domain.live_blob_peak = domain.live_blob_count;
        }
    }

    /// Resolve a handle's slot pointer, or null when the slot index was
    /// never carved (a forged/garbage handle — reads only domain-stable
    /// state, so it never faults). `initialized_slot_count` is read
    /// without the lock: it only grows, a handle for a slot can only
    /// exist AFTER that slot was carved (the count already included it),
    /// and the release/acquire pairing guarantees an admitted index
    /// resolves to fully initialized slot and segment memory.
    fn slotPointer(domain: *BlobDomain, handle: BlobHandle) ?*BlobSlot {
        if (handle.slot >= domain.initialized_slot_count.load(.acquire)) return null;
        return domain.slotPointerUnchecked(handle.slot);
    }

    fn slotPointerUnchecked(domain: *BlobDomain, slot_index: u32) *BlobSlot {
        const segment = domain.segments[slot_index / slots_per_segment].?;
        return &segment[slot_index % slots_per_segment];
    }

    fn lockDomain(domain: *BlobDomain) void {
        while (!domain.domain_lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn lockRegistry(domain: *BlobDomain) void {
        while (!domain.registry_lock.tryLock()) std.atomic.spinLoopHint();
    }
};

/// Registry key hash (atom ids are small dense integers; spread them so
/// linear probing stays short). Fibonacci hashing on the 32-bit key.
fn hashRegistryKey(key: u32) u32 {
    return @truncate((@as(u64, key) *% 0x9E3779B97F4A7C15) >> 32);
}

/// Releasing a reference that does not exist (stale generation or zero
/// count) is a bookkeeping bug in the kernel's own callers — the ledger,
/// the registry, and the flight path all release exactly what they
/// retained — or a Zap-surface use-after-release, which the surface
/// panics on with its own message before reaching here.
fn unreachableStaleRelease() noreturn {
    @branchHint(.cold);
    @panic("BlobDomain.release: stale blob handle (release without a matching owned reference) — bookkeeping bug");
}

// ---------------------------------------------------------------------------
// Per-process ownership ledger
// ---------------------------------------------------------------------------

/// The per-process record of owned blob references (a PCB field —
/// `process.zig`). Owner-only, like every PCB field: only the process's
/// own quantum appends/removes, and teardown (the owning scheduler)
/// drains it. Each entry is one acquisition (`create`, adopted receive,
/// `registryGet`) = one owned reference; `releaseAllOwned` at teardown is
/// what makes "a process dying with blob handles releases them" hold —
/// the drop-list discipline (research.md §6.5) for the share tier.
///
/// Storage grows by doubling from the domain's backing allocator and is
/// freed at teardown. Explicit release scans from the TAIL (LIFO —
/// recently acquired blobs release first in the common case, making the
/// scan O(1) amortized for release-promptly workloads).
pub const BlobLedger = struct {
    entries: ?[*]u64,
    entry_count: u32,
    capacity: u32,

    pub const empty = BlobLedger{ .entries = null, .entry_count = 0, .capacity = 0 };

    const initial_capacity: u32 = 16;

    /// Record one owned reference.
    pub fn append(ledger: *BlobLedger, handle_bits: u64) error{OutOfMemory}!void {
        if (ledger.entry_count == ledger.capacity) {
            const new_capacity = if (ledger.capacity == 0) initial_capacity else ledger.capacity * 2;
            const new_storage = backing_allocator.alloc(u64, new_capacity) catch
                return error.OutOfMemory;
            if (ledger.entries) |old_storage| {
                @memcpy(new_storage[0..ledger.entry_count], old_storage[0..ledger.entry_count]);
                backing_allocator.free(old_storage[0..ledger.capacity]);
            }
            ledger.entries = new_storage.ptr;
            ledger.capacity = new_capacity;
        }
        ledger.entries.?[ledger.entry_count] = handle_bits;
        ledger.entry_count += 1;
    }

    /// Remove ONE entry matching `handle_bits`, scanning from the tail.
    /// Returns false when this process owns no such reference (the
    /// surface panics — releasing what you do not own is a program bug).
    pub fn removeOne(ledger: *BlobLedger, handle_bits: u64) bool {
        const entries = ledger.entries orelse return false;
        var index = ledger.entry_count;
        while (index > 0) {
            index -= 1;
            if (entries[index] == handle_bits) {
                entries[index] = entries[ledger.entry_count - 1];
                ledger.entry_count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Whether this process owns at least one reference to `handle_bits`
    /// (tail-first scan, mirroring `removeOne`). The ownership gate every
    /// payload-touching blob intrinsic checks: an operation on a blob the
    /// process does not own is a program bug surfaced as a loud panic,
    /// never a racy read of memory another owner may free.
    pub fn contains(ledger: *const BlobLedger, handle_bits: u64) bool {
        const entries = ledger.entries orelse return false;
        var index = ledger.entry_count;
        while (index > 0) {
            index -= 1;
            if (entries[index] == handle_bits) return true;
        }
        return false;
    }

    /// Number of owned references recorded (test/observability surface).
    pub fn ownedCount(ledger: *const BlobLedger) u32 {
        return ledger.entry_count;
    }

    /// Teardown drain: release every recorded reference into `domain`
    /// and free the storage. With a null domain the ledger must be empty
    /// (a process can only acquire blobs through the domain-backed
    /// intrinsics), asserted. Idempotent-by-reset: the ledger is `empty`
    /// afterwards.
    pub fn releaseAllOwned(ledger: *BlobLedger, domain: ?*BlobDomain) void {
        if (ledger.entries) |entries| {
            if (domain) |live_domain| {
                for (entries[0..ledger.entry_count]) |handle_bits| {
                    _ = live_domain.release(BlobHandle.fromBits(handle_bits));
                }
            } else {
                std.debug.assert(ledger.entry_count == 0);
            }
            backing_allocator.free(entries[0..ledger.capacity]);
        } else {
            std.debug.assert(ledger.entry_count == 0);
        }
        ledger.* = .empty;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "BlobDomain: create copies bytes in; reads see them; the creator's release frees leak-exactly" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    var source = [_]u8{ 'z', 'a', 'p', '!', 0x00, 0xFF };
    const handle = try domain.create(&source);
    // Creation COPIED the bytes: mutating the source afterwards must not
    // be observable through the blob (deep immutability at the domain
    // boundary).
    source[0] = 'X';

    try testing.expectEqual(@as(?usize, 6), domain.byteLength(handle));
    const view = domain.bytesView(handle).?;
    try testing.expectEqualSlices(u8, &.{ 'z', 'a', 'p', '!', 0x00, 0xFF }, view);
    try testing.expectEqual(@as(?u32, 1), domain.shareCount(handle));
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_blob_count);

    try testing.expectEqual(BlobDomain.ReleaseOutcome.freed, domain.release(handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);

    // The freed handle is stale everywhere: generation bumped in the
    // freeing CAS, so no read or retain validates.
    try testing.expectEqual(@as(?usize, null), domain.byteLength(handle));
    try testing.expect(!domain.tryRetain(handle));
}

test "BlobDomain: retain/release count discipline — the last of N holders frees" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("shared payload");
    try testing.expect(domain.tryRetain(handle));
    try testing.expect(domain.tryRetain(handle));
    try testing.expectEqual(@as(?u32, 3), domain.shareCount(handle));

    try testing.expectEqual(BlobDomain.ReleaseOutcome.still_shared, domain.release(handle));
    try testing.expectEqual(BlobDomain.ReleaseOutcome.still_shared, domain.release(handle));
    try testing.expectEqual(@as(?u32, 1), domain.shareCount(handle));
    try testing.expectEqual(BlobDomain.ReleaseOutcome.freed, domain.release(handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);
}

test "BlobDomain: slot reuse bumps the generation — a stale handle never aliases a successor" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const first = try domain.create("first life");
    _ = domain.release(first);

    // The successor reuses the same slot (LIFO free list) with a bumped
    // generation.
    const second = try domain.create("second life");
    try testing.expectEqual(first.slot, second.slot);
    try testing.expect(first.generation != second.generation);

    // The stale first-life handle fails every operation; the live one
    // works.
    try testing.expect(!domain.tryRetain(first));
    try testing.expect(domain.bytesView(first) == null);
    try testing.expectEqualSlices(u8, "second life", domain.bytesView(second).?);
    _ = domain.release(second);
}

test "BlobDomain: payload pointer identity round-trips through the header (the moved-envelope seam)" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("route me by pointer");
    const payload = domain.payloadPointer(handle).?;
    // The header behind the payload resolves back to the exact handle —
    // the receive/adopt and envelope-reclaim path.
    try testing.expectEqual(handle.toBits(), BlobDomain.handleForPayloadPointer(payload).toBits());
    // And the pointer IS the bytes (zero-copy identity witness).
    try testing.expectEqualSlices(u8, "route me by pointer", payload[0..domain.byteLength(handle).?]);
    _ = domain.release(handle);
}

test "BlobDomain: registry put/get/replace — get retains for the caller; replace releases the old value" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const key: u32 = 7741;
    try testing.expectEqual(@as(?BlobHandle, null), domain.registryGet(key));

    const first = try domain.create("config v1");
    try domain.registryPut(key, first);
    try testing.expectEqual(@as(?u32, 2), domain.shareCount(first)); // creator + registry
    try testing.expectEqual(@as(u32, 1), domain.statistics().registry_entry_count);

    // get retains for the caller: count 3 (creator + registry + getter).
    const got = domain.registryGet(key).?;
    try testing.expectEqual(first.toBits(), got.toBits());
    try testing.expectEqual(@as(?u32, 3), domain.shareCount(first));
    _ = domain.release(got); // the getter drops its grant

    // Replace: the registry's reference to v1 is released; v1 survives
    // only through its creator, and v2 is what get now observes.
    const second = try domain.create("config v2");
    try domain.registryPut(key, second);
    try testing.expectEqual(@as(u32, 1), domain.statistics().registry_entry_count);
    try testing.expectEqual(@as(?u32, 1), domain.shareCount(first)); // creator only
    const got_second = domain.registryGet(key).?;
    try testing.expectEqual(second.toBits(), got_second.toBits());
    try testing.expectEqualSlices(u8, "config v2", domain.bytesView(got_second).?);
    _ = domain.release(got_second);

    // Creator drops v1: fully freed even while v2 sits in the registry.
    try testing.expectEqual(BlobDomain.ReleaseOutcome.freed, domain.release(first));
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_blob_count);

    // v2's creator drops; the registry still holds it (persistent-term
    // survives process churn) — deinit's registry sweep frees it, which
    // the deferred `domain.deinit` asserts leak-exactly.
    _ = domain.release(second);
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_blob_count);
}

test "BlobLedger: append/removeOne/releaseAllOwned — teardown drains every owned reference" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    var ledger = BlobLedger.empty;
    const first = try domain.create("one");
    const second = try domain.create("two");
    try ledger.append(first.toBits());
    try ledger.append(second.toBits());
    try testing.expectEqual(@as(u32, 2), ledger.ownedCount());

    // Explicit early release of one entry (tail-first scan).
    try testing.expect(ledger.removeOne(second.toBits()));
    _ = domain.release(second);
    try testing.expect(!ledger.removeOne(second.toBits())); // no double-own

    // Teardown drains the rest.
    ledger.releaseAllOwned(&domain);
    try testing.expectEqual(@as(u32, 0), ledger.ownedCount());
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);
}

test "BlobLedger: growth beyond the initial capacity keeps every entry" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    var ledger = BlobLedger.empty;
    var handles: [40]BlobHandle = undefined;
    for (&handles, 0..) |*slot, index| {
        var payload: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&payload, "b{d}", .{index}) catch unreachable;
        slot.* = try domain.create(text);
        try ledger.append(slot.toBits());
    }
    try testing.expectEqual(@as(u32, 40), ledger.ownedCount());
    try testing.expectEqual(@as(u32, 40), domain.statistics().live_blob_count);
    ledger.releaseAllOwned(&domain);
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);
}

// -- the Blob-backed String tier (P6-J3) --------------------------------------

test "BlobDomain: every payload sits at the fixed page offset with page-rounded capacity — the probe precondition" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const page_size = std.heap.pageSize();
    const handle = try domain.create("probe precondition payload");
    const payload = domain.payloadPointer(handle).?;
    // The layout invariant `resolveWholePayloadView` rests on: payload at
    // exactly `header_byte_length` past a page boundary.
    try testing.expectEqual(header_byte_length, @intFromPtr(payload) % page_size);
    try testing.expectEqual(header_byte_length, payloadPageOffset());
    // Page-rounded capacity: the whole rounded allocation minus the header,
    // never less than the payload itself.
    const capacity = domain.payloadCapacity(handle).?;
    try testing.expectEqual(page_size - header_byte_length, capacity);
    try testing.expect(capacity >= domain.byteLength(handle).?);
    _ = domain.release(handle);
}

test "BlobDomain: createFromParts concatenates both parts and honors the minimum capacity" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const page_size = std.heap.pageSize();
    const handle = try domain.createFromParts("hello ", "world", 3 * page_size);
    try testing.expectEqualSlices(u8, "hello world", domain.bytesView(handle).?);
    try testing.expectEqual(@as(usize, 11), domain.byteLength(handle).?);
    // minimum_capacity 3 pages → allocation rounds to 4 pages (header + 3
    // pages of requested capacity spill into a fourth page).
    try testing.expect(domain.payloadCapacity(handle).? >= 3 * page_size);
    _ = domain.release(handle);
}

test "BlobDomain: tryAppendInPlace appends at the frontier when sole-owned; the pointer never moves" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("frontier");
    const payload_before = domain.payloadPointer(handle).?;
    try testing.expect(domain.tryAppendInPlace(handle, 8, " grows"));
    // Same buffer (no realloc), grown length, correct bytes.
    try testing.expectEqual(payload_before, domain.payloadPointer(handle).?);
    try testing.expectEqual(@as(usize, 14), domain.byteLength(handle).?);
    try testing.expectEqualSlices(u8, "frontier grows", domain.bytesView(handle).?);

    // A second append continues from the NEW frontier; the stale frontier
    // is rejected (a shorter alias must never clobber a longer one).
    try testing.expect(!domain.tryAppendInPlace(handle, 8, "clobber"));
    try testing.expect(domain.tryAppendInPlace(handle, 14, "!"));
    try testing.expectEqualSlices(u8, "frontier grows!", domain.bytesView(handle).?);
    _ = domain.release(handle);
}

test "BlobDomain: tryAppendInPlace refuses a shared blob and never mutates it — observational immutability" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("shared payload");
    try testing.expect(domain.tryRetain(handle)); // a second holder exists
    try testing.expect(!domain.tryAppendInPlace(handle, 14, " mutation"));
    // Frozen: length and bytes unchanged for the other holder.
    try testing.expectEqual(@as(usize, 14), domain.byteLength(handle).?);
    try testing.expectEqualSlices(u8, "shared payload", domain.bytesView(handle).?);

    // Back to sole ownership (the other holder released): appendable again
    // — rc==1 is the whole test, not "never shared in the past".
    _ = domain.release(handle);
    try testing.expect(domain.tryAppendInPlace(handle, 14, " again"));
    try testing.expectEqualSlices(u8, "shared payload again", domain.bytesView(handle).?);
    _ = domain.release(handle);
}

test "BlobDomain: tryAppendInPlace refuses an append beyond the capacity" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("x");
    const capacity = domain.payloadCapacity(handle).?;
    const oversized = try backing_allocator.alloc(u8, capacity);
    defer backing_allocator.free(oversized);
    @memset(oversized, 'y');
    // 1 (frontier) + capacity > capacity → refuse, mutate nothing.
    try testing.expect(!domain.tryAppendInPlace(handle, 1, oversized));
    try testing.expectEqual(@as(usize, 1), domain.byteLength(handle).?);
    // Exactly filling the capacity is legal.
    try testing.expect(domain.tryAppendInPlace(handle, 1, oversized[0 .. capacity - 1]));
    try testing.expectEqual(capacity, domain.byteLength(handle).?);
    _ = domain.release(handle);
}

test "BlobDomain: resolveWholePayloadView accepts exactly the whole live view and nothing else" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("resolve me by layout");
    const payload = domain.payloadPointer(handle).?;
    const byte_length = domain.byteLength(handle).?;

    // The whole view resolves to the owning handle.
    const resolved = domain.resolveWholePayloadView(payload, byte_length).?;
    try testing.expectEqual(handle.toBits(), resolved.toBits());

    // A prefix view does NOT resolve (the copy-out-slices law: a short
    // view never rides the share tier).
    try testing.expect(domain.resolveWholePayloadView(payload, byte_length - 1) == null);
    // An interior pointer fails the page-offset filter without any read.
    try testing.expect(domain.resolveWholePayloadView(payload + 1, byte_length - 1) == null);
    // An ordinary heap slice is rejected.
    const foreign = try backing_allocator.alloc(u8, 64);
    defer backing_allocator.free(foreign);
    try testing.expect(domain.resolveWholePayloadView(foreign.ptr, 64) == null);
    // A zero-length view never resolves (and must not read behind a
    // possibly-dangling pointer).
    try testing.expect(domain.resolveWholePayloadView(payload, 0) == null);

    // A STALE header — the exact bytes of a real header, still mapped
    // after its blob was freed (a probe input can never be unmapped
    // memory: every Zap string is readable, and a blob-backed string's
    // blob is ledger-pinned for the string's whole life; this fake page
    // models leftover header bytes in recycled memory). The generation
    // bumped in the freeing CAS, so the probe rejects it.
    const stale_page = try backing_allocator.alignedAlloc(u8, .of(BlobHeader), std.heap.pageSize());
    defer backing_allocator.free(stale_page);
    const live_header: [*]const u8 = @ptrCast(BlobHeader.fromPayloadPointer(payload));
    @memcpy(stale_page[0..header_byte_length], live_header[0..header_byte_length]);
    // While the blob lives, the copied header still fails (address
    // round-trip: the slot's header is not on this page)...
    try testing.expect(domain.resolveWholePayloadView(
        stale_page.ptr + header_byte_length,
        byte_length,
    ) == null);
    // ...and after the free it fails one gate earlier (stale generation).
    _ = domain.release(handle);
    try testing.expect(domain.resolveWholePayloadView(
        stale_page.ptr + header_byte_length,
        byte_length,
    ) == null);
}

test "BlobDomain: resolveWholePayloadView tracks the frontier across in-place appends" {
    var domain = try BlobDomain.init();
    defer domain.deinit();

    const handle = try domain.create("frontier view");
    const payload = domain.payloadPointer(handle).?;
    try testing.expect(domain.tryAppendInPlace(handle, 13, " grew"));
    // The OLD whole view is now a prefix — it must no longer resolve —
    // and the new frontier view resolves.
    try testing.expect(domain.resolveWholePayloadView(payload, 13) == null);
    try testing.expectEqual(
        handle.toBits(),
        domain.resolveWholePayloadView(payload, 18).?.toBits(),
    );
    _ = domain.release(handle);
}

// -- multi-threaded atomic-tier stress (the TSan proof surface) --------------

/// One worker of the atomic-tier stress: hammers retain/release on the
/// shared blobs and exercises the lock-free registry get against
/// replacing puts, from its own OS thread.
const AtomicTierWorker = struct {
    domain: *BlobDomain,
    shared_handles: []const BlobHandle,
    registry_key: u32,
    rounds: usize,
    /// Seed for the per-worker PRNG (decorrelates the interleavings).
    seed: u64,
    failed: bool = false,

    fn run(worker: *AtomicTierWorker) void {
        var prng = std.Random.DefaultPrng.init(worker.seed);
        const random = prng.random();
        var round: usize = 0;
        while (round < worker.rounds) : (round += 1) {
            // Retain → read → release on a randomly chosen shared blob.
            // The worker's retain is rooted in the test body's owned
            // reference (alive for the whole stress), modeling the send
            // path's retain-from-owned discipline.
            const handle = worker.shared_handles[random.uintLessThan(usize, worker.shared_handles.len)];
            if (!worker.domain.tryRetain(handle)) {
                worker.failed = true;
                return;
            }
            const view = worker.domain.bytesView(handle) orelse {
                worker.failed = true;
                return;
            };
            if (view.len == 0 or view[0] != 's') {
                worker.failed = true;
                return;
            }
            if (worker.domain.release(handle) == .freed) {
                // The test body holds the creator reference throughout,
                // so a worker can never be the last holder.
                worker.failed = true;
                return;
            }

            // Lock-free registry get racing replacing puts (below): every
            // observed value must be a live, readable blob whose payload
            // starts with the registry marker.
            if (worker.domain.registryGet(worker.registry_key)) |got| {
                const got_view = worker.domain.bytesView(got) orelse {
                    worker.failed = true;
                    return;
                };
                if (got_view.len == 0 or got_view[0] != 'r') {
                    worker.failed = true;
                    return;
                }
                _ = worker.domain.release(got);
            }
        }
    }
};

test "BlobDomain: cross-thread retain/release/read + lock-free registry get under replacing puts — exact counts at quiescence" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var domain = try BlobDomain.init();
    defer domain.deinit();

    // Shared blobs the workers hammer (the test body owns the creator
    // reference of each for the duration).
    var shared: [4]BlobHandle = undefined;
    for (&shared, 0..) |*slot, index| {
        var payload: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&payload, "shared-{d}", .{index}) catch unreachable;
        slot.* = try domain.create(text);
    }

    const registry_key: u32 = 42;
    const initial = try domain.create("registry-0");
    try domain.registryPut(registry_key, initial);
    _ = domain.release(initial); // registry now sole owner of v0

    const worker_count = 6;
    const rounds_per_worker = 20_000;
    var workers: [worker_count]AtomicTierWorker = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{
            .domain = &domain,
            .shared_handles = &shared,
            .registry_key = registry_key,
            .rounds = rounds_per_worker,
            .seed = 0x9E3779B97F4A7C15 +% index,
        };
    }
    var threads: [worker_count]std.Thread = undefined;
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, AtomicTierWorker.run, .{worker});
    }

    // This thread: replacing puts against the workers' lock-free gets.
    var replacement_round: usize = 0;
    while (replacement_round < 500) : (replacement_round += 1) {
        var payload: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&payload, "registry-{d}", .{replacement_round + 1}) catch unreachable;
        const replacement = try domain.create(text);
        try domain.registryPut(registry_key, replacement);
        _ = domain.release(replacement); // registry sole owner
    }

    for (&threads) |*thread| thread.join();
    for (&workers) |*worker| try testing.expect(!worker.failed);

    // Quiescence: every worker retain was released, every superseded
    // registry value died with its last reader — live blobs are exactly
    // the 4 shared ones + the final registry value.
    try testing.expectEqual(@as(u32, 5), domain.statistics().live_blob_count);
    for (shared) |handle| {
        try testing.expectEqual(@as(?u32, 1), domain.shareCount(handle));
        try testing.expectEqual(BlobDomain.ReleaseOutcome.freed, domain.release(handle));
    }
    // The final registry value survives until deinit's sweep (asserted
    // leak-exact by the deferred deinit).
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_blob_count);
}

/// One worker of the string-tier stress: runs a PRIVATE append chain
/// (create → in-place appends → geometric re-promotion, the exact
/// mechanism sequence `String.concat` drives) while probing the SHARED
/// frozen blobs and adversarial fake-header candidates from its own OS
/// thread. Private chains never race (sole-owner discipline); the probes
/// are the cross-thread surface under test.
const StringTierWorker = struct {
    domain: *BlobDomain,
    shared_handle: BlobHandle,
    shared_payload: [*]const u8,
    shared_byte_length: usize,
    /// A page-aligned NON-blob buffer primed with a byte-copy of the
    /// shared blob's header — the adversarial false-positive candidate:
    /// its handle bits name a LIVE blob, so only the address round-trip
    /// can reject it.
    fake_header_page: [*]const u8,
    rounds: usize,
    failed: bool = false,

    fn run(worker: *StringTierWorker) void {
        var round: usize = 0;
        while (round < worker.rounds) : (round += 1) {
            // Private append chain: create, fill the slack, re-promote once.
            const first = worker.domain.create("chain-seed") catch {
                worker.failed = true;
                return;
            };
            var frontier: usize = "chain-seed".len;
            const capacity = worker.domain.payloadCapacity(first).?;
            while (worker.domain.tryAppendInPlace(first, frontier, "-append")) {
                frontier += "-append".len;
            }
            if (capacity - frontier >= "-append".len) {
                worker.failed = true; // the loop must stop only at capacity
                return;
            }
            const view = worker.domain.bytesView(first).?;
            const grown = worker.domain.createFromParts(view, "-grown", capacity * 2) catch {
                worker.failed = true;
                return;
            };
            if (worker.domain.payloadCapacity(grown).? < capacity * 2) worker.failed = true;
            const grown_view = worker.domain.bytesView(grown).?;
            if (!std.mem.eql(u8, grown_view[0..10], "chain-seed")) worker.failed = true;
            if (!std.mem.eql(u8, grown_view[grown_view.len - 6 ..], "-grown")) worker.failed = true;
            // The grown blob's whole view resolves; the superseded one too
            // (both are live and this worker owns them).
            if (worker.domain.resolveWholePayloadView(grown_view.ptr, grown_view.len) == null) {
                worker.failed = true;
            }
            _ = worker.domain.release(first);
            _ = worker.domain.release(grown);

            // Cross-thread probes of the SHARED frozen blob: the whole view
            // resolves, a prefix and an interior pointer never do.
            const resolved = worker.domain.resolveWholePayloadView(
                worker.shared_payload,
                worker.shared_byte_length,
            ) orelse {
                worker.failed = true;
                return;
            };
            if (resolved.toBits() != worker.shared_handle.toBits()) worker.failed = true;
            if (worker.domain.resolveWholePayloadView(
                worker.shared_payload,
                worker.shared_byte_length - 1,
            ) != null) worker.failed = true;
            if (worker.domain.resolveWholePayloadView(
                worker.shared_payload + 1,
                worker.shared_byte_length - 1,
            ) != null) worker.failed = true;

            // Adversarial fake-header candidate racing the other workers'
            // create/free churn: handle bits name a live blob, address
            // round-trip must reject it — every time.
            if (worker.domain.resolveWholePayloadView(
                worker.fake_header_page + header_byte_length,
                worker.shared_byte_length,
            ) != null) worker.failed = true;
        }
    }
};

test "BlobDomain: string-tier append chains + probes race across threads — no false positive, exact counts" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var domain = try BlobDomain.init();
    defer domain.deinit();

    const shared = try domain.create("shared frozen string payload");
    const shared_payload = domain.payloadPointer(shared).?;
    const shared_byte_length = domain.byteLength(shared).?;

    // Prime the adversarial candidate: a page-aligned non-blob buffer whose
    // first bytes are a byte-copy of the shared blob's REAL header.
    const fake_page = try backing_allocator.alignedAlloc(u8, .of(BlobHeader), std.heap.pageSize());
    defer backing_allocator.free(fake_page);
    const real_header: [*]const u8 = @ptrCast(BlobHeader.fromPayloadPointer(shared_payload));
    @memcpy(fake_page[0..header_byte_length], real_header[0..header_byte_length]);

    const worker_count = 6;
    var workers: [worker_count]StringTierWorker = undefined;
    for (&workers) |*worker| {
        worker.* = .{
            .domain = &domain,
            .shared_handle = shared,
            .shared_payload = shared_payload,
            .shared_byte_length = shared_byte_length,
            .fake_header_page = fake_page.ptr,
            .rounds = 2_000,
        };
    }
    var threads: [worker_count]std.Thread = undefined;
    for (&threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, StringTierWorker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();
    for (&workers) |*worker| try testing.expect(!worker.failed);

    // Quiescence: every chain blob was released; only the shared one lives.
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_blob_count);
    try testing.expectEqual(BlobDomain.ReleaseOutcome.freed, domain.release(shared));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);
}

test "BlobDomain: concurrent create/release churn across threads — slot recycling stays exact" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var domain = try BlobDomain.init();
    defer domain.deinit();

    const Churner = struct {
        domain: *BlobDomain,
        rounds: usize,
        failed: bool = false,

        fn run(churner: *@This()) void {
            var round: usize = 0;
            while (round < churner.rounds) : (round += 1) {
                const handle = churner.domain.create("churn payload") catch {
                    churner.failed = true;
                    return;
                };
                const view = churner.domain.bytesView(handle) orelse {
                    churner.failed = true;
                    return;
                };
                if (view.len != "churn payload".len) {
                    churner.failed = true;
                    return;
                }
                if (churner.domain.release(handle) != .freed) {
                    churner.failed = true;
                    return;
                }
            }
        }
    };

    const churner_count = 6;
    var churners: [churner_count]Churner = undefined;
    for (&churners) |*churner| churner.* = .{ .domain = &domain, .rounds = 5_000 };
    var threads: [churner_count]std.Thread = undefined;
    for (&threads, &churners) |*thread, *churner| {
        thread.* = try std.Thread.spawn(.{}, Churner.run, .{churner});
    }
    for (&threads) |*thread| thread.join();
    for (&churners) |*churner| try testing.expect(!churner.failed);

    try testing.expectEqual(@as(u32, 0), domain.statistics().live_blob_count);
}
