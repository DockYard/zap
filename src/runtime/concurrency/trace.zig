//! Message-flow trace points for the Zap concurrency kernel.
//!
//! Phase 6 item 6.5 of `docs/concurrency-implementation-plan.md` (job
//! P6-J6), implementing research.md §6.9's "message tracing hooks
//! (compile-time-optional trace points on send/receive)". Five event
//! kinds cover the whole message-flow lifecycle: `spawn`, `exit`,
//! `send`, `receive`, and `signal` (exit/`DOWN` envelope delivery).
//!
//! ## Compile-time gate (the P2-J1 marker-rewrite pattern)
//!
//! `RUNTIME_TRACE_DEFAULT` below is a source marker, exactly like
//! `RUNTIME_CONCURRENCY_DEFAULT` in `src/runtime.zig`: the source
//! default is `false`, and the build driver (`src/concurrency_driver.zig`)
//! rewrites it to `true` — in a staged copy of the kernel unit, never in
//! the source tree — only for builds that resolved `runtime_tracing` ON
//! (the `Zap.Manifest` field or `-Druntime-tracing=on`). Every emit site
//! in the kernel is guarded by `if (comptime runtime_trace_active)`, so a
//! gate-OFF kernel object contains ZERO trace instructions on the
//! send/receive/spawn/exit/signal paths and ZERO ring storage — the
//! campaign's zero-cost-when-off discipline. The READ surface
//! (`abi.zig`'s `zap_trace_*` exports) stays compiled in both modes and
//! reports "disabled" when OFF, so the runtime's extern declarations
//! always resolve and the Zap-level API is total.
//!
//! ## The v1 sink: a bounded in-memory ring, not a callback
//!
//! Decision (plan 6.5): the v1 trace sink is a fixed-capacity in-memory
//! ring READABLE FROM ZAP (`RuntimeInfo.trace_*`), not a registered
//! callback. A callback sink invites re-entrancy into the scheduler from
//! arbitrary user code on the hottest kernel paths — the ring keeps the
//! emit path to a handful of atomic stores, keeps the consumer fully
//! decoupled, and doubles as the deterministic testing hook (§6.9's
//! "these hooks double as the testing hooks"). A streaming/callback sink
//! can be layered ON TOP of the ring later without touching the emit
//! sites.
//!
//! ## Concurrency contract (read this before trusting an entry)
//!
//! Writers are the scheduler threads (and blocking-pool threads running a
//! process's send). The ring is lock-free multi-producer: a writer claims
//! a monotonically increasing ticket (`fetchAdd`) and overwrites the slot
//! `ticket % capacity`. Every slot field is an atomic, so there are no
//! torn reads and no data races (ThreadSanitizer-clean by construction).
//! Consistency is per-slot, seqlock-style: the slot's `stamp` is
//! invalidated before the payload stores and published (ticket + 1) after
//! them, and the payload's `meta` word redundantly carries the ticket —
//! a reader that observes a stamp/meta/ticket mismatch SKIPS the slot.
//! The documented approximation: a capture that races active writers may
//! miss the entries being overwritten in that instant (they are the
//! oldest ones), and in the pathological case of a writer stalled for a
//! FULL ring circumference while another writer laps it, a slot's
//! pid/timestamp words could pair across the two writers — the ticket
//! cross-check bounds this to a vanishing window and such an entry is
//! diagnostic data, never dereferenced. Captures at quiescence (how the
//! tests read) are exact over the last `ring_capacity` events.

const std = @import("std");

/// P6-J6 gate marker — rewritten to `true` by the build driver's staged
/// kernel copy when `runtime_tracing` resolves ON (see the module doc).
/// NEVER edit by hand.
pub const RUNTIME_TRACE_DEFAULT: bool = false;

/// Whether this kernel build carries the trace instrumentation. Comptime;
/// the single source every emit site branches on.
pub const runtime_trace_active: bool = RUNTIME_TRACE_DEFAULT;

/// Number of events the global ring retains (the newest
/// `ring_capacity`; older events are overwritten). Power of two so the
/// slot index is a mask. 4096 × 40 B = 160 KiB of BSS, present only in
/// trace-ON kernel objects (the storage is comptime-gated away when OFF).
pub const ring_capacity: usize = 4096;

/// What happened, per event. Values are ABI-stable (the `zap_trace_kind`
/// export returns them raw and `lib/runtime_info.zap` maps them to atoms).
pub const TraceEventKind = enum(u8) {
    /// A process was created and admitted (pid = the child).
    spawn = 1,
    /// A process finished teardown (pid = the dead process;
    /// detail 0 = normal exit, 1 = killed/crashed).
    exit = 2,
    /// A process sent a user message (pid = sender, peer = target;
    /// detail 0 = delivered, 1 = dead-lettered).
    send = 3,
    /// A process consumed a user message from its mailbox (pid = the
    /// receiver).
    receive = 4,
    /// A trapped-exit or monitor-`DOWN` envelope was pushed to a process
    /// (pid = the signal's origin, peer = the target; detail =
    /// `signal.SignalKind`).
    signal = 5,
};

/// One captured trace event — a plain value snapshot of a ring slot.
pub const TraceEventRecord = struct {
    /// Global emission order (the ring ticket): strictly increasing
    /// across every scheduler thread, so two events from one capture
    /// compare by `sequence`.
    sequence: u64,
    /// Monotonic nanoseconds at emission, read through the emitting
    /// scheduler's clock seam (virtual under the seeded simulator).
    timestamp_nanoseconds: u64,
    /// What happened.
    kind: TraceEventKind,
    /// Kind-specific detail byte (see `TraceEventKind`).
    detail: u8,
    /// The acting process's raw pid bits.
    pid_bits: u64,
    /// The counterparty's raw pid bits (send target / signal target),
    /// 0 when the event has none.
    peer_pid_bits: u64,
};

/// The bounded multi-producer trace ring (module doc for the full
/// concurrency contract). Generic over capacity so the kernel test suite
/// exercises small rings (wrap behavior) regardless of the comptime
/// trace gate; the kernel's global instance uses `ring_capacity`.
pub fn TraceRing(comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity >= 2 and std.math.isPowerOfTwo(capacity));
    }
    return struct {
        const Self = @This();
        const index_mask: u64 = capacity - 1;
        /// How many low ticket bits the `meta` word carries for the
        /// reader's cross-check (the rest hold kind + detail).
        const meta_ticket_bits: u6 = 48;
        const meta_ticket_mask: u64 = (@as(u64, 1) << meta_ticket_bits) - 1;

        /// One overwritable event slot. Every field is an atomic so a
        /// reader racing a writer sees only whole words (TSan-clean; no
        /// torn reads). `stamp` is the seqlock word: 0 while a write is
        /// in flight, `ticket + 1` once published.
        const Slot = struct {
            stamp: std.atomic.Value(u64),
            timestamp: std.atomic.Value(u64),
            pid_bits: std.atomic.Value(u64),
            peer_pid_bits: std.atomic.Value(u64),
            /// Packed `(ticket & meta_ticket_mask) << 16 | detail << 8 | kind`.
            meta: std.atomic.Value(u64),
        };

        /// Next ticket to claim == total events ever emitted.
        head: std.atomic.Value(u64),
        slots: [capacity]Slot,

        /// A fresh, empty ring.
        pub const empty: Self = .{
            .head = .init(0),
            .slots = @splat(.{
                .stamp = .init(0),
                .timestamp = .init(0),
                .pid_bits = .init(0),
                .peer_pid_bits = .init(0),
                .meta = .init(0),
            }),
        };

        /// Record one event. Lock-free, wait-free but for the single
        /// `fetchAdd`; callable from any thread.
        pub fn emit(
            ring: *Self,
            timestamp_nanoseconds: u64,
            kind: TraceEventKind,
            detail: u8,
            pid_bits: u64,
            peer_pid_bits: u64,
        ) void {
            const ticket = ring.head.fetchAdd(1, .monotonic);
            const slot = &ring.slots[@intCast(ticket & index_mask)];
            // Invalidate for readers, store the payload, then publish.
            // Release on the invalidation orders it before the payload
            // stores as observed by an acquire reader; release on the
            // publication orders the payload stores before it.
            slot.stamp.store(0, .release);
            slot.timestamp.store(timestamp_nanoseconds, .monotonic);
            slot.pid_bits.store(pid_bits, .monotonic);
            slot.peer_pid_bits.store(peer_pid_bits, .monotonic);
            slot.meta.store(
                ((ticket & meta_ticket_mask) << 16) |
                    (@as(u64, detail) << 8) |
                    @intFromEnum(kind),
                .monotonic,
            );
            slot.stamp.store(ticket + 1, .release);
        }

        /// Total events ever emitted (monotonic; events older than the
        /// newest `capacity` have been overwritten).
        pub fn emittedTotal(ring: *const Self) u64 {
            return ring.head.load(.acquire);
        }

        /// Copy the retained events, oldest first, into `destination`;
        /// returns how many were written. Entries a racing writer is
        /// overwriting mid-capture are skipped (module doc). Exact at
        /// quiescence.
        pub fn capture(ring: *Self, destination: []TraceEventRecord) usize {
            const end_ticket = ring.head.load(.acquire);
            const retained = @min(end_ticket, capacity);
            var ticket = end_ticket - retained;
            var written: usize = 0;
            while (ticket < end_ticket and written < destination.len) : (ticket += 1) {
                const slot = &ring.slots[@intCast(ticket & index_mask)];
                const stamp_before = slot.stamp.load(.acquire);
                if (stamp_before != ticket + 1) continue; // overwritten or in flight
                const timestamp = slot.timestamp.load(.monotonic);
                const pid_bits = slot.pid_bits.load(.monotonic);
                const peer_pid_bits = slot.peer_pid_bits.load(.monotonic);
                const meta = slot.meta.load(.monotonic);
                const stamp_after = slot.stamp.load(.acquire);
                if (stamp_after != ticket + 1) continue; // overwritten mid-read
                if ((meta >> 16) != (ticket & meta_ticket_mask)) continue; // laps crossed
                const kind_raw: u8 = @truncate(meta);
                if (kind_raw < @intFromEnum(TraceEventKind.spawn) or
                    kind_raw > @intFromEnum(TraceEventKind.signal)) continue;
                const kind: TraceEventKind = @enumFromInt(kind_raw);
                destination[written] = .{
                    .sequence = ticket,
                    .timestamp_nanoseconds = timestamp,
                    .kind = kind,
                    .detail = @truncate(meta >> 8),
                    .pid_bits = pid_bits,
                    .peer_pid_bits = peer_pid_bits,
                };
                written += 1;
            }
            return written;
        }

        /// Discard every retained event and restart sequence numbering.
        /// A DIAGNOSTIC/TEST aid: callers must invoke it at a point where
        /// no writer is emitting (e.g. between test cases at quiescence)
        /// — a concurrent emit may survive or be dropped, never corrupt.
        pub fn reset(ring: *Self) void {
            for (&ring.slots) |*slot| slot.stamp.store(0, .release);
            ring.head.store(0, .release);
        }
    };
}

/// The kernel's global trace ring — storage exists only in trace-ON
/// builds (`void` otherwise; the emit and read paths are equally gated).
var global_ring_storage: if (runtime_trace_active) TraceRing(ring_capacity) else void =
    if (runtime_trace_active) .empty else {};

/// Record one event into the global ring. The caller (an emit site in
/// `scheduler.zig`) MUST wrap the call — including its timestamp read —
/// in `if (comptime runtime_trace_active)`, so a trace-OFF kernel emits
/// nothing and reads no clock.
pub inline fn emitGlobal(
    timestamp_nanoseconds: u64,
    kind: TraceEventKind,
    detail: u8,
    pid_bits: u64,
    peer_pid_bits: u64,
) void {
    comptime std.debug.assert(runtime_trace_active);
    global_ring_storage.emit(timestamp_nanoseconds, kind, detail, pid_bits, peer_pid_bits);
}

/// Capture the global ring, oldest first (0 when tracing is compiled
/// OFF). Read surface for `abi.zig`'s `zap_trace_capture`.
pub fn captureGlobal(destination: []TraceEventRecord) usize {
    if (comptime !runtime_trace_active) return 0;
    return global_ring_storage.capture(destination);
}

/// Total events ever emitted into the global ring (0 when OFF).
pub fn emittedTotalGlobal() u64 {
    if (comptime !runtime_trace_active) return 0;
    return global_ring_storage.emittedTotal();
}

/// Reset the global ring (no-op when OFF). Test/diagnostic aid — call at
/// quiescence (see `TraceRing.reset`).
pub fn resetGlobal() void {
    if (comptime !runtime_trace_active) return;
    global_ring_storage.reset();
}

// ---------------------------------------------------------------------------
// Tests — the ring is exercised directly (independent of the comptime
// gate, which is OFF in the kernel test build); the end-to-end trace-ON
// proof is the gate-ON Zap suite (`test_concurrency_traced/`), built by
// the compiler with the marker rewritten.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "TraceRing: events capture oldest-first with sequence, kind, detail, and pids intact" {
    var ring: TraceRing(8) = .empty;
    ring.emit(100, .spawn, 0, 11, 0);
    ring.emit(200, .send, 0, 11, 22);
    ring.emit(300, .receive, 0, 22, 0);
    ring.emit(400, .exit, 1, 22, 0);

    var events: [8]TraceEventRecord = undefined;
    const captured = ring.capture(&events);
    try testing.expectEqual(@as(usize, 4), captured);
    try testing.expectEqual(@as(u64, 4), ring.emittedTotal());

    try testing.expectEqual(TraceEventKind.spawn, events[0].kind);
    try testing.expectEqual(@as(u64, 0), events[0].sequence);
    try testing.expectEqual(@as(u64, 100), events[0].timestamp_nanoseconds);
    try testing.expectEqual(@as(u64, 11), events[0].pid_bits);

    try testing.expectEqual(TraceEventKind.send, events[1].kind);
    try testing.expectEqual(@as(u64, 11), events[1].pid_bits);
    try testing.expectEqual(@as(u64, 22), events[1].peer_pid_bits);

    try testing.expectEqual(TraceEventKind.receive, events[2].kind);
    try testing.expectEqual(@as(u64, 22), events[2].pid_bits);

    try testing.expectEqual(TraceEventKind.exit, events[3].kind);
    try testing.expectEqual(@as(u8, 1), events[3].detail);
    // Strictly increasing sequence — the "in order" guarantee.
    try testing.expect(events[0].sequence < events[1].sequence);
    try testing.expect(events[1].sequence < events[2].sequence);
    try testing.expect(events[2].sequence < events[3].sequence);
}

test "TraceRing: overwrite keeps exactly the newest capacity events" {
    var ring: TraceRing(4) = .empty;
    var emitted: u64 = 0;
    while (emitted < 11) : (emitted += 1) {
        ring.emit(emitted, .send, 0, emitted, emitted + 1);
    }
    var events: [4]TraceEventRecord = undefined;
    const captured = ring.capture(&events);
    try testing.expectEqual(@as(usize, 4), captured);
    try testing.expectEqual(@as(u64, 11), ring.emittedTotal());
    // The newest four events, oldest first: sequences 7, 8, 9, 10.
    for (events[0..captured], 0..) |event, index| {
        try testing.expectEqual(@as(u64, 7 + index), event.sequence);
        try testing.expectEqual(@as(u64, 7 + index), event.pid_bits);
    }
}

test "TraceRing: a short destination receives the oldest retained events" {
    var ring: TraceRing(8) = .empty;
    ring.emit(1, .spawn, 0, 1, 0);
    ring.emit(2, .send, 0, 1, 2);
    ring.emit(3, .exit, 0, 1, 0);
    var events: [2]TraceEventRecord = undefined;
    const captured = ring.capture(&events);
    try testing.expectEqual(@as(usize, 2), captured);
    try testing.expectEqual(TraceEventKind.spawn, events[0].kind);
    try testing.expectEqual(TraceEventKind.send, events[1].kind);
}

test "TraceRing: reset discards retained events and restarts sequencing" {
    var ring: TraceRing(4) = .empty;
    ring.emit(1, .spawn, 0, 5, 0);
    ring.emit(2, .exit, 0, 5, 0);
    ring.reset();
    var events: [4]TraceEventRecord = undefined;
    try testing.expectEqual(@as(usize, 0), ring.capture(&events));
    try testing.expectEqual(@as(u64, 0), ring.emittedTotal());
    ring.emit(3, .receive, 0, 7, 0);
    try testing.expectEqual(@as(usize, 1), ring.capture(&events));
    try testing.expectEqual(@as(u64, 0), events[0].sequence);
    try testing.expectEqual(@as(u64, 7), events[0].pid_bits);
}

test "TraceRing: concurrent producers lose nothing and every entry is coherent" {
    // Cross-thread accounting proof (TSan runs this): four producer
    // threads hammer one ring; afterwards the retained window is fully
    // coherent (every captured entry's pid/peer/detail agree with the
    // producer encoding) and the total equals the sum of emissions.
    const producer_count = 4;
    const events_per_producer = 4096;
    const Ring = TraceRing(1024);
    const ring = try testing.allocator.create(Ring);
    defer testing.allocator.destroy(ring);
    ring.* = .empty;

    const Producer = struct {
        fn run(target_ring: *Ring, producer_index: u64) void {
            var emitted: u64 = 0;
            while (emitted < events_per_producer) : (emitted += 1) {
                // pid encodes producer + local index; peer = pid + 1 —
                // the coherence invariant the reader checks.
                const pid_bits = (producer_index << 32) | emitted;
                target_ring.emit(emitted, .send, @intCast(producer_index), pid_bits, pid_bits + 1);
            }
        }
    };

    var threads: [producer_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, producer_index| {
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{ ring, @as(u64, producer_index) });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(
        @as(u64, producer_count * events_per_producer),
        ring.emittedTotal(),
    );
    var events: [1024]TraceEventRecord = undefined;
    const captured = ring.capture(&events);
    // Quiescent capture: the full retained window is readable.
    try testing.expectEqual(@as(usize, 1024), captured);
    var previous_sequence: u64 = 0;
    for (events[0..captured], 0..) |event, index| {
        if (index > 0) try testing.expect(event.sequence > previous_sequence);
        previous_sequence = event.sequence;
        try testing.expectEqual(TraceEventKind.send, event.kind);
        try testing.expectEqual(event.pid_bits + 1, event.peer_pid_bits);
        try testing.expectEqual(@as(u64, event.detail), event.pid_bits >> 32);
    }
}
