//! Kernel signal primitives for the Zap concurrency runtime — the genuine
//! MECHANISM over which links, monitors, and supervision are written in pure
//! Zap (`docs/concurrency-implementation-plan.md` §5.1, job P5-J1; research.md
//! §6.7). This leaf module owns the *data* of process signalling; the scheduler
//! (`scheduler.zig`) drives propagation and the ABI (`abi.zig`) exposes the
//! intrinsics. The division of labor (plan §4, CLAUDE.md "Zap is a language"):
//! ONLY the signal mechanism is Zig — links/monitors/supervisors as user-facing
//! behavior are Zap stdlib (jobs J2/J3), layered on the intrinsics J1 provides.
//!
//! ## Erlang-fidelity semantics (research.md §6.7, verified against erlang.org)
//!
//! * **Links** are bidirectional, one-per-pair (linking twice is idempotent),
//!   and propagate exit signals. A process's `links` set is mutated from ANY
//!   core (the peer establishing the link runs elsewhere), so it is guarded by
//!   `SignalState.lock`.
//! * **Monitors** are unidirectional and stackable (N monitors ⇒ N `DOWN`
//!   messages). The monitored process holds a `monitored_by` set (who watches
//!   it — cross-core, locked); the monitoring process holds a `monitors` set
//!   (what it watches — OWNER-ONLY, no lock, since only the owner monitors and
//!   demonitors). A monitor reference (`Ref`) is a process-global unique u64.
//! * **Exit reasons.** `normal` does not kill a non-trapping linked process (a
//!   trapping one still receives it as a message); every other reason is
//!   `abnormal` — it kills a non-trapping linked process (cascading) and is
//!   delivered as a message to a trapping one. `kill` is a distinct UNTRAPPABLE
//!   input: it terminates the target with reason `killed` (so the target's own
//!   links receive the trappable `killed`, never `kill`).
//!
//! ## Reason terms (Zap-owned atoms, kernel-opaque)
//!
//! An exit reason carries an opaque `term` — an atom id in the binary-global
//! atom table (`String`/atom transport, `lib/process.zap`). The kernel NEVER
//! interprets a term; it only distinguishes the propagation `category`
//! (`normal` vs `abnormal`), which the Zap surface supplies. The three reasons
//! the kernel must SYNTHESIZE — `normal` (a clean exit), `killed` (a kill), and
//! `noproc` (monitoring/linking an already-dead process) — are registered by
//! the Zap signal wrappers at first use (`ReasonAtoms.set`), so no Zap atom
//! name is ever hardcoded in Zig.
//!
//! ## Allocation
//!
//! Link/monitor set entries are fixed-size `SignalNode`s drawn from a shared,
//! block-allocating, lock-guarded `SignalNodePool` (page-efficient — one page
//! backs hundreds of nodes; cross-core alloc/free like the envelope pool). An
//! exit/`DOWN` message's payload is a `SignalPayload` carried in a runtime
//! ledger block through the neutral envelope, freed by the receiver's
//! `zap_proc_envelope_free` exactly like a copied user payload; the scheduler
//! allocates it through the `PayloadSeam` (wired by `abi.zig` to its ledger).
//!
//! ## Concurrency
//!
//! `SignalState.lock` (a spinlock, `std.atomic.Mutex`, matching the kernel's
//! libc-free convention) guards the cross-core-mutated sets (`links`,
//! `monitored_by`) and `pending_exit`. Two-lock operations (`link`) acquire in
//! address order so they cannot deadlock; teardown holds AT MOST ONE state lock
//! at a time (it snapshots its own sets under its own lock, releases, then
//! touches each peer under that peer's lock), so it can never be a party to a
//! lock cycle either. `trap_exit` is a lone atomic (read from any core).

const std = @import("std");

/// The kind of a signal message merged into a mailbox — the discriminator the
/// receive lowering reads to tell a signal from an ordinary user message. Lives
/// on the envelope `Fragment` (`mailbox.zig`); `none` is an ordinary message.
pub const SignalKind = enum(u8) {
    /// Not a signal — an ordinary user message.
    none,
    /// A trapped exit signal, delivered as `{'EXIT', From, Reason}` to a
    /// process with `trap_exit` set.
    exit,
    /// A monitor `DOWN`, delivered as `{'DOWN', Ref, process, Pid, Reason}`.
    down,
};

/// The propagation category the kernel's signal rules switch on — the only
/// facet of a reason the kernel interprets (the `term` is Zap-opaque). Selects
/// whether a non-trapping linked process dies (research.md §6.7).
pub const ReasonCategory = enum(u8) {
    /// A clean exit: does NOT kill a non-trapping linked process; a trapping
    /// one still receives `{'EXIT', From, normal}`.
    normal,
    /// Any abnormal reason (a crash term, `killed`, a user reason): kills a
    /// non-trapping linked process (cascading) and is delivered as a message
    /// to a trapping one.
    abnormal,
};

/// A process's full exit reason: the propagation `category` (which also selects
/// the crash-report label and exit counter, `scheduler.zig`) plus the opaque
/// reason `term` delivered to trapping links (`{'EXIT', From, term}`) and
/// monitors (`{'DOWN', …, term}`). The term is an atom id in the binary-global
/// atom table; richer arbitrary-term reasons layer on later without changing
/// the propagation rules.
pub const ExitStatus = struct {
    /// The propagation category (`normal` never kills a non-trapping link).
    category: ReasonCategory,
    /// The opaque reason term (atom id) carried to trapping links and monitors.
    term: u64,

    /// A clean-exit status carrying `term` (an atom id — typically `normal`).
    pub fn normalStatus(term: u64) ExitStatus {
        return .{ .category = .normal, .term = term };
    }

    /// An abnormal-exit status carrying `term` (a crash/`killed`/user reason).
    pub fn abnormalStatus(term: u64) ExitStatus {
        return .{ .category = .abnormal, .term = term };
    }
};

/// A monitor reference — a process-global unique identifier for one monitor
/// (research.md §6.7: N monitors ⇒ N distinct refs ⇒ N `DOWN` messages). Minted
/// from a process-global atomic counter; opaque and copyable, it identifies the
/// monitor in `demonitor` and in the delivered `DOWN` message. Zero is the
/// never-issued invalid ref.
pub const Ref = u64;

/// The fixed-size payload of an exit/`DOWN` signal message, carried in a
/// runtime ledger block through the neutral envelope. The `SignalKind`
/// discriminator lives on the `Fragment`; these are the signal's fields the
/// receive lowering (and the raw J1 test surface) reads out.
pub const SignalPayload = struct {
    /// The pid (raw bits) the signal is FROM — the exiting process for an
    /// `exit`, the monitored process for a `down`.
    from_bits: u64 = 0,
    /// The monitor reference (`down` only; 0 for `exit`).
    ref: Ref = 0,
    /// The reason term (atom id) — `{'EXIT', From, term}` / `{'DOWN', …, term}`.
    reason_term: u64 = 0,
};

/// One entry in a link/monitor set — an intrusive node drawn from the shared
/// `SignalNodePool`. A `links`/`monitored_by`/`monitors` set is a singly-linked
/// list of these. For a link entry only `pid_bits` is meaningful; monitor
/// entries also carry the `ref`.
pub const SignalNode = struct {
    /// Next entry in the owning set (intrusive list).
    next: ?*SignalNode = null,
    /// The peer pid's raw bits: the linked peer, the monitoring process
    /// (`monitored_by`), or the monitored process (`monitors`).
    pid_bits: u64 = 0,
    /// The monitor reference (monitor entries only; 0 for a link entry).
    ref: Ref = 0,
};

/// A shared, block-allocating, lock-guarded free-list of `SignalNode`s. One
/// backing block (a page's worth of nodes) amortizes the page-granular backing
/// allocation across hundreds of nodes — a link/monitor entry must never cost a
/// whole page. Cross-core by design (a link established on one core frees its
/// node at the peer's teardown on another), guarded by a spinlock exactly like
/// the runtime payload ledger (`abi.zig`). `liveNodeCount` is the leak oracle;
/// `sweep` (at runtime deinit) returns every block to the backing allocator.
pub const SignalNodePool = struct {
    /// Page-granular backing allocator (the runtime's libc-free page allocator).
    backing_allocator: std.mem.Allocator,
    /// Guards the free list, the block list, and the count.
    lock: std.atomic.Mutex = .unlocked,
    /// Recycled nodes ready to hand out.
    free_list: ?*SignalNode = null,
    /// Every backing block, for `sweep`.
    blocks: ?*Block = null,
    /// Nodes currently checked out (never returned) — the leak oracle.
    live_node_count: usize = 0,

    /// Nodes carved per backing block. A block is one `Block`'s worth of
    /// contiguous nodes; 256 keeps the block near a couple of pages while
    /// amortizing the backing allocation broadly.
    const nodes_per_block: usize = 256;

    /// One backing allocation: a header linking it for `sweep` plus its nodes.
    const Block = struct {
        next: ?*Block,
        nodes: [nodes_per_block]SignalNode,
    };

    /// Create a pool over `backing_allocator` (no allocation until first use).
    pub fn init(backing_allocator: std.mem.Allocator) SignalNodePool {
        return .{ .backing_allocator = backing_allocator };
    }

    fn acquire(pool: *SignalNodePool) void {
        while (!pool.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Hand out one node (fields zeroed), growing the pool by a block when the
    /// free list is empty. The backing allocation, when needed, happens under
    /// the lock (rare — only on growth); the fast path is a lock + list pop.
    pub fn allocate(pool: *SignalNodePool) error{OutOfMemory}!*SignalNode {
        pool.acquire();
        defer pool.lock.unlock();
        if (pool.free_list == null) {
            const block = try pool.backing_allocator.create(Block);
            block.next = pool.blocks;
            pool.blocks = block;
            // Thread the fresh block's nodes onto the free list.
            for (&block.nodes) |*node| {
                node.* = .{ .next = pool.free_list };
                pool.free_list = node;
            }
        }
        const node = pool.free_list.?;
        pool.free_list = node.next;
        node.* = .{};
        pool.live_node_count += 1;
        return node;
    }

    /// Return one node to the free list.
    pub fn free(pool: *SignalNodePool, node: *SignalNode) void {
        pool.acquire();
        defer pool.lock.unlock();
        node.next = pool.free_list;
        pool.free_list = node;
        std.debug.assert(pool.live_node_count > 0);
        pool.live_node_count -= 1;
    }

    /// Nodes currently checked out (the leak oracle; must reach zero once every
    /// process's sets are drained at teardown).
    pub fn liveNodeCount(pool: *SignalNodePool) usize {
        pool.acquire();
        defer pool.lock.unlock();
        return pool.live_node_count;
    }

    /// Return every backing block to the allocator (runtime deinit). No node
    /// may be live (`liveNodeCount == 0`) — every process's teardown drained
    /// its sets.
    pub fn deinit(pool: *SignalNodePool) void {
        std.debug.assert(pool.live_node_count == 0);
        var block = pool.blocks;
        while (block) |current| {
            block = current.next;
            pool.backing_allocator.destroy(current);
        }
        pool.blocks = null;
        pool.free_list = null;
    }
};

/// The kernel's registry of the three well-known reason atoms it must
/// SYNTHESIZE: `normal` (a clean exit's reason), `killed` (the reason a killed
/// process dies with, and that its links then see), and `noproc` (monitoring or
/// linking an already-dead process). The Zap signal wrappers register these at
/// first use (`lib/process.zap`) so no Zap atom name is ever hardcoded in Zig;
/// the values are idempotent (always the same atom ids), so the plain-atomic
/// stores/loads never observe a torn or inconsistent term.
pub const ReasonAtoms = struct {
    normal: std.atomic.Value(u64) = .init(0),
    killed: std.atomic.Value(u64) = .init(0),
    noproc: std.atomic.Value(u64) = .init(0),

    /// Register the three well-known reason atom ids (idempotent).
    pub fn set(atoms: *ReasonAtoms, normal_term: u64, killed_term: u64, noproc_term: u64) void {
        atoms.normal.store(normal_term, .monotonic);
        atoms.killed.store(killed_term, .monotonic);
        atoms.noproc.store(noproc_term, .monotonic);
    }

    /// The registered `normal` reason term (0 if never registered — only
    /// possible when no process has links/monitors, so the term is unused).
    pub fn normalTerm(atoms: *const ReasonAtoms) u64 {
        return atoms.normal.load(.monotonic);
    }

    /// The registered `killed` reason term.
    pub fn killedTerm(atoms: *const ReasonAtoms) u64 {
        return atoms.killed.load(.monotonic);
    }

    /// The registered `noproc` reason term.
    pub fn noprocTerm(atoms: *const ReasonAtoms) u64 {
        return atoms.noproc.load(.monotonic);
    }
};

/// The scheduler's seam for allocating and freeing signal-message PAYLOAD
/// blocks. An exit/`DOWN` payload must be freeable by the receiver's ordinary
/// `zap_proc_envelope_free`, so it lives in a runtime ledger block; the ledger
/// is owned by `abi.zig`, which wires these function pointers at runtime init.
/// `allocate` returns a body pointer (or null on OOM); `free` releases one the
/// scheduler allocated but never delivered (a dead-letter or a teardown drain).
pub const PayloadSeam = struct {
    /// Opaque context threaded to the seam calls (the runtime's ledger).
    context: ?*anyopaque = null,
    /// Allocate `byte_length` payload bytes; null on exhaustion.
    allocate: ?*const fn (context: ?*anyopaque, byte_length: usize) callconv(.c) ?[*]u8 = null,
    /// Free a payload body the scheduler allocated but did not deliver.
    free: ?*const fn (context: ?*anyopaque, body: [*]const u8, byte_length: usize) callconv(.c) void = null,
};

/// The shared runtime state the signal mechanism needs: the node pool, the
/// reason-atom registry, and the payload seam. One instance is created at
/// runtime init (`abi.zig`) and shared across every scheduler core (like the
/// pid table and envelope pool); a standalone kernel-test scheduler creates its
/// own. Pointed to from `Scheduler.Options.signal_runtime`.
pub const SignalRuntime = struct {
    /// Backing store for link/monitor set entries.
    node_pool: SignalNodePool,
    /// The well-known reason atoms the kernel synthesizes.
    reason_atoms: ReasonAtoms = .{},
    /// The exit/`DOWN` payload alloc/free seam (wired by `abi.zig`).
    payload_seam: PayloadSeam = .{},
    /// Monotonic source of process-global-unique monitor references. Minted by
    /// `mintRef`; starts at 1 so a `Ref` is never the zero invalid value.
    ref_counter: std.atomic.Value(Ref) = .init(0),

    /// Create a signal runtime over `backing_allocator` (for the node pool).
    pub fn init(backing_allocator: std.mem.Allocator) SignalRuntime {
        return .{ .node_pool = SignalNodePool.init(backing_allocator) };
    }

    /// Mint a fresh process-global-unique monitor reference (never zero).
    pub fn mintRef(runtime: *SignalRuntime) Ref {
        return runtime.ref_counter.fetchAdd(1, .monotonic) + 1;
    }

    /// Release the node pool's backing blocks (runtime deinit).
    pub fn deinit(runtime: *SignalRuntime) void {
        runtime.node_pool.deinit();
    }
};

/// Per-process signal state, embedded by value in the process control block
/// (`process.zig`). Holds the bidirectional link set, the incoming-monitor set
/// (`monitored_by` — who watches this process), the outgoing-monitor set
/// (`monitors` — what this process watches), the `trap_exit` flag, and a
/// `pending_exit` reason set when an abnormal signal dooms a non-trapping
/// process. See the module doc for the locking discipline.
pub const SignalState = struct {
    /// Guards `links`, `monitored_by`, and `pending_exit` — all cross-core
    /// mutated. `monitors` and `trap_exit` do NOT need it (see their docs).
    lock: std.atomic.Mutex = .unlocked,
    /// Processes this one is linked to (bidirectional, one node per peer).
    /// Cross-core mutated (a peer links from its own core); under `lock`.
    links: ?*SignalNode = null,
    /// Monitors held ON this process — `{ref, monitoring pid}` per node. Fired
    /// as `DOWN` at teardown. Cross-core mutated (a watcher monitors from its
    /// own core; `demonitor` removes from its own core); under `lock`.
    monitored_by: ?*SignalNode = null,
    /// Monitors this process HOLDS on others — `{ref, monitored pid}` per node.
    /// OWNER-ONLY (only this process monitors/demonitors), so NO lock: used to
    /// route `demonitor(ref)` to the target and to clean the target's
    /// `monitored_by` at this process's teardown.
    monitors: ?*SignalNode = null,
    /// Whether this process traps exits: a trappable exit signal becomes an
    /// `{'EXIT', From, Reason}` mailbox message instead of killing it. A lone
    /// atomic — read from any core delivering a signal, written by this process
    /// (or a supervisor) via `set_trap_exit`.
    trap_exit: std.atomic.Value(bool) = .init(false),
    /// The reason a non-trapping process was doomed by an abnormal signal, read
    /// by teardown. Set under `lock` (first-wins; an untrappable `kill`
    /// overrides to `killed`). Null until the process is doomed by a signal
    /// (a normal return / self-exit fills the reason at the teardown site).
    pending_exit: ?ExitStatus = null,

    fn acquire(state: *SignalState) void {
        while (!state.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Whether this process traps exits (atomic acquire load).
    pub fn trapsExits(state: *const SignalState) bool {
        return state.trap_exit.load(.acquire);
    }

    /// Set the trap-exit flag, returning the previous value (Erlang
    /// `process_flag(trap_exit, …)` returns the old flag).
    pub fn setTrapExit(state: *SignalState, value: bool) bool {
        return state.trap_exit.swap(value, .acq_rel);
    }

    /// Push a CALLER-PROVIDED, pre-allocated node into the link set for
    /// `peer_bits`, WITHOUT dedup or allocation — the infallible half of the
    /// atomic `spawn_link` path (P5-J2). `spawn` pre-allocates the two link
    /// nodes BEFORE minting the child's pid (so an OOM fails the spawn cleanly),
    /// then inserts them here once the pid exists but before the child is
    /// admitted — so the link is in place before the child can run and exit. No
    /// dedup is needed: the child's pid is freshly minted, so no peer can already
    /// be linked to it. Self-locking (the parent side may be mutated by a third
    /// core concurrently).
    pub fn insertLinkNode(state: *SignalState, node: *SignalNode, peer_bits: u64) void {
        node.pid_bits = peer_bits;
        node.ref = 0;
        state.acquire();
        defer state.lock.unlock();
        node.next = state.links;
        state.links = node;
    }

    /// Add `peer_bits` to the link set if absent (idempotent — one node per
    /// peer, so `link` twice is a no-op). Returns whether a node was added.
    /// Self-locking. Allocates from `pool` on insert.
    pub fn linkPeer(state: *SignalState, pool: *SignalNodePool, peer_bits: u64) error{OutOfMemory}!bool {
        state.acquire();
        defer state.lock.unlock();
        var node = state.links;
        while (node) |current| : (node = current.next) {
            if (current.pid_bits == peer_bits) return false;
        }
        const fresh = try pool.allocate();
        fresh.pid_bits = peer_bits;
        fresh.next = state.links;
        state.links = fresh;
        return true;
    }

    /// Remove `peer_bits` from the link set if present, freeing its node.
    /// Returns whether a node was removed. Self-locking.
    pub fn unlinkPeer(state: *SignalState, pool: *SignalNodePool, peer_bits: u64) bool {
        state.acquire();
        defer state.lock.unlock();
        var indirect = &state.links;
        while (indirect.*) |current| {
            if (current.pid_bits == peer_bits) {
                indirect.* = current.next;
                pool.free(current);
                return true;
            }
            indirect = &current.next;
        }
        return false;
    }

    /// Take the whole link set for teardown propagation: return the list head
    /// and clear the set (so no late peer can observe a half-drained list).
    /// The caller walks and frees the nodes. Self-locking.
    pub fn takeLinks(state: *SignalState) ?*SignalNode {
        state.acquire();
        defer state.lock.unlock();
        const head = state.links;
        state.links = null;
        return head;
    }

    /// Push a CALLER-PROVIDED, pre-allocated node into the incoming-monitor set
    /// (`{ref, monitor_bits}`), WITHOUT allocation — the infallible half of the
    /// atomic `spawn_monitor` path (P5-J2), inserted after the child's pid is
    /// minted but before it is admitted. Stackable, like `addMonitoredBy`.
    /// Self-locking.
    pub fn insertMonitoredByNode(state: *SignalState, node: *SignalNode, ref: Ref, monitor_bits: u64) void {
        node.pid_bits = monitor_bits;
        node.ref = ref;
        state.acquire();
        defer state.lock.unlock();
        node.next = state.monitored_by;
        state.monitored_by = node;
    }

    /// Record that `monitor_bits` monitors this process under `ref`. Stackable —
    /// no dedup (N monitors ⇒ N entries ⇒ N `DOWN`s). Self-locking.
    pub fn addMonitoredBy(state: *SignalState, pool: *SignalNodePool, ref: Ref, monitor_bits: u64) error{OutOfMemory}!void {
        state.acquire();
        defer state.lock.unlock();
        const fresh = try pool.allocate();
        fresh.pid_bits = monitor_bits;
        fresh.ref = ref;
        fresh.next = state.monitored_by;
        state.monitored_by = fresh;
    }

    /// Remove the incoming-monitor entry with `ref` if present, freeing its
    /// node. Returns whether one was removed. Self-locking.
    pub fn removeMonitoredByRef(state: *SignalState, pool: *SignalNodePool, ref: Ref) bool {
        state.acquire();
        defer state.lock.unlock();
        var indirect = &state.monitored_by;
        while (indirect.*) |current| {
            if (current.ref == ref) {
                indirect.* = current.next;
                pool.free(current);
                return true;
            }
            indirect = &current.next;
        }
        return false;
    }

    /// Take the whole incoming-monitor set for teardown (fire `DOWN` to each,
    /// then free the nodes). Self-locking.
    pub fn takeMonitoredBy(state: *SignalState) ?*SignalNode {
        state.acquire();
        defer state.lock.unlock();
        const head = state.monitored_by;
        state.monitored_by = null;
        return head;
    }

    /// Push a CALLER-PROVIDED, pre-allocated node into the outgoing-monitor set
    /// (`{ref → target_bits}`), WITHOUT allocation — the infallible half of the
    /// atomic `spawn_monitor` path (P5-J2) for the PARENT (monitoring) side. The
    /// parent's `monitors` set is owner-only, but the parent is the running
    /// spawner, so the insert races nothing; still, the insert must be sequenced
    /// before the child is admitted. No lock (owner-only), like `addMonitor`.
    pub fn insertMonitorNode(state: *SignalState, node: *SignalNode, ref: Ref, target_bits: u64) void {
        node.pid_bits = target_bits;
        node.ref = ref;
        node.next = state.monitors;
        state.monitors = node;
    }

    /// Record an outgoing monitor `{ref → target_bits}` (owner-only; no lock).
    pub fn addMonitor(state: *SignalState, pool: *SignalNodePool, ref: Ref, target_bits: u64) error{OutOfMemory}!void {
        const fresh = try pool.allocate();
        fresh.pid_bits = target_bits;
        fresh.ref = ref;
        fresh.next = state.monitors;
        state.monitors = fresh;
    }

    /// Remove the outgoing monitor with `ref`, returning its target pid bits
    /// (or null if unknown). Owner-only; no lock. Frees the node.
    pub fn takeMonitorRef(state: *SignalState, pool: *SignalNodePool, ref: Ref) ?u64 {
        var indirect = &state.monitors;
        while (indirect.*) |current| {
            if (current.ref == ref) {
                const target = current.pid_bits;
                indirect.* = current.next;
                pool.free(current);
                return target;
            }
            indirect = &current.next;
        }
        return null;
    }

    /// Take the whole outgoing-monitor set for teardown (clean each target's
    /// `monitored_by`, then free the nodes). Owner-only; no lock.
    pub fn takeMonitors(state: *SignalState) ?*SignalNode {
        const head = state.monitors;
        state.monitors = null;
        return head;
    }

    /// Record the reason this process was doomed by a signal (read by teardown).
    /// First-wins: an existing reason is kept UNLESS `override` (an untrappable
    /// `kill` overriding a trappable reason to `killed`). Self-locking.
    pub fn setPendingExit(state: *SignalState, status: ExitStatus, override: bool) void {
        state.acquire();
        defer state.lock.unlock();
        if (state.pending_exit == null or override) state.pending_exit = status;
    }

    /// The reason a signal doomed this process, or null (a plain same-core kill /
    /// self-exit records none). Self-locking.
    pub fn getPendingExit(state: *SignalState) ?ExitStatus {
        state.acquire();
        defer state.lock.unlock();
        return state.pending_exit;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SignalNodePool: allocate/free round-trips and grows in blocks, leak-exact" {
    var pool = SignalNodePool.init(testing.allocator);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 0), pool.liveNodeCount());

    // Allocate more than one block's worth to force growth.
    const count = SignalNodePool.nodes_per_block + 5;
    var nodes: [SignalNodePool.nodes_per_block + 5]*SignalNode = undefined;
    for (&nodes) |*slot| slot.* = try pool.allocate();
    try testing.expectEqual(count, pool.liveNodeCount());

    // Fields are zeroed on hand-out.
    try testing.expectEqual(@as(u64, 0), nodes[0].pid_bits);
    try testing.expectEqual(@as(Ref, 0), nodes[0].ref);

    for (nodes) |node| pool.free(node);
    try testing.expectEqual(@as(usize, 0), pool.liveNodeCount());

    // A freed node is handed back out (recycle, no new block).
    const recycled = try pool.allocate();
    try testing.expectEqual(@as(usize, 1), pool.liveNodeCount());
    pool.free(recycled);
    try testing.expectEqual(@as(usize, 0), pool.liveNodeCount());
}

test "SignalState: link set is idempotent and removable, leak-exact" {
    var pool = SignalNodePool.init(testing.allocator);
    defer pool.deinit();
    var state = SignalState{};

    // First link adds; second (same peer) is a no-op (one-per-pair).
    try testing.expect(try state.linkPeer(&pool, 0xAAAA));
    try testing.expect(!try state.linkPeer(&pool, 0xAAAA));
    try testing.expect(try state.linkPeer(&pool, 0xBBBB));
    try testing.expectEqual(@as(usize, 2), pool.liveNodeCount());

    try testing.expect(state.unlinkPeer(&pool, 0xAAAA));
    try testing.expect(!state.unlinkPeer(&pool, 0xAAAA)); // already gone
    try testing.expect(state.unlinkPeer(&pool, 0xBBBB));
    try testing.expectEqual(@as(usize, 0), pool.liveNodeCount());
}

test "SignalState: monitors stack and route by ref, leak-exact" {
    var pool = SignalNodePool.init(testing.allocator);
    defer pool.deinit();
    var monitored = SignalState{};
    var monitor = SignalState{};

    // Two monitors on the same target stack (N monitors ⇒ N entries).
    try monitored.addMonitoredBy(&pool, 1, 0xCAFE);
    try monitored.addMonitoredBy(&pool, 2, 0xCAFE);

    // The monitoring side records the outgoing refs (owner-only).
    try monitor.addMonitor(&pool, 1, 0xF00D);
    try monitor.addMonitor(&pool, 2, 0xF00D);
    try testing.expectEqual(@as(usize, 4), pool.liveNodeCount());

    // demonitor routes ref → target and removes both sides.
    try testing.expectEqual(@as(?u64, 0xF00D), monitor.takeMonitorRef(&pool, 1));
    try testing.expectEqual(@as(?u64, null), monitor.takeMonitorRef(&pool, 1)); // gone
    try testing.expect(monitored.removeMonitoredByRef(&pool, 1));
    try testing.expect(!monitored.removeMonitoredByRef(&pool, 1));

    // The second monitor is still live on both sides.
    try testing.expectEqual(@as(usize, 2), pool.liveNodeCount());
    try testing.expectEqual(@as(?u64, 0xF00D), monitor.takeMonitorRef(&pool, 2));
    try testing.expect(monitored.removeMonitoredByRef(&pool, 2));
    try testing.expectEqual(@as(usize, 0), pool.liveNodeCount());
}

test "SignalState: trap_exit flag swaps and reads" {
    var state = SignalState{};
    try testing.expect(!state.trapsExits());
    try testing.expect(!state.setTrapExit(true)); // returns previous
    try testing.expect(state.trapsExits());
    try testing.expect(state.setTrapExit(false));
    try testing.expect(!state.trapsExits());
}

test "ReasonAtoms: idempotent registration and readback" {
    var atoms = ReasonAtoms{};
    try testing.expectEqual(@as(u64, 0), atoms.normalTerm());
    atoms.set(11, 22, 33);
    try testing.expectEqual(@as(u64, 11), atoms.normalTerm());
    try testing.expectEqual(@as(u64, 22), atoms.killedTerm());
    try testing.expectEqual(@as(u64, 33), atoms.noprocTerm());
    atoms.set(11, 22, 33); // idempotent
    try testing.expectEqual(@as(u64, 11), atoms.normalTerm());
}

test "ExitStatus: constructors set category and term" {
    const clean = ExitStatus.normalStatus(7);
    try testing.expectEqual(ReasonCategory.normal, clean.category);
    try testing.expectEqual(@as(u64, 7), clean.term);
    const crash = ExitStatus.abnormalStatus(9);
    try testing.expectEqual(ReasonCategory.abnormal, crash.category);
    try testing.expectEqual(@as(u64, 9), crash.term);
}
