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
//! then tears the PCB down. Unregistering the pid FIRST
//! (`process.zig`) makes new senders dead-letter; a sender already past
//! lookup is the Phase 4 PCB-lifetime caveat documented in
//! `pid_table.zig` and is out of scope for the single-scheduler Phase 1.
//!
//! ## Toolchain
//!
//! Pure atomics/data-structure code — no fiber context switches — so
//! this file has no special compiler requirement; see `concurrency.zig`
//! for the kernel-wide fork-compiler requirement on optimized builds.

const std = @import("std");
const builtin = @import("builtin");
const envelope_pool = @import("envelope_pool.zig");

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
    /// populates it, or for payload-less control messages).
    payload_pointer: ?[*]const u8 = null,
    /// Fragment length in bytes.
    payload_byte_length: usize = 0,
    /// Pool page the payload bytes were carved from (Phase 2 seam;
    /// distinct from `Envelope.origin_page`, which is the page the
    /// ENVELOPE HEADER itself lives in).
    payload_origin_page: ?*envelope_pool.EnvelopePage = null,
};

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
        if (transitioned_from_empty) mailbox.wake_callback(mailbox.wake_context);
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

    /// Approximate number of queued envelopes (see `approximate_depth`).
    pub fn depth(mailbox: *const Mailbox) usize {
        return mailbox.approximate_depth.load(.monotonic);
    }

    fn deliver(mailbox: *Mailbox, envelope: *Envelope) PopOutcome {
        _ = mailbox.approximate_depth.fetchSub(1, .monotonic);
        return .{ .envelope = envelope };
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
