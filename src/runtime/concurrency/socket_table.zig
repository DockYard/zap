//! `SocketDomain` — the FOURTH kernel-owned allocation domain of the Zap
//! isolation model (Phase S0 of `docs/socket-implementation-plan.md`,
//! Decision B): a generational, single-owner, MOVE-ONLY table mapping a
//! one-word handle `{generation, slot}` to the kernel-owned state of an
//! open socket `{fd, owner, generation, kind, occupancy}`.
//!
//! It is the socket analogue of the envelope pool (`envelope_pool.zig`)
//! and the Blob domain (`blob.zig`): socket state lives OFF every
//! per-process manager heap, in this domain's own page-allocator-backed
//! slot table. A process's per-spawn manager never sees a socket byte, so
//! teardown, the copy walker, and per-spawn managers are all untouched by
//! sockets — the third-allocation-domain discipline, applied a fourth
//! time.
//!
//! ## Why single-owner and move-only (UNLIKE Blob)
//!
//! A `Blob` is deeply immutable and atomic-refcount *shareable* — two
//! processes reading the same immutable bytes is safe. A socket is
//! neither: an fd is mutable shared OS state, and two processes reading
//! one fd is a data race the type system must forbid. So a socket handle
//! is **single-owner and move-only**: exactly one process owns it at a
//! time; it travels between processes solely via `Process.send_move`
//! (built in a later phase — S3). There is therefore NO share count here
//! — a slot is simply `free`, `occupied`, or `retired`. Ownership is
//! recorded per-process in a `SocketLedger` (the PCB field), the drop-list
//! discipline (research.md §6.5) applied to the socket tier.
//!
//! ## Memory safety: stale/foreign handles PANIC, never corrupt
//!
//! Handles are `{slot, generation}` pairs into a segmented, TYPE-STABLE
//! slot table (segments are never freed while the domain lives; slots are
//! reused, never unmapped — the `blob.zig`/`pid_table.zig` discipline).
//! Every validate/close touches ONLY the stable slot word, never the fd's
//! OS resource through a stale reference, so a stale or forged handle can
//! never fault or corrupt memory: it either fails the generation check
//! (clean panic at the surface) or legally references a still-live socket.
//! A slot whose generation would wrap is RETIRED (never reissued), so a
//! `{slot, generation}` pair is never reused — reuse ABA is structurally
//! impossible, exactly as for pids and blobs.
//!
//! ## Purity — no I/O in this module
//!
//! This module is PURE data-structure code (std only, no `std.Io.net`):
//! it stores the fd as an opaque `Fd` integer and never performs a
//! syscall. The actual connect/close/shutdown syscalls live in the bridge
//! (`runtime.zig`'s `Socket` namespace gate-OFF; `abi.zig`'s `zap_socket_*`
//! gate-ON), which read the fd out of a slot and act on it through the
//! portable `std.Io.net` API. That purity is what lets this one type be
//! `@import`ed by BOTH the always-linked runtime (the gate-OFF singleton,
//! Decision D) and the concurrency kernel (the gate-ON singleton in
//! `abi.zig`'s `RuntimeState`) without dragging the kernel into gate-OFF
//! binaries.
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so this
//! file has no special compiler requirement; see `concurrency.zig` for the
//! kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");

/// Backing allocator for slot-table segments and ledger storage. The page
/// allocator is deliberate — OS-direct (mmap), no C-runtime init-order
/// dependency, kernel memory kept apart from user-code allocators (the
/// `blob.zig`/`abi.zig` convention).
const backing_allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Handle encoding
// ---------------------------------------------------------------------------

/// A socket handle: `{slot, generation}` packed into one `u64` — the value
/// the Zap surface carries in its reserved `zap_socket_handle` field. Slot
/// occupies the LOW 32 bits (extraction is a single mask); generation the
/// high 32. Generation 0 is reserved never-issued, so the all-zero word is
/// the canonical INVALID handle (mirroring `Pid.invalid` / `BlobHandle`).
pub const SocketHandle = packed struct(u64) {
    slot: u32,
    generation: u32,

    /// The never-issued invalid handle (all-zero bits).
    pub const invalid = SocketHandle{ .slot = 0, .generation = 0 };

    pub fn toBits(handle: SocketHandle) u64 {
        return @bitCast(handle);
    }

    pub fn fromBits(bits: u64) SocketHandle {
        return @bitCast(bits);
    }
};

/// Opaque storage for a platform socket handle. The bridge casts this
/// to/from `std.Io.net.Socket.Handle` (posix `fd_t`, i.e. a small `c_int`;
/// Windows `SOCKET`, a pointer-sized value that fits `i64` on 64-bit
/// targets). This module never interprets it — it only stores and returns
/// it — so it names no per-OS type and stays portable.
pub const Fd = i64;

/// Sentinel for a process's in-flight-offload fd slot
/// (`ProcessControlBlock.socket_pending_fd`): NO fd is currently held there.
/// A live socket fd is always non-negative (a posix `fd_t` is `>= 0`; a
/// Windows `SOCKET` is never `~0` for a live socket), so `-1` is an
/// unambiguous "empty". The slot holds an fd produced by an offloaded
/// connect/accept BETWEEN the pool thread producing it and the fiber
/// continuation promoting it into this domain + the process ledger; if a kill
/// lands in that window the teardown socket-sweep closes whatever fd is still
/// parked here (the `abi.zig` HIGH-1 reclamation discipline).
pub const no_pending_socket_fd: Fd = -1;

/// What kind of socket a handle names. Reserved from S0 so the layout is
/// stable when TLS lands (S4/S5): a TLS session lives behind the SAME
/// handle type, distinguished by this tag, per Decision B.
pub const SocketKind = enum(u8) {
    /// A plaintext TCP/UDP/Unix socket.
    plain = 0,
    /// A TLS session riding the same handle (S4/S5; reserved in S0).
    tls_session = 1,
};

/// Reserved generation marking a retired slot (never reissued): a slot
/// whose generation would wrap is retired instead — the discipline that
/// makes handle-reuse ABA structurally impossible.
const retired_generation: u32 = std.math.maxInt(u32);

/// Table-level lifecycle state of a slot.
const Occupancy = enum(u8) {
    /// In the free list, available to `open`.
    free = 0,
    /// Holds a live socket; the slot's `fd`/`owner`/`kind` are valid.
    occupied = 1,
    /// Generation space exhausted; permanently out of service.
    retired = 2,
};

/// The packed per-slot atomic word: generation + occupancy, observed and
/// mutated together so every validate/close decision reads one atomic
/// unit (the `pid_table.zig` "read as one unit" discipline). There is no
/// share count — a socket is single-owner.
const SlotState = packed struct(u64) {
    generation: u32,
    occupancy: Occupancy,
    reserved: u24 = 0,
};

// ---------------------------------------------------------------------------
// Slot table geometry
// ---------------------------------------------------------------------------

/// Slots per segment. Segments are allocated on demand under the domain
/// lock and never freed until `deinit`, so slot addresses are stable for
/// the domain's lifetime (the type-stability the validation discipline
/// rests on).
const slots_per_segment: u32 = 1024;

/// Maximum number of segments (fixed pointer array in the domain). The
/// ceiling is 1024 × 1024 ≈ 1M simultaneously-open sockets — far beyond
/// any real fd working set (the OS `RLIMIT_NOFILE` binds first); exceeding
/// it fails `open` loudly (`error.SocketTableExhausted`), never silently.
const max_segment_count: u32 = 1024;

/// Free-list terminator for `Slot.next_free`.
const no_free_slot: u32 = std.math.maxInt(u32);

/// One slot of the socket table. `state` carries the generation/occupancy
/// protocol (atomic — validated from the owning core or a teardown
/// scheduler thread). `fd`/`owner_pid_bits`/`kind` are plain fields
/// written only while the slot is PRIVATELY held (before the publishing
/// state store, or after winning the freeing transition); the state word's
/// release/acquire edge orders them for any later validated reader. Since a
/// socket is single-owner there is no racy cross-owner probe (unlike the
/// blob string-tier), so these need no per-field atomicity.
const Slot = struct {
    /// Packed `{generation, occupancy}` — see `SlotState`.
    state: std.atomic.Value(u64),
    /// The platform fd this slot owns while `occupied`.
    fd: Fd,
    /// The owning process's pid bits (`0` gate-OFF, where there are no
    /// processes). Recorded for later `send_move` re-parenting (S3) and
    /// foreign-handle diagnostics.
    owner_pid_bits: u64,
    /// The local port this socket is bound to: the ephemeral port for a
    /// `listen` socket (so `Socket.local_port` can report it — §7.3's
    /// "bind port 0 → local_address to discover"), `0` for an S0 client.
    local_port: u16,
    /// Whether this is a plaintext or TLS socket (reserved for S4/S5).
    kind: SocketKind,
    /// Intrusive free-list link (slot index; guarded by the domain lock).
    next_free: u32,
};

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/// Domain statistics snapshot (tests + observability). Taken under the
/// domain lock for a consistent `{live, peak}` pair.
pub const Statistics = struct {
    /// Sockets currently open (opened, not yet closed).
    live_socket_count: u32,
    /// High-watermark of `live_socket_count`.
    live_socket_peak: u32,
    /// Slots permanently retired by generation exhaustion.
    retired_slot_count: u32,
};

// ---------------------------------------------------------------------------
// The domain
// ---------------------------------------------------------------------------

/// The socket allocation domain: the segmented generational slot table.
/// One per runtime (owned gate-ON by `abi.zig`'s `RuntimeState`, gate-OFF
/// by the always-linked runtime's lazy singleton). Kernel tests create
/// standalone instances. Must not move once handles are issued (slots are
/// reached through the embedded segment pointer array).
pub const SocketDomain = struct {
    /// Guards slot acquire/recycle, segment growth, the free list, and the
    /// statistics counters. Cold path only (once per socket open/close).
    domain_lock: std.atomic.Mutex,
    /// Segment pointer array (segments allocated on demand, stable once
    /// created). Written under `domain_lock`; read lock-free by
    /// `slotPointer`, ordered by the `initialized_slot_count`
    /// release/acquire pair.
    segments: [max_segment_count]?[*]Slot,
    /// Number of segments currently allocated.
    segment_count: u32,
    /// Slots ever carved (bump cursor). Atomic because `slotPointer` reads
    /// it WITHOUT the domain lock: the `.release` store (under the lock,
    /// after the slot and its segment are fully initialized) pairs with the
    /// lock-free `.acquire` load so an admitted index always resolves to
    /// initialized memory.
    initialized_slot_count: std.atomic.Value(u32),
    /// Head of the vacant-slot free list (slot index), `no_free_slot` when
    /// empty. Guarded by `domain_lock`.
    free_list_head: u32,
    /// Live socket count. Guarded by `domain_lock`.
    live_socket_count: u32,
    /// High-watermark of `live_socket_count`. Guarded by `domain_lock`.
    live_socket_peak: u32,
    /// Slots permanently retired. Guarded by `domain_lock`.
    retired_slot_count: u32,

    pub const OpenError = error{
        /// Every table slot is live (the documented fixed ceiling).
        SocketTableExhausted,
        /// A table segment could not be allocated.
        OutOfMemory,
    };

    /// Create an empty domain. The slot table grows on demand.
    pub fn init() SocketDomain {
        return .{
            .domain_lock = .unlocked,
            .segments = @splat(null),
            .segment_count = 0,
            .initialized_slot_count = .init(0),
            .free_list_head = no_free_slot,
            .live_socket_count = 0,
            .live_socket_peak = 0,
            .retired_slot_count = 0,
        };
    }

    /// Tear the domain down: assert the leak-exactness gate — no socket may
    /// still be open (every process ledger must have closed/drained first,
    /// exactly the blob domain's "zero live" discipline) — and free the
    /// segments.
    pub fn deinit(domain: *SocketDomain) void {
        std.debug.assert(domain.live_socket_count == 0);
        for (domain.segments[0..domain.segment_count]) |segment| {
            backing_allocator.free(@as([]Slot, segment.?[0..slots_per_segment]));
        }
        domain.* = undefined;
    }

    /// Snapshot the domain counters (tests + observability).
    pub fn statistics(domain: *SocketDomain) Statistics {
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        return .{
            .live_socket_count = domain.live_socket_count,
            .live_socket_peak = domain.live_socket_peak,
            .retired_slot_count = domain.retired_slot_count,
        };
    }

    // -- open / close ------------------------------------------------------

    /// Register an already-connected `fd` in a fresh slot owned by
    /// `owner_pid_bits` (0 gate-OFF), and mint its `{slot, generation}`
    /// handle. The bridge calls this AFTER the connect syscall succeeds, so
    /// the domain never performs I/O.
    pub fn open(
        domain: *SocketDomain,
        socket_fd: Fd,
        owner_pid_bits: u64,
        local_port: u16,
        socket_kind: SocketKind,
    ) OpenError!SocketHandle {
        const acquired = try domain.acquireSlot();
        acquired.slot.fd = socket_fd;
        acquired.slot.owner_pid_bits = owner_pid_bits;
        acquired.slot.local_port = local_port;
        acquired.slot.kind = socket_kind;
        // Publish: occupied, this generation. `.release` orders the
        // fd/owner/kind writes above before any acquire-load of the state —
        // a reader that validates the generation is guaranteed to see them.
        acquired.slot.state.store(@bitCast(SlotState{
            .generation = acquired.handle.generation,
            .occupancy = .occupied,
        }), .release);
        return acquired.handle;
    }

    /// Whether `handle` names a live socket owned by this domain (generation-
    /// validated). A stale/forged/closed handle returns false — never faults.
    pub fn isLive(domain: *SocketDomain, handle: SocketHandle) bool {
        const slot = domain.slotPointer(handle) orelse return false;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        return state.occupancy == .occupied and state.generation == handle.generation;
    }

    /// The platform fd for a live handle, or null when the handle is stale
    /// (closed / forged / wrong generation). Reads only the type-stable slot.
    pub fn fd(domain: *SocketDomain, handle: SocketHandle) ?Fd {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        return slot.fd;
    }

    /// The owning pid bits for a live handle, or null when stale.
    pub fn owner(domain: *SocketDomain, handle: SocketHandle) ?u64 {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        return slot.owner_pid_bits;
    }

    /// The socket kind for a live handle, or null when stale.
    pub fn kind(domain: *SocketDomain, handle: SocketHandle) ?SocketKind {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        return slot.kind;
    }

    /// The local (bound) port for a live handle, or null when stale.
    pub fn localPort(domain: *SocketDomain, handle: SocketHandle) ?u16 {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        return slot.local_port;
    }

    /// Close a handle: validate its generation, bump the generation (which
    /// invalidates EVERY outstanding copy of this handle in one store),
    /// recycle the slot (or retire it at generation exhaustion), and return
    /// the fd the caller must now close via the I/O seam. Returns null when
    /// the handle is already stale (closed / forged / wrong generation) —
    /// the surface turns that into a use-after-close panic. The fd is
    /// returned rather than closed here to keep this module free of I/O.
    pub fn close(domain: *SocketDomain, handle: SocketHandle) ?Fd {
        const slot = domain.slotPointer(handle) orelse return null;
        // Validate the generation and recycle the slot ATOMICALLY under the
        // domain lock (MED-2). Reading the state, deciding the handle is live,
        // and retiring/recycling the slot must be ONE indivisible step:
        // otherwise two concurrent closes of the same live handle could BOTH
        // pass the generation check (each loading before either recycles) and
        // BOTH recycle the slot — corrupting the free list (a slot linked
        // twice) and double-closing a possibly-already-reused fd. Taking the
        // lock BEFORE the validating load closes that window: the first close
        // bumps the generation under the lock, so the second's load (also under
        // the lock) fails the generation check and returns null. The `.acquire`
        // load still pairs with `open`'s `.release` publish (performed outside
        // the lock) so `slot.fd`/`owner`/`kind` are visible to this reader.
        domain.lockDomain();
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) {
            domain.domain_lock.unlock();
            return null;
        }
        const closed_fd = slot.fd;
        domain.recycleSlotLocked(handle.slot, slot, state.generation);
        domain.domain_lock.unlock();
        return closed_fd;
    }

    // -- internal ----------------------------------------------------------

    const AcquiredSlot = struct {
        handle: SocketHandle,
        slot: *Slot,
    };

    /// Acquire a vacant slot (free list first, then bump-carve, growing by
    /// one segment when exhausted) and mint its next-generation handle. The
    /// returned slot is privately held: its state word still reads
    /// `{free, old generation}` so every concurrent stale probe fails; the
    /// caller publishes the occupied state after wiring fd/owner/kind.
    fn acquireSlot(domain: *SocketDomain) OpenError!AcquiredSlot {
        domain.lockDomain();

        while (domain.free_list_head != no_free_slot) {
            const slot_index = domain.free_list_head;
            const slot = domain.slotPointerUnchecked(slot_index);
            domain.free_list_head = slot.next_free;
            slot.next_free = no_free_slot;
            const state: SlotState = @bitCast(slot.state.load(.monotonic));
            std.debug.assert(state.occupancy == .free);
            if (state.generation == retired_generation) {
                // A slot whose generation wrapped is retired — never
                // reissued. Fall through to the next free slot or a carve.
                continue;
            }
            domain.noteSocketOpenedLocked();
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
                return error.SocketTableExhausted;
            }
            const segment = backing_allocator.alloc(Slot, slots_per_segment) catch {
                domain.domain_lock.unlock();
                return error.OutOfMemory;
            };
            domain.segments[domain.segment_count] = segment.ptr;
            domain.segment_count += 1;
        }
        const slot_index = carved_count;
        const slot = domain.slotPointerUnchecked(slot_index);
        slot.* = .{
            // Generation 1 is the first issued generation (0 is the reserved
            // invalid — a zero handle never validates).
            .state = .init(@bitCast(SlotState{ .generation = 1, .occupancy = .free })),
            .fd = 0,
            .owner_pid_bits = 0,
            .local_port = 0,
            .kind = .plain,
            .next_free = no_free_slot,
        };
        // Publish the carve AFTER the slot (and its segment pointer) are
        // fully initialized: the lock-free `slotPointer` acquire-load pairing
        // makes an admitted index safe to dereference.
        domain.initialized_slot_count.store(slot_index + 1, .release);
        domain.noteSocketOpenedLocked();
        domain.domain_lock.unlock();
        return .{
            .handle = .{ .slot = slot_index, .generation = 1 },
            .slot = slot,
        };
    }

    /// Recycle a slot on close, with `domain_lock` ALREADY HELD by the caller
    /// (`close`, so validation and recycling are one atomic step — MED-2): bump
    /// the generation (killing every outstanding handle of this slot) and
    /// return it to the free list, or retire it at generation exhaustion.
    /// `current_generation` is the validated live generation.
    fn recycleSlotLocked(domain: *SocketDomain, slot_index: u32, slot: *Slot, current_generation: u32) void {
        const retiring = current_generation == retired_generation - 1;
        if (retiring) {
            // Generation space exhausted: park the slot permanently so the
            // {slot, generation} space is never reissued.
            slot.state.store(@bitCast(SlotState{
                .generation = retired_generation,
                .occupancy = .retired,
            }), .release);
            domain.retired_slot_count += 1;
        } else {
            slot.state.store(@bitCast(SlotState{
                .generation = current_generation + 1,
                .occupancy = .free,
            }), .release);
            slot.next_free = domain.free_list_head;
            domain.free_list_head = slot_index;
        }
        std.debug.assert(domain.live_socket_count > 0);
        domain.live_socket_count -= 1;
    }

    fn noteSocketOpenedLocked(domain: *SocketDomain) void {
        domain.live_socket_count += 1;
        if (domain.live_socket_count > domain.live_socket_peak) {
            domain.live_socket_peak = domain.live_socket_count;
        }
    }

    /// Resolve a handle's slot pointer, or null when the slot index was
    /// never carved (a forged/garbage handle — reads only domain-stable
    /// state, so it never faults). `initialized_slot_count` grows only, and
    /// the release/acquire pairing guarantees an admitted index resolves to
    /// fully initialized memory.
    fn slotPointer(domain: *SocketDomain, handle: SocketHandle) ?*Slot {
        if (handle.slot >= domain.initialized_slot_count.load(.acquire)) return null;
        return domain.slotPointerUnchecked(handle.slot);
    }

    fn slotPointerUnchecked(domain: *SocketDomain, slot_index: u32) *Slot {
        const segment = domain.segments[slot_index / slots_per_segment].?;
        return &segment[slot_index % slots_per_segment];
    }

    fn lockDomain(domain: *SocketDomain) void {
        while (!domain.domain_lock.tryLock()) std.atomic.spinLoopHint();
    }
};

// ---------------------------------------------------------------------------
// Per-process ownership ledger
// ---------------------------------------------------------------------------

/// The per-process record of owned socket handles (a PCB field —
/// `process.zig`). Owner-only, like every PCB field: only the process's own
/// quantum appends/removes, and teardown (the owning scheduler, via the
/// drop-list sweep destructor) drains it. Each entry is one owned socket;
/// the teardown drain closes every fd the process still owns — the drop-list
/// discipline (research.md §6.5) for the socket tier, modeled on
/// `blob.zig`'s `BlobLedger`.
///
/// Storage grows by doubling from the page allocator and is freed at
/// teardown. The ledger stores only handle bits; the actual fd close is the
/// bridge's job (this module performs no I/O), so the sweep iterates
/// `ownedHandles()` and closes each fd through the I/O seam, then
/// `releaseStorage()`.
pub const SocketLedger = struct {
    entries: ?[*]u64,
    entry_count: u32,
    capacity: u32,
    /// The reason code of this process's most recent FAILED `connect`/
    /// `listen` — an errno-style per-process last-error (per-process, so it
    /// is race-free across green-process preemption, unlike a thread-local).
    /// The socket bridge stores it when a blocking op fails and returns the
    /// `0`/invalid handle; `lib/socket.zap` reads it in the immediately
    /// following (non-yielding) error arm to build the typed `SocketError`.
    /// A `socket_io.Reason` value (0 = ok / none).
    last_error: i32,
    /// The status of this process's most recent `recv` (Phase S1): `0` =
    /// CHUNK (bytes were delivered), `-1` = CLOSED (clean EOF), a positive
    /// `socket_io.Reason` code = FAILED (`2` = idle timeout). Like
    /// `last_error` it is a per-process errno-style slot the socket bridge
    /// writes when a `recv` completes and `lib/socket.zap` reads in the
    /// immediately-following (non-yielding) arm to build the `SocketRecv`
    /// union — race-free across green-process preemption.
    last_recv_status: i32,

    pub const empty = SocketLedger{ .entries = null, .entry_count = 0, .capacity = 0, .last_error = 0, .last_recv_status = 0 };

    const initial_capacity: u32 = 8;

    /// Record one owned socket handle.
    pub fn append(ledger: *SocketLedger, handle_bits: u64) error{OutOfMemory}!void {
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

    /// Remove ONE entry matching `handle_bits`, scanning from the tail
    /// (LIFO — recently opened sockets close first in the common case).
    /// Returns false when this process owns no such handle (the surface
    /// panics — closing what you do not own is a program bug).
    pub fn removeOne(ledger: *SocketLedger, handle_bits: u64) bool {
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

    /// Whether this process owns `handle_bits` (tail-first scan). The
    /// ownership gate every socket op checks: an operation on a socket the
    /// process does not own is a program bug surfaced as a loud panic.
    pub fn contains(ledger: *const SocketLedger, handle_bits: u64) bool {
        const entries = ledger.entries orelse return false;
        var index = ledger.entry_count;
        while (index > 0) {
            index -= 1;
            if (entries[index] == handle_bits) return true;
        }
        return false;
    }

    /// The owned handles (test/observability + the teardown sweep). Valid
    /// until the next `append`/`removeOne`/`releaseStorage`.
    pub fn ownedHandles(ledger: *const SocketLedger) []const u64 {
        const entries = ledger.entries orelse return &.{};
        return entries[0..ledger.entry_count];
    }

    /// Number of owned sockets recorded.
    pub fn ownedCount(ledger: *const SocketLedger) u32 {
        return ledger.entry_count;
    }

    /// Free the ledger storage and reset to `empty`. The teardown sweep
    /// calls this AFTER closing every owned fd. With no storage it is a
    /// no-op (a process that never opened a socket).
    pub fn releaseStorage(ledger: *SocketLedger) void {
        if (ledger.entries) |entries| {
            backing_allocator.free(entries[0..ledger.capacity]);
        }
        ledger.* = .empty;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SocketDomain: open records fd/owner/kind; reads see them; close frees leak-exactly" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(7, 0xABCD, 8080, .plain);
    try testing.expect(domain.isLive(handle));
    try testing.expectEqual(@as(?Fd, 7), domain.fd(handle));
    try testing.expectEqual(@as(?u64, 0xABCD), domain.owner(handle));
    try testing.expectEqual(@as(?SocketKind, .plain), domain.kind(handle));
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_socket_count);

    // Close returns the fd for the bridge to close, and frees the slot.
    try testing.expectEqual(@as(?Fd, 7), domain.close(handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);

    // The closed handle is stale everywhere: generation bumped on close.
    try testing.expect(!domain.isLive(handle));
    try testing.expectEqual(@as(?Fd, null), domain.fd(handle));
    try testing.expectEqual(@as(?Fd, null), domain.close(handle));
}

test "SocketDomain: slot reuse bumps the generation and keeps stale handles dead" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const first = try domain.open(10, 0, 0, .plain);
    _ = domain.close(first);

    const second = try domain.open(20, 0, 0, .plain);
    try testing.expectEqual(first.slot, second.slot);
    try testing.expectEqual(first.generation + 1, second.generation);

    // The stale first handle never resolves to the reused slot.
    try testing.expect(!domain.isLive(first));
    try testing.expectEqual(@as(?Fd, null), domain.fd(first));
    try testing.expect(domain.isLive(second));
    try testing.expectEqual(@as(?Fd, 20), domain.fd(second));

    _ = domain.close(second);
}

test "SocketDomain: a forged handle (never-carved slot) never faults" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const forged = SocketHandle{ .slot = 9999, .generation = 3 };
    try testing.expect(!domain.isLive(forged));
    try testing.expectEqual(@as(?Fd, null), domain.fd(forged));
    try testing.expectEqual(@as(?u64, null), domain.owner(forged));
    try testing.expectEqual(@as(?Fd, null), domain.close(forged));

    // The invalid (all-zero) handle likewise never resolves.
    try testing.expect(!domain.isLive(SocketHandle.invalid));
}

test "SocketDomain: many opens grow segments and stay generation-consistent" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    var handles: [2500]SocketHandle = undefined;
    for (&handles, 0..) |*h, i| h.* = try domain.open(@intCast(i), 0, 0, .plain);
    try testing.expectEqual(@as(u32, 2500), domain.statistics().live_socket_count);
    for (handles, 0..) |h, i| try testing.expectEqual(@as(?Fd, @intCast(i)), domain.fd(h));
    for (handles) |h| _ = domain.close(h);
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain: concurrent closes of the same handle are exactly-once (MED-2 atomic validate+recycle)" {
    // Many threads each try to close EVERY handle in a batch. With the atomic
    // validate+recycle under `domain_lock`, exactly ONE close per handle
    // returns the fd; every other returns null. The pre-fix code read the slot
    // state OUTSIDE the lock and only THEN took the lock to recycle, so two
    // threads could both pass the generation check and both recycle the same
    // slot — the same fd returned twice (a double-close) plus free-list
    // corruption (a slot linked into the free list twice). Here that surfaces
    // as a per-handle win count of 2 (caught by the assertion) or a
    // `live_socket_count` underflow in `recycleSlotLocked`.
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle_count = 64;
    var handles: [handle_count]SocketHandle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try domain.open(@intCast(1000 + index), 0, 0, .plain);
    try testing.expectEqual(@as(u32, handle_count), domain.statistics().live_socket_count);

    var win_counts: [handle_count]std.atomic.Value(u32) = undefined;
    for (&win_counts) |*count| count.* = .init(0);

    const Closer = struct {
        domain: *SocketDomain,
        handles: []const SocketHandle,
        win_counts: []std.atomic.Value(u32),

        fn run(closer: @This()) void {
            for (closer.handles, 0..) |handle, index| {
                if (closer.domain.close(handle)) |_| {
                    _ = closer.win_counts[index].fetchAdd(1, .monotonic);
                }
            }
        }
    };

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Closer.run, .{Closer{
            .domain = &domain,
            .handles = handles[0..],
            .win_counts = win_counts[0..],
        }});
    }
    for (threads) |thread| thread.join();

    // Exactly one close won per handle — no double-close, no lost close.
    for (win_counts) |count| try testing.expectEqual(@as(u32, 1), count.load(.monotonic));
    // Leak-exact: every slot recycled exactly once, the count back to zero.
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketLedger: append/contains/removeOne discipline" {
    var ledger = SocketLedger.empty;
    defer ledger.releaseStorage();

    try ledger.append(0x1111);
    try ledger.append(0x2222);
    try ledger.append(0x3333);
    try testing.expectEqual(@as(u32, 3), ledger.ownedCount());
    try testing.expect(ledger.contains(0x2222));
    try testing.expect(!ledger.contains(0x9999));

    try testing.expect(ledger.removeOne(0x2222));
    try testing.expect(!ledger.contains(0x2222));
    try testing.expect(!ledger.removeOne(0x2222));
    try testing.expectEqual(@as(u32, 2), ledger.ownedCount());
}

test "SocketLedger: grows past the initial capacity by doubling" {
    var ledger = SocketLedger.empty;
    defer ledger.releaseStorage();

    var i: u64 = 0;
    while (i < 100) : (i += 1) try ledger.append(0x1000 + i);
    try testing.expectEqual(@as(u32, 100), ledger.ownedCount());
    i = 0;
    while (i < 100) : (i += 1) try testing.expect(ledger.contains(0x1000 + i));
}

test "SocketLedger: ownedHandles reflects the live set for the teardown sweep" {
    var ledger = SocketLedger.empty;
    defer ledger.releaseStorage();

    try ledger.append(0xAA);
    try ledger.append(0xBB);
    const owned = ledger.ownedHandles();
    try testing.expectEqual(@as(usize, 2), owned.len);
    try testing.expectEqual(@as(u64, 0xAA), owned[0]);
    try testing.expectEqual(@as(u64, 0xBB), owned[1]);
}
