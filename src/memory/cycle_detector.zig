//! Bacon–Rajan synchronous trial-deletion cycle detector (Phase 4.d).
//!
//! This module implements the diagnostic-mode reference-cycle detector
//! described in `docs/error-system-research-brief.md` Part V + Part VII
//! Decision 3 (Bacon & Rajan, "Concurrent Cycle Collection in Reference
//! Counted Systems", ECOOP 2001 — the *synchronous* variant). It finds
//! groups of reference-counted heap objects that keep each other alive
//! through a reference cycle and would therefore never be released by the
//! base Perceus / ARC reference-counting scheme.
//!
//! ## Diagnostic only — this detector REPORTS, it does NOT free.
//!
//! Reclaiming a detected cycle requires breaking one of its edges, which
//! in turn requires the `weak`/`unowned` reference qualifiers that are the
//! Phase 5 deliverable (the cycle *fix*). Until then this engine is a pure
//! observer: it identifies the participating objects and hands them to the
//! unified diagnostic renderer as a `domain=cycle` report so a developer
//! sees exactly which `%Type{} → %Type{}` retain path leaks.
//!
//! ## Phase-5 note: cycles are not user-constructible from today's Zap.
//!
//! Zap's surface syntax is fully immutable in this phase: there is no
//! field-mutation operator, no `Ref`/`Cell`/`Atom` mutable primitive, and
//! functional update (`%R{r | f: v}`) always creates a NEW value. A
//! value-level ARC reference cycle therefore CANNOT be built bottom-up —
//! every `%Node{next: Some(other)}` requires `other` to already exist, so
//! allocations only ever point at strictly-older allocations and the loop
//! can never close. This detector is consequently *preemptive
//! infrastructure*: it is built and tested now (via the runtime-level unit
//! tests in this file, which assemble cyclic `ArcHeader` graphs directly),
//! ready to exercise the moment Phase 5 lands mutation / `Ref` / `weak`.
//! Both user-constructible cycles AND the `weak`/`unowned` cycle FIX are
//! Phase 5 work; see the brief's Phase 5 section.
//!
//! ## Algorithm (trial deletion)
//!
//! Given a set of *candidate* roots (objects whose refcount was decremented
//! to a still-positive value — a possible cycle root — or, under
//! `Memory.Tracking`, every survivor in the deinit live-set):
//!
//!   1. **Mark.** For every candidate, walk its ARC children via the
//!      compiler-emitted per-type child enumeration and *trial-decrement*
//!      each reachable tracked node's refcount in a private scratch table.
//!      This simulates deleting every internal (candidate-to-candidate)
//!      reference.
//!   2. **Scan.** Any node whose trial refcount is still > 0 after the mark
//!      is held alive by a reference from OUTSIDE the candidate set — it is
//!      externally referenced and live. Restore it and everything reachable
//!      from it (re-increment the trial counts back through its subgraph).
//!      Any node that reached exactly 0 is tentatively garbage.
//!   3. **Collect.** Nodes that are STILL 0 after the scan are reachable
//!      only through internal cycle edges: they form the cyclic strongly
//!      connected component(s). REPORT them; do not free.
//!
//! This correctly avoids false positives: an acyclic graph that is held by
//! an external owner has a node whose real refcount exceeds its internal
//! in-degree, so its trial count stays > 0, ScanBlack restores the whole
//! subgraph, and nothing is collected.
//!
//! ## Generality (no hardcoded Zap type names)
//!
//! The engine never names a Zap type. Each candidate carries a type-erased
//! `cycle_walk` closure produced at the allocation site by `CycleWalkFnFor`
//! (the non-destructive sibling of the runtime's `DeepWalkFnFor`): it
//! enumerates exactly the same ARC children as the destructive deep-walk
//! but invokes a runtime visitor per child instead of releasing it. The
//! Zap type name flows in as borrowed `.rodata`, identical to the Phase 4.c
//! leak-attribution path.

const std = @import("std");

/// Read the current reference count of a candidate object. Supplied by the
/// owning manager: under `Memory.ARC` this consults the side-table /
/// inline-header refcount via the slab lookup (size + alignment locate the
/// class); under `Memory.Tracking` (no refcounts) the construction-site
/// count of `1` is synthesized. Returns the live count at call time.
pub const RefcountReadFn = *const fn (object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32;

/// Per-child visitor invoked by a `CycleWalkFn`. `child_object` is the
/// pointer to one ARC-managed child cell of the object being walked. The
/// visitor is the engine's mark / scan / restore action; it is the seam
/// that lets the SAME comptime child-enumeration drive every phase of the
/// algorithm without the enumeration knowing which phase is running.
pub const CycleChildVisitor = *const fn (visitor_ctx: ?*anyopaque, child_object: *anyopaque) callconv(.c) void;

/// Non-destructive per-type child enumeration. Mirrors the runtime's
/// `DeepWalkFnFor(T)` child set EXACTLY — every `.pointer(.one)` /
/// `ProtocolBox` / nested-aggregate / active-union-variant ARC child the
/// destructive deep-walk would release — but instead of releasing each
/// child it invokes `visitor(visitor_ctx, child_object)`. Produced at the
/// allocation site (where `T` is known) and stored type-erased on the
/// candidate. `null` for flat types with no ARC children.
pub const CycleWalkFn = *const fn (object: *anyopaque, visitor_ctx: ?*anyopaque, visitor: CycleChildVisitor) callconv(.c) void;

/// One cycle-detection candidate: a heap object plus the metadata needed
/// to read its refcount, enumerate its ARC children non-destructively, and
/// attribute it in the report. Candidates are pushed onto the purple
/// buffer (ARC, on decrement-to-positive) or synthesized from the live-set
/// (Tracking, at deinit).
pub const Candidate = struct {
    /// The reference-counted cell pointer (the user pointer the manager
    /// hands out — the same value the refcount read + child walk expect).
    object: *anyopaque,

    /// User-visible allocation size in bytes. Needed to locate the slab
    /// class for the refcount read under ARC, and reported as the bytes
    /// held by the cycle.
    size: usize,

    /// User-visible allocation alignment. Half of the slab-class key.
    alignment: u32,

    /// Refcount reader for this object's manager.
    refcount_read: RefcountReadFn,

    /// Non-destructive child enumerator for this object's concrete type, or
    /// `null` when the type carries no ARC children (a flat cell can never
    /// be part of a cycle — it has no outgoing edges).
    cycle_walk: ?CycleWalkFn,

    /// Borrowed `.rodata` Zap type label (e.g. `User` for `%User{}`), or
    /// empty when the allocation was not attributed. Never freed here.
    type_name_ptr: ?[*]const u8 = null,
    type_name_len: usize = 0,

    /// Allocation-site return addresses (borrowed). Symbolized by the
    /// report sink, exactly like a leak record's backtrace.
    backtrace_ptr: ?[*]const usize = null,
    backtrace_len: usize = 0,

    pub fn typeName(self: *const Candidate) []const u8 {
        if (self.type_name_len == 0) return "";
        return self.type_name_ptr.?[0..self.type_name_len];
    }
};

/// The color of a node during trial deletion, tracked in the scratch
/// table. Mirrors the Bacon–Rajan node colors restricted to the
/// synchronous trial-deletion subset this detector uses.
const NodeColor = enum {
    /// Reached during the mark phase; trial-decrement in progress. The
    /// node is a member of the candidate-reachable subgraph.
    gray,
    /// Proven externally referenced (trial count returned > 0 in scan) and
    /// restored — live, not garbage.
    black,
    /// Tentatively garbage: trial count reached 0 and the scan has not (yet)
    /// restored it.
    white,
};

/// Per-node scratch state for one detection pass. Keyed by object pointer
/// in `Engine.nodes`. `trial_rc` is a SIGNED running count so an
/// over-decrement (which a malformed graph could in principle produce) is
/// observable rather than wrapping; a correct graph keeps it >= 0.
const NodeState = struct {
    /// Index of the owning `Candidate` in the engine's candidate slice when
    /// this node is itself a candidate, else `null` (a child that is not a
    /// candidate root — reachable but not independently buffered).
    candidate_index: ?usize,
    /// The real refcount sampled once on first visit.
    real_rc: u32,
    /// Running trial count: real_rc minus internal in-edges seen so far,
    /// restored upward during scan.
    trial_rc: i64,
    color: NodeColor,
    /// Set once the node has been scanned (prevents re-scanning in the
    /// recursive scan/restore walk).
    scanned: bool,
    /// The candidate metadata for this node (object/size/walk/type), copied
    /// so children-that-are-not-candidates can still be re-walked during
    /// scan and enumerated for the report. For non-candidate children the
    /// `type_name`/backtrace fields are empty.
    info: Candidate,
};

/// A single detected cyclic component: the participating objects (by
/// pointer) plus the aggregate bytes they hold. The report renderer turns
/// this into a `domain=cycle` diagnostic.
pub const DetectedCycle = struct {
    /// Object pointers of the cycle members, in the deterministic order the
    /// engine emits (sorted — see `Engine.collect`).
    members: []const CycleMember,
    /// Total user bytes held by the cycle members.
    total_bytes: usize,
};

/// One member of a detected cycle, carrying enough to render its line in
/// the participating-types retain path.
pub const CycleMember = struct {
    object: *anyopaque,
    size: usize,
    type_name_ptr: ?[*]const u8,
    type_name_len: usize,
    backtrace_ptr: ?[*]const usize,
    backtrace_len: usize,

    pub fn typeName(self: *const CycleMember) []const u8 {
        if (self.type_name_len == 0) return "";
        return self.type_name_ptr.?[0..self.type_name_len];
    }
};

/// The trial-deletion engine. Allocates its scratch table from the
/// supplied allocator (the runtime passes `page_allocator`, matching the
/// tracking manager — no libc dependency). One `Engine` drives one
/// detection pass over a candidate set and collects the cyclic components.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Scratch node table for the current pass, keyed by `@intFromPtr`.
    nodes: std.AutoHashMapUnmanaged(usize, NodeState) = .empty,
    /// Object pointers of nodes that ended the scan white (cycle garbage),
    /// accumulated by `collect`.
    white_set: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine) void {
        self.nodes.deinit(self.allocator);
        self.white_set.deinit(self.allocator);
    }

    /// Run trial deletion over `candidates` and return the set of object
    /// pointers that form cyclic garbage (the white set after scan).
    ///
    /// NOTE: deliberately incomplete in this first TDD step — it builds the
    /// node table but performs no mark/scan/collect, so it reports NO cycle.
    /// The failing test below pins the contract; the engine body lands next.
    pub fn detect(self: *Engine, candidates: []const Candidate) error{OutOfMemory}![]const usize {
        _ = candidates;
        return self.white_set.items;
    }
};

// ===========================================================================
// Runtime-level unit tests (Phase 4.d).
//
// Per the resolved Phase 4.d decision, cycles are exercised by assembling
// cyclic `ArcHeader`-style object graphs DIRECTLY at the runtime level (no
// throwaway language primitive) and driving the trial-deletion engine over
// them. These tests construct the graphs with a plain test allocator and a
// hand-written refcount model so they validate the ALGORITHM independent of
// any specific manager.
// ===========================================================================

const testing = std.testing;

/// A minimal two-field test node: a refcount and up to two outgoing edges
/// to other test nodes. Stands in for an ARC cell whose Zap fields are
/// `next`/`other` pointers. The cycle detector treats it via a
/// `CycleWalkFn` that enumerates the non-null edges.
const TestNode = struct {
    rc: u32,
    edges: [2]?*TestNode = .{ null, null },
};

fn testRefcountRead(object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = size;
    _ = alignment;
    const node: *TestNode = @ptrCast(@alignCast(object));
    return node.rc;
}

fn testCycleWalk(object: *anyopaque, visitor_ctx: ?*anyopaque, visitor: CycleChildVisitor) callconv(.c) void {
    const node: *TestNode = @ptrCast(@alignCast(object));
    for (node.edges) |maybe_edge| {
        if (maybe_edge) |edge| visitor(visitor_ctx, @ptrCast(edge));
    }
}

fn testCandidate(node: *TestNode) Candidate {
    return .{
        .object = @ptrCast(node),
        .size = @sizeOf(TestNode),
        .alignment = @alignOf(TestNode),
        .refcount_read = testRefcountRead,
        .cycle_walk = testCycleWalk,
    };
}

test "trial deletion detects a 2-node mutual reference cycle" {
    // Two nodes that reference each other and nothing else.
    //   a.edges[0] -> b      b.edges[0] -> a
    // Each is kept alive solely by the other: rc == 1, entirely from the
    // internal cycle edge. No external owner. This MUST be detected.
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&a), testCandidate(&b) };
    const garbage = try engine.detect(&candidates);

    // Both nodes are cyclic garbage.
    try testing.expectEqual(@as(usize, 2), garbage.len);
}
