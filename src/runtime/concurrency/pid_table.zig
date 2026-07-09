//! Generational pid table for the Zap concurrency kernel.
//!
//! Phase 1 item 1.2 of `docs/concurrency-implementation-plan.md` (job
//! P1-J2): the process-identity structure from the plan §3 process
//! definition — *a pid table slot `{slot, generation, model bits, node
//! bits}`* — with OTP-28-style scalable live-process iteration from day
//! one. Locked design decision 4 (`zap-concurrency-research.md` §6) and
//! the sharpened §2.4 pid invariant govern the design:
//!
//! > Model bits are a function of {slot, generation} and are immutable
//! > for the life of that generation. Slot reuse bumps the generation; a
//! > sender must read model bits and generation *together*, and must
//! > dead-letter on generation mismatch rather than emit cells in a
//! > stale layout.
//!
//! `lookup` therefore validates generation and model as ONE atomic unit —
//! they live in a single per-slot metadata word read with one atomic load
//! — and routes every mismatch through the table's dead-letter hook.
//! Phase 1 stores the manifest manager's model at `acquire`; Phase 3 item
//! 3.3 makes the model bits live for per-reachable-pair copy stubs. The
//! structure and the invariant are built now so Phase 3 changes no
//! layout. Precedent (research.md §6.7): BEAM's node+number+serial+
//! creation pids, ECS generational handles with type bits, Vale
//! generational references.
//!
//! ## Pid bit layout (64 bits)
//!
//! ```
//!   bit 63       56 55  54 53                           24 23          0
//!   +---------------+------+-------------------------------+------------+
//!   | node id (8)   | model| generation (30)               | slot (24)  |
//!   +---------------+------+-------------------------------+------------+
//! ```
//!
//! Width rationale (the authoritative constants are `pid_bit_layout`):
//!
//! * **slot: 24 bits** — 16,777,215 concurrent processes (the all-ones
//!   index is reserved as the free-list sentinel, `max_table_capacity`):
//!   64× BEAM's default process table (`+P` 262,144) and comfortably
//!   "millions", while keeping absolute-maximum table memory bounded
//!   (24 bytes/slot → 384 MiB at the 2^24 ceiling; 6 MiB at the
//!   BEAM-default capacity). The slot field occupies the LOW bits so slot
//!   extraction on the send hot path is a single mask, no shift.
//! * **generation: 30 bits** — 1,073,741,822 usable generations per slot
//!   (generation 0 is reserved never-live, see `Pid.invalid`). ABA safety
//!   does NOT rest on this width being "big enough": a slot whose
//!   generation reaches `max_generation` is RETIRED (never returned to
//!   the free list), so a `{slot, generation}` pair is never reissued and
//!   a stale pid can never alias a newer process — reuse ABA is
//!   structurally impossible, not merely improbable. The width instead
//!   bounds how much spawn traffic one slot absorbs before retiring: a
//!   pathological spawn/exit loop hammering a single LIFO-reused slot at
//!   1M processes/second retires that one slot after ~18 minutes, and
//!   exhausting the whole table that way needs 2^54 spawns (≈ 570 years
//!   at 1M spawns/second sustained).
//! * **model: 2 bits** — exactly the four-model reclamation roster
//!   (`zap-concurrency-research.md` §2.3/§2.5; "≤4 models" is locked
//!   design decision 2), see `ReclamationModel`.
//! * **node: 8 bits** — 255 remote nodes + local (`node == 0`); reserved
//!   for distribution (research.md §6.10 — remote pids are just pids with
//!   nonzero node). 8 bits is the committed v1 layout: pid layouts must
//!   stay stable once messages carry pids, so this is not resized later.
//!
//! ## Concurrency posture (what is M:N-safe today, what is deferred)
//!
//! Phase 1 runs a single scheduler, but the table is built M:N-ready and
//! takes NO global lock anywhere — not on `lookup`, not on `acquire`:
//!
//! * **Free list** — a Treiber stack of slot indices whose head packs
//!   `{slot_index: u24, aba_tag: u40}` into one CAS-word; the tag
//!   increments on every successful push AND pop, so the classic Treiber
//!   pop ABA (head reused with a different next pointer) can only commit
//!   if the tag wraps a full 2^40 cycle inside one thread's load→CAS
//!   window — see `FreeListHead` for the earned-guarantee arithmetic.
//!   Safe for concurrent acquire/release today.
//! * **Per-slot metadata** — `{generation, model, state}` packed into one
//!   atomic u64. Publication ordering: `acquire` stores the PCB pointer
//!   (`.release`) BEFORE publishing the occupied metadata (`.release`);
//!   `release` bumps generation and frees the slot with a single
//!   validating CAS (`.release`). Readers use acquire loads. The
//!   release-CAS free-list push → acquire-load pop edge orders a slot's
//!   previous life strictly before its next life.
//! * **Lookup / iteration** — seqlock-flavored consistent reads: load
//!   metadata (acquire), load PCB pointer (acquire), re-load metadata
//!   (acquire); accept only if the two metadata observations are
//!   identical. Because generations are monotone per slot and the PCB
//!   pointer store of generation G+n happens-after the metadata store
//!   that ended generation G (via the free-list happens-before chain), an
//!   unchanged metadata word proves the pointer belongs to that exact
//!   generation. Retries only occur when the slot is concurrently
//!   released/reacquired mid-read, and each retry observes strictly newer
//!   metadata.
//! * **Borrowed-PCB lifetime (Phase 4 grace period):** the LIFETIME of
//!   the `*ProcessControlBlock` a lookup or iteration returns. Under a
//!   single scheduler the pointer is valid for the current scheduling
//!   quantum; under M:N schedulers a process can exit and its PCB drain,
//!   recycle, or reuse while another scheduler still holds the pointer.
//!   The `send` path closes this with a cross-scheduler grace period: it
//!   pins the target across the push and re-validates identity under the
//!   pin, and teardown waits every in-flight send out before draining
//!   (`scheduler.zig` `ProcessRecord.beginSend`/`endSend`/`closeAndQuiesce`;
//!   `mailbox.zig` "Teardown protocol"). The table's identity checks were
//!   always race-free; that discipline now covers the borrowed pointer's
//!   lifetime on the message path. Still deferred: a general borrowed-PCB
//!   reclamation for lookups OTHER than `send` (introspection snapshots
//!   read best-effort by contract), and per-slot cache-line padding
//!   against false sharing between
//!   adjacent slots (24-byte slots share lines ~2.6:1); a Phase 4
//!   measurement decides whether the memory trade is worth it.
//!
//! ## Capacity policy (fixed, by design)
//!
//! Capacity is fixed at `init` from `Config` and the table never grows.
//! This mirrors BEAM, whose process table is sized once at boot (`+P`)
//! and never resized — precedent that fixed capacity IS the production
//! design for this table, not a stopgap. The failure mode is explicit:
//! `acquire` returns `error.ProcessTableExhausted` and the spawn path
//! surfaces it. Segmented lock-free growth was considered and rejected:
//! it buys nothing BEAM needed in 25 years of production, and it puts an
//! extra indirection on the lookup hot path. If a growth story is ever
//! wanted, it is a Phase 4 (M:N scheduler) work item and must be
//! re-justified there; revisit alongside the Phase 4 padding measurement.
//!
//! ## Iteration semantics (plan item 1.2, OTP 28 precedent)
//!
//! `iterateLiveProcesses` is snapshot-free and lock-free: a monotone walk
//! of the slot array performing the same seqlock-consistent per-slot read
//! as `lookup`. Guarantees, under concurrent acquire/release:
//!
//! * every yielded `{pid, pcb}` pair was live at the moment its slot was
//!   visited, and the pair is internally consistent (the pcb is the one
//!   registered for exactly that pid's generation) — a released slot can
//!   never yield a stale PCB;
//! * processes that stay live for the whole iteration are yielded exactly
//!   once (slots are visited once and slot indices never move);
//! * processes spawned during iteration may or may not appear (their slot
//!   may lie before or after the cursor);
//! * processes released during iteration may or may not appear, but if
//!   yielded they were live at visit time (their pid resolves nowhere
//!   afterwards — holders hit the dead-letter path).
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so this
//! file has no special compiler requirement; see `concurrency.zig` for
//! the kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

const log = std.log.scoped(.zap_pid_table);

/// Reclamation model of the process a pid addresses — the pid-encoded
/// "model bits" of the §2.4 invariant. The FOUR models are the locked
/// roster of `zap-concurrency-research.md` §2.3/§2.5 (decision 2: the
/// specialization key is the reclamation model, ≤4 of them). The u2 tag
/// values are pid-encoding ABI: they are baked into every pid a program
/// ever observes, so they are explicit and MUST NOT be renumbered.
///
/// The compiler-side twin is `src/memory/elision.zig`'s
/// `ReclamationModel` (same four names, untagged — compiler-internal).
/// The kernel is a self-contained source tree (see `concurrency.zig`) and
/// cannot import compiler modules; Phase 3 item 3.3, which makes model
/// bits live, wires the compiler's model classification to these tag
/// values and must assert the name-for-name correspondence at that seam.
pub const ReclamationModel = enum(u2) {
    /// Reference-counted (ARC/ORC): retain/release, free-at-zero.
    /// Phase 1's manifest model.
    refcounted = 0,
    /// Bulk free at reset/exit (Arena) or never free (NoOp/Leak).
    bulk_or_never = 1,
    /// Individual free, no refcount (Tracking): static free-at-last-use.
    individual_no_refcount = 2,
    /// Tracing collection (GC manager): collector-driven reclamation.
    traced = 3,
};

/// The published pid bit-layout specification. Other components (copy
/// stubs, the compiler's send lowering, distribution) assert against
/// these constants rather than hardcoding widths; the `comptime` block
/// below proves they match the `Pid` type exactly. See the module doc
/// for the width rationale.
pub const pid_bit_layout = struct {
    /// Slot-index field width: 2^24 = 16,777,216 addressable slots.
    pub const slot_bits = 24;
    /// Generation field width: generations 1..`max_generation` per slot.
    pub const generation_bits = 30;
    /// Reclamation-model field width (the four-model roster).
    pub const model_bits = 2;
    /// Node-id field width (distribution reserve; 0 = local).
    pub const node_bits = 8;

    /// Bit position of the slot field (low bits: extraction is one mask).
    pub const slot_shift = 0;
    /// Bit position of the generation field.
    pub const generation_shift = slot_bits;
    /// Bit position of the model field.
    pub const model_shift = slot_bits + generation_bits;
    /// Bit position of the node field (top byte).
    pub const node_shift = slot_bits + generation_bits + model_bits;

    /// Size of the pid slot-index ADDRESS SPACE: slot indices must fit
    /// the 24-bit slot field. Not every index is usable as a table slot —
    /// see `max_table_capacity`.
    pub const max_slot_capacity = 1 << slot_bits;
    /// Maximum table capacity: one index of the 24-bit slot space (the
    /// all-ones `maxInt(u24)`) is reserved as the free-list "empty"
    /// sentinel (`free_list_sentinel`), so it can never name a real slot.
    /// Reserving an index keeps the free-list head packed as
    /// `{slot_index: u24, aba_tag: u40}` — the widest ABA tag the
    /// CAS word can carry (see `FreeListHead`).
    pub const max_table_capacity = max_slot_capacity - 1;
    /// First generation ever issued for any slot. Generation 0 is
    /// reserved never-live so the all-zero bit pattern (`Pid.invalid`)
    /// can never name a live process.
    pub const first_live_generation = 1;
    /// Last generation a slot may hold. A release at this generation
    /// RETIRES the slot instead of wrapping — see the module doc's ABA
    /// discussion.
    pub const max_generation = (1 << generation_bits) - 1;
    /// The node id of the local node. Nonzero nodes are remote
    /// (distribution, research.md §6.10) and never resolve locally.
    pub const local_node_id = 0;
};

/// Process identifier: a plain, trivially copyable 64-bit value (pids are
/// sendable non-heap values, research.md §6.7). See the module doc for
/// the layout diagram and width rationale, and `pid_bit_layout` for the
/// authoritative constants.
pub const Pid = packed struct(u64) {
    /// Index of the process's slot in the pid table.
    slot: u24,
    /// The slot generation this pid was issued for. A pid is live iff
    /// its slot currently holds exactly this generation (and model) in
    /// the occupied state.
    generation: u30,
    /// Reclamation model of the addressed process — immutable for this
    /// generation's lifetime (§2.4 invariant).
    model: ReclamationModel,
    /// Node id; `pid_bit_layout.local_node_id` (0) for every pid the
    /// Phase 1 kernel issues.
    node: u8,

    /// The canonical "no process" pid: all-zero bits. Its generation is
    /// 0, which `pid_bit_layout.first_live_generation` guarantees is
    /// never issued, so `invalid` can never collide with a live pid.
    pub const invalid: Pid = @bitCast(@as(u64, 0));

    /// The pid's raw 64-bit encoding (what ZIR lowering and the wire
    /// format carry).
    pub inline fn toBits(pid: Pid) u64 {
        return @bitCast(pid);
    }

    /// Reconstruct a pid from its raw 64-bit encoding. Performs no
    /// validation — resolve through `PidTable.lookup`.
    pub inline fn fromBits(bits: u64) Pid {
        return @bitCast(bits);
    }

    /// Whether the pid names a process on this node.
    pub inline fn isLocal(pid: Pid) bool {
        return pid.node == pid_bit_layout.local_node_id;
    }
};

comptime {
    // The published spec and the Pid type must agree exactly; widths sum
    // to one machine word.
    std.debug.assert(pid_bit_layout.slot_bits + pid_bit_layout.generation_bits +
        pid_bit_layout.model_bits + pid_bit_layout.node_bits == 64);
    std.debug.assert(@bitSizeOf(Pid) == 64);
    std.debug.assert(@sizeOf(Pid) == @sizeOf(u64));
    std.debug.assert(@bitOffsetOf(Pid, "slot") == pid_bit_layout.slot_shift);
    std.debug.assert(@bitOffsetOf(Pid, "generation") == pid_bit_layout.generation_shift);
    std.debug.assert(@bitOffsetOf(Pid, "model") == pid_bit_layout.model_shift);
    std.debug.assert(@bitOffsetOf(Pid, "node") == pid_bit_layout.node_shift);
    std.debug.assert(@bitSizeOf(ReclamationModel) == pid_bit_layout.model_bits);
    std.debug.assert(pid_bit_layout.max_generation == std.math.maxInt(u30));
    std.debug.assert(pid_bit_layout.max_slot_capacity - 1 == std.math.maxInt(u24));
    std.debug.assert(pid_bit_layout.first_live_generation >= 1);
    std.debug.assert(Pid.invalid.toBits() == 0);
    std.debug.assert(@bitSizeOf(SlotMetadata) == 64);

    // Free-list head layout: the slot-index field spans exactly the pid
    // slot space (low bits), and every remaining bit of the CAS word is
    // ABA tag — widening the tag any further would shrink the slot field.
    std.debug.assert(@bitSizeOf(FreeListHead) == 64);
    std.debug.assert(@bitOffsetOf(FreeListHead, "slot_index") == 0);
    std.debug.assert(@bitSizeOf(@FieldType(FreeListHead, "slot_index")) == pid_bit_layout.slot_bits);
    std.debug.assert(@bitSizeOf(@FieldType(FreeListHead, "aba_tag")) == 64 - pid_bit_layout.slot_bits);
    // The sentinel is the one reserved slot index: strictly above every
    // index a table may use, still representable in the packed field.
    std.debug.assert(free_list_sentinel == std.math.maxInt(u24));
    std.debug.assert(free_list_sentinel == pid_bit_layout.max_table_capacity);
    std.debug.assert(pid_bit_layout.max_table_capacity == pid_bit_layout.max_slot_capacity - 1);
}

/// Table-level lifecycle state of a slot (distinct from the PCB's
/// `ProcessState`, which is scheduler state).
const SlotState = enum(u2) {
    /// In the free list, available to `acquire`.
    free = 0,
    /// Holds a live process; the slot's PCB pointer is valid.
    occupied = 1,
    /// Generation space exhausted; permanently out of service (module
    /// doc: retirement is what makes reuse ABA impossible).
    retired = 2,
};

/// Per-slot metadata, packed so generation + model + state are read and
/// written as ONE atomic unit — the §2.4 "read model bits and generation
/// together" requirement is met structurally, not by convention. The
/// `model` field is meaningful only while `state == .occupied` (it is
/// (re)written by every acquire and retained-but-dead otherwise).
const SlotMetadata = packed struct(u64) {
    generation: u30,
    model: ReclamationModel,
    state: SlotState,
    reserved: u30 = 0,
};

/// One pid-table slot. 24 bytes; adjacent slots share cache lines — the
/// module doc records the deliberate no-padding decision (Phase 4
/// revisit).
const Slot = struct {
    /// Packed `{generation, model, state}` — see `SlotMetadata`.
    metadata: std.atomic.Value(u64),
    /// The registered process; non-null iff metadata says `.occupied`
    /// (published before, and proven consistent with, the metadata word —
    /// see the module doc's seqlock discussion).
    pcb: std.atomic.Value(?*process.ProcessControlBlock),
    /// Next slot index in the free list; meaningful only while the slot
    /// is inside the free list. Written before the push CAS (which
    /// publishes it with `.release`). Values are always in the u24 slot
    /// space (or `free_list_sentinel`); the field is u32 only because
    /// u24 is not an atomic operand size.
    next_free: std.atomic.Value(u32),
};

/// Free-list head: a Treiber-stack top packed with an ABA tag that
/// increments on every successful push and pop.
///
/// The tag is the EARNED guarantee, not an absolute one: a head CAS
/// commits against a stale `next_free` observation only if the tag wraps
/// a full cycle — exactly 2^40 successful push/pop operations — between
/// one thread's head load and its CAS. 2^40 = 1,099,511,627,776 ≈
/// 1.1 × 10^12 operations; even at a pathological 10^9 free-list
/// operations per second sustained by other threads, the stalled
/// thread's load→CAS window would have to span ~18 minutes (2^40 / 10^9
/// ≈ 1,100 s) for the wrap to line up, versus ~4.3 s for the u32 tag
/// this replaced (2^32 ≈ 4.3 × 10^9). This hardening is probabilistic;
/// the STRUCTURAL pid-identity guarantee (a `{slot, generation}` pair is
/// never reissued) rests on generation retirement, not on this tag —
/// see the module doc's generation-width rationale.
///
/// The slot-index field is u24 (the pid slot space, giving the tag every
/// remaining bit of the CAS word), which is why one 24-bit index —
/// `free_list_sentinel` — is reserved and `max_table_capacity` is one
/// below the 2^24 address space.
const FreeListHead = packed struct(u64) {
    slot_index: u24,
    aba_tag: u40,
};

/// "Empty free list" marker for `FreeListHead.slot_index` and the
/// per-slot `next_free` links (which store u24-range values widened to
/// u32 — u24 is not an atomic operand size). Reserved: no table slot
/// ever carries this index (`pid_bit_layout.max_table_capacity`).
const free_list_sentinel: u24 = std.math.maxInt(u24);

/// Why a pid failed to resolve. Passed to the dead-letter hook so the
/// message system (P1-J3+) can distinguish stale senders from forged or
/// misrouted pids.
pub const DeadLetterReason = enum {
    /// The pid's node id is not the local node — distribution is not
    /// implemented (plan: design-for only).
    remote_node,
    /// The pid's slot index is outside this table's capacity (forged or
    /// misconfigured pid — a table never shrinks, so an issued pid's
    /// slot is always in range).
    slot_out_of_range,
    /// The slot's current generation is not the pid's — THE stale-sender
    /// case of the §2.4 invariant: the process exited (slot free with a
    /// bumped generation) or the slot was already reused (occupied by a
    /// successor generation). Checked FIRST among the slot-state reasons
    /// so stale senders always see this reason regardless of what the
    /// slot is doing now.
    generation_mismatch,
    /// The generation matches but the slot is not occupied: either a
    /// forged pid carrying a generation the slot has not issued yet
    /// (free slot), or the stale pid of a retired slot's final
    /// generation (retired slots keep their last generation forever).
    slot_not_occupied,
    /// Generation matched an occupied slot but model bits did not. The
    /// §2.4 invariant (model is a function of {slot, generation}) makes
    /// this impossible for table-issued pids — seeing it means a
    /// forged/corrupted pid, so it is surfaced as its own reason rather
    /// than folded into `generation_mismatch`.
    model_mismatch,
};

/// Dead-letter callback. `context` is `PidTable.dead_letter_context`.
/// Phase 1 default: `defaultDeadLetterHook` (debug log; the table's
/// `dead_letter_count` is incremented unconditionally BEFORE the hook so
/// a custom hook cannot break the observability counter). The message
/// system replaces this in P1-J3+ to route the undeliverable payload.
pub const DeadLetterHook = *const fn (
    context: ?*anyopaque,
    stale_pid: Pid,
    reason: DeadLetterReason,
) void;

/// Table sizing configuration. Kernel-internal for Phase 1; wired to the
/// program manifest when the language surface lands (Phase 2).
pub const Config = struct {
    /// Number of slots (= maximum concurrent processes). Must be in
    /// `[1, pid_bit_layout.max_table_capacity]` (one 24-bit index is
    /// reserved as the free-list sentinel — see `pid_bit_layout`).
    capacity: u32 = default_capacity,
};

/// Default table capacity: 262,144, matching BEAM's default process
/// limit (`+P`), the 25-year production precedent for this table shape.
/// 24 bytes/slot → 6 MiB, allocated eagerly at `init` (BEAM allocates
/// its process table at boot the same way); non-spawning binaries never
/// initialize the kernel, so the zero-cost gate is unaffected.
pub const default_capacity: u32 = 262_144;

/// One live process as yielded by `LiveProcessIterator`: the pid and the
/// PCB registered for exactly that pid's generation.
pub const LiveProcess = struct {
    /// The process's pid, reconstructed from the slot's current
    /// (visit-time) generation and model.
    pid: Pid,
    /// The registered PCB. Borrowed — see the module doc's Phase 4
    /// lifetime caveat.
    pcb: *process.ProcessControlBlock,
};

/// Snapshot-free, lock-free live-process iterator — see the module doc's
/// "Iteration semantics" for the exact guarantees under concurrent
/// acquire/release. Obtain via `PidTable.iterateLiveProcesses`.
pub const LiveProcessIterator = struct {
    /// The table being walked.
    table: *PidTable,
    /// Next slot index to visit.
    next_slot_index: u32 = 0,

    /// Yield the next live process, or null when the walk is complete.
    pub fn next(iterator: *LiveProcessIterator) ?LiveProcess {
        const table = iterator.table;
        while (iterator.next_slot_index < table.slots.len) {
            const slot_index = iterator.next_slot_index;
            iterator.next_slot_index += 1;

            const observation = readSlotConsistent(&table.slots[slot_index]);
            if (observation.metadata.state != .occupied) continue;

            return .{
                .pid = .{
                    .slot = @intCast(slot_index),
                    .generation = observation.metadata.generation,
                    .model = observation.metadata.model,
                    .node = pid_bit_layout.local_node_id,
                },
                // Non-null exactly when the consistent read observed
                // `.occupied` — see `readSlotConsistent`.
                .pcb = observation.pcb.?,
            };
        }
        return null;
    }
};

/// Aggregate observability counters (plan Phase 1 item 1.6 skeleton).
/// The counters are monotonic atomics maintained alongside slot
/// transitions; under concurrent mutation they are advisory (momentarily
/// out of sync with a racing slot write), never load-bearing.
pub const Statistics = struct {
    /// Fixed slot count of this table.
    capacity: u32,
    /// Processes currently registered (acquired minus released/retired).
    live_process_count: u32,
    /// Total failed lookups routed to the dead-letter path.
    dead_letter_count: u64,
    /// Slots permanently retired by generation exhaustion.
    retired_slot_count: u32,
};

/// The generational pid table: slot storage + lock-free free list +
/// dead-letter hook + observability counters. See the module doc for the
/// design; all public operations are safe for concurrent use (with the
/// documented Phase 4 pointer-lifetime caveat on `lookup`/iteration
/// results).
pub const PidTable = struct {
    /// Slot storage, `config.capacity` entries, allocated at `init`.
    slots: []Slot,
    /// Treiber free-list head (`FreeListHead` bits).
    free_list_head: std.atomic.Value(u64),
    /// Called on every failed lookup, after `dead_letter_count` is
    /// incremented. Replaceable; single-store publication — install
    /// before sharing the table across threads.
    dead_letter_hook: DeadLetterHook,
    /// Opaque context handed to `dead_letter_hook`.
    dead_letter_context: ?*anyopaque,
    /// Whether `release` emits a `warn` when a slot is permanently retired
    /// on generation exhaustion. Default true: retirement is a real,
    /// once-in-~570-years operational event (module doc "Capacity policy")
    /// worth surfacing in production. The white-box retirement test forces
    /// exhaustion on purpose and opts OUT, so its intentional trigger does
    /// not write to the test process's stderr — which the Zig build runner
    /// captures under `--listen=-` and surfaces as `failed command:` noise
    /// on an otherwise-green step (same seam rationale as the deterministic
    /// harness's `suppress_failure_seed_print`).
    warn_on_slot_retirement: bool = true,
    /// See `Statistics.dead_letter_count`.
    dead_letter_count: std.atomic.Value(u64),
    /// See `Statistics.live_process_count`.
    live_process_count: std.atomic.Value(u32),
    /// See `Statistics.retired_slot_count`.
    retired_slot_count: std.atomic.Value(u32),
    /// Allocator that owns `slots`.
    allocator: std.mem.Allocator,

    /// Errors from `init`.
    pub const InitError = error{
        /// `Config.capacity` is 0 or exceeds
        /// `pid_bit_layout.max_table_capacity`.
        InvalidCapacity,
        /// Slot-storage allocation failed.
        OutOfMemory,
    };

    /// Errors from `acquire`.
    pub const AcquireError = error{
        /// Every slot is occupied or retired — the documented fixed-
        /// capacity failure mode (module doc "Capacity policy").
        ProcessTableExhausted,
    };

    /// Allocate and wire a table of `config.capacity` slots: every slot
    /// starts free at `first_live_generation` and the free list is
    /// threaded in ascending slot order (so single-threaded acquisition
    /// is deterministic: slot 0 first).
    pub fn init(allocator: std.mem.Allocator, config: Config) InitError!PidTable {
        if (config.capacity == 0 or config.capacity > pid_bit_layout.max_table_capacity) {
            return error.InvalidCapacity;
        }

        const slots = try allocator.alloc(Slot, config.capacity);
        for (slots, 0..) |*slot, slot_index| {
            const next_free_index: u32 =
                if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else free_list_sentinel;
            slot.* = .{
                .metadata = .init(@bitCast(SlotMetadata{
                    .generation = pid_bit_layout.first_live_generation,
                    .model = .refcounted, // meaningless while free; stamped by acquire
                    .state = .free,
                })),
                .pcb = .init(null),
                .next_free = .init(next_free_index),
            };
        }

        return .{
            .slots = slots,
            .free_list_head = .init(@bitCast(FreeListHead{ .slot_index = 0, .aba_tag = 0 })),
            .dead_letter_hook = defaultDeadLetterHook,
            .dead_letter_context = null,
            .dead_letter_count = .init(0),
            .live_process_count = .init(0),
            .retired_slot_count = .init(0),
            .allocator = allocator,
        };
    }

    /// Release the slot storage. The caller guarantees no concurrent
    /// use and no outstanding borrowed PCB pointers.
    pub fn deinit(table: *PidTable) void {
        table.allocator.free(table.slots);
        table.* = undefined;
    }

    /// Register a process: pop a free slot (lock-free free list — never
    /// a scan), record the PCB pointer, stamp the slot's current
    /// generation with `model` (the §2.4 model-bits-written-at-acquire
    /// point), and return the encoded pid (always local-node). The
    /// returned pid is the process's identity until `release`.
    pub fn acquire(
        table: *PidTable,
        pcb: *process.ProcessControlBlock,
        model: ReclamationModel,
    ) AcquireError!Pid {
        const slot_index = table.popFreeSlot() orelse return error.ProcessTableExhausted;
        const slot = &table.slots[slot_index];

        // The free-list pop granted exclusive ownership of this slot, so
        // the metadata read cannot race a writer (`.monotonic` suffices;
        // the pop CAS's acquire ordering made the releasing store
        // visible). A popped slot that is not `.free` means the free
        // list and the slot metadata disagree — free-list corruption —
        // and must fail loudly in every build mode (the same posture as
        // `release`'s validating-CAS panic) rather than resurrect a
        // live or retired slot.
        const current: SlotMetadata = @bitCast(slot.metadata.load(.monotonic));
        if (current.state != .free) {
            @branchHint(.cold);
            @panic("PidTable.acquire: popped slot is not free (free-list corruption) — kernel bug");
        }

        // Publication order (module doc "Concurrency posture"): PCB
        // pointer first with `.release` (so a seqlock reader that
        // observes this pointer also observes everything before it —
        // including the metadata store that ended the slot's previous
        // generation), then the occupied metadata with `.release` (so a
        // reader that observes `.occupied` also observes the pointer).
        slot.pcb.store(pcb, .release);
        slot.metadata.store(@bitCast(SlotMetadata{
            .generation = current.generation,
            .model = model,
            .state = .occupied,
        }), .release);

        _ = table.live_process_count.fetchAdd(1, .monotonic);
        return .{
            .slot = @intCast(slot_index),
            .generation = current.generation,
            .model = model,
            .node = pid_bit_layout.local_node_id,
        };
    }

    /// Unregister a process: atomically bump the slot's generation —
    /// which invalidates ALL outstanding pids for the slot in one store —
    /// and return the slot to the free list (or retire it at generation
    /// exhaustion). `pid` must be the slot's current live pid; anything
    /// else (double release, stale or forged pid) is a kernel bug and
    /// panics in every build mode, matching `transitionTo`'s discipline.
    pub fn release(table: *PidTable, pid: Pid) void {
        if (!pid.isLocal() or pid.slot >= table.slots.len) {
            @branchHint(.cold);
            @panic("PidTable.release: pid does not belong to this table — kernel bug");
        }
        const slot = &table.slots[pid.slot];

        const expected = SlotMetadata{
            .generation = pid.generation,
            .model = pid.model,
            .state = .occupied,
        };
        const retiring = pid.generation == pid_bit_layout.max_generation;
        const successor = if (retiring)
            // Generation space exhausted: park the slot permanently so
            // the {slot, generation} space is never reissued (module
            // doc: this is what makes reuse ABA impossible).
            SlotMetadata{ .generation = pid.generation, .model = pid.model, .state = .retired }
        else
            // One store both bumps the generation — atomically killing
            // EVERY outstanding pid of the old generation — and marks
            // the slot free.
            SlotMetadata{ .generation = pid.generation + 1, .model = pid.model, .state = .free };

        // The CAS is simultaneously the release validation (only the
        // slot's current live pid matches) and the publication point;
        // `.release` orders the process's final PCB writes before any
        // future acquire of this slot observes it free.
        if (slot.metadata.cmpxchgStrong(@bitCast(expected), @bitCast(successor), .release, .monotonic)) |_| {
            @branchHint(.cold);
            @panic("PidTable.release: pid does not own its slot (double release or stale/forged pid) — kernel bug");
        }

        _ = table.live_process_count.fetchSub(1, .monotonic);
        if (retiring) {
            _ = table.retired_slot_count.fetchAdd(1, .monotonic);
            if (table.warn_on_slot_retirement) {
                log.warn("pid-table slot {d} retired after generation exhaustion", .{pid.slot});
            }
            return;
        }
        table.pushFreeSlot(pid.slot);
    }

    /// Resolve a pid to its live PCB, validating node, slot range, and —
    /// as one atomic unit — occupancy, generation, AND model bits (§2.4).
    /// Any mismatch increments `dead_letter_count`, invokes the
    /// dead-letter hook with the precise `DeadLetterReason`, and returns
    /// null; stale senders hit `generation_mismatch` and can never
    /// observe a mis-typed layout. The returned pointer is borrowed —
    /// module-doc Phase 4 lifetime caveat.
    pub fn lookup(table: *PidTable, pid: Pid) ?*process.ProcessControlBlock {
        if (!pid.isLocal()) return table.deadLetter(pid, .remote_node);
        if (pid.slot >= table.slots.len) return table.deadLetter(pid, .slot_out_of_range);

        const observation = readSlotConsistent(&table.slots[pid.slot]);
        // Occupancy, generation, and model come from ONE atomic metadata
        // word (§2.4: generation and model bits are read together, never
        // separately), classified in precedence order: generation first,
        // so a stale sender always sees `generation_mismatch` (see
        // `DeadLetterReason`).
        if (observation.metadata.generation != pid.generation) {
            return table.deadLetter(pid, .generation_mismatch);
        }
        if (observation.metadata.state != .occupied) return table.deadLetter(pid, .slot_not_occupied);
        if (observation.metadata.model != pid.model) return table.deadLetter(pid, .model_mismatch);
        return observation.pcb.?;
    }

    /// Silent aliveness probe: the same validation as `lookup` without
    /// the dead-letter accounting, hook, or log — for control-flow
    /// checks where a dead pid is the EXPECTED terminal condition
    /// rather than a mis-addressed message (the scheduler's
    /// root-process join polls this every loop iteration after the
    /// root exits).
    pub fn isAlive(table: *PidTable, pid: Pid) bool {
        if (!pid.isLocal()) return false;
        if (pid.slot >= table.slots.len) return false;
        const observation = readSlotConsistent(&table.slots[pid.slot]);
        if (observation.metadata.generation != pid.generation) return false;
        if (observation.metadata.state != .occupied) return false;
        if (observation.metadata.model != pid.model) return false;
        return true;
    }

    /// Begin a snapshot-free live-process walk (module doc "Iteration
    /// semantics"; plan item 1.2 / OTP 28 precedent).
    pub fn iterateLiveProcesses(table: *PidTable) LiveProcessIterator {
        return .{ .table = table };
    }

    /// Read the observability counters (advisory under concurrency —
    /// see `Statistics`).
    pub fn statistics(table: *const PidTable) Statistics {
        return .{
            .capacity = @intCast(table.slots.len),
            .live_process_count = table.live_process_count.load(.monotonic),
            .dead_letter_count = table.dead_letter_count.load(.monotonic),
            .retired_slot_count = table.retired_slot_count.load(.monotonic),
        };
    }

    /// Pop a slot index off the Treiber free list, or null when empty.
    /// Lock-free: the head CAS carries the u40 ABA tag bumped on every
    /// successful push/pop, so a stale `next_free` observation commits
    /// only across an exact 2^40-operation tag wrap inside this thread's
    /// load→CAS window (`FreeListHead` states the arithmetic). The head
    /// load and CAS-failure reload use `.acquire` to pair with the push
    /// CAS's `.release`, which is what publishes both the popped slot's
    /// `next_free` and its released metadata to this thread.
    fn popFreeSlot(table: *PidTable) ?u32 {
        var observed_head = table.free_list_head.load(.acquire);
        while (true) {
            const head: FreeListHead = @bitCast(observed_head);
            if (head.slot_index == free_list_sentinel) return null;

            // Safe even though this thread does not own the slot yet: if
            // another thread pops/pushes it concurrently, the head tag
            // moves and the CAS below fails. `next_free` only ever holds
            // u24-range values (slot indices or the sentinel), so the
            // narrowing is lossless.
            const next_index: u24 = @intCast(table.slots[head.slot_index].next_free.load(.monotonic));
            const successor = FreeListHead{
                .slot_index = next_index,
                .aba_tag = head.aba_tag +% 1,
            };
            observed_head = table.free_list_head.cmpxchgWeak(
                observed_head,
                @bitCast(successor),
                .acq_rel,
                .acquire,
            ) orelse return head.slot_index;
        }
    }

    /// Push a free slot index onto the Treiber free list. The successful
    /// CAS's `.release` publishes both the slot's `next_free` link and —
    /// via the caller's preceding metadata store — the slot's freed
    /// state to the next popper (see `popFreeSlot`).
    fn pushFreeSlot(table: *PidTable, slot_index: u24) void {
        var observed_head = table.free_list_head.load(.monotonic);
        while (true) {
            const head: FreeListHead = @bitCast(observed_head);
            table.slots[slot_index].next_free.store(head.slot_index, .monotonic);
            const successor = FreeListHead{
                .slot_index = slot_index,
                .aba_tag = head.aba_tag +% 1,
            };
            observed_head = table.free_list_head.cmpxchgWeak(
                observed_head,
                @bitCast(successor),
                .release,
                .monotonic,
            ) orelse return;
        }
    }

    /// Route a failed lookup to the dead-letter path: bump the
    /// unconditional observability counter, invoke the hook, resolve to
    /// "no process". Returns null so lookup call sites read as a single
    /// expression.
    fn deadLetter(
        table: *PidTable,
        stale_pid: Pid,
        reason: DeadLetterReason,
    ) ?*process.ProcessControlBlock {
        _ = table.dead_letter_count.fetchAdd(1, .monotonic);
        table.dead_letter_hook(table.dead_letter_context, stale_pid, reason);
        return null;
    }
};

/// One internally consistent observation of a slot: the metadata word
/// plus, iff it says `.occupied`, the PCB pointer registered for exactly
/// that metadata's generation.
const ConsistentSlotRead = struct {
    metadata: SlotMetadata,
    pcb: ?*process.ProcessControlBlock,
};

/// Seqlock-flavored consistent slot read (module doc "Concurrency
/// posture"): metadata (acquire) → PCB pointer (acquire) → metadata
/// again (acquire); accept only if the two metadata observations are
/// bit-identical. Correctness: generations are monotone per slot, and
/// the PCB store for generation G+n happens-after the metadata store
/// that ended generation G (release-CAS → free-list push `.release` →
/// pop `.acquire` → acquire's stores), while the pcb load's `.acquire`
/// pins the second metadata load after it — so an unchanged metadata
/// word proves the pointer belongs to that exact generation. Each retry
/// observes strictly newer metadata; a retry only happens when the slot
/// is concurrently released/reacquired mid-read.
fn readSlotConsistent(slot: *Slot) ConsistentSlotRead {
    var observed_before = slot.metadata.load(.acquire);
    while (true) {
        const metadata: SlotMetadata = @bitCast(observed_before);
        if (metadata.state != .occupied) return .{ .metadata = metadata, .pcb = null };

        const pcb = slot.pcb.load(.acquire);
        const observed_after = slot.metadata.load(.acquire);
        if (observed_before == observed_after) return .{ .metadata = metadata, .pcb = pcb.? };
        observed_before = observed_after;
    }
}

/// Phase 1 default dead-letter hook: debug log only (the
/// `dead_letter_count` counter is maintained unconditionally by the
/// table BEFORE the hook runs, so replacing the hook never breaks
/// observability). The message system replaces this in P1-J3+.
fn defaultDeadLetterHook(context: ?*anyopaque, stale_pid: Pid, reason: DeadLetterReason) void {
    _ = context;
    log.debug("dead-letter: pid 0x{x} (slot={d} generation={d} model={t} node={d}) reason={t}", .{
        stale_pid.toBits(),
        stale_pid.slot,
        stale_pid.generation,
        stale_pid.model,
        stale_pid.node,
        reason,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Pid: bit layout matches the published spec and round-trips through u64" {
    const pid = Pid{
        .slot = 0x42,
        .generation = 7,
        .model = .traced,
        .node = 5,
    };

    // Against the published layout spec…
    const expected_bits: u64 =
        (@as(u64, 5) << pid_bit_layout.node_shift) |
        (@as(u64, @intFromEnum(ReclamationModel.traced)) << pid_bit_layout.model_shift) |
        (@as(u64, 7) << pid_bit_layout.generation_shift) |
        (@as(u64, 0x42) << pid_bit_layout.slot_shift);
    try testing.expectEqual(expected_bits, pid.toBits());

    // …and against the hard literal, so spec constants cannot drift
    // silently alongside the type.
    try testing.expectEqual(@as(u64, 0x05C0_0000_0700_0042), pid.toBits());

    const round_tripped = Pid.fromBits(pid.toBits());
    try testing.expectEqual(@as(u24, 0x42), round_tripped.slot);
    try testing.expectEqual(@as(u30, 7), round_tripped.generation);
    try testing.expectEqual(ReclamationModel.traced, round_tripped.model);
    try testing.expectEqual(@as(u8, 5), round_tripped.node);
    try testing.expect(!round_tripped.isLocal());
}

test "Pid: invalid pid is the all-zero bit pattern and generation zero is never issued" {
    try testing.expectEqual(@as(u64, 0), Pid.invalid.toBits());
    try testing.expect(Pid.invalid.isLocal());

    var table = try PidTable.init(testing.allocator, .{ .capacity = 1 });
    defer table.deinit();

    // Looking up the invalid pid never resolves; it dead-letters.
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(.invalid));
    try testing.expectEqual(@as(u64, 1), table.statistics().dead_letter_count);

    // The first pid a slot ever issues carries first_live_generation, so
    // no live pid can equal `invalid`.
    var pcb: process.ProcessControlBlock = undefined;
    const pid = try table.acquire(&pcb, .refcounted);
    try testing.expectEqual(@as(u30, pid_bit_layout.first_live_generation), pid.generation);
    table.release(pid);
}

test "PidTable: init validates capacity bounds" {
    try testing.expectError(error.InvalidCapacity, PidTable.init(testing.allocator, .{ .capacity = 0 }));
    // The full 2^24 slot address space is NOT a legal capacity: the
    // all-ones index is the reserved free-list sentinel.
    try testing.expectError(
        error.InvalidCapacity,
        PidTable.init(testing.allocator, .{ .capacity = pid_bit_layout.max_slot_capacity }),
    );
    try testing.expectError(
        error.InvalidCapacity,
        PidTable.init(testing.allocator, .{ .capacity = pid_bit_layout.max_table_capacity + 1 }),
    );
}

test "PidTable: acquire/lookup/release lifecycle round-trip" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 4 });
    defer table.deinit();

    var pcb: process.ProcessControlBlock = undefined;
    const pid = try table.acquire(&pcb, .refcounted);

    try testing.expect(pid.isLocal());
    try testing.expectEqual(ReclamationModel.refcounted, pid.model);
    try testing.expect(pid.slot < 4);
    try testing.expectEqual(@as(u30, pid_bit_layout.first_live_generation), pid.generation);

    try testing.expectEqual(@as(?*process.ProcessControlBlock, &pcb), table.lookup(pid));

    const stats_live = table.statistics();
    try testing.expectEqual(@as(u32, 4), stats_live.capacity);
    try testing.expectEqual(@as(u32, 1), stats_live.live_process_count);
    try testing.expectEqual(@as(u64, 0), stats_live.dead_letter_count);

    table.release(pid);
    try testing.expectEqual(@as(u32, 0), table.statistics().live_process_count);
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(pid));
}

/// Captures dead-letter invocations for hook-behavior tests.
const DeadLetterProbe = struct {
    call_count: usize = 0,
    observed_pid_bits: u64 = 0,
    observed_reason: ?DeadLetterReason = null,

    fn hook(context: ?*anyopaque, stale_pid: Pid, reason: DeadLetterReason) void {
        const probe: *DeadLetterProbe = @ptrCast(@alignCast(context.?));
        probe.call_count += 1;
        probe.observed_pid_bits = stale_pid.toBits();
        probe.observed_reason = reason;
    }
};

test "PidTable: release invalidates every outstanding pid for the slot and fires the dead-letter hook" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 2 });
    defer table.deinit();

    var probe = DeadLetterProbe{};
    table.dead_letter_hook = DeadLetterProbe.hook;
    table.dead_letter_context = &probe;

    var pcb: process.ProcessControlBlock = undefined;
    const pid = try table.acquire(&pcb, .refcounted);
    const outstanding_copy = Pid.fromBits(pid.toBits());

    table.release(pid);

    // EVERY outstanding pid for the slot is dead after one release.
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(outstanding_copy));
    try testing.expectEqual(@as(usize, 1), probe.call_count);
    try testing.expectEqual(outstanding_copy.toBits(), probe.observed_pid_bits);
    try testing.expectEqual(DeadLetterReason.generation_mismatch, probe.observed_reason.?);
    // The unconditional counter incremented even with a custom hook.
    try testing.expectEqual(@as(u64, 1), table.statistics().dead_letter_count);
}

test "PidTable: slot reuse bumps the generation and keeps stale pids dead" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 1 });
    defer table.deinit();

    var first_pcb: process.ProcessControlBlock = undefined;
    var second_pcb: process.ProcessControlBlock = undefined;

    const first_pid = try table.acquire(&first_pcb, .refcounted);
    table.release(first_pid);

    const second_pid = try table.acquire(&second_pcb, .refcounted);
    try testing.expectEqual(first_pid.slot, second_pid.slot);
    try testing.expectEqual(first_pid.generation + 1, second_pid.generation);

    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(first_pid));
    try testing.expectEqual(@as(?*process.ProcessControlBlock, &second_pcb), table.lookup(second_pid));

    table.release(second_pid);
}

test "PidTable: model bits are immutable per generation and validated together with the generation" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 1 });
    defer table.deinit();

    var probe = DeadLetterProbe{};
    table.dead_letter_hook = DeadLetterProbe.hook;
    table.dead_letter_context = &probe;

    var pcb: process.ProcessControlBlock = undefined;
    const pid = try table.acquire(&pcb, .refcounted);

    // A forged pid with the right slot+generation but wrong model bits
    // must not resolve (§2.4: the pair is validated as one unit).
    var forged = pid;
    forged.model = .traced;
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(forged));
    try testing.expectEqual(DeadLetterReason.model_mismatch, probe.observed_reason.?);

    // The genuine pid still resolves — the forged lookup disturbed
    // nothing.
    try testing.expectEqual(@as(?*process.ProcessControlBlock, &pcb), table.lookup(pid));

    // Reuse under a DIFFERENT model: the new generation carries the new
    // model bits…
    table.release(pid);
    var traced_pcb: process.ProcessControlBlock = undefined;
    const traced_pid = try table.acquire(&traced_pcb, .traced);
    try testing.expectEqual(ReclamationModel.traced, traced_pid.model);
    try testing.expectEqual(pid.slot, traced_pid.slot);

    // …and the stale sender holding the old-model pid hits GENERATION
    // mismatch (never a mis-emitted layout): the §2.4 stale-sender path.
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(pid));
    try testing.expectEqual(DeadLetterReason.generation_mismatch, probe.observed_reason.?);

    table.release(traced_pid);
}

test "PidTable: lookup dead-letters remote-node and out-of-range pids" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 4 });
    defer table.deinit();

    var probe = DeadLetterProbe{};
    table.dead_letter_hook = DeadLetterProbe.hook;
    table.dead_letter_context = &probe;

    const remote_pid = Pid{
        .slot = 0,
        .generation = pid_bit_layout.first_live_generation,
        .model = .refcounted,
        .node = 1,
    };
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(remote_pid));
    try testing.expectEqual(DeadLetterReason.remote_node, probe.observed_reason.?);

    const out_of_range_pid = Pid{
        .slot = 7, // capacity is 4
        .generation = pid_bit_layout.first_live_generation,
        .model = .refcounted,
        .node = pid_bit_layout.local_node_id,
    };
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(out_of_range_pid));
    try testing.expectEqual(DeadLetterReason.slot_out_of_range, probe.observed_reason.?);

    try testing.expectEqual(@as(u64, 2), table.statistics().dead_letter_count);
}

test "PidTable: acquire fails cleanly on free-list exhaustion and recovers after release" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 2 });
    defer table.deinit();

    var pcbs: [3]process.ProcessControlBlock = undefined;
    const first_pid = try table.acquire(&pcbs[0], .refcounted);
    const second_pid = try table.acquire(&pcbs[1], .refcounted);

    try testing.expectError(error.ProcessTableExhausted, table.acquire(&pcbs[2], .refcounted));

    // Releasing a slot makes acquisition possible again — same slot,
    // bumped generation.
    table.release(first_pid);
    const reused_pid = try table.acquire(&pcbs[2], .refcounted);
    try testing.expectEqual(first_pid.slot, reused_pid.slot);
    try testing.expectEqual(first_pid.generation + 1, reused_pid.generation);

    table.release(second_pid);
    table.release(reused_pid);
}

test "PidTable: generation exhaustion retires the slot instead of wrapping" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 1 });
    defer table.deinit();
    // This white-box test DELIBERATELY drives a slot to generation
    // exhaustion, which fires the retirement `warn`. Opt out of the log so
    // the intentional trigger stays off the test process's stderr (the Zig
    // build runner surfaces any such byte as `failed command:` noise on
    // this otherwise-green step); production keeps the warning.
    table.warn_on_slot_retirement = false;

    var probe = DeadLetterProbe{};
    table.dead_letter_hook = DeadLetterProbe.hook;
    table.dead_letter_context = &probe;

    // White-box: fast-forward the (free) slot to its final generation —
    // equivalent to max_generation-1 acquire/release cycles.
    table.slots[0].metadata.store(@bitCast(SlotMetadata{
        .generation = pid_bit_layout.max_generation,
        .model = .refcounted,
        .state = .free,
    }), .monotonic);

    var pcb: process.ProcessControlBlock = undefined;
    const final_generation_pid = try table.acquire(&pcb, .refcounted);
    try testing.expectEqual(@as(u30, pid_bit_layout.max_generation), final_generation_pid.generation);

    // Releasing at max_generation retires the slot: it never re-enters
    // the free list, so the {slot, generation} space is never reissued.
    table.release(final_generation_pid);
    try testing.expectEqual(@as(u32, 1), table.statistics().retired_slot_count);
    try testing.expectEqual(@as(u32, 0), table.statistics().live_process_count);
    try testing.expectError(error.ProcessTableExhausted, table.acquire(&pcb, .refcounted));

    // The retired-generation pid stays dead, and it dead-letters with
    // the RETIRED-slot reason: the slot keeps its final generation
    // forever, so the pid's generation still MATCHES and the miss is
    // classified `slot_not_occupied` (the `DeadLetterReason` doc's
    // retired-final-generation case), never `generation_mismatch`.
    try testing.expectEqual(@as(?*process.ProcessControlBlock, null), table.lookup(final_generation_pid));
    try testing.expectEqual(@as(usize, 1), probe.call_count);
    try testing.expectEqual(final_generation_pid.toBits(), probe.observed_pid_bits);
    try testing.expectEqual(DeadLetterReason.slot_not_occupied, probe.observed_reason.?);
}

test "PidTable: iterator yields exactly the live set and skips released slots" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 8 });
    defer table.deinit();

    var pcbs: [5]process.ProcessControlBlock = undefined;
    var pids: [5]Pid = undefined;
    for (&pids, &pcbs) |*pid, *pcb| {
        pid.* = try table.acquire(pcb, .refcounted);
    }

    table.release(pids[1]);
    table.release(pids[3]);

    var yielded_bits: [8]u64 = undefined;
    var yielded_count: usize = 0;
    var iterator = table.iterateLiveProcesses();
    while (iterator.next()) |live| {
        yielded_bits[yielded_count] = live.pid.toBits();
        yielded_count += 1;
        // Each yielded pair is internally consistent.
        try testing.expectEqual(@as(?*process.ProcessControlBlock, live.pcb), table.lookup(live.pid));
    }

    try testing.expectEqual(@as(usize, 3), yielded_count);
    for ([_]usize{ 0, 2, 4 }) |live_index| {
        const expected = pids[live_index].toBits();
        var found = false;
        for (yielded_bits[0..yielded_count]) |bits| {
            if (bits == expected) found = true;
        }
        try testing.expect(found);
    }

    table.release(pids[0]);
    table.release(pids[2]);
    table.release(pids[4]);
}

test "PidTable: iterator tolerates interleaved acquire/release mid-iteration" {
    var table = try PidTable.init(testing.allocator, .{ .capacity = 8 });
    defer table.deinit();

    var pcbs: [6]process.ProcessControlBlock = undefined;
    var pids: [6]Pid = undefined;
    for (&pids, &pcbs) |*pid, *pcb| {
        pid.* = try table.acquire(pcb, .refcounted);
    }

    var iterator = table.iterateLiveProcesses();

    // Visit the first two live slots (ascending slot order on a
    // single-threaded table).
    const first_yield = iterator.next().?;
    const second_yield = iterator.next().?;
    try testing.expectEqual(pids[0].toBits(), first_yield.pid.toBits());
    try testing.expectEqual(pids[1].toBits(), second_yield.pid.toBits());

    // Mutate ahead of the cursor mid-iteration: release slot 3's process
    // and spawn a replacement (LIFO free list → same slot, new
    // generation), and release slot 4's process outright.
    table.release(pids[3]);
    var replacement_pcb: process.ProcessControlBlock = undefined;
    const replacement_pid = try table.acquire(&replacement_pcb, .refcounted);
    try testing.expectEqual(pids[3].slot, replacement_pid.slot);
    table.release(pids[4]);

    var yielded_bits: [8]u64 = undefined;
    var yielded_count: usize = 0;
    while (iterator.next()) |live| {
        yielded_bits[yielded_count] = live.pid.toBits();
        yielded_count += 1;
    }

    // slot 2, slot 3 (the REPLACEMENT — live at visit), and slot 5.
    try testing.expectEqual(@as(usize, 3), yielded_count);
    try testing.expectEqual(pids[2].toBits(), yielded_bits[0]);
    try testing.expectEqual(replacement_pid.toBits(), yielded_bits[1]);
    try testing.expectEqual(pids[5].toBits(), yielded_bits[2]);

    // The released-then-reused slot's OLD pid was never yielded and the
    // released slot 4 was skipped — released processes never surface as
    // stale PCBs.
    for (yielded_bits[0..yielded_count]) |bits| {
        try testing.expect(bits != pids[3].toBits());
        try testing.expect(bits != pids[4].toBits());
    }

    table.release(pids[0]);
    table.release(pids[1]);
    table.release(pids[2]);
    table.release(replacement_pid);
    table.release(pids[5]);
}

/// Shared state of the multi-threaded smoke test.
const SmokeTestShared = struct {
    table: *PidTable,
    all_pcbs: []process.ProcessControlBlock,
    failure_count: std.atomic.Value(u32) = .init(0),
    stale_lookup_total: std.atomic.Value(u64) = .init(0),
    workers_done: std.atomic.Value(u32) = .init(0),

    fn fail(shared: *SmokeTestShared) void {
        _ = shared.failure_count.fetchAdd(1, .monotonic);
    }
};

/// One acquire/lookup/release worker of the multi-threaded smoke test.
const SmokeTestWorker = struct {
    shared: *SmokeTestShared,
    pcbs: []process.ProcessControlBlock,

    const iterations = 4000;
    const held_ring_size = 8;

    fn run(worker: *SmokeTestWorker) void {
        const table = worker.shared.table;
        var held: [held_ring_size]?Pid = @splat(null);
        var stale: [held_ring_size]?Pid = @splat(null);

        for (0..iterations) |iteration| {
            const ring = iteration % held_ring_size;
            if (held[ring]) |live_pid| {
                // Invariant: our live pid resolves to OUR pcb.
                const resolved = table.lookup(live_pid) orelse return worker.shared.fail();
                if (resolved != &worker.pcbs[ring]) return worker.shared.fail();

                table.release(live_pid);
                held[ring] = null;
                stale[ring] = live_pid;

                // Invariant: a released pid never resolves again
                // (generations are monotone; retirement forbids wrap).
                if (table.lookup(live_pid) != null) return worker.shared.fail();
                _ = worker.shared.stale_lookup_total.fetchAdd(1, .monotonic);
            } else {
                const pid = table.acquire(&worker.pcbs[ring], .refcounted) catch
                    return worker.shared.fail();
                if (!pid.isLocal()) return worker.shared.fail();
                if (pid.model != .refcounted) return worker.shared.fail();
                if (pid.generation < pid_bit_layout.first_live_generation) return worker.shared.fail();
                held[ring] = pid;

                // Long-stale pids stay dead across many reuses.
                if (stale[ring]) |stale_pid| {
                    if (table.lookup(stale_pid) != null) return worker.shared.fail();
                    _ = worker.shared.stale_lookup_total.fetchAdd(1, .monotonic);
                }
            }
        }

        for (&held) |*held_slot| {
            if (held_slot.*) |live_pid| {
                table.release(live_pid);
                held_slot.* = null;
            }
        }
    }

    fn runAndSignal(worker: *SmokeTestWorker) void {
        worker.run();
        _ = worker.shared.workers_done.fetchAdd(1, .monotonic);
    }
};

/// Concurrent iteration observer of the multi-threaded smoke test.
const SmokeTestObserver = struct {
    shared: *SmokeTestShared,
    worker_count: u32,

    fn run(observer: *SmokeTestObserver) void {
        const shared = observer.shared;
        const table = shared.table;
        const pcb_base = @intFromPtr(shared.all_pcbs.ptr);
        const pcb_end = pcb_base + shared.all_pcbs.len * @sizeOf(process.ProcessControlBlock);

        while (shared.workers_done.load(.acquire) < observer.worker_count) {
            var iterator = table.iterateLiveProcesses();
            while (iterator.next()) |live| {
                if (!live.pid.isLocal()) return shared.fail();
                if (live.pid.generation < pid_bit_layout.first_live_generation) return shared.fail();
                if (live.pid.slot >= table.slots.len) return shared.fail();

                // Yielded PCBs are always real worker PCBs — never torn
                // or stale pointers.
                const pcb_address = @intFromPtr(live.pcb);
                if (pcb_address < pcb_base or pcb_address >= pcb_end) return shared.fail();
                if ((pcb_address - pcb_base) % @sizeOf(process.ProcessControlBlock) != 0)
                    return shared.fail();

                // A yielded pid either still resolves to the SAME pcb or
                // has died — never to a different process.
                if (table.lookup(live.pid)) |resolved| {
                    if (resolved != live.pcb) return shared.fail();
                } else {
                    _ = shared.stale_lookup_total.fetchAdd(1, .monotonic);
                }
            }
        }
    }
};

test "PidTable: multi-threaded acquire/lookup/release/iteration smoke" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const worker_thread_count = 4;
    var table = try PidTable.init(testing.allocator, .{ .capacity = 64 });
    defer table.deinit();

    const all_pcbs = try testing.allocator.alloc(
        process.ProcessControlBlock,
        worker_thread_count * SmokeTestWorker.held_ring_size,
    );
    defer testing.allocator.free(all_pcbs);

    var shared = SmokeTestShared{ .table = &table, .all_pcbs = all_pcbs };

    var workers: [worker_thread_count]SmokeTestWorker = undefined;
    for (&workers, 0..) |*worker, worker_index| {
        const first_pcb = worker_index * SmokeTestWorker.held_ring_size;
        worker.* = .{
            .shared = &shared,
            .pcbs = all_pcbs[first_pcb .. first_pcb + SmokeTestWorker.held_ring_size],
        };
    }
    var observer = SmokeTestObserver{ .shared = &shared, .worker_count = worker_thread_count };

    var worker_threads: [worker_thread_count]std.Thread = undefined;
    for (&worker_threads, &workers) |*thread, *worker| {
        thread.* = try std.Thread.spawn(.{}, SmokeTestWorker.runAndSignal, .{worker});
    }
    const observer_thread = try std.Thread.spawn(.{}, SmokeTestObserver.run, .{&observer});

    for (&worker_threads) |*thread| thread.join();
    observer_thread.join();

    try testing.expectEqual(@as(u32, 0), shared.failure_count.load(.monotonic));

    // Quiescent state: everything released, nothing live, and the
    // dead-letter counter agrees exactly with the stale lookups the
    // threads performed (no other dead-letter source exists here).
    const stats = table.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_process_count);
    try testing.expectEqual(@as(u32, 0), stats.retired_slot_count);
    try testing.expectEqual(shared.stale_lookup_total.load(.monotonic), stats.dead_letter_count);

    var iterator = table.iterateLiveProcesses();
    try testing.expect(iterator.next() == null);
}
