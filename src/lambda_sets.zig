const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");

// ============================================================
// Lambda Set Specialization (Research Plan Phase 6)
//
// Whole-program 0-CFA closure flow analysis:
//   - Track which closures (identified by FunctionId from make_closure)
//     may flow to each function-typed binding.
//   - Worklist-based propagation to fixpoint.
//   - Contification detection (Kennedy/Fluet-Weeks):
//     A closure is contifiable if it is ONLY ever called, never stored,
//     passed as argument, or returned.
//   - Per-call-site specialization decisions:
//     empty -> unreachable, singleton -> direct_call,
//     small set -> switch_dispatch, large -> dyn_closure_dispatch,
//     contifiable -> contified.
// ============================================================

/// Set of FunctionIds that may flow to a binding.
/// Backed by a sorted dynamic array for deterministic iteration
/// and efficient membership testing.
pub const FunctionIdSet = struct {
    allocator: std.mem.Allocator,
    members: std.ArrayList(ir.FunctionId),

    pub fn init(allocator: std.mem.Allocator) FunctionIdSet {
        return .{
            .allocator = allocator,
            .members = .empty,
        };
    }

    pub fn deinit(self: *FunctionIdSet) void {
        self.members.deinit(self.allocator);
    }

    pub fn clone(self: *const FunctionIdSet) !FunctionIdSet {
        var copy = FunctionIdSet.init(self.allocator);
        try copy.members.appendSlice(self.allocator, self.members.items);
        return copy;
    }

    /// Add a FunctionId. Returns true if the set changed (id was new).
    /// Maintains sorted order for deterministic results.
    pub fn add(self: *FunctionIdSet, id: ir.FunctionId) !bool {
        // Binary search for insertion point
        const items = self.members.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < id) {
                lo = mid + 1;
            } else if (items[mid] > id) {
                hi = mid;
            } else {
                return false; // already present
            }
        }
        // Insert at lo to maintain sorted order
        try self.members.insert(self.allocator, lo, id);
        return true;
    }

    /// Add all members from another set. Returns true if any new member was added.
    pub fn addAll(self: *FunctionIdSet, other: *const FunctionIdSet) !bool {
        var changed = false;
        for (other.members.items) |id| {
            if (try self.add(id)) {
                changed = true;
            }
        }
        return changed;
    }

    /// Check if the set contains a given FunctionId.
    pub fn contains(self: *const FunctionIdSet, id: ir.FunctionId) bool {
        const items = self.members.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < id) {
                lo = mid + 1;
            } else if (items[mid] > id) {
                hi = mid;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn size(self: *const FunctionIdSet) usize {
        return self.members.items.len;
    }

    pub fn isEmpty(self: *const FunctionIdSet) bool {
        return self.members.items.len == 0;
    }

    pub fn isSingleton(self: *const FunctionIdSet) bool {
        return self.members.items.len == 1;
    }

    /// Convert to an immutable LambdaSet (allocates a new slice).
    pub fn toLambdaSet(self: *const FunctionIdSet, allocator: std.mem.Allocator) !lattice.LambdaSet {
        if (self.members.items.len == 0) {
            return lattice.LambdaSet.empty();
        }
        const slice = try allocator.alloc(ir.FunctionId, self.members.items.len);
        @memcpy(slice, self.members.items);
        return .{ .members = slice };
    }
};

/// Key for per-parameter lambda sets.
pub const ParamKey = struct {
    function: ir.FunctionId,
    param_index: u32,
};

/// A recorded call site with its specialization decision.
pub const CallSiteDecision = struct {
    /// Function containing this call site.
    function: ir.FunctionId,
    /// Block label where the call resides.
    block: ir.LabelId,
    /// Index of the instruction within the block.
    instr_index: u32,
    /// The local holding the callee closure.
    callee_local: ir.LocalId,
    /// Computed specialization decision.
    decision: lattice.SpecializationDecision,
    /// The lambda set at the callee binding.
    lambda_set: lattice.LambdaSet,
};

/// Tracks how a closure-producing local is used, for contification.
const UsageKind = enum {
    /// Only used as the callee of call_closure instructions.
    only_called,
    /// Used in some non-call context (stored, passed as arg, returned, etc.)
    escaped,
};

// ============================================================
// Worklist item: identifies a (function, local) whose lambda set changed.
// ============================================================
const WorkItem = struct {
    function: ir.FunctionId,
    local: ir.LocalId,
};

// ============================================================
// LambdaSetAnalyzer
// ============================================================

pub const LambdaSetAnalyzer = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,

    /// Per-value lambda sets: (function_id, local_id) -> set of closure FunctionIds.
    lambda_sets: std.AutoHashMap(lattice.ValueKey, FunctionIdSet),

    /// Per-function-parameter lambda sets.
    param_lambda_sets: std.AutoHashMap(ParamKey, FunctionIdSet),

    /// Function name -> FunctionId resolution.
    name_to_id: std.StringHashMap(ir.FunctionId),

    /// Call sites and their decisions (populated after analysis).
    call_site_decisions: std.ArrayList(CallSiteDecision),

    /// Contifiable closures (function_id -> true if contifiable).
    contifiable: std.AutoHashMap(ir.FunctionId, bool),

    /// Worklist for fixpoint iteration.
    worklist: std.ArrayList(WorkItem),

    /// Tracks which (function, local) pairs are already on the worklist.
    on_worklist: std.AutoHashMap(lattice.ValueKey, void),

    /// Per-closure usage tracking for contification.
    closure_usage: std.AutoHashMap(ir.FunctionId, UsageKind),

    /// Return value propagation: maps callee FunctionId to list of
    /// (caller function, dest local) pairs that receive the return value.
    return_sites: std.AutoHashMap(ir.FunctionId, ReturnSiteList),

    const ReturnSiteList = struct {
        items: std.ArrayList(lattice.ValueKey),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) ReturnSiteList {
            return .{ .items = .empty, .allocator = allocator };
        }

        fn deinit(self: *ReturnSiteList) void {
            self.items.deinit(self.allocator);
        }

        fn append(self: *ReturnSiteList, key: lattice.ValueKey) !void {
            try self.items.append(self.allocator, key);
        }
    };

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program) !LambdaSetAnalyzer {
        var self = LambdaSetAnalyzer{
            .allocator = allocator,
            .program = program,
            .lambda_sets = std.AutoHashMap(lattice.ValueKey, FunctionIdSet).init(allocator),
            .param_lambda_sets = std.AutoHashMap(ParamKey, FunctionIdSet).init(allocator),
            .name_to_id = std.StringHashMap(ir.FunctionId).init(allocator),
            .call_site_decisions = .empty,
            .contifiable = std.AutoHashMap(ir.FunctionId, bool).init(allocator),
            .worklist = .empty,
            .on_worklist = std.AutoHashMap(lattice.ValueKey, void).init(allocator),
            .closure_usage = std.AutoHashMap(ir.FunctionId, UsageKind).init(allocator),
            .return_sites = std.AutoHashMap(ir.FunctionId, ReturnSiteList).init(allocator),
        };

        // Build name -> id map
        for (program.functions) |func| {
            try self.name_to_id.put(func.name, func.id);
        }

        return self;
    }

    pub fn deinit(self: *LambdaSetAnalyzer) void {
        // Deinit all FunctionIdSets in lambda_sets
        var ls_iter = self.lambda_sets.iterator();
        while (ls_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.lambda_sets.deinit();

        // Deinit all FunctionIdSets in param_lambda_sets
        var pls_iter = self.param_lambda_sets.iterator();
        while (pls_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.param_lambda_sets.deinit();

        self.name_to_id.deinit();
        // Free allocated lambda set slices in call site decisions
        for (self.call_site_decisions.items) |d| {
            if (d.lambda_set.members.len > 0) {
                self.allocator.free(d.lambda_set.members);
            }
        }
        self.call_site_decisions.deinit(self.allocator);
        self.contifiable.deinit();
        self.worklist.deinit(self.allocator);
        self.on_worklist.deinit();
        self.closure_usage.deinit();

        // Deinit return_sites lists
        var rs_iter = self.return_sites.iterator();
        while (rs_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.return_sites.deinit();
    }

    // --------------------------------------------------------
    // Main analysis entry point
    // --------------------------------------------------------

    pub fn analyze(self: *LambdaSetAnalyzer) !void {
        // Phase 1: Seed lambda sets from make_closure instructions
        //          and collect contification usage info.
        try self.seedAndCollectUsage();

        // Phase 2: Fixpoint propagation
        try self.propagateToFixpoint();

        // Phase 3: Determine contifiability
        try self.determineContifiability();

        // Phase 4: Compute per-call-site specialization decisions
        try self.computeDecisions();
    }

    // --------------------------------------------------------
    // Phase 1: Seed from make_closure + collect usage
    // --------------------------------------------------------

    fn seedAndCollectUsage(self: *LambdaSetAnalyzer) !void {
        for (self.program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    try self.seedInstruction(func.id, instr);
                }
            }
        }
        // Second pass: register all call-site return edges so return
        // propagation can find callers during fixpoint iteration.
        for (self.program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    try self.registerCallReturnSites(func.id, instr);
                }
            }
        }
    }

    /// Pre-register return-value edges for all call instructions.
    fn registerCallReturnSites(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, instr: ir.Instruction) !void {
        switch (instr) {
            .call_direct => |cd| {
                try self.registerReturnSite(cd.function, func_id, cd.dest);
            },
            .call_named => |cn| {
                if (self.name_to_id.get(cn.name)) |callee_id| {
                    try self.registerReturnSite(callee_id, func_id, cn.dest);
                }
            },
            .call_closure => |cc| {
                // For call_closure, we register return sites lazily during
                // propagation once we know which closures may be called.
                _ = cc;
            },
            .if_expr => |ie| {
                for (ie.then_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
                for (ie.else_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
                for (cb.arms) |arm| {
                    for (arm.cond_instrs) |sub| {
                        try self.registerCallReturnSites(func_id, sub);
                    }
                    for (arm.body_instrs) |sub| {
                        try self.registerCallReturnSites(func_id, sub);
                    }
                }
                for (cb.default_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
            },
            .guard_block => |gb| {
                for (gb.body) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.registerCallReturnSites(func_id, sub);
                    }
                }
                for (sl.default_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.registerCallReturnSites(func_id, sub);
                    }
                }
                for (sr.default_instrs) |sub| {
                    try self.registerCallReturnSites(func_id, sub);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.registerCallReturnSites(func_id, sub);
                    }
                }
            },
            else => {},
        }
    }

    fn seedInstruction(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, instr: ir.Instruction) !void {
        switch (instr) {
            .make_closure => |mc| {
                // Seed: lambda_set[dest] = {mc.function}
                const key = lattice.ValueKey{ .function = func_id, .local = mc.dest };
                try self.ensureSet(key);
                const set = self.lambda_sets.getPtr(key).?;
                if (try set.add(mc.function)) {
                    try self.enqueue(func_id, mc.dest);
                }
                // Initialize closure usage as only_called (optimistic)
                if (!self.closure_usage.contains(mc.function)) {
                    try self.closure_usage.put(mc.function, .only_called);
                }
            },
            .call_closure => |cc| {
                // Args being passed to a closure callee marks those closures
                // in the args as escaped (they're being passed as arguments).
                for (cc.args) |arg| {
                    try self.markClosuresEscaped(func_id, arg);
                }
            },
            .call_direct => |cd| {
                // Args passed to a direct call: mark closures in args as escaped
                for (cd.args) |arg| {
                    try self.markClosuresEscaped(func_id, arg);
                }
            },
            .call_named => |cn| {
                for (cn.args) |arg| {
                    try self.markClosuresEscaped(func_id, arg);
                }
            },
            .ret => |r| {
                // Returning a closure marks it as escaped
                if (r.value) |val| {
                    try self.markClosuresEscaped(func_id, val);
                }
            },
            .local_set => |ls| {
                // Storing a closure into a variable marks it escaped
                // (because local_set is a write to a mutable binding)
                try self.markClosuresEscaped(func_id, ls.value);
            },
            .if_expr => |ie| {
                for (ie.then_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
                for (ie.else_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
                for (cb.arms) |arm| {
                    for (arm.cond_instrs) |sub| {
                        try self.seedInstruction(func_id, sub);
                    }
                    for (arm.body_instrs) |sub| {
                        try self.seedInstruction(func_id, sub);
                    }
                }
                for (cb.default_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
            },
            .guard_block => |gb| {
                for (gb.body) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.seedInstruction(func_id, sub);
                    }
                }
                for (sl.default_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.seedInstruction(func_id, sub);
                    }
                }
                for (sr.default_instrs) |sub| {
                    try self.seedInstruction(func_id, sub);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.seedInstruction(func_id, sub);
                    }
                }
            },
            else => {},
        }
    }

    /// Mark all closures flowing to a local as escaped (not contifiable).
    fn markClosuresEscaped(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, local: ir.LocalId) !void {
        const key = lattice.ValueKey{ .function = func_id, .local = local };
        if (self.lambda_sets.getPtr(key)) |set| {
            for (set.members.items) |closure_id| {
                try self.closure_usage.put(closure_id, .escaped);
            }
        }
    }

    // --------------------------------------------------------
    // Phase 2: Fixpoint propagation
    // --------------------------------------------------------

    fn propagateToFixpoint(self: *LambdaSetAnalyzer) !void {
        // Seed worklist with all known lambda set bindings
        var iter = self.lambda_sets.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.isEmpty()) {
                try self.enqueue(entry.key_ptr.function, entry.key_ptr.local);
            }
        }

        // Process worklist until empty
        var iterations: usize = 0;
        const max_iterations: usize = 100_000; // safety bound
        while (self.worklist.items.len > 0 and iterations < max_iterations) {
            iterations += 1;
            const item = self.worklist.orderedRemove(0);
            const key = lattice.ValueKey{ .function = item.function, .local = item.local };
            _ = self.on_worklist.remove(key);

            // Propagate through all instructions in this function that use this local
            try self.propagateFromLocal(item.function, item.local);
        }
    }

    /// Propagate lambda set changes from a specific local through all instructions
    /// in the containing function.
    fn propagateFromLocal(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, local: ir.LocalId) !void {
        const func = self.getFunction(func_id) orelse return;
        for (func.body) |block| {
            for (block.instructions, 0..) |instr, instr_idx| {
                try self.propagateInstruction(func_id, block.label, @intCast(instr_idx), instr, local);
            }
        }
    }

    fn propagateInstruction(
        self: *LambdaSetAnalyzer,
        func_id: ir.FunctionId,
        block_label: ir.LabelId,
        instr_index: u32,
        instr: ir.Instruction,
        changed_local: ir.LocalId,
    ) !void {
        switch (instr) {
            .local_get => |lg| {
                // lambda_set[dest] |= lambda_set[source]
                if (lg.source == changed_local) {
                    try self.propagateUnion(func_id, lg.dest, func_id, lg.source);
                }
            },
            .local_set => |ls| {
                // lambda_set[dest] |= lambda_set[value]
                if (ls.value == changed_local) {
                    try self.propagateUnion(func_id, ls.dest, func_id, ls.value);
                }
            },
            .call_direct => |cd| {
                // Propagate lambda sets from args to callee's params
                for (cd.args, 0..) |arg, i| {
                    if (arg == changed_local) {
                        try self.propagateArgToParam(func_id, arg, cd.function, @intCast(i));
                    }
                }
                // Register return site so we can propagate return values
                try self.registerReturnSite(cd.function, func_id, cd.dest);
            },
            .call_named => |cn| {
                if (self.name_to_id.get(cn.name)) |callee_id| {
                    for (cn.args, 0..) |arg, i| {
                        if (arg == changed_local) {
                            try self.propagateArgToParam(func_id, arg, callee_id, @intCast(i));
                        }
                    }
                    try self.registerReturnSite(callee_id, func_id, cn.dest);
                }
            },
            .call_closure => |cc| {
                // For each closure in lambda_set[callee], propagate args to that closure's params
                if (cc.callee == changed_local) {
                    const callee_key = lattice.ValueKey{ .function = func_id, .local = cc.callee };
                    if (self.lambda_sets.getPtr(callee_key)) |callee_set| {
                        for (callee_set.members.items) |closure_id| {
                            for (cc.args, 0..) |arg, i| {
                                try self.propagateArgToParam(func_id, arg, closure_id, @intCast(i));
                            }
                            try self.registerReturnSite(closure_id, func_id, cc.dest);
                        }
                    }
                }
                // Also propagate if an arg changed
                for (cc.args, 0..) |arg, i| {
                    if (arg == changed_local) {
                        const callee_key = lattice.ValueKey{ .function = func_id, .local = cc.callee };
                        if (self.lambda_sets.getPtr(callee_key)) |callee_set| {
                            for (callee_set.members.items) |closure_id| {
                                try self.propagateArgToParam(func_id, arg, closure_id, @intCast(i));
                            }
                        }
                    }
                }
            },
            .ret => |r| {
                // Propagate lambda_set[val] to all callers' return destinations
                if (r.value) |val| {
                    if (val == changed_local) {
                        try self.propagateReturn(func_id, val);
                    }
                }
            },
            .phi => |p| {
                // lambda_set[dest] |= lambda_set[src] for each source
                for (p.sources) |src| {
                    if (src.value == changed_local) {
                        try self.propagateUnion(func_id, p.dest, func_id, src.value);
                    }
                }
            },
            .if_expr => |ie| {
                // Propagate through sub-instructions
                for (ie.then_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                for (ie.else_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                // Propagate result locals to dest
                if (ie.then_result) |tr| {
                    if (tr == changed_local) {
                        try self.propagateUnion(func_id, ie.dest, func_id, tr);
                    }
                }
                if (ie.else_result) |er| {
                    if (er == changed_local) {
                        try self.propagateUnion(func_id, ie.dest, func_id, er);
                    }
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                for (cb.arms) |arm| {
                    for (arm.cond_instrs, 0..) |sub, idx| {
                        try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                    }
                    for (arm.body_instrs, 0..) |sub, idx| {
                        try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                    }
                    if (arm.result) |r| {
                        if (r == changed_local) {
                            try self.propagateUnion(func_id, cb.dest, func_id, r);
                        }
                    }
                }
                for (cb.default_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                if (cb.default_result) |dr| {
                    if (dr == changed_local) {
                        try self.propagateUnion(func_id, cb.dest, func_id, dr);
                    }
                }
            },
            .guard_block => |gb| {
                for (gb.body, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                    }
                    if (c.result) |r| {
                        if (r == changed_local) {
                            try self.propagateUnion(func_id, sl.dest, func_id, r);
                        }
                    }
                }
                for (sl.default_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                if (sl.default_result) |dr| {
                    if (dr == changed_local) {
                        try self.propagateUnion(func_id, sl.dest, func_id, dr);
                    }
                }
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                    }
                    if (c.return_value) |rv| {
                        if (rv == changed_local) {
                            try self.propagateReturn(func_id, rv);
                        }
                    }
                }
                for (sr.default_instrs, 0..) |sub, idx| {
                    try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                }
                if (sr.default_result) |dr| {
                    if (dr == changed_local) {
                        try self.propagateReturn(func_id, dr);
                    }
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.propagateInstruction(func_id, block_label, @intCast(instr_index + idx), sub, changed_local);
                    }
                    if (c.return_value) |rv| {
                        if (rv == changed_local) {
                            try self.propagateReturn(func_id, rv);
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Propagate: lambda_set[dest_func:dest] |= lambda_set[src_func:src]
    fn propagateUnion(
        self: *LambdaSetAnalyzer,
        dest_func: ir.FunctionId,
        dest_local: ir.LocalId,
        src_func: ir.FunctionId,
        src_local: ir.LocalId,
    ) !void {
        const src_key = lattice.ValueKey{ .function = src_func, .local = src_local };
        const dest_key = lattice.ValueKey{ .function = dest_func, .local = dest_local };

        // Get source set members -- copy to temp buffer because ensureSet
        // may invalidate pointers into the hash map.
        const src_set = self.lambda_sets.getPtr(src_key) orelse return;
        if (src_set.isEmpty()) return;

        // Copy source members before any map mutation
        const src_members = try self.allocator.alloc(ir.FunctionId, src_set.members.items.len);
        defer self.allocator.free(src_members);
        @memcpy(src_members, src_set.members.items);

        // Ensure dest set exists (may rehash the map)
        try self.ensureSet(dest_key);
        const dest_set = self.lambda_sets.getPtr(dest_key).?;

        // Add from copied members
        var changed = false;
        for (src_members) |id| {
            if (try dest_set.add(id)) {
                changed = true;
            }
        }
        if (changed) {
            try self.enqueue(dest_func, dest_local);
        }
    }

    /// Propagate lambda set from an argument to a callee's parameter.
    fn propagateArgToParam(
        self: *LambdaSetAnalyzer,
        caller_func: ir.FunctionId,
        arg_local: ir.LocalId,
        callee_func: ir.FunctionId,
        param_index: u32,
    ) !void {
        const arg_key = lattice.ValueKey{ .function = caller_func, .local = arg_local };
        const src_set = self.lambda_sets.getPtr(arg_key) orelse return;
        if (src_set.isEmpty()) return;

        const param_key = ParamKey{ .function = callee_func, .param_index = param_index };

        // Ensure param set exists
        const result = try self.param_lambda_sets.getOrPut(param_key);
        if (!result.found_existing) {
            result.value_ptr.* = FunctionIdSet.init(self.allocator);
        }

        if (try result.value_ptr.addAll(src_set)) {
            // Param lambda set changed - propagate to param_get instructions in callee
            try self.propagateParamToLocals(callee_func, param_index);
        }
    }

    /// When a parameter's lambda set changes, propagate to all param_get
    /// instructions in the callee function that read this parameter.
    fn propagateParamToLocals(self: *LambdaSetAnalyzer, callee_func: ir.FunctionId, param_index: u32) !void {
        const func = self.getFunction(callee_func) orelse return;
        const param_key = ParamKey{ .function = callee_func, .param_index = param_index };
        const param_set = self.param_lambda_sets.getPtr(param_key) orelse return;

        for (func.body) |block| {
            for (block.instructions) |instr| {
                try self.propagateParamInstr(callee_func, instr, param_index, param_set);
            }
        }
    }

    fn propagateParamInstr(
        self: *LambdaSetAnalyzer,
        func_id: ir.FunctionId,
        instr: ir.Instruction,
        param_index: u32,
        param_set: *const FunctionIdSet,
    ) !void {
        switch (instr) {
            .param_get => |pg| {
                if (pg.index == param_index) {
                    const dest_key = lattice.ValueKey{ .function = func_id, .local = pg.dest };
                    try self.ensureSet(dest_key);
                    const dest_set = self.lambda_sets.getPtr(dest_key).?;
                    if (try dest_set.addAll(param_set)) {
                        try self.enqueue(func_id, pg.dest);
                    }
                }
            },
            .if_expr => |ie| {
                for (ie.then_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
                for (ie.else_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
                for (cb.arms) |arm| {
                    for (arm.cond_instrs) |sub| {
                        try self.propagateParamInstr(func_id, sub, param_index, param_set);
                    }
                    for (arm.body_instrs) |sub| {
                        try self.propagateParamInstr(func_id, sub, param_index, param_set);
                    }
                }
                for (cb.default_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
            },
            .guard_block => |gb| {
                for (gb.body) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.propagateParamInstr(func_id, sub, param_index, param_set);
                    }
                }
                for (sl.default_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.propagateParamInstr(func_id, sub, param_index, param_set);
                    }
                }
                for (sr.default_instrs) |sub| {
                    try self.propagateParamInstr(func_id, sub, param_index, param_set);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    for (c.body_instrs) |sub| {
                        try self.propagateParamInstr(func_id, sub, param_index, param_set);
                    }
                }
            },
            else => {},
        }
    }

    /// Propagate a return value's lambda set to all registered call-site destinations.
    fn propagateReturn(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, ret_local: ir.LocalId) !void {
        const ret_key = lattice.ValueKey{ .function = func_id, .local = ret_local };
        const ret_set = self.lambda_sets.getPtr(ret_key) orelse return;
        if (ret_set.isEmpty()) return;

        // Copy source members before map mutation (ensureSet may rehash)
        const src_members = try self.allocator.alloc(ir.FunctionId, ret_set.members.items.len);
        defer self.allocator.free(src_members);
        @memcpy(src_members, ret_set.members.items);

        if (self.return_sites.getPtr(func_id)) |site_list| {
            for (site_list.items.items) |site| {
                const dest_key = lattice.ValueKey{ .function = site.function, .local = site.local };
                try self.ensureSet(dest_key);
                const dest_set = self.lambda_sets.getPtr(dest_key).?;
                var changed = false;
                for (src_members) |id| {
                    if (try dest_set.add(id)) {
                        changed = true;
                    }
                }
                if (changed) {
                    try self.enqueue(site.function, site.local);
                }
            }
        }
    }

    /// Register that a call to callee_func stores its return value into
    /// (caller_func, dest_local).
    fn registerReturnSite(
        self: *LambdaSetAnalyzer,
        callee_func: ir.FunctionId,
        caller_func: ir.FunctionId,
        dest_local: ir.LocalId,
    ) !void {
        const result = try self.return_sites.getOrPut(callee_func);
        if (!result.found_existing) {
            result.value_ptr.* = ReturnSiteList.init(self.allocator);
        }
        const dest_key = lattice.ValueKey{ .function = caller_func, .local = dest_local };
        // Avoid duplicates
        for (result.value_ptr.items.items) |existing| {
            if (existing.function == dest_key.function and existing.local == dest_key.local) return;
        }
        try result.value_ptr.append(dest_key);
    }

    // --------------------------------------------------------
    // Phase 3: Contification
    // --------------------------------------------------------

    fn determineContifiability(self: *LambdaSetAnalyzer) !void {
        // A closure is contifiable if:
        // 1. It is created by make_closure
        // 2. Every use of its dest local is as the callee of call_closure
        // 3. It is never stored, passed as argument, or returned
        //
        // We already tracked this in closure_usage during seeding.
        // Now finalize: also verify the closure is not used across functions
        // (i.e., it's not in any param_lambda_set).

        var usage_iter = self.closure_usage.iterator();
        while (usage_iter.next()) |entry| {
            const closure_id = entry.key_ptr.*;
            const usage = entry.value_ptr.*;

            if (usage == .only_called) {
                // Also check: the closure must not appear in any parameter lambda set
                // (meaning it was never passed as an argument interprocedurally)
                var escaped_via_param = false;
                var pls_iter = self.param_lambda_sets.iterator();
                while (pls_iter.next()) |pls_entry| {
                    if (pls_entry.value_ptr.contains(closure_id)) {
                        escaped_via_param = true;
                        break;
                    }
                }

                try self.contifiable.put(closure_id, !escaped_via_param);
            } else {
                try self.contifiable.put(closure_id, false);
            }
        }
    }

    // --------------------------------------------------------
    // Phase 4: Compute specialization decisions
    // --------------------------------------------------------

    fn computeDecisions(self: *LambdaSetAnalyzer) !void {
        for (self.program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions, 0..) |instr, instr_idx| {
                    try self.computeInstrDecision(func.id, block.label, @intCast(instr_idx), instr);
                }
            }
        }
    }

    fn computeInstrDecision(
        self: *LambdaSetAnalyzer,
        func_id: ir.FunctionId,
        block_label: ir.LabelId,
        instr_index: u32,
        instr: ir.Instruction,
    ) !void {
        switch (instr) {
            .call_closure => |cc| {
                const callee_key = lattice.ValueKey{ .function = func_id, .local = cc.callee };
                const set = self.lambda_sets.getPtr(callee_key);

                var ls: lattice.LambdaSet = undefined;
                var is_contifiable = false;

                if (set) |s| {
                    ls = try s.toLambdaSet(self.allocator);
                    // Check contifiability: singleton must be contifiable
                    if (s.isSingleton()) {
                        is_contifiable = self.isContifiable(s.members.items[0]);
                    }
                } else {
                    ls = lattice.LambdaSet.empty();
                }

                const decision = lattice.specializationForLambdaSet(ls, is_contifiable);
                try self.call_site_decisions.append(self.allocator, .{
                    .function = func_id,
                    .block = block_label,
                    .instr_index = instr_index,
                    .callee_local = cc.callee,
                    .decision = decision,
                    .lambda_set = ls,
                });
            },
            .if_expr => |ie| {
                for (ie.then_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
                for (ie.else_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
                for (cb.arms) |arm| {
                    for (arm.cond_instrs, 0..) |sub, idx| {
                        try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                    }
                    for (arm.body_instrs, 0..) |sub, idx| {
                        try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                    }
                }
                for (cb.default_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
            },
            .guard_block => |gb| {
                for (gb.body, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                    }
                }
                for (sl.default_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                    }
                }
                for (sr.default_instrs, 0..) |sub, idx| {
                    try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    for (c.body_instrs, 0..) |sub, idx| {
                        try self.computeInstrDecision(func_id, block_label, @intCast(instr_index + idx), sub);
                    }
                }
            },
            else => {},
        }
    }

    // --------------------------------------------------------
    // Query interface
    // --------------------------------------------------------

    /// Get the lambda set for a given value binding.
    pub fn getLambdaSet(self: *const LambdaSetAnalyzer, key: lattice.ValueKey) ?lattice.LambdaSet {
        const set = self.lambda_sets.getPtr(key) orelse return null;
        // Return a view without allocation (references internal storage)
        if (set.members.items.len == 0) return lattice.LambdaSet.empty();
        return .{ .members = set.members.items };
    }

    /// Get the specialization decision for a call site by index.
    pub fn getDecision(self: *const LambdaSetAnalyzer, call_site_idx: usize) ?lattice.SpecializationDecision {
        if (call_site_idx >= self.call_site_decisions.items.len) return null;
        return self.call_site_decisions.items[call_site_idx].decision;
    }

    /// Check if a closure is contifiable.
    pub fn isContifiable(self: *const LambdaSetAnalyzer, func_id: ir.FunctionId) bool {
        return self.contifiable.get(func_id) orelse false;
    }

    /// Populate an AnalysisContext with results from this analysis.
    pub fn populateContext(self: *LambdaSetAnalyzer, ctx: *lattice.AnalysisContext) !void {
        // Populate per-binding lambda sets
        var iter = self.lambda_sets.iterator();
        while (iter.next()) |entry| {
            const ls = try entry.value_ptr.toLambdaSet(self.allocator);
            try ctx.lambda_sets.put(entry.key_ptr.*, ls);
        }

        for (self.call_site_decisions.items) |decision| {
            const copied_set = if (decision.lambda_set.members.len == 0)
                lattice.LambdaSet.empty()
            else blk: {
                const members = try self.allocator.alloc(ir.FunctionId, decision.lambda_set.members.len);
                @memcpy(members, decision.lambda_set.members);
                break :blk lattice.LambdaSet{ .members = members };
            };
            try ctx.call_specializations.put(.{
                .function = decision.function,
                .block = decision.block,
                .instr_index = decision.instr_index,
            }, .{
                .decision = decision.decision,
                .lambda_set = copied_set,
            });
        }
    }

    // --------------------------------------------------------
    // Helpers
    // --------------------------------------------------------

    fn ensureSet(self: *LambdaSetAnalyzer, key: lattice.ValueKey) !void {
        const result = try self.lambda_sets.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = FunctionIdSet.init(self.allocator);
        }
    }

    fn enqueue(self: *LambdaSetAnalyzer, func_id: ir.FunctionId, local: ir.LocalId) !void {
        const key = lattice.ValueKey{ .function = func_id, .local = local };
        const result = try self.on_worklist.getOrPut(key);
        if (!result.found_existing) {
            try self.worklist.append(self.allocator, .{ .function = func_id, .local = local });
        }
    }

    fn getFunction(self: *const LambdaSetAnalyzer, func_id: ir.FunctionId) ?*const ir.Function {
        for (self.program.functions) |*func| {
            if (func.id == func_id) return func;
        }
        return null;
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// Test 1: Single closure flows to single call site -> singleton lambda set -> direct_call
test "singleton lambda set yields direct_call" {
    const allocator = testing.allocator;

    // Program:
    //   fn main():
    //     %0 = make_closure(closure_fn, [])
    //     %1 = call_closure(%0, [])
    //     ret %1
    //   fn closure_fn():
    //     %0 = const_int 42
    //     ret %0
    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "closure_fn", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Check lambda set at %0 in main is {closure_fn}
    const key = lattice.ValueKey{ .function = 0, .local = 0 };
    const ls = analyzer.getLambdaSet(key).?;
    try testing.expectEqual(@as(usize, 1), ls.size());
    try testing.expect(ls.contains(1));

    // Check decision: should be direct_call or contified (contified since only called)
    try testing.expect(analyzer.call_site_decisions.items.len >= 1);
    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.callee_local == 0 and d.function == 0) {
            try testing.expect(d.decision == .contified or d.decision == .direct_call);
            found = true;
        }
    }
    try testing.expect(found);
}

// Test 2: Two closures flow to same call site -> 2-element set -> switch_dispatch
test "two closures yield switch_dispatch" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &.{} } },
        .{ .const_bool = .{ .dest = 3, .value = true } },
        .{ .if_expr = .{
            .dest = 2,
            .condition = 3,
            .then_instrs = &.{},
            .then_result = 0,
            .else_instrs = &.{},
            .else_result = 1,
        } },
        .{ .call_closure = .{ .dest = 4, .callee = 2, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 4 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const empty_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const empty_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &empty_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "fn_a", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &empty_blocks, .is_closure = true, .captures = &.{} },
        .{ .id = 2, .name = "fn_b", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &empty_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Check lambda set at %2 in main is {fn_a, fn_b}
    const key = lattice.ValueKey{ .function = 0, .local = 2 };
    const ls = analyzer.getLambdaSet(key).?;
    try testing.expectEqual(@as(usize, 2), ls.size());
    try testing.expect(ls.contains(1));
    try testing.expect(ls.contains(2));

    // Check decision: should be switch_dispatch
    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.callee_local == 2 and d.function == 0) {
            try testing.expectEqual(lattice.SpecializationDecision.switch_dispatch, d.decision);
            found = true;
        }
    }
    try testing.expect(found);
}

// Test 3: Closure only ever called directly -> contifiable
test "closure only called is contifiable" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 10 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "closure_fn", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    try testing.expect(analyzer.isContifiable(1));

    // Decision should be contified
    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.callee_local == 0 and d.function == 0) {
            try testing.expectEqual(lattice.SpecializationDecision.contified, d.decision);
            found = true;
        }
    }
    try testing.expect(found);
}

// Test 4: Closure stored in variable via local_set -> NOT contifiable
test "closure stored in variable is not contifiable" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .local_set = .{ .dest = 1, .value = 0 } },
        .{ .call_closure = .{ .dest = 2, .callee = 1, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 2 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 10 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "closure_fn", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Closure should NOT be contifiable (it was stored via local_set)
    try testing.expect(!analyzer.isContifiable(1));
}

// Test 5: Closure passed to function that calls it -> lambda set propagates through parameters
test "closure propagates through function parameters" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 2, .captures = &.{} } },
        .{ .call_direct = .{ .dest = 1, .function = 1, .args = &[_]ir.LocalId{0}, .arg_modes = &.{} } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const apply_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &apply_instrs },
    };

    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 99 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const apply_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .any },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "apply", .scope_id = 0, .arity = 0, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "the_closure", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Lambda set at apply's param_get %0 should contain the_closure (func 2)
    const apply_local_key = lattice.ValueKey{ .function = 1, .local = 0 };
    const ls = analyzer.getLambdaSet(apply_local_key);
    try testing.expect(ls != null);
    try testing.expectEqual(@as(usize, 1), ls.?.size());
    try testing.expect(ls.?.contains(2));

    // Not contifiable since it's passed as an argument
    try testing.expect(!analyzer.isContifiable(2));
}

// Test 6: Closure returned from function -> lambda set propagates to caller's return binding
test "closure return propagates to caller" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .call_direct = .{ .dest = 0, .function = 1, .args = &.{}, .arg_modes = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const make_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 2, .captures = &.{} } },
        .{ .ret = .{ .value = 0 } },
    };
    const make_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &make_instrs },
    };

    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 77 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "make_it", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .any, .body = &make_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "the_closure", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Lambda set at main's %0 (return from make_it) should contain the_closure (func 2)
    const main_ret_key = lattice.ValueKey{ .function = 0, .local = 0 };
    const ls = analyzer.getLambdaSet(main_ret_key);
    try testing.expect(ls != null);
    try testing.expectEqual(@as(usize, 1), ls.?.size());
    try testing.expect(ls.?.contains(2));

    // Returned closure is not contifiable
    try testing.expect(!analyzer.isContifiable(2));
}

// Test 7: Empty lambda set at call site -> unreachable_call
test "empty lambda set yields unreachable_call" {
    const allocator = testing.allocator;

    const main_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .any },
    };
    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &main_params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // No make_closure flows to %0, so lambda set is empty -> unreachable
    try testing.expect(analyzer.call_site_decisions.items.len >= 1);
    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.callee_local == 0 and d.function == 0) {
            try testing.expectEqual(lattice.SpecializationDecision.unreachable_call, d.decision);
            found = true;
        }
    }
    try testing.expect(found);
}

test "returned two-target closure propagates to higher-order callee" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .call_direct = .{ .dest = 0, .function = 1, .args = &.{}, .arg_modes = &.{} } },
        .{ .call_direct = .{ .dest = 1, .function = 2, .args = &[_]ir.LocalId{0}, .arg_modes = &.{} } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};

    const choose_instrs = [_]ir.Instruction{
        .{ .const_bool = .{ .dest = 0, .value = true } },
        .{ .make_closure = .{ .dest = 1, .function = 3, .captures = &.{} } },
        .{ .make_closure = .{ .dest = 2, .function = 4, .captures = &.{} } },
        .{ .if_expr = .{
            .dest = 5,
            .condition = 0,
            .then_instrs = &.{},
            .then_result = 1,
            .else_instrs = &.{},
            .else_result = 2,
        } },
        .{ .ret = .{ .value = 5 } },
    };
    const choose_blocks = [_]ir.Block{.{ .label = 0, .instructions = &choose_instrs }};

    const apply_params = [_]ir.Param{.{ .name = "f", .type_expr = .any }};
    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .i64 } },
        .{ .ret = .{ .value = 1 } },
    };
    const apply_blocks = [_]ir.Block{.{ .label = 0, .instructions = &apply_instrs }};

    const leaf_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const leaf_blocks = [_]ir.Block{.{ .label = 0, .instructions = &leaf_instrs }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "choose", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .any, .body = &choose_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "apply", .scope_id = 0, .arity = 1, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 3, .name = "fn_a", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &leaf_blocks, .is_closure = true, .captures = &.{} },
        .{ .id = 4, .name = "fn_b", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &leaf_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();
    try analyzer.analyze();

    const key = lattice.ValueKey{ .function = 2, .local = 0 };
    const ls = analyzer.getLambdaSet(key);
    try testing.expect(ls != null);
    try testing.expectEqual(@as(usize, 2), ls.?.size());
    try testing.expect(ls.?.contains(3));
    try testing.expect(ls.?.contains(4));

    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.function == 2 and d.callee_local == 0) {
            try testing.expectEqual(lattice.SpecializationDecision.switch_dispatch, d.decision);
            found = true;
        }
    }
    try testing.expect(found);
}

// Test 8: Large lambda set (>SWITCH_THRESHOLD) -> dyn_closure_dispatch
test "large lambda set yields dyn_closure_dispatch" {
    const allocator = testing.allocator;

    const num_closures = lattice.SWITCH_THRESHOLD + 1;
    const merge_local: ir.LocalId = @intCast(num_closures);

    // Build instructions dynamically
    var main_instrs: std.ArrayList(ir.Instruction) = .empty;
    defer main_instrs.deinit(allocator);

    for (0..num_closures) |i| {
        try main_instrs.append(allocator, .{ .make_closure = .{
            .dest = @intCast(i),
            .function = @intCast(i + 1),
            .captures = &.{},
        } });
    }
    // Use local_get to merge all into merge_local
    for (0..num_closures) |i| {
        try main_instrs.append(allocator, .{ .local_get = .{
            .dest = merge_local,
            .source = @intCast(i),
        } });
    }
    try main_instrs.append(allocator, .{ .call_closure = .{
        .dest = @intCast(merge_local + 1),
        .callee = merge_local,
        .args = &.{},
        .arg_modes = &.{},
        .return_type = .void,
    } });
    try main_instrs.append(allocator, .{ .ret = .{ .value = @intCast(merge_local + 1) } });

    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = main_instrs.items },
    };

    // Build closure functions
    var closure_fns: std.ArrayList(ir.Function) = .empty;
    defer closure_fns.deinit(allocator);

    try closure_fns.append(allocator, .{
        .id = 0,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &main_blocks,
        .is_closure = false,
        .captures = &.{},
    });

    const closure_body_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_body_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_body_instrs },
    };

    for (0..num_closures) |i| {
        try closure_fns.append(allocator, .{
            .id = @intCast(i + 1),
            .name = "closure_fn",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &closure_body_blocks,
            .is_closure = true,
            .captures = &.{},
        });
    }

    const program = ir.Program{
        .functions = closure_fns.items,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Check lambda set at merge_local has all closures
    const key = lattice.ValueKey{ .function = 0, .local = merge_local };
    const ls = analyzer.getLambdaSet(key);
    try testing.expect(ls != null);
    try testing.expectEqual(num_closures, ls.?.size());

    // Check decision: should be dyn_closure_dispatch
    var found = false;
    for (analyzer.call_site_decisions.items) |d| {
        if (d.callee_local == merge_local and d.function == 0) {
            try testing.expectEqual(lattice.SpecializationDecision.dyn_closure_dispatch, d.decision);
            found = true;
        }
    }
    try testing.expect(found);
}

// Test 9: If/else branches creating different closures, merged -> union of lambda sets
test "if_expr branches merge lambda sets" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &.{} } },
        .{ .const_bool = .{ .dest = 2, .value = true } },
        .{ .if_expr = .{
            .dest = 3,
            .condition = 2,
            .then_instrs = &.{},
            .then_result = 0,
            .else_instrs = &.{},
            .else_result = 1,
        } },
        .{ .call_closure = .{ .dest = 4, .callee = 3, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 4 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const cl_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const cl_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &cl_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "fn_a", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
        .{ .id = 2, .name = "fn_b", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // %3 should have the union {fn_a, fn_b}
    const key = lattice.ValueKey{ .function = 0, .local = 3 };
    const ls = analyzer.getLambdaSet(key).?;
    try testing.expectEqual(@as(usize, 2), ls.size());
    try testing.expect(ls.contains(1));
    try testing.expect(ls.contains(2));
}

// Test 10: Phi of two closure bindings -> union
test "phi merges lambda sets" {
    const allocator = testing.allocator;

    const block0_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
    };
    const phi_sources = [_]ir.PhiSource{
        .{ .from_block = 0, .value = 0 },
        .{ .from_block = 1, .value = 1 },
    };
    const block1_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &.{} } },
    };
    const block2_instrs = [_]ir.Instruction{
        .{ .phi = .{ .dest = 2, .sources = &phi_sources } },
        .{ .call_closure = .{ .dest = 3, .callee = 2, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 3 } },
    };

    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &block0_instrs },
        .{ .label = 1, .instructions = &block1_instrs },
        .{ .label = 2, .instructions = &block2_instrs },
    };

    const cl_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const cl_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &cl_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "fn_a", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
        .{ .id = 2, .name = "fn_b", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // %2 should have the union {fn_a, fn_b}
    const key = lattice.ValueKey{ .function = 0, .local = 2 };
    const ls = analyzer.getLambdaSet(key).?;
    try testing.expectEqual(@as(usize, 2), ls.size());
    try testing.expect(ls.contains(1));
    try testing.expect(ls.contains(2));
}

// Test: FunctionIdSet basic operations
test "FunctionIdSet add and contains" {
    const allocator = testing.allocator;
    var set = FunctionIdSet.init(allocator);
    defer set.deinit();

    try testing.expect(set.isEmpty());
    try testing.expectEqual(@as(usize, 0), set.size());

    // Adding new element returns true
    try testing.expect(try set.add(5));
    try testing.expectEqual(@as(usize, 1), set.size());
    try testing.expect(set.contains(5));
    try testing.expect(!set.contains(3));

    // Adding same element returns false
    try testing.expect(!try set.add(5));
    try testing.expectEqual(@as(usize, 1), set.size());

    // Add more elements, verify sorted order
    try testing.expect(try set.add(3));
    try testing.expect(try set.add(7));
    try testing.expect(try set.add(1));
    try testing.expectEqual(@as(usize, 4), set.size());

    // Verify sorted
    try testing.expectEqual(@as(ir.FunctionId, 1), set.members.items[0]);
    try testing.expectEqual(@as(ir.FunctionId, 3), set.members.items[1]);
    try testing.expectEqual(@as(ir.FunctionId, 5), set.members.items[2]);
    try testing.expectEqual(@as(ir.FunctionId, 7), set.members.items[3]);
}

// Test: FunctionIdSet addAll
test "FunctionIdSet addAll merges sets" {
    const allocator = testing.allocator;

    var set_a = FunctionIdSet.init(allocator);
    defer set_a.deinit();
    _ = try set_a.add(1);
    _ = try set_a.add(3);

    var set_b = FunctionIdSet.init(allocator);
    defer set_b.deinit();
    _ = try set_b.add(2);
    _ = try set_b.add(3); // overlap

    try testing.expect(try set_a.addAll(&set_b));
    try testing.expectEqual(@as(usize, 3), set_a.size());
    try testing.expect(set_a.contains(1));
    try testing.expect(set_a.contains(2));
    try testing.expect(set_a.contains(3));

    // Adding same again should not change
    try testing.expect(!try set_a.addAll(&set_b));
}

// Test: FunctionIdSet toLambdaSet
test "FunctionIdSet toLambdaSet" {
    const allocator = testing.allocator;

    var set = FunctionIdSet.init(allocator);
    defer set.deinit();

    // Empty set
    const empty_ls = try set.toLambdaSet(allocator);
    try testing.expect(empty_ls.isEmpty());

    // Non-empty
    _ = try set.add(2);
    _ = try set.add(5);
    const ls = try set.toLambdaSet(allocator);
    defer allocator.free(ls.members);

    try testing.expectEqual(@as(usize, 2), ls.size());
    try testing.expect(ls.contains(2));
    try testing.expect(ls.contains(5));
}

// Test: populateContext
test "populateContext fills AnalysisContext" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const cl_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const cl_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &cl_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "closure_fn", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();
    try analyzer.analyze();

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();

    try analyzer.populateContext(&ctx);

    // Should have a lambda set for main's %0
    const key = lattice.ValueKey{ .function = 0, .local = 0 };
    const ls = ctx.getLambdaSet(key);
    try testing.expect(ls != null);
    try testing.expect(ls.?.contains(1));
}

// Test: call_named resolution
test "call_named resolves to function and propagates" {
    const allocator = testing.allocator;

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 2, .captures = &.{} } },
        .{ .call_named = .{ .dest = 1, .name = "apply", .args = &[_]ir.LocalId{0}, .arg_modes = &.{} } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .void } },
        .{ .ret = .{ .value = 1 } },
    };
    const apply_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &apply_instrs },
    };
    const apply_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .any },
    };

    const cl_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .ret = .{ .value = 0 } },
    };
    const cl_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &cl_instrs },
    };

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "apply", .scope_id = 0, .arity = 0, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "the_closure", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &cl_blocks, .is_closure = true, .captures = &.{} },
    };

    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var analyzer = try LambdaSetAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.analyze();

    // Lambda set at apply's local %0 should contain the_closure (func 2)
    const key = lattice.ValueKey{ .function = 1, .local = 0 };
    const ls = analyzer.getLambdaSet(key);
    try testing.expect(ls != null);
    try testing.expect(ls.?.contains(2));
}
