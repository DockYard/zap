const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");

// ============================================================
// Region-Based Lifetime Solver (Research Plan Phase 4)
//
// Computes minimal region assignments for SSA values using:
//   1. Dominator-tree construction over the implicit CFG
//   2. Constraint generation from IR instructions
//   3. Non-lexical lifetime solving via LCA in dominator tree
//   4. MLKit-inspired multiplicity inference
//   5. MLKit-inspired storage mode analysis
//   6. Region-to-allocation-strategy mapping
// ============================================================

// ============================================================
// Section 1: CFG Extraction
// ============================================================

/// A successor edge in the control-flow graph.
pub const CfgEdge = struct {
    from: ir.LabelId,
    to: ir.LabelId,
};

/// Adjacency representation of a function's control-flow graph.
/// Built from the implicit CFG encoded in IR instructions.
pub const Cfg = struct {
    allocator: std.mem.Allocator,
    /// Successors for each block.
    successors: std.AutoArrayHashMap(ir.LabelId, LabelList),
    /// Predecessors for each block (inverse of successors).
    predecessors: std.AutoArrayHashMap(ir.LabelId, LabelList),
    /// All block labels in the function (in order).
    block_labels: LabelList,

    const LabelList = std.ArrayListUnmanaged(ir.LabelId);

    pub fn init(allocator: std.mem.Allocator) Cfg {
        return .{
            .allocator = allocator,
            .successors = std.AutoArrayHashMap(ir.LabelId, LabelList).init(allocator),
            .predecessors = std.AutoArrayHashMap(ir.LabelId, LabelList).init(allocator),
            .block_labels = .empty,
        };
    }

    pub fn deinit(self: *Cfg) void {
        for (self.successors.values()) |*list| {
            list.deinit(self.allocator);
        }
        self.successors.deinit();
        for (self.predecessors.values()) |*list| {
            list.deinit(self.allocator);
        }
        self.predecessors.deinit();
        self.block_labels.deinit(self.allocator);
    }

    fn ensureNode(self: *Cfg, label: ir.LabelId) !void {
        if (!self.successors.contains(label)) {
            try self.successors.put(label, .empty);
            try self.predecessors.put(label, .empty);
        }
    }

    fn addEdge(self: *Cfg, from: ir.LabelId, to: ir.LabelId) !void {
        try self.ensureNode(from);
        try self.ensureNode(to);
        const succ_list = self.successors.getPtr(from).?;
        // Avoid duplicate edges.
        for (succ_list.items) |s| {
            if (s == to) return;
        }
        try succ_list.append(self.allocator, to);
        const pred_list = self.predecessors.getPtr(to).?;
        try pred_list.append(self.allocator, from);
    }

    /// Build a CFG from a function's block list.
    /// Zap's IR has an implicit CFG: blocks are laid out sequentially,
    /// and control-flow instructions (branch, cond_branch, if_expr,
    /// case_block, etc.) create edges.
    pub fn build(allocator: std.mem.Allocator, func: *const ir.Function) !Cfg {
        var cfg = Cfg.init(allocator);
        errdefer cfg.deinit();

        for (func.body) |block| {
            try cfg.ensureNode(block.label);
            try cfg.block_labels.append(allocator, block.label);
        }

        for (func.body, 0..) |block, block_idx| {
            // Scan instructions for control-flow edges.
            try scanInstructionsForEdges(&cfg, block.label, block.instructions);

            // If the block does not end with a terminator, it falls through
            // to the next block.
            if (block.instructions.len > 0) {
                const last = block.instructions[block.instructions.len - 1];
                if (isTerminator(last)) continue;
            }
            // Fall-through to next block.
            if (block_idx + 1 < func.body.len) {
                try cfg.addEdge(block.label, func.body[block_idx + 1].label);
            }
        }

        return cfg;
    }

    fn scanInstructionsForEdges(cfg: *Cfg, from_label: ir.LabelId, instrs: []const ir.Instruction) !void {
        for (instrs) |instr| {
            switch (instr) {
                .branch => |br| {
                    try cfg.addEdge(from_label, br.target);
                },
                .cond_branch => |cb| {
                    try cfg.addEdge(from_label, cb.then_target);
                    try cfg.addEdge(from_label, cb.else_target);
                },
                .jump => |j| {
                    try cfg.addEdge(from_label, j.target);
                },
                .switch_tag => |st| {
                    for (st.cases) |case| {
                        try cfg.addEdge(from_label, case.target);
                    }
                    try cfg.addEdge(from_label, st.default);
                },
                .if_expr => |ie| {
                    // Nested instruction lists create implicit sub-flows.
                    // For dominator tree purposes, we treat the entire if_expr
                    // as belonging to the parent block (no new block labels created).
                    try scanInstructionsForEdges(cfg, from_label, ie.then_instrs);
                    try scanInstructionsForEdges(cfg, from_label, ie.else_instrs);
                },
                .case_block => |cb| {
                    for (cb.arms) |arm| {
                        try scanInstructionsForEdges(cfg, from_label, arm.cond_instrs);
                        try scanInstructionsForEdges(cfg, from_label, arm.body_instrs);
                    }
                    try scanInstructionsForEdges(cfg, from_label, cb.pre_instrs);
                    try scanInstructionsForEdges(cfg, from_label, cb.default_instrs);
                },
                .guard_block => |gb| {
                    try scanInstructionsForEdges(cfg, from_label, gb.body);
                },
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        try scanInstructionsForEdges(cfg, from_label, case.body_instrs);
                    }
                    try scanInstructionsForEdges(cfg, from_label, sl.default_instrs);
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| {
                        try scanInstructionsForEdges(cfg, from_label, case.body_instrs);
                    }
                    try scanInstructionsForEdges(cfg, from_label, sr.default_instrs);
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| {
                        try scanInstructionsForEdges(cfg, from_label, case.body_instrs);
                    }
                },
                .union_switch => |us| {
                    for (us.cases) |case| {
                        try scanInstructionsForEdges(cfg, from_label, case.body_instrs);
                    }
                },
                else => {},
            }
        }
    }

    fn isTerminator(instr: ir.Instruction) bool {
        return switch (instr) {
            .branch, .cond_branch, .ret, .jump, .switch_tag => true,
            .tail_call => true,
            else => false,
        };
    }

    /// Returns the list of successor labels for a given block.
    pub fn getSuccessors(self: *const Cfg, label: ir.LabelId) []const ir.LabelId {
        if (self.successors.getPtr(label)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// Returns the list of predecessor labels for a given block.
    pub fn getPredecessors(self: *const Cfg, label: ir.LabelId) []const ir.LabelId {
        if (self.predecessors.getPtr(label)) |list| {
            return list.items;
        }
        return &.{};
    }
};

// ============================================================
// Section 2: Dominator Tree
// ============================================================

/// Dominator tree for a function's CFG.
/// Computed using the iterative dominator algorithm (Cooper, Harvey, Kennedy).
pub const DominatorTree = struct {
    allocator: std.mem.Allocator,
    /// Immediate dominator for each block (indexed by block label).
    idom: std.AutoArrayHashMap(ir.LabelId, ir.LabelId),
    /// Depth of each block in the dominator tree.
    depth: std.AutoArrayHashMap(ir.LabelId, u32),
    /// Entry block label.
    entry: ir.LabelId,
    /// Reverse postorder numbering for the iterative algorithm.
    rpo_number: std.AutoArrayHashMap(ir.LabelId, u32),

    pub fn init(allocator: std.mem.Allocator) DominatorTree {
        return .{
            .allocator = allocator,
            .idom = std.AutoArrayHashMap(ir.LabelId, ir.LabelId).init(allocator),
            .depth = std.AutoArrayHashMap(ir.LabelId, u32).init(allocator),
            .entry = 0,
            .rpo_number = std.AutoArrayHashMap(ir.LabelId, u32).init(allocator),
        };
    }

    pub fn deinit(self: *DominatorTree) void {
        self.idom.deinit();
        self.depth.deinit();
        self.rpo_number.deinit();
    }

    /// Build the dominator tree from a function using Cooper-Harvey-Kennedy
    /// iterative algorithm. O(n^2) in the worst case but fast in practice.
    pub fn build(allocator: std.mem.Allocator, func: *const ir.Function) !DominatorTree {
        var cfg = try Cfg.build(allocator, func);
        defer cfg.deinit();
        return buildFromCfg(allocator, &cfg);
    }

    /// Build from an already-constructed CFG.
    pub fn buildFromCfg(allocator: std.mem.Allocator, cfg: *const Cfg) !DominatorTree {
        var tree = DominatorTree.init(allocator);
        errdefer tree.deinit();

        if (cfg.block_labels.items.len == 0) return tree;

        tree.entry = cfg.block_labels.items[0];

        // Step 1: Compute reverse postorder (RPO) via DFS.
        var rpo: std.ArrayListUnmanaged(ir.LabelId) = .empty;
        defer rpo.deinit(allocator);
        var visited = std.AutoArrayHashMap(ir.LabelId, void).init(allocator);
        defer visited.deinit();

        try dfsPostorder(allocator, cfg, tree.entry, &visited, &rpo);

        // rpo now has postorder; reverse it.
        std.mem.reverse(ir.LabelId, rpo.items);

        // Assign RPO numbers.
        for (rpo.items, 0..) |label, i| {
            try tree.rpo_number.put(label, @intCast(i));
        }

        // Step 2: Initialize idom. Entry dominates itself.
        const sentinel: ir.LabelId = std.math.maxInt(ir.LabelId);
        for (rpo.items) |label| {
            try tree.idom.put(label, sentinel);
        }
        tree.idom.getPtr(tree.entry).?.* = tree.entry;

        // Step 3: Iterate until convergence.
        var changed = true;
        while (changed) {
            changed = false;
            for (rpo.items) |b| {
                if (b == tree.entry) continue;

                const preds = cfg.getPredecessors(b);
                if (preds.len == 0) continue;

                // Find first processed predecessor.
                var new_idom: ir.LabelId = sentinel;
                for (preds) |p| {
                    if (tree.idom.get(p)) |idom_p| {
                        if (idom_p != sentinel) {
                            new_idom = p;
                            break;
                        }
                    }
                }
                if (new_idom == sentinel) continue;

                // Intersect with remaining predecessors.
                for (preds) |p| {
                    if (p == new_idom) continue;
                    if (tree.idom.get(p)) |idom_p| {
                        if (idom_p != sentinel) {
                            new_idom = tree.intersect(new_idom, p);
                        }
                    }
                }

                const current_idom = tree.idom.get(b) orelse sentinel;
                if (current_idom != new_idom) {
                    tree.idom.getPtr(b).?.* = new_idom;
                    changed = true;
                }
            }
        }

        // Step 4: Compute depths.
        for (rpo.items) |label| {
            _ = try tree.computeDepth(label);
        }

        return tree;
    }

    fn dfsPostorder(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        node: ir.LabelId,
        visited: *std.AutoArrayHashMap(ir.LabelId, void),
        postorder: *std.ArrayListUnmanaged(ir.LabelId),
    ) !void {
        if (visited.contains(node)) return;
        try visited.put(node, {});
        for (cfg.getSuccessors(node)) |succ| {
            try dfsPostorder(allocator, cfg, succ, visited, postorder);
        }
        try postorder.append(allocator, node);
    }

    /// Intersect two nodes to find their common dominator.
    fn intersect(self: *const DominatorTree, a_in: ir.LabelId, b_in: ir.LabelId) ir.LabelId {
        var a = a_in;
        var b = b_in;
        const rpo = &self.rpo_number;
        while (a != b) {
            const a_num = rpo.get(a) orelse return self.entry;
            const b_num = rpo.get(b) orelse return self.entry;
            if (a_num > b_num) {
                a = self.idom.get(a) orelse return self.entry;
            } else {
                b = self.idom.get(b) orelse return self.entry;
            }
        }
        return a;
    }

    fn computeDepth(self: *DominatorTree, label: ir.LabelId) !u32 {
        if (self.depth.get(label)) |d| return d;
        if (label == self.entry) {
            try self.depth.put(label, 0);
            return 0;
        }
        const parent = self.idom.get(label) orelse {
            try self.depth.put(label, 0);
            return 0;
        };
        if (parent == label) {
            try self.depth.put(label, 0);
            return 0;
        }
        const parent_depth = try self.computeDepth(parent);
        const d = parent_depth + 1;
        try self.depth.put(label, d);
        return d;
    }

    /// Get the immediate dominator of a block. Returns null for the entry block.
    pub fn getIdom(self: *const DominatorTree, block: ir.LabelId) ?ir.LabelId {
        const idom_val = self.idom.get(block) orelse return null;
        if (idom_val == block) return null; // Entry node.
        return idom_val;
    }

    /// Compute the lowest common ancestor of two blocks in the dominator tree.
    pub fn lca(self: *const DominatorTree, a: ir.LabelId, b: ir.LabelId) ir.LabelId {
        return self.intersect(a, b);
    }

    /// Returns true if block `a` dominates block `b`.
    pub fn dominates(self: *const DominatorTree, a: ir.LabelId, b: ir.LabelId) bool {
        if (a == b) return true;
        // Walk up from b until we reach a or the entry.
        var current = b;
        while (true) {
            const parent = self.idom.get(current) orelse return false;
            if (parent == current) return a == current;
            if (parent == a) return true;
            current = parent;
        }
    }

    /// Returns true if `block` is in a loop. A block is in a loop if
    /// any of its successors dominates it (back-edge).
    pub fn isInLoop(self: *const DominatorTree, block: ir.LabelId, cfg: *const Cfg) bool {
        for (cfg.getSuccessors(block)) |succ| {
            if (self.dominates(succ, block)) return true;
        }
        return false;
    }

    /// Get the depth of a block in the dominator tree.
    pub fn getDepth(self: *const DominatorTree, block: ir.LabelId) u32 {
        return self.depth.get(block) orelse 0;
    }
};

// ============================================================
// Section 3: Use-Def Information
// ============================================================

/// Tracks definition and use sites for each local in a function.
pub const UseDefInfo = struct {
    allocator: std.mem.Allocator,
    /// Block where each local is defined.
    def_block: std.AutoArrayHashMap(ir.LocalId, ir.LabelId),
    /// Blocks where each local is used.
    use_blocks: std.AutoArrayHashMap(ir.LocalId, std.ArrayListUnmanaged(ir.LabelId)),

    pub fn init(allocator: std.mem.Allocator) UseDefInfo {
        return .{
            .allocator = allocator,
            .def_block = std.AutoArrayHashMap(ir.LocalId, ir.LabelId).init(allocator),
            .use_blocks = std.AutoArrayHashMap(ir.LocalId, std.ArrayListUnmanaged(ir.LabelId)).init(allocator),
        };
    }

    pub fn deinit(self: *UseDefInfo) void {
        self.def_block.deinit();
        for (self.use_blocks.values()) |*list| {
            list.deinit(self.allocator);
        }
        self.use_blocks.deinit();
    }

    /// Build use-def info for a function by scanning all blocks.
    pub fn build(allocator: std.mem.Allocator, func: *const ir.Function) !UseDefInfo {
        var info = UseDefInfo.init(allocator);
        errdefer info.deinit();

        for (func.body) |block| {
            try scanInstructionsForUseDef(&info, block.label, block.instructions);
        }

        return info;
    }

    fn recordDef(self: *UseDefInfo, local: ir.LocalId, block: ir.LabelId) !void {
        // First definition wins (SSA property).
        if (!self.def_block.contains(local)) {
            try self.def_block.put(local, block);
        }
    }

    fn recordUse(self: *UseDefInfo, local: ir.LocalId, block: ir.LabelId) !void {
        const result = try self.use_blocks.getOrPut(local);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, block);
    }

    fn scanInstructionsForUseDef(info: *UseDefInfo, block: ir.LabelId, instrs: []const ir.Instruction) error{OutOfMemory}!void {
        for (instrs) |instr| {
            try scanSingleInstruction(info, block, instr);
        }
    }

    fn scanSingleInstruction(info: *UseDefInfo, block: ir.LabelId, instr: ir.Instruction) error{OutOfMemory}!void {
        switch (instr) {
            // Constants define a dest.
            .const_int => |ci| try info.recordDef(ci.dest, block),
            .const_float => |cf| try info.recordDef(cf.dest, block),
            .const_string => |cs| try info.recordDef(cs.dest, block),
            .const_bool => |cb| try info.recordDef(cb.dest, block),
            .const_atom => |ca| try info.recordDef(ca.dest, block),
            .const_nil => |dest| try info.recordDef(dest, block),

            // Local operations.
            .local_get => |lg| {
                try info.recordDef(lg.dest, block);
                try info.recordUse(lg.source, block);
            },
            .local_set => |ls| {
                try info.recordDef(ls.dest, block);
                try info.recordUse(ls.value, block);
            },
            .move_value => |mv| {
                try info.recordDef(mv.dest, block);
                try info.recordUse(mv.source, block);
            },
            .share_value => |sv| {
                try info.recordDef(sv.dest, block);
                try info.recordUse(sv.source, block);
            },
            .reset => |r| {
                try info.recordDef(r.dest, block);
                try info.recordUse(r.source, block);
            },
            .reuse_alloc => |ra| {
                try info.recordDef(ra.dest, block);
                if (ra.token) |t| try info.recordUse(t, block);
            },
            .param_get => |pg| try info.recordDef(pg.dest, block),

            // Aggregate constructors.
            .tuple_init, .list_init => |ai| {
                try info.recordDef(ai.dest, block);
                for (ai.elements) |elem| {
                    try info.recordUse(elem, block);
                }
            },
            .map_init => |mi| {
                try info.recordDef(mi.dest, block);
                for (mi.entries) |entry| {
                    try info.recordUse(entry.key, block);
                    try info.recordUse(entry.value, block);
                }
            },
            .struct_init => |si| {
                try info.recordDef(si.dest, block);
                for (si.fields) |field| {
                    try info.recordUse(field.value, block);
                }
            },
            .union_init => |ui| {
                try info.recordDef(ui.dest, block);
                try info.recordUse(ui.value, block);
            },
            .enum_literal => |el| try info.recordDef(el.dest, block),

            // Field access.
            .field_get => |fg| {
                try info.recordDef(fg.dest, block);
                try info.recordUse(fg.object, block);
            },
            .field_set => |fs| {
                try info.recordUse(fs.object, block);
                try info.recordUse(fs.value, block);
            },
            .index_get => |ig| {
                try info.recordDef(ig.dest, block);
                try info.recordUse(ig.object, block);
            },
            .list_len_check => |llc| {
                try info.recordDef(llc.dest, block);
                try info.recordUse(llc.scrutinee, block);
            },
            .list_get => |lg| {
                try info.recordDef(lg.dest, block);
                try info.recordUse(lg.list, block);
            },
            .map_has_key => |mhk| {
                try info.recordDef(mhk.dest, block);
                try info.recordUse(mhk.map, block);
                try info.recordUse(mhk.key, block);
            },
            .map_get => |mg| {
                try info.recordDef(mg.dest, block);
                try info.recordUse(mg.map, block);
                try info.recordUse(mg.key, block);
                try info.recordUse(mg.default, block);
            },

            // Arithmetic / logic.
            .binary_op => |bo| {
                try info.recordDef(bo.dest, block);
                try info.recordUse(bo.lhs, block);
                try info.recordUse(bo.rhs, block);
            },
            .unary_op => |uo| {
                try info.recordDef(uo.dest, block);
                try info.recordUse(uo.operand, block);
            },

            // Calls.
            .call_direct => |cd| {
                try info.recordDef(cd.dest, block);
                for (cd.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .call_named => |cn| {
                try info.recordDef(cn.dest, block);
                for (cn.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .try_call_named => |tcn| {
                try info.recordDef(tcn.dest, block);
                for (tcn.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .call_closure => |cc| {
                try info.recordDef(cc.dest, block);
                try info.recordUse(cc.callee, block);
                for (cc.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .call_dispatch => |cd| {
                try info.recordDef(cd.dest, block);
                for (cd.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .call_builtin => |cb| {
                try info.recordDef(cb.dest, block);
                for (cb.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },
            .tail_call => |tc| {
                for (tc.args) |arg| {
                    try info.recordUse(arg, block);
                }
            },

            // Control flow.
            .if_expr => |ie| {
                try info.recordDef(ie.dest, block);
                try info.recordUse(ie.condition, block);
                try scanInstructionsForUseDef(info, block, ie.then_instrs);
                try scanInstructionsForUseDef(info, block, ie.else_instrs);
                if (ie.then_result) |tr| try info.recordUse(tr, block);
                if (ie.else_result) |er| try info.recordUse(er, block);
            },
            .case_block => |cb| {
                try info.recordDef(cb.dest, block);
                try scanInstructionsForUseDef(info, block, cb.pre_instrs);
                for (cb.arms) |arm| {
                    try info.recordUse(arm.condition, block);
                    try scanInstructionsForUseDef(info, block, arm.cond_instrs);
                    try scanInstructionsForUseDef(info, block, arm.body_instrs);
                    if (arm.result) |r| try info.recordUse(r, block);
                }
                try scanInstructionsForUseDef(info, block, cb.default_instrs);
                if (cb.default_result) |dr| try info.recordUse(dr, block);
            },
            .guard_block => |gb| {
                try info.recordUse(gb.condition, block);
                try scanInstructionsForUseDef(info, block, gb.body);
            },
            .switch_literal => |sl| {
                try info.recordDef(sl.dest, block);
                try info.recordUse(sl.scrutinee, block);
                for (sl.cases) |case| {
                    try scanInstructionsForUseDef(info, block, case.body_instrs);
                    if (case.result) |r| try info.recordUse(r, block);
                }
                try scanInstructionsForUseDef(info, block, sl.default_instrs);
                if (sl.default_result) |dr| try info.recordUse(dr, block);
            },
            .switch_return => |sr| {
                for (sr.cases) |case| {
                    try scanInstructionsForUseDef(info, block, case.body_instrs);
                    if (case.return_value) |rv| try info.recordUse(rv, block);
                }
                try scanInstructionsForUseDef(info, block, sr.default_instrs);
                if (sr.default_result) |dr| try info.recordUse(dr, block);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    try scanInstructionsForUseDef(info, block, case.body_instrs);
                    if (case.return_value) |rv| try info.recordUse(rv, block);
                }
            },
            .union_switch => |us| {
                try info.recordDef(us.dest, block);
                try info.recordUse(us.scrutinee, block);
                for (us.cases) |case| {
                    try scanInstructionsForUseDef(info, block, case.body_instrs);
                    if (case.return_value) |rv| try info.recordUse(rv, block);
                }
            },

            .ret => |ret_instr| {
                if (ret_instr.value) |v| try info.recordUse(v, block);
            },
            .cond_return => |cr| {
                try info.recordUse(cr.condition, block);
                if (cr.value) |v| try info.recordUse(v, block);
            },
            .case_break => |cb| {
                if (cb.value) |v| try info.recordUse(v, block);
            },
            .cond_branch => |cb| {
                try info.recordUse(cb.condition, block);
            },
            .switch_tag => |st| {
                try info.recordUse(st.scrutinee, block);
            },

            // Closures.
            .make_closure => |mc| {
                try info.recordDef(mc.dest, block);
                for (mc.captures) |cap| {
                    try info.recordUse(cap, block);
                }
            },
            .capture_get => |cg| try info.recordDef(cg.dest, block),

            // Phi.
            .phi => |p| {
                try info.recordDef(p.dest, block);
                for (p.sources) |src| {
                    try info.recordUse(src.value, block);
                }
            },

            // Optional unwrap.
            .optional_unwrap => |ou| {
                try info.recordDef(ou.dest, block);
                try info.recordUse(ou.source, block);
            },

            // Error catch: defines dest, uses source and catch_value.
            .error_catch => |ec| {
                try info.recordDef(ec.dest, block);
                try info.recordUse(ec.source, block);
                try info.recordUse(ec.catch_value, block);
            },

            // Pattern matching.
            .match_atom => |ma| {
                try info.recordDef(ma.dest, block);
                try info.recordUse(ma.scrutinee, block);
            },
            .match_int => |mi| {
                try info.recordDef(mi.dest, block);
                try info.recordUse(mi.scrutinee, block);
            },
            .match_float => |mf| {
                try info.recordDef(mf.dest, block);
                try info.recordUse(mf.scrutinee, block);
            },
            .match_string => |ms| {
                try info.recordDef(ms.dest, block);
                try info.recordUse(ms.scrutinee, block);
            },
            .match_type => |mt| {
                try info.recordDef(mt.dest, block);
                try info.recordUse(mt.scrutinee, block);
            },

            // Memory / ARC.
            .retain => |r| try info.recordUse(r.value, block),
            .release => |r| try info.recordUse(r.value, block),

            // Binary pattern matching.
            .bin_len_check => |blc| {
                try info.recordDef(blc.dest, block);
                try info.recordUse(blc.scrutinee, block);
            },
            .bin_read_int => |bri| {
                try info.recordDef(bri.dest, block);
                try info.recordUse(bri.source, block);
                switch (bri.offset) {
                    .dynamic => |d| try info.recordUse(d, block),
                    .static => {},
                }
            },
            .bin_read_float => |brf| {
                try info.recordDef(brf.dest, block);
                try info.recordUse(brf.source, block);
                switch (brf.offset) {
                    .dynamic => |d| try info.recordUse(d, block),
                    .static => {},
                }
            },
            .bin_slice => |bs| {
                try info.recordDef(bs.dest, block);
                try info.recordUse(bs.source, block);
                switch (bs.offset) {
                    .dynamic => |d| try info.recordUse(d, block),
                    .static => {},
                }
                if (bs.length) |len| {
                    switch (len) {
                        .dynamic => |d| try info.recordUse(d, block),
                        .static => {},
                    }
                }
            },
            .bin_read_utf8 => |bru| {
                try info.recordDef(bru.dest_codepoint, block);
                try info.recordDef(bru.dest_len, block);
                try info.recordUse(bru.source, block);
                switch (bru.offset) {
                    .dynamic => |d| try info.recordUse(d, block),
                    .static => {},
                }
            },
            .bin_match_prefix => |bmp| {
                try info.recordDef(bmp.dest, block);
                try info.recordUse(bmp.source, block);
            },

            // Non-data instructions.
            .branch, .jump, .match_fail, .match_error_return => {},
        }
    }

    /// Get all blocks where a local is used.
    pub fn getUseBlocks(self: *const UseDefInfo, local: ir.LocalId) []const ir.LabelId {
        if (self.use_blocks.getPtr(local)) |list| {
            return list.items;
        }
        return &.{};
    }

    /// Get the block where a local is defined.
    pub fn getDefBlock(self: *const UseDefInfo, local: ir.LocalId) ?ir.LabelId {
        return self.def_block.get(local);
    }
};

/// CFG-aware live block computation for a single SSA value.
/// Computes the set of blocks on paths from the value's definition to any use,
/// which is a closer approximation to non-lexical lifetime regions than using
/// only the LCA of def/use blocks.
pub const LiveBlockSet = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoArrayHashMap(ir.LabelId, void),

    pub fn init(allocator: std.mem.Allocator) LiveBlockSet {
        return .{
            .allocator = allocator,
            .blocks = std.AutoArrayHashMap(ir.LabelId, void).init(allocator),
        };
    }

    pub fn deinit(self: *LiveBlockSet) void {
        self.blocks.deinit();
    }

    pub fn contains(self: *const LiveBlockSet, block: ir.LabelId) bool {
        return self.blocks.contains(block);
    }

    pub fn compute(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        use_def: *const UseDefInfo,
        local: ir.LocalId,
    ) !LiveBlockSet {
        var live = LiveBlockSet.init(allocator);
        errdefer live.deinit();

        const def_block = use_def.getDefBlock(local) orelse return live;
        var worklist: std.ArrayListUnmanaged(ir.LabelId) = .empty;
        defer worklist.deinit(allocator);

        try live.blocks.put(def_block, {});
        for (use_def.getUseBlocks(local)) |use_block| {
            try worklist.append(allocator, use_block);
        }

        while (worklist.items.len > 0) {
            const block = worklist.pop() orelse break;
            if (live.blocks.contains(block)) continue;
            try live.blocks.put(block, {});
            if (block == def_block) continue;
            for (cfg.getPredecessors(block)) |pred| {
                if (!live.blocks.contains(pred)) {
                    try worklist.append(allocator, pred);
                }
            }
        }

        return live;
    }
};

/// Per-local block liveness over the CFG.
/// This gives a CFG-aware approximation of non-lexical live ranges, including
/// loop-carried values that are live into a header on the next iteration.
pub const LocalBlockLiveness = struct {
    allocator: std.mem.Allocator,
    live_in: std.AutoArrayHashMap(ir.LabelId, bool),
    live_out: std.AutoArrayHashMap(ir.LabelId, bool),

    pub fn init(allocator: std.mem.Allocator) LocalBlockLiveness {
        return .{
            .allocator = allocator,
            .live_in = std.AutoArrayHashMap(ir.LabelId, bool).init(allocator),
            .live_out = std.AutoArrayHashMap(ir.LabelId, bool).init(allocator),
        };
    }

    pub fn deinit(self: *LocalBlockLiveness) void {
        self.live_in.deinit();
        self.live_out.deinit();
    }

    pub fn isLiveIn(self: *const LocalBlockLiveness, block: ir.LabelId) bool {
        return self.live_in.get(block) orelse false;
    }

    pub fn isLiveOut(self: *const LocalBlockLiveness, block: ir.LabelId) bool {
        return self.live_out.get(block) orelse false;
    }

    pub fn build(
        allocator: std.mem.Allocator,
        cfg: *const Cfg,
        func: *const ir.Function,
        local: ir.LocalId,
    ) !LocalBlockLiveness {
        var result = LocalBlockLiveness.init(allocator);
        errdefer result.deinit();

        var use_before_def = std.AutoArrayHashMap(ir.LabelId, bool).init(allocator);
        defer use_before_def.deinit();
        var kill = std.AutoArrayHashMap(ir.LabelId, bool).init(allocator);
        defer kill.deinit();

        for (func.body) |block| {
            const summary = summarizeBlockLocalUsage(local, block.instructions);
            try use_before_def.put(block.label, summary.use_before_def);
            try kill.put(block.label, summary.defines_local);
            try result.live_in.put(block.label, false);
            try result.live_out.put(block.label, false);
        }

        var changed = true;
        while (changed) {
            changed = false;
            var idx: usize = cfg.block_labels.items.len;
            while (idx > 0) {
                idx -= 1;
                const block = cfg.block_labels.items[idx];

                var out = false;
                for (cfg.getSuccessors(block)) |succ| {
                    if (result.isLiveIn(succ)) {
                        out = true;
                        break;
                    }
                }

                const in = (use_before_def.get(block) orelse false) or (out and !(kill.get(block) orelse false));
                if (result.live_out.getPtr(block)) |ptr| {
                    if (ptr.* != out) {
                        ptr.* = out;
                        changed = true;
                    }
                }
                if (result.live_in.getPtr(block)) |ptr| {
                    if (ptr.* != in) {
                        ptr.* = in;
                        changed = true;
                    }
                }
            }
        }

        return result;
    }
};

const BlockLocalUsage = struct {
    use_before_def: bool,
    defines_local: bool,
};

fn summarizeBlockLocalUsage(local: ir.LocalId, instrs: []const ir.Instruction) BlockLocalUsage {
    var defined = false;
    var use_before_def = false;
    var defines_local = false;
    for (instrs) |instr| {
        if (!defined and instructionUsesLocal(local, instr)) {
            use_before_def = true;
        }
        if (instructionDefinesLocal(local, instr)) {
            defined = true;
            defines_local = true;
        }
    }
    return .{ .use_before_def = use_before_def, .defines_local = defines_local };
}

fn instructionDefinesLocal(local: ir.LocalId, instr: ir.Instruction) bool {
    const dest = RegionSolver.getInstructionDest(instr);
    return dest != null and dest.? == local;
}

fn instructionUsesLocal(local: ir.LocalId, instr: ir.Instruction) bool {
    switch (instr) {
        .local_get => |lg| return lg.source == local,
        .local_set => |ls| return ls.value == local,
        .move_value => |mv| return mv.source == local,
        .share_value => |sv| return sv.source == local,
        .reset => |r| return r.source == local,
        .reuse_alloc => |ra| return ra.token != null and ra.token.? == local,
        .field_get => |fg| return fg.object == local,
        .field_set => |fs| return fs.object == local or fs.value == local,
        .index_get => |ig| return ig.object == local,
        .list_len_check => |llc| return llc.scrutinee == local,
        .list_get => |lg| return lg.list == local,
        .map_has_key => |mhk| return mhk.map == local or mhk.key == local,
        .map_get => |mg| return mg.map == local or mg.key == local or mg.default == local,
        .binary_op => |bo| return bo.lhs == local or bo.rhs == local,
        .unary_op => |uo| return uo.operand == local,
        .call_direct => |cd| {
            for (cd.args) |arg| if (arg == local) return true;
            return false;
        },
        .call_named => |cn| {
            for (cn.args) |arg| if (arg == local) return true;
            return false;
        },
        .call_closure => |cc| {
            if (cc.callee == local) return true;
            for (cc.args) |arg| if (arg == local) return true;
            return false;
        },
        .call_dispatch => |cd| {
            for (cd.args) |arg| if (arg == local) return true;
            return false;
        },
        .call_builtin => |cb| {
            for (cb.args) |arg| if (arg == local) return true;
            return false;
        },
        .tail_call => |tc| {
            for (tc.args) |arg| if (arg == local) return true;
            return false;
        },
        .if_expr => |ie| {
            if (ie.condition == local) return true;
            if (ie.then_result != null and ie.then_result.? == local) return true;
            if (ie.else_result != null and ie.else_result.? == local) return true;
            return containsLocalUse(local, ie.then_instrs) or containsLocalUse(local, ie.else_instrs);
        },
        .case_block => |cb| {
            if (containsLocalUse(local, cb.pre_instrs) or containsLocalUse(local, cb.default_instrs)) return true;
            if (cb.default_result != null and cb.default_result.? == local) return true;
            for (cb.arms) |arm| {
                if (arm.condition == local) return true;
                if (arm.result != null and arm.result.? == local) return true;
                if (containsLocalUse(local, arm.cond_instrs) or containsLocalUse(local, arm.body_instrs)) return true;
            }
            return false;
        },
        .guard_block => |gb| return gb.condition == local or containsLocalUse(local, gb.body),
        .switch_literal => |sl| {
            if (sl.scrutinee == local) return true;
            if (containsLocalUse(local, sl.default_instrs)) return true;
            if (sl.default_result != null and sl.default_result.? == local) return true;
            for (sl.cases) |case| {
                if (case.result != null and case.result.? == local) return true;
                if (containsLocalUse(local, case.body_instrs)) return true;
            }
            return false;
        },
        .switch_return => |sr| {
            if (containsLocalUse(local, sr.default_instrs)) return true;
            if (sr.default_result != null and sr.default_result.? == local) return true;
            for (sr.cases) |case| {
                if (case.return_value != null and case.return_value.? == local) return true;
                if (containsLocalUse(local, case.body_instrs)) return true;
            }
            return false;
        },
        .union_switch_return => |usr| {
            for (usr.cases) |case| {
                if (case.return_value != null and case.return_value.? == local) return true;
                if (containsLocalUse(local, case.body_instrs)) return true;
            }
            return false;
        },
        .union_switch => |us| {
            if (us.dest == local or us.scrutinee == local) return true;
            for (us.cases) |case| {
                if (case.return_value != null and case.return_value.? == local) return true;
                if (containsLocalUse(local, case.body_instrs)) return true;
            }
            return false;
        },
        .ret => |ret_instr| return ret_instr.value != null and ret_instr.value.? == local,
        .cond_return => |cr| return cr.condition == local or (cr.value != null and cr.value.? == local),
        .case_break => |cb| return cb.value != null and cb.value.? == local,
        .cond_branch => |cb| return cb.condition == local,
        .switch_tag => |st| return st.scrutinee == local,
        .make_closure => |mc| {
            for (mc.captures) |cap| if (cap == local) return true;
            return false;
        },
        .tuple_init, .list_init => |ai| {
            for (ai.elements) |elem| if (elem == local) return true;
            return false;
        },
        .map_init => |mi| {
            for (mi.entries) |entry| if (entry.key == local or entry.value == local) return true;
            return false;
        },
        .struct_init => |si| {
            for (si.fields) |field| if (field.value == local) return true;
            return false;
        },
        .union_init => |ui| return ui.value == local,
        .optional_unwrap => |ou| return ou.source == local,
        .match_atom => |ma| return ma.scrutinee == local,
        .match_int => |mi| return mi.scrutinee == local,
        .match_float => |mf| return mf.scrutinee == local,
        .match_string => |ms| return ms.scrutinee == local,
        .match_type => |mt| return mt.scrutinee == local,
        .phi => |p| {
            for (p.sources) |src| if (src.value == local) return true;
            return false;
        },
        .retain => |r| return r.value == local,
        .release => |r| return r.value == local,
        .bin_len_check => |blc| return blc.scrutinee == local,
        .bin_read_int => |bri| return bri.source == local or (bri.offset == .dynamic and bri.offset.dynamic == local),
        .bin_read_float => |brf| return brf.source == local or (brf.offset == .dynamic and brf.offset.dynamic == local),
        .bin_slice => |bs| {
            if (bs.source == local) return true;
            if (bs.offset == .dynamic and bs.offset.dynamic == local) return true;
            if (bs.length) |len| if (len == .dynamic and len.dynamic == local) return true;
            return false;
        },
        .bin_read_utf8 => |bru| return bru.source == local or (bru.offset == .dynamic and bru.offset.dynamic == local),
        .bin_match_prefix => |bmp| return bmp.source == local,
        else => return false,
    }
}

fn containsLocalUse(local: ir.LocalId, instrs: []const ir.Instruction) bool {
    for (instrs) |instr| {
        if (instructionUsesLocal(local, instr)) return true;
    }
    return false;
}

// ============================================================
// Section 4: Constraint Generator
// ============================================================

/// Walks IR and generates outlives constraints for region solving.
pub const ConstraintGenerator = struct {
    allocator: std.mem.Allocator,
    function_id: ir.FunctionId,
    constraints: std.ArrayListUnmanaged(lattice.OutlivesConstraint),
    /// Region assignments built so far (values -> regions).
    region_of: std.AutoArrayHashMap(ir.LocalId, lattice.RegionId),

    pub fn init(allocator: std.mem.Allocator, function_id: ir.FunctionId) ConstraintGenerator {
        return .{
            .allocator = allocator,
            .function_id = function_id,
            .constraints = .empty,
            .region_of = std.AutoArrayHashMap(ir.LocalId, lattice.RegionId).init(allocator),
        };
    }

    pub fn deinit(self: *ConstraintGenerator) void {
        self.constraints.deinit(self.allocator);
        self.region_of.deinit();
    }

    /// Get the region assigned to a local, defaulting to function_frame.
    fn regionOf(self: *const ConstraintGenerator, local: ir.LocalId) lattice.RegionId {
        return self.region_of.get(local) orelse .function_frame;
    }

    /// Add an outlives constraint.
    fn addConstraint(self: *ConstraintGenerator, longer: lattice.RegionId, shorter: lattice.RegionId, reason: lattice.OutlivesReason) !void {
        // Skip trivial constraints where both sides are the same.
        if (longer == shorter) return;
        try self.constraints.append(self.allocator, .{
            .longer = longer,
            .shorter = shorter,
            .reason = reason,
        });
    }

    /// Generate constraints for all blocks in a function.
    pub fn generateForFunction(self: *ConstraintGenerator, func: *const ir.Function) !void {
        for (func.body) |block| {
            try self.generateForInstructions(block.label, block.instructions);
        }
    }

    fn generateForInstructions(self: *ConstraintGenerator, block_label: ir.LabelId, instrs: []const ir.Instruction) error{OutOfMemory}!void {
        for (instrs) |instr| {
            try self.generateForInstruction(block_label, instr);
        }
    }

    fn generateForInstruction(self: *ConstraintGenerator, block_label: ir.LabelId, instr: ir.Instruction) error{OutOfMemory}!void {
        _ = block_label;
        switch (instr) {
            // Assignment: local_get (dest = source copy).
            // region(source) must outlive region(dest).
            .local_get => |lg| {
                const src_region = self.regionOf(lg.source);
                const dst_region = self.regionOf(lg.dest);
                try self.addConstraint(src_region, dst_region, .assignment);
            },

            // Assignment: local_set (dest = value).
            .local_set => |ls| {
                const val_region = self.regionOf(ls.value);
                const dst_region = self.regionOf(ls.dest);
                try self.addConstraint(val_region, dst_region, .assignment);
            },

            // Return: returned value must outlive the function (-> heap).
            .ret => |ret_instr| {
                if (ret_instr.value) |v| {
                    const val_region = self.regionOf(v);
                    try self.addConstraint(val_region, .heap, .return_value);
                }
            },

            // Conditional return.
            .cond_return => |cr| {
                if (cr.value) |v| {
                    const val_region = self.regionOf(v);
                    try self.addConstraint(val_region, .heap, .return_value);
                }
            },

            // Phi: dest = phi(sources...). All source regions must outlive dest region.
            .phi => |p| {
                const dest_region = self.regionOf(p.dest);
                for (p.sources) |src| {
                    const src_region = self.regionOf(src.value);
                    try self.addConstraint(src_region, dest_region, .phi_merge);
                }
            },

            // Store: container.field = value.
            // region(value) must outlive region(container).
            .field_set => |fs| {
                const val_region = self.regionOf(fs.value);
                const container_region = self.regionOf(fs.object);
                try self.addConstraint(val_region, container_region, .store_into_container);
            },

            // Calls: argument regions may need to outlive callee.
            .call_direct => |cd| {
                for (cd.args) |arg| {
                    const arg_region = self.regionOf(arg);
                    // Conservative: arguments must outlive the call (function_frame).
                    try self.addConstraint(arg_region, .function_frame, .call_argument);
                }
            },
            .call_named => |cn| {
                for (cn.args) |arg| {
                    const arg_region = self.regionOf(arg);
                    try self.addConstraint(arg_region, .function_frame, .call_argument);
                }
            },
            .call_closure => |cc| {
                try self.addConstraint(self.regionOf(cc.callee), .function_frame, .call_argument);
                for (cc.args) |arg| {
                    const arg_region = self.regionOf(arg);
                    try self.addConstraint(arg_region, .function_frame, .call_argument);
                }
            },
            .call_dispatch => |cd| {
                for (cd.args) |arg| {
                    const arg_region = self.regionOf(arg);
                    try self.addConstraint(arg_region, .function_frame, .call_argument);
                }
            },
            .call_builtin => |cb| {
                for (cb.args) |arg| {
                    const arg_region = self.regionOf(arg);
                    try self.addConstraint(arg_region, .function_frame, .call_argument);
                }
            },

            // Closure captures: captured values must outlive the closure.
            .make_closure => |mc| {
                const closure_region = self.regionOf(mc.dest);
                for (mc.captures) |cap| {
                    const cap_region = self.regionOf(cap);
                    try self.addConstraint(cap_region, closure_region, .store_into_container);
                }
            },

            // Nested control flow: recurse into sub-instruction lists.
            .if_expr => |ie| {
                // Results flow into dest.
                const dest_region = self.regionOf(ie.dest);
                if (ie.then_result) |tr| {
                    try self.addConstraint(self.regionOf(tr), dest_region, .phi_merge);
                }
                if (ie.else_result) |er| {
                    try self.addConstraint(self.regionOf(er), dest_region, .phi_merge);
                }
                try self.generateForInstructions(0, ie.then_instrs);
                try self.generateForInstructions(0, ie.else_instrs);
            },
            .case_block => |cb| {
                const dest_region = self.regionOf(cb.dest);
                try self.generateForInstructions(0, cb.pre_instrs);
                for (cb.arms) |arm| {
                    if (arm.result) |r| {
                        try self.addConstraint(self.regionOf(r), dest_region, .phi_merge);
                    }
                    try self.generateForInstructions(0, arm.cond_instrs);
                    try self.generateForInstructions(0, arm.body_instrs);
                }
                if (cb.default_result) |dr| {
                    try self.addConstraint(self.regionOf(dr), dest_region, .phi_merge);
                }
                try self.generateForInstructions(0, cb.default_instrs);
            },
            .guard_block => |gb| {
                try self.generateForInstructions(0, gb.body);
            },
            .switch_literal => |sl| {
                const dest_region = self.regionOf(sl.dest);
                for (sl.cases) |case| {
                    if (case.result) |r| {
                        try self.addConstraint(self.regionOf(r), dest_region, .phi_merge);
                    }
                    try self.generateForInstructions(0, case.body_instrs);
                }
                if (sl.default_result) |dr| {
                    try self.addConstraint(self.regionOf(dr), dest_region, .phi_merge);
                }
                try self.generateForInstructions(0, sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |case| {
                    if (case.return_value) |rv| {
                        try self.addConstraint(self.regionOf(rv), .heap, .return_value);
                    }
                    try self.generateForInstructions(0, case.body_instrs);
                }
                if (sr.default_result) |dr| {
                    try self.addConstraint(self.regionOf(dr), .heap, .return_value);
                }
                try self.generateForInstructions(0, sr.default_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    if (case.return_value) |rv| {
                        try self.addConstraint(self.regionOf(rv), .heap, .return_value);
                    }
                    try self.generateForInstructions(0, case.body_instrs);
                }
            },
            .union_switch => |us| {
                for (us.cases) |case| {
                    if (case.return_value) |rv| {
                        try self.addConstraint(self.regionOf(rv), self.regionOf(us.dest), .assignment);
                    }
                    try self.generateForInstructions(0, case.body_instrs);
                }
            },

            // Aggregate constructors: elements flow into the aggregate.
            .struct_init => |si| {
                const dest_region = self.regionOf(si.dest);
                for (si.fields) |field| {
                    try self.addConstraint(self.regionOf(field.value), dest_region, .store_into_container);
                }
            },
            .tuple_init, .list_init => |ai| {
                const dest_region = self.regionOf(ai.dest);
                for (ai.elements) |elem| {
                    try self.addConstraint(self.regionOf(elem), dest_region, .store_into_container);
                }
            },
            .map_init => |mi| {
                const dest_region = self.regionOf(mi.dest);
                for (mi.entries) |entry| {
                    try self.addConstraint(self.regionOf(entry.key), dest_region, .store_into_container);
                    try self.addConstraint(self.regionOf(entry.value), dest_region, .store_into_container);
                }
            },
            .union_init => |ui| {
                const dest_region = self.regionOf(ui.dest);
                try self.addConstraint(self.regionOf(ui.value), dest_region, .store_into_container);
            },

            // Everything else generates no constraints.
            else => {},
        }
    }
};

// ============================================================
// Section 5: Region Solver
// ============================================================

/// Result of region solving for a single function.
pub const FunctionRegionResult = struct {
    allocator: std.mem.Allocator,
    /// Region assigned to each local.
    region_assignments: std.AutoArrayHashMap(ir.LocalId, lattice.RegionId),
    /// Allocation site summaries.
    alloc_summaries: std.AutoArrayHashMap(lattice.AllocSiteId, lattice.AllocSiteSummary),
    /// Generated outlives constraints.
    outlives_constraints: std.ArrayListUnmanaged(lattice.OutlivesConstraint),
    /// Multiplicity for each region.
    multiplicities: std.AutoArrayHashMap(lattice.RegionId, lattice.Multiplicity),
    /// Storage mode for each region.
    storage_modes: std.AutoArrayHashMap(lattice.RegionId, lattice.StorageMode),

    pub fn init(allocator: std.mem.Allocator) FunctionRegionResult {
        return .{
            .allocator = allocator,
            .region_assignments = std.AutoArrayHashMap(ir.LocalId, lattice.RegionId).init(allocator),
            .alloc_summaries = std.AutoArrayHashMap(lattice.AllocSiteId, lattice.AllocSiteSummary).init(allocator),
            .outlives_constraints = .empty,
            .multiplicities = std.AutoArrayHashMap(lattice.RegionId, lattice.Multiplicity).init(allocator),
            .storage_modes = std.AutoArrayHashMap(lattice.RegionId, lattice.StorageMode).init(allocator),
        };
    }

    pub fn deinit(self: *FunctionRegionResult) void {
        self.region_assignments.deinit();
        self.alloc_summaries.deinit();
        self.outlives_constraints.deinit(self.allocator);
        self.multiplicities.deinit();
        self.storage_modes.deinit();
    }
};

/// The main region solver. Takes a function, its escape states, and
/// allocation sites, and produces region assignments, multiplicities,
/// storage modes, and allocation strategies.
pub const RegionSolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RegionSolver {
        return .{
            .allocator = allocator,
        };
    }

    /// Solve region assignments for a single function.
    ///
    /// Parameters:
    ///   - func: The IR function to analyze.
    ///   - escape_states: Pre-computed escape states for locals (from escape analysis).
    ///   - alloc_sites: Map from LocalId (dest of allocating instruction) to AllocSiteId.
    pub fn solveFunction(
        self: *RegionSolver,
        func: *const ir.Function,
        escape_states: *const std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState),
        alloc_sites: *const std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId),
    ) !FunctionRegionResult {
        var result = FunctionRegionResult.init(self.allocator);
        errdefer result.deinit();

        if (func.body.len == 0) return result;

        // Step 1: Build CFG and dominator tree.
        var cfg = try Cfg.build(self.allocator, func);
        defer cfg.deinit();

        var dom_tree = try DominatorTree.buildFromCfg(self.allocator, &cfg);
        defer dom_tree.deinit();

        // Step 2: Build use-def info.
        var use_def = try UseDefInfo.build(self.allocator, func);
        defer use_def.deinit();

        // Step 3: Compute initial region assignments using CFG-aware live block sets.
        try self.computeInitialRegions(&result, &cfg, &dom_tree, &use_def, escape_states);

        // Step 4: Generate outlives constraints.
        var cgen = ConstraintGenerator.init(self.allocator, func.id);
        defer cgen.deinit();
        // Seed constraint generator with our region assignments.
        var region_iter = result.region_assignments.iterator();
        while (region_iter.next()) |entry| {
            try cgen.region_of.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try cgen.generateForFunction(func);

        // Copy constraints to result.
        for (cgen.constraints.items) |c| {
            try result.outlives_constraints.append(self.allocator, c);
        }

        // Step 5: Verify and promote regions that violate constraints.
        try self.verifyAndPromote(&result, &dom_tree, escape_states);

        // Step 6: Multiplicity inference.
        try self.inferMultiplicities(&result, alloc_sites, &dom_tree, &cfg, func);

        // Step 7: Storage mode analysis.
        try self.analyzeStorageModes(&result, alloc_sites, &use_def, &cfg, func);

        // Step 8: Build allocation site summaries.
        try self.buildAllocSummaries(&result, escape_states, alloc_sites);

        return result;
    }

    /// Compute initial region for each local as the LCA of its def point
    /// and all use points in the dominator tree.
    fn computeInitialRegions(
        self: *RegionSolver,
        result: *FunctionRegionResult,
        cfg: *const Cfg,
        dom_tree: *const DominatorTree,
        use_def: *const UseDefInfo,
        escape_states: *const std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState),
    ) !void {
        _ = self;
        // Iterate over all locals that have definitions.
        var def_iter = use_def.def_block.iterator();
        while (def_iter.next()) |entry| {
            const local = entry.key_ptr.*;
            const def_block = entry.value_ptr.*;

            // Check escape state first: globally-escaping values go to heap.
            const escape = escape_states.get(local) orelse .bottom;
            if (escape.requiresHeap()) {
                try result.region_assignments.put(local, .heap);
                continue;
            }
            if (escape.isEliminable()) {
                // Dead value: assign to function_frame (will be eliminated).
                try result.region_assignments.put(local, .function_frame);
                continue;
            }

            var live_blocks = try LiveBlockSet.compute(result.allocator, cfg, use_def, local);
            defer live_blocks.deinit();
            var region_block = def_block;
            var block_iter = live_blocks.blocks.iterator();
            while (block_iter.next()) |live_entry| {
                region_block = dom_tree.lca(region_block, live_entry.key_ptr.*);
            }

            // Map the common dominator of the live block set to a region.
            // If it is the entry block, use function_frame.
            // Otherwise, use a block-scoped region.
            if (region_block == dom_tree.entry) {
                try result.region_assignments.put(local, .function_frame);
            } else {
                try result.region_assignments.put(local, lattice.RegionId.fromBlock(region_block));
            }
        }
    }

    /// Verify outlives constraints. If any constraint is violated, promote
    /// the shorter-lived value to a wider region.
    fn verifyAndPromote(
        self: *RegionSolver,
        result: *FunctionRegionResult,
        dom_tree: *const DominatorTree,
        escape_states: *const std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState),
    ) !void {
        _ = self;
        _ = escape_states;

        // Iterate constraints until no more promotions occur.
        var changed = true;
        var iterations: u32 = 0;
        const max_iterations: u32 = 100;

        while (changed and iterations < max_iterations) {
            changed = false;
            iterations += 1;

            for (result.outlives_constraints.items) |constraint| {
                // Check if longer actually outlives shorter.
                if (!constraintSatisfied(constraint.longer, constraint.shorter, dom_tree)) {
                    // Promote the shorter region to match the longer.
                    // Find all locals assigned to the shorter region and promote them.
                    const promoted_region = widenRegion(constraint.shorter, dom_tree);
                    var iter = result.region_assignments.iterator();
                    while (iter.next()) |entry_inner| {
                        if (entry_inner.value_ptr.* == constraint.shorter) {
                            entry_inner.value_ptr.* = promoted_region;
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    /// Check if the outlives constraint is satisfied: `longer` must outlive `shorter`.
    fn constraintSatisfied(longer: lattice.RegionId, shorter: lattice.RegionId, dom_tree: *const DominatorTree) bool {
        // Heap outlives everything.
        if (longer == .heap) return true;
        if (shorter == .heap) return false;

        // Function frame outlives any block region.
        if (longer == .function_frame) return true;
        if (shorter == .function_frame) return false;

        // Both are block regions: longer outlives shorter if longer dominates shorter.
        const longer_block = longer.toBlock() orelse return false;
        const shorter_block = shorter.toBlock() orelse return false;
        return dom_tree.dominates(longer_block, shorter_block);
    }

    /// Widen a region by moving to its dominator's region, or function_frame.
    fn widenRegion(region: lattice.RegionId, dom_tree: *const DominatorTree) lattice.RegionId {
        if (region == .heap or region == .function_frame) return region;
        const block = region.toBlock() orelse return .function_frame;
        const idom_val = dom_tree.getIdom(block) orelse return .function_frame;
        if (idom_val == dom_tree.entry) return .function_frame;
        return lattice.RegionId.fromBlock(idom_val);
    }

    /// MLKit-inspired multiplicity inference.
    /// For each region, count allocation sites and check for loops.
    fn inferMultiplicities(
        self: *RegionSolver,
        result: *FunctionRegionResult,
        alloc_sites: *const std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId),
        dom_tree: *const DominatorTree,
        cfg: *const Cfg,
        func: *const ir.Function,
    ) !void {
        _ = self;

        // Count allocation sites per region.
        var region_alloc_counts = std.AutoArrayHashMap(lattice.RegionId, u32).init(result.allocator);
        defer region_alloc_counts.deinit();

        // Track whether any alloc site in a region is in a loop.
        var region_has_loop_alloc = std.AutoArrayHashMap(lattice.RegionId, bool).init(result.allocator);
        defer region_has_loop_alloc.deinit();

        // Build a set of blocks that are in loops.
        var loop_blocks = std.AutoArrayHashMap(ir.LabelId, bool).init(result.allocator);
        defer loop_blocks.deinit();
        for (func.body) |block| {
            try loop_blocks.put(block.label, dom_tree.isInLoop(block.label, cfg));
        }

        // For each allocation site, find its region and check loop membership.
        var alloc_iter = alloc_sites.iterator();
        while (alloc_iter.next()) |entry| {
            const local = entry.key_ptr.*;
            const region = result.region_assignments.get(local) orelse .function_frame;

            // Increment count.
            const count_result = try region_alloc_counts.getOrPut(region);
            if (!count_result.found_existing) {
                count_result.value_ptr.* = 0;
            }
            count_result.value_ptr.* += 1;

            // Check if this alloc is in a loop block.
            var in_loop = false;
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    const dest = getInstructionDest(instr);
                    if (dest != null and dest.? == local) {
                        in_loop = loop_blocks.get(block.label) orelse false;
                        break;
                    }
                }
                if (in_loop) break;
            }

            if (in_loop) {
                try region_has_loop_alloc.put(region, true);
            } else if (!region_has_loop_alloc.contains(region)) {
                try region_has_loop_alloc.put(region, false);
            }
        }

        // Assign multiplicities.
        // Collect all unique regions.
        var all_regions = std.AutoArrayHashMap(lattice.RegionId, void).init(result.allocator);
        defer all_regions.deinit();
        var region_iter = result.region_assignments.iterator();
        while (region_iter.next()) |entry| {
            try all_regions.put(entry.value_ptr.*, {});
        }

        for (all_regions.keys()) |region| {
            const count = region_alloc_counts.get(region) orelse 0;
            const has_loop = region_has_loop_alloc.get(region) orelse false;

            const multiplicity: lattice.Multiplicity = if (count == 0)
                .zero
            else if (count == 1 and !has_loop)
                .one
            else
                .many;

            try result.multiplicities.put(region, multiplicity);
        }
    }

    /// Get the destination local of an instruction, if any.
    fn getInstructionDest(instr: ir.Instruction) ?ir.LocalId {
        return switch (instr) {
            .const_int => |ci| ci.dest,
            .const_float => |cf| cf.dest,
            .const_string => |cs| cs.dest,
            .const_bool => |cb| cb.dest,
            .const_atom => |ca| ca.dest,
            .const_nil => |dest| dest,
            .local_get => |lg| lg.dest,
            .local_set => |ls| ls.dest,
            .param_get => |pg| pg.dest,
            .tuple_init, .list_init => |ai| ai.dest,
            .map_init => |mi| mi.dest,
            .struct_init => |si| si.dest,
            .union_init => |ui| ui.dest,
            .enum_literal => |el| el.dest,
            .field_get => |fg| fg.dest,
            .index_get => |ig| ig.dest,
            .list_len_check => |llc| llc.dest,
            .list_get => |lg| lg.dest,
            .map_has_key => |mhk| mhk.dest,
            .map_get => |mg| mg.dest,
            .binary_op => |bo| bo.dest,
            .unary_op => |uo| uo.dest,
            .call_direct => |cd| cd.dest,
            .call_named => |cn| cn.dest,
            .call_closure => |cc| cc.dest,
            .call_dispatch => |cd| cd.dest,
            .call_builtin => |cb| cb.dest,
            .if_expr => |ie| ie.dest,
            .case_block => |cb| cb.dest,
            .switch_literal => |sl| sl.dest,
            .make_closure => |mc| mc.dest,
            .capture_get => |cg| cg.dest,
            .optional_unwrap => |ou| ou.dest,
            .match_atom => |ma| ma.dest,
            .match_int => |mi| mi.dest,
            .match_float => |mf| mf.dest,
            .match_string => |ms| ms.dest,
            .match_type => |mt| mt.dest,
            .phi => |p| p.dest,
            .bin_len_check => |blc| blc.dest,
            .bin_read_int => |bri| bri.dest,
            .bin_read_float => |brf| brf.dest,
            .bin_slice => |bs| bs.dest,
            .bin_match_prefix => |bmp| bmp.dest,
            else => null,
        };
    }

    /// MLKit-inspired storage mode analysis.
    /// For regions with multiplicity=many, determine attop vs atbot.
    fn analyzeStorageModes(
        self: *RegionSolver,
        result: *FunctionRegionResult,
        alloc_sites: *const std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId),
        use_def: *const UseDefInfo,
        cfg: *const Cfg,
        func: *const ir.Function,
    ) !void {
        _ = self;

        for (result.multiplicities.keys(), result.multiplicities.values()) |region, mult| {
            if (mult != .many) {
                // Only analyze multi-value regions.
                try result.storage_modes.put(region, .attop);
                continue;
            }

            // Collect all locals in this region.
            var locals_in_region: std.ArrayListUnmanaged(ir.LocalId) = .empty;
            defer locals_in_region.deinit(result.allocator);

            var ra_iter = result.region_assignments.iterator();
            while (ra_iter.next()) |entry| {
                if (entry.value_ptr.* == region) {
                    try locals_in_region.append(result.allocator, entry.key_ptr.*);
                }
            }

            // For each allocation site in this region, check if all other
            // values in the region are dead at that point.
            var can_atbot = true;

            var as_iter = alloc_sites.iterator();
            while (as_iter.next()) |entry| {
                const alloc_local = entry.key_ptr.*;
                const alloc_region = result.region_assignments.get(alloc_local) orelse continue;
                if (alloc_region != region) continue;

                // Check if any other value in the region is live at this alloc point.
                for (locals_in_region.items) |other_local| {
                    if (other_local == alloc_local) continue;
                    if (try isLiveAt(result.allocator, other_local, alloc_local, use_def, cfg, func)) {
                        can_atbot = false;
                        break;
                    }
                }
                if (!can_atbot) break;
            }

            try result.storage_modes.put(region, if (can_atbot) .atbot else .attop);
        }
    }

    /// Conservative liveness check: is `query_local` live at the point
    /// where `at_local` is defined?
    /// A local is considered live if it is defined before `at_local` and
    /// has uses after `at_local`.
    fn isLiveAt(
        allocator: std.mem.Allocator,
        query_local: ir.LocalId,
        at_local: ir.LocalId,
        use_def: *const UseDefInfo,
        cfg: *const Cfg,
        func: *const ir.Function,
    ) !bool {
        const query_def_pos = findInstructionPosition(query_local, func) orelse return false;
        const at_def_pos = findInstructionPosition(at_local, func) orelse return false;
        var liveness = try LocalBlockLiveness.build(allocator, cfg, func, query_local);
        defer liveness.deinit();

        // query must be defined before at_local.
        if (query_def_pos.block_idx > at_def_pos.block_idx) return false;
        if (query_def_pos.block_idx == at_def_pos.block_idx and
            query_def_pos.instr_idx >= at_def_pos.instr_idx) return false;

        const at_block = func.body[at_def_pos.block_idx];
        if (query_def_pos.block_idx == at_def_pos.block_idx) {
            if (blockHasUseAfter(query_local, at_block.instructions, at_def_pos.instr_idx + 1)) return true;
            return liveness.isLiveOut(at_block.label);
        }

        if (liveness.isLiveIn(at_block.label) or liveness.isLiveOut(at_block.label)) {
            return true;
        }

        for (use_def.getUseBlocks(query_local)) |use_block| {
            if (use_block == at_block.label) {
                return blockHasUseAfter(query_local, at_block.instructions, at_def_pos.instr_idx + 1);
            }
        }

        return false;
    }

    fn blockHasUseAfter(local: ir.LocalId, instrs: []const ir.Instruction, start_idx: usize) bool {
        var idx = start_idx;
        while (idx < instrs.len) : (idx += 1) {
            if (instructionUsesLocal(local, instrs[idx])) return true;
        }
        return false;
    }

    const InstructionPosition = struct {
        block_idx: usize,
        instr_idx: usize,
    };

    fn findInstructionPosition(local: ir.LocalId, func: *const ir.Function) ?InstructionPosition {
        for (func.body, 0..) |block, bi| {
            for (block.instructions, 0..) |instr, ii| {
                const dest = getInstructionDest(instr);
                if (dest != null and dest.? == local) {
                    return .{ .block_idx = bi, .instr_idx = ii };
                }
            }
        }
        return null;
    }

    /// Build AllocSiteSummary for each allocation site.
    fn buildAllocSummaries(
        self: *RegionSolver,
        result: *FunctionRegionResult,
        escape_states: *const std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState),
        alloc_sites: *const std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId),
    ) !void {
        _ = self;

        var alloc_iter = alloc_sites.iterator();
        while (alloc_iter.next()) |entry| {
            const local = entry.key_ptr.*;
            const site_id = entry.value_ptr.*;

            const escape = escape_states.get(local) orelse .bottom;
            const region = result.region_assignments.get(local) orelse .function_frame;
            const multiplicity = result.multiplicities.get(region) orelse .zero;
            const storage_mode = result.storage_modes.get(region) orelse .attop;
            const strategy = lattice.escapeToStrategy(escape, multiplicity);

            var summary = lattice.AllocSiteSummary.init(site_id, 0);
            summary.escape = escape;
            summary.region = region;
            summary.multiplicity = multiplicity;
            summary.storage_mode = storage_mode;
            summary.strategy = strategy;

            try result.alloc_summaries.put(site_id, summary);
        }
    }
};

// ============================================================
// Section 6: Tests
// ============================================================

test "DominatorTree: single block function" {
    const allocator = std.testing.allocator;

    // Single block function: block 0 is the entry and dominates itself.
    const func = ir.Function{
        .id = 0,
        .name = "test_single",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 42 } },
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var tree = try DominatorTree.build(allocator, &func);
    defer tree.deinit();

    // Entry has no immediate dominator (dominates itself).
    try std.testing.expect(tree.getIdom(0) == null);
    try std.testing.expect(tree.dominates(0, 0));
    try std.testing.expectEqual(@as(u32, 0), tree.getDepth(0));
}

test "DominatorTree: linear blocks" {
    const allocator = std.testing.allocator;

    // block 0 -> block 1 -> block 2 (linear chain)
    const func = ir.Function{
        .id = 0,
        .name = "test_linear",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 1 } },
                    // Falls through to block 1.
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 2 } },
                    // Falls through to block 2.
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var tree = try DominatorTree.build(allocator, &func);
    defer tree.deinit();

    // Block 0 dominates blocks 1 and 2.
    try std.testing.expect(tree.dominates(0, 1));
    try std.testing.expect(tree.dominates(0, 2));
    try std.testing.expect(tree.dominates(1, 2));

    // Idom of 1 is 0, idom of 2 is 1.
    try std.testing.expectEqual(@as(ir.LabelId, 0), tree.getIdom(1).?);
    try std.testing.expectEqual(@as(ir.LabelId, 1), tree.getIdom(2).?);

    // LCA of 1 and 2 is 1.
    try std.testing.expectEqual(@as(ir.LabelId, 1), tree.lca(1, 2));
    // LCA of 0 and 2 is 0.
    try std.testing.expectEqual(@as(ir.LabelId, 0), tree.lca(0, 2));
}

test "DominatorTree: diamond CFG" {
    const allocator = std.testing.allocator;

    // block 0 -> block 1 (then), block 2 (else) -> block 3 (merge)
    const func = ir.Function{
        .id = 0,
        .name = "test_diamond",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 0, .value = true } },
                    .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 10 } },
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 2, .value = 20 } },
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 3,
                .instructions = &[_]ir.Instruction{
                    .{ .phi = .{
                        .dest = 3,
                        .sources = &[_]ir.PhiSource{
                            .{ .from_block = 1, .value = 1 },
                            .{ .from_block = 2, .value = 2 },
                        },
                    } },
                    .{ .ret = .{ .value = 3 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var tree = try DominatorTree.build(allocator, &func);
    defer tree.deinit();

    // Block 0 dominates all blocks.
    try std.testing.expect(tree.dominates(0, 1));
    try std.testing.expect(tree.dominates(0, 2));
    try std.testing.expect(tree.dominates(0, 3));

    // Block 1 does NOT dominate block 3 (could come from 2).
    try std.testing.expect(!tree.dominates(1, 3));
    try std.testing.expect(!tree.dominates(2, 3));

    // Idom of 3 is 0 (common dominator of both predecessors).
    try std.testing.expectEqual(@as(ir.LabelId, 0), tree.getIdom(3).?);

    // LCA of 1 and 2 is 0.
    try std.testing.expectEqual(@as(ir.LabelId, 0), tree.lca(1, 2));
}

test "UseDefInfo: basic use-def tracking" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_usedef",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 42 } },
                    .{ .const_int = .{ .dest = 1, .value = 10 } },
                    .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
                    .{ .ret = .{ .value = 2 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var info = try UseDefInfo.build(allocator, &func);
    defer info.deinit();

    // All locals defined in block 0.
    try std.testing.expectEqual(@as(ir.LabelId, 0), info.getDefBlock(0).?);
    try std.testing.expectEqual(@as(ir.LabelId, 0), info.getDefBlock(1).?);
    try std.testing.expectEqual(@as(ir.LabelId, 0), info.getDefBlock(2).?);

    // Locals 0 and 1 are used in block 0 (by binary_op).
    try std.testing.expect(info.getUseBlocks(0).len > 0);
    try std.testing.expect(info.getUseBlocks(1).len > 0);

    // Local 2 is used by ret.
    try std.testing.expect(info.getUseBlocks(2).len > 0);
}

test "RegionSolver: value defined and used in same block -> block region" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_same_block",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 10, .value = 1 } },
                    // Falls through to block 1.
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    // Local 0 defined and used only in block 1.
                    .{ .const_int = .{ .dest = 0, .value = 42 } },
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .ret = .{ .value = 10 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .block_local);
    try escape_states.put(1, .block_local);
    try escape_states.put(10, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Local 0 defined and used in block 1 -> block-scoped region for block 1.
    const region_0 = result.region_assignments.get(0).?;
    try std.testing.expectEqual(lattice.RegionId.fromBlock(1), region_0);
}

test "RegionSolver: value defined in block A, used in block B -> LCA region" {
    const allocator = std.testing.allocator;

    // Block 0 defines local 0, block 1 uses it.
    const func = ir.Function{
        .id = 0,
        .name = "test_cross_block",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 42 } },
                    // Falls through.
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // LCA of block 0 (def) and block 1 (use) is block 0 (entry) -> function_frame.
    const region_0 = result.region_assignments.get(0).?;
    try std.testing.expectEqual(lattice.RegionId.function_frame, region_0);
}

test "RegionSolver: returned value -> heap region" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_return_heap",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .global_escape);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Globally escaping value -> heap region.
    const region_0 = result.region_assignments.get(0).?;
    try std.testing.expectEqual(lattice.RegionId.heap, region_0);

    // Allocation strategy should be heap_arc.
    const summary = result.alloc_summaries.get(0).?;
    try std.testing.expectEqual(lattice.AllocationStrategy.heap_arc, summary.strategy);
}

test "RegionSolver: single allocation not in loop -> multiplicity=one" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_mult_one",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Single block, no loop, one alloc site -> multiplicity=one.
    const region = result.region_assignments.get(0).?;
    const mult = result.multiplicities.get(region).?;
    try std.testing.expectEqual(lattice.Multiplicity.one, mult);
}

test "RegionSolver: allocation in loop -> multiplicity=many" {
    const allocator = std.testing.allocator;

    // block 0 -> block 1 -> block 0 (back edge = loop)
    const func = ir.Function{
        .id = 0,
        .name = "test_mult_many",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 5, .value = true } },
                    .{ .cond_branch = .{ .condition = 5, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    // Allocation inside loop body.
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    // Back edge to block 0 (creates loop).
                    .{ .branch = .{ .target = 0 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);
    try escape_states.put(5, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Block 1 has a back edge to block 0 -> block 1 is in a loop.
    // Single alloc site in loop -> multiplicity=many.
    const region = result.region_assignments.get(0).?;
    const mult = result.multiplicities.get(region).?;
    try std.testing.expectEqual(lattice.Multiplicity.many, mult);
}

test "RegionSolver: dead values in region at alloc point -> atbot" {
    const allocator = std.testing.allocator;

    // Loop with single alloc site. No other values in the same region are live.
    const func = ir.Function{
        .id = 0,
        .name = "test_atbot",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 5, .value = true } },
                    .{ .cond_branch = .{ .condition = 5, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    // Single alloc in loop -- only value in its region.
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .branch = .{ .target = 0 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);
    try escape_states.put(5, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    const region = result.region_assignments.get(0).?;
    const mult = result.multiplicities.get(region).?;
    try std.testing.expectEqual(lattice.Multiplicity.many, mult);

    // Since local 0 is the only alloc in the region and no other values
    // in the same region are live at the alloc point -> atbot.
    const mode = result.storage_modes.get(region).?;
    try std.testing.expectEqual(lattice.StorageMode.atbot, mode);
}

test "RegionSolver: live values in region at alloc point -> attop" {
    const allocator = std.testing.allocator;

    // Two alloc sites in same block (both mapped to same region by escape analysis).
    // Local 0 is still live when local 3 is allocated -> attop.
    const func = ir.Function{
        .id = 0,
        .name = "test_attop",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 5, .value = true } },
                    .{ .cond_branch = .{ .condition = 5, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .struct_init = .{
                        .dest = 3,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    // Use both after the second alloc.
                    .{ .binary_op = .{ .dest = 4, .op = .add, .lhs = 0, .rhs = 3 } },
                    .{ .branch = .{ .target = 0 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);
    try escape_states.put(3, .function_local);
    try escape_states.put(4, .function_local);
    try escape_states.put(5, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);
    try alloc_sites.put(3, 1);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Both allocs in same region (function_frame), both in loop -> many.
    const region_0 = result.region_assignments.get(0).?;
    const region_3 = result.region_assignments.get(3).?;
    try std.testing.expectEqual(region_0, region_3);

    const mult = result.multiplicities.get(region_0).?;
    try std.testing.expectEqual(lattice.Multiplicity.many, mult);

    // Local 0 is live when local 3 is allocated -> attop.
    const mode = result.storage_modes.get(region_0).?;
    try std.testing.expectEqual(lattice.StorageMode.attop, mode);
}

test "RegionSolver: constraint violation promotes to wider region" {
    const allocator = std.testing.allocator;

    // Diamond CFG: block 0 -> 1, 2 -> 3
    // Local 0 defined in block 1, used in block 3 (via phi).
    const func = ir.Function{
        .id = 0,
        .name = "test_promotion",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 5, .value = true } },
                    .{ .cond_branch = .{ .condition = 5, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .struct_init = .{
                        .dest = 0,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .struct_init = .{
                        .dest = 1,
                        .type_name = "Point",
                        .fields = &.{},
                    } },
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 3,
                .instructions = &[_]ir.Instruction{
                    .{ .phi = .{
                        .dest = 2,
                        .sources = &[_]ir.PhiSource{
                            .{ .from_block = 1, .value = 0 },
                            .{ .from_block = 2, .value = 1 },
                        },
                    } },
                    .{ .ret = .{ .value = 2 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);
    try escape_states.put(2, .global_escape);
    try escape_states.put(5, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);
    try alloc_sites.put(1, 1);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    // Local 2 (phi result, returned) should be in heap region.
    const region_2 = result.region_assignments.get(2).?;
    try std.testing.expectEqual(lattice.RegionId.heap, region_2);

    // Locals 0 and 1 are function_local: used across blocks but not escaping.
    // Since they're defined in blocks 1 and 2 respectively, and used in block 3,
    // the LCA is block 0 (entry) -> function_frame.
    const region_0 = result.region_assignments.get(0).?;
    const region_1 = result.region_assignments.get(1).?;
    try std.testing.expectEqual(lattice.RegionId.function_frame, region_0);
    try std.testing.expectEqual(lattice.RegionId.function_frame, region_1);
}

test "RegionSolver: arg_escape_safe alloc site maps to caller_region strategy" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_caller_region",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .tuple_init = .{ .dest = 0, .elements = &[_]ir.LocalId{} } },
                    .{ .ret = .{ .value = null } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .arg_escape_safe);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();
    try alloc_sites.put(0, 0);

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    const summary = result.alloc_summaries.get(0).?;
    try std.testing.expectEqual(lattice.AllocationStrategy.caller_region, summary.strategy);
}

test "RegionSolver: loop-carried value remains function-frame stable" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_loop_carried",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 1 } },
                    .{ .branch = .{ .target = 1 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .cond_branch = .{ .condition = 1, .then_target = 2, .else_target = 3 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .call_builtin = .{ .dest = 2, .name = "identity", .args = &[_]ir.LocalId{0}, .arg_modes = &[_]ir.ValueMode{.share} } },
                    .{ .branch = .{ .target = 1 } },
                },
            },
            .{
                .label = 3,
                .instructions = &[_]ir.Instruction{
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
    defer escape_states.deinit();
    try escape_states.put(0, .function_local);
    try escape_states.put(1, .function_local);
    try escape_states.put(2, .function_local);

    var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
    defer alloc_sites.deinit();

    var solver = RegionSolver.init(allocator);
    var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
    defer result.deinit();

    try std.testing.expectEqual(lattice.RegionId.function_frame, result.region_assignments.get(0).?);
}

test "LiveBlockSet: includes intermediate CFG blocks between def and use" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_live_blocks",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 1 } },
                    .{ .branch = .{ .target = 1 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .branch = .{ .target = 2 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var cfg = try Cfg.build(allocator, &func);
    defer cfg.deinit();
    var use_def = try UseDefInfo.build(allocator, &func);
    defer use_def.deinit();
    var live_blocks = try LiveBlockSet.compute(allocator, &cfg, &use_def, 0);
    defer live_blocks.deinit();

    try std.testing.expect(live_blocks.contains(0));
    try std.testing.expect(live_blocks.contains(1));
    try std.testing.expect(live_blocks.contains(2));
}

test "LocalBlockLiveness: detects value dead before next iteration" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_dead_before_next_iter",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .branch = .{ .target = 1 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 1 } },
                    .{ .local_get = .{ .dest = 1, .source = 0 } },
                    .{ .cond_branch = .{ .condition = 1, .then_target = 2, .else_target = 3 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .branch = .{ .target = 1 } },
                },
            },
            .{
                .label = 3,
                .instructions = &[_]ir.Instruction{
                    .{ .ret = .{ .value = 1 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var cfg = try Cfg.build(allocator, &func);
    defer cfg.deinit();
    var liveness = try LocalBlockLiveness.build(allocator, &cfg, &func, 0);
    defer liveness.deinit();

    try std.testing.expect(!liveness.isLiveIn(1));
}

test "ConstraintGenerator: generates return constraints" {
    const allocator = std.testing.allocator;

    var cgen = ConstraintGenerator.init(allocator, 0);
    defer cgen.deinit();

    const func = ir.Function{
        .id = 0,
        .name = "test_constraints",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 42 } },
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    try cgen.generateForFunction(&func);

    // Should have a return constraint: region(0) outlives heap.
    try std.testing.expect(cgen.constraints.items.len > 0);
    var found_return_constraint = false;
    for (cgen.constraints.items) |c| {
        if (c.reason == .return_value) {
            found_return_constraint = true;
            // The shorter side should be heap (return target).
            try std.testing.expectEqual(lattice.RegionId.heap, c.shorter);
            break;
        }
    }
    try std.testing.expect(found_return_constraint);
}

test "ConstraintGenerator: generates phi merge constraints" {
    const allocator = std.testing.allocator;

    var cgen = ConstraintGenerator.init(allocator, 0);
    defer cgen.deinit();

    const func = ir.Function{
        .id = 0,
        .name = "test_phi_constraints",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 0, .value = 1 } },
                    .{ .const_int = .{ .dest = 1, .value = 2 } },
                    .{ .phi = .{
                        .dest = 2,
                        .sources = &[_]ir.PhiSource{
                            .{ .from_block = 1, .value = 0 },
                            .{ .from_block = 2, .value = 1 },
                        },
                    } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    try cgen.generateForFunction(&func);

    // All regions default to function_frame, so phi constraints are
    // elided (same region on both sides). This verifies the mechanism works
    // without generating redundant constraints.
    for (cgen.constraints.items) |c| {
        if (c.reason == .phi_merge) {
            // If a phi constraint was generated, both sides should differ.
            try std.testing.expect(c.longer != c.shorter);
        }
    }
}

test "ConstraintGenerator: generates store constraints" {
    const allocator = std.testing.allocator;

    var cgen = ConstraintGenerator.init(allocator, 0);
    defer cgen.deinit();

    // Assign different regions to create a non-trivial constraint.
    try cgen.region_of.put(0, .function_frame);
    try cgen.region_of.put(1, lattice.RegionId.fromBlock(1));

    const func = ir.Function{
        .id = 0,
        .name = "test_store_constraints",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .field_set = .{
                        .object = 0,
                        .field = "x",
                        .value = 1,
                    } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    try cgen.generateForFunction(&func);

    var found_store = false;
    for (cgen.constraints.items) |c| {
        if (c.reason == .store_into_container) {
            found_store = true;
            break;
        }
    }
    try std.testing.expect(found_store);
}

test "Cfg: basic CFG construction" {
    const allocator = std.testing.allocator;

    const func = ir.Function{
        .id = 0,
        .name = "test_cfg",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 0, .value = true } },
                    .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .branch = .{ .target = 3 } },
                },
            },
            .{
                .label = 3,
                .instructions = &[_]ir.Instruction{
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var cfg = try Cfg.build(allocator, &func);
    defer cfg.deinit();

    // Block 0 has successors 1 and 2.
    const succs_0 = cfg.getSuccessors(0);
    try std.testing.expectEqual(@as(usize, 2), succs_0.len);

    // Block 1 has successor 3.
    const succs_1 = cfg.getSuccessors(1);
    try std.testing.expectEqual(@as(usize, 1), succs_1.len);
    try std.testing.expectEqual(@as(ir.LabelId, 3), succs_1[0]);

    // Block 3 has predecessors 1 and 2.
    const preds_3 = cfg.getPredecessors(3);
    try std.testing.expectEqual(@as(usize, 2), preds_3.len);
}

test "RegionSolver: escapeToStrategy integration" {
    // Verify that the final alloc summaries use the correct strategy mapping.
    const allocator = std.testing.allocator;

    // Test 1: no_escape with a single alloc site -> scalar_replaced.
    {
        const func = ir.Function{
            .id = 0,
            .name = "test_strategy_scalar",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &[_]ir.Block{
                .{
                    .label = 0,
                    .instructions = &[_]ir.Instruction{
                        .{ .struct_init = .{
                            .dest = 0,
                            .type_name = "Point",
                            .fields = &.{},
                        } },
                        .{ .ret = .{ .value = 0 } },
                    },
                },
            },
            .is_closure = false,
            .captures = &.{},
        };

        var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
        defer escape_states.deinit();
        try escape_states.put(0, .no_escape);

        var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
        defer alloc_sites.deinit();
        try alloc_sites.put(0, 0);

        var solver = RegionSolver.init(allocator);
        var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
        defer result.deinit();

        const summary_0 = result.alloc_summaries.get(0).?;
        try std.testing.expectEqual(lattice.AllocationStrategy.scalar_replaced, summary_0.strategy);
    }

    // Test 2: function_local with a single alloc site -> stack_function.
    {
        const func = ir.Function{
            .id = 1,
            .name = "test_strategy_stack",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &[_]ir.Block{
                .{
                    .label = 0,
                    .instructions = &[_]ir.Instruction{
                        .{ .struct_init = .{
                            .dest = 0,
                            .type_name = "Rect",
                            .fields = &.{},
                        } },
                        .{ .local_get = .{ .dest = 1, .source = 0 } },
                        .{ .ret = .{ .value = 1 } },
                    },
                },
            },
            .is_closure = false,
            .captures = &.{},
        };

        var escape_states = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(allocator);
        defer escape_states.deinit();
        try escape_states.put(0, .function_local);
        try escape_states.put(1, .function_local);

        var alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(allocator);
        defer alloc_sites.deinit();
        try alloc_sites.put(0, 0);

        var solver = RegionSolver.init(allocator);
        var result = try solver.solveFunction(&func, &escape_states, &alloc_sites);
        defer result.deinit();

        const summary_0 = result.alloc_summaries.get(0).?;
        try std.testing.expectEqual(lattice.AllocationStrategy.stack_function, summary_0.strategy);
    }
}

test "DominatorTree: loop detection via back-edge" {
    const allocator = std.testing.allocator;

    // block 0 -> block 1 -> block 0 (loop via back-edge)
    //                     -> block 2 (exit)
    const func = ir.Function{
        .id = 0,
        .name = "test_loop_detect",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &[_]ir.Block{
            .{
                .label = 0,
                .instructions = &[_]ir.Instruction{
                    .{ .const_bool = .{ .dest = 0, .value = true } },
                    .{ .cond_branch = .{ .condition = 0, .then_target = 1, .else_target = 2 } },
                },
            },
            .{
                .label = 1,
                .instructions = &[_]ir.Instruction{
                    .{ .const_int = .{ .dest = 1, .value = 42 } },
                    .{ .branch = .{ .target = 0 } }, // Back-edge.
                },
            },
            .{
                .label = 2,
                .instructions = &[_]ir.Instruction{
                    .{ .ret = .{ .value = 0 } },
                },
            },
        },
        .is_closure = false,
        .captures = &.{},
    };

    var cfg = try Cfg.build(allocator, &func);
    defer cfg.deinit();

    var tree = try DominatorTree.buildFromCfg(allocator, &cfg);
    defer tree.deinit();

    // Block 1 has a successor (block 0) that dominates it -> in loop.
    try std.testing.expect(tree.isInLoop(1, &cfg));

    // Block 2 has no back-edge -> not in loop.
    try std.testing.expect(!tree.isInLoop(2, &cfg));
}

test "RegionId: fromBlock and toBlock roundtrip" {
    const region = lattice.RegionId.fromBlock(5);
    try std.testing.expectEqual(@as(ir.LabelId, 5), region.toBlock().?);

    // heap and function_frame return null for toBlock.
    try std.testing.expect(lattice.RegionId.heap.toBlock() == null);
    try std.testing.expect(lattice.RegionId.function_frame.toBlock() == null);
}

test "RegionId: outlives ordering" {
    // heap outlives everything.
    try std.testing.expect(lattice.RegionId.heap.outlives(.function_frame));
    try std.testing.expect(lattice.RegionId.heap.outlives(lattice.RegionId.fromBlock(0)));

    // function_frame outlives block regions.
    try std.testing.expect(lattice.RegionId.function_frame.outlives(lattice.RegionId.fromBlock(0)));

    // Block regions: lower index outlives higher index (conservative).
    try std.testing.expect(lattice.RegionId.fromBlock(0).outlives(lattice.RegionId.fromBlock(1)));
}
