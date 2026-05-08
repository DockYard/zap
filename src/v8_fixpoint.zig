const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const v8_signature = @import("v8_signature.zig");

const ParamSig = v8_signature.ParamSig;
const UniquenessClass = v8_signature.UniquenessClass;
const FunctionSig = v8_signature.FunctionSig;
const ProgramSignatures = v8_signature.ProgramSignatures;

// ============================================================
// SCC fixpoint over the call graph for Phase 1.2 of the escape-
// analysis plan (research2 §1.2).
//
// Pipeline placement:
//
//     ... → arc_liveness                       (last-use side table)
//          → v8_fixpoint.computeSignatures     (THIS PASS — computes
//                                              `ProgramSignatures` from
//                                              every monomorphized
//                                              function body, iterated
//                                              over Tarjan SCCs)
//             → arc_param_convention           (consults signatures in
//                                              the borrowed-source veto)
//                → arc_ownership pipeline      (V8 rewrite + verifier)
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
//   - The verifier in `arc_verifier.zig::runV8` re-validates every
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
        try iterateScc(allocator, program, &name_to_id, &call_graph, scc, &signatures);
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

    while (worklist.pop()) |fid| {
        _ = in_worklist.remove(fid);
        const func = lookupFunction(program, fid) orelse continue;

        var changed = false;
        try analyzeFunctionBody(
            allocator,
            program,
            name_to_id,
            func,
            signatures,
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
    var walker = FlowWalker{
        .allocator = allocator,
        .program = program,
        .name_to_id = name_to_id,
        .function = function,
        .signatures = signatures,
        .accumulators = &accumulators,
        .carrier_of = &carrier_of,
    };
    for (function.body) |block| {
        try walker.walkStream(block.instructions);
    }

    // Merge accumulators into the program signature. A signature
    // upgrades (changed_out=true) when its class moved monotonically
    // from a lower lattice element to a strictly higher one.
    const sig_entry = signatures.by_function.getPtr(function.id) orelse return;
    for (sig_entry.params, accumulators.items) |*existing, observed| {
        const new_value = v8_signature.join(existing.*, observed.sig);
        if (new_value.class != existing.class or
            new_value.preserves_to_return_component != existing.preserves_to_return_component)
        {
            existing.* = new_value;
            changed_out.* = true;
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

const FlowWalker = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    function: *const ir.Function,
    signatures: *ProgramSignatures,
    accumulators: *std.ArrayListUnmanaged(ParamAccumulator),
    carrier_of: *std.AutoHashMapUnmanaged(ir.LocalId, u32),

    fn walkStream(
        self: *FlowWalker,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            try self.classifyAndPropagate(instr);
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(
        self: *FlowWalker,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            .if_expr => |ie| {
                try self.walkStream(ie.then_instrs);
                try self.walkStream(ie.else_instrs);
            },
            .case_block => |cb| {
                try self.walkStream(cb.pre_instrs);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                }
                try self.walkStream(cb.default_instrs);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try self.walkStream(c.body_instrs);
                try self.walkStream(sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try self.walkStream(c.body_instrs);
                try self.walkStream(sr.default_instrs);
            },
            .union_switch => |us| {
                for (us.cases) |c| try self.walkStream(c.body_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try self.walkStream(c.body_instrs);
            },
            .try_call_named => |tcn| {
                try self.walkStream(tcn.handler_instrs);
                try self.walkStream(tcn.success_instrs);
            },
            .guard_block => |gb| {
                try self.walkStream(gb.body);
            },
            .optional_dispatch => |od| {
                try self.walkStream(od.nil_instrs);
                try self.walkStream(od.struct_instrs);
            },
            else => {},
        }
    }

    fn classifyAndPropagate(self: *FlowWalker, instr: *const ir.Instruction) !void {
        switch (instr.*) {
            // -------------------------------------------------
            // Carrier-propagating alias forms.
            // -------------------------------------------------
            .local_get => |lg| try self.propagateCarrier(lg.dest, lg.source),
            .local_set => |ls| try self.propagateCarrier(ls.dest, ls.value),
            .move_value => |mv| try self.propagateCarrier(mv.dest, mv.source),
            .share_value => |sv| try self.propagateCarrier(sv.dest, sv.source),
            .copy_value => |cv| {
                // copy_value creates a new owner with a runtime retain.
                // The resulting cell has refcount > 1 — the parameter's
                // uniqueness is no longer preservable through this
                // path. Mark the source param as AL.
                if (self.carrier_of.get(cv.source)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
                _ = self.carrier_of.remove(cv.dest);
            },
            .borrow_value => |bv| try self.propagateCarrier(bv.dest, bv.source),

            // -------------------------------------------------
            // Aggregate inits — storing a parameter into an
            // aggregate cell aliases it (the aggregate holds a
            // permanent retain).
            // -------------------------------------------------
            .tuple_init => |ti| {
                for (ti.elements) |elem| {
                    if (self.carrier_of.get(elem)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                }
            },
            .list_init => |li| {
                for (li.elements) |elem| {
                    if (self.carrier_of.get(elem)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                }
            },
            .list_cons => |lc| {
                if (self.carrier_of.get(lc.head)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
                if (self.carrier_of.get(lc.tail)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    if (self.carrier_of.get(entry.key)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                    if (self.carrier_of.get(entry.value)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                }
            },
            .struct_init => |si| {
                for (si.fields) |f| {
                    if (self.carrier_of.get(f.value)) |slot| {
                        try self.upgradeParam(slot, ParamSig.aliasesOut());
                    }
                }
            },
            .union_init => |ui| {
                if (self.carrier_of.get(ui.value)) |slot| {
                    try self.upgradeParam(slot, ParamSig.aliasesOut());
                }
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
                }
            },

            // -------------------------------------------------
            // Calls — the meaty case. Each arg slot of the callee
            // contributes either CU (consumes uniqueness), PU
            // (preserves), or AL (aliases) to the caller's
            // parameter accumulator, depending on the callee's
            // own signature.
            // -------------------------------------------------
            .call_named => |cn| try self.classifyCall(cn.name, cn.args, cn.dest, false),
            .call_direct => |cd| try self.classifyCallToFunction(cd.function, cd.args, cd.dest, false),
            .try_call_named => |tcn| try self.classifyCall(tcn.name, tcn.args, tcn.dest, false),
            .tail_call => |tc| try self.classifyCall(tc.name, tc.args, 0, true),
            .call_builtin => |cb| try self.classifyBuiltinCall(cb.name, cb.args, cb.dest),
            .call_closure => |cc| {
                // Closure calls have unanalysable callees — every
                // arg that carries a parameter contributes ⊤.
                for (cc.args) |arg| {
                    if (self.carrier_of.get(arg)) |slot| {
                        try self.upgradeParam(slot, ParamSig.unknown());
                    }
                }
                _ = self.carrier_of.remove(cc.dest);
            },
            .call_dispatch => |cd| {
                for (cd.args) |arg| {
                    if (self.carrier_of.get(arg)) |slot| {
                        try self.upgradeParam(slot, ParamSig.unknown());
                    }
                }
                _ = self.carrier_of.remove(cd.dest);
            },

            // -------------------------------------------------
            // Returns — a parameter that flows directly into the
            // return position can preserve uniqueness through to
            // the caller. Treat as PU with a return-component
            // witness (Phase 2 will widen this for tuple returns).
            // -------------------------------------------------
            .ret => |r| {
                if (r.value) |val| {
                    if (self.carrier_of.get(val)) |slot| {
                        try self.upgradeParam(slot, ParamSig.preservesUniqueness(0));
                    }
                }
            },
            .cond_return => |cr| {
                if (cr.value) |val| {
                    if (self.carrier_of.get(val)) |slot| {
                        try self.upgradeParam(slot, ParamSig.preservesUniqueness(0));
                    }
                }
            },

            // -------------------------------------------------
            // Field/index reads — these don't move ownership of
            // the source. The dest is a borrow into the parent
            // aggregate, NOT a carrier of a parameter.
            // -------------------------------------------------
            .field_get,
            .index_get,
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

    /// Classify a builtin call. Owned-mutating builtins (Map.put,
    /// Vector.set, etc.) consume their receiver and return a
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
        // PU/CU flows the v8_fixpoint already classifies), the call
        // is a "borrow pass-through" and must not poison the caller's
        // carrier accumulator. The verifier (V8) remains the safety
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
        // For example: `VectorI64.get(vec, index)` (a Zap function
        // forwarding to a non-mutating runtime builtin) has slot 0
        // `.borrowed` and signature `top` post-cleanup. Without this
        // guard, every caller's V8 carrier accumulator gets polluted
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
                        try self.upgradeParam(carrier_slot, ParamSig.preservesUniqueness(0));
                    } else {
                        try self.upgradeParam(carrier_slot, ParamSig.consumesUniquely());
                    }
                },
                .preserves_uniqueness => {
                    // Callee threads uniqueness through to its return.
                    // Caller's parameter contributes PU; the dest
                    // carries the same parameter forward.
                    try self.upgradeParam(carrier_slot, ParamSig.preservesUniqueness(0));
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
                            // (the call's dest, even if a Vector,
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
        self.accumulators.items[slot].sig = v8_signature.join(existing, new_sig);
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

test "v8_fixpoint: empty program produces empty signatures" {
    var program = ir.Program{ .functions = &.{}, .type_defs = &.{}, .entry = null };
    var sigs = try computeSignatures(testing.allocator, &program);
    defer sigs.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), sigs.by_function.count());
}

test "v8_fixpoint: identity function returning its parameter is PU" {
    // Function: fn id(p :: VectorI64) -> VectorI64 { p }
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

test "v8_fixpoint: function storing param into list_cons is AL" {
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

test "v8_fixpoint: function calling owned-mutating builtin on param is PU" {
    // Body (sketch of `set_zero(arr) -> Vector.set(arr, 0, 0)`):
    //   [0] param_get   dest=0 index=0
    //   [1] const_int   dest=1 value=0
    //   [2] const_int   dest=2 value=0
    //   [3] move_value  dest=3 source=0
    //   [4] call_builtin dest=4 name="VectorI64.set" args=[3,1,2]
    //   [5] ret         value=4
    //
    // The receiver (arg 0 of Vector.set) is owned-mutating, so the
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
            .name = "VectorI64.set",
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

test "v8_fixpoint: function with no in-scope callers is conservative top when truly unobserved" {
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

test "v8_fixpoint: borrow-passthrough callee with top signature does not poison caller (Phase 1.8 item #5)" {
    // Two-function setup that exercises the borrow short-circuit
    // specifically. The callee's body has CONFLICTING flows that
    // join to `top` WITHIN the callee's SCC analysis (PU from
    // returning the param + AL from a tuple_init storing the param).
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
    //   callee(p :: VectorI64) -> VectorI64 {     # borrowed slot 0, top sig
    //     _ = {p, p}                                # AL flow
    //     p                                          # PU flow (ret)
    //   }
    //
    //   caller(v :: VectorI64) -> VectorI64 {      # owned slot 0
    //     _ = callee(v)                             # borrow-passthrough call
    //     Vector.set(v, 0, 0)                       # PU flow → caller slot 0 = PU
    //   }
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Function 0 (id=0): "borrow_aliaser" -- the borrowed callee whose
    // body has conflicting flows for slot 0:
    //   [0] param_get  dest=0  index=0
    //   [1] tuple_init dest=1  elements=[0]    -- AL flow on slot 0
    //   [2] ret         value=0                 -- PU flow on slot 0
    //
    // Slot 0 conv = .borrowed. Body flows: AL (tuple_init) ⊔ PU (ret) = top.
    // After SCC analysis (no cleanup needed — the body produces top
    // directly), the signature for slot 0 is `top` AND the slot conv
    // remains `.borrowed`.
    const tuple_elems_callee = try arena.alloc(ir.LocalId, 1);
    tuple_elems_callee[0] = 0;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems_callee } },
        .{ .ret = .{ .value = 0 } },
    };
    var callee_func = try buildTestFunction(
        arena,
        "borrow_aliaser",
        &callee_instrs,
        2,
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
    //   [6] call_builtin dest=6 name="VectorI64.set" args=[5,3,4]
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
            .name = "VectorI64.set",
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
    // through Vector.set). Without the short-circuit, the call to
    // `borrow_aliaser` (callee class top, callee slot 0 .borrowed)
    // would poison caller's slot 0 to top.
    const caller_sig = sigs.forFunction(1).?;
    try testing.expectEqual(UniquenessClass.preserves_uniqueness, caller_sig.params[0].class);
}

test "v8_fixpoint: aliases-out callee still poisons caller (sound check for borrow short-circuit)" {
    // Two-function setup where the callee genuinely escapes its
    // borrowed parameter into a tuple. The callee's signature is
    // `aliases`, NOT `top`. The borrow short-circuit MUST NOT bypass
    // the upgrade in this case — caller's carrier must be poisoned.
    //
    //   callee(p) -> {p}                  # aliases through tuple_init
    //   caller(v) -> callee(v)            # caller passes v
    //
    // Expected: caller's param 0 = AL (aliases), NOT PU.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Function 0: callee that aliases its param into a tuple.
    //   [0] param_get  dest=0 index=0
    //   [1] tuple_init dest=1 elements=[0]
    //   [2] ret         value=1
    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .ret = .{ .value = 1 } },
    };
    var callee_func = try buildTestFunction(
        arena,
        "tuple_wrap",
        &callee_instrs,
        2,
        &[_]ir.ParamConvention{.borrowed},
        .owned,
    );
    callee_func.id = 0;

    // Function 1: caller forwarding its param into the aliasing callee.
    //   [0] param_get  dest=0 index=0
    //   [1] call_named dest=1 name="tuple_wrap" args=[0]
    //   [2] ret         value=1
    const caller_call_args = try arena.alloc(ir.LocalId, 1);
    caller_call_args[0] = 0;
    const caller_call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    caller_call_arg_modes[0] = .share;
    const caller_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_named = .{
            .dest = 1,
            .name = "tuple_wrap",
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

    // Callee aliases its param via tuple_init: signature = AL.
    const callee_sig = sigs.forFunction(0).?;
    try testing.expectEqual(UniquenessClass.aliases, callee_sig.params[0].class);

    // Caller's param 0 must inherit AL — the short-circuit must NOT
    // bypass the aliases upgrade.
    const caller_sig = sigs.forFunction(1).?;
    try testing.expectEqual(UniquenessClass.aliases, caller_sig.params[0].class);
}
