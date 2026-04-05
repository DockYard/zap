const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");

// ============================================================
// Interprocedural Analysis (Research Plan Phase 3)
//
// Call graph construction, Tarjan SCC computation, and
// bottom-up function summary generation.
//
// The analysis computes per-function FunctionSummary values
// that describe how each parameter escapes. Callers use these
// summaries to avoid conservative assumptions about callees.
//
// Pipeline:
//   1. Build call graph from IR program
//   2. Compute SCCs via Tarjan's algorithm
//   3. Process SCCs in reverse topological order (leaves first)
//      - Non-recursive: single-pass analysis
//      - Recursive SCCs: iterate to fixpoint
// ============================================================

// ============================================================
// Section 1: Call Graph
// ============================================================

/// Directed call graph built from an ir.Program.
///
/// Tracks caller -> callee edges (including through closures)
/// and which function creates which closures.
pub const CallGraph = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,

    /// Adjacency lists: function -> list of callees (as owned slices)
    callees: std.AutoArrayHashMap(ir.FunctionId, FuncIdList),

    /// Reverse adjacency lists: function -> list of callers (as owned slices)
    callers: std.AutoArrayHashMap(ir.FunctionId, FuncIdList),

    /// Closure creation tracking: closure function -> creating function
    closure_creators: std.AutoArrayHashMap(ir.FunctionId, ir.FunctionId),

    /// Name-to-function-id lookup for resolving call_named
    name_to_id: std.StringHashMap(ir.FunctionId),

    /// All function IDs in the program (owned slice)
    all_function_ids: []ir.FunctionId,

    const FuncIdList = struct {
        items: []ir.FunctionId,
        len: usize,
        capacity: usize,
        alloc: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) FuncIdList {
            return .{ .items = &.{}, .len = 0, .capacity = 0, .alloc = allocator };
        }

        fn append(self: *FuncIdList, value: ir.FunctionId) !void {
            if (self.len >= self.capacity) {
                const new_cap = if (self.capacity == 0) 4 else self.capacity * 2;
                const new_items = try self.alloc.alloc(ir.FunctionId, new_cap);
                if (self.len > 0) {
                    @memcpy(new_items[0..self.len], self.items[0..self.len]);
                    self.alloc.free(self.items[0..self.capacity]);
                }
                self.items = new_items.ptr[0..new_cap];
                self.capacity = new_cap;
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        fn slice(self: *const FuncIdList) []const ir.FunctionId {
            return self.items[0..self.len];
        }

        fn deinit(self: *FuncIdList) void {
            if (self.capacity > 0) {
                self.alloc.free(self.items[0..self.capacity]);
            }
        }
    };

    pub fn build(allocator: std.mem.Allocator, program: *const ir.Program) !CallGraph {
        // Build all_function_ids
        const all_ids = try allocator.alloc(ir.FunctionId, program.functions.len);
        for (program.functions, 0..) |func, i| {
            all_ids[i] = func.id;
        }

        var graph = CallGraph{
            .allocator = allocator,
            .program = program,
            .callees = std.AutoArrayHashMap(ir.FunctionId, FuncIdList).init(allocator),
            .callers = std.AutoArrayHashMap(ir.FunctionId, FuncIdList).init(allocator),
            .closure_creators = std.AutoArrayHashMap(ir.FunctionId, ir.FunctionId).init(allocator),
            .name_to_id = std.StringHashMap(ir.FunctionId).init(allocator),
            .all_function_ids = all_ids,
        };

        // Build name lookup
        for (program.functions) |func| {
            try graph.name_to_id.put(func.name, func.id);
        }

        // Build edges
        for (program.functions) |func| {
            try graph.scanFunction(func);
        }

        return graph;
    }

    fn scanFunction(self: *CallGraph, func: ir.Function) !void {
        for (func.body) |block| {
            try self.scanInstructions(func.id, block.instructions);
        }
    }

    fn scanInstructions(self: *CallGraph, caller: ir.FunctionId, instructions: []const ir.Instruction) !void {
        for (instructions) |instr| {
            switch (instr) {
                .call_direct => |cd| {
                    try self.addEdge(caller, cd.function);
                },
                .call_named => |cn| {
                    if (self.name_to_id.get(cn.name)) |callee_id| {
                        try self.addEdge(caller, callee_id);
                    }
                },
                .make_closure => |mc| {
                    try self.closure_creators.put(mc.function, caller);
                    try self.addEdge(caller, mc.function);
                },
                .tail_call => |tc| {
                    if (self.name_to_id.get(tc.name)) |callee_id| {
                        try self.addEdge(caller, callee_id);
                    }
                },
                // Walk into nested instruction lists
                .if_expr => |ie| {
                    try self.scanInstructions(caller, ie.then_instrs);
                    try self.scanInstructions(caller, ie.else_instrs);
                },
                .case_block => |cb| {
                    try self.scanInstructions(caller, cb.pre_instrs);
                    for (cb.arms) |arm| {
                        try self.scanInstructions(caller, arm.cond_instrs);
                        try self.scanInstructions(caller, arm.body_instrs);
                    }
                    try self.scanInstructions(caller, cb.default_instrs);
                },
                .guard_block => |gb| {
                    try self.scanInstructions(caller, gb.body);
                },
                .switch_literal => |sl| {
                    for (sl.cases) |c| {
                        try self.scanInstructions(caller, c.body_instrs);
                    }
                    try self.scanInstructions(caller, sl.default_instrs);
                },
                .switch_return => |sr| {
                    for (sr.cases) |c| {
                        try self.scanInstructions(caller, c.body_instrs);
                    }
                    try self.scanInstructions(caller, sr.default_instrs);
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |c| {
                        try self.scanInstructions(caller, c.body_instrs);
                    }
                },
                .union_switch => |us| {
                    for (us.cases) |c| {
                        try self.scanInstructions(caller, c.body_instrs);
                    }
                },
                else => {},
            }
        }
    }

    fn addEdge(self: *CallGraph, caller: ir.FunctionId, callee: ir.FunctionId) !void {
        // Add to callees
        const callee_result = try self.callees.getOrPut(caller);
        if (!callee_result.found_existing) {
            callee_result.value_ptr.* = FuncIdList.init(self.allocator);
        }
        // Avoid duplicate edges
        for (callee_result.value_ptr.slice()) |existing| {
            if (existing == callee) return;
        }
        try callee_result.value_ptr.append(callee);

        // Add to callers
        const caller_result = try self.callers.getOrPut(callee);
        if (!caller_result.found_existing) {
            caller_result.value_ptr.* = FuncIdList.init(self.allocator);
        }
        for (caller_result.value_ptr.slice()) |existing| {
            if (existing == caller) return;
        }
        try caller_result.value_ptr.append(caller);
    }

    pub fn getCallees(self: *const CallGraph, func: ir.FunctionId) []const ir.FunctionId {
        if (self.callees.get(func)) |list| {
            return list.items[0..list.len];
        }
        return &.{};
    }

    pub fn getCallers(self: *const CallGraph, func: ir.FunctionId) []const ir.FunctionId {
        if (self.callers.get(func)) |list| {
            return list.items[0..list.len];
        }
        return &.{};
    }

    pub fn getCreator(self: *const CallGraph, closure_func: ir.FunctionId) ?ir.FunctionId {
        return self.closure_creators.get(closure_func);
    }

    pub fn functionCount(self: *const CallGraph) usize {
        return self.all_function_ids.len;
    }

    pub fn deinit(self: *CallGraph) void {
        var callees_iter = self.callees.iterator();
        while (callees_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.callees.deinit();

        var callers_iter = self.callers.iterator();
        while (callers_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.callers.deinit();

        self.closure_creators.deinit();
        self.name_to_id.deinit();
        self.allocator.free(self.all_function_ids);
    }
};

// ============================================================
// Section 2: Tarjan's SCC Algorithm
// ============================================================

/// Result of SCC computation. SCCs are in reverse topological order:
/// the first SCC has no outgoing edges to later SCCs (leaf functions).
pub const SccResult = struct {
    allocator: std.mem.Allocator,
    /// SCCs in reverse topological order (process first to last).
    sccs: []const []const ir.FunctionId,

    pub fn deinit(self: *SccResult) void {
        for (self.sccs) |scc| {
            self.allocator.free(scc);
        }
        self.allocator.free(self.sccs);
    }
};

/// Tarjan SCC state for a single node.
const TarjanNode = struct {
    index: ?u32 = null,
    lowlink: u32 = 0,
    on_stack: bool = false,
};

/// Compute strongly connected components of the call graph using
/// Tarjan's algorithm. Returns SCCs in reverse topological order.
pub fn computeSccs(allocator: std.mem.Allocator, graph: *const CallGraph) !SccResult {
    var state = TarjanState{
        .allocator = allocator,
        .graph = graph,
        .nodes = std.AutoArrayHashMap(ir.FunctionId, TarjanNode).init(allocator),
        .stack_items = try allocator.alloc(ir.FunctionId, graph.all_function_ids.len),
        .stack_len = 0,
        .scc_list = try allocator.alloc([]const ir.FunctionId, graph.all_function_ids.len),
        .scc_count = 0,
        .index_counter = 0,
    };
    defer state.nodes.deinit();
    defer allocator.free(state.stack_items);

    // Initialize all nodes
    for (graph.all_function_ids) |func_id| {
        try state.nodes.put(func_id, .{});
    }

    // Visit all unvisited nodes
    for (graph.all_function_ids) |func_id| {
        if (state.nodes.get(func_id).?.index == null) {
            try state.strongConnect(func_id);
        }
    }

    // Trim scc_list to actual count
    const result_sccs = try allocator.alloc([]const ir.FunctionId, state.scc_count);
    @memcpy(result_sccs, state.scc_list[0..state.scc_count]);
    allocator.free(state.scc_list);

    return .{
        .allocator = allocator,
        .sccs = result_sccs,
    };
}

const TarjanState = struct {
    allocator: std.mem.Allocator,
    graph: *const CallGraph,
    nodes: std.AutoArrayHashMap(ir.FunctionId, TarjanNode),
    stack_items: []ir.FunctionId,
    stack_len: usize,
    scc_list: [][]const ir.FunctionId,
    scc_count: usize,
    index_counter: u32,

    fn strongConnect(self: *TarjanState, v: ir.FunctionId) !void {
        const v_node = self.nodes.getPtr(v).?;
        v_node.index = self.index_counter;
        v_node.lowlink = self.index_counter;
        self.index_counter += 1;
        self.stack_items[self.stack_len] = v;
        self.stack_len += 1;
        v_node.on_stack = true;

        // Consider successors
        const successors = self.graph.getCallees(v);
        for (successors) |w| {
            if (self.nodes.getPtr(w)) |w_node| {
                if (w_node.index == null) {
                    try self.strongConnect(w);
                    const v_node_after = self.nodes.getPtr(v).?;
                    const w_node_after = self.nodes.getPtr(w).?;
                    v_node_after.lowlink = @min(v_node_after.lowlink, w_node_after.lowlink);
                } else if (w_node.on_stack) {
                    const v_node_after = self.nodes.getPtr(v).?;
                    v_node_after.lowlink = @min(v_node_after.lowlink, w_node.index.?);
                }
            }
        }

        // If v is a root, pop the SCC
        const v_final = self.nodes.getPtr(v).?;
        if (v_final.lowlink == v_final.index.?) {
            // Count how many nodes in this SCC
            var count: usize = 0;
            var i = self.stack_len;
            while (i > 0) {
                i -= 1;
                count += 1;
                if (self.stack_items[i] == v) break;
            }

            const scc = try self.allocator.alloc(ir.FunctionId, count);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                self.stack_len -= 1;
                const w = self.stack_items[self.stack_len];
                self.nodes.getPtr(w).?.on_stack = false;
                scc[idx] = w;
            }
            self.scc_list[self.scc_count] = scc;
            self.scc_count += 1;
        }
    }
};

// ============================================================
// Section 3: Interprocedural Analyzer
// ============================================================

/// Computes FunctionSummary for every function in an ir.Program
/// by bottom-up analysis over the SCC-ordered call graph.
pub const InterproceduralAnalyzer = struct {
    allocator: std.mem.Allocator,
    call_graph: CallGraph,
    summaries: std.AutoArrayHashMap(ir.FunctionId, lattice.FunctionSummary),
    program: *const ir.Program,

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program) !InterproceduralAnalyzer {
        return .{
            .allocator = allocator,
            .call_graph = try CallGraph.build(allocator, program),
            .summaries = std.AutoArrayHashMap(ir.FunctionId, lattice.FunctionSummary).init(allocator),
            .program = program,
        };
    }

    pub fn deinit(self: *InterproceduralAnalyzer) void {
        var iter = self.summaries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.param_summaries);
            self.allocator.free(entry.value_ptr.param_lambda_sets);
            if (entry.value_ptr.return_summary.param_sources.len > 0) {
                self.allocator.free(entry.value_ptr.return_summary.param_sources);
            }
        }
        self.summaries.deinit();
        self.call_graph.deinit();
    }

    /// Run the full interprocedural analysis.
    /// After this returns, getSummary() will return summaries for all functions.
    pub fn analyze(self: *InterproceduralAnalyzer) !void {
        var scc_result = try computeSccs(self.allocator, &self.call_graph);
        defer scc_result.deinit();

        for (scc_result.sccs) |scc| {
            if (scc.len == 1) {
                const func_id = scc[0];
                const is_self_recursive = blk: {
                    for (self.call_graph.getCallees(func_id)) |callee| {
                        if (callee == func_id) break :blk true;
                    }
                    break :blk false;
                };

                if (is_self_recursive) {
                    try self.analyzeSccFixpoint(scc);
                } else {
                    const summary = try self.analyzeFunction(func_id, false);
                    try self.summaries.put(func_id, summary);
                }
            } else {
                // Multi-function SCC: mutual recursion → may_diverge.
                try self.analyzeSccFixpoint(scc);
            }
        }
    }

    /// Get the computed summary for a function, or null if not yet analyzed.
    pub fn getSummary(self: *const InterproceduralAnalyzer, func: ir.FunctionId) ?lattice.FunctionSummary {
        return self.summaries.get(func);
    }

    /// Retrieve the function definition by ID.
    fn getFunction(self: *const InterproceduralAnalyzer, func_id: ir.FunctionId) ?ir.Function {
        for (self.program.functions) |f| {
            if (f.id == func_id) return f;
        }
        return null;
    }

    /// Analyze a single function to produce its summary.
    /// `is_recursive` indicates whether this function is in a non-trivial SCC.
    fn analyzeFunction(self: *InterproceduralAnalyzer, func_id: ir.FunctionId, is_recursive: bool) !lattice.FunctionSummary {
        const func = self.getFunction(func_id) orelse {
            return try lattice.FunctionSummary.conservative(0, self.allocator);
        };

        const num_params = func.params.len;

        const param_summaries = try self.allocator.alloc(lattice.ParamSummary, num_params);
        for (param_summaries) |*ps| {
            ps.* = lattice.ParamSummary.safe();
        }

        var aliases = std.AutoArrayHashMap(ir.LocalId, ParamSet).init(self.allocator);
        defer aliases.deinit();

        var fresh_locals = std.AutoArrayHashMap(ir.LocalId, void).init(self.allocator);
        defer fresh_locals.deinit();

        var return_sources = ReturnSourceCollector.init(self.allocator);
        defer return_sources.deinit();

        // Track dereference depth per local (for escape_deref_depth computation).
        var deref_depths = std.AutoArrayHashMap(ir.LocalId, i8).init(self.allocator);
        defer deref_depths.deinit();

        // Initialize params at deref depth 0.
        for (0..num_params) |i| {
            const param_local: ir.LocalId = @intCast(i);
            try deref_depths.put(param_local, 0);
        }

        // Walk all instructions
        for (func.body) |block| {
            try self.analyzeInstructions(
                block.instructions,
                num_params,
                param_summaries,
                &aliases,
                &fresh_locals,
                &return_sources,
            );
            // Also track deref depths through field_get chains.
            self.trackDerefDepths(block.instructions, &aliases, &deref_depths, num_params, param_summaries);
        }

        // Infer read-only: a param is read_only if it doesn't escape at all
        for (param_summaries) |*ps| {
            if (!ps.escapes_to_heap and !ps.returned and !ps.passed_to_unknown) {
                ps.read_only = true;
            } else {
                ps.read_only = false;
            }
        }

        // Compute may_diverge: recursive functions may diverge.
        // Also check if the function has no ret instruction (infinite loop).
        const has_ret = blk: {
            for (func.body) |block| {
                if (hasRetInstruction(block.instructions)) break :blk true;
            }
            break :blk false;
        };
        const may_diverge = is_recursive or !has_ret;

        const return_summary = lattice.ReturnSummary{
            .param_sources = try return_sources.toOwnedSlice(),
            .fresh_alloc = return_sources.has_fresh,
        };

        const lambda_sets = try self.allocator.alloc(lattice.LambdaSet, num_params);
        @memset(lambda_sets, lattice.LambdaSet.empty());

        return .{
            .param_summaries = param_summaries,
            .return_summary = return_summary,
            .may_diverge = may_diverge,
            .param_lambda_sets = lambda_sets,
        };
    }

    /// Check if an instruction list contains a ret instruction (possibly nested).
    fn hasRetInstruction(instrs: []const ir.Instruction) bool {
        for (instrs) |instr| {
            switch (instr) {
                .ret => return true,
                .cond_return => return true,
                .if_expr => |ie| {
                    if (hasRetInstruction(ie.then_instrs)) return true;
                    if (hasRetInstruction(ie.else_instrs)) return true;
                },
                .case_block => |cb| {
                    if (hasRetInstruction(cb.pre_instrs)) return true;
                    for (cb.arms) |arm| {
                        if (hasRetInstruction(arm.body_instrs)) return true;
                    }
                    if (hasRetInstruction(cb.default_instrs)) return true;
                },
                .switch_return, .union_switch_return, .union_switch => return true,
                else => {},
            }
        }
        return false;
    }

    /// Track dereference depths through field_get operations.
    /// If a param-derived value is field_get'd, the loaded value has depth+1.
    /// If that loaded value escapes, set escape_deref_depth on the param.
    fn trackDerefDepths(
        self: *InterproceduralAnalyzer,
        instrs: []const ir.Instruction,
        aliases: *const std.AutoArrayHashMap(ir.LocalId, ParamSet),
        deref_depths: *std.AutoArrayHashMap(ir.LocalId, i8),
        num_params: usize,
        param_summaries: []lattice.ParamSummary,
    ) void {
        _ = self;
        for (instrs) |instr| {
            switch (instr) {
                .field_get => |fg| {
                    // If source is param-derived, loaded value has depth+1.
                    if (deref_depths.get(fg.object)) |src_depth| {
                        deref_depths.put(fg.dest, src_depth + 1) catch {};
                    } else if (aliases.get(fg.object)) |param_set| {
                        // Source is an alias of params — start at depth 1.
                        _ = param_set;
                        deref_depths.put(fg.dest, 1) catch {};
                    }
                },
                .ret => |r| {
                    if (r.value) |v| {
                        if (deref_depths.get(v)) |depth| {
                            // This local (at some deref depth) is returned.
                            // Find which params it derives from and set escape_deref_depth.
                            if (aliases.get(v)) |param_set| {
                                for (0..num_params) |i| {
                                    if (param_set.contains(@intCast(i))) {
                                        param_summaries[i].escape_deref_depth = @max(param_summaries[i].escape_deref_depth, depth);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Analyze a list of instructions, updating parameter summaries.
    fn analyzeInstructions(
        self: *InterproceduralAnalyzer,
        instructions: []const ir.Instruction,
        num_params: usize,
        param_summaries: []lattice.ParamSummary,
        aliases: *std.AutoArrayHashMap(ir.LocalId, ParamSet),
        fresh_locals: *std.AutoArrayHashMap(ir.LocalId, void),
        return_sources: *ReturnSourceCollector,
    ) !void {
        for (instructions) |instr| {
            switch (instr) {
                .param_get => |pg| {
                    if (pg.index < num_params) {
                        try aliases.put(pg.dest, ParamSet.singleton(pg.index));
                    }
                },

                .local_get => |lg| {
                    if (aliases.get(lg.source)) |param_set| {
                        try aliases.put(lg.dest, param_set);
                    }
                },

                .local_set => |ls| {
                    if (aliases.get(ls.value)) |param_set| {
                        try aliases.put(ls.dest, param_set);
                    }
                },

                .struct_init => |si| {
                    try fresh_locals.put(si.dest, {});
                    for (si.fields) |field| {
                        markEscapeToHeap(aliases, field.value, param_summaries);
                    }
                },

                .tuple_init => |ti| {
                    try fresh_locals.put(ti.dest, {});
                    for (ti.elements) |elem| {
                        markEscapeToHeap(aliases, elem, param_summaries);
                    }
                },

                .list_init => |li| {
                    try fresh_locals.put(li.dest, {});
                    for (li.elements) |elem| {
                        markEscapeToHeap(aliases, elem, param_summaries);
                    }
                },

                .map_init => |mi| {
                    try fresh_locals.put(mi.dest, {});
                    for (mi.entries) |entry| {
                        markEscapeToHeap(aliases, entry.key, param_summaries);
                        markEscapeToHeap(aliases, entry.value, param_summaries);
                    }
                },

                .union_init => |ui| {
                    try fresh_locals.put(ui.dest, {});
                    markEscapeToHeap(aliases, ui.value, param_summaries);
                },

                .field_set => |fs| {
                    markEscapeToHeap(aliases, fs.value, param_summaries);
                },

                .field_get => |fg| {
                    // Reading from an object: the result is a derived value.
                    // We don't propagate the param alias through field access.
                    if (fresh_locals.get(fg.object) != null) {
                        try fresh_locals.put(fg.dest, {});
                    }
                },

                // Constants
                .const_int => |ci| try fresh_locals.put(ci.dest, {}),
                .const_float => |cf| try fresh_locals.put(cf.dest, {}),
                .const_string => |cs| try fresh_locals.put(cs.dest, {}),
                .const_bool => |cb| try fresh_locals.put(cb.dest, {}),
                .const_atom => |ca| try fresh_locals.put(ca.dest, {}),
                .const_nil => |dest| try fresh_locals.put(dest, {}),

                // Arithmetic produces fresh values
                .binary_op => |bo| try fresh_locals.put(bo.dest, {}),
                .unary_op => |uo| try fresh_locals.put(uo.dest, {}),

                // Calls
                .call_direct => |cd| {
                    self.analyzeCallArgsDirect(
                        cd.args,
                        cd.function,
                        param_summaries,
                        aliases,
                    );
                    if (self.summaries.get(cd.function)) |callee_summary| {
                        if (callee_summary.return_summary.fresh_alloc) {
                            try fresh_locals.put(cd.dest, {});
                        } else {
                            for (callee_summary.return_summary.param_sources) |src_idx| {
                                if (src_idx < cd.args.len) {
                                    if (aliases.get(cd.args[src_idx])) |param_set| {
                                        try aliases.put(cd.dest, param_set);
                                    }
                                }
                            }
                        }
                    } else {
                        try fresh_locals.put(cd.dest, {});
                    }
                },

                .call_named => |cn| {
                    const callee_id = self.call_graph.name_to_id.get(cn.name);
                    if (callee_id) |cid| {
                        self.analyzeCallArgsDirect(
                            cn.args,
                            cid,
                            param_summaries,
                            aliases,
                        );
                        if (self.summaries.get(cid)) |callee_summary| {
                            if (callee_summary.return_summary.fresh_alloc) {
                                try fresh_locals.put(cn.dest, {});
                            } else {
                                for (callee_summary.return_summary.param_sources) |src_idx| {
                                    if (src_idx < cn.args.len) {
                                        if (aliases.get(cn.args[src_idx])) |param_set| {
                                            try aliases.put(cn.dest, param_set);
                                        }
                                    }
                                }
                            }
                        } else {
                            try fresh_locals.put(cn.dest, {});
                        }
                    } else {
                        markArgsPassedToUnknown(cn.args, param_summaries, aliases);
                        try fresh_locals.put(cn.dest, {});
                    }
                },

                .try_call_named => |tcn| {
                    const callee_id = self.call_graph.name_to_id.get(tcn.name);
                    if (callee_id) |cid| {
                        self.analyzeCallArgsDirect(
                            tcn.args,
                            cid,
                            param_summaries,
                            aliases,
                        );
                        if (self.summaries.get(cid)) |callee_summary| {
                            if (callee_summary.return_summary.fresh_alloc) {
                                try fresh_locals.put(tcn.dest, {});
                            } else {
                                for (callee_summary.return_summary.param_sources) |src_idx| {
                                    if (src_idx < tcn.args.len) {
                                        if (aliases.get(tcn.args[src_idx])) |param_set| {
                                            try aliases.put(tcn.dest, param_set);
                                        }
                                    }
                                }
                            }
                        } else {
                            try fresh_locals.put(tcn.dest, {});
                        }
                    } else {
                        markArgsPassedToUnknown(tcn.args, param_summaries, aliases);
                        try fresh_locals.put(tcn.dest, {});
                    }
                },

                .call_closure => |cc| {
                    markArgsPassedToUnknown(cc.args, param_summaries, aliases);
                    try fresh_locals.put(cc.dest, {});
                },

                .call_builtin => |cbi| {
                    markArgsPassedToUnknown(cbi.args, param_summaries, aliases);
                    try fresh_locals.put(cbi.dest, {});
                },

                .call_dispatch => |cdi| {
                    markArgsPassedToUnknown(cdi.args, param_summaries, aliases);
                    try fresh_locals.put(cdi.dest, {});
                },

                .tail_call => |tc| {
                    // Tail calls: args become return values transitively
                    for (tc.args) |arg| {
                        if (aliases.get(arg)) |param_set| {
                            var iter = param_set.iterator();
                            while (iter.next()) |idx| {
                                if (idx < param_summaries.len) {
                                    param_summaries[idx].returned = true;
                                }
                            }
                        }
                    }
                },

                .make_closure => |mc| {
                    for (mc.captures) |cap| {
                        markEscapeToHeap(aliases, cap, param_summaries);
                    }
                    try fresh_locals.put(mc.dest, {});
                },

                .ret => |r| {
                    if (r.value) |val| {
                        try self.recordReturnValue(val, param_summaries, aliases, fresh_locals, return_sources);
                    }
                },

                .cond_return => |cr| {
                    if (cr.value) |val| {
                        try self.recordReturnValue(val, param_summaries, aliases, fresh_locals, return_sources);
                    }
                },

                .phi => |p| {
                    var merged = ParamSet.empty();
                    var any_fresh = false;
                    for (p.sources) |src| {
                        if (aliases.get(src.value)) |param_set| {
                            merged = merged.merge(param_set);
                        }
                        if (fresh_locals.get(src.value) != null) {
                            any_fresh = true;
                        }
                    }
                    if (!merged.isEmpty()) {
                        try aliases.put(p.dest, merged);
                    }
                    if (any_fresh) {
                        try fresh_locals.put(p.dest, {});
                    }
                },

                .optional_unwrap => |ou| {
                    if (aliases.get(ou.source)) |param_set| {
                        try aliases.put(ou.dest, param_set);
                    }
                },

                .error_catch => |ec| {
                    // dest may come from source or catch_value; merge both alias sets.
                    var merged = ParamSet.empty();
                    if (aliases.get(ec.source)) |ps| merged = merged.merge(ps);
                    if (aliases.get(ec.catch_value)) |ps| merged = merged.merge(ps);
                    if (!merged.isEmpty()) {
                        try aliases.put(ec.dest, merged);
                    } else if (fresh_locals.get(ec.source) != null or fresh_locals.get(ec.catch_value) != null) {
                        try fresh_locals.put(ec.dest, {});
                    }
                },

                .index_get => |ig| {
                    if (aliases.get(ig.object)) |param_set| {
                        try aliases.put(ig.dest, param_set);
                    }
                },

                .list_get => |lg| {
                    if (aliases.get(lg.list)) |param_set| {
                        try aliases.put(lg.dest, param_set);
                    }
                },

                // Nested control flow
                .if_expr => |ie| {
                    try self.analyzeInstructions(ie.then_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    try self.analyzeInstructions(ie.else_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    // Merge result aliases from both branches
                    var merged = ParamSet.empty();
                    var any_fresh = false;
                    if (ie.then_result) |tr| {
                        if (aliases.get(tr)) |ps| merged = merged.merge(ps);
                        if (fresh_locals.get(tr) != null) any_fresh = true;
                    }
                    if (ie.else_result) |er| {
                        if (aliases.get(er)) |ps| merged = merged.merge(ps);
                        if (fresh_locals.get(er) != null) any_fresh = true;
                    }
                    if (!merged.isEmpty()) try aliases.put(ie.dest, merged);
                    if (any_fresh) try fresh_locals.put(ie.dest, {});
                },

                .case_block => |cb| {
                    try self.analyzeInstructions(cb.pre_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    var merged = ParamSet.empty();
                    var any_fresh = false;
                    for (cb.arms) |arm| {
                        try self.analyzeInstructions(arm.cond_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        try self.analyzeInstructions(arm.body_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        if (arm.result) |res| {
                            if (aliases.get(res)) |ps| merged = merged.merge(ps);
                            if (fresh_locals.get(res) != null) any_fresh = true;
                        }
                    }
                    try self.analyzeInstructions(cb.default_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    if (cb.default_result) |dr| {
                        if (aliases.get(dr)) |ps| merged = merged.merge(ps);
                        if (fresh_locals.get(dr) != null) any_fresh = true;
                    }
                    if (!merged.isEmpty()) try aliases.put(cb.dest, merged);
                    if (any_fresh) try fresh_locals.put(cb.dest, {});
                },

                .guard_block => |gb| {
                    try self.analyzeInstructions(gb.body, num_params, param_summaries, aliases, fresh_locals, return_sources);
                },

                .switch_literal => |sl| {
                    var merged = ParamSet.empty();
                    var any_fresh = false;
                    for (sl.cases) |c| {
                        try self.analyzeInstructions(c.body_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        if (c.result) |res| {
                            if (aliases.get(res)) |ps| merged = merged.merge(ps);
                            if (fresh_locals.get(res) != null) any_fresh = true;
                        }
                    }
                    try self.analyzeInstructions(sl.default_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    if (sl.default_result) |dr| {
                        if (aliases.get(dr)) |ps| merged = merged.merge(ps);
                        if (fresh_locals.get(dr) != null) any_fresh = true;
                    }
                    if (!merged.isEmpty()) try aliases.put(sl.dest, merged);
                    if (any_fresh) try fresh_locals.put(sl.dest, {});
                },

                .switch_return => |sr| {
                    for (sr.cases) |c| {
                        try self.analyzeInstructions(c.body_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        if (c.return_value) |rv| {
                            try self.recordReturnValue(rv, param_summaries, aliases, fresh_locals, return_sources);
                        }
                    }
                    try self.analyzeInstructions(sr.default_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                    if (sr.default_result) |dr| {
                        try self.recordReturnValue(dr, param_summaries, aliases, fresh_locals, return_sources);
                    }
                },

                .union_switch_return => |usr| {
                    for (usr.cases) |c| {
                        try self.analyzeInstructions(c.body_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        if (c.return_value) |rv| {
                            try self.recordReturnValue(rv, param_summaries, aliases, fresh_locals, return_sources);
                        }
                    }
                },

                .union_switch => |us| {
                    for (us.cases) |c| {
                        try self.analyzeInstructions(c.body_instrs, num_params, param_summaries, aliases, fresh_locals, return_sources);
                        if (c.return_value) |rv| {
                            try self.recordReturnValue(rv, param_summaries, aliases, fresh_locals, return_sources);
                        }
                    }
                },

                // Value movement — propagate aliases
                .move_value => |mv| {
                    if (aliases.get(mv.source)) |param_set| {
                        try aliases.put(mv.dest, param_set);
                    } else {
                        try fresh_locals.put(mv.dest, {});
                    }
                },
                .share_value => |sv| {
                    if (aliases.get(sv.source)) |param_set| {
                        try aliases.put(sv.dest, param_set);
                    } else {
                        try fresh_locals.put(sv.dest, {});
                    }
                },

                // ARC operations
                .retain, .release => {},

                // Perceus: record def/use.
                .reset => |r| {
                    try fresh_locals.put(r.dest, {});
                },
                .reuse_alloc => |ra| {
                    try fresh_locals.put(ra.dest, {});
                },

                .capture_get => |cg| try fresh_locals.put(cg.dest, {}),
                .enum_literal => |el| try fresh_locals.put(el.dest, {}),
                .match_atom => |ma| try fresh_locals.put(ma.dest, {}),
                .match_int => |mi| try fresh_locals.put(mi.dest, {}),
                .match_float => |mf| try fresh_locals.put(mf.dest, {}),
                .match_string => |ms| try fresh_locals.put(ms.dest, {}),
                .match_type => |mt| try fresh_locals.put(mt.dest, {}),
                .bin_len_check => |blc| try fresh_locals.put(blc.dest, {}),
                .bin_read_int => |bri| try fresh_locals.put(bri.dest, {}),
                .bin_read_float => |brf| try fresh_locals.put(brf.dest, {}),
                .bin_slice => |bs| try fresh_locals.put(bs.dest, {}),
                .bin_read_utf8 => |bru| {
                    try fresh_locals.put(bru.dest_codepoint, {});
                    try fresh_locals.put(bru.dest_len, {});
                },
                .bin_match_prefix => |bmp| try fresh_locals.put(bmp.dest, {}),
                .list_len_check => |llc| try fresh_locals.put(llc.dest, {}),
                .switch_tag => {},
                .branch, .cond_branch, .jump, .case_break, .match_fail, .match_error_return => {},
            }
        }
    }

    /// Record a return value: mark param summaries and track return sources.
    fn recordReturnValue(
        self: *InterproceduralAnalyzer,
        val: ir.LocalId,
        param_summaries: []lattice.ParamSummary,
        aliases: *std.AutoArrayHashMap(ir.LocalId, ParamSet),
        fresh_locals: *std.AutoArrayHashMap(ir.LocalId, void),
        return_sources: *ReturnSourceCollector,
    ) !void {
        _ = self;
        if (aliases.get(val)) |param_set| {
            var iter = param_set.iterator();
            while (iter.next()) |idx| {
                if (idx < param_summaries.len) {
                    param_summaries[idx].returned = true;
                    try return_sources.addSource(idx);
                }
            }
        } else if (fresh_locals.get(val) != null) {
            return_sources.has_fresh = true;
        }
    }

    /// Analyze call arguments using the callee's summary.
    fn analyzeCallArgsDirect(
        self: *InterproceduralAnalyzer,
        args: []const ir.LocalId,
        callee_id: ir.FunctionId,
        param_summaries: []lattice.ParamSummary,
        aliases: *std.AutoArrayHashMap(ir.LocalId, ParamSet),
    ) void {
        if (self.summaries.get(callee_id)) |callee_summary| {
            for (args, 0..) |arg, arg_idx| {
                if (aliases.get(arg)) |param_set| {
                    var iter = param_set.iterator();
                    while (iter.next()) |our_param_idx| {
                        if (our_param_idx < param_summaries.len) {
                            if (arg_idx < callee_summary.param_summaries.len) {
                                const callee_param = callee_summary.param_summaries[arg_idx];
                                if (callee_param.escapes_to_heap) {
                                    param_summaries[our_param_idx].escapes_to_heap = true;
                                }
                                if (callee_param.returned) {
                                    param_summaries[our_param_idx].returned = true;
                                }
                                if (callee_param.passed_to_unknown) {
                                    param_summaries[our_param_idx].passed_to_unknown = true;
                                }
                            } else {
                                param_summaries[our_param_idx].passed_to_unknown = true;
                            }
                        }
                    }
                }
            }
        } else {
            markArgsPassedToUnknown(args, param_summaries, aliases);
        }
    }

    /// Process a recursive SCC by iterating to fixpoint.
    fn analyzeSccFixpoint(self: *InterproceduralAnalyzer, scc: []const ir.FunctionId) !void {
        // Initialize all SCC members with conservative summaries
        for (scc) |func_id| {
            const func = self.getFunction(func_id) orelse continue;
            const summary = try lattice.FunctionSummary.conservative(func.params.len, self.allocator);
            try self.summaries.put(func_id, summary);
        }

        const max_iterations: usize = 100;
        var iteration: usize = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            var changed = false;

            for (scc) |func_id| {
                const new_summary = try self.analyzeFunction(func_id, true);
                const old_summary = self.summaries.get(func_id).?;

                if (!summariesEqual(old_summary, new_summary)) {
                    freeSummary(self.allocator, old_summary);
                    try self.summaries.put(func_id, new_summary);
                    changed = true;
                } else {
                    freeSummary(self.allocator, new_summary);
                }
            }

            if (!changed) break;
        }
    }
};

// ============================================================
// Section 4: Helper Types
// ============================================================

/// Compact bitset for tracking which parameters a local aliases.
/// Supports up to 64 parameters.
const ParamSet = struct {
    bits: u64,

    fn empty() ParamSet {
        return .{ .bits = 0 };
    }

    fn singleton(idx: u32) ParamSet {
        if (idx >= 64) return .{ .bits = 0 };
        return .{ .bits = @as(u64, 1) << @intCast(idx) };
    }

    fn isEmpty(self: ParamSet) bool {
        return self.bits == 0;
    }

    fn contains(self: ParamSet, idx: u32) bool {
        if (idx >= 64) return false;
        return (self.bits & (@as(u64, 1) << @intCast(idx))) != 0;
    }

    fn merge(self: ParamSet, other: ParamSet) ParamSet {
        return .{ .bits = self.bits | other.bits };
    }

    fn iterator(self: ParamSet) ParamSetIterator {
        return .{ .bits = self.bits, .current = 0 };
    }
};

const ParamSetIterator = struct {
    bits: u64,
    current: u32,

    fn next(self: *ParamSetIterator) ?u32 {
        while (self.current < 64) {
            const idx = self.current;
            self.current += 1;
            if ((self.bits & (@as(u64, 1) << @intCast(idx))) != 0) {
                return idx;
            }
        }
        return null;
    }
};

/// Collects return source parameter indices and fresh-alloc flag.
const ReturnSourceCollector = struct {
    sources: []u32,
    len: usize,
    capacity: usize,
    has_fresh: bool,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ReturnSourceCollector {
        return .{
            .sources = &.{},
            .len = 0,
            .capacity = 0,
            .has_fresh = false,
            .allocator = allocator,
        };
    }

    fn addSource(self: *ReturnSourceCollector, idx: u32) !void {
        // Check duplicate
        for (self.sources[0..self.len]) |existing| {
            if (existing == idx) return;
        }
        if (self.len >= self.capacity) {
            const new_cap = if (self.capacity == 0) 4 else self.capacity * 2;
            const new_buf = try self.allocator.alloc(u32, new_cap);
            if (self.len > 0) {
                @memcpy(new_buf[0..self.len], self.sources[0..self.len]);
                self.allocator.free(self.sources[0..self.capacity]);
            }
            self.sources = new_buf.ptr[0..new_cap];
            self.capacity = new_cap;
        }
        self.sources[self.len] = idx;
        self.len += 1;
    }

    fn toOwnedSlice(self: *ReturnSourceCollector) ![]u32 {
        if (self.len == 0) {
            if (self.capacity > 0) {
                self.allocator.free(self.sources[0..self.capacity]);
            }
            return &.{};
        }
        const result = try self.allocator.alloc(u32, self.len);
        @memcpy(result, self.sources[0..self.len]);
        if (self.capacity > 0) {
            self.allocator.free(self.sources[0..self.capacity]);
        }
        self.sources = &.{};
        self.len = 0;
        self.capacity = 0;
        return result;
    }

    fn deinit(self: *ReturnSourceCollector) void {
        if (self.capacity > 0) {
            self.allocator.free(self.sources[0..self.capacity]);
        }
    }
};

// ============================================================
// Section 5: Utility Functions
// ============================================================

/// Mark a local's param aliases as escaping to heap.
fn markEscapeToHeap(
    aliases: *std.AutoArrayHashMap(ir.LocalId, ParamSet),
    local: ir.LocalId,
    param_summaries: []lattice.ParamSummary,
) void {
    if (aliases.get(local)) |param_set| {
        var iter = param_set.iterator();
        while (iter.next()) |idx| {
            if (idx < param_summaries.len) {
                param_summaries[idx].escapes_to_heap = true;
            }
        }
    }
}

/// Mark all args' param aliases as passed_to_unknown.
fn markArgsPassedToUnknown(
    args: []const ir.LocalId,
    param_summaries: []lattice.ParamSummary,
    aliases: *std.AutoArrayHashMap(ir.LocalId, ParamSet),
) void {
    for (args) |arg| {
        if (aliases.get(arg)) |param_set| {
            var iter = param_set.iterator();
            while (iter.next()) |idx| {
                if (idx < param_summaries.len) {
                    param_summaries[idx].passed_to_unknown = true;
                }
            }
        }
    }
}

/// Compare two FunctionSummary values for equality.
fn summariesEqual(a: lattice.FunctionSummary, b: lattice.FunctionSummary) bool {
    if (a.may_diverge != b.may_diverge) return false;
    if (a.param_summaries.len != b.param_summaries.len) return false;

    for (a.param_summaries, b.param_summaries) |pa, pb| {
        if (pa.escapes_to_heap != pb.escapes_to_heap) return false;
        if (pa.returned != pb.returned) return false;
        if (pa.passed_to_unknown != pb.passed_to_unknown) return false;
        if (pa.used_in_reset != pb.used_in_reset) return false;
        if (pa.read_only != pb.read_only) return false;
        if (pa.escape_deref_depth != pb.escape_deref_depth) return false;
    }

    if (a.return_summary.fresh_alloc != b.return_summary.fresh_alloc) return false;
    if (a.return_summary.param_sources.len != b.return_summary.param_sources.len) return false;
    for (a.return_summary.param_sources, b.return_summary.param_sources) |sa, sb| {
        if (sa != sb) return false;
    }

    return true;
}

/// Free a FunctionSummary's owned memory.
fn freeSummary(allocator: std.mem.Allocator, summary: lattice.FunctionSummary) void {
    allocator.free(summary.param_summaries);
    allocator.free(summary.param_lambda_sets);
    if (summary.return_summary.param_sources.len > 0) {
        allocator.free(summary.return_summary.param_sources);
    }
}

// ============================================================
// Section 6: Tests
// ============================================================

test "call graph: empty program" {
    const allocator = std.testing.allocator;
    const program = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };
    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 0), graph.functionCount());
}

test "call graph: simple direct call" {
    const allocator = std.testing.allocator;

    const call_instr = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 1,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_instr}) };
    const block1 = ir.Block{ .label = 0, .instructions = &.{} };

    const func0 = ir.Function{
        .id = 0,
        .name = "caller",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "callee",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.functionCount());
    try std.testing.expectEqual(@as(usize, 1), graph.getCallees(0).len);
    try std.testing.expectEqual(@as(ir.FunctionId, 1), graph.getCallees(0)[0]);
    try std.testing.expectEqual(@as(usize, 1), graph.getCallers(1).len);
    try std.testing.expectEqual(@as(ir.FunctionId, 0), graph.getCallers(1)[0]);
}

test "call graph: named call resolution" {
    const allocator = std.testing.allocator;

    const call_instr = ir.Instruction{ .call_named = .{
        .dest = 0,
        .name = "target",
        .args = &.{},
        .arg_modes = &.{},
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_instr}) };
    const block1 = ir.Block{ .label = 0, .instructions = &.{} };

    const func0 = ir.Function{
        .id = 0,
        .name = "caller",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "target",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.getCallees(0).len);
    try std.testing.expectEqual(@as(ir.FunctionId, 1), graph.getCallees(0)[0]);
}

test "call graph: closure creation tracking" {
    const allocator = std.testing.allocator;

    const mc_instr = ir.Instruction{ .make_closure = .{
        .dest = 0,
        .function = 1,
        .captures = &.{},
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{mc_instr}) };
    const block1 = ir.Block{ .label = 0, .instructions = &.{} };

    const func0 = ir.Function{
        .id = 0,
        .name = "creator",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "closure_fn",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = true,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    try std.testing.expectEqual(@as(?ir.FunctionId, 0), graph.getCreator(1));
    try std.testing.expectEqual(@as(usize, 1), graph.getCallees(0).len);
}

test "SCC: single function no recursion" {
    const allocator = std.testing.allocator;

    const block0 = ir.Block{ .label = 0, .instructions = &.{} };
    const func0 = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    var result = try computeSccs(allocator, &graph);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.sccs.len);
    try std.testing.expectEqual(@as(usize, 1), result.sccs[0].len);
    try std.testing.expectEqual(@as(ir.FunctionId, 0), result.sccs[0][0]);
}

test "SCC: self-recursive function" {
    const allocator = std.testing.allocator;

    const call_instr = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 0,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_instr}) };
    const func0 = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    var result = try computeSccs(allocator, &graph);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.sccs.len);
    try std.testing.expectEqual(@as(usize, 1), result.sccs[0].len);
}

test "SCC: mutual recursion" {
    const allocator = std.testing.allocator;

    const call_01 = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 1,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const call_10 = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 0,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_01}) };
    const block1 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_10}) };

    const func0 = ir.Function{
        .id = 0,
        .name = "even",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "n", .type_expr = .i64 }},
        .return_type = .bool_type,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "odd",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "n", .type_expr = .i64 }},
        .return_type = .bool_type,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    var result = try computeSccs(allocator, &graph);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.sccs.len);
    try std.testing.expectEqual(@as(usize, 2), result.sccs[0].len);
}

test "SCC: chain A -> B -> C in reverse topological order" {
    const allocator = std.testing.allocator;

    const call_ab = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 1,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const call_bc = ir.Instruction{ .call_direct = .{
        .dest = 0,
        .function = 2,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const block_a = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_ab}) };
    const block_b = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{call_bc}) };
    const block_c = ir.Block{ .label = 0, .instructions = &.{} };

    const func_a = ir.Function{
        .id = 0,
        .name = "A",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block_a}),
        .is_closure = false,
        .captures = &.{},
    };
    const func_b = ir.Function{
        .id = 1,
        .name = "B",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block_b}),
        .is_closure = false,
        .captures = &.{},
    };
    const func_c = ir.Function{
        .id = 2,
        .name = "C",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block_c}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func_a, func_b, func_c };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    var result = try computeSccs(allocator, &graph);
    defer result.deinit();

    // Three singleton SCCs
    try std.testing.expectEqual(@as(usize, 3), result.sccs.len);
    // C should come first (leaf), then B, then A
    try std.testing.expectEqual(@as(ir.FunctionId, 2), result.sccs[0][0]);
    try std.testing.expectEqual(@as(ir.FunctionId, 1), result.sccs[1][0]);
    try std.testing.expectEqual(@as(ir.FunctionId, 0), result.sccs[2][0]);
}

test "analyzer: function with no params produces empty summary" {
    const allocator = std.testing.allocator;

    const ret_instr = ir.Instruction{ .ret = .{ .value = null } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{ret_instr}) };
    const func0 = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    try std.testing.expectEqual(@as(usize, 0), summary.param_summaries.len);
    try std.testing.expect(!summary.may_diverge);
}

test "analyzer: function that returns its param" {
    const allocator = std.testing.allocator;

    const pg_instr = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const ret_instr = ir.Instruction{ .ret = .{ .value = 0 } };
    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg_instr, ret_instr }),
    };
    const func0 = ir.Function{
        .id = 0,
        .name = "identity",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    try std.testing.expectEqual(@as(usize, 1), summary.param_summaries.len);
    try std.testing.expect(summary.param_summaries[0].returned);
    try std.testing.expect(!summary.param_summaries[0].read_only);
    try std.testing.expectEqual(@as(usize, 1), summary.return_summary.param_sources.len);
    try std.testing.expectEqual(@as(u32, 0), summary.return_summary.param_sources[0]);
}

test "analyzer: function that only reads param (read-only / borrowable)" {
    const allocator = std.testing.allocator;

    const pg_instr = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const fg_instr = ir.Instruction{ .field_get = .{ .dest = 1, .object = 0, .field = "name" } };
    const ret_instr = ir.Instruction{ .ret = .{ .value = 1 } };
    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg_instr, fg_instr, ret_instr }),
    };
    const func0 = ir.Function{
        .id = 0,
        .name = "get_name",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "obj", .type_expr = .any }},
        .return_type = .string,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    try std.testing.expectEqual(@as(usize, 1), summary.param_summaries.len);
    try std.testing.expect(summary.param_summaries[0].read_only);
    try std.testing.expect(summary.param_summaries[0].canBorrow());
    try std.testing.expect(!summary.param_summaries[0].escapes());
}

test "analyzer: function stores param in struct -> escapes to heap" {
    const allocator = std.testing.allocator;

    const pg_instr = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const field_init = ir.StructFieldInit{ .name = "value", .value = 0 };
    const si_instr = ir.Instruction{ .struct_init = .{
        .dest = 1,
        .type_name = "MyStruct",
        .fields = @constCast(&[_]ir.StructFieldInit{field_init}),
    } };
    const ret_instr = ir.Instruction{ .ret = .{ .value = 1 } };
    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg_instr, si_instr, ret_instr }),
    };
    const func0 = ir.Function{
        .id = 0,
        .name = "wrap",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    try std.testing.expect(summary.param_summaries[0].escapes_to_heap);
    try std.testing.expect(!summary.param_summaries[0].canBorrow());
    try std.testing.expect(summary.param_summaries[0].escapes());
}

test "analyzer: recursive function pair converges" {
    const allocator = std.testing.allocator;

    const pg0 = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const one0 = ir.Instruction{ .const_int = .{ .dest = 1, .value = 1 } };
    const sub0 = ir.Instruction{ .binary_op = .{ .dest = 2, .op = .sub, .lhs = 0, .rhs = 1 } };
    const args0 = [_]ir.LocalId{2};
    const call0 = ir.Instruction{ .call_direct = .{
        .dest = 3,
        .function = 1,
        .args = &args0,
        .arg_modes = &.{},
    } };
    const ret0 = ir.Instruction{ .ret = .{ .value = 3 } };

    const pg1 = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const one1 = ir.Instruction{ .const_int = .{ .dest = 1, .value = 1 } };
    const sub1 = ir.Instruction{ .binary_op = .{ .dest = 2, .op = .sub, .lhs = 0, .rhs = 1 } };
    const args1 = [_]ir.LocalId{2};
    const call1 = ir.Instruction{ .call_direct = .{
        .dest = 3,
        .function = 0,
        .args = &args1,
        .arg_modes = &.{},
    } };
    const ret1 = ir.Instruction{ .ret = .{ .value = 3 } };

    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg0, one0, sub0, call0, ret0 }),
    };
    const block1 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg1, one1, sub1, call1, ret1 }),
    };

    const func0 = ir.Function{
        .id = 0,
        .name = "even",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "n", .type_expr = .i64 }},
        .return_type = .bool_type,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "odd",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "n", .type_expr = .i64 }},
        .return_type = .bool_type,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const even_summary = analyzer.getSummary(0).?;
    const odd_summary = analyzer.getSummary(1).?;

    try std.testing.expectEqual(@as(usize, 1), even_summary.param_summaries.len);
    try std.testing.expectEqual(@as(usize, 1), odd_summary.param_summaries.len);

    // The param is read_only because n-1 (fresh) is passed, not the param itself
    try std.testing.expect(even_summary.param_summaries[0].read_only);
    try std.testing.expect(odd_summary.param_summaries[0].read_only);
    try std.testing.expect(even_summary.param_summaries[0].canBorrow());
}

test "analyzer: call chain A -> B -> C transitive behavior" {
    const allocator = std.testing.allocator;

    // C(x): stores x in struct -> escapes_to_heap
    const c_pg = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const c_field = ir.StructFieldInit{ .name = "val", .value = 0 };
    const c_si = ir.Instruction{ .struct_init = .{
        .dest = 1,
        .type_name = "Box",
        .fields = @constCast(&[_]ir.StructFieldInit{c_field}),
    } };
    const c_ret = ir.Instruction{ .ret = .{ .value = 1 } };
    const c_block = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ c_pg, c_si, c_ret }),
    };

    // B(x): passes x to C
    const b_pg = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const b_args = [_]ir.LocalId{0};
    const b_call = ir.Instruction{ .call_direct = .{
        .dest = 1,
        .function = 2,
        .args = &b_args,
        .arg_modes = &.{},
    } };
    const b_ret = ir.Instruction{ .ret = .{ .value = 1 } };
    const b_block = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ b_pg, b_call, b_ret }),
    };

    // A(x): passes x to B
    const a_pg = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const a_args = [_]ir.LocalId{0};
    const a_call = ir.Instruction{ .call_direct = .{
        .dest = 1,
        .function = 1,
        .args = &a_args,
        .arg_modes = &.{},
    } };
    const a_ret = ir.Instruction{ .ret = .{ .value = 1 } };
    const a_block = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ a_pg, a_call, a_ret }),
    };

    const func_a = ir.Function{
        .id = 0,
        .name = "A",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{a_block}),
        .is_closure = false,
        .captures = &.{},
    };
    const func_b = ir.Function{
        .id = 1,
        .name = "B",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{b_block}),
        .is_closure = false,
        .captures = &.{},
    };
    const func_c = ir.Function{
        .id = 2,
        .name = "C",
        .scope_id = 0,
        .arity = 1,
        .params = &.{.{ .name = "x", .type_expr = .any }},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{c_block}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func_a, func_b, func_c };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // C's param escapes to heap
    const c_summary = analyzer.getSummary(2).?;
    try std.testing.expect(c_summary.param_summaries[0].escapes_to_heap);

    // B's param should also escape (B passes to C which stores it)
    const b_summary = analyzer.getSummary(1).?;
    try std.testing.expect(b_summary.param_summaries[0].escapes_to_heap);

    // A's param should also escape transitively
    const a_summary = analyzer.getSummary(0).?;
    try std.testing.expect(a_summary.param_summaries[0].escapes_to_heap);
}

test "analyzer: fresh return allocation" {
    const allocator = std.testing.allocator;

    const ci_instr = ir.Instruction{ .const_int = .{ .dest = 0, .value = 42 } };
    const field_init = ir.StructFieldInit{ .name = "value", .value = 0 };
    const si_instr = ir.Instruction{ .struct_init = .{
        .dest = 1,
        .type_name = "Box",
        .fields = @constCast(&[_]ir.StructFieldInit{field_init}),
    } };
    const ret_instr = ir.Instruction{ .ret = .{ .value = 1 } };
    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ ci_instr, si_instr, ret_instr }),
    };
    const func0 = ir.Function{
        .id = 0,
        .name = "make_box",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    try std.testing.expect(summary.return_summary.fresh_alloc);
    try std.testing.expectEqual(@as(usize, 0), summary.return_summary.param_sources.len);
}

test "ParamSet operations" {
    const empty_set = ParamSet.empty();
    try std.testing.expect(empty_set.isEmpty());

    const s0 = ParamSet.singleton(0);
    try std.testing.expect(!s0.isEmpty());

    const s1 = ParamSet.singleton(1);
    const merged = s0.merge(s1);

    var count: u32 = 0;
    var iter = merged.iterator();
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "summariesEqual: identical summaries" {
    const allocator = std.testing.allocator;
    const s1 = try lattice.FunctionSummary.conservative(2, allocator);
    defer allocator.free(s1.param_summaries);
    defer allocator.free(s1.param_lambda_sets);

    const s2 = try lattice.FunctionSummary.conservative(2, allocator);
    defer allocator.free(s2.param_summaries);
    defer allocator.free(s2.param_lambda_sets);

    try std.testing.expect(summariesEqual(s1, s2));
}

test "summariesEqual: different summaries" {
    const allocator = std.testing.allocator;
    const s1 = try lattice.FunctionSummary.conservative(2, allocator);
    defer allocator.free(s1.param_summaries);
    defer allocator.free(s1.param_lambda_sets);

    const param_sums = try allocator.alloc(lattice.ParamSummary, 2);
    param_sums[0] = lattice.ParamSummary.safe();
    param_sums[1] = lattice.ParamSummary.conservative();
    defer allocator.free(param_sums);
    const lambda_sets = try allocator.alloc(lattice.LambdaSet, 2);
    @memset(lambda_sets, lattice.LambdaSet.empty());
    defer allocator.free(lambda_sets);

    const s2 = lattice.FunctionSummary{
        .param_summaries = param_sums,
        .return_summary = lattice.ReturnSummary.unknown(),
        .may_diverge = false,
        .param_lambda_sets = lambda_sets,
    };

    try std.testing.expect(!summariesEqual(s1, s2));
}

test "analyzer: multiple params, mixed escape" {
    const allocator = std.testing.allocator;

    const pg0 = ir.Instruction{ .param_get = .{ .dest = 0, .index = 0 } };
    const pg1 = ir.Instruction{ .param_get = .{ .dest = 1, .index = 1 } };
    const fg = ir.Instruction{ .field_get = .{ .dest = 2, .object = 0, .field = "name" } };
    const field_init = ir.StructFieldInit{ .name = "val", .value = 1 };
    const si = ir.Instruction{ .struct_init = .{
        .dest = 3,
        .type_name = "S",
        .fields = @constCast(&[_]ir.StructFieldInit{field_init}),
    } };
    const ret = ir.Instruction{ .ret = .{ .value = 2 } };
    const block0 = ir.Block{
        .label = 0,
        .instructions = @constCast(&[_]ir.Instruction{ pg0, pg1, fg, si, ret }),
    };

    const func0 = ir.Function{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 2,
        .params = &.{
            .{ .name = "a", .type_expr = .any },
            .{ .name = "b", .type_expr = .any },
        },
        .return_type = .any,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{func0};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = try InterproceduralAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    const summary = analyzer.getSummary(0).?;
    // a (param 0): only read via field_get -> read_only, canBorrow
    try std.testing.expect(summary.param_summaries[0].read_only);
    try std.testing.expect(summary.param_summaries[0].canBorrow());
    try std.testing.expect(!summary.param_summaries[0].escapes());

    // b (param 1): stored in struct -> escapes_to_heap
    try std.testing.expect(summary.param_summaries[1].escapes_to_heap);
    try std.testing.expect(!summary.param_summaries[1].read_only);
    try std.testing.expect(!summary.param_summaries[1].canBorrow());
    try std.testing.expect(summary.param_summaries[1].escapes());
}

test "call graph: nested if_expr scanning" {
    const allocator = std.testing.allocator;

    const inner_call = ir.Instruction{ .call_direct = .{
        .dest = 2,
        .function = 1,
        .args = &.{},
        .arg_modes = &.{},
    } };
    const if_instr = ir.Instruction{ .if_expr = .{
        .dest = 1,
        .condition = 0,
        .then_instrs = @constCast(&[_]ir.Instruction{inner_call}),
        .then_result = 2,
        .else_instrs = &.{},
        .else_result = null,
    } };
    const block0 = ir.Block{ .label = 0, .instructions = @constCast(&[_]ir.Instruction{if_instr}) };
    const block1 = ir.Block{ .label = 0, .instructions = &.{} };

    const func0 = ir.Function{
        .id = 0,
        .name = "caller",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block0}),
        .is_closure = false,
        .captures = &.{},
    };
    const func1 = ir.Function{
        .id = 1,
        .name = "callee",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = @constCast(&[_]ir.Block{block1}),
        .is_closure = false,
        .captures = &.{},
    };

    const functions = [_]ir.Function{ func0, func1 };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var graph = try CallGraph.build(allocator, &program);
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.getCallees(0).len);
    try std.testing.expectEqual(@as(ir.FunctionId, 1), graph.getCallees(0)[0]);
}
