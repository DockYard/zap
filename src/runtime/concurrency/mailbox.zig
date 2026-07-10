//! Vyukov intrusive MPSC mailbox for the Zap concurrency kernel.
//!
//! Phase 1 item 1.3 of `docs/concurrency-implementation-plan.md` (job
//! P1-J3), first half: the per-process mailbox from the plan §3 process
//! definition, in the canonical shape research.md §6.2 locks in — the
//! **Vyukov intrusive MPSC queue** (Akka/Netty/RxJava lineage): **one
//! atomic exchange per push**, wait-free producers, single-consumer pop.
//! The intrusive node lives in the message envelope; the queue links
//! *envelopes*, and the atomic operations touch ONLY the envelope links
//! and the queue tail — **never a payload refcount** (research.md §6.4/
//! §6.6: the in-flight envelope is message-system property owned by
//! neither process's manager; payload cells are copied by the sender
//! before the push and adopted by the receiver after the pop, so no
//! refcounted cell is ever visible to two threads).
//!
//! ## Queue shape
//!
//! ```
//!   consumer_head ─▶ E1 ─▶ E2 ─▶ … ─▶ En ◀─ producer_tail
//!   (consumer-only)  (next links, release-published)   (XCHG point)
//! ```
//!
//! An embedded `stub` envelope marks the empty queue: `producer_tail ==
//! &stub` **iff** the mailbox is linearizably empty. Push is Vyukov's
//! unchanged: `XCHG(producer_tail, envelope)` then `previous.next =
//! envelope`. Pop departs from the canonical version in exactly one
//! place — see "Draining the last envelope" below.
//!
//! ## The transient gap (research.md §6.2's documented subtlety)
//!
//! A producer suspended *between* its XCHG and its next-store leaves the
//! list temporarily unlinked: the queue is nonempty (the tail moved) but
//! the consumer cannot reach past the unlinked hop — and that pending
//! hop also blocks every envelope already linked behind it, including
//! fully-published ones. `pop` therefore distinguishes three outcomes:
//! `.envelope`, `.empty` (tail is the stub — linearizably drained), and
//! `.transient_gap` (nonempty but a producer is mid-publish). On a gap
//! it spins a small bounded number of iterations (the window is two
//! adjacent instructions in a running producer) and then returns
//! `.transient_gap` so the scheduler — not this queue — decides whether
//! to retry or reschedule; the consumer is never blocked unboundedly by
//! a preempted producer.
//!
//! ## Draining the last envelope (deliberate departure from canonical Vyukov)
//!
//! Canonical Vyukov pop re-pushes the stub *through the producer path*
//! when it reaches the last envelope, which lets a racing producer
//! observe `previous == &stub` while a real envelope is still queued —
//! making "my XCHG returned the stub" an *approximate* was-empty signal.
//! This mailbox instead **closes** the queue: it resets `stub.next` and
//! CASes `producer_tail` from the last envelope back to the stub. If the
//! CAS succeeds the queue is linearizably empty at that instant and the
//! last envelope is returned; if it fails a producer already appended
//! (gap handling proceeds as usual). Costs one CAS on the drain
//! transition only; push stays one XCHG + one store.
//!
//! ### Wake-signal exactness
//!
//! With the close-CAS, `producer_tail == &stub` holds exactly between a
//! drain and the next push, so `push` returning `previous == &stub` is
//! an EXACT empty→nonempty transition signal: among racing producers
//! exactly one XCHGs the stub out. Quiescent invariant (started empty,
//! ended empty, ≥1 push): `Σ true push returns == Σ wake callbacks ==
//! drain_closure_count` — asserted under full contention by the stress
//! test in `envelope_pool.zig`.
//!
//! The `wake_callback` seam fires on every such transition, from the
//! PRODUCER's thread, after the envelope is linked (so a woken consumer
//! can reach it). It must be cheap, non-blocking, and thread-safe.
//! Phase 1 default: no-op; P1-J4's scheduler installs the real
//! run-queue wake.
//!
//! ## Ordering guarantee: pairwise FIFO (and nothing more)
//!
//! Per research.md §6.2 (Erlang's guarantee, Elixir semantics): messages
//! from one sender to one receiver arrive in send order — a sender's
//! pushes are program-ordered and the XCHG serializes each push at one
//! list position, so the consumer, walking list order, sees every
//! sender's subsequence in order. **No global cross-sender order and no
//! causal order is promised**; the XCHG interleaving across senders is
//! arbitrary.
//!
//! ## The correlated receive + receive-mark (P5-J4 — the ONE sanctioned
//! ## deviation from pop-head-and-dispatch)
//!
//! Research §6.2's ref-trick (`recv_mark`/`recv_opt_info`) and
//! zap-concurrency-research.md §5.2/decision 7: the `call`/`Task.await`
//! machinery — and ONLY it, never surface syntax — needs to receive the
//! one message correlated with a freshly-minted unique reference,
//! skipping an arbitrarily deep backlog in O(1). Three consumer-side
//! pieces implement it:
//!
//! * **The mark** (`prepareReceiveMark`/`bindReceiveMark`): captured at
//!   ref-creation time as the NEWEST queued envelope (`producer_tail`).
//!   No message at-or-before the mark can carry a reference minted after
//!   the capture (the reply's push XCHG is totally ordered after the
//!   capture on `producer_tail`), so a correlated scan starts AT THE
//!   MARK's successor — O(1) from the mark instead of O(backlog) from
//!   the head. `prepare` runs BEFORE the ref is minted (so an
//!   immediately-fired `noproc` `DOWN` still lands after the mark);
//!   `bind` then names the ref the mark serves. One mark slot (Erlang's
//!   own limitation): a correlated receive whose ref does not match the
//!   bound ref falls back to a head scan — always sound, just O(N).
//!   INVARIANT: a `.after` mark references a STILL-QUEUED envelope;
//!   `pop` and the correlated extraction repair the mark before that
//!   envelope leaves the queue.
//!
//! * **The scan + extraction** (`takeCorrelated`): walks from the mark
//!   (or head), EXAMINES each envelope against the correlation ref (the
//!   envelope-header `correlation_ref` stamp, or a `DOWN` signal's
//!   monitor ref — the kernel never interprets payload bytes), and
//!   EXTRACTS only the match. Skipped envelopes are never unlinked:
//!   they remain queued, in order, for the steady-state receive — no
//!   loss, no reorder of the skipped prefix. Extraction unlinks an
//!   interior node with a consumer-only predecessor relink; extracting
//!   the current TAIL closes the queue back to the predecessor with the
//!   same reset-then-CAS discipline as the drain closure below (the
//!   predecessor plays the stub's role).
//!
//! * **The any-push wake flag** (`armCorrelatedWake`): the wake seam
//!   fires only on empty→nonempty transitions, but a correlated waiter
//!   parks with a NONEMPTY (skipped-backlog) mailbox, so `push` also
//!   fires the seam whenever `correlated_wake_armed` is set. Arming is
//!   race-free without any new fence in `push`: the consumer stores the
//!   flag, then CASes `producer_tail` against the last envelope its scan
//!   examined (a no-op value write). If the CAS succeeds, the flag store
//!   is release-published into `producer_tail`'s release sequence — every
//!   later push's acq_rel XCHG synchronizes-with it and reads the flag as
//!   set; if it fails, the tail already moved and the consumer rescans
//!   instead of parking. Cost on the non-correlated hot path: one
//!   monotonic load per push of a cache line the XCHG already owns.
//!
//! ## Memory ordering (the complete atomics inventory)
//!
//! | atomic | op / ordering | why |
//! |---|---|---|
//! | `producer_tail` | push: `swap .acq_rel` | *release:* publishes the pushing thread's envelope initialization (incl. `next = null`) to the producer that XCHGs after it — which is what makes that predecessor-write of `next = null` happen-before the successor's link-store into the same field (RMWs on one atomic are totally ordered; acquire/release pairs adjacent pushes). *acquire:* symmetric half of the same pairing. |
//! | `producer_tail` | pop empty-check: `load .acquire`; close: `cmpxchgStrong .acq_rel/.acquire` | the close-CAS's *release* publishes the consumer's `stub.next = null` reset to the next producer that XCHGs the stub out (which then link-stores into `stub.next`); a stale-empty read is benign — the transitioning producer fires the wake seam. |
//! | `Envelope.next` | producer link-store: `.release`; consumer loads: `.acquire` | THE payload-publication edge: the sender's fragment writes happen-before the link-store, so the consumer that acquires the link sees the fully-written envelope. This is the edge that lets payload refcounts stay non-atomic. |
//! | `approximate_depth` | `fetchAdd`/`fetchSub .monotonic` | observability only (plan 1.6); documented approximate, never load-bearing. |
//!
//! Consumer-only state (`consumer_head`, `drain_closure_count`) is
//! deliberately non-atomic: exactly one consumer — the owning process —
//! may call `pop` (single-consumer discipline, same owner-only posture
//! as every kernel structure).
//!
//! ## Teardown protocol (seam for 1.4/J4)
//!
//! On process exit the owner drains its mailbox (`pop` until `.empty`,
//! bounded-retrying `.transient_gap`), frees every envelope back to the
//! pool (`envelope_pool.free` — dead-lettering the payloads), and only
//! then tears the PCB down. Unregistering the pid FIRST (`process.zig`)
//! makes new senders dead-letter. A sender that already passed lookup —
//! the borrowed-PCB window `pid_table.zig` defers to Phase 4 — is closed
//! by the scheduler's cross-thread send grace period: BEFORE the drain,
//! teardown closes the mailbox to not-yet-pinned senders and waits for
//! every in-flight send to finish its push (`scheduler.zig`
//! `ProcessRecord.beginSend`/`endSend`/`closeAndQuiesce`), so no push can
//! land after the drain. Without it a push racing the drain orphaned its
//! envelope — and the sender's abandoned page — the message-vs-timer
//! envelope-page leak.
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so
//! this file has no special compiler requirement; see `concurrency.zig`
//! for the kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");
const envelope_pool = @import("envelope_pool.zig");
const signal_module = @import("signal.zig");

/// The opaque payload reference an envelope carries — the Phase 2 seam.
/// Phase 1 treats these three words as opaque bytes: tests stamp them
/// directly, nothing in the kernel interprets them. Phase 2's deep-copy
/// walker (plan item 2.4) populates them with the detachable fragment
/// it copies the message graph into: `payload_pointer`/
/// `payload_byte_length` describe the fragment bytes and
/// `payload_origin_page` names the pool page(s) those bytes were carved
/// from so receive-side adoption can account them. Payload cells are
/// NEVER touched through this struct by the mailbox or the pool — the
/// non-atomic-refcount invariant (module doc) depends on that.
pub const Fragment = struct {
    /// First byte of the detached payload fragment (null until Phase 2
    /// populates it, or for payload-less control messages). For a MOVED
    /// payload (`moved_reclaim != null`) this is the ROOT of a value graph
    /// re-parented from the sender uncopied — not a byte blob.
    payload_pointer: ?[*]const u8 = null,
    /// Fragment length in bytes.
    payload_byte_length: usize = 0,
    /// Pool page the payload bytes were carved from (Phase 2 seam;
    /// distinct from `Envelope.origin_page`, which is the page the
    /// ENVELOPE HEADER itself lives in).
    payload_origin_page: ?*envelope_pool.EnvelopePage = null,
    /// The same-model O(1) region-move send (plan item 6.1, P3-J5). When
    /// non-null, `payload_pointer` is a value graph MOVED from the sender
    /// (detached from its heap, uncopied), and this is the leak-exactness
    /// reclaim to run IF the envelope is freed WITHOUT the receiver adopting
    /// the graph (dead-letter, or a mailbox drained at receiver teardown). The
    /// receive path clears the fragment once it takes ownership, so a delivered
    /// move is never reclaimed. Its presence is also the moved-vs-copied
    /// discriminator. Opaque to the mailbox and pool — the kernel never
    /// interprets the payload, only invokes this caller-supplied hook.
    moved_reclaim: ?MovedReclaimFn = null,
    /// Signal discriminator (P5-J1, `signal.zig`): `.none` for an ordinary user
    /// message, `.exit`/`.down` for a kernel-synthesized exit/`DOWN` signal
    /// merged into the mailbox for a trapping/monitoring process. When non-`.none`
    /// the payload is a `signal.SignalPayload` (a ledger block, freed by the
    /// receiver's ordinary `zap_proc_envelope_free`); the receive lowering reads
    /// this to tell a signal from a user message.
    signal_kind: signal_module.SignalKind = .none,
    /// Correlation token (P5-J4, research §6.2's ref-trick): the unique
    /// reference stamped by the INTERNAL correlated send
    /// (`zap_proc_send_correlated` — the `call`/`Task` reply path) so the
    /// receiver's correlated receive matches this envelope by a header
    /// compare, never by interpreting payload bytes. Zero for every
    /// ordinary (uncorrelated) send.
    correlation_ref: u64 = 0,
};

/// Reclaim hook for an un-adopted moved payload (see `Fragment.moved_reclaim`).
/// Given the moved graph's root pointer, returns its backing to the OS.
pub const MovedReclaimFn = *const fn (payload_pointer: [*]const u8) callconv(.c) void;

/// One in-flight message: the intrusive Vyukov node plus the opaque
/// payload fragment reference. Envelope headers are carved from
/// `envelope_pool.EnvelopePage`s and are message-system property from
/// `Handle.allocate` until `envelope_pool.free` — owned by NEITHER
/// process's memory manager (research.md §6.6).
pub const Envelope = struct {
    /// Intrusive queue link — the ONLY field the mailbox mutates. Dead
    /// once the envelope is popped; the pool reuses it as the
    /// recycled-slot link, and `push` re-nulls it.
    next: std.atomic.Value(?*Envelope),
    /// The pool page this envelope header was carved from (set by the
    /// pool at allocation; null only for a mailbox's embedded stub,
    /// which is never freed).
    origin_page: ?*envelope_pool.EnvelopePage,
    /// The opaque payload reference (Phase 2 seam — see `Fragment`).
    fragment: Fragment,
};

/// Wake seam callback (module doc, "Wake-signal exactness"): invoked by
/// `push`, on the producer's thread, after linking the envelope that
/// transitioned the mailbox empty→nonempty. Must be cheap, non-blocking,
/// and thread-safe.
pub const WakeCallback = *const fn (wake_context: ?*anyopaque) void;

/// Phase 1 default wake callback: nothing to wake yet (P1-J4's scheduler
/// replaces it).
pub fn noopWakeCallback(wake_context: ?*anyopaque) void {
    _ = wake_context;
}

/// Result of one `pop` attempt — see the module doc's transient-gap
/// section for why three outcomes exist.
pub const PopOutcome = union(enum) {
    /// The oldest deliverable envelope. The consumer now owns it and
    /// must eventually return it via `envelope_pool.free`.
    envelope: *Envelope,
    /// Linearizably empty at the observation point.
    empty,
    /// Nonempty, but a producer sitting between its XCHG and its
    /// next-store makes the head (or the whole queue) unreachable; the
    /// bounded in-`pop` spin did not see the link land. Retry later —
    /// the pending store belongs to a RUNNING producer and lands within
    /// two instructions unless that producer was preempted.
    transient_gap,
};

/// Where a correlated receive starts scanning (P5-J4 receive-mark; module
/// doc, "The correlated receive + receive-mark"). Consumer-only state.
pub const ReceiveMark = union(enum) {
    /// No mark armed: a correlated scan starts at the head.
    none,
    /// The queue was EMPTY at prepare time (or the marked envelope has
    /// since been delivered): every queued envelope is at-or-after the
    /// mark position, so scan from the head — same skip guarantee, the
    /// backlog to skip is simply gone.
    from_head,
    /// Scan from this envelope's SUCCESSOR: it was the newest queued
    /// envelope at prepare time, so nothing at-or-before it can carry a
    /// ref minted after the capture. INVARIANT: still queued (`pop` and
    /// the correlated extraction repair the mark before delivering it).
    after: *Envelope,
};

/// Which envelopes a correlated scan matches (P5-J4; the `_any` kinds are
/// P5-R1's signal-aware receive split).
pub const CorrelatedMatchKind = enum {
    /// A correlated USER reply (`Fragment.correlation_ref == ref`) OR the
    /// monitor `DOWN` carrying `ref` — the `call`/`Task.await` wait.
    user_or_down,
    /// ONLY the monitor `DOWN` carrying `ref` — the demonitor-flush path
    /// (a late user reply must stay queued and surface through the
    /// steady-state receive's dead-letter accounting, never be silently
    /// eaten by a flush).
    down_only,
    /// ANY signal envelope (a trapped exit or a `DOWN`), `ref` ignored
    /// (pass 0) — the `await_signal` scan: user messages are skipped and
    /// stay queued, in order, for the steady-state receive.
    signal_any,
    /// ANY ordinary user envelope (`signal_kind == .none`), `ref` ignored
    /// (pass 0) — the steady-state receive's scan: signal envelopes are
    /// skipped and stay queued, in order, for `await_signal` (Erlang: an
    /// unmatched trapped exit sits in the mailbox; it is never decoded as
    /// a user message).
    user_any,
};

/// One `takeCorrelated` attempt (consumer-only).
pub const CorrelatedScanOutcome = union(enum) {
    /// The matching envelope, EXTRACTED from the queue — the caller owns
    /// it (and must eventually free it). Every skipped envelope remains
    /// queued, in order.
    matched: *Envelope,
    /// No match anywhere in the reachable queue; the payload is the LAST
    /// queued envelope the scan examined (the queue tail at scan end), or
    /// the embedded stub when the queue is empty. Hand it to
    /// `armCorrelatedWake`, and back to the next `takeCorrelated` as
    /// `resume_after` so the rescan only walks NEW arrivals.
    exhausted: *Envelope,
    /// A producer is mid-publish past the last reachable envelope (the
    /// tail moved but the link is not visible after the bounded spin):
    /// more input is arriving, so do not park — yield and rescan from the
    /// payload envelope. Mirrors `PopOutcome.transient_gap`.
    publish_pending: *Envelope,
    /// The queue-extraction step itself hit a mid-publish window (the
    /// matched envelope is the last node, the close-CAS failed, and the
    /// appending producer's link did not land within the spin bound). The
    /// matched envelope REMAINS QUEUED; yield and rescan (the same
    /// deterministic match is found again). Mirrors `PopOutcome.transient_gap`.
    extraction_pending,
};

/// One non-consuming `scanForMatch` probe (consumer-only) — the
/// signal-aware `receive … after` wait (P5-R1): "is a matching envelope
/// queued?" without extracting it.
pub const ScanProbeOutcome = union(enum) {
    /// A matching envelope is queued; a following consuming scan
    /// (`takeCorrelated`) finds it.
    found,
    /// No match anywhere in the reachable queue; the payload is the LAST
    /// queued envelope the probe examined (the embedded stub when empty).
    /// Hand it to `armCorrelatedWake` and back as `resume_after` so the
    /// re-probe only walks NEW arrivals.
    exhausted: *Envelope,
    /// A producer is mid-publish past the last reachable envelope: more
    /// input is arriving — yield and re-probe from the payload envelope.
    /// Mirrors `PopOutcome.transient_gap`.
    publish_pending: *Envelope,
};

/// Result of a non-consuming `Mailbox.peek` (the `receive … after`
/// timeout path). Mirrors `PopOutcome` minus the envelope payload — the
/// message, if any, is left in place for a following `pop`.
pub const PeekOutcome = enum {
    /// A deliverable envelope is at the head; a following `pop` returns it.
    available,
    /// Linearizably empty at the observation point.
    empty,
    /// A producer is mid-publish at the boundary (see `PopOutcome.transient_gap`).
    transient_gap,
};

/// How many spin iterations `pop` grants a mid-publish producer before
/// giving up and reporting `.transient_gap`. The window is two adjacent
/// instructions, so a small bound resolves every non-preempted case;
/// beyond that, spinning would burn the consumer's quantum on a
/// preempted producer's behalf.
const transient_gap_spin_limit: u32 = 64;

/// Whether the deterministic-interleaving test instrumentation is
/// compiled in. Test builds only — the hook, its field, and its call
/// site all vanish from non-test builds.
pub const enable_test_instrumentation = builtin.is_test;

/// Test-only producer instrumentation (compiled out of non-test builds):
/// `between_exchange_and_link` runs on the producer's thread AFTER its
/// XCHG on `producer_tail` and BEFORE its next-store — exactly the
/// transient-gap window — letting a test park a producer there and
/// exercise the gap DETERMINISTICALLY (see the gap tests below).
pub const PushInstrumentation = if (enable_test_instrumentation) struct {
    /// Hook invoked in the gap window; null (default) disables.
    between_exchange_and_link: ?*const fn (instrumentation_context: ?*anyopaque, envelope: *Envelope) void = null,
    /// Opaque context handed to the hook.
    instrumentation_context: ?*anyopaque = null,
} else struct {};

/// The per-process mailbox: Vyukov intrusive MPSC over `Envelope`s. One
/// per process, embedded in the PCB (`process.zig`). PINNED: the queue's
/// empty state references the embedded `stub`, so a Mailbox must never
/// move after `init` — the PCB guarantees this (it is at its final
/// address from birth; see `ProcessControlBlock.init`).
pub const Mailbox = struct {
    /// Producer end: the most recently pushed envelope, or `&stub` when
    /// the mailbox is empty. The push XCHG lives here.
    producer_tail: std.atomic.Value(*Envelope),
    /// Consumer end: the next envelope to deliver, or `&stub` at the
    /// empty boundary. Consumer-only; non-atomic by design.
    consumer_head: *Envelope,
    /// Approximate depth for observability (plan item 1.6): incremented
    /// before the push XCHG, decremented on successful pop, so it may
    /// momentarily over-count in-flight pushes. DOCUMENTED APPROXIMATE —
    /// exact only at quiescence; never used for control flow.
    approximate_depth: std.atomic.Value(usize),
    /// Number of times the consumer closed the queue to empty (the
    /// drain-transition CAS succeeded). Consumer-only observability;
    /// with the wake counters it forms the quiescent exactness invariant
    /// (module doc, "Wake-signal exactness").
    drain_closure_count: usize,
    /// Wake seam (module doc). Installed before the mailbox is shared;
    /// single-store publication.
    wake_callback: WakeCallback,
    /// Opaque context handed to `wake_callback`.
    wake_context: ?*anyopaque,
    /// The correlated receive's any-push wake request (module doc, "The
    /// correlated receive + receive-mark"). Written ONLY by the consumer
    /// (armed via `armCorrelatedWake`'s release-sequence protocol, cleared
    /// on resume); read by every producer after its push XCHG. While set,
    /// `push` fires the wake seam on EVERY push, not only the
    /// empty→nonempty transition.
    correlated_wake_armed: std.atomic.Value(bool),
    /// The receive-mark (P5-J4). Consumer-only.
    receive_mark: ReceiveMark,
    /// The unique ref the mark serves, bound by `bindReceiveMark` after
    /// the ref is minted; zero = unbound. A correlated scan uses the mark
    /// only when its ref matches — a mismatch falls back to a head scan
    /// (sound, just unskipped). Consumer-only.
    receive_mark_ref: u64,
    /// Cumulative count of envelopes EXAMINED by correlated scans — the
    /// R8 operation-count telemetry proving the O(1)-from-mark claim (a
    /// 10k-backlog correlated receive that starts at the mark examines a
    /// handful of envelopes, not 10k). Consumer-only observability; never
    /// control flow.
    correlated_scan_visit_total: u64,
    /// Test-only producer instrumentation (zero-sized outside tests).
    push_instrumentation: PushInstrumentation,
    /// The embedded stub envelope marking the empty queue. Never pushed
    /// by producers, never freed, never carries a payload.
    stub: Envelope,

    /// Initialize in place (the mailbox is pinned from this call on —
    /// see the type doc). Empty queue, zero depth, no-op wake seam.
    pub fn init(mailbox: *Mailbox) void {
        mailbox.stub = .{
            .next = .init(null),
            .origin_page = null,
            .fragment = .{},
        };
        mailbox.producer_tail = .init(&mailbox.stub);
        mailbox.consumer_head = &mailbox.stub;
        mailbox.approximate_depth = .init(0);
        mailbox.drain_closure_count = 0;
        mailbox.wake_callback = noopWakeCallback;
        mailbox.wake_context = null;
        mailbox.correlated_wake_armed = .init(false);
        mailbox.receive_mark = .none;
        mailbox.receive_mark_ref = 0;
        mailbox.correlated_scan_visit_total = 0;
        mailbox.push_instrumentation = .{};
    }

    /// Producer side — callable from any thread, WAIT-FREE (one XCHG,
    /// one store, no loops, no CAS). Enqueues `envelope` and returns
    /// whether this push transitioned the mailbox empty→nonempty — the
    /// exact wake signal (module doc); the wake seam has already fired
    /// when this returns true.
    pub fn push(mailbox: *Mailbox, envelope: *Envelope) bool {
        std.debug.assert(envelope != &mailbox.stub);
        envelope.next.store(null, .monotonic);
        _ = mailbox.approximate_depth.fetchAdd(1, .monotonic);

        const previous_tail = mailbox.producer_tail.swap(envelope, .acq_rel);
        mailbox.runBetweenExchangeAndLinkInstrumentation(envelope);
        // THE publication edge: everything the producer wrote into the
        // envelope happens-before this store (module doc ordering table).
        previous_tail.next.store(envelope, .release);

        const transitioned_from_empty = previous_tail == &mailbox.stub;
        // The correlated-waiter wake (module doc): while the flag is set,
        // EVERY push wakes — a correlated waiter parks with a nonempty
        // (skipped-backlog) mailbox, so the empty→nonempty transition
        // cannot be its wake source. Visibility of a `true` flag is
        // guaranteed by the arm protocol's release sequence on
        // `producer_tail` (the swap above acquires it); the load itself
        // is a monotonic read of a line the XCHG already owns.
        const correlated_wake_requested = mailbox.correlated_wake_armed.load(.monotonic);
        if (transitioned_from_empty or correlated_wake_requested) {
            mailbox.wake_callback(mailbox.wake_context);
        }
        return transitioned_from_empty;
    }

    /// Consumer side — the owning process ONLY (single-consumer
    /// discipline; consumer state is non-atomic). Returns the oldest
    /// deliverable envelope, `.empty`, or `.transient_gap` (module doc).
    pub fn pop(mailbox: *Mailbox) PopOutcome {
        const stub_envelope = &mailbox.stub;
        var head = mailbox.consumer_head;

        if (head == stub_envelope) {
            // At the empty boundary: the first real envelope hangs off
            // the stub.
            const first = stub_envelope.next.load(.acquire) orelse first: {
                if (mailbox.producer_tail.load(.acquire) == stub_envelope) return .empty;
                // Tail moved but the stub link hasn't landed: a producer
                // is mid-publish right at the boundary.
                break :first spinForNextLink(stub_envelope) orelse return .transient_gap;
            };
            mailbox.consumer_head = first;
            head = first;
        }

        // `head` is a real envelope; delivering it requires moving
        // consumer_head off it first.
        if (head.next.load(.acquire)) |successor| {
            mailbox.consumer_head = successor;
            return mailbox.deliver(head);
        }

        // head.next is null: `head` is the last envelope — unless a
        // producer behind it is mid-publish. Try to CLOSE the queue
        // (module doc, "Draining the last envelope"): reset the stub
        // link BEFORE the CAS can make the stub producer-reachable
        // (the CAS's release publishes the reset).
        stub_envelope.next.store(null, .monotonic);
        if (mailbox.producer_tail.cmpxchgStrong(head, stub_envelope, .acq_rel, .acquire) == null) {
            // Closed: linearizably empty as of the CAS.
            mailbox.consumer_head = stub_envelope;
            mailbox.drain_closure_count += 1;
            return mailbox.deliver(head);
        }

        // Close failed: the tail already moved past `head`, so a
        // producer appended behind it — its link lands momentarily.
        const successor = head.next.load(.acquire) orelse
            (spinForNextLink(head) orelse return .transient_gap);
        mailbox.consumer_head = successor;
        return mailbox.deliver(head);
    }

    /// Consumer side — the owning process ONLY — whether a deliverable
    /// envelope is at the head, WITHOUT consuming it. The `receive … after`
    /// timeout path (`ProcessContext.receiveWaitTimeout`) uses this to
    /// distinguish message-vs-timeout while leaving the message for a
    /// following `pop`. Mirrors `pop`'s boundary handling exactly, so no
    /// false `.empty` can be reported while a producer is mid-publish.
    pub fn peek(mailbox: *Mailbox) PeekOutcome {
        const stub_envelope = &mailbox.stub;
        // `consumer_head` off the stub is always a real, not-yet-delivered
        // envelope (`pop` advances it past each delivery).
        if (mailbox.consumer_head != stub_envelope) return .available;

        // At the empty boundary: the first real envelope, if any, hangs off
        // the stub.
        if (stub_envelope.next.load(.acquire) != null) return .available;
        if (mailbox.producer_tail.load(.acquire) == stub_envelope) return .empty;
        // Tail moved but the stub link has not landed: a producer is
        // mid-publish right at the boundary.
        return if (spinForNextLink(stub_envelope) != null) .available else .transient_gap;
    }

    /// Approximate number of queued envelopes (see `approximate_depth`).
    pub fn depth(mailbox: *const Mailbox) usize {
        return mailbox.approximate_depth.load(.monotonic);
    }

    fn deliver(mailbox: *Mailbox, envelope: *Envelope) PopOutcome {
        mailbox.repairMarkBeforeDelivery(envelope, null);
        _ = mailbox.approximate_depth.fetchSub(1, .monotonic);
        return .{ .envelope = envelope };
    }

    /// Maintain the `.after`-mark invariant (module doc): the marked
    /// envelope must never leave the queue while the mark references it.
    /// `pop` delivers the HEAD, so when the marked envelope is delivered
    /// every remaining envelope is younger than the mark — `from_head`
    /// preserves the skip guarantee exactly. A correlated EXTRACTION can
    /// remove the marked envelope from mid-queue (a head-scan fallback
    /// matching it); repairing to its still-queued `predecessor` is the
    /// conservative-older repair (a too-old mark only widens the scan,
    /// never skips a matchable message).
    fn repairMarkBeforeDelivery(mailbox: *Mailbox, envelope: *Envelope, predecessor: ?*Envelope) void {
        if (mailbox.receive_mark != .after) return;
        if (mailbox.receive_mark.after != envelope) return;
        if (predecessor) |previous| {
            if (previous != &mailbox.stub) {
                mailbox.receive_mark = .{ .after = previous };
                return;
            }
        }
        mailbox.receive_mark = .from_head;
    }

    // -------------------------------------------------------------------------
    // The correlated receive (P5-J4 — module doc, "The correlated receive +
    // receive-mark"). Consumer-only, like every consumer-side entry point.
    // -------------------------------------------------------------------------

    /// Capture the receive-mark position: the newest queued envelope at
    /// this instant (or `from_head` when empty). MUST run BEFORE the
    /// correlation ref is minted — a monitor on an already-dead target
    /// fires its `noproc` `DOWN` during minting, and that `DOWN` must land
    /// AFTER the mark to be scannable. Overwrites any previous mark (one
    /// slot — the Erlang `recv_mark` limitation; a mismatched correlated
    /// receive falls back to a head scan).
    pub fn prepareReceiveMark(mailbox: *Mailbox) void {
        const tail = mailbox.producer_tail.load(.monotonic);
        mailbox.receive_mark = if (tail == &mailbox.stub) .from_head else .{ .after = tail };
        mailbox.receive_mark_ref = 0;
    }

    /// Bind the prepared mark to the freshly-minted `ref` it serves.
    /// Pushes that land between `prepareReceiveMark` and this bind sit
    /// AFTER the mark position, so they stay scannable — the two-step
    /// protocol has no gap.
    pub fn bindReceiveMark(mailbox: *Mailbox, ref: u64) void {
        if (mailbox.receive_mark == .none) return;
        mailbox.receive_mark_ref = ref;
    }

    /// Whether `envelope` is correlated with `ref` under `match_kind`:
    /// a user reply stamped `correlation_ref == ref`, or the monitor
    /// `DOWN` whose signal payload carries `ref` — or, for the `_any`
    /// kinds, a class match on the envelope's `signal_kind` alone.
    /// Header/payload-struct compares only — the kernel never interprets
    /// user payload bytes.
    fn envelopeMatchesCorrelation(envelope: *const Envelope, ref: u64, match_kind: CorrelatedMatchKind) bool {
        switch (match_kind) {
            .signal_any => return envelope.fragment.signal_kind != .none,
            .user_any => return envelope.fragment.signal_kind == .none,
            .user_or_down, .down_only => {},
        }
        switch (envelope.fragment.signal_kind) {
            .none => {
                if (match_kind == .down_only) return false;
                return envelope.fragment.correlation_ref == ref;
            },
            .down => {
                const payload: *const signal_module.SignalPayload =
                    @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
                return payload.ref == ref;
            },
            .exit => return false,
        }
    }

    /// One correlated scan-and-extract attempt for `ref` (consumer-only;
    /// blocking/parking policy lives in the scheduler). Scans from
    /// `resume_after` when non-null (a previous attempt's `exhausted`/
    /// `publish_pending` position — every envelope at-or-before it was
    /// already examined and stays queued), else from the mark when it is
    /// armed for `ref`, else from the head. Skipped envelopes are never
    /// unlinked; only the match is extracted. See `CorrelatedScanOutcome`.
    pub fn takeCorrelated(
        mailbox: *Mailbox,
        ref: u64,
        match_kind: CorrelatedMatchKind,
        resume_after: ?*Envelope,
    ) CorrelatedScanOutcome {
        // Ref 0 is the "uncorrelated" stamp every ordinary send carries; a
        // ref-keyed scan for it would match arbitrary user messages. The
        // class-match `_any` kinds ignore the ref and pass 0.
        std.debug.assert(ref != 0 or match_kind == .signal_any or match_kind == .user_any);
        const stub_envelope = &mailbox.stub;

        // The anchor: the queued envelope whose successor opens the
        // unscanned region — or null, meaning the region starts AT
        // `consumer_head` itself (a head scan with a real head). The mark
        // is consulted only for a nonzero ref: `receive_mark_ref == 0`
        // means "prepared but unbound", which a ref-0 class scan must
        // never mistake for its own mark.
        var anchor: ?*Envelope = null;
        var start_at_head = false;
        if (resume_after) |resumed| {
            anchor = resumed;
        } else if (ref != 0 and mailbox.receive_mark == .after and mailbox.receive_mark_ref == ref) {
            anchor = mailbox.receive_mark.after;
        } else {
            start_at_head = true;
        }
        if (start_at_head) {
            if (mailbox.consumer_head == stub_envelope) {
                anchor = stub_envelope;
            } else {
                anchor = null;
            }
        }

        // Establish (previous, current) for the walk.
        var previous: ?*Envelope = undefined;
        var current: *Envelope = undefined;
        if (anchor) |anchored| {
            const first = anchored.next.load(.acquire) orelse first: {
                if (mailbox.producer_tail.load(.acquire) == anchored) {
                    return .{ .exhausted = anchored };
                }
                // The tail moved past the anchor but the link is not
                // visible: a producer is mid-publish right at the scan
                // boundary. Grant it the pop-path spin grace.
                break :first spinForNextLink(anchored) orelse
                    return .{ .publish_pending = anchored };
            };
            previous = anchored;
            current = first;
        } else {
            previous = null;
            current = mailbox.consumer_head;
        }

        while (true) {
            // The R8 telemetry counts REF-CORRELATED scan work only (the
            // `call`/`Task.await` O(1)-from-mark proof); the `_any` class
            // scans of the steady-state receive / `await_signal` would
            // drown it.
            if (match_kind == .user_or_down or match_kind == .down_only) {
                mailbox.correlated_scan_visit_total += 1;
            }
            if (envelopeMatchesCorrelation(current, ref, match_kind)) {
                const extracted = mailbox.extractCorrelated(previous, current) orelse
                    return .extraction_pending;
                return .{ .matched = extracted };
            }
            const successor = current.next.load(.acquire) orelse {
                if (mailbox.producer_tail.load(.acquire) == current) {
                    return .{ .exhausted = current };
                }
                const linked = spinForNextLink(current) orelse
                    return .{ .publish_pending = current };
                previous = current;
                current = linked;
                continue;
            };
            previous = current;
            current = successor;
        }
    }

    /// Non-consuming twin of `takeCorrelated` for the class-match kinds:
    /// walk the reachable queue for an envelope matching `match_kind` and
    /// report WHETHER one is queued, leaving everything in place — the
    /// signal-aware `receive … after` wait probes for `.user_any` with
    /// this (a queued signal alone must not satisfy the wait; the message
    /// it reports stays queued for the following consuming receive).
    /// Scans from `resume_after` when non-null (every envelope at-or-
    /// before it was already examined and unmatched), else from the head.
    /// Never consults the receive-mark (class scans are ref-less).
    pub fn scanForMatch(
        mailbox: *Mailbox,
        ref: u64,
        match_kind: CorrelatedMatchKind,
        resume_after: ?*Envelope,
    ) ScanProbeOutcome {
        std.debug.assert(ref != 0 or match_kind == .signal_any or match_kind == .user_any);
        const stub_envelope = &mailbox.stub;

        // The anchor: the queued envelope whose successor opens the
        // unexamined region — `resume_after`, or the embedded stub for a
        // head probe of an empty-headed queue; null means the region
        // starts AT `consumer_head` itself (a head probe with a real head).
        const anchor: ?*Envelope = resume_after orelse
            (if (mailbox.consumer_head == stub_envelope) stub_envelope else null);

        var current: *Envelope = undefined;
        if (anchor) |anchored| {
            current = anchored.next.load(.acquire) orelse first: {
                if (mailbox.producer_tail.load(.acquire) == anchored) {
                    return .{ .exhausted = anchored };
                }
                // The tail moved past the anchor but the link is not
                // visible: a producer is mid-publish at the probe
                // boundary. Grant it the pop-path spin grace.
                break :first spinForNextLink(anchored) orelse
                    return .{ .publish_pending = anchored };
            };
        } else {
            current = mailbox.consumer_head;
        }

        while (true) {
            if (envelopeMatchesCorrelation(current, ref, match_kind)) return .found;
            const successor = current.next.load(.acquire) orelse {
                if (mailbox.producer_tail.load(.acquire) == current) {
                    return .{ .exhausted = current };
                }
                const linked = spinForNextLink(current) orelse
                    return .{ .publish_pending = current };
                current = linked;
                continue;
            };
            current = successor;
        }
    }

    /// Extract `matched` from the queue, leaving every other envelope in
    /// place and in order. `previous` is the queued envelope linking to
    /// `matched` (the embedded stub at the head boundary), or null when
    /// `matched` IS `consumer_head` — that case is exactly `pop`'s head
    /// delivery. Returns null when the matched envelope is the current
    /// tail, the close-CAS lost to an appending producer, AND that
    /// producer's link did not land within the spin bound — the matched
    /// envelope then REMAINS QUEUED (nothing is torn down) and the caller
    /// retries after a yield.
    fn extractCorrelated(mailbox: *Mailbox, previous: ?*Envelope, matched: *Envelope) ?*Envelope {
        const stub_envelope = &mailbox.stub;

        if (previous) |predecessor| {
            if (matched.next.load(.acquire)) |successor| {
                // Interior unlink: `predecessor.next` is dead to every
                // producer (only the CURRENT tail's `next` is ever
                // producer-written, and `matched` sits after
                // `predecessor`), so a consumer-only monotonic store
                // suffices.
                predecessor.next.store(successor, .monotonic);
                return mailbox.finishExtraction(matched, predecessor);
            }
            // `matched` is the last reachable node: close the queue back
            // to `predecessor` with the drain-closure discipline (reset
            // the new tail's link BEFORE the CAS so the CAS's release
            // publishes it to the next producer that XCHGs it out).
            predecessor.next.store(null, .monotonic);
            if (mailbox.producer_tail.cmpxchgStrong(matched, predecessor, .acq_rel, .acquire) == null) {
                if (predecessor == stub_envelope) {
                    // The queue closed to EMPTY (the head-boundary shape
                    // `stub → matched`): this is exactly `pop`'s drain
                    // closure, so keep the wake-exactness ledger honest.
                    mailbox.consumer_head = stub_envelope;
                    mailbox.drain_closure_count += 1;
                }
                return mailbox.finishExtraction(matched, predecessor);
            }
            // Close lost: a producer appended behind `matched`. Its link
            // lands within two producer instructions unless preempted.
            const successor = matched.next.load(.acquire) orelse
                spinForNextLink(matched) orelse {
                // Restore the chain (consumer-only field, no racing
                // writer) and let the caller retry after a yield.
                predecessor.next.store(matched, .monotonic);
                return null;
            };
            predecessor.next.store(successor, .monotonic);
            return mailbox.finishExtraction(matched, predecessor);
        }

        // Head extraction: `matched == consumer_head` — mirror `pop`'s
        // delivery of the head exactly.
        std.debug.assert(matched == mailbox.consumer_head);
        if (matched.next.load(.acquire)) |successor| {
            mailbox.consumer_head = successor;
            return mailbox.finishExtraction(matched, null);
        }
        stub_envelope.next.store(null, .monotonic);
        if (mailbox.producer_tail.cmpxchgStrong(matched, stub_envelope, .acq_rel, .acquire) == null) {
            mailbox.consumer_head = stub_envelope;
            mailbox.drain_closure_count += 1;
            return mailbox.finishExtraction(matched, null);
        }
        const successor = matched.next.load(.acquire) orelse
            spinForNextLink(matched) orelse return null;
        mailbox.consumer_head = successor;
        return mailbox.finishExtraction(matched, null);
    }

    fn finishExtraction(mailbox: *Mailbox, matched: *Envelope, predecessor: ?*Envelope) *Envelope {
        mailbox.repairMarkBeforeDelivery(matched, predecessor);
        _ = mailbox.approximate_depth.fetchSub(1, .monotonic);
        return matched;
    }

    /// Arm the any-push wake for a correlated waiter about to park
    /// (module doc). `last_examined` is the scan's `exhausted` payload —
    /// the queue tail as the scan saw it (the embedded stub when empty).
    /// Returns true when armed: the flag store is release-published into
    /// `producer_tail`'s release sequence by a successful no-op CAS, so
    /// every LATER push's acq_rel XCHG synchronizes-with it and observes
    /// the flag — no fence added to the push hot path, no lost wake.
    /// Returns false (flag cleared) when the tail already moved past
    /// `last_examined`: a message arrived after the scan — rescan instead
    /// of parking.
    pub fn armCorrelatedWake(mailbox: *Mailbox, last_examined: *Envelope) bool {
        mailbox.correlated_wake_armed.store(true, .monotonic);
        if (mailbox.producer_tail.cmpxchgStrong(last_examined, last_examined, .acq_rel, .acquire) == null) {
            return true;
        }
        mailbox.correlated_wake_armed.store(false, .monotonic);
        return false;
    }

    /// Clear the any-push wake request (the correlated waiter resumed).
    /// Consumer-only; producers that already read `true` fire at most one
    /// redundant wake, which the park handshake absorbs.
    pub fn disarmCorrelatedWake(mailbox: *Mailbox) void {
        mailbox.correlated_wake_armed.store(false, .monotonic);
    }

    /// Cumulative correlated-scan visit count (R8 telemetry; see the
    /// field doc).
    pub fn correlatedScanVisits(mailbox: *const Mailbox) u64 {
        return mailbox.correlated_scan_visit_total;
    }

    /// Bounded wait for a mid-publish producer's link store (module doc,
    /// transient gap). Returns the linked successor, or null if the
    /// bound expired.
    fn spinForNextLink(envelope: *Envelope) ?*Envelope {
        var spin_count: u32 = 0;
        while (spin_count < transient_gap_spin_limit) : (spin_count += 1) {
            std.atomic.spinLoopHint();
            if (envelope.next.load(.acquire)) |linked| return linked;
        }
        return null;
    }

    inline fn runBetweenExchangeAndLinkInstrumentation(mailbox: *Mailbox, envelope: *Envelope) void {
        if (comptime enable_test_instrumentation) {
            if (mailbox.push_instrumentation.between_exchange_and_link) |instrument| {
                instrument(mailbox.push_instrumentation.instrumentation_context, envelope);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test-support monotonic clock: the fork's std has no `std.time.Timer`;
/// `std.c.clock_gettime` is the E9-spike precedent and `std.c` is
/// already a kernel-test dependency (stack_pool).
pub fn testMonotonicNowNanoseconds() u64 {
    var now: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &now) == 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Wall-clock bound so a broken queue fails a test instead of hanging it.
pub const TestDeadline = struct {
    deadline_nanoseconds: u64,

    pub fn init(timeout_nanoseconds: u64) TestDeadline {
        return .{ .deadline_nanoseconds = testMonotonicNowNanoseconds() + timeout_nanoseconds };
    }

    pub fn expired(deadline: TestDeadline) bool {
        return testMonotonicNowNanoseconds() > deadline.deadline_nanoseconds;
    }
};

/// Minimal test event built on an atomic flag (the fork std has no
/// ResetEvent; a spin-wait is fine for the short, deterministic windows
/// these tests create).
const TestEvent = struct {
    signaled: std.atomic.Value(bool) = .init(false),

    fn set(event: *TestEvent) void {
        event.signaled.store(true, .release);
    }

    fn timedWait(event: *TestEvent, timeout_nanoseconds: u64) error{Timeout}!void {
        const deadline = TestDeadline.init(timeout_nanoseconds);
        while (!event.signaled.load(.acquire)) {
            if (deadline.expired()) return error.Timeout;
            std.atomic.spinLoopHint();
        }
    }
};

const test_wait_nanoseconds: u64 = 30 * std.time.ns_per_s;

/// A standalone envelope for mailbox-only tests (no pool page behind it;
/// the mailbox never dereferences `origin_page`).
fn standaloneEnvelope(sequence: usize) Envelope {
    return .{
        .next = .init(null),
        .origin_page = null,
        .fragment = .{ .payload_byte_length = sequence },
    };
}

fn expectPopped(mailbox: *Mailbox, expected: *Envelope) !void {
    switch (mailbox.pop()) {
        .envelope => |envelope| try testing.expectEqual(expected, envelope),
        .empty => return error.TestUnexpectedEmpty,
        .transient_gap => return error.TestUnexpectedGap,
    }
}

test "Mailbox: fresh mailbox is empty with zero depth" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
    try testing.expectEqual(@as(usize, 0), mailbox.depth());
    try testing.expectEqual(@as(usize, 0), mailbox.drain_closure_count);
}

test "Mailbox: single-producer FIFO, wake signal, and depth accounting" {
    var mailbox: Mailbox = undefined;
    mailbox.init();
    var wake_count: usize = 0;
    mailbox.wake_callback = countingWakeCallbackSingleThreaded;
    mailbox.wake_context = &wake_count;

    var first = standaloneEnvelope(1);
    var second = standaloneEnvelope(2);
    var third = standaloneEnvelope(3);

    // Only the empty→nonempty push signals; the seam fired exactly once.
    try testing.expect(mailbox.push(&first));
    try testing.expect(!mailbox.push(&second));
    try testing.expect(!mailbox.push(&third));
    try testing.expectEqual(@as(usize, 1), wake_count);
    try testing.expectEqual(@as(usize, 3), mailbox.depth());

    // FIFO delivery.
    try expectPopped(&mailbox, &first);
    try testing.expectEqual(@as(usize, 2), mailbox.depth());
    try expectPopped(&mailbox, &second);
    try expectPopped(&mailbox, &third);
    try testing.expectEqual(@as(usize, 0), mailbox.depth());
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());

    // Draining the last envelope closed the queue exactly once (the
    // first two pops advanced through linked successors).
    try testing.expectEqual(@as(usize, 1), mailbox.drain_closure_count);
}

test "Mailbox: wake signal fires exactly once per empty→nonempty transition (sequential)" {
    var mailbox: Mailbox = undefined;
    mailbox.init();
    var wake_count: usize = 0;
    mailbox.wake_callback = countingWakeCallbackSingleThreaded;
    mailbox.wake_context = &wake_count;

    var envelopes: [6]Envelope = undefined;
    for (&envelopes, 0..) |*envelope, index| envelope.* = standaloneEnvelope(index);

    // Three fill/drain cycles: one signal per cycle, and the quiescent
    // invariant (signals == closures) holds after each drain.
    var signal_total: usize = 0;
    for (0..3) |cycle| {
        const first_of_cycle = &envelopes[cycle * 2];
        const second_of_cycle = &envelopes[cycle * 2 + 1];
        if (mailbox.push(first_of_cycle)) signal_total += 1;
        if (mailbox.push(second_of_cycle)) signal_total += 1;
        try expectPopped(&mailbox, first_of_cycle);
        try expectPopped(&mailbox, second_of_cycle);
        try testing.expectEqual(PopOutcome.empty, mailbox.pop());

        try testing.expectEqual(cycle + 1, signal_total);
        try testing.expectEqual(signal_total, wake_count);
        try testing.expectEqual(signal_total, mailbox.drain_closure_count);
    }
}

fn countingWakeCallbackSingleThreaded(wake_context: ?*anyopaque) void {
    const counter: *usize = @ptrCast(@alignCast(wake_context.?));
    counter.* += 1;
}

// -- correlated receive + receive-mark (P5-J4) --------------------------------

fn correlatedEnvelope(ref: u64) Envelope {
    return .{
        .next = .init(null),
        .origin_page = null,
        .fragment = .{ .correlation_ref = ref },
    };
}

fn downSignalEnvelope(payload: *const signal_module.SignalPayload) Envelope {
    return .{
        .next = .init(null),
        .origin_page = null,
        .fragment = .{
            .payload_pointer = @ptrCast(payload),
            .payload_byte_length = @sizeOf(signal_module.SignalPayload),
            .signal_kind = .down,
        },
    };
}

fn expectTakeMatched(mailbox: *Mailbox, ref: u64, expected: *Envelope) !void {
    switch (mailbox.takeCorrelated(ref, .user_or_down, null)) {
        .matched => |envelope| try testing.expectEqual(expected, envelope),
        else => return error.TestExpectedMatch,
    }
}

test "Mailbox: correlated take extracts the interior match and preserves skipped order" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var first = standaloneEnvelope(1);
    var second = standaloneEnvelope(2);
    var reply = correlatedEnvelope(77);
    var third = standaloneEnvelope(3);
    _ = mailbox.push(&first);
    _ = mailbox.push(&second);
    _ = mailbox.push(&reply);
    _ = mailbox.push(&third);
    try testing.expectEqual(@as(usize, 4), mailbox.depth());

    // No mark armed: head scan finds the match, extracts ONLY it.
    try expectTakeMatched(&mailbox, 77, &reply);
    try testing.expectEqual(@as(usize, 3), mailbox.depth());

    // The skipped prefix and suffix remain queued, in order — no loss,
    // no reorder.
    try expectPopped(&mailbox, &first);
    try expectPopped(&mailbox, &second);
    try expectPopped(&mailbox, &third);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: correlated take at the head and at the tail mirrors pop's boundary discipline" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // Head + sole envelope: extraction closes the queue (a drain closure).
    var sole = correlatedEnvelope(5);
    try testing.expect(mailbox.push(&sole));
    try expectTakeMatched(&mailbox, 5, &sole);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
    try testing.expectEqual(@as(usize, 1), mailbox.drain_closure_count);
    // The next push is an exact empty→nonempty transition again.
    var after_close = standaloneEnvelope(9);
    try testing.expect(mailbox.push(&after_close));
    try expectPopped(&mailbox, &after_close);

    // Tail extraction with a real predecessor: the queue closes back to
    // the predecessor (NOT to empty — no drain closure), and a later push
    // links behind the predecessor correctly.
    var kept = standaloneEnvelope(10);
    var tail_reply = correlatedEnvelope(6);
    _ = mailbox.push(&kept);
    _ = mailbox.push(&tail_reply);
    try expectTakeMatched(&mailbox, 6, &tail_reply);
    var appended = standaloneEnvelope(11);
    _ = mailbox.push(&appended);
    try expectPopped(&mailbox, &kept);
    try expectPopped(&mailbox, &appended);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: correlated take reports exhausted (with the scan tail) when nothing matches" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // Empty queue: exhausted at the stub.
    switch (mailbox.takeCorrelated(3, .user_or_down, null)) {
        .exhausted => |last| try testing.expectEqual(&mailbox.stub, last),
        else => return error.TestExpectedExhausted,
    }

    var first = standaloneEnvelope(1);
    var second = standaloneEnvelope(2);
    _ = mailbox.push(&first);
    _ = mailbox.push(&second);
    switch (mailbox.takeCorrelated(3, .user_or_down, null)) {
        .exhausted => |last| try testing.expectEqual(&second, last),
        else => return error.TestExpectedExhausted,
    }
    // Resuming from the reported position rescans only new arrivals.
    var reply = correlatedEnvelope(3);
    _ = mailbox.push(&reply);
    const visits_before_resume = mailbox.correlatedScanVisits();
    switch (mailbox.takeCorrelated(3, .user_or_down, &second)) {
        .matched => |envelope| try testing.expectEqual(&reply, envelope),
        else => return error.TestExpectedMatch,
    }
    try testing.expectEqual(@as(u64, 1), mailbox.correlatedScanVisits() - visits_before_resume);
    try expectPopped(&mailbox, &first);
    try expectPopped(&mailbox, &second);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: the receive-mark makes a correlated take O(1) past a deep backlog (R8)" {
    const backlog_count = 10_000;
    var mailbox: Mailbox = undefined;
    mailbox.init();

    const backlog = try testing.allocator.alloc(Envelope, backlog_count);
    defer testing.allocator.free(backlog);
    for (backlog, 0..) |*envelope, index| {
        envelope.* = standaloneEnvelope(index);
        _ = mailbox.push(envelope);
    }

    // The call protocol: mark BEFORE the ref exists, then bind.
    mailbox.prepareReceiveMark();
    mailbox.bindReceiveMark(42);

    // Post-mark traffic: one unrelated message, then the correlated reply.
    var unrelated = standaloneEnvelope(999_999);
    var reply = correlatedEnvelope(42);
    _ = mailbox.push(&unrelated);
    _ = mailbox.push(&reply);

    const visits_before = mailbox.correlatedScanVisits();
    try expectTakeMatched(&mailbox, 42, &reply);
    const visited = mailbox.correlatedScanVisits() - visits_before;

    // THE R8 proof: the scan started at the mark and examined only the
    // post-mark messages (2), not the 10k backlog. A head scan would have
    // visited backlog_count + 2.
    try testing.expectEqual(@as(u64, 2), visited);

    // No loss, no reorder: the full backlog (and the skipped post-mark
    // message) drain in order through the steady-state pop.
    for (backlog) |*envelope| try expectPopped(&mailbox, envelope);
    try expectPopped(&mailbox, &unrelated);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: a mismatched ref ignores the mark and falls back to a (sound) head scan" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // An older correlated reply for ref A sits BEFORE the mark armed for
    // ref B; awaiting A must still find it (head fallback), not skip it.
    var reply_a = correlatedEnvelope(101);
    _ = mailbox.push(&reply_a);
    mailbox.prepareReceiveMark();
    mailbox.bindReceiveMark(202);

    try expectTakeMatched(&mailbox, 101, &reply_a);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: pop of the marked envelope repairs the mark to from_head" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var first = standaloneEnvelope(1);
    var second = standaloneEnvelope(2);
    _ = mailbox.push(&first);
    _ = mailbox.push(&second);
    mailbox.prepareReceiveMark();
    mailbox.bindReceiveMark(7);
    try testing.expect(mailbox.receive_mark == .after);
    try testing.expectEqual(&second, mailbox.receive_mark.after);

    // Steady-state pops deliver up to and including the marked envelope.
    try expectPopped(&mailbox, &first);
    try testing.expect(mailbox.receive_mark == .after);
    try expectPopped(&mailbox, &second);
    try testing.expect(mailbox.receive_mark == .from_head);

    // The mark stays honest: a reply pushed after the repair is found.
    var reply = correlatedEnvelope(7);
    _ = mailbox.push(&reply);
    try expectTakeMatched(&mailbox, 7, &reply);
}

test "Mailbox: correlated extraction of the marked envelope repairs the mark to its predecessor" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var older = standaloneEnvelope(1);
    var marked_reply = correlatedEnvelope(11);
    _ = mailbox.push(&older);
    _ = mailbox.push(&marked_reply);
    // Mark lands ON the correlated envelope (newest at prepare time),
    // bound to a DIFFERENT ref, so awaiting 11 head-scans and extracts
    // the marked envelope itself.
    mailbox.prepareReceiveMark();
    mailbox.bindReceiveMark(999);
    try testing.expectEqual(&marked_reply, mailbox.receive_mark.after);

    try expectTakeMatched(&mailbox, 11, &marked_reply);
    // Repaired to the still-queued predecessor (conservative-older).
    try testing.expect(mailbox.receive_mark == .after);
    try testing.expectEqual(&older, mailbox.receive_mark.after);
    try expectPopped(&mailbox, &older);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: down_only matches the DOWN and never a correlated user reply" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var payload = signal_module.SignalPayload{ .from_bits = 5, .ref = 33, .reason_term = 1 };
    var user_reply = correlatedEnvelope(33);
    var down = downSignalEnvelope(&payload);
    _ = mailbox.push(&user_reply);
    _ = mailbox.push(&down);

    // down_only skips the (same-ref) user reply and takes the DOWN.
    switch (mailbox.takeCorrelated(33, .down_only, null)) {
        .matched => |envelope| try testing.expectEqual(&down, envelope),
        else => return error.TestExpectedMatch,
    }
    // user_or_down then takes the reply; an exit signal never matches.
    try expectTakeMatched(&mailbox, 33, &user_reply);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: user_or_down takes the earlier of reply and DOWN in queue order" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var payload = signal_module.SignalPayload{ .from_bits = 5, .ref = 44, .reason_term = 1 };
    var reply = correlatedEnvelope(44);
    var down = downSignalEnvelope(&payload);
    _ = mailbox.push(&reply);
    _ = mailbox.push(&down);

    // The reply precedes its DOWN (the worker replies, then exits): the
    // wait must take the reply.
    try expectTakeMatched(&mailbox, 44, &reply);
    switch (mailbox.takeCorrelated(44, .down_only, null)) {
        .matched => |envelope| try testing.expectEqual(&down, envelope),
        else => return error.TestExpectedMatch,
    }
}

// -- signal-aware receive split (P5-R1): signal_any / user_any / scanForMatch --

fn exitSignalEnvelope(payload: *const signal_module.SignalPayload) Envelope {
    return .{
        .next = .init(null),
        .origin_page = null,
        .fragment = .{
            .payload_pointer = @ptrCast(payload),
            .payload_byte_length = @sizeOf(signal_module.SignalPayload),
            .signal_kind = .exit,
        },
    };
}

test "Mailbox: signal_any extracts the oldest signal, leaving user messages queued in order" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var exit_payload = signal_module.SignalPayload{ .from_bits = 7, .reason_term = 2 };
    var down_payload = signal_module.SignalPayload{ .from_bits = 8, .ref = 55, .reason_term = 3 };
    var first_user = standaloneEnvelope(1);
    var exit_envelope = exitSignalEnvelope(&exit_payload);
    var second_user = standaloneEnvelope(2);
    var down_envelope = downSignalEnvelope(&down_payload);
    _ = mailbox.push(&first_user);
    _ = mailbox.push(&exit_envelope);
    _ = mailbox.push(&second_user);
    _ = mailbox.push(&down_envelope);

    // The oldest SIGNAL (the exit) is taken first — the user head is
    // skipped, never a match, never disturbed.
    switch (mailbox.takeCorrelated(0, .signal_any, null)) {
        .matched => |envelope| try testing.expectEqual(&exit_envelope, envelope),
        else => return error.TestExpectedMatch,
    }
    // Then the DOWN; signal kinds are indistinguishable to the class scan.
    switch (mailbox.takeCorrelated(0, .signal_any, null)) {
        .matched => |envelope| try testing.expectEqual(&down_envelope, envelope),
        else => return error.TestExpectedMatch,
    }
    // The skipped user messages remain queued, in order.
    try expectPopped(&mailbox, &first_user);
    try expectPopped(&mailbox, &second_user);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: user_any extracts the oldest user message, leaving signals queued in order" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var exit_payload = signal_module.SignalPayload{ .from_bits = 7, .reason_term = 2 };
    var exit_envelope = exitSignalEnvelope(&exit_payload);
    var first_user = standaloneEnvelope(1);
    var second_user = standaloneEnvelope(2);
    _ = mailbox.push(&exit_envelope);
    _ = mailbox.push(&first_user);
    _ = mailbox.push(&second_user);

    // The signal head is skipped; the oldest USER message is taken —
    // FIFO among user messages is preserved.
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .matched => |envelope| try testing.expectEqual(&first_user, envelope),
        else => return error.TestExpectedMatch,
    }
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .matched => |envelope| try testing.expectEqual(&second_user, envelope),
        else => return error.TestExpectedMatch,
    }
    // No user message left: exhausted, with the signal still queued for
    // the signal surface.
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .exhausted => {},
        else => return error.TestExpectedExhausted,
    }
    switch (mailbox.takeCorrelated(0, .signal_any, null)) {
        .matched => |envelope| try testing.expectEqual(&exit_envelope, envelope),
        else => return error.TestExpectedMatch,
    }
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: a correlated-stamped reply is a user message to the class scans" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // A late correlated reply (its awaiter timed out) must surface through
    // the steady-state user receive — user_any matches it.
    var late_reply = correlatedEnvelope(99);
    _ = mailbox.push(&late_reply);
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .matched => |envelope| try testing.expectEqual(&late_reply, envelope),
        else => return error.TestExpectedMatch,
    }
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: scanForMatch probes without consuming and honors the class kinds" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // Empty queue: exhausted at the stub.
    switch (mailbox.scanForMatch(0, .user_any, null)) {
        .exhausted => |last| try testing.expectEqual(&mailbox.stub, last),
        else => return error.TestExpectedExhausted,
    }

    // Only a signal queued: a user_any probe reports exhausted (the
    // signal-aware `after` wait must NOT count it) — and consumes nothing.
    var exit_payload = signal_module.SignalPayload{ .from_bits = 7, .reason_term = 2 };
    var exit_envelope = exitSignalEnvelope(&exit_payload);
    _ = mailbox.push(&exit_envelope);
    switch (mailbox.scanForMatch(0, .user_any, null)) {
        .exhausted => |last| try testing.expectEqual(&exit_envelope, last),
        else => return error.TestExpectedExhausted,
    }
    try testing.expectEqual(@as(usize, 1), mailbox.depth());

    // A user message behind the signal: found — still nothing consumed,
    // and a resumed probe from the exhausted tail sees only new arrivals.
    var user_envelope = standaloneEnvelope(1);
    _ = mailbox.push(&user_envelope);
    switch (mailbox.scanForMatch(0, .user_any, &exit_envelope)) {
        .found => {},
        else => return error.TestExpectedFound,
    }
    try testing.expectEqual(@as(usize, 2), mailbox.depth());

    // The probe left everything in place for the consuming scans.
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .matched => |envelope| try testing.expectEqual(&user_envelope, envelope),
        else => return error.TestExpectedMatch,
    }
    switch (mailbox.takeCorrelated(0, .signal_any, null)) {
        .matched => |envelope| try testing.expectEqual(&exit_envelope, envelope),
        else => return error.TestExpectedMatch,
    }
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: class scans never consult the receive-mark and never bump the R8 counter" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    // Arm a mark past an older user message (the call-protocol shape).
    var older_user = standaloneEnvelope(1);
    _ = mailbox.push(&older_user);
    mailbox.prepareReceiveMark();
    mailbox.bindReceiveMark(42);
    var newer_user = standaloneEnvelope(2);
    _ = mailbox.push(&newer_user);

    // A ref-0 class scan must start at the HEAD (an armed-but-foreign mark
    // never applies): the OLDER user message is taken first.
    const visits_before = mailbox.correlatedScanVisits();
    switch (mailbox.takeCorrelated(0, .user_any, null)) {
        .matched => |envelope| try testing.expectEqual(&older_user, envelope),
        else => return error.TestExpectedMatch,
    }
    // And the class scan does not pollute the R8 correlated-visit counter.
    try testing.expectEqual(visits_before, mailbox.correlatedScanVisits());

    try expectPopped(&mailbox, &newer_user);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: armCorrelatedWake makes every push fire the wake seam until disarmed" {
    var mailbox: Mailbox = undefined;
    mailbox.init();
    var wake_count: usize = 0;
    mailbox.wake_callback = countingWakeCallbackSingleThreaded;
    mailbox.wake_context = &wake_count;

    // Nonempty mailbox (the correlated-waiter shape): a push while
    // UNARMED does not wake (no empty→nonempty transition)…
    var backlog_envelope = standaloneEnvelope(1);
    try testing.expect(mailbox.push(&backlog_envelope)); // transition wake
    try testing.expectEqual(@as(usize, 1), wake_count);
    var silent = standaloneEnvelope(2);
    try testing.expect(!mailbox.push(&silent));
    try testing.expectEqual(@as(usize, 1), wake_count);

    // …but after arming at the scan's exhausted tail, every push wakes.
    const exhausted_tail = switch (mailbox.takeCorrelated(9, .user_or_down, null)) {
        .exhausted => |last| last,
        else => return error.TestExpectedExhausted,
    };
    try testing.expectEqual(&silent, exhausted_tail);
    try testing.expect(mailbox.armCorrelatedWake(exhausted_tail));
    var woken_one = standaloneEnvelope(3);
    var woken_two = standaloneEnvelope(4);
    _ = mailbox.push(&woken_one);
    _ = mailbox.push(&woken_two);
    try testing.expectEqual(@as(usize, 3), wake_count);

    // Disarm restores transition-only waking.
    mailbox.disarmCorrelatedWake();
    var silent_again = standaloneEnvelope(5);
    _ = mailbox.push(&silent_again);
    try testing.expectEqual(@as(usize, 3), wake_count);
}

test "Mailbox: armCorrelatedWake refuses when a message landed after the scan" {
    var mailbox: Mailbox = undefined;
    mailbox.init();

    var first = standaloneEnvelope(1);
    _ = mailbox.push(&first);
    const exhausted_tail = switch (mailbox.takeCorrelated(9, .user_or_down, null)) {
        .exhausted => |last| last,
        else => return error.TestExpectedExhausted,
    };

    // A message lands between the scan and the arm: the arm must fail
    // (and leave the flag clear) so the caller rescans instead of parking.
    var raced = correlatedEnvelope(9);
    _ = mailbox.push(&raced);
    try testing.expect(!mailbox.armCorrelatedWake(exhausted_tail));
    try testing.expect(!mailbox.correlated_wake_armed.load(.monotonic));

    // The rescan from the stale position finds the racer.
    switch (mailbox.takeCorrelated(9, .user_or_down, exhausted_tail)) {
        .matched => |envelope| try testing.expectEqual(&raced, envelope),
        else => return error.TestExpectedMatch,
    }
    try expectPopped(&mailbox, &first);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

test "Mailbox: correlated take reports publish_pending on a parked mid-publish producer" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mailbox: Mailbox = undefined;
    mailbox.init();

    var parked_envelope = correlatedEnvelope(21);
    var producer = ParkedProducer{
        .target_mailbox = &mailbox,
        .park_on_envelope = &parked_envelope,
    };
    producer.arm();

    const producer_thread = try std.Thread.spawn(.{}, ParkedProducer.run, .{&producer});
    try producer.reached_gap_window.timedWait(test_wait_nanoseconds);

    // The tail moved (the reply is arriving) but the link has not landed:
    // the scan must report publish_pending — never exhausted (which would
    // let the caller park and miss the wake) and never a bogus match.
    switch (mailbox.takeCorrelated(21, .user_or_down, null)) {
        .publish_pending => |last| try testing.expectEqual(&mailbox.stub, last),
        else => return error.TestExpectedPublishPending,
    }

    producer.release_from_gap_window.set();
    producer_thread.join();

    try expectTakeMatched(&mailbox, 21, &parked_envelope);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

// -- deterministic transient-gap tests ---------------------------------------

/// Drives one push on a separate thread and parks it INSIDE the gap
/// window (between the XCHG and the next-store) via the test-only push
/// instrumentation, until the test releases it.
const ParkedProducer = struct {
    target_mailbox: *Mailbox,
    /// The producer parks only when pushing exactly this envelope, so
    /// tests can push other envelopes un-parked through the same
    /// mailbox.
    park_on_envelope: *Envelope,
    reached_gap_window: TestEvent = .{},
    release_from_gap_window: TestEvent = .{},
    push_transitioned_from_empty: bool = false,

    fn instrumentation(instrumentation_context: ?*anyopaque, envelope: *Envelope) void {
        const producer: *ParkedProducer = @ptrCast(@alignCast(instrumentation_context.?));
        if (envelope != producer.park_on_envelope) return;
        producer.reached_gap_window.set();
        producer.release_from_gap_window.timedWait(test_wait_nanoseconds) catch
            @panic("ParkedProducer: never released from the gap window");
    }

    fn run(producer: *ParkedProducer) void {
        producer.push_transitioned_from_empty =
            producer.target_mailbox.push(producer.park_on_envelope);
    }

    fn arm(producer: *ParkedProducer) void {
        producer.target_mailbox.push_instrumentation = .{
            .between_exchange_and_link = instrumentation,
            .instrumentation_context = producer,
        };
    }
};

test "Mailbox: deterministic transient gap at the empty boundary — pop reports the gap, never empty" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mailbox: Mailbox = undefined;
    mailbox.init();

    var parked_envelope = standaloneEnvelope(42);
    var producer = ParkedProducer{
        .target_mailbox = &mailbox,
        .park_on_envelope = &parked_envelope,
    };
    producer.arm();

    const producer_thread = try std.Thread.spawn(.{}, ParkedProducer.run, .{&producer});
    try producer.reached_gap_window.timedWait(test_wait_nanoseconds);

    // The producer now sits between its XCHG and its next-store: the
    // mailbox is NONEMPTY (tail moved, depth counted) but unlinkable.
    // The consumer must report the gap — repeatedly, deterministically —
    // and must NOT claim empty.
    for (0..4) |_| {
        try testing.expectEqual(PopOutcome.transient_gap, mailbox.pop());
    }
    try testing.expectEqual(@as(usize, 1), mailbox.depth());

    // Release the producer; the pending link lands and delivery resumes.
    producer.release_from_gap_window.set();
    producer_thread.join();
    try testing.expect(producer.push_transitioned_from_empty);

    try expectPopped(&mailbox, &parked_envelope);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
    try testing.expectEqual(@as(usize, 0), mailbox.depth());
}

test "Mailbox: deterministic transient gap mid-queue — a parked producer transiently blocks its linked predecessor" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var mailbox: Mailbox = undefined;
    mailbox.init();

    var published_first = standaloneEnvelope(1);
    var parked_second = standaloneEnvelope(2);
    var producer = ParkedProducer{
        .target_mailbox = &mailbox,
        .park_on_envelope = &parked_second,
    };
    producer.arm();

    // First envelope is fully published (the instrumentation only parks
    // the second one).
    try testing.expect(mailbox.push(&published_first));

    const producer_thread = try std.Thread.spawn(.{}, ParkedProducer.run, .{&producer});
    try producer.reached_gap_window.timedWait(test_wait_nanoseconds);

    // Vyukov semantics (module doc): the pending hop blocks even the
    // fully-published head — the consumer cannot pop `published_first`
    // because advancing off it needs the parked producer's link. It must
    // see the gap, not empty, and not a bogus delivery.
    for (0..4) |_| {
        try testing.expectEqual(PopOutcome.transient_gap, mailbox.pop());
    }
    try testing.expectEqual(@as(usize, 2), mailbox.depth());

    producer.release_from_gap_window.set();
    producer_thread.join();
    // The mailbox was nonempty at the parked producer's XCHG.
    try testing.expect(!producer.push_transitioned_from_empty);

    // Both envelopes deliver, in order.
    try expectPopped(&mailbox, &published_first);
    try expectPopped(&mailbox, &parked_second);
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
}

// -- concurrent wake-signal exactness ----------------------------------------

const FirstPushRacer = struct {
    target_mailbox: *Mailbox,
    envelope: *Envelope,
    start_signal: *TestEvent,
    observed_transition: bool = false,

    fn run(racer: *FirstPushRacer) void {
        racer.start_signal.timedWait(test_wait_nanoseconds) catch
            @panic("FirstPushRacer: start signal never fired");
        racer.observed_transition = racer.target_mailbox.push(racer.envelope);
    }
};

test "Mailbox: concurrent first-pushers — exactly one wake signal per empty→nonempty transition" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const racer_count = 4;
    const round_count = 50;

    var mailbox: Mailbox = undefined;
    mailbox.init();
    var wake_count = std.atomic.Value(usize).init(0);
    mailbox.wake_callback = countingWakeCallbackAtomic;
    mailbox.wake_context = &wake_count;

    for (0..round_count) |_| {
        var envelopes: [racer_count]Envelope = undefined;
        for (&envelopes, 0..) |*envelope, index| envelope.* = standaloneEnvelope(index);

        var start_signal = TestEvent{};
        var racers: [racer_count]FirstPushRacer = undefined;
        var racer_threads: [racer_count]std.Thread = undefined;
        for (&racers, &envelopes, 0..) |*racer, *envelope, index| {
            racer.* = .{
                .target_mailbox = &mailbox,
                .envelope = envelope,
                .start_signal = &start_signal,
            };
            racer_threads[index] = try std.Thread.spawn(.{}, FirstPushRacer.run, .{racer});
        }

        // Release all racers into the quiescent-empty mailbox at once.
        start_signal.set();
        for (&racer_threads) |*thread| thread.join();

        // EXACTLY one racer transitioned it, and the seam fired once.
        var transition_count: usize = 0;
        for (&racers) |*racer| {
            if (racer.observed_transition) transition_count += 1;
        }
        try testing.expectEqual(@as(usize, 1), transition_count);
        try testing.expectEqual(@as(usize, 1), wake_count.load(.monotonic));

        // Drain back to quiescent-empty for the next round. All pushes
        // completed (threads joined), so no gaps are possible.
        for (0..racer_count) |_| {
            switch (mailbox.pop()) {
                .envelope => {},
                .empty => return error.TestUnexpectedEmpty,
                .transient_gap => return error.TestUnexpectedGap,
            }
        }
        try testing.expectEqual(PopOutcome.empty, mailbox.pop());
        wake_count.store(0, .monotonic);
    }
}

fn countingWakeCallbackAtomic(wake_context: ?*anyopaque) void {
    const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(wake_context.?));
    _ = counter.fetchAdd(1, .monotonic);
}

// -- interleaved per-producer FIFO -------------------------------------------

const FifoProducer = struct {
    target_mailbox: *Mailbox,
    envelopes: []Envelope,
    producer_index: usize,

    fn run(producer: *FifoProducer) void {
        for (producer.envelopes, 0..) |*envelope, sequence| {
            envelope.* = .{
                .next = .init(null),
                .origin_page = null,
                // Stamp {producer, sequence} into the opaque fragment.
                .fragment = .{
                    .payload_pointer = null,
                    .payload_byte_length = producer.producer_index << 32 | sequence,
                },
            };
            _ = producer.target_mailbox.push(envelope);
        }
    }
};

test "Mailbox: per-producer FIFO holds across interleaved producers (no global order asserted)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const producer_count = 4;
    const messages_per_producer = 20_000;

    var mailbox: Mailbox = undefined;
    mailbox.init();

    const all_envelopes = try testing.allocator.alloc(Envelope, producer_count * messages_per_producer);
    defer testing.allocator.free(all_envelopes);

    var producers: [producer_count]FifoProducer = undefined;
    var producer_threads: [producer_count]std.Thread = undefined;
    for (&producers, 0..) |*producer, producer_index| {
        const first = producer_index * messages_per_producer;
        producer.* = .{
            .target_mailbox = &mailbox,
            .envelopes = all_envelopes[first .. first + messages_per_producer],
            .producer_index = producer_index,
        };
        producer_threads[producer_index] = try std.Thread.spawn(.{}, FifoProducer.run, .{producer});
    }

    // Consume concurrently with production: assert each producer's
    // sequence numbers arrive strictly in send order.
    var expected_sequence: [producer_count]usize = @splat(0);
    var received_total: usize = 0;
    const deadline = TestDeadline.init(test_wait_nanoseconds);
    while (received_total < all_envelopes.len) {
        switch (mailbox.pop()) {
            .envelope => |envelope| {
                const stamp = envelope.fragment.payload_byte_length;
                const producer_index = stamp >> 32;
                const sequence = stamp & std.math.maxInt(u32);
                try testing.expectEqual(expected_sequence[producer_index], sequence);
                expected_sequence[producer_index] += 1;
                received_total += 1;
            },
            .empty, .transient_gap => {
                if (deadline.expired()) return error.TestTimeout;
                std.atomic.spinLoopHint();
            },
        }
    }

    for (&producer_threads) |*thread| thread.join();
    for (expected_sequence) |sequence| {
        try testing.expectEqual(@as(usize, messages_per_producer), sequence);
    }
    try testing.expectEqual(PopOutcome.empty, mailbox.pop());
    try testing.expectEqual(@as(usize, 0), mailbox.depth());
}
