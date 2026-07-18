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
//! ## Cross-process handoff — the exactly-one-owner invariant (S3)
//!
//! A socket travels between processes by `Process.send_move` (S3). The
//! transfer is a two-step state machine on the domain slot — `beginHandoff`
//! (run by the SENDER) and `completeHandoff` (run by the RECEIVER at
//! delivery) — over a MOVED envelope carrying the successor handle bits (the
//! `abi.zig` transport, mirroring the Blob flight/adopt pair). The load-
//! bearing correctness invariant, upheld across BOTH processes and every
//! crash window:
//!
//!   **At any instant EXACTLY ONE party owns the close obligation for a live
//!   slot** — either (i) exactly one process's `SocketLedger`, or (ii)
//!   exactly one in-flight moved envelope (whose reclaim hook is the owner),
//!   never both and never neither.
//!
//! `beginHandoff` BUMPS THE GENERATION in place (minting the successor on the
//! same slot/fd), re-points `owner_pid_bits` to the receiver, and sets the
//! `in_flight` bit; the sender's OLD handle bits go stale everywhere the
//! instant the handoff begins (a later op on them fails the generation check —
//! a loud panic, never a silent wrong-fd op). The sender RELINQUISHES the
//! handle from its own ledger BEFORE the envelope is enqueued, so the two
//! ownership windows (sender-ledger and in-flight-envelope) never overlap: a
//! killed sender's teardown sweep drains only its ledger, which no longer
//! holds the fd. `completeHandoff` clears the `in_flight` bit as the receiver
//! records the handle in ITS ledger (the envelope relinquishes; the ledger
//! assumes the obligation). The fd itself is closed exactly once — by whoever
//! owns it at that instant: the receiver's ledger sweep, the sender's
//! dead-letter undo, or the in-flight envelope's reclaim hook.
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
    /// Set while this slot's live socket is IN FLIGHT in a cross-process
    /// handoff — a moved envelope (not any process ledger) owns its close
    /// obligation (S3, `beginHandoff`/`completeHandoff`); cleared when the
    /// receiver adopts (`completeHandoff`). Part of the exactly-one-owner
    /// handoff state machine documented in the module header. Ignored by the
    /// ordinary validate/close reads (they gate on `occupancy`/`generation`),
    /// so it never perturbs the S0/S1 lifecycle.
    in_flight: bool = false,
    reserved: u23 = 0,
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
    /// The TLS session bound to this socket when `kind == .tls_session`, else
    /// `null` (Phase S4). STORED and RETURNED (by `close`) but NEVER
    /// DEREFERENCED here — the pure table treats it exactly like the opaque
    /// `fd`, so the module stays free of the TLS/crypto/I-O the bridge owns
    /// (`abi.zig` gate-ON, `SocketRuntime` gate-OFF cast it back to the
    /// concrete `*TlsSession`). Set by `attachTls` (fresh TLS connect) or
    /// `upgradeToTls` (STARTTLS), carried across a cross-process move by
    /// `beginHandoff`, and handed back on EVERY close path so the session is
    /// scrubbed + freed exactly once (the no-key-residue / no-leak guarantee).
    tls_state: ?*anyopaque,
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
        // A freshly opened socket carries no TLS session; the handshake path
        // (`attachTls`) or a STARTTLS `upgradeToTls` sets it later.
        acquired.slot.tls_state = null;
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

    /// The opaque TLS session bound to a live handle (Phase S4), or null when
    /// the handle is stale OR the socket is plaintext (`tls_state == null`).
    /// The bridge calls this AFTER `kind(handle) == .tls_session` to recover
    /// the session pointer it casts back to `*TlsSession`; for a `.tls_session`
    /// slot the pointer is guaranteed non-null (set atomically with the kind
    /// flip by `attachTls`/`upgradeToTls`). Reads only the type-stable slot —
    /// never faults, never dereferences the session.
    pub fn tlsState(domain: *SocketDomain, handle: SocketHandle) ?*anyopaque {
        const slot = domain.slotPointer(handle) orelse return null;
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        return slot.tls_state;
    }

    /// What a successful `close` hands back to the bridge: the fd it must now
    /// close via the I/O seam, plus the TLS session (if any) it must scrub +
    /// free. Returning them TOGETHER makes the no-leak / no-key-residue
    /// guarantee structural: every close path (explicit close, kill/crash
    /// sweep, handoff-undo, dead-letter reclaim) receives the session and frees
    /// it in lockstep with the fd — the socket's fd is closed exactly once, so
    /// its session is freed exactly once (the single-owner invariant). A plain
    /// socket returns `tls_state == null`.
    pub const ClosedSocket = struct {
        fd: Fd,
        tls_state: ?*anyopaque,
    };

    /// Close a handle: validate its generation, bump the generation (which
    /// invalidates EVERY outstanding copy of this handle in one store),
    /// recycle the slot (or retire it at generation exhaustion), and return
    /// the fd the caller must now close via the I/O seam ALONGSIDE the TLS
    /// session (if any) it must scrub + free. Returns null when the handle is
    /// already stale (closed / forged / wrong generation) — the surface turns
    /// that into a use-after-close panic. The fd/session are returned rather
    /// than acted on here to keep this module free of I/O and crypto.
    pub fn close(domain: *SocketDomain, handle: SocketHandle) ?ClosedSocket {
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
        const closed_tls_state = slot.tls_state;
        domain.recycleSlotLocked(handle.slot, slot, state.generation);
        domain.domain_lock.unlock();
        return .{ .fd = closed_fd, .tls_state = closed_tls_state };
    }

    // -- TLS binding (S4) --------------------------------------------------

    /// Bind a TLS session to a LIVE handle after a successful handshake on a
    /// FRESH TLS connection (the `Tls.connect` path): validate generation +
    /// occupancy + ownership by `from_pid_bits`, then set `tls_state` and flip
    /// `kind` to `.tls_session` as ONE atomic step under `domain_lock`. The
    /// generation is NOT bumped — the SAME handle keeps naming the socket, now
    /// TLS (a fresh connect's handle was never used for plaintext I/O, so there
    /// is nothing to invalidate — UNLIKE `upgradeToTls`). Returns true on
    /// success; false when the handle is stale/forged or not owned by
    /// `from_pid_bits` (defense in depth over the caller's ledger gate), leaving
    /// the slot UNTOUCHED. The `.release` re-store of the (unchanged) state word
    /// orders the `tls_state`/`kind` writes before any later acquire-load.
    pub fn attachTls(
        domain: *SocketDomain,
        handle: SocketHandle,
        from_pid_bits: u64,
        tls_state: *anyopaque,
    ) bool {
        const slot = domain.slotPointer(handle) orelse return false;
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return false;
        if (slot.owner_pid_bits != from_pid_bits) return false;
        slot.tls_state = tls_state;
        slot.kind = .tls_session;
        slot.state.store(@bitCast(state), .release);
        return true;
    }

    /// STARTTLS upgrade (the `Tls.upgrade` path): CONSUME the plaintext handle
    /// and mint a TLS SUCCESSOR on the same slot/fd. Validate generation +
    /// occupancy + ownership by `from_pid_bits`, bind `tls_state`, flip `kind`
    /// to `.tls_session`, and BUMP THE GENERATION IN PLACE — so the caller's
    /// OLD plaintext handle goes stale EVERYWHERE the instant the upgrade
    /// commits (a use-after-upgrade fails the generation check = a loud panic,
    /// never accidental plaintext I/O over a now-encrypted socket; the OQ2
    /// consume floor). The owner is UNCHANGED (this is not a cross-process
    /// handoff — no `in_flight`, the same process keeps owning). Returns the
    /// successor handle, or null when the handle is stale/forged or not owned
    /// by `from_pid_bits`, leaving the slot UNTOUCHED (the retire-edge carve is
    /// the only fallible step and runs before ANY mutation — the "did not mutate
    /// on failure" contract, exactly like `beginHandoff`). At the generation-
    /// exhaustion retire edge the SAME fd is re-homed on a fresh slot (the old
    /// slot retired, never reissued) so a `{slot, generation}` pair is never
    /// reused and the fd never closes. `live_socket_count` is conserved across
    /// the re-home (no fd opened/closed — the same socket, now TLS).
    pub fn upgradeToTls(
        domain: *SocketDomain,
        handle: SocketHandle,
        from_pid_bits: u64,
        tls_state: *anyopaque,
    ) ?SocketHandle {
        const slot = domain.slotPointer(handle) orelse return null;
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        if (slot.owner_pid_bits != from_pid_bits) return null;

        if (state.generation == retired_generation - 1) {
            // Generation space exhausted on this slot: re-home the SAME fd on a
            // fresh slot (the socket stays live — no fd close, no live-count
            // change) and retire the old slot. CARVE FIRST, before any mutation
            // of the old slot (the carve is the only fallible step; this module
            // is pure, so "did not mutate on failure" holds — on carve failure
            // the old plaintext handle is still valid and the caller's undo
            // closes it exactly once). Correct the transient double-count and
            // restore the pre-carve peak, exactly as `beginHandoff` does.
            const peak_before_rehome = domain.live_socket_peak;
            const acquired = domain.acquireSlotLocked() catch return null;
            std.debug.assert(domain.live_socket_count > 0);
            domain.live_socket_count -= 1;
            domain.live_socket_peak = peak_before_rehome;

            const preserved_fd = slot.fd;
            const preserved_port = slot.local_port;
            slot.state.store(@bitCast(SlotState{
                .generation = retired_generation,
                .occupancy = .retired,
            }), .release);
            domain.retired_slot_count += 1;
            acquired.slot.fd = preserved_fd;
            acquired.slot.owner_pid_bits = from_pid_bits; // same owner (not a handoff)
            acquired.slot.local_port = preserved_port;
            acquired.slot.kind = .tls_session;
            acquired.slot.tls_state = tls_state;
            acquired.slot.state.store(@bitCast(SlotState{
                .generation = acquired.handle.generation,
                .occupancy = .occupied,
            }), .release);
            return acquired.handle;
        }

        // In-place generation bump: same slot/fd, next generation, same owner,
        // now a TLS session. `.release` orders the tls_state/kind writes before
        // any acquire-load of the new state word; the old handle's generation
        // is now stale everywhere.
        slot.kind = .tls_session;
        slot.tls_state = tls_state;
        const successor_generation = state.generation + 1;
        slot.state.store(@bitCast(SlotState{
            .generation = successor_generation,
            .occupancy = .occupied,
        }), .release);
        return SocketHandle{ .slot = handle.slot, .generation = successor_generation };
    }

    // -- cross-process handoff (S3) ----------------------------------------

    /// Begin a cross-process handoff of a live handle from `from_pid_bits` to
    /// `to_pid_bits`: mint the SUCCESSOR handle by BUMPING THE GENERATION in
    /// place on the same slot/fd, re-point the owner to `to_pid_bits`, and set
    /// the `in_flight` bit — an in-flight moved envelope now owns the close
    /// obligation (the exactly-one-owner invariant, module header). Returns the
    /// successor handle, or null when the handle is stale/forged, not occupied,
    /// or not owned by `from_pid_bits` (defense in depth OVER the caller's
    /// ledger gate — the only-owner-moves security property). Validated and
    /// mutated as ONE atomic step under `domain_lock` (MED-2): a concurrent
    /// begin/close of the same handle resolves to exactly one winner (the loser
    /// fails the post-bump generation check), so one fd is never double-
    /// transferred.
    ///
    /// The generation bump makes the sender's OLD handle bits stale EVERYWHERE
    /// the instant the handoff begins: any later op on them fails the
    /// generation check (a loud panic at the surface, never a silent wrong-fd
    /// op — the stale-after-handoff property). At the retire edge (a slot whose
    /// generation would wrap) the in-place bump is REFUSED; the SAME fd is
    /// re-homed on a fresh slot and the old slot is retired (never reissued),
    /// so a `{slot, generation}` pair is never reused and the fd never closes.
    /// A carve failure at that astronomically-rare edge returns null (the
    /// caller then closes the fd — the handoff could not proceed).
    pub fn beginHandoff(
        domain: *SocketDomain,
        handle: SocketHandle,
        from_pid_bits: u64,
        to_pid_bits: u64,
    ) ?SocketHandle {
        const slot = domain.slotPointer(handle) orelse return null;
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        // Validate under the lock: live, this generation, owned by `from`.
        if (state.occupancy != .occupied or state.generation != handle.generation) return null;
        if (slot.owner_pid_bits != from_pid_bits) return null;

        if (state.generation == retired_generation - 1) {
            // Generation space exhausted on this slot: refuse the in-place bump
            // and re-home the SAME fd on a fresh slot (the socket stays live —
            // no fd close, no live-count change). Retire the old slot so its
            // `{slot, generation}` pair is never reissued.
            //
            // CARVE THE FRESH SLOT FIRST, before ANY mutation of the old slot.
            // The carve is the ONLY fallible step here, and this module is pure
            // (it cannot close an fd — Decision D), so `beginHandoff` upholds its
            // "did not mutate on failure" contract by NOT touching the old slot
            // until the carve has succeeded. If the carve fails (table exhausted
            // / OOM) the old slot is left UNTOUCHED and still live at its original
            // generation, so the caller's undo (`abi.zig`'s handoff-send failure
            // arm) validly closes the ORIGINAL handle exactly once — no fd leak.
            // Retiring the old slot BEFORE the carve would strand `preserved_fd`
            // on carve failure: the original handle's now-stale generation would
            // fail the caller's `close`, leaking the fd.
            //
            // `acquireSlotLocked` counts the carve as a newly opened socket and
            // may raise `live_socket_peak`, but this is the SAME live socket
            // re-homed, not a new open: `live_socket_count` is CONSERVED across
            // the handoff (the leak-exactness gate at `deinit` depends on it), so
            // correct the double count. The peak must not be spuriously inflated
            // by the transient double count either, so restore it to its pre-carve
            // value once the count is corrected.
            const peak_before_rehome = domain.live_socket_peak;
            const acquired = domain.acquireSlotLocked() catch return null;
            std.debug.assert(domain.live_socket_count > 0);
            domain.live_socket_count -= 1;
            domain.live_socket_peak = peak_before_rehome;

            // The carve succeeded — the point of no return. Now retire the OLD
            // slot and re-home the SAME fd/port/kind onto the fresh slot,
            // re-parented to the receiver and in-flight.
            const preserved_fd = slot.fd;
            const preserved_port = slot.local_port;
            const preserved_kind = slot.kind;
            // A moved TLS socket CARRIES its session across the process boundary
            // (Phase S4): the session heap-box is process-agnostic, so the
            // successor slot re-homes the same `tls_state` — the receiver's
            // later recv decrypts into ITS recv-arena, and whichever process
            // ultimately closes the successor scrubs + frees the one session
            // exactly once (never two processes sharing it).
            const preserved_tls_state = slot.tls_state;
            slot.state.store(@bitCast(SlotState{
                .generation = retired_generation,
                .occupancy = .retired,
            }), .release);
            domain.retired_slot_count += 1;
            acquired.slot.fd = preserved_fd;
            acquired.slot.owner_pid_bits = to_pid_bits;
            acquired.slot.local_port = preserved_port;
            acquired.slot.kind = preserved_kind;
            acquired.slot.tls_state = preserved_tls_state;
            acquired.slot.state.store(@bitCast(SlotState{
                .generation = acquired.handle.generation,
                .occupancy = .occupied,
                .in_flight = true,
            }), .release);
            return acquired.handle;
        }

        // In-place bump: same slot, same fd, next generation, re-parented
        // owner, in-flight. `.release` orders the owner write before any
        // acquire-load of the new state word.
        slot.owner_pid_bits = to_pid_bits;
        const successor_generation = state.generation + 1;
        slot.state.store(@bitCast(SlotState{
            .generation = successor_generation,
            .occupancy = .occupied,
            .in_flight = true,
        }), .release);
        return SocketHandle{ .slot = handle.slot, .generation = successor_generation };
    }

    /// Complete a cross-process handoff: the receiver `to_pid_bits` adopts the
    /// in-flight successor `handle`. Validate, require the `in_flight` bit set
    /// AND the owner already re-pointed to `to_pid_bits` (both established by
    /// `beginHandoff`), then CLEAR `in_flight` — the receiver's ledger now owns
    /// the close obligation, the in-flight envelope relinquishes it. Returns
    /// false when the handle is stale (a laundered/forged/replayed `u64` fails
    /// the generation check post-bump — the no-forged-adoption gate), NOT in
    /// flight (already adopted — the no-double-adopt gate), or not in flight to
    /// `to_pid_bits`. Validated + mutated as one atomic step under `domain_lock`.
    pub fn completeHandoff(domain: *SocketDomain, handle: SocketHandle, to_pid_bits: u64) bool {
        const slot = domain.slotPointer(handle) orelse return false;
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        const state: SlotState = @bitCast(slot.state.load(.acquire));
        if (state.occupancy != .occupied or state.generation != handle.generation) return false;
        if (!state.in_flight or slot.owner_pid_bits != to_pid_bits) return false;
        slot.state.store(@bitCast(SlotState{
            .generation = state.generation,
            .occupancy = .occupied,
            .in_flight = false,
        }), .release);
        return true;
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
    /// caller publishes the occupied state after wiring fd/owner/kind. Takes
    /// `domain_lock` for the duration; `beginHandoff`'s retire-edge path reuses
    /// the lock-held body directly (`acquireSlotLocked`).
    fn acquireSlot(domain: *SocketDomain) OpenError!AcquiredSlot {
        domain.lockDomain();
        defer domain.domain_lock.unlock();
        return domain.acquireSlotLocked();
    }

    /// The lock-held body of `acquireSlot` — assumes `domain_lock` is ALREADY
    /// held and does not release it (so a caller mid-transaction, like
    /// `beginHandoff`'s generation-exhaustion re-home, can carve a fresh slot
    /// without dropping the lock). Every mutation it performs (free-list pop,
    /// segment growth, bump-carve, `live_socket_count`) is guarded by that held
    /// lock exactly as in the wrapper.
    fn acquireSlotLocked(domain: *SocketDomain) OpenError!AcquiredSlot {
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
                return error.SocketTableExhausted;
            }
            const segment = backing_allocator.alloc(Slot, slots_per_segment) catch {
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
            .tls_state = null,
            .next_free = no_free_slot,
        };
        // Publish the carve AFTER the slot (and its segment pointer) are
        // fully initialized: the lock-free `slotPointer` acquire-load pairing
        // makes an admitted index safe to dereference.
        domain.initialized_slot_count.store(slot_index + 1, .release);
        domain.noteSocketOpenedLocked();
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
        // Clear the TLS binding as the slot leaves service — `close` already
        // captured it to hand back, and a recycled/retired slot must never
        // carry a stale session pointer into its next life (a fresh `open`
        // re-nulls it too; this is defense in depth so an inspecting reader
        // never sees a dangling pointer on a free/retired slot).
        slot.tls_state = null;
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

/// Assert a `close` result: `expected == null` requires a stale-handle null;
/// `expected == fd` requires a live close returning that fd. The `tls_state`
/// (Phase S4) is asserted separately by the TLS tests — most tests close plain
/// sockets and only care that the fd comes back exactly once.
fn expectClosedFd(expected: ?Fd, closed: ?SocketDomain.ClosedSocket) !void {
    if (expected) |fd| {
        try testing.expect(closed != null);
        try testing.expectEqual(fd, closed.?.fd);
    } else {
        try testing.expect(closed == null);
    }
}

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
    try expectClosedFd(7, domain.close(handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);

    // The closed handle is stale everywhere: generation bumped on close.
    try testing.expect(!domain.isLive(handle));
    try testing.expectEqual(@as(?Fd, null), domain.fd(handle));
    try expectClosedFd(null, domain.close(handle));
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
    try expectClosedFd(null, domain.close(forged));

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

test "SocketDomain.beginHandoff: bumps the generation, re-points the owner, sets in-flight; the sender's OLD handle is stale everywhere" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const original = try domain.open(42, 0xAAAA, 1234, .plain);
    const successor = domain.beginHandoff(original, 0xAAAA, 0xBBBB) orelse
        return error.TestUnexpectedResult;

    // Successor: same slot/fd, next generation, re-parented to B, port/kind
    // preserved — and the socket is STILL live (a re-parent, not a close).
    try testing.expectEqual(original.slot, successor.slot);
    try testing.expectEqual(original.generation + 1, successor.generation);
    try testing.expectEqual(@as(?Fd, 42), domain.fd(successor));
    try testing.expectEqual(@as(?u64, 0xBBBB), domain.owner(successor));
    try testing.expectEqual(@as(?u16, 1234), domain.localPort(successor));
    try testing.expect(domain.isLive(successor));
    // Live-count conserved (no fd close during the handoff).
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_socket_count);

    // The sender's OLD handle is stale everywhere the instant the handoff
    // began — the stale-after-handoff security property.
    try testing.expect(!domain.isLive(original));
    try testing.expectEqual(@as(?Fd, null), domain.fd(original));
    try testing.expectEqual(@as(?u64, null), domain.owner(original));
    try expectClosedFd(null, domain.close(original));

    // Complete + close leak-exactly.
    try testing.expect(domain.completeHandoff(successor, 0xBBBB));
    try expectClosedFd(42, domain.close(successor));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.beginHandoff: rejects a wrong-owner move without mutating the slot (only-owner-moves, defense in depth)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(7, 0xAAAA, 0, .plain);
    // A process that is NOT the owner cannot begin the handoff.
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(handle, 0xDEAD, 0xBBBB));
    // The slot is untouched: the true owner's handle is still live and owned.
    try testing.expect(domain.isLive(handle));
    try testing.expectEqual(@as(?u64, 0xAAAA), domain.owner(handle));
    _ = domain.close(handle);
}

test "SocketDomain.beginHandoff: a stale/forged handle never begins a handoff (returns null, never faults)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(9, 0xAAAA, 0, .plain);
    _ = domain.close(handle);
    // The closed (generation-bumped) handle can no longer be moved.
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(handle, 0xAAAA, 0xBBBB));
    // A forged never-carved handle likewise.
    const forged = SocketHandle{ .slot = 9999, .generation = 3 };
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(forged, 0xAAAA, 0xBBBB));
}

test "SocketDomain.completeHandoff: no-double-adopt — a second complete of the same successor fails" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const original = try domain.open(11, 0xAAAA, 0, .plain);
    const successor = domain.beginHandoff(original, 0xAAAA, 0xBBBB).?;

    // First complete clears in-flight (B's ledger now owns the obligation).
    try testing.expect(domain.completeHandoff(successor, 0xBBBB));
    // A second complete finds in_flight already cleared → false (no double
    // adoption of one in-flight fragment).
    try testing.expect(!domain.completeHandoff(successor, 0xBBBB));
    // A complete claiming the WRONG receiver fails too (owner mismatch).
    const again = try domain.open(12, 0xAAAA, 0, .plain);
    const again_successor = domain.beginHandoff(again, 0xAAAA, 0xBBBB).?;
    try testing.expect(!domain.completeHandoff(again_successor, 0xCCCC));
    // The legitimate receiver still can.
    try testing.expect(domain.completeHandoff(again_successor, 0xBBBB));

    _ = domain.close(successor);
    _ = domain.close(again_successor);
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.completeHandoff: a laundered successor with the wrong generation fails (no forged adoption)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const original = try domain.open(13, 0xAAAA, 0, .plain);
    const successor = domain.beginHandoff(original, 0xAAAA, 0xBBBB).?;
    // A forged u64 on the right slot but a wrong generation cannot be adopted.
    const laundered = SocketHandle{ .slot = successor.slot, .generation = successor.generation + 7 };
    try testing.expect(!domain.completeHandoff(laundered, 0xBBBB));
    // The genuine successor still completes.
    try testing.expect(domain.completeHandoff(successor, 0xBBBB));
    _ = domain.close(successor);
}

test "SocketDomain.beginHandoff: a chained handoff A->B->C re-points each time; only the newest handle is live" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const a_handle = try domain.open(21, 0xA, 0, .plain);
    const b_handle = domain.beginHandoff(a_handle, 0xA, 0xB).?;
    try testing.expect(domain.completeHandoff(b_handle, 0xB));
    // A re-move of the SUCCESSOR from B to C works; the A handle stays dead and
    // begin on the stale A handle is refused.
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(a_handle, 0xA, 0xC));
    const c_handle = domain.beginHandoff(b_handle, 0xB, 0xC).?;
    try testing.expect(!domain.isLive(a_handle));
    try testing.expect(!domain.isLive(b_handle));
    try testing.expect(domain.isLive(c_handle));
    try testing.expectEqual(@as(?u64, 0xC), domain.owner(c_handle));
    try testing.expect(domain.completeHandoff(c_handle, 0xC));
    try expectClosedFd(21, domain.close(c_handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.beginHandoff: the generation-exhaustion retire edge re-homes the fd on a fresh slot, live-count conserved" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    // Open a socket, then artificially advance its slot to the retire edge
    // (a real slot would need ~4 billion open/close cycles). White-box: the
    // test shares the module, so it reaches the slot word directly.
    const handle = try domain.open(42, 0xAAAA, 1234, .plain);
    const edge_slot = domain.slotPointerUnchecked(handle.slot);
    edge_slot.state.store(@bitCast(SlotState{
        .generation = retired_generation - 1,
        .occupancy = .occupied,
    }), .release);
    const edge_handle = SocketHandle{ .slot = handle.slot, .generation = retired_generation - 1 };

    const live_before = domain.statistics().live_socket_count;
    const peak_before = domain.statistics().live_socket_peak;
    const retired_before = domain.statistics().retired_slot_count;

    const successor = domain.beginHandoff(edge_handle, 0xAAAA, 0xBBBB) orelse
        return error.TestUnexpectedResult;

    // The fd is re-homed on a DIFFERENT slot (the exhausted slot retired), the
    // SAME fd/port carried over, re-parented to B.
    try testing.expect(successor.slot != handle.slot);
    try testing.expectEqual(@as(?Fd, 42), domain.fd(successor));
    try testing.expectEqual(@as(?u64, 0xBBBB), domain.owner(successor));
    try testing.expectEqual(@as(?u16, 1234), domain.localPort(successor));
    // Live-count CONSERVED (still one live socket); one slot retired.
    try testing.expectEqual(live_before, domain.statistics().live_socket_count);
    try testing.expectEqual(retired_before + 1, domain.statistics().retired_slot_count);
    // Peak CONSERVED too: a re-home opens no new socket, so the transient
    // carve-count bump inside `acquireSlotLocked` must not inflate the peak.
    try testing.expectEqual(peak_before, domain.statistics().live_socket_peak);
    // The retired edge handle is stale everywhere.
    try testing.expect(!domain.isLive(edge_handle));
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(edge_handle, 0xAAAA, 0xCCCC));

    try testing.expect(domain.completeHandoff(successor, 0xBBBB));
    try expectClosedFd(42, domain.close(successor));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.beginHandoff: a carve FAILURE at the retire edge leaves the old slot UNTOUCHED — the original handle stays live and closeable (no fd leak)" {
    // The retire edge re-homes the fd onto a FRESH slot; carving that slot is
    // the ONLY fallible step. If it fails (table exhausted / OOM) `beginHandoff`
    // must honour its "did not mutate on failure" contract at THIS edge too: the
    // OLD slot must be left UNTOUCHED and still live at its original generation,
    // so the caller's undo (`abi.zig`'s `zap_socket_handoff_send` failure arm)
    // validly closes the ORIGINAL handle exactly once. Before the carve-first
    // reorder the old slot was RETIRED before the failing carve, stranding its
    // fd: the original handle's now-stale generation failed the caller's `close`,
    // which returned null, and the fd LEAKED (a pure one-fd DoS leak).
    var domain = SocketDomain.init();
    defer domain.deinit();

    // A live socket whose slot is advanced to the retire edge (white-box: the
    // test shares the module, so it reaches the slot word directly).
    const handle = try domain.open(42, 0xAAAA, 1234, .plain);
    const edge_slot = domain.slotPointerUnchecked(handle.slot);
    edge_slot.state.store(@bitCast(SlotState{
        .generation = retired_generation - 1,
        .occupancy = .occupied,
    }), .release);
    const edge_handle = SocketHandle{ .slot = handle.slot, .generation = retired_generation - 1 };

    // Force the re-home carve to fail with `error.SocketTableExhausted`: the free
    // list is empty (the one slot is occupied), so drive the bump-carve cursor to
    // the fixed segment ceiling. White-box geometry, restored below so `deinit`
    // (which walks `segments[0..segment_count]`) stays sound on every exit.
    std.debug.assert(domain.free_list_head == no_free_slot);
    const saved_segment_count = domain.segment_count;
    const saved_initialized = domain.initialized_slot_count.load(.monotonic);
    domain.segment_count = max_segment_count;
    domain.initialized_slot_count.store(max_segment_count * slots_per_segment, .monotonic);

    const live_before = domain.statistics().live_socket_count;
    const peak_before = domain.statistics().live_socket_peak;
    const retired_before = domain.statistics().retired_slot_count;

    // The handoff cannot proceed — the re-home carve fails.
    try testing.expectEqual(@as(?SocketHandle, null), domain.beginHandoff(edge_handle, 0xAAAA, 0xBBBB));

    // Restore the faked table geometry BEFORE any fallible assertion so `deinit`
    // stays sound regardless of which assertion (if any) trips.
    domain.segment_count = saved_segment_count;
    domain.initialized_slot_count.store(saved_initialized, .monotonic);

    // CONTRACT: the failed handoff did not mutate the old slot. The ORIGINAL
    // handle is still live, still owned by the sender, still naming fd 42 — and
    // nothing was retired or double-counted along the way.
    try testing.expect(domain.isLive(edge_handle));
    try testing.expectEqual(@as(?Fd, 42), domain.fd(edge_handle));
    try testing.expectEqual(@as(?u64, 0xAAAA), domain.owner(edge_handle));
    try testing.expectEqual(live_before, domain.statistics().live_socket_count);
    try testing.expectEqual(peak_before, domain.statistics().live_socket_peak);
    try testing.expectEqual(retired_before, domain.statistics().retired_slot_count);

    // NO fd LEAK: the caller's undo closes the ORIGINAL handle exactly once and
    // the live count returns to baseline (this close retires the exhausted slot).
    try expectClosedFd(42, domain.close(edge_handle));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
    try testing.expectEqual(retired_before + 1, domain.statistics().retired_slot_count);
}

test "SocketDomain: concurrent beginHandoff of one handle mints exactly ONE successor (atomic under domain_lock)" {
    // The handoff analogue of the MED-2 concurrent-close proof: if two threads
    // both `beginHandoff` the SAME live handle, exactly ONE may win (bump the
    // generation, mint the successor, set in-flight); every other must fail the
    // post-bump generation check and return null. Two winners would double-
    // transfer one fd — two in-flight envelopes owning one close obligation, a
    // guaranteed double-close/leak. The atomic validate+bump under `domain_lock`
    // closes that window.
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle_count = 64;
    var handles: [handle_count]SocketHandle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try domain.open(@intCast(1000 + index), 0xA, 0, .plain);

    var win_counts: [handle_count]std.atomic.Value(u32) = undefined;
    for (&win_counts) |*count| count.* = .init(0);
    var successors: [handle_count]std.atomic.Value(u64) = undefined;
    for (&successors) |*successor| successor.* = .init(0);

    const Beginner = struct {
        domain: *SocketDomain,
        handles: []const SocketHandle,
        win_counts: []std.atomic.Value(u32),
        successors: []std.atomic.Value(u64),

        fn run(beginner: @This()) void {
            for (beginner.handles, 0..) |handle, index| {
                if (beginner.domain.beginHandoff(handle, 0xA, 0xB)) |successor| {
                    _ = beginner.win_counts[index].fetchAdd(1, .monotonic);
                    beginner.successors[index].store(successor.toBits(), .monotonic);
                }
            }
        }
    };

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Beginner.run, .{Beginner{
            .domain = &domain,
            .handles = handles[0..],
            .win_counts = win_counts[0..],
            .successors = successors[0..],
        }});
    }
    for (threads) |thread| thread.join();

    // Exactly one begin won per handle; complete + close each minted successor —
    // leak-exact back to zero (no fd double-transferred, none lost).
    for (win_counts, 0..) |count, index| {
        try testing.expectEqual(@as(u32, 1), count.load(.monotonic));
        const successor = SocketHandle.fromBits(successors[index].load(.monotonic));
        try testing.expect(domain.completeHandoff(successor, 0xB));
        try testing.expect(domain.close(successor) != null);
    }
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

// ---------------------------------------------------------------------------
// Phase S4 — the TLS domain primitives (`tls_state`, `attachTls`,
// `upgradeToTls`, `close`-returns-the-session, `beginHandoff` preserves the
// session). The session pointer is an OPAQUE sentinel here — the pure table
// never dereferences it (the bridge's `*TlsSession` cast is exercised by the
// abi/socket_io suites), so these tests use throwaway `*anyopaque` markers.
// ---------------------------------------------------------------------------

/// A distinct non-null opaque marker standing in for a `*TlsSession` (the table
/// stores/returns it verbatim, never dereferences it).
fn fakeTlsState(tag: usize) *anyopaque {
    return @ptrFromInt(0x1000 + tag);
}

test "SocketDomain.attachTls: binds a session + flips kind to tls_session WITHOUT bumping the generation (fresh-connect path)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(7, 0xAB, 0, .plain);
    try testing.expectEqual(@as(?SocketKind, .plain), domain.kind(handle));
    try testing.expectEqual(@as(?*anyopaque, null), domain.tlsState(handle));

    const session = fakeTlsState(1);
    try testing.expect(domain.attachTls(handle, 0xAB, session));

    // SAME handle still names the socket — now TLS, with the session bound.
    try testing.expect(domain.isLive(handle));
    try testing.expectEqual(@as(?SocketKind, .tls_session), domain.kind(handle));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(handle));

    // A wrong-owner attach is refused (defense in depth); the slot is untouched.
    try testing.expect(!domain.attachTls(handle, 0x99, fakeTlsState(2)));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(handle));

    // close hands the session back ALONGSIDE the fd (the no-leak seam).
    const closed = domain.close(handle) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(Fd, 7), closed.fd);
    try testing.expectEqual(@as(?*anyopaque, session), closed.tls_state);
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.attachTls: a stale/forged handle is refused (no bind)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(7, 0, 0, .plain);
    _ = domain.close(handle); // now stale
    try testing.expect(!domain.attachTls(handle, 0, fakeTlsState(1)));

    const forged = SocketHandle{ .slot = 4242, .generation = 5 };
    try testing.expect(!domain.attachTls(forged, 0, fakeTlsState(2)));
}

test "SocketDomain.upgradeToTls: gen-bump consumes the plaintext handle; use-after-upgrade is stale (STARTTLS)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const plaintext = try domain.open(9, 0xCD, 4444, .plain);
    const session = fakeTlsState(3);

    const upgraded = domain.upgradeToTls(plaintext, 0xCD, session) orelse
        return error.TestUnexpectedResult;

    // Same slot/fd, generation bumped: the OLD plaintext handle is stale
    // everywhere (no accidental plaintext I/O over the now-encrypted socket).
    try testing.expectEqual(plaintext.slot, upgraded.slot);
    try testing.expectEqual(plaintext.generation + 1, upgraded.generation);
    try testing.expect(!domain.isLive(plaintext));
    try testing.expectEqual(@as(?Fd, null), domain.fd(plaintext));
    try testing.expectEqual(@as(?*anyopaque, null), domain.tlsState(plaintext));

    // The successor is a live TLS socket on the same fd, owned by the same pid.
    try testing.expect(domain.isLive(upgraded));
    try testing.expectEqual(@as(?Fd, 9), domain.fd(upgraded));
    try testing.expectEqual(@as(?u64, 0xCD), domain.owner(upgraded));
    try testing.expectEqual(@as(?SocketKind, .tls_session), domain.kind(upgraded));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(upgraded));
    // Live-count CONSERVED — the upgrade opens/closes no fd.
    try testing.expectEqual(@as(u32, 1), domain.statistics().live_socket_count);

    const closed = domain.close(upgraded) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(Fd, 9), closed.fd);
    try testing.expectEqual(@as(?*anyopaque, session), closed.tls_state);
}

test "SocketDomain.upgradeToTls: wrong owner / stale handle is refused, slot untouched" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(9, 0xCD, 0, .plain);
    // Wrong owner: refused, slot untouched (still a live plaintext socket).
    try testing.expectEqual(@as(?SocketHandle, null), domain.upgradeToTls(handle, 0x99, fakeTlsState(1)));
    try testing.expect(domain.isLive(handle));
    try testing.expectEqual(@as(?SocketKind, .plain), domain.kind(handle));
    try testing.expectEqual(@as(?*anyopaque, null), domain.tlsState(handle));

    _ = domain.close(handle); // now stale
    try testing.expectEqual(@as(?SocketHandle, null), domain.upgradeToTls(handle, 0xCD, fakeTlsState(2)));
}

test "SocketDomain.upgradeToTls: the generation-exhaustion retire edge re-homes the fd as TLS, live-count conserved" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(42, 0xAAAA, 1234, .plain);
    const edge_slot = domain.slotPointerUnchecked(handle.slot);
    edge_slot.state.store(@bitCast(SlotState{
        .generation = retired_generation - 1,
        .occupancy = .occupied,
    }), .release);
    const edge_handle = SocketHandle{ .slot = handle.slot, .generation = retired_generation - 1 };

    const live_before = domain.statistics().live_socket_count;
    const peak_before = domain.statistics().live_socket_peak;
    const retired_before = domain.statistics().retired_slot_count;

    const session = fakeTlsState(7);
    const successor = domain.upgradeToTls(edge_handle, 0xAAAA, session) orelse
        return error.TestUnexpectedResult;

    // The fd re-homed on a DIFFERENT slot, now a TLS socket owned by the SAME
    // pid (not a handoff), the session bound, the exhausted slot retired.
    try testing.expect(successor.slot != handle.slot);
    try testing.expectEqual(@as(?Fd, 42), domain.fd(successor));
    try testing.expectEqual(@as(?u64, 0xAAAA), domain.owner(successor));
    try testing.expectEqual(@as(?SocketKind, .tls_session), domain.kind(successor));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(successor));
    try testing.expectEqual(@as(?u16, 1234), domain.localPort(successor));
    // Live-count + peak CONSERVED; one slot retired; old edge handle stale.
    try testing.expectEqual(live_before, domain.statistics().live_socket_count);
    try testing.expectEqual(peak_before, domain.statistics().live_socket_peak);
    try testing.expectEqual(retired_before + 1, domain.statistics().retired_slot_count);
    try testing.expect(!domain.isLive(edge_handle));

    try expectClosedFd(42, domain.close(successor));
    try testing.expectEqual(@as(u32, 0), domain.statistics().live_socket_count);
}

test "SocketDomain.beginHandoff: a moved TLS socket CARRIES its session to the successor (in-place bump)" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(11, 0xA, 0, .plain);
    const session = fakeTlsState(5);
    try testing.expect(domain.attachTls(handle, 0xA, session));

    const successor = domain.beginHandoff(handle, 0xA, 0xB) orelse
        return error.TestUnexpectedResult;

    // The successor carries the SAME session across the move (kind + tls_state
    // preserved); the sender's old handle is stale everywhere.
    try testing.expect(!domain.isLive(handle));
    try testing.expectEqual(@as(?SocketKind, .tls_session), domain.kind(successor));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(successor));

    try testing.expect(domain.completeHandoff(successor, 0xB));
    const closed = domain.close(successor) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(Fd, 11), closed.fd);
    try testing.expectEqual(@as(?*anyopaque, session), closed.tls_state);
}

test "SocketDomain.beginHandoff: the retire edge preserves the TLS session on the re-homed slot" {
    var domain = SocketDomain.init();
    defer domain.deinit();

    const handle = try domain.open(11, 0xAAAA, 0, .plain);
    const session = fakeTlsState(6);
    try testing.expect(domain.attachTls(handle, 0xAAAA, session));

    // Advance the slot to the retire edge, then move it: the re-home must carry
    // the session onto the fresh slot.
    const edge_slot = domain.slotPointerUnchecked(handle.slot);
    edge_slot.state.store(@bitCast(SlotState{
        .generation = retired_generation - 1,
        .occupancy = .occupied,
    }), .release);
    const edge_handle = SocketHandle{ .slot = handle.slot, .generation = retired_generation - 1 };

    const successor = domain.beginHandoff(edge_handle, 0xAAAA, 0xBBBB) orelse
        return error.TestUnexpectedResult;
    try testing.expect(successor.slot != handle.slot);
    try testing.expectEqual(@as(?SocketKind, .tls_session), domain.kind(successor));
    try testing.expectEqual(@as(?*anyopaque, session), domain.tlsState(successor));

    try testing.expect(domain.completeHandoff(successor, 0xBBBB));
    const closed = domain.close(successor) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?*anyopaque, session), closed.tls_state);
}
