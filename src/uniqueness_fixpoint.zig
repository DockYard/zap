const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const uniqueness_signature = @import("uniqueness_signature.zig");

const ParamSig = uniqueness_signature.ParamSig;
const UniquenessClass = uniqueness_signature.UniquenessClass;
const FunctionSig = uniqueness_signature.FunctionSig;
const ProgramSignatures = uniqueness_signature.ProgramSignatures;

// ============================================================
// SCC fixpoint over the call graph for Phase 1.2 of the escape-
// analysis plan (research2 §1.2).
//
// Pipeline placement:
//
//     ... → arc_liveness                       (last-use side table)
//          → uniqueness_fixpoint.computeSignatures     (THIS PASS — computes
//                                              `ProgramSignatures` from
//                                              every monomorphized
//                                              function body, iterated
//                                              over Tarjan SCCs)
//             → arc_param_convention           (consults signatures in
//                                              the borrowed-source veto)
//                → arc_ownership pipeline      (uniqueness rewrite + verifier)
//
// Algorithm overview (research2 §1.2):
//
//   1. Build the call graph (direct edges only — call_named,
//      call_direct, try_call_named, tail_call). Calls through
//      closures, dispatch witnesses, or unanalysable builtins are
//      *flow-out* edges that contribute conservatively to the
//      caller's signature (their target is `top`).
//   2. Compute SCCs via Tarjan. O(V+E).
//   3. Initialize every parameter slot to `unobserved`.
//   4. Iterate SCCs in reverse-topological order. Within each SCC,
//      worklist iteration to least fixpoint:
//        - Pop a function F from the worklist.
//        - Walk F's body intraprocedurally; for each parameter of F,
//          record observed flows and join into `Sig(F, i)`.
//        - If `Sig(F, i)` changed, enqueue every other function in
//          the same SCC plus every direct caller of F whose own
//          signature might depend on F's result classification.
//   5. Stop when the worklist is empty.
//
// Termination
// -----------
//
// The lattice height is 4 (`unobserved` → {CU, PU, AL} → top).
// Joins are monotone — they never move signatures down. The total
// number of upgrades across the program is bounded by
// (functions × max_params × 4), so the fixpoint terminates in
// O(N) iterations, where N is the parameter-slot count.
//
// Soundness
// ---------
//
// Conservative defaults at every analysis frontier:
//   - Unanalysable callees (builtins, closures, dynamic dispatch)
//     contribute `top` to any parameter that flows into them.
//   - Recursive call sites within the same SCC are treated
//     symbolically — when `Sig(callee, slot)` is still `unobserved`,
//     we join `unobserved` (which is the identity), letting the
//     analysis converge as the SCC is iterated.
//   - The verifier in `arc_verifier.zig::runUniquenessCheck` re-validates every
//     emission of `*_owned_unchecked` against the post-fixpoint
//     signatures. A buggy classification produces compilation
//     failure, never miscompilation.
//
// ============================================================

/// Compute uniqueness signatures for every function in `program`.
///
/// Returns a `ProgramSignatures` whose lifetime is owned by the
/// caller — `deinit` releases the per-function slices.
///
/// `arc_ownership_data` is consulted only to identify owned-mutating
/// builtins (via `arc_liveness.ownedMutatingBuiltinSlot`). It is
/// optional in tests; without it, builtin call sites are treated
/// conservatively as `top`.
pub fn computeSignatures(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
) !ProgramSignatures {
    return computeSignaturesWithOwnership(allocator, program, null);
}

/// Phase 2.2 — variant that accepts an optional per-function
/// `ArcOwnership` table. When provided, the walker consults
/// `last_use_map`/`isLastUseAt` to recognise `copy_value` at last-use
/// as a uniqueness-preserving alias rather than an aliasing escape.
/// Without ownership data the walker conservatively classifies every
/// `copy_value` as AL (the legacy behaviour).
///
/// The ownership table is the result of `arc_liveness.runProgramArcOwnership`
/// against the same `program`. Tests can pass `null` to opt out.
pub fn computeSignaturesWithOwnership(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    ownerships: ?*const arc_liveness.ProgramArcOwnership,
) !ProgramSignatures {
    var signatures = ProgramSignatures.init(allocator);
    errdefer signatures.deinit(allocator);

    // Step 1: build name→id lookup (reused across all phases that
    // need to resolve call_named / try_call_named / tail_call).
    var name_to_id: std.StringHashMapUnmanaged(ir.FunctionId) = .empty;
    defer name_to_id.deinit(allocator);
    for (program.functions) |func| {
        try name_to_id.put(allocator, func.name, func.id);
        if (func.local_name.len != 0) {
            const gop = try name_to_id.getOrPut(allocator, func.local_name);
            if (!gop.found_existing) gop.value_ptr.* = func.id;
        }
    }

    // Step 2: pre-allocate per-function FunctionSig slices in the
    // signatures arena. Initially every slot is `unobserved`. The
    // intraprocedural walks below will mutate these slices in place.
    const arena_alloc = signatures.arena.allocator();
    for (program.functions) |func| {
        var sig: FunctionSig = .{ .params = &.{}, .return_components = &.{} };
        if (func.param_conventions.len > 0) {
            const slots = try arena_alloc.alloc(ParamSig, func.param_conventions.len);
            for (slots) |*s| s.* = ParamSig.initial();
            sig.params = slots;
        }
        // Return components: for now we always allocate at least one slot
        // (single-result return). Phase 2 will widen this for tuple/struct
        // returns; the structure is here so callers can already query
        // `return_components[0]`.
        const return_components = try arena_alloc.alloc(?u8, 1);
        return_components[0] = null;
        sig.return_components = return_components;
        try signatures.by_function.put(allocator, func.id, sig);
    }

    // Step 3: build the direct-call graph (caller → callees).
    var call_graph = try buildCallGraph(allocator, program, &name_to_id);
    defer call_graph.deinit(allocator);

    // Step 4: Tarjan SCC over the call graph. Returns SCCs in
    // reverse-topological order (leaves first), which is the order
    // we iterate the fixpoint.
    var sccs = try computeSccs(allocator, program, &call_graph);
    defer sccs.deinit(allocator);

    // Step 5: SCC-by-SCC fixpoint. Inside each SCC we worklist until
    // local convergence; across SCCs we go strictly forward (leaves
    // before their callers), so a single pass per SCC suffices to
    // make all of its callees' signatures stable.
    for (sccs.components.items) |scc| {
        try iterateScc(allocator, program, &name_to_id, &call_graph, scc, &signatures, ownerships);
    }

    // Defensive cleanup: any slot that remained `unobserved` after
    // the fixpoint had no flows in the body — promote it to `top`
    // so callers don't accidentally treat ⊥ as "proven CU/PU."
    var iter = signatures.by_function.iterator();
    while (iter.next()) |entry| {
        for (entry.value_ptr.params) |*slot| {
            if (slot.class == .unobserved) {
                slot.* = ParamSig.unknown();
            }
        }
    }

    return signatures;
}

// ============================================================
// Direct-call graph construction
// ============================================================

const CallGraph = struct {
    /// Caller → list of (callee, instruction-id, args) edges. The
    /// instruction id is depth-first, mirroring `arc_liveness`'s
    /// numbering so we can correlate with last-use queries.
    edges_by_caller: std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(CallEdge)) = .empty,
    /// Reverse map: callee → list of caller ids. Used to enqueue
    /// callers when a callee's signature changes.
    callers_by_callee: std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)) = .empty,

    fn deinit(self: *CallGraph, allocator: std.mem.Allocator) void {
        var iter = self.edges_by_caller.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.edges_by_caller.deinit(allocator);
        var rev_iter = self.callers_by_callee.iterator();
        while (rev_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.callers_by_callee.deinit(allocator);
    }

    fn directCallees(self: *const CallGraph, caller: ir.FunctionId) []const CallEdge {
        if (self.edges_by_caller.getPtr(caller)) |list| return list.items;
        return &.{};
    }

    fn callersOf(self: *const CallGraph, callee: ir.FunctionId) []const ir.FunctionId {
        if (self.callers_by_callee.getPtr(callee)) |list| return list.items;
        return &.{};
    }
};

const CallEdge = struct {
    callee: ir.FunctionId,
    /// Args passed by the caller, in source order. Cross-references
    /// the function's parameter slots one-for-one (slot i := args[i]).
    args: []const ir.LocalId,
    /// True for self-recursive tail calls. The fixpoint uses this to
    /// classify the call as a uniqueness-preserving recurrence, the
    /// most common shape in accumulator recursion.
    is_tail_call: bool,
};

fn buildCallGraph(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
) !CallGraph {
    var graph: CallGraph = .{};
    errdefer graph.deinit(allocator);

    for (program.functions) |*caller| {
        var edges: std.ArrayListUnmanaged(CallEdge) = .empty;
        try collectCalleesIntoStream(
            allocator,
            caller.body,
            name_to_id,
            &edges,
        );
        if (edges.items.len > 0) {
            try graph.edges_by_caller.put(allocator, caller.id, edges);
            for (edges.items) |edge| {
                const gop = try graph.callers_by_callee.getOrPut(allocator, edge.callee);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                // De-duplicate: a single caller may invoke the same
                // callee from many call sites; the SCC iteration only
                // needs to enqueue the caller once per cascade event.
                var already_recorded = false;
                for (gop.value_ptr.items) |existing| {
                    if (existing == caller.id) {
                        already_recorded = true;
                        break;
                    }
                }
                if (!already_recorded) {
                    try gop.value_ptr.append(allocator, caller.id);
                }
            }
        } else {
            edges.deinit(allocator);
        }
    }

    return graph;
}

fn collectCalleesIntoStream(
    allocator: std.mem.Allocator,
    blocks: []const ir.Block,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    edges: *std.ArrayListUnmanaged(CallEdge),
) !void {
    for (blocks) |block| {
        try walkStreamForCallees(allocator, block.instructions, name_to_id, edges);
    }
}

fn walkStreamForCallees(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    edges: *std.ArrayListUnmanaged(CallEdge),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_named => |cn| {
                if (name_to_id.get(cn.name)) |target| {
                    try edges.append(allocator, .{
                        .callee = target,
                        .args = cn.args,
                        .is_tail_call = false,
                    });
                }
            },
            .call_direct => |cd| {
                try edges.append(allocator, .{
                    .callee = cd.function,
                    .args = cd.args,
                    .is_tail_call = false,
                });
            },
            .try_call_named => |tcn| {
                if (name_to_id.get(tcn.name)) |target| {
                    try edges.append(allocator, .{
                        .callee = target,
                        .args = tcn.args,
                        .is_tail_call = false,
                    });
                }
            },
            .tail_call => |tc| {
                if (name_to_id.get(tc.name)) |target| {
                    try edges.append(allocator, .{
                        .callee = target,
                        .args = tc.args,
                        .is_tail_call = true,
                    });
                }
            },
            .if_expr => |ie| {
                try walkStreamForCallees(allocator, ie.then_instrs, name_to_id, edges);
                try walkStreamForCallees(allocator, ie.else_instrs, name_to_id, edges);
            },
            .case_block => |cb| {
                try walkStreamForCallees(allocator, cb.pre_instrs, name_to_id, edges);
                for (cb.arms) |arm| {
                    try walkStreamForCallees(allocator, arm.cond_instrs, name_to_id, edges);
                    try walkStreamForCallees(allocator, arm.body_instrs, name_to_id, edges);
                }
                try walkStreamForCallees(allocator, cb.default_instrs, name_to_id, edges);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try walkStreamForCallees(allocator, c.body_instrs, name_to_id, edges);
                try walkStreamForCallees(allocator, sl.default_instrs, name_to_id, edges);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try walkStreamForCallees(allocator, c.body_instrs, name_to_id, edges);
                try walkStreamForCallees(allocator, sr.default_instrs, name_to_id, edges);
            },
            .union_switch => |us| {
                for (us.cases) |c| try walkStreamForCallees(allocator, c.body_instrs, name_to_id, edges);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try walkStreamForCallees(allocator, c.body_instrs, name_to_id, edges);
            },
            .guard_block => |gb| {
                try walkStreamForCallees(allocator, gb.body, name_to_id, edges);
            },
            .optional_dispatch => |od| {
                try walkStreamForCallees(allocator, od.nil_instrs, name_to_id, edges);
                try walkStreamForCallees(allocator, od.struct_instrs, name_to_id, edges);
            },
            else => {},
        }
    }
}

// ============================================================
// Tarjan SCC computation
// ============================================================

const SccList = struct {
    /// Each component is a slice of FunctionIds belonging to the SCC.
    /// Components are returned in **reverse-topological** order: the
    /// callee leaves come first, callers later. Allocator ownership:
    /// each `component` slice is owned by `allocator`.
    components: std.ArrayListUnmanaged([]const ir.FunctionId) = .empty,

    fn deinit(self: *SccList, allocator: std.mem.Allocator) void {
        for (self.components.items) |comp| allocator.free(comp);
        self.components.deinit(allocator);
    }
};

fn computeSccs(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    graph: *const CallGraph,
) !SccList {
    var result: SccList = .{};
    errdefer result.deinit(allocator);

    var solver = TarjanSolver{
        .allocator = allocator,
        .graph = graph,
        .program = program,
        .index = 0,
        .indices = .empty,
        .lowlinks = .empty,
        .on_stack = .empty,
        .stack = .empty,
        .result = &result,
    };
    defer solver.deinit();

    for (program.functions) |func| {
        if (!solver.indices.contains(func.id)) {
            try solver.strongConnect(func.id);
        }
    }

    return result;
}

const TarjanSolver = struct {
    allocator: std.mem.Allocator,
    graph: *const CallGraph,
    program: *const ir.Program,
    index: u32,
    indices: std.AutoHashMapUnmanaged(ir.FunctionId, u32),
    lowlinks: std.AutoHashMapUnmanaged(ir.FunctionId, u32),
    on_stack: std.AutoHashMapUnmanaged(ir.FunctionId, void),
    stack: std.ArrayListUnmanaged(ir.FunctionId),
    result: *SccList,

    fn deinit(self: *TarjanSolver) void {
        self.indices.deinit(self.allocator);
        self.lowlinks.deinit(self.allocator);
        self.on_stack.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    fn strongConnect(self: *TarjanSolver, v: ir.FunctionId) !void {
        // Iterative Tarjan to avoid stack overflow on long call chains.
        // The standard recursive form is described in research2 §1.2;
        // we mirror its semantics with an explicit work stack.
        const Frame = struct {
            v: ir.FunctionId,
            edge_index: usize,
        };
        var work: std.ArrayListUnmanaged(Frame) = .empty;
        defer work.deinit(self.allocator);

        try self.indices.put(self.allocator, v, self.index);
        try self.lowlinks.put(self.allocator, v, self.index);
        self.index += 1;
        try self.stack.append(self.allocator, v);
        try self.on_stack.put(self.allocator, v, {});
        try work.append(self.allocator, .{ .v = v, .edge_index = 0 });

        while (work.items.len > 0) {
            const top = &work.items[work.items.len - 1];
            const edges = self.graph.directCallees(top.v);
            if (top.edge_index >= edges.len) {
                // Finalise: if v is a root, pop the SCC.
                const v_low = self.lowlinks.get(top.v).?;
                const v_idx = self.indices.get(top.v).?;
                if (v_low == v_idx) {
                    var component: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
                    errdefer component.deinit(self.allocator);
                    while (true) {
                        const popped = self.stack.pop().?;
                        _ = self.on_stack.remove(popped);
                        try component.append(self.allocator, popped);
                        if (popped == top.v) break;
                    }
                    const slice = try component.toOwnedSlice(self.allocator);
                    try self.result.components.append(self.allocator, slice);
                }
                _ = work.pop();
                if (work.items.len > 0) {
                    const parent = &work.items[work.items.len - 1];
                    const parent_edges = self.graph.directCallees(parent.v);
                    const just_finished = parent_edges[parent.edge_index - 1].callee;
                    const child_low = self.lowlinks.get(just_finished).?;
                    const parent_low = self.lowlinks.get(parent.v).?;
                    if (child_low < parent_low) {
                        try self.lowlinks.put(self.allocator, parent.v, child_low);
                    }
                }
                continue;
            }
            const w = edges[top.edge_index].callee;
            top.edge_index += 1;
            if (!self.indices.contains(w)) {
                try self.indices.put(self.allocator, w, self.index);
                try self.lowlinks.put(self.allocator, w, self.index);
                self.index += 1;
                try self.stack.append(self.allocator, w);
                try self.on_stack.put(self.allocator, w, {});
                try work.append(self.allocator, .{ .v = w, .edge_index = 0 });
            } else if (self.on_stack.contains(w)) {
                const w_idx = self.indices.get(w).?;
                const v_low = self.lowlinks.get(top.v).?;
                if (w_idx < v_low) {
                    try self.lowlinks.put(self.allocator, top.v, w_idx);
                }
            }
        }
    }
};

// ============================================================
// SCC-local worklist iteration
// ============================================================

fn iterateScc(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    graph: *const CallGraph,
    scc: []const ir.FunctionId,
    signatures: *ProgramSignatures,
    ownerships: ?*const arc_liveness.ProgramArcOwnership,
) !void {
    // Within a single SCC, every function's signature can depend on
    // any other's. We worklist until stability.
    var worklist: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
    defer worklist.deinit(allocator);
    var in_worklist: std.AutoHashMapUnmanaged(ir.FunctionId, void) = .empty;
    defer in_worklist.deinit(allocator);

    var scc_set: std.AutoHashMapUnmanaged(ir.FunctionId, void) = .empty;
    defer scc_set.deinit(allocator);
    for (scc) |fid| {
        try scc_set.put(allocator, fid, {});
        try worklist.append(allocator, fid);
        try in_worklist.put(allocator, fid, {});
    }

    // Phase 2.6.1 — bound the SCC fixpoint iteration count. The
    // monotone lattice (params: 4 levels each; return_components:
    // per-component witness lattice with bounded oscillation under
    // correct merge semantics) guarantees convergence; this cap is
    // a defensive safety net against future changes that might
    // accidentally introduce non-monotone observations. Sized at
    // 32× SCC size + 64 to comfortably absorb any in-SCC cascade.
    var iter_count: u32 = 0;
    const max_scc_iter: u32 = @intCast(scc.len * 32 + 64);
    while (worklist.pop()) |fid| {
        iter_count += 1;
        if (iter_count > max_scc_iter) break;
        _ = in_worklist.remove(fid);
        const func = lookupFunction(program, fid) orelse continue;

        var changed = false;
        try analyzeFunctionBody(
            allocator,
            program,
            name_to_id,
            func,
            signatures,
            ownerships,
            &changed,
        );

        if (changed) {
            // Re-enqueue every function in this SCC (its signature may
            // depend on the just-updated one) AND every direct caller
            // of this function (likely outside the SCC, but we still
            // run them again to refine their per-call-site analysis).
            for (scc) |peer| {
                if (peer == fid) continue;
                if (!in_worklist.contains(peer)) {
                    try worklist.append(allocator, peer);
                    try in_worklist.put(allocator, peer, {});
                }
            }
            for (graph.callersOf(fid)) |caller_id| {
                // Across-SCC callers: enqueue them too, but only if
                // they're already in this SCC (cross-SCC propagation
                // is handled by the outer SCC iteration order).
                if (scc_set.contains(caller_id) and !in_worklist.contains(caller_id)) {
                    try worklist.append(allocator, caller_id);
                    try in_worklist.put(allocator, caller_id, {});
                }
            }
        }
    }
}

fn lookupFunction(program: *const ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*func| {
        if (func.id == function_id) return func;
    }
    return null;
}

// ============================================================
// Intraprocedural classification
// ============================================================

/// Per-parameter accumulator while walking a function body.
const ParamAccumulator = struct {
    /// Accumulated signature for this parameter so far. Joins
    /// monotonically as we encounter more flows.
    sig: ParamSig = ParamSig.initial(),
};

/// Walk `function`'s body once, classify every flow of every
/// parameter, and join into the existing signature. Sets
/// `changed_out` to `true` when any signature element strictly
/// upgrades (e.g. unobserved → CU, PU → top).
///
/// The classification produces, for each `local_id`, a *carrier*:
/// either "tracks parameter `slot`" or "fresh value" or "from
/// non-tracked source." A flow is then classified as CU/PU/AL
/// based on what the carrier hits.
fn analyzeFunctionBody(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    function: *const ir.Function,
    signatures: *ProgramSignatures,
    ownerships: ?*const arc_liveness.ProgramArcOwnership,
    changed_out: *bool,
) !void {
    const arena_alloc = signatures.arena.allocator();
    _ = arena_alloc;

    if (function.param_conventions.len == 0) return;

    // Scratch: per-parameter accumulator for THIS pass over the body.
    var accumulators: std.ArrayListUnmanaged(ParamAccumulator) = .empty;
    defer accumulators.deinit(allocator);
    try accumulators.resize(allocator, function.param_conventions.len);
    for (accumulators.items) |*acc| acc.* = .{};

    // Map LocalId → "carries parameter slot" (or null for non-tracked).
    // Conservatively, we propagate carrier through alias-form
    // instructions (local_get/set, move_value, share_value, copy_value,
    // borrow_value, param_get) AND through owned-mutating call results
    // (those return a fresh-rc=1 cell that originated from the
    // receiver, so the carrier carries through).
    var carrier_of: std.AutoHashMapUnmanaged(ir.LocalId, u32) = .empty;
    defer carrier_of.deinit(allocator);

    // Phase 2.1 — tuple_pending tracking. A `tuple_init` whose elements
    // include carriers is *deferred*: instead of unconditionally
    // upgrading every carrier to `aliases`, we store a per-component
    // record in `tuple_pending`. The deferred entry resolves later:
    //
    //   * `ret` / `cond_return` of the tuple_pending dest → each
    //     component-carrier classifies as PU, with the component index
    //     stored as the witness. This is the canonical
    //     "fn f(p) -> {p, q}" idiom that fannkuch's `count_flips`,
    //     `advance_perm`, and `rotate_loop` exhibit.
    //
    //   * Storage into another aggregate (list_init, list_cons, map_init,
    //     struct_init, union_init, make_closure, nested tuple) where the
    //     containing aggregate is NOT itself a returned tuple → resolve
    //     deferred carriers as AL.
    //
    //   * Use as a call argument (the called function may escape it) →
    //     resolve as AL. The tuple itself is the argument; its
    //     components are not the call's first-class arg slots.
    //
    //   * Use that survives until end-of-body without resolution → leave
    //     unresolved. The component carriers have not been observed at
    //     a sink, which is the same "unobserved" outcome as if the
    //     tuple_init never existed.
    //
    // Multiple tuple_pending entries for chained tuples are supported:
    // when a tuple_init's element is itself a tuple_pending dest, the
    // outer tuple becomes a new tuple_pending whose carriers are
    // *flattened* (the inner tuple's carriers contribute their own
    // component-mapped slots). Chained returns then resolve correctly
    // via the same return-component witness path.
    var tuple_pending: std.AutoHashMapUnmanaged(ir.LocalId, []TupleComponent) = .empty;
    defer {
        var it = tuple_pending.valueIterator();
        while (it.next()) |comps| allocator.free(comps.*);
        tuple_pending.deinit(allocator);
    }

    // First pass: seed every `param_get` instruction so its dest
    // carries the corresponding parameter slot. Subsequent flow steps
    // propagate via alias forms.
    var visitor = ParamGetSeeder{ .carrier_of = &carrier_of, .allocator = allocator };
    try seedParamGets(function, &visitor);

    // Second pass: walk every instruction in source order. At each
    // instruction we may:
    //   1. Propagate carrier through alias forms (local_get, etc.).
    //   2. Observe a flow into a sink (consume site, escape site,
    //      return site, etc.) and join the corresponding parameter's
    //      accumulator.
    const function_ownership: ?*const arc_liveness.ArcOwnership = blk: {
        if (ownerships) |program_ownership| {
            break :blk program_ownership.get(function.id);
        }
        break :blk null;
    };

    var walker = FlowWalker{
        .allocator = allocator,
        .program = program,
        .name_to_id = name_to_id,
        .function = function,
        .signatures = signatures,
        .accumulators = &accumulators,
        .carrier_of = &carrier_of,
        .tuple_pending = &tuple_pending,
        .function_ownership = function_ownership,
    };
    defer walker.deinit();
    for (function.body) |block| {
        try walker.walkStream(block.instructions);
    }

    // Merge accumulators into the program signature. A signature
    // upgrades (changed_out=true) when its class moved monotonically
    // from a lower lattice element to a strictly higher one.
    const sig_entry = signatures.by_function.getPtr(function.id) orelse return;
    for (sig_entry.params, accumulators.items) |*existing, observed| {
        const new_value = uniqueness_signature.join(existing.*, observed.sig);
        if (new_value.class != existing.class or
            new_value.preserves_to_return_component != existing.preserves_to_return_component)
        {
            existing.* = new_value;
            changed_out.* = true;
        }
    }

    // Phase 2.1 — observed return components. The walker accumulates
    // per-tuple-component witnesses across every `ret`/`cond_return`
    // observation: if EVERY return that returns a tuple_pending value
    // associates the same parameter slot with component i, then
    // `return_components[i]` records that slot. Returns whose value is
    // not a tuple_pending dest (e.g. a non-tuple early exit, or a
    // tuple_pending with conflicting carriers) drop the witness for
    // the associated component to `null`.
    if (sig_entry.return_components.len < walker.observed_return_components.items.len) {
        // The arena slice is sized at allocation time; if the body
        // observes a wider tuple than we pre-allocated, fall back to
        // a fresh allocation in the signatures arena.
        const arena_alloc_local = signatures.arena.allocator();
        const new_components = arena_alloc_local.alloc(?u8, walker.observed_return_components.items.len) catch return;
        for (new_components, 0..) |*slot, i| slot.* = if (i < sig_entry.return_components.len) sig_entry.return_components[i] else null;
        sig_entry.return_components = new_components;
    }
    if (sig_entry.return_components.len > 0) {
        // SAFETY: the slice was allocated by the same signatures arena.
        // We mutate the per-component witness in place; the slice's
        // backing memory is owned by the signatures arena and freed
        // wholesale at `signatures.deinit`.
        //
        // Phase 2.6.1 fixpoint termination: the merge is monotone-down
        // ONCE a witness has been recorded. Specifically:
        //   * old=null, observed=Some(slot) -> upgrade to Some(slot).
        //     This is the FIRST observation of this component.
        //   * old=Some(x), observed=Some(x) -> no change (consistent).
        //   * old=Some(x), observed=Some(y!=x) -> downgrade to null
        //     (disagreement across observations).
        //   * old=Some(x), observed=null -> KEEP old. The absence of
        //     an observation in THIS body walk does NOT downgrade a
        //     witness recorded in a PREVIOUS iteration. The prior
        //     walk may have observed witnesses through callee
        //     signatures that have since stabilised; re-walking
        //     under those same signatures should not strictly
        //     reduce the observation set unless the per-arm shape
        //     changed (which can't happen — the IR is fixed).
        //     Treating absent-observation as a downgrade caused
        //     infinite SCC oscillation when callee synthesis
        //     toggled on/off across SCC iterations.
        //   * old=null, observed=null -> no change.
        const components_mut: []?u8 = @constCast(sig_entry.return_components);
        for (walker.observed_return_components.items, 0..) |observed, i| {
            if (i >= components_mut.len) break;
            const old = components_mut[i];
            const observed_slot = observed orelse continue;
            const merged: ?u8 = if (old == null)
                @as(?u8, observed_slot)
            else if (old.? == observed_slot)
                old
            else
                null;
            if (merged != old) {
                components_mut[i] = merged;
                changed_out.* = true;
            }
        }
    }
}

const ParamGetSeeder = struct {
    carrier_of: *std.AutoHashMapUnmanaged(ir.LocalId, u32),
    allocator: std.mem.Allocator,

    fn visit(self: *ParamGetSeeder, instr: *const ir.Instruction) void {
        switch (instr.*) {
            .param_get => |pg| {
                self.carrier_of.put(self.allocator, pg.dest, pg.index) catch {};
            },
            else => {},
        }
    }
};

fn seedParamGets(
    function: *const ir.Function,
    visitor: *ParamGetSeeder,
) !void {
    ir.forEachInstruction(function, visitor, ParamGetSeeder.visit);
}

/// A `tuple_init` deferred record. One entry per component of a
/// constructed tuple whose dest is on the `tuple_pending` map. Each
/// entry records (a) the source parameter slot the component carries
/// (when known) and (b) whether the component itself is the dest of a
/// nested tuple_pending (so chained tuples can flatten on resolve).
///
/// `slot == null && nested == null` means "non-carrier component"
/// (e.g. an `i64` literal). The presence of any non-carrier component
/// does NOT block PU classification of the carrier components — each
/// component's witness is independent.
pub const TupleComponent = struct {
    slot: ?u32 = null,
};

const FlowWalker = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    function: *const ir.Function,
    signatures: *ProgramSignatures,
    accumulators: *std.ArrayListUnmanaged(ParamAccumulator),
    carrier_of: *std.AutoHashMapUnmanaged(ir.LocalId, u32),
    /// Phase 2.1 — deferred tuple-construction records. See the
    /// commentary in `analyzeFunctionBody` for the resolution rules.
    /// The slice associated with each pending entry is owned by
    /// `allocator` and must be freed when the entry is removed (via
    /// resolve-as-AL or resolve-as-PU at a return).
    tuple_pending: *std.AutoHashMapUnmanaged(ir.LocalId, []TupleComponent),
    /// Phase 2.1 — per-tuple-return-component observed parameter
    /// witnesses. Grown lazily as the walker observes returns. After
    /// the body is walked, the merge phase combines these with the
    /// signature's `return_components` slice (taking the meet — when
    /// two observed returns disagree on a component, the witness drops
    /// to `null` for that component).
    observed_return_components: std.ArrayListUnmanaged(?u8) = .empty,
    /// Phase 2.2 — per-function ARC ownership info, when available.
    /// Used by `copy_value` classification to recognise last-use
    /// `copy_value` as a uniqueness-preserving alias rather than an
    /// aliasing escape. Without ownership info the walker
    /// conservatively classifies every `copy_value` as AL.
    function_ownership: ?*const arc_liveness.ArcOwnership = null,
    /// Phase 2.2 — running InstructionId mirrored from `arc_liveness`'s
    /// depth-first traversal. Each top-level instruction increments
    /// this counter before being classified, so per-instruction
    /// queries (e.g. `isLastUseAt`) match the analyzer's id space.
    next_instr_id: arc_liveness.InstructionId = 0,

    fn deinit(self: *FlowWalker) void {
        self.observed_return_components.deinit(self.allocator);
    }

    fn walkStream(
        self: *FlowWalker,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const id = self.next_instr_id;
            self.next_instr_id += 1;
            try self.classifyAndPropagate(instr, id);
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(
        self: *FlowWalker,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            // -----------------------------------------------------
            // Phase 2.6.1 — `if_expr` / `case_block` /
            // `switch_literal` / `try_call_named` aggregate their arm
            // results via a parent `dest` LocalId. After each arm
            // body finishes, merge the arm's per-arm result-local's
            // `tuple_pending` and `carrier_of` records into the
            // parent's `dest`. A downstream `ret(parent.dest)` then
            // resolves the merged pending and emits a
            // (possibly demoted) per-component witness.
            // -----------------------------------------------------
            .if_expr => |ie| {
                try self.walkStream(ie.then_instrs);
                if (ie.then_result) |tr| try self.mergeArmResultIntoDest(ie.dest, tr);
                try self.walkStream(ie.else_instrs);
                if (ie.else_result) |er| try self.mergeArmResultIntoDest(ie.dest, er);
            },
            .case_block => |cb| {
                try self.walkStream(cb.pre_instrs);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                    if (arm.result) |ar| try self.mergeArmResultIntoDest(cb.dest, ar);
                }
                try self.walkStream(cb.default_instrs);
                if (cb.default_result) |dr| try self.mergeArmResultIntoDest(cb.dest, dr);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    if (c.result) |r| try self.mergeArmResultIntoDest(sl.dest, r);
                }
                try self.walkStream(sl.default_instrs);
                if (sl.default_result) |dr| try self.mergeArmResultIntoDest(sl.dest, dr);
            },
            // -----------------------------------------------------
            // Phase 2.6.1 — `switch_return` / `union_switch_return` /
            // `optional_dispatch` are return-equivalent: every arm's
            // `return_value` (or `default_result` / arm-result) lowers
            // to an implicit `ret` at codegen. Trigger the existing
            // `classifyReturnValue` on each so the per-arm tuple_init
            // contributions roll up into the function's
            // `return_components` table. Without this hop, multi-clause
            // tuple-returning functions (fannkuch's `advance_perm`
            // dispatched via int-literal first param) lose their per-
            // component PU witness — the caller's destructure-then-uniqueness
            // chain never sees the witness propagate through the
            // tuple to the uniqueness site.
            // -----------------------------------------------------
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    if (c.return_value) |rv| try self.classifyReturnValue(rv);
                }
                try self.walkStream(sr.default_instrs);
                if (sr.default_result) |dr| try self.classifyReturnValue(dr);
            },
            .union_switch => |us| {
                for (us.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    if (c.return_value) |rv| try self.mergeArmResultIntoDest(us.dest, rv);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    if (c.return_value) |rv| try self.classifyReturnValue(rv);
                }
            },
            .try_call_named => |tcn| {
                try self.walkStream(tcn.handler_instrs);
                if (tcn.handler_result) |hr| try self.mergeArmResultIntoDest(tcn.dest, hr);
                try self.walkStream(tcn.success_instrs);
                if (tcn.success_result) |sr_local| try self.mergeArmResultIntoDest(tcn.dest, sr_local);
            },
            .guard_block => |gb| {
                try self.walkStream(gb.body);
            },
            .optional_dispatch => |od| {
                try self.walkStream(od.nil_instrs);
                if (od.nil_result) |nr| try self.classifyReturnValue(nr);
                try self.walkStream(od.struct_instrs);
                if (od.struct_result) |sr_local| try self.classifyReturnValue(sr_local);
            },
            else => {},
        }
    }

    /// Phase 2.6.1 — propagate an arm's result local into the parent
    /// aggregating instruction's `dest`. The arm result is whatever
    /// the arm "produces" (the implicit join value at the arm
    /// boundary); the parent's `dest` is where that join value lives
    /// in the post-merge stream.
    ///
    /// Two pieces of metadata flow through the join:
    ///   * `tuple_pending` membership: when the arm result is a
    ///     pending tuple, the dest inherits the pending entry. If
    ///     the dest already has an entry from a previous arm, the
    ///     new entry's per-component witnesses are MEET'd into the
    ///     existing one (matching slot keeps witness; mismatch
    ///     demotes to null). This models "every arm's contribution
    ///     must agree for the witness to survive".
    ///   * `carrier_of`: when the arm result names a parameter slot
    ///     directly (whole-return PU, not a tuple), the dest
    ///     inherits the same slot when ALL arms agree. A
    ///     disagreement removes the dest's entry.
    fn mergeArmResultIntoDest(
        self: *FlowWalker,
        dest: ir.LocalId,
        arm_result: ir.LocalId,
    ) !void {
        if (dest == arm_result) return;

        // Merge tuple_pending. The arm's pending entry transfers
        // ownership to the dest; subsequent arms merge into that
        // shared entry under the per-component meet.
        if (self.tuple_pending.fetchRemove(arm_result)) |kv| {
            const arm_components = kv.value;
            if (self.tuple_pending.getPtr(dest)) |dest_components_ptr| {
                // Existing entry from a previous arm — apply per-
                // component meet, then free the arm's slice. Per-
                // component rule:
                //   * Both arms agree on slot → keep the slot.
                //   * Disagree → demote to null.
                //   * One arm has null → demote to null (the arm
                //     without a witness contributes "no slot
                //     known" which dominates the meet).
                const dest_components = dest_components_ptr.*;
                const min_len = @min(arm_components.len, dest_components.len);
                for (dest_components[0..min_len], arm_components[0..min_len]) |*dc, ac| {
                    if (dc.slot != null and ac.slot != null) {
                        if (dc.slot.? != ac.slot.?) dc.slot = null;
                    } else {
                        dc.slot = null;
                    }
                }
                // Components beyond min_len stay as they were on
                // the dest. A future arm that exhibits a different
                // shape would conservatively resolve those as null
                // since their slots are absent in this arm.
                self.allocator.free(arm_components);
            } else {
                // First arm to contribute — install the arm's slice
                // directly under dest.
                try self.tuple_pending.put(self.allocator, dest, arm_components);
            }
        }

        // Merge carrier_of. The dest inherits the arm's slot when
        // the dest had no prior carrier (first arm to contribute)
        // or all arms agree on the same slot. Disagreement removes
        // the dest's entry so a downstream classifier sees "no
        // carrier".
        if (self.carrier_of.get(arm_result)) |arm_slot| {
            if (self.carrier_of.get(dest)) |existing_slot| {
                if (existing_slot != arm_slot) {
                    _ = self.carrier_of.remove(dest);
                }
            } else {
                try self.carrier_of.put(self.allocator, dest, arm_slot);
            }
        } else {
            // Arm has no carrier — if a previous arm did, demote
            // the dest by removing the carrier (every arm must
            // agree).
            _ = self.carrier_of.remove(dest);
        }
    }

    fn classifyAndPropagate(self: *FlowWalker, instr: *const ir.Instruction, instr_id: arc_liveness.InstructionId) !void {
        switch (instr.*) {
            // -------------------------------------------------
            // Carrier-propagating alias forms. Phase 2.1: also
            // propagate `tuple_pending` membership through these forms
            // so a tuple_init's dest can flow through a `local_set`
            // re-binding and still resolve as PU at the return site.
            // -------------------------------------------------
            .local_get => |lg| {
                try self.propagateCarrier(lg.dest, lg.source);
                try self.propagateTuplePending(lg.dest, lg.source);
            },
            .local_set => |ls| {
                try self.propagateCarrier(ls.dest, ls.value);
                try self.propagateTuplePending(ls.dest, ls.value);
            },
            .move_value => |mv| {
                try self.propagateCarrier(mv.dest, mv.source);
                try self.propagateTuplePending(mv.dest, mv.source);
            },
            .share_value => |sv| {
                try self.propagateCarrier(sv.dest, sv.source);
                try self.propagateTuplePending(sv.dest, sv.source);
            },
            .copy_value => |cv| {
                // Phase 2.2 — `copy_value` at last-use is semantically
                // a `move_value`. The IR builder emits `copy_value`
                // defensively when a binding *might* have further uses
                // along OTHER execution paths, but along the CURRENT
                // path (the one this `copy_value` lives on), the
                // source is dead immediately after the copy. The
                // matching scope-exit drop on the source is paired
                // with the copy's retain, so net refcount delta is 0
                // — the cell stays unique, just under a new owner
                // alias. Treat it as a carrier-propagating alias
                // form.
                //
                // Without ownership info, fall back to the legacy
                // conservative behaviour (AL on the source, no
                // carrier propagation).
                const is_last_use_copy = blk: {
                    if (self.function_ownership) |fo| {
                        if (fo.isLastUseAt(cv.source, instr_id)) break :blk true;
                    }
                    break :blk false;
                };
                if (is_last_use_copy) {
                    try self.propagateCarrier(cv.dest, cv.source);
                    try self.propagateTuplePending(cv.dest, cv.source);
                } else {
                    // copy_value creates a new owner with a runtime
                    // retain. The resulting cell has refcount > 1 —
                    // the parameter's uniqueness is no longer
                    // preservable through this path. Mark the source
                    // param as AL.
                    if (self.carrier_of.get(cv.source)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    _ = self.carrier_of.remove(cv.dest);
                    // copy_value at a non-last-use source resolves
                    // the pending entry as AL — the cell now exists
                    // in two owner positions (the copy + the
                    // original tuple construction), so neither is
                    // uniquely owned.
                    try self.resolveTuplePendingAsAL(cv.source);
                }
            },
            .borrow_value => |bv| {
                try self.propagateCarrier(bv.dest, bv.source);
                try self.propagateTuplePending(bv.dest, bv.source);
            },

            // -------------------------------------------------
            // Aggregate inits — storing a parameter into an
            // aggregate cell aliases it (the aggregate holds a
            // permanent retain).
            //
            // Phase 2.1 — `tuple_init` is the EXCEPTION: instead of
            // unconditionally upgrading carriers to AL, we DEFER the
            // classification by recording a `tuple_pending` entry
            // keyed on the tuple's dest. Later, when the tuple is
            // observed at a sink (return = PU witness, escape = AL),
            // the deferred entry resolves with the appropriate flow.
            // -------------------------------------------------
            .tuple_init => |ti| {
                try self.recordTuplePending(ti.dest, ti.elements);
            },
            .list_init => |li| {
                for (li.elements) |elem| {
                    if (self.carrier_of.get(elem)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    try self.resolveTuplePendingAsAL(elem);
                }
            },
            .list_cons => |lc| {
                if (self.carrier_of.get(lc.head)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
                if (self.carrier_of.get(lc.tail)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
                try self.resolveTuplePendingAsAL(lc.head);
                try self.resolveTuplePendingAsAL(lc.tail);
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    if (self.carrier_of.get(entry.key)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    if (self.carrier_of.get(entry.value)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    try self.resolveTuplePendingAsAL(entry.key);
                    try self.resolveTuplePendingAsAL(entry.value);
                }
            },
            .struct_init => |si| {
                for (si.fields) |f| {
                    if (self.carrier_of.get(f.value)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    try self.resolveTuplePendingAsAL(f.value);
                }
            },
            .union_init => |ui| {
                if (self.carrier_of.get(ui.value)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
                try self.resolveTuplePendingAsAL(ui.value);
            },
            .make_closure => |mc| {
                // Capturing a parameter into a closure environment
                // is an unconditional escape — the closure may live
                // beyond the function, so the parameter is no longer
                // unique-recoverable.
                for (mc.captures) |cap| {
                    if (self.carrier_of.get(cap)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    try self.resolveTuplePendingAsAL(cap);
                }
            },

            // -------------------------------------------------
            // Calls — the meaty case. Each arg slot of the callee
            // contributes either CU (consumes uniqueness), PU
            // (preserves), or AL (aliases) to the caller's
            // parameter accumulator, depending on the callee's
            // own signature.
            //
            // Phase 2.1: a tuple_pending arg passed to a call is a
            // strong escape signal — the called function may store
            // the tuple in a non-returned aggregate, capture it in a
            // closure, etc. Resolve the pending entry as AL before
            // the call's classifier runs (the call itself has its
            // own per-arg classification, but the deferred tuple
            // record must be cleared so it doesn't survive past the
            // call as a stale pending entry).
            // -------------------------------------------------
            .call_named => |cn| {
                for (cn.args) |arg| try self.resolveTuplePendingAsAL(arg);
                try self.classifyCall(cn.name, cn.args, cn.dest, false);
            },
            .call_direct => |cd| {
                for (cd.args) |arg| try self.resolveTuplePendingAsAL(arg);
                try self.classifyCallToFunction(cd.function, cd.args, cd.dest, false);
            },
            .try_call_named => |tcn| {
                for (tcn.args) |arg| try self.resolveTuplePendingAsAL(arg);
                try self.classifyCall(tcn.name, tcn.args, tcn.dest, false);
            },
            .tail_call => |tc| {
                for (tc.args) |arg| try self.resolveTuplePendingAsAL(arg);
                try self.classifyCall(tc.name, tc.args, 0, true);
            },
            .call_builtin => |cb| {
                for (cb.args) |arg| try self.resolveTuplePendingAsAL(arg);
                try self.classifyBuiltinCall(cb.name, cb.args, cb.dest);
            },
            .call_closure => |cc| {
                // Closure calls have unanalysable callees — every
                // arg that carries a parameter contributes ⊤.
                for (cc.args) |arg| {
                    if (self.carrier_of.get(arg)) |slot| {
                        try self.upgradeParam(slot, ParamSig.unknown());
                    }
                    try self.resolveTuplePendingAsAL(arg);
                }
                _ = self.carrier_of.remove(cc.dest);
            },
            .call_dispatch => |cd| {
                for (cd.args) |arg| {
                    if (self.carrier_of.get(arg)) |slot| {
                        try self.upgradeParam(slot, ParamSig.unknown());
                    }
                    try self.resolveTuplePendingAsAL(arg);
                }
                _ = self.carrier_of.remove(cd.dest);
            },

            // -------------------------------------------------
            // Returns — a parameter that flows directly into the
            // return position preserves uniqueness through to the
            // caller. Phase 2.1 widens this to tuple-pending returns:
            // when the return value is a `tuple_pending` dest, every
            // component-carrier classifies as PU with the component
            // index as the witness.
            // -------------------------------------------------
            .ret => |r| {
                if (r.value) |val| try self.classifyReturnValue(val);
            },
            .cond_return => |cr| {
                if (cr.value) |val| try self.classifyReturnValue(val);
            },

            // -------------------------------------------------
            // Field/index reads — these don't move ownership of
            // the source. The dest is a borrow into the parent
            // aggregate, NOT a carrier of a parameter.
            //
            // Phase 2.1 EXCEPTION — `index_get` from a `tuple_pending`
            // source: the destructured component DOES carry the
            // parameter slot recorded on that component. This is
            // exactly the `{p, count, done} = call_result` idiom
            // fannkuch's `main_loop` uses on `advance_perm`'s tuple
            // return — without this hop, the destructured `p` and
            // `count` lose their parameter-slot identity and the uniqueness
            // `List.set` rewrite never fires on the rebound
            // bindings.
            // -------------------------------------------------
            .index_get => |ig| {
                if (self.tuple_pending.getPtr(ig.object)) |comps_ptr| {
                    const comps = comps_ptr.*;
                    if (ig.index < comps.len) {
                        if (comps[ig.index].slot) |slot| {
                            try self.carrier_of.put(self.allocator, ig.dest, slot);
                        }
                    }
                }
            },
            .field_get,
            .list_len_check,
            .list_get,
            .list_is_not_empty,
            .list_head,
            .list_tail,
            .map_has_key,
            .map_get,
            => {},

            // -------------------------------------------------
            // No-effect on the carrier-flow for the rest.
            // -------------------------------------------------
            else => {},
        }
    }

    /// Propagate the carrier from `source` to `dest`. After this
    /// call, any flow from `dest` is treated as the same parameter
    /// flow as `source` was.
    fn propagateCarrier(self: *FlowWalker, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.carrier_of.get(source)) |slot| {
            try self.carrier_of.put(self.allocator, dest, slot);
        }
    }

    /// Phase 2.1 — propagate a `tuple_pending` membership through an
    /// alias-form instruction. When `source` is a tuple_pending dest,
    /// the alias's `dest` becomes a new tuple_pending entry pointing
    /// at the same component table. Pure aliasing does not change
    /// component witnesses or resolve the deferred entry — only true
    /// sinks (return / escape) do.
    ///
    /// We move ownership of the component slice from `source` to
    /// `dest`: the source key is removed and the component slice is
    /// re-keyed under `dest`. This keeps the walker's per-key
    /// invariant intact (each pending entry owns exactly one slice in
    /// `allocator`), without doubling memory.
    ///
    /// If `source` is not a tuple_pending dest, this is a no-op.
    fn propagateTuplePending(self: *FlowWalker, dest: ir.LocalId, source: ir.LocalId) !void {
        if (dest == source) return;
        const entry = self.tuple_pending.fetchRemove(source) orelse return;
        // Remove any pre-existing pending entry at `dest` (e.g.
        // overwritten by a re-binding) — its slice must be freed
        // before being replaced.
        if (self.tuple_pending.fetchRemove(dest)) |existing| {
            self.allocator.free(existing.value);
        }
        try self.tuple_pending.put(self.allocator, dest, entry.value);
    }

    /// Phase 2.1 — record a fresh `tuple_init` deferral. Builds a
    /// component table from `elements` (each entry's `slot` is the
    /// parameter slot the corresponding element carries, or `null` for
    /// non-carrier components). When an element is itself a
    /// tuple_pending dest, we conservatively classify ALL of the
    /// inner tuple's carriers as AL — a nested tuple stored as a
    /// component of an outer tuple loses its first-class identity for
    /// the return-witness analysis. The outer tuple's component for
    /// that slot still records `null` (no carrier witness) and the
    /// inner pending entry is removed.
    fn recordTuplePending(
        self: *FlowWalker,
        dest: ir.LocalId,
        elements: []const ir.LocalId,
    ) !void {
        // Allocate the component table eagerly. If allocation fails
        // we fall back to the legacy AL-per-element behaviour for the
        // current tuple_init, preserving correctness under OOM.
        const components = self.allocator.alloc(TupleComponent, elements.len) catch {
            for (elements) |elem| {
                if (self.carrier_of.get(elem)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
            }
            return;
        };
        for (components, elements) |*comp, elem| {
            comp.* = .{ .slot = self.carrier_of.get(elem) };
            // Nested tuple — flatten by AL'ing the nested carriers
            // and removing the inner pending entry. A more permissive
            // analysis could recursively flatten witnesses through
            // nested tuples, but that adds complexity without payoff
            // for the fannkuch / spectral-norm patterns: those return
            // flat tuples, never nested ones.
            try self.resolveTuplePendingAsAL(elem);
        }
        // If `dest` already has a pending entry (e.g. overwritten by a
        // re-binding through `local_set`), free the old slice first.
        if (self.tuple_pending.fetchRemove(dest)) |existing| {
            self.allocator.free(existing.value);
        }
        try self.tuple_pending.put(self.allocator, dest, components);
    }

    /// Phase 2.1 — resolve a deferred tuple-construction record as AL.
    /// Every component-carrier in the table contributes an AL
    /// observation to the corresponding parameter's accumulator.
    /// Removes the entry from the pending map. No-op when `local`
    /// is not on the pending map.
    fn resolveTuplePendingAsAL(self: *FlowWalker, local: ir.LocalId) !void {
        const entry = self.tuple_pending.fetchRemove(local) orelse return;
        defer self.allocator.free(entry.value);
        for (entry.value) |comp| {
            if (comp.slot) |slot| {
                try self.upgradeParam(slot, ParamSig.aliasesOut());
            }
        }
    }

    /// Phase 2.1 — classify a return-position value. Three cases:
    ///
    ///   1. The value is a `tuple_pending` dest: each component-
    ///      carrier classifies as PU with its component index as the
    ///      return-witness. Component witnesses also accumulate into
    ///      `observed_return_components` so the merge phase can
    ///      record per-tuple-component witnesses on the function's
    ///      `return_components` slice. The pending entry is removed
    ///      after resolution.
    ///
    ///   2. The value is a direct carrier (the param is returned
    ///      whole — single-result PU): classify as PU with the
    ///      whole-return witness (`null`).
    ///
    ///   3. Otherwise: no flow upgrade. The return doesn't observe
    ///      a parameter at this site.
    fn classifyReturnValue(self: *FlowWalker, val: ir.LocalId) !void {
        if (self.tuple_pending.fetchRemove(val)) |entry| {
            defer self.allocator.free(entry.value);
            // Ensure observed_return_components is sized to the tuple's
            // arity, padding with `null` for any gaps.
            while (self.observed_return_components.items.len < entry.value.len) {
                try self.observed_return_components.append(self.allocator, null);
            }
            for (entry.value, 0..) |comp, idx| {
                if (comp.slot) |slot| {
                    try self.upgradeParam(slot, ParamSig.preservesUniqueness(@intCast(idx)));
                    // Record the per-component witness for this
                    // observed return. The merge phase later joins
                    // across all observations and stores the meet on
                    // the signature's `return_components` slice.
                    if (idx < self.observed_return_components.items.len) {
                        const existing = self.observed_return_components.items[idx];
                        const merged: ?u8 = if (existing == null)
                            @as(?u8, @intCast(slot))
                        else if (existing.? == @as(u8, @intCast(slot)))
                            existing
                        else
                            null;
                        self.observed_return_components.items[idx] = merged;
                    }
                }
            }
            return;
        }
        // Non-tuple return: direct-carrier → whole-return PU.
        if (self.carrier_of.get(val)) |slot| {
            try self.upgradeParam(slot, ParamSig.preservesUniqueness(null));
        }
    }

    /// Classify a builtin call. Owned-mutating builtins (Map.put,
    /// List.set, etc.) consume their receiver and return a
    /// fresh-rc=1 cell — so for the receiver slot, the parameter
    /// is consumed. The result carries the same parameter as the
    /// receiver did (the runtime contract guarantees rc=1, so the
    /// dest is a uniqueness-preserving derivative).
    fn classifyBuiltinCall(
        self: *FlowWalker,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
    ) !void {
        const slot_opt = arc_liveness.ownedMutatingBuiltinSlot(name);
        if (slot_opt) |receiver_idx| {
            // Owned-mutating: receiver is consumed; dest is the
            // fresh-rc=1 cell. Parameter flows through.
            for (args, 0..) |arg, idx| {
                if (self.carrier_of.get(arg)) |slot| {
                    if (idx == receiver_idx) {
                        // Receiver position: the call consumes the
                        // parameter's uniqueness, but returns a
                        // unique-derivative; this is the textbook
                        // "preserves uniqueness" idiom.
                        try self.upgradeParam(slot, ParamSig.preservesUniqueness(null));
                    } else {
                        // Non-receiver position: the arg is just
                        // borrowed. No uniqueness is consumed, and
                        // no flow upgrades. Leave the accumulator.
                    }
                }
            }
            // Carry the receiver's parameter through to the dest.
            if (receiver_idx < args.len) {
                if (self.carrier_of.get(args[receiver_idx])) |slot| {
                    try self.carrier_of.put(self.allocator, dest, slot);
                }
            }
            return;
        }
        // `:zig.List.cons(head, tail)` — the cons tail (slot 1) is the
        // existing list the new cell prepends onto. Under the runtime's
        // rc-1 in-place fast path a refcount-1 tail is mutated in place
        // and returned AS the result cell, so the tail's uniqueness
        // flows through to the cons result: the tail position is
        // `preserves_uniqueness`, and the result carries the tail's
        // parameter slot forward. The head (slot 0) is stored into the
        // new cell as an element (clone-on-insert gives the cell its own
        // owner), so it `aliases` out — the head is NOT recoverable as a
        // unique value through the return.
        //
        // This is the signature-inference half of the cons-tail-at-last-
        // use linearity that `consBuiltinTailSlot` names. The
        // per-instruction enforcement (the tail-at-last-use gate
        // mirroring the `list_cons` IR-node rc-1 path) lives in the
        // uniqueness dataflow (`uniqueness.Analyzer.applyEffect` and the
        // tentative pre-flight); the verifier is the final safety net.
        // Closing this is what lets a `List.prepend(accumulator, value)`
        // wrapper inherit its `list` slot's uniqueness into the return,
        // so a recursive combinator accumulator threaded through cons
        // stays unique-on-entry and can be promoted to `.owned`.
        if (arc_liveness.consBuiltinTailSlot(name)) |tail_slot| {
            for (args, 0..) |arg, idx| {
                if (self.carrier_of.get(arg)) |slot| {
                    if (idx == tail_slot) {
                        try self.upgradeParam(slot, ParamSig.preservesUniqueness(null));
                    } else {
                        // Head position (or any non-tail arg): stored as
                        // an element; the parameter aliases out.
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                }
            }
            // Carry the tail's parameter through to the dest so the
            // cons result is recognised as preserving that parameter's
            // uniqueness for the enclosing function's return witness.
            if (tail_slot < args.len) {
                if (self.carrier_of.get(args[tail_slot])) |slot| {
                    try self.carrier_of.put(self.allocator, dest, slot);
                } else {
                    _ = self.carrier_of.remove(dest);
                }
            } else {
                _ = self.carrier_of.remove(dest);
            }
            return;
        }

        // Non-mutating builtin: any param flowing in is borrowed —
        // the parameter is *not* consumed, no flow upgrades. The
        // dest does not carry a parameter (fresh, not parameter-
        // preserving by construction).
        _ = self.carrier_of.remove(dest);
    }

    /// Classify a call to a Zap function (call_named etc.). For
    /// each arg position, we consult the *callee's* signature for
    /// that slot:
    ///
    ///   - `consumes_uniquely`: the call consumes the parameter,
    ///     no live alias remains. Caller's parameter contributes
    ///     CU at this site.
    ///   - `preserves_uniqueness`: the call consumes uniqueness
    ///     and threads it through the return. Caller's parameter
    ///     contributes PU; the return value carries the parameter
    ///     forward.
    ///   - `aliases`: the callee escapes the parameter. Caller
    ///     contributes AL.
    ///   - `top` or unknown: conservative — caller contributes
    ///     `top` (i.e. demote the parameter's signature to ⊤).
    fn classifyCall(
        self: *FlowWalker,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        is_tail_call: bool,
    ) !void {
        const target = self.lookupByName(name) orelse {
            // Unresolvable target — every arg carrier flows into ⊤.
            for (args) |arg| {
                if (self.carrier_of.get(arg)) |slot| {
                    try self.upgradeParam(slot, ParamSig.unknown());
                }
            }
            _ = self.carrier_of.remove(dest);
            return;
        };
        try self.classifyCallToFunction(target, args, dest, is_tail_call);
    }

    fn classifyCallToFunction(
        self: *FlowWalker,
        callee_id: ir.FunctionId,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        is_tail_call: bool,
    ) !void {
        const callee_sig = self.signatures.forFunction(callee_id) orelse {
            // No signature recorded — should never happen for
            // in-program callees, but be conservative.
            for (args) |arg| {
                if (self.carrier_of.get(arg)) |slot| {
                    try self.upgradeParam(slot, ParamSig.unknown());
                }
            }
            _ = self.carrier_of.remove(dest);
            return;
        };

        // Phase 1.8 item #5 — borrow short-circuit. When the callee
        // resolves to a function whose parameter slot is `.borrowed`,
        // the ABI guarantees that callee never consumes the value's
        // refcount. Combined with a non-aliasing signature
        // (`unobserved` or `top` — i.e., no observed escape — the only
        // upgrades that fire on the callee body's flows would be the
        // PU/CU flows the uniqueness_fixpoint already classifies), the call
        // is a "borrow pass-through" and must not poison the caller's
        // carrier accumulator. The verifier (uniqueness) remains the safety
        // net: a wrong inference produces a compilation rejection,
        // never a miscompilation.
        //
        // The guard fires only when:
        //   1. The callee resolves to a function in the program, AND
        //   2. The relevant slot's convention is `.borrowed`, AND
        //   3. The slot's signature class is `top` or `unobserved`
        //      (no concrete escape observation has been recorded —
        //      `aliases` is excluded by construction).
        //
        // For example: `List.get(list, index)` (a Zap function
        // forwarding to a non-mutating runtime builtin) has slot 0
        // `.borrowed` and signature `top` post-cleanup. Without this
        // guard, every caller's uniqueness carrier accumulator gets polluted
        // to ⊤; with it, the caller's accumulator passes through
        // unchanged so downstream PU/CU flows keep firing.
        const callee_func = lookupFunction(self.program, callee_id);

        // Track which arg position (if any) preserves uniqueness
        // through to the dest. This determines whether the dest
        // *carries* a parameter forward.
        var preserves_carrier_from_arg: ?usize = null;

        for (args, 0..) |arg, arg_idx| {
            const carrier_slot = self.carrier_of.get(arg) orelse continue;
            const callee_class: UniquenessClass = blk: {
                if (arg_idx >= callee_sig.params.len) break :blk .top;
                break :blk callee_sig.params[arg_idx].class;
            };
            switch (callee_class) {
                .consumes_uniquely => {
                    // Caller's parameter is consumed at this site.
                    // Combined with a tail-call this is the canonical
                    // accumulator-recursion shape (PU).
                    if (is_tail_call) {
                        try self.upgradeParam(carrier_slot, ParamSig.preservesUniqueness(null));
                    } else {
                        try self.upgradeParam(carrier_slot, ParamSig.consumesUniquely());
                    }
                },
                .preserves_uniqueness => {
                    // Callee threads uniqueness through to its return.
                    // Caller's parameter contributes PU; the dest
                    // carries the same parameter forward.
                    //
                    // Phase 2.1: record the per-arg-to-component
                    // mapping in the dest's `tuple_pending` table when
                    // the callee's signature has a non-empty
                    // `return_components` table that names this arg
                    // position as a witness. This allows downstream
                    // destructuring (`{q, ...} = call_dest`) to
                    // recover the carrier on the destructured local
                    // and surface PU to a tuple-return on the caller.
                    try self.upgradeParam(carrier_slot, ParamSig.preservesUniqueness(callee_sig.params[arg_idx].preserves_to_return_component));
                    preserves_carrier_from_arg = arg_idx;
                },
                .aliases => {
                    try self.upgradeParam(carrier_slot, ParamSig.aliasesOut());
                },
                .top, .unobserved => {
                    // Phase 1.8 item #5 — borrow short-circuit gate.
                    // When the callee's slot is `.borrowed` and the
                    // signature lacks any escape evidence
                    // (top/unobserved), the call is a no-effect
                    // borrow pass-through on the caller's carrier.
                    // The borrow ABI rules out consume; no upgrade
                    // observation rules out alias-into-aggregate.
                    if (callee_func) |fp| {
                        if (arg_idx < fp.param_conventions.len and
                            fp.param_conventions[arg_idx] == .borrowed)
                        {
                            // Borrow pass-through: leave the caller's
                            // carrier untouched. Don't upgrade and
                            // don't set `preserves_carrier_from_arg`
                            // (the call's dest, even if a List,
                            // doesn't preserve the caller's parameter
                            // chain through this call — borrows
                            // produce a fresh dest unrelated to the
                            // borrowed source's owner identity).
                            continue;
                        }
                    }
                    if (callee_class == .unobserved) {
                        // Within an SCC, the callee's signature
                        // hasn't settled yet. Don't pollute the
                        // accumulator — leave it untouched and rely
                        // on the next iteration to refine.
                        // BUT we also don't clear the carrier on
                        // the dest, in case the callee later proves
                        // PU and the dest should carry the param.
                    } else {
                        try self.upgradeParam(carrier_slot, ParamSig.unknown());
                    }
                },
            }
        }

        // Propagate the carrier into the dest if the callee preserves
        // uniqueness from one of the arg positions. (Tail calls have
        // dest=0 by convention; the caller's body has already been
        // flushed and there's nothing to track post-tail.)
        if (!is_tail_call) {
            // Phase 2.1: when the callee's signature has a
            // non-trivial `return_components` table (any component
            // names a parameter slot witness), synthesize a
            // tuple_pending record on the call's dest. Each component
            // that names parameter slot j inherits the caller's
            // carrier of `args[j]`. Downstream `index_get` on the
            // dest will project the appropriate carrier out per
            // component — letting `{p, count, done} = call_result`
            // recover the parameter slot identity for each
            // destructured local.
            //
            // This synthesized pending entry is functionally
            // equivalent to the call dest being a `tuple_init` whose
            // elements were the per-component witness aliases — but
            // we don't need the IR to actually emit a tuple_init for
            // the synthesis to apply.
            var has_per_component_witness = false;
            for (callee_sig.return_components) |opt| {
                if (opt != null) {
                    has_per_component_witness = true;
                    break;
                }
            }
            if (has_per_component_witness) {
                const components = self.allocator.alloc(TupleComponent, callee_sig.return_components.len) catch null;
                if (components) |comps| {
                    for (comps, callee_sig.return_components) |*comp, witness_opt| {
                        comp.* = .{ .slot = null };
                        if (witness_opt) |arg_idx_u8| {
                            const arg_idx_in: usize = @intCast(arg_idx_u8);
                            if (arg_idx_in < args.len) {
                                if (self.carrier_of.get(args[arg_idx_in])) |slot| {
                                    comp.slot = slot;
                                }
                            }
                        }
                    }
                    if (self.tuple_pending.fetchRemove(dest)) |existing| {
                        self.allocator.free(existing.value);
                    }
                    self.tuple_pending.put(self.allocator, dest, comps) catch self.allocator.free(comps);
                }
            }

            if (preserves_carrier_from_arg) |arg_idx| {
                if (self.carrier_of.get(args[arg_idx])) |slot| {
                    try self.carrier_of.put(self.allocator, dest, slot);
                }
            } else {
                _ = self.carrier_of.remove(dest);
            }
        }
    }

    fn lookupByName(self: *const FlowWalker, name: []const u8) ?ir.FunctionId {
        return self.name_to_id.get(name);
    }

    fn upgradeParam(self: *FlowWalker, slot: u32, new_sig: ParamSig) !void {
        if (slot >= self.accumulators.items.len) return;
        const existing = self.accumulators.items[slot].sig;
        self.accumulators.items[slot].sig = uniqueness_signature.join(existing, new_sig);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-rolled fixpoint tests.
/// Caller owns the slices in `arena` and is responsible for freeing
/// them by deinit'ing the arena.
fn buildTestFunction(
    arena: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_count: u32,
    param_conventions: []const ir.ParamConvention,
    result_convention: ir.ResultConvention,
) !ir.Function {
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, instructions),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, local_count);
    for (ownership) |*o| o.* = .owned;
    const conventions = try arena.dupe(ir.ParamConvention, param_conventions);
    const params = try arena.alloc(ir.Param, param_conventions.len);
    for (params) |*p| p.* = .{ .name = "p", .type_expr = .void, .type_id = null };
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = @intCast(param_conventions.len),
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = local_count,
        .param_conventions = conventions,
        .local_ownership = ownership,
        .result_convention = result_convention,
    };
}

test "uniqueness_fixpoint: empty program produces empty signatures" {
    var program = ir.Program{ .functions = &.{}, .type_defs = &.{}, .entry = null };
    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), sigs.by_function.count());
}

test "uniqueness_fixpoint: identity function returning its parameter is PU" {
    // Function: fn id(p :: List(i64)) -> List(i64) { p }
    // Body:
    //   [0] param_get  dest=0 index=0
    //   [1] ret         value=0
    //
    // Expected signature: param[0].class = preserves_uniqueness.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(arena, "id", &instrs, 1, &.{.owned}, .owned);
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(@as(usize, 1), sig.params.len);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[0].class);
}

test "uniqueness_fixpoint: function storing param into list_cons is AL" {
    // Body:
    //   [0] param_get   dest=0 index=0
    //   [1] const_nil   1
    //   [2] list_cons   dest=2 head=0 tail=1
    //   [3] ret         value=2
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    var function = try buildTestFunction(arena, "store", &instrs, 3, &.{.owned}, .owned);
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.aliases, sig.params[0].class);
}

test "uniqueness_fixpoint: function calling owned-mutating builtin on param is PU" {
    // Body (sketch of `set_zero(list) -> List.set(list, 0, 0)`):
    //   [0] param_get   dest=0 index=0
    //   [1] const_int   dest=1 value=0
    //   [2] const_int   dest=2 value=0
    //   [3] move_value  dest=3 source=0
    //   [4] call_builtin dest=4 name="List:i64.set" args=[3,1,2]
    //   [5] ret         value=4
    //
    // The receiver (arg 0 of List.set) is owned-mutating, so the
    // param's flow is "preserves uniqueness through to the dest"; the
    // dest is then returned.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List:i64.set",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    var function = try buildTestFunction(arena, "set_zero", &instrs, 5, &.{.owned}, .owned);
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[0].class);
}

test "uniqueness_fixpoint: function with no in-scope callers is conservative top when truly unobserved" {
    // Body:
    //   [0] param_get   dest=0 index=0
    //   [1] ret         value=null  (no return value to observe)
    //
    // Note: if the param is never used in any flow, we promote
    // unobserved → top via the sweep at the end of computeSignatures.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = null } },
    };
    var function = try buildTestFunction(arena, "noop", &instrs, 1, &.{.owned}, .trivial);
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.top, sig.params[0].class);
}

test "uniqueness_fixpoint: borrow-passthrough callee with top signature does not poison caller (Phase 1.8 item #5)" {
    // Two-function setup that exercises the borrow short-circuit
    // specifically. The callee's body has CONFLICTING flows that
    // join to `top` WITHIN the callee's SCC analysis (PU from
    // returning the param + AL from a list_cons storing the param).
    // Without the short-circuit, the caller's classifyCallToFunction
    // sees the callee's slot class as `top` mid-SCC and pollutes the
    // caller's carrier accumulator — the caller's param 0 reaches
    // `top` instead of PU.
    //
    // With the short-circuit (item #5): the callee's slot is
    // `.borrowed`, so even when its class settles at `top`, the
    // call site is treated as no-effect on the caller's carrier.
    // The caller's param 0 reaches PU via the downstream
    // owned-mutating call.
    //
    //   callee(p :: List(i64)) -> List(i64) {     # borrowed slot 0, top sig
    //     _ = [p | nil]                             # AL flow (list_cons; survives Phase 2.1)
    //     p                                          # PU flow (ret)
    //   }
    //
    //   caller(v :: List(i64)) -> List(i64) {      # owned slot 0
    //     _ = callee(v)                             # borrow-passthrough call
    //     List.set(v, 0, 0)                         # PU flow -> caller slot 0 = PU
    //   }
    //
    // Phase 2.1 note: the original test used `tuple_init` for the AL
    // evidence, but Phase 2.1 defers tuple-init aliasing until a
    // resolution sink is observed. A dead tuple_init no longer ALs
    // the param. We keep the same conflicting-flows shape using
    // list_cons, which is still classified as an immediate AL site
    // (lists do escape unconditionally).
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Function 0 (id=0): "borrow_aliaser" -- the borrowed callee whose
    // body has conflicting flows for slot 0:
    //   [0] param_get  dest=0  index=0
    //   [1] const_nil  dest=1                     -- nil tail
    //   [2] list_cons  dest=2  head=0 tail=1      -- AL flow on slot 0
    //   [3] ret         value=0                    -- PU flow on slot 0
    //
    // Slot 0 conv = .borrowed. Body flows: AL (list_cons) ⊔ PU (ret) = top.
    // After SCC analysis (no cleanup needed — the body produces top
    // directly), the signature for slot 0 is `top` AND the slot conv
    // remains `.borrowed`.
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    var callee_func = try buildTestFunction(
        arena,
        "borrow_aliaser",
        &callee_instrs,
        3,
        &[_]ir.ParamConvention{.borrowed},
        .owned,
    );
    callee_func.id = 0;

    // Function 1 (id=1): "caller" -- exercises the borrow short-circuit.
    //   [0] param_get   dest=0  index=0      (read v for the borrow_aliaser call)
    //   [1] call_named  dest=1  name="borrow_aliaser" args=[0]
    //   [2] param_get   dest=2  index=0      (read v again for the set)
    //   [3] const_int   dest=3  value=0
    //   [4] const_int   dest=4  value=0
    //   [5] move_value  dest=5  source=2
    //   [6] call_builtin dest=6 name="List:i64.set" args=[5,3,4]
    //   [7] ret         value=6
    const caller_call_args = try arena.alloc(ir.LocalId, 1);
    caller_call_args[0] = 0;
    const caller_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_call_arg_modes[0] = .borrow;
    const set_args = try arena.alloc(ir.LocalId, 3);
    set_args[0] = 5;
    set_args[1] = 3;
    set_args[2] = 4;
    const set_arg_modes = try arena.alloc(ir.ValueMode, 3);
    set_arg_modes[0] = .move;
    set_arg_modes[1] = .borrow;
    set_arg_modes[2] = .borrow;
    const caller_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_named = .{
            .dest = 1,
            .name = "borrow_aliaser",
            .args = caller_call_args,
            .arg_modes = caller_call_arg_modes,
        } },
        .{ .param_get = .{ .dest = 2, .index = 0 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 2 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "List:i64.set",
            .args = set_args,
            .arg_modes = set_arg_modes,
        } },
        .{ .ret = .{ .value = 6 } },
    };
    var caller_func = try buildTestFunction(
        arena,
        "caller",
        &caller_instrs,
        7,
        &[_]ir.ParamConvention{.owned},
        .owned,
    );
    caller_func.id = 1;

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = callee_func;
    functions[1] = caller_func;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    // Sanity: the borrow_aliaser callee's slot 0 reached `top` from
    // the AL ⊔ PU join.
    const callee_sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.top, callee_sig.params[0].class);

    // Phase 1.8 item #5 expectation: caller's param 0 is PU (preserved
    // through List.set). Without the short-circuit, the call to
    // `borrow_aliaser` (callee class top, callee slot 0 .borrowed)
    // would poison caller's slot 0 to top.
    const caller_sig = sigs.forFunction(1).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, caller_sig.params[0].class);
}

test "uniqueness_fixpoint: aliases-out callee via list_cons still poisons caller (sound check for borrow short-circuit)" {
    // Two-function setup where the callee genuinely escapes its
    // borrowed parameter into a list (which is unconditionally an AL
    // sink — lists hold a permanent retain on their elements). The
    // callee's signature is `aliases`, NOT `top`. The borrow
    // short-circuit MUST NOT bypass the upgrade in this case —
    // caller's carrier must be poisoned.
    //
    //   callee(p) -> List(List(i64)) { [p] }     # aliases through list_cons
    //   caller(v) -> callee(v)                   # caller passes v
    //
    // Expected: caller's param 0 = AL (aliases), NOT PU.
    //
    // Phase 2.1 note: the original test used a `tuple_init` and
    // returned the tuple, but Phase 2.1's tuple-return PU
    // classification correctly recognises that `fn f(p) -> {p}`
    // preserves uniqueness (the caller's `q = (f(v)).0` recovers a
    // unique alias to the same cell). The aliasing escape is now
    // tested through `list_cons`, which remains AL because lists
    // produce a heap-stored alias that outlives the function.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Function 0: callee that aliases its param into a list.
    //   [0] param_get  dest=0 index=0
    //   [1] const_nil  dest=1
    //   [2] list_cons  dest=2 head=0 tail=1
    //   [3] ret         value=2
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    var callee_func = try buildTestFunction(
        arena,
        "list_wrap",
        &callee_instrs,
        3,
        &[_]ir.ParamConvention{.borrowed},
        .owned,
    );
    callee_func.id = 0;

    // Function 1: caller forwarding its param into the aliasing callee.
    //   [0] param_get  dest=0 index=0
    //   [1] call_named dest=1 name="list_wrap" args=[0]
    //   [2] ret         value=1
    const caller_call_args = try arena.alloc(ir.LocalId, 1);
    caller_call_args[0] = 0;
    const caller_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_call_arg_modes[0] = .share;
    const caller_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_named = .{
            .dest = 1,
            .name = "list_wrap",
            .args = caller_call_args,
            .arg_modes = caller_call_arg_modes,
        } },
        .{ .ret = .{ .value = 1 } },
    };
    var caller_func = try buildTestFunction(
        arena,
        "forward",
        &caller_instrs,
        2,
        &[_]ir.ParamConvention{.owned},
        .owned,
    );
    caller_func.id = 1;

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = callee_func;
    functions[1] = caller_func;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    // Callee aliases its param via list_cons: signature = AL.
    const callee_sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.aliases, callee_sig.params[0].class);

    // Caller's param 0 must inherit AL — the short-circuit must NOT
    // bypass the aliases upgrade.
    const caller_sig = sigs.forFunction(1).?;
    try testing.expectEqual(UniquenessClass.aliases, caller_sig.params[0].class);
}

test "uniqueness_fixpoint: tuple-return identity is PU (Phase 2.1)" {
    // The canonical `fn f(p) -> {p}` shape that Phase 2.1's
    // tuple-return PU classification is meant to recognise. Without
    // the deferred-tuple-pending logic, the param would AL via the
    // tuple_init and reach `top` after the join with the PU return
    // observation. With Phase 2.1, the tuple_init's classification
    // is deferred; the `ret(tuple)` resolves the deferral as PU
    // with a per-component witness pointing back at slot 0.
    //
    //   fn id_tuple(p :: List(i64)) -> {List(i64)} = {p}
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .ret = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        arena,
        "id_tuple",
        &callee_instrs,
        2,
        &[_]ir.ParamConvention{.owned},
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    // Phase 2.1: param 0's signature is PU (the tuple_init defers,
    // ret resolves as PU).
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[0].class);
    // The component witness for return component 0 names parameter
    // slot 0 as the source of preservation.
    try testing.expect(sig.return_components.len >= 1);
    try testing.expectEqual(@as(?u8, 0), sig.return_components[0]);
}

test "uniqueness_fixpoint: tuple-return mixed components classify each carrier as PU (Phase 2.1)" {
    // Multi-carrier tuple return: `fn f(p, q) -> {p, q, false}`.
    // Each carrier component classifies as PU with its own witness.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elems = try arena.alloc(ir.LocalId, 3);
    tuple_elems[0] = 0; // param_get(0)
    tuple_elems[1] = 1; // param_get(1)
    tuple_elems[2] = 2; // const_bool false
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .const_bool = .{ .dest = 2, .value = false } },
        .{ .tuple_init = .{ .dest = 3, .elements = tuple_elems } },
        .{ .ret = .{ .value = 3 } },
    };
    var function = try buildTestFunction(
        arena,
        "id_pair",
        &callee_instrs,
        4,
        &[_]ir.ParamConvention{ .owned, .owned },
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[0].class);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[1].class);
    // Return components: comp 0 -> param 0, comp 1 -> param 1, comp 2 -> none.
    try testing.expect(sig.return_components.len >= 3);
    try testing.expectEqual(@as(?u8, 0), sig.return_components[0]);
    try testing.expectEqual(@as(?u8, 1), sig.return_components[1]);
    try testing.expectEqual(@as(?u8, null), sig.return_components[2]);
}

test "uniqueness_fixpoint: tuple stored in list still ALs the carrier (Phase 2.1 escape resolution)" {
    // `fn f(p) -> List({List(i64)}) { [{p}] }`. The tuple is
    // constructed with `p` as a component, then stored in a list
    // (via list_cons). The list_cons resolves the tuple_pending
    // entry as AL, so param 0's signature lands at AL — the runtime
    // contract is "the list holds a permanent retain on the tuple,
    // which holds a permanent retain on p".
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .const_nil = 2 },
        .{ .list_cons = .{ .dest = 3, .head = 1, .tail = 2 } },
        .{ .ret = .{ .value = 3 } },
    };
    var function = try buildTestFunction(
        arena,
        "tuple_in_list",
        &callee_instrs,
        4,
        &[_]ir.ParamConvention{.owned},
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.aliases, sig.params[0].class);
}

// ============================================================
// Phase 2.6.1 — signature propagation through aggregating
// control flow. Multi-clause functions whose tuple return flows
// through `switch_return`, `if_expr`, `case_block`,
// `switch_literal`, or `optional_dispatch` previously dropped
// the per-component witness because the walker did not classify
// the per-arm result locals at the merge point. The fix:
//
//   * `switch_return` / `union_switch_return` — every arm's
//     `return_value` (and the `default_result`) is a return-
//     equivalent sink. Trigger `classifyReturnValue` on each so
//     the per-arm tuple_init contributions roll up into the
//     function's `return_components` table.
//   * `if_expr` / `case_block` / `switch_literal` /
//     `try_call_named` — these aggregate via a parent `dest`
//     LocalId. Merge each arm's result-local `tuple_pending`
//     entry into the parent dest's entry under per-component
//     meet semantics so a downstream `ret(parent.dest)` resolves
//     the merged pending and emits a (possibly demoted) per-
//     component witness.
//   * `optional_dispatch` — each arm's result is a return-
//     equivalent sink at codegen time (the ZIR backend lowers
//     each arm with an implicit `ret`). Treat both arm results
//     like `switch_return` arms.
// ============================================================

test "uniqueness_fixpoint: switch_return per-arm tuple_init records per-component PU witness (Phase 2.6.1)" {
    // Multi-clause function dispatched on the first param's int
    // literal, both arms build a tuple from the remaining params
    // in matching positions. Both arms must record their per-
    // component PU witnesses on the function's signature.
    //
    //   pub fn advance(1, p, q) -> {List(i64), List(i64)} { {p, q} }
    //   pub fn advance(_, p, q) -> {List(i64), List(i64)} { {p, q} }
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Case 1 body: param_get(1) -> p, param_get(2) -> q,
    //              tuple_init({p, q}) -> t.
    const case_1_elems = try arena.alloc(ir.LocalId, 2);
    case_1_elems[0] = 10;
    case_1_elems[1] = 11;
    const case_1_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 10, .index = 1 } },
        .{ .param_get = .{ .dest = 11, .index = 2 } },
        .{ .tuple_init = .{ .dest = 12, .elements = case_1_elems } },
    });

    // Default body: same shape.
    const default_elems = try arena.alloc(ir.LocalId, 2);
    default_elems[0] = 20;
    default_elems[1] = 21;
    const default_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 20, .index = 1 } },
        .{ .param_get = .{ .dest = 21, .index = 2 } },
        .{ .tuple_init = .{ .dest = 22, .elements = default_elems } },
    });

    const cases = try arena.alloc(ir.ReturnCase, 1);
    cases[0] = .{
        .value = .{ .int = 1 },
        .body_instrs = case_1_body,
        .return_value = 12,
    };

    const callee_instrs = [_]ir.Instruction{
        .{ .switch_return = .{
            .scrutinee_param = 0,
            .cases = cases,
            .default_instrs = default_body,
            .default_result = 22,
        } },
    };

    var function = try buildTestFunction(
        arena,
        "advance_same_shape",
        &callee_instrs,
        23,
        &[_]ir.ParamConvention{ .owned, .owned, .owned },
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    // params 1 and 2 should both classify as PU (each appears as a
    // tuple component in every return arm, and both arms agree).
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[1].class);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[2].class);
    // return_components: both arms agree on (component 0 -> param 1,
    // component 1 -> param 2). Witnesses preserve through the meet.
    try testing.expect(sig.return_components.len >= 2);
    try testing.expectEqual(@as(?u8, 1), sig.return_components[0]);
    try testing.expectEqual(@as(?u8, 2), sig.return_components[1]);
}

test "uniqueness_fixpoint: switch_return disagreeing arms demote witness (Phase 2.6.1)" {
    // Case-1 returns {p, q}; default returns {q, p}. The per-arm
    // observations disagree on which slot occupies each component,
    // so the merge meet demotes both component witnesses to null.
    // Per-param classification still rolls up to PU because each
    // param is a tuple-component carrier in some arm.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const case_1_elems = try arena.alloc(ir.LocalId, 2);
    case_1_elems[0] = 10; // param 1
    case_1_elems[1] = 11; // param 2
    const case_1_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 10, .index = 1 } },
        .{ .param_get = .{ .dest = 11, .index = 2 } },
        .{ .tuple_init = .{ .dest = 12, .elements = case_1_elems } },
    });

    const default_elems = try arena.alloc(ir.LocalId, 2);
    default_elems[0] = 21; // param 2 — flipped
    default_elems[1] = 20; // param 1
    const default_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 20, .index = 1 } },
        .{ .param_get = .{ .dest = 21, .index = 2 } },
        .{ .tuple_init = .{ .dest = 22, .elements = default_elems } },
    });

    const cases = try arena.alloc(ir.ReturnCase, 1);
    cases[0] = .{
        .value = .{ .int = 1 },
        .body_instrs = case_1_body,
        .return_value = 12,
    };

    const callee_instrs = [_]ir.Instruction{
        .{ .switch_return = .{
            .scrutinee_param = 0,
            .cases = cases,
            .default_instrs = default_body,
            .default_result = 22,
        } },
    };

    var function = try buildTestFunction(
        arena,
        "advance_disagree",
        &callee_instrs,
        23,
        &[_]ir.ParamConvention{ .owned, .owned, .owned },
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[1].class);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[2].class);
    try testing.expect(sig.return_components.len >= 2);
    try testing.expectEqual(@as(?u8, null), sig.return_components[0]);
    try testing.expectEqual(@as(?u8, null), sig.return_components[1]);
}

test "uniqueness_fixpoint: if_expr arm result merges tuple_pending into dest (Phase 2.6.1)" {
    // Function shape:
    //   pub fn pick(b, p, q) -> {List(i64), List(i64)} {
    //     if b { {p, q} } else { {p, q} }
    //   }
    //
    // The if_expr's `dest` is the merge of the two arm results;
    // both arms produce a tuple_pending entry whose components map
    // (p, q). The merged dest should also be a tuple_pending entry,
    // and the outer `ret` should resolve it as PU with per-component
    // witnesses pointing at param slots 1 and 2.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const then_elems = try arena.alloc(ir.LocalId, 2);
    then_elems[0] = 10;
    then_elems[1] = 11;
    const then_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 10, .index = 1 } },
        .{ .param_get = .{ .dest = 11, .index = 2 } },
        .{ .tuple_init = .{ .dest = 12, .elements = then_elems } },
    });

    const else_elems = try arena.alloc(ir.LocalId, 2);
    else_elems[0] = 20;
    else_elems[1] = 21;
    const else_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 20, .index = 1 } },
        .{ .param_get = .{ .dest = 21, .index = 2 } },
        .{ .tuple_init = .{ .dest = 22, .elements = else_elems } },
    });

    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .if_expr = .{
            .dest = 1,
            .condition = 0,
            .then_instrs = then_body,
            .then_result = 12,
            .else_instrs = else_body,
            .else_result = 22,
        } },
        .{ .ret = .{ .value = 1 } },
    };

    var function = try buildTestFunction(
        arena,
        "pick",
        &callee_instrs,
        23,
        &[_]ir.ParamConvention{ .trivial, .owned, .owned },
        .owned,
    );
    function.id = 0;

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = function;
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);

    const sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[1].class);
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, sig.params[2].class);
    try testing.expect(sig.return_components.len >= 2);
    try testing.expectEqual(@as(?u8, 1), sig.return_components[0]);
    try testing.expectEqual(@as(?u8, 2), sig.return_components[1]);
}
