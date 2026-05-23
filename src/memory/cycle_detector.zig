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

/// A fully-described ARC child edge yielded by a `CycleWalkFn`. Because the
/// destructive deep-walk knows each child field's CONCRETE static type at
/// comptime (the `.pointer(.one)` case in `releaseFieldChildAny` has
/// `p.child`), the non-destructive cycle walk can — at that same comptime
/// site — synthesize the child's own refcount reader, child enumerator, and
/// type label and hand them to the visitor. This is what makes the engine
/// self-sufficient: it discovers reachable non-candidate nodes (cycle
/// members that were never independently buffered) through the walk WITH
/// full metadata, instead of needing them pre-registered as candidates.
pub const ChildRef = struct {
    /// The child cell pointer.
    object: *anyopaque,
    /// The child's user-visible size / alignment (its own static type's),
    /// for the refcount read and the bytes-held report.
    size: usize,
    alignment: u32,
    /// The child's refcount reader (its manager's — same as the parent's in
    /// a single-manager binary).
    refcount_read: RefcountReadFn,
    /// The child's own non-destructive child enumerator, or `null` if the
    /// child type is flat.
    cycle_walk: ?CycleWalkFn,
    /// Borrowed `.rodata` type label for the child, or empty.
    type_name_ptr: ?[*]const u8 = null,
    type_name_len: usize = 0,
};

/// Per-child visitor invoked by a `CycleWalkFn`, once per ARC-managed child
/// edge with a fully-populated `ChildRef`. The visitor is the engine's mark
/// / scan / restore action; it is the seam that lets the SAME comptime
/// child-enumeration drive every phase of the algorithm without the
/// enumeration knowing which phase is running.
pub const CycleChildVisitor = *const fn (visitor_ctx: ?*anyopaque, child: *const ChildRef) callconv(.c) void;

/// Non-destructive per-type child enumeration. Mirrors the runtime's
/// `DeepWalkFnFor(T)` child set EXACTLY — every `.pointer(.one)` /
/// `ProtocolBox` / nested-aggregate / active-union-variant ARC child the
/// destructive deep-walk would release — but instead of releasing each
/// child it invokes `visitor(visitor_ctx, &child_ref)`. Produced at the
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

// ===========================================================================
// Report model + renderer (`domain=cycle`).
//
// The renderer is writer-generic and side-effect-free so the EXACT bytes are
// unit-testable here (against a fixed buffer) while the runtime drives it
// through an async-signal-safe `write(2)` adapter. Symbolization (address →
// file:line) is the runtime's job (it owns DWARF); the renderer consumes
// already-resolved data via `RenderMember.source`, identical in spirit to how
// the leak renderer resolves the alloc site before writing.
// ===========================================================================

/// Visual-language glyph + SGR vocabulary, mirroring `RuntimeFormat` in
/// `src/runtime.zig` so a `domain=cycle` runtime report reads identically to
/// the compile renderer's cycle diagnostic and to the leak report. The
/// drift guard in `tools/error_format_drift_test.zig` covers the runtime
/// mirror; these are re-stated here (the only consumer that cannot import
/// `runtime.zig`) and pinned by the render tests below.
pub const Format = struct {
    pub const frame_indent = "  ";
    pub const source_line_separator = ":";
    pub const gutter_bar = "\u{2502}";
    pub const footer_corner = "\u{2514}\u{2500}";
    pub const retain_arrow = " \u{2192} "; // " → "
    pub const sgr_reset = "\x1b[0m";
    pub const sgr_bold = "\x1b[1m";
    pub const sgr_bold_yellow = "\x1b[1;33m";
    pub const sgr_cyan = "\x1b[36m";
};

/// Output format selector — text (human) or JSON (machine / LSP / CI),
/// matching the leak report's `LeakReportFormat`.
pub const ReportFormat = enum { text, json };

/// A resolved source location for a member's allocation site. Borrowed for
/// the render call only.
pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
};

/// One member as the renderer sees it: its Zap type label, bytes held, and
/// (optionally) its resolved allocation site. The runtime fills `source`
/// from the symbolized backtrace; a unit test supplies it directly.
pub const RenderMember = struct {
    type_name: []const u8,
    size: usize,
    source: ?SourceLocation = null,
};

/// The full renderable cycle: the participating members in deterministic
/// (engine) order plus the aggregate bytes. The retain path is rendered as
/// `%A{} → %B{} → %A{}` (closing back to the first member to make the cycle
/// visually explicit).
pub const RenderView = struct {
    members: []const RenderMember,
    total_bytes: usize,
};

/// Write a Zap type label: `` `%Name{}` `` when named, or a neutral
/// `an allocation` when the type was not attributed (so the line still
/// reads naturally — identical to the leak renderer's `writeLeakTypeLabel`).
fn writeTypeLabel(writer: anytype, type_name: []const u8) !void {
    if (type_name.len == 0) {
        try writer.writeAll("an allocation");
        return;
    }
    try writer.writeAll("`%");
    try writer.writeAll(type_name);
    try writer.writeAll("{}`");
}

/// Bare `%Name{}` (no backticks) for the inline retain path, or `?` when the
/// type was not attributed.
fn writePathNode(writer: anytype, type_name: []const u8) !void {
    if (type_name.len == 0) {
        try writer.writeAll("?");
        return;
    }
    try writer.writeAll("%");
    try writer.writeAll(type_name);
    try writer.writeAll("{}");
}

fn writeJsonStringBody(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write an unsigned integer as base-10 ASCII through the minimal
/// `writeAll`-only writer interface. Kept here (rather than relying on a
/// writer `.print`) so the renderer works equally over a `std.Io.Writer`
/// fixed buffer (the unit tests) and the runtime's async-signal-safe
/// `write(2)` adapter, neither of which need a `print` implementation.
fn writeUnsigned(writer: anytype, value: usize) !void {
    var tmp: [20]u8 = undefined; // u64 max is 20 digits
    var i: usize = tmp.len;
    var v = value;
    if (v == 0) {
        try writer.writeAll("0");
        return;
    }
    while (v != 0) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    try writer.writeAll(tmp[i..]);
}

/// Render one detected cycle as a unified `domain=cycle` diagnostic.
///
/// Text shape (unified visual language — header, gutter, retain path,
/// per-member alloc sites, footer corner):
///
///   warning: reference cycle: 2 objects (80 B) held alive by a cycle
///     │  retain path: %A{} → %B{} → %A{}
///     │
///     %A{} (40 B), allocated at app.zap:12
///     %B{} (40 B), allocated at app.zap:18
///     └─ reference cycle (no owner outside the cycle)
///
/// JSON shape mirrors the canonical Error IR `domain=cycle` projection:
/// `domain`/`severity`/`sub_kind`/`trace_policy`/`message` + a `machine_data`
/// object carrying `object_count`/`bytes`/`participants[]` (each with `type`
/// and optional `allocated_at`).
pub fn renderReport(
    writer: anytype,
    view: RenderView,
    format: ReportFormat,
    color: bool,
) !void {
    switch (format) {
        .text => try renderReportText(writer, view, color),
        .json => try renderReportJson(writer, view),
    }
}

fn renderReportText(writer: anytype, view: RenderView, color: bool) !void {
    // Header.
    if (color) try writer.writeAll(Format.sgr_bold_yellow);
    try writer.writeAll("warning: ");
    if (color) try writer.writeAll(Format.sgr_reset);
    if (color) try writer.writeAll(Format.sgr_bold);
    try writer.writeAll("reference cycle: ");
    try writeUnsigned(writer, view.members.len);
    try writer.writeAll(if (view.members.len == 1) " object (" else " objects (");
    try writeUnsigned(writer, view.total_bytes);
    try writer.writeAll(" B) held alive by a cycle");
    if (color) try writer.writeAll(Format.sgr_reset);
    try writer.writeAll("\n");

    // Gutter + retain path line.
    try writer.writeAll(Format.frame_indent);
    if (color) try writer.writeAll(Format.sgr_cyan);
    try writer.writeAll(Format.gutter_bar);
    if (color) try writer.writeAll(Format.sgr_reset);
    try writer.writeAll("  retain path: ");
    for (view.members, 0..) |m, i| {
        if (i != 0) try writer.writeAll(Format.retain_arrow);
        try writePathNode(writer, m.type_name);
    }
    // Close the cycle back to the first member so the loop is explicit.
    if (view.members.len > 0) {
        try writer.writeAll(Format.retain_arrow);
        try writePathNode(writer, view.members[0].type_name);
    }
    try writer.writeAll("\n");

    // Blank gutter line.
    try writer.writeAll(Format.frame_indent);
    if (color) try writer.writeAll(Format.sgr_cyan);
    try writer.writeAll(Format.gutter_bar);
    if (color) try writer.writeAll(Format.sgr_reset);
    try writer.writeAll("\n");

    // Per-member detail lines.
    for (view.members) |m| {
        try writer.writeAll(Format.frame_indent);
        try writeTypeLabel(writer, m.type_name);
        try writer.writeAll(" (");
        try writeUnsigned(writer, m.size);
        try writer.writeAll(" B)");
        if (m.source) |loc| {
            try writer.writeAll(", allocated at ");
            try writer.writeAll(loc.file);
            try writer.writeAll(Format.source_line_separator);
            try writeUnsigned(writer, loc.line);
        }
        try writer.writeAll("\n");
    }

    // Footer corner.
    try writer.writeAll(Format.frame_indent);
    if (color) try writer.writeAll(Format.sgr_cyan);
    try writer.writeAll(Format.footer_corner);
    if (color) try writer.writeAll(Format.sgr_reset);
    try writer.writeAll(" reference cycle (no owner outside the cycle)\n");
}

fn renderReportJson(writer: anytype, view: RenderView) !void {
    try writer.writeAll("{\"domain\":\"cycle\",\"severity\":\"warning\",\"sub_kind\":\"reference_cycle\",\"trace_policy\":\"allocation\",\"message\":\"reference cycle: ");
    try writeUnsigned(writer, view.members.len);
    try writer.writeAll(if (view.members.len == 1) " object held alive by a cycle" else " objects held alive by a cycle");
    try writer.writeAll("\",\"machine_data\":{\"object_count\":");
    try writeUnsigned(writer, view.members.len);
    try writer.writeAll(",\"bytes\":");
    try writeUnsigned(writer, view.total_bytes);
    try writer.writeAll(",\"participants\":[");
    for (view.members, 0..) |m, i| {
        if (i != 0) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"");
        try writeJsonStringBody(writer, m.type_name);
        try writer.writeAll("\",\"bytes\":");
        try writeUnsigned(writer, m.size);
        if (m.source) |loc| {
            try writer.writeAll(",\"allocated_at\":{\"file\":\"");
            try writeJsonStringBody(writer, loc.file);
            try writer.writeAll("\",\"line\":");
            try writeUnsigned(writer, loc.line);
            try writer.writeAll("}");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}}\n");
}

/// The trial-deletion engine. Allocates its scratch table from the
/// supplied allocator (the runtime passes `page_allocator`, matching the
/// tracking manager — no libc dependency). One `Engine` drives one
/// detection pass over a candidate set and collects the cyclic components.
///
/// ## Why a scratch table keyed by object pointer
///
/// Trial deletion must NOT mutate the real objects (this is a diagnostic
/// pass — the objects are still live and may keep being used). The signed
/// `trial_rc` per node lives entirely in this side table; the only thing
/// read from the real object is its refcount (once, on first visit) and its
/// children (via the type-erased `cycle_walk`). The table also lets the
/// recursive scan / restore terminate on revisit (the `color` / `scanned`
/// flags), which a naive recursion over a cyclic graph could not.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    /// Scratch node table for the current pass, keyed by `@intFromPtr`.
    nodes: std.AutoHashMapUnmanaged(usize, NodeState) = .empty,
    /// Object pointers of nodes that ended the scan white (cycle garbage),
    /// accumulated by `collect`, in deterministic (pointer-sorted) order.
    white_set: std.ArrayListUnmanaged(usize) = .empty,
    /// Deferred allocation failure from inside a `callconv(.c)` visitor
    /// (which cannot itself return an error). Checked after each walk; a
    /// set flag aborts the pass cleanly without swallowing OOM.
    oom: bool = false,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine) void {
        self.nodes.deinit(self.allocator);
        self.white_set.deinit(self.allocator);
    }

    /// Run trial deletion over `candidates` and return the object pointers
    /// that form cyclic garbage (the white set after scan), sorted
    /// ascending so the result — and any report derived from it — is
    /// deterministic across runs regardless of candidate / hash-map order.
    ///
    /// The candidate set need not be closed under reachability: the mark
    /// walk discovers reachable non-candidate children (with full metadata
    /// via `ChildRef`) and adds them to the table. Returns an empty slice
    /// when no cycle is present (the common, cycle-free case).
    pub fn detect(self: *Engine, candidates: []const Candidate) error{OutOfMemory}![]const usize {
        self.nodes.clearRetainingCapacity();
        self.white_set.clearRetainingCapacity();
        self.oom = false;

        // Phase 1 — seed the table with every candidate, then mark: walk
        // each node's children once and trial-decrement every internal edge.
        try self.seedCandidates(candidates);
        try self.markAll();

        // Phase 2 — scan: a candidate whose trial count survived > 0 is
        // externally referenced; restore it and its subgraph (black). The
        // rest go white (tentative garbage).
        try self.scanAll();

        // Phase 3 — collect: nodes still white are cyclic garbage.
        try self.collectWhite();

        return self.white_set.items;
    }

    /// Insert a node into the scratch table if absent, sampling its real
    /// refcount once. Returns a pointer to the (new or existing) state.
    fn ensureNode(self: *Engine, info: Candidate, candidate_index: ?usize) error{OutOfMemory}!*NodeState {
        const key = @intFromPtr(info.object);
        const gop = try self.nodes.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            const rc = info.refcount_read(info.object, info.size, info.alignment);
            gop.value_ptr.* = .{
                .candidate_index = candidate_index,
                .real_rc = rc,
                .trial_rc = @intCast(rc),
                .color = .gray,
                .scanned = false,
                .info = info,
            };
        } else if (candidate_index != null and gop.value_ptr.candidate_index == null) {
            // A node first discovered as a child is later found to also be a
            // candidate root — record its candidate index + carry the richer
            // attribution (type/backtrace) from the candidate record.
            gop.value_ptr.candidate_index = candidate_index;
            gop.value_ptr.info = info;
        }
        return gop.value_ptr;
    }

    fn seedCandidates(self: *Engine, candidates: []const Candidate) error{OutOfMemory}!void {
        for (candidates, 0..) |cand, i| {
            _ = try self.ensureNode(cand, i);
        }
    }

    // ----- Mark -----------------------------------------------------------
    //
    // For every node in the table, walk its children ONCE and trial-
    // decrement each child that is a tracked node. A child not yet in the
    // table is added (a reachable non-candidate) and then decremented. The
    // single-visit guard is the `gray`+marked flag: Bacon–Rajan marks each
    // node gray exactly once.

    const MarkCtx = struct { engine: *Engine };

    fn markVisitor(visitor_ctx: ?*anyopaque, child: *const ChildRef) callconv(.c) void {
        const ctx: *MarkCtx = @ptrCast(@alignCast(visitor_ctx.?));
        const self = ctx.engine;
        if (self.oom) return;
        const child_info: Candidate = .{
            .object = child.object,
            .size = child.size,
            .alignment = child.alignment,
            .refcount_read = child.refcount_read,
            .cycle_walk = child.cycle_walk,
            .type_name_ptr = child.type_name_ptr,
            .type_name_len = child.type_name_len,
        };
        const state = self.ensureNode(child_info, null) catch {
            self.oom = true;
            return;
        };
        // Trial-decrement: this edge is internal to the candidate-reachable
        // subgraph, so "delete" it.
        state.trial_rc -= 1;
    }

    fn markAll(self: *Engine) error{OutOfMemory}!void {
        // The mark walk may add new (child) nodes to the table mid-iteration,
        // which would invalidate a live iterator. Work over a worklist of
        // object keys, draining newly-discovered nodes until fixpoint.
        var worklist: std.ArrayListUnmanaged(usize) = .empty;
        defer worklist.deinit(self.allocator);

        var it = self.nodes.keyIterator();
        while (it.next()) |k| try worklist.append(self.allocator, k.*);

        var marked: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer marked.deinit(self.allocator);

        var ctx: MarkCtx = .{ .engine = self };
        var head: usize = 0;
        while (head < worklist.items.len) : (head += 1) {
            const key = worklist.items[head];
            if (marked.contains(key)) continue;
            try marked.put(self.allocator, key, {});

            const before_count = self.nodes.count();
            const state = self.nodes.getPtr(key).?;
            if (state.info.cycle_walk) |walk| {
                walk(state.info.object, &ctx, markVisitor);
                if (self.oom) return error.OutOfMemory;
            }
            // If the walk discovered new nodes, enqueue them so their own
            // children get marked too.
            if (self.nodes.count() != before_count) {
                var new_it = self.nodes.keyIterator();
                while (new_it.next()) |nk| {
                    if (!marked.contains(nk.*)) {
                        var already_queued = false;
                        for (worklist.items[head + 1 ..]) |q| {
                            if (q == nk.*) {
                                already_queued = true;
                                break;
                            }
                        }
                        if (!already_queued) try worklist.append(self.allocator, nk.*);
                    }
                }
            }
        }
    }

    // ----- Scan -----------------------------------------------------------
    //
    // For each node: if its trial count is > 0 it is held by an external
    // reference → ScanBlack (restore it and re-increment every child,
    // recursively restoring the reachable subgraph). Otherwise it is
    // tentatively white. Scanning is idempotent via the `scanned` flag.

    const ScanCtx = struct { engine: *Engine, mode: enum { scan, black } };

    fn scanAll(self: *Engine) error{OutOfMemory}!void {
        // Deterministic scan order: by object pointer. (The set of white
        // nodes is order-independent, but a fixed order keeps any future
        // order-sensitive instrumentation stable.)
        var keys: std.ArrayListUnmanaged(usize) = .empty;
        defer keys.deinit(self.allocator);
        var it = self.nodes.keyIterator();
        while (it.next()) |k| try keys.append(self.allocator, k.*);
        std.mem.sort(usize, keys.items, {}, std.sort.asc(usize));

        for (keys.items) |key| {
            try self.scanNode(key);
            if (self.oom) return error.OutOfMemory;
        }
    }

    fn scanNode(self: *Engine, key: usize) error{OutOfMemory}!void {
        const state = self.nodes.getPtr(key) orelse return;
        if (state.scanned) return;
        if (state.trial_rc > 0) {
            try self.scanBlack(key);
        } else {
            state.color = .white;
            state.scanned = true;
            // Recurse into children so they also get scanned.
            var ctx: ScanCtx = .{ .engine = self, .mode = .scan };
            if (state.info.cycle_walk) |walk| {
                walk(state.info.object, &ctx, scanVisitor);
                if (self.oom) return error.OutOfMemory;
            }
        }
    }

    fn scanBlack(self: *Engine, key: usize) error{OutOfMemory}!void {
        const state = self.nodes.getPtr(key) orelse return;
        // Restoring a node: paint it black and mark scanned. Re-incrementing
        // its children's trial counts + recursively blackening them undoes
        // the trial deletion for the externally-referenced subgraph.
        state.color = .black;
        state.scanned = true;
        var ctx: ScanCtx = .{ .engine = self, .mode = .black };
        if (state.info.cycle_walk) |walk| {
            walk(state.info.object, &ctx, scanVisitor);
            if (self.oom) return error.OutOfMemory;
        }
    }

    fn scanVisitor(visitor_ctx: ?*anyopaque, child: *const ChildRef) callconv(.c) void {
        const ctx: *ScanCtx = @ptrCast(@alignCast(visitor_ctx.?));
        const self = ctx.engine;
        if (self.oom) return;
        const key = @intFromPtr(child.object);
        const state = self.nodes.getPtr(key) orelse return;
        switch (ctx.mode) {
            .scan => {
                // Plain scan recursion: scan the child (black if it itself
                // survived, white otherwise).
                self.scanNode(key) catch {
                    self.oom = true;
                };
            },
            .black => {
                // Restore the edge we trial-deleted, then ensure the child
                // is black (it is reachable from an externally-referenced
                // node, so it is live too).
                state.trial_rc += 1;
                if (state.color != .black) {
                    self.scanBlack(key) catch {
                        self.oom = true;
                    };
                }
            },
        }
    }

    // ----- Collect --------------------------------------------------------

    fn collectWhite(self: *Engine) error{OutOfMemory}!void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.color == .white) {
                try self.white_set.append(self.allocator, entry.key_ptr.*);
            }
        }
        std.mem.sort(usize, self.white_set.items, {}, std.sort.asc(usize));
    }

    /// Look up the scratch state for an object pointer (the report builder
    /// reads `info`/`size`/`type_name` for each white member). Returns null
    /// for a pointer that was not part of this pass.
    pub fn nodeInfo(self: *const Engine, object: *anyopaque) ?Candidate {
        const state = self.nodes.get(@intFromPtr(object)) orelse return null;
        return state.info;
    }
};

// ===========================================================================
// Purple candidate buffer (Bacon–Rajan §"possible roots").
//
// A reference-counted object becomes a *possible cycle root* exactly when a
// `release` decrement leaves its refcount POSITIVE: it lost a reference but
// is still alive, so it might be part of a cycle that the lost reference was
// (partly) holding together. The classic optimization — and a HARD
// requirement here — is that a decrement-to-ZERO does NOT buffer anything:
// that object is being torn down on the spot (the common Perceus path), so it
// is irrelevant to cycle detection and the hot path pays nothing.
//
// `PurpleBuffer.recordDecrementToPositive(prev_refcount, object)` encodes that
// rule in ONE place: it enqueues the object only when `prev_refcount > 1`
// (i.e. the new count `prev-1` is > 0). The ARC manager calls it at its
// already-computed `prev > 1` release branch — zero added work on the
// decrement-to-zero branch, which never calls in.
//
// The buffer stores raw object pointers (roots). Full per-object descriptors
// (size / `cycle_walk` / type) are looked up at drain time from the
// alloc-time cycle registry, because release sites are type-erased while the
// allocation site (where the type is known) is not.
// ===========================================================================

/// Bounded purple candidate buffer. Fixed-capacity + dedup-on-overflow so a
/// release-heavy program never unbounded-grows the buffer; past capacity the
/// add is dropped (the live-set walk at drain still finds every survivor, so
/// dropping a redundant root only risks missing a cycle whose ONLY root
/// overflowed — acceptable for a diagnostic and noted). Stores `@intFromPtr`.
pub const PurpleBuffer = struct {
    /// Capacity chosen so the buffer is a few pages — large enough that real
    /// programs rarely overflow, small enough to be a fixed cost.
    pub const CAPACITY: usize = 8192;

    roots: [CAPACITY]usize = undefined,
    len: usize = 0,
    overflowed: bool = false,

    /// Record a release that left a POSITIVE refcount as a possible cycle
    /// root. `prev_refcount` is the count BEFORE the decrement (exactly the
    /// `prev` the ARC manager already holds). Does nothing — touches no
    /// memory beyond the early-return branch — when `prev_refcount <= 1`
    /// (the decrement-to-zero / sole-owner teardown path). THIS is the
    /// zero-hot-path guarantee.
    pub fn recordDecrementToPositive(self: *PurpleBuffer, prev_refcount: u32, object: *anyopaque) void {
        // Decrement to zero (prev == 1) or an impossible under-release
        // (prev == 0): NOT a cycle root. Return before touching the buffer.
        if (prev_refcount <= 1) return;
        self.recordRoot(object);
    }

    /// Append a root pointer (deduplication is the engine's job — duplicates
    /// only cost a redundant table insert there). Drops past capacity.
    pub fn recordRoot(self: *PurpleBuffer, object: *anyopaque) void {
        if (self.len >= CAPACITY) {
            self.overflowed = true;
            return;
        }
        self.roots[self.len] = @intFromPtr(object);
        self.len += 1;
    }

    pub fn items(self: *const PurpleBuffer) []const usize {
        return self.roots[0..self.len];
    }

    pub fn clear(self: *PurpleBuffer) void {
        self.len = 0;
        self.overflowed = false;
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
        if (maybe_edge) |edge| {
            // Every edge target is itself a `TestNode`, so its child
            // descriptor uses the same size/alignment/walk/reader. This is
            // the comptime-known-child-type case from `releaseFieldChildAny`.
            const child_ref: ChildRef = .{
                .object = @ptrCast(edge),
                .size = @sizeOf(TestNode),
                .alignment = @alignOf(TestNode),
                .refcount_read = testRefcountRead,
                .cycle_walk = testCycleWalk,
            };
            visitor(visitor_ctx, &child_ref);
        }
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
    try testing.expect(containsPtr(garbage, &a));
    try testing.expect(containsPtr(garbage, &b));
}

fn containsPtr(set: []const usize, node: anytype) bool {
    const want = @intFromPtr(node);
    for (set) |p| if (p == want) return true;
    return false;
}

test "trial deletion detects a self-cycle (node pointing at itself)" {
    // A single node holding a reference to itself: rc == 1, the one
    // reference being the self-edge. Pure garbage with no external owner.
    var a: TestNode = .{ .rc = 1 };
    a.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{testCandidate(&a)};
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 1), garbage.len);
    try testing.expect(containsPtr(garbage, &a));
}

test "trial deletion detects a 3-node ring" {
    // a -> b -> c -> a, each rc == 1 from its single incoming ring edge.
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    var c: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &c;
    c.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&a), testCandidate(&b), testCandidate(&c) };
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 3), garbage.len);
    try testing.expect(containsPtr(garbage, &a));
    try testing.expect(containsPtr(garbage, &b));
    try testing.expect(containsPtr(garbage, &c));
}

test "no false positive: externally-referenced acyclic graph is NOT collected" {
    // a -> b -> c, a chain held by an EXTERNAL owner (a.rc == 2: one from
    // the outside world, one would-be from a parent — here just the extra
    // external count). b.rc == 1 (from a), c.rc == 1 (from b). No cycle.
    // Trial deletion must leave nothing white.
    var a: TestNode = .{ .rc = 2 }; // +1 external reference
    var b: TestNode = .{ .rc = 1 };
    var c: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &c;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&a), testCandidate(&b), testCandidate(&c) };
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 0), garbage.len);
}

test "no false positive: a cycle reachable from a live external owner is NOT collected" {
    // root -> a,  a <-> b  (a and b form a cycle, but `a` ALSO has an
    // external reference via root). a.rc == 2 (b's edge + root's edge),
    // b.rc == 1 (a's edge), root.rc == 1 (external). Because the cycle is
    // kept alive from outside, it is live — NOT garbage.
    var root: TestNode = .{ .rc = 1 };
    var a: TestNode = .{ .rc = 2 };
    var b: TestNode = .{ .rc = 1 };
    root.edges[0] = &a;
    a.edges[0] = &b;
    b.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    // root is the candidate (it was released-to-positive); a and b are
    // discovered through the walk. None should be collected.
    const candidates = [_]Candidate{ testCandidate(&root), testCandidate(&a), testCandidate(&b) };
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 0), garbage.len);
}

test "mixed graph: isolated cycle collected, external acyclic subtree spared" {
    // Cycle: x <-> y (x.rc==1, y.rc==1) — pure garbage.
    // Separate live chain: p -> q held externally (p.rc==2, q.rc==1).
    // Only x and y are collected.
    var x: TestNode = .{ .rc = 1 };
    var y: TestNode = .{ .rc = 1 };
    x.edges[0] = &y;
    y.edges[0] = &x;

    var p: TestNode = .{ .rc = 2 }; // +1 external
    var q: TestNode = .{ .rc = 1 };
    p.edges[0] = &q;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{
        testCandidate(&x), testCandidate(&y),
        testCandidate(&p), testCandidate(&q),
    };
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 2), garbage.len);
    try testing.expect(containsPtr(garbage, &x));
    try testing.expect(containsPtr(garbage, &y));
    try testing.expect(!containsPtr(garbage, &p));
    try testing.expect(!containsPtr(garbage, &q));
}

test "result is deterministic: white set is pointer-sorted ascending" {
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&a), testCandidate(&b) };
    const garbage = try engine.detect(&candidates);
    try testing.expectEqual(@as(usize, 2), garbage.len);
    // Sorted ascending regardless of candidate order.
    try testing.expect(garbage[0] < garbage[1]);
}

test "flat candidate with no children is never garbage" {
    // A node with no cycle_walk (flat type) cannot participate in a cycle.
    var a: TestNode = .{ .rc = 1 };
    var engine = Engine.init(testing.allocator);
    defer engine.deinit();
    var cand = testCandidate(&a);
    cand.cycle_walk = null;
    const candidates = [_]Candidate{cand};
    const garbage = try engine.detect(&candidates);
    try testing.expectEqual(@as(usize, 0), garbage.len);
}

// ----- Report-rendering shape tests -----------------------------------------

test "render: text shape of a 2-node cycle (deterministic, no color)" {
    const members = [_]RenderMember{
        .{ .type_name = "A", .size = 40, .source = .{ .file = "app.zap", .line = 12 } },
        .{ .type_name = "B", .size = 40, .source = .{ .file = "app.zap", .line = 18 } },
    };
    const view: RenderView = .{ .members = &members, .total_bytes = 80 };

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderReport(&w, view, .text, false);
    const out = w.buffered();

    const expected =
        "warning: reference cycle: 2 objects (80 B) held alive by a cycle\n" ++
        "  \u{2502}  retain path: %A{} \u{2192} %B{} \u{2192} %A{}\n" ++
        "  \u{2502}\n" ++
        "  `%A{}` (40 B), allocated at app.zap:12\n" ++
        "  `%B{}` (40 B), allocated at app.zap:18\n" ++
        "  \u{2514}\u{2500} reference cycle (no owner outside the cycle)\n";
    try testing.expectEqualStrings(expected, out);
}

test "render: JSON shape of a 2-node cycle mirrors canonical domain=cycle" {
    const members = [_]RenderMember{
        .{ .type_name = "A", .size = 40, .source = .{ .file = "app.zap", .line = 12 } },
        .{ .type_name = "B", .size = 40, .source = null },
    };
    const view: RenderView = .{ .members = &members, .total_bytes = 80 };

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderReport(&w, view, .json, false);
    const out = w.buffered();

    const expected =
        "{\"domain\":\"cycle\",\"severity\":\"warning\",\"sub_kind\":\"reference_cycle\"," ++
        "\"trace_policy\":\"allocation\",\"message\":\"reference cycle: 2 objects held alive by a cycle\"," ++
        "\"machine_data\":{\"object_count\":2,\"bytes\":80,\"participants\":[" ++
        "{\"type\":\"A\",\"bytes\":40,\"allocated_at\":{\"file\":\"app.zap\",\"line\":12}}," ++
        "{\"type\":\"B\",\"bytes\":40}]}}\n";
    try testing.expectEqualStrings(expected, out);
}

// ----- Purple buffer + zero-hot-path tests ----------------------------------

test "zero hot path: a release-to-zero never touches the purple buffer" {
    var pb: PurpleBuffer = .{};
    var dummy: TestNode = .{ .rc = 0 };
    // prev_refcount == 1 means the decrement drops to zero (sole owner
    // teardown). This is the common Perceus path and MUST NOT enqueue.
    pb.recordDecrementToPositive(1, @ptrCast(&dummy));
    try testing.expectEqual(@as(usize, 0), pb.len);
    // prev_refcount == 0 (under-release / impossible) also enqueues nothing.
    pb.recordDecrementToPositive(0, @ptrCast(&dummy));
    try testing.expectEqual(@as(usize, 0), pb.len);
}

test "purple buffer enqueues only decrements that leave a positive count" {
    var pb: PurpleBuffer = .{};
    var a: TestNode = .{ .rc = 2 };
    var b: TestNode = .{ .rc = 1 };
    // prev == 3 -> new count 2 (>0): a possible root. Enqueue.
    pb.recordDecrementToPositive(3, @ptrCast(&a));
    // prev == 1 -> new count 0: teardown. Do NOT enqueue.
    pb.recordDecrementToPositive(1, @ptrCast(&b));
    try testing.expectEqual(@as(usize, 1), pb.len);
    try testing.expectEqual(@intFromPtr(&a), pb.items()[0]);
}

test "purple buffer drains into the engine and detects the cycle" {
    // Model the ARC release path: a<->b cycle, then `a` is released once
    // (prev rc 2 -> 1, still positive) so it lands in the purple buffer.
    // Draining the buffer through the engine (looking each root's descriptor
    // up — here supplied directly) detects the 2-node cycle.
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &a;

    var pb: PurpleBuffer = .{};
    // Simulate: some owner dropped its ref to `a`, leaving a.rc positive
    // (the remaining ref is b's cycle edge). prev == 2 here is the
    // pre-decrement count; we leave a.rc at its post-decrement value 1.
    pb.recordDecrementToPositive(2, @ptrCast(&a));
    try testing.expectEqual(@as(usize, 1), pb.len);

    // Build candidates from the purple roots. (The runtime joins each root
    // with its alloc-time descriptor; the test supplies the descriptor.)
    var engine = Engine.init(testing.allocator);
    defer engine.deinit();
    var candidates: [PurpleBuffer.CAPACITY]Candidate = undefined;
    var n: usize = 0;
    for (pb.items()) |root| {
        // a root pointer -> its TestNode descriptor
        candidates[n] = testCandidate(@ptrFromInt(root));
        n += 1;
    }
    const garbage = try engine.detect(candidates[0..n]);
    // The cycle is found even though only `a` was a purple root — the mark
    // walk discovers `b` through `a`'s edge.
    try testing.expectEqual(@as(usize, 2), garbage.len);
}

test "render: end-to-end — detect a cycle then render its participants" {
    // Build a 2-node cycle, run the engine, then assemble a RenderView from
    // the white set + per-node info and render it. Proves the engine result
    // feeds the renderer (the runtime does exactly this, plus symbolization).
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &a;
    // Attribute the two nodes with borrowed type labels.
    const name_a = "Parent";
    const name_b = "Child";

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    var cand_a = testCandidate(&a);
    cand_a.type_name_ptr = name_a.ptr;
    cand_a.type_name_len = name_a.len;
    var cand_b = testCandidate(&b);
    cand_b.type_name_ptr = name_b.ptr;
    cand_b.type_name_len = name_b.len;

    const candidates = [_]Candidate{ cand_a, cand_b };
    const garbage = try engine.detect(&candidates);
    try testing.expectEqual(@as(usize, 2), garbage.len);

    // Assemble the render view from the engine output.
    var render_members: [8]RenderMember = undefined;
    var total: usize = 0;
    for (garbage, 0..) |ptr, i| {
        const info = engine.nodeInfo(@ptrFromInt(ptr)).?;
        render_members[i] = .{ .type_name = info.typeName(), .size = info.size };
        total += info.size;
    }
    const view: RenderView = .{ .members = render_members[0..garbage.len], .total_bytes = total };

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderReport(&w, view, .text, false);
    const out = w.buffered();

    // Both type names appear in the retain path + detail; total bytes is sum.
    try testing.expect(std.mem.indexOf(u8, out, "Parent") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Child") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 objects (") != null);
    try testing.expect(std.mem.indexOf(u8, out, "retain path:") != null);
}

/// The exact pass/fail decision a Zest `assert_no_cycles { <block> }` makes on
/// the detector's result: a positive detected-object count is a reference
/// cycle (FAIL); zero is clean (PASS). Mirrors
/// `Zest.Assertion.would_report_cycle?/1` (lib/zest/assertion.zap) so the
/// runtime engine's white-set size and the assertion's verdict are pinned
/// together in one host test, closing the loop the Phase-5 caveat leaves open
/// (a real cycle is not constructible from a `.zap` source yet, so the
/// detect→FAIL link cannot be exercised from Zap — it is exercised HERE).
fn zestWouldReportCycle(detected_object_count: usize) bool {
    return detected_object_count > 0;
}

test "assert_no_cycles detect-and-fail: a detected cycle drives the assertion to FAIL" {
    // Build the 2-node mutual cycle the runtime registry would hold after a
    // block constructed a reference loop, run the detector exactly as
    // `scanLiveCyclesAndReport` does, and confirm the resulting white-set size
    // makes the `assert_no_cycles` decision FAIL.
    var a: TestNode = .{ .rc = 1 };
    var b: TestNode = .{ .rc = 1 };
    a.edges[0] = &b;
    b.edges[0] = &a;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&a), testCandidate(&b) };
    const garbage = try engine.detect(&candidates);

    // The detector found cyclic garbage ...
    try testing.expectEqual(@as(usize, 2), garbage.len);
    // ... so `assert_no_cycles` must FAIL (the inverse of a clean block).
    try testing.expect(zestWouldReportCycle(garbage.len));
}

test "assert_no_cycles detect-and-fail: an acyclic externally-owned graph PASSES" {
    // A two-node acyclic chain held by an external owner (rc reflects the
    // outside reference): the detector finds NO cycle, so `assert_no_cycles`
    // PASSES — the clean-block branch, verified against the same engine.
    var owner_held: TestNode = .{ .rc = 2 }; // one external ref + one internal
    var tail: TestNode = .{ .rc = 1 };
    owner_held.edges[0] = &tail;

    var engine = Engine.init(testing.allocator);
    defer engine.deinit();

    const candidates = [_]Candidate{ testCandidate(&owner_held), testCandidate(&tail) };
    const garbage = try engine.detect(&candidates);

    try testing.expectEqual(@as(usize, 0), garbage.len);
    try testing.expect(!zestWouldReportCycle(garbage.len));
}
