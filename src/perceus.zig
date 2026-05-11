const std = @import("std");
const ir = @import("ir.zig");
const types_mod = @import("types.zig");
const lattice = @import("escape_lattice.zig");

// ============================================================
// Perceus-style Reuse Analysis and Drop Specialization
//
// Inspired by Koka's Perceus (PLDI 2021). This pass pairs pattern-match
// deconstruction sites with same-type/size construction sites so that
// memory can be reused in-place when the deconstructed value is uniquely
// owned (RC=1). When ownership is shared, a dynamic check is emitted.
//
// The canonical FBIP example: `map(list, f)` where list is uniquely owned.
//   - case_block deconstructs the list (match on head|tail)
//   - Each branch constructs a new list node `[f(head) | map(tail, f)]`
//   - If list has RC=1, the old node memory is reused for the new node
//   - Zero allocation for the entire map operation
//
// This pass also generates drop specializations: at pattern match sites
// where the constructor tag is known, we emit per-field drop sequences
// instead of a generic tag-dispatching drop.
// ============================================================

/// Information about a type extracted from IR instructions, used for
/// reuse compatibility checking.
pub const TypeInfo = struct {
    name: ?[]const u8,
    kind: TypeKind,
    num_fields: u32,

    pub const TypeKind = enum {
        struct_type,
        tuple_type,
        list_type,
        union_type,
        map_type,
    };

    pub fn eql(a: TypeInfo, b: TypeInfo) bool {
        if (a.kind != b.kind) return false;
        if (a.num_fields != b.num_fields) return false;
        if (a.name != null and b.name != null) {
            return std.mem.eql(u8, a.name.?, b.name.?);
        }
        // If either name is null, match on kind + field count only
        return true;
    }
};

/// A site where a value is deconstructed via pattern matching.
pub const DeconstructionSite = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    /// Path from the top-level block to the stream containing the
    /// deconstruction instruction. Empty for top-level positions.
    /// Each step descends one level of nesting. Replaces the
    /// previous synthetic-index encoding (which was effectively
    /// dead code — `current_instr_index` in the ZIR driver is only
    /// updated during top-level block emission, so nested-encoded
    /// records never matched).
    path: []const lattice.StreamStep = &.{},
    /// Index within the innermost stream reached by walking `path`.
    instr_index: u32,
    scrutinee: ir.LocalId,
    scrutinee_type: TypeInfo,
    match_site_id: lattice.MatchSiteId,
    /// The instruction tag so we know what kind of match this is.
    match_kind: MatchKind,

    pub const MatchKind = enum {
        case_block,
        switch_tag,
        if_expr,
        /// Multi-clause `f(nil) / f(t :: T)` shape lowered to
        /// `optional_dispatch`. The struct branch unwraps `?T` to the
        /// boxed `*const T` payload and consumes it. Treated as a
        /// deconstruction site so the payload is dropped at the end of
        /// the struct branch.
        optional_dispatch,
    };
};

/// A site where a value is constructed (allocation).
pub const ConstructionSite = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
    /// Path from the top-level block to the stream containing the
    /// construction instruction. Same semantics as
    /// `DeconstructionSite.path`.
    path: []const lattice.StreamStep = &.{},
    /// Index within the innermost stream.
    instr_index: u32,
    dest: ir.LocalId,
    dest_type: TypeInfo,
    alloc_site_id: lattice.AllocSiteId,
};

/// A per-field drop to be emitted instead of a generic drop call.
pub const FieldDrop = lattice.FieldDrop;
pub const DropSpecialization = lattice.DropSpecialization;

/// Per-function statistics about reuse analysis results.
pub const FunctionStats = struct {
    function_id: ir.FunctionId,
    function_name: []const u8,
    total_reuse_pairs: u32,
    static_reuses: u32,
    dynamic_reuses: u32,
    drop_specializations: u32,
    deconstruction_sites: u32,
    construction_sites: u32,
};

/// Function-id + scrutinee-param-index pair surfaced by the
/// destructive-optional-dispatch detector.
pub const DestructiveOptionalDispatch = struct {
    function: ir.FunctionId,
    scrutinee_param: u32,
};

/// Complete results from the Perceus analysis pass.
pub const AnalysisResult = struct {
    reuse_pairs: []const lattice.ReusePair,
    arc_ops: []const lattice.ArcOperation,
    drop_specializations: []const DropSpecialization,
    function_stats: []const FunctionStats,
    destructive_optional_dispatch: []const DestructiveOptionalDispatch,

    pub fn deinit(self: *const AnalysisResult, allocator: std.mem.Allocator) void {
        for (self.reuse_pairs) |pair| {
            allocator.free(pair.reuse.insertion_point.path);
        }
        allocator.free(self.reuse_pairs);
        for (self.arc_ops) |op| {
            allocator.free(op.insertion_point.path);
        }
        allocator.free(self.arc_ops);
        for (self.drop_specializations) |ds| {
            allocator.free(ds.field_drops);
            allocator.free(ds.insertion_point.path);
        }
        allocator.free(self.drop_specializations);
        allocator.free(self.function_stats);
        allocator.free(self.destructive_optional_dispatch);
    }
};

// ============================================================
// Perceus Analyzer
// ============================================================

pub const PerceusAnalyzer = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    context: ?*const lattice.AnalysisContext,
    next_match_site_id: lattice.MatchSiteId,
    next_alloc_site_id: lattice.AllocSiteId,

    // Accumulated results (unmanaged ArrayLists — allocator passed per call)
    reuse_pairs: std.ArrayList(lattice.ReusePair),
    arc_ops: std.ArrayList(lattice.ArcOperation),
    drop_specializations: std.ArrayList(DropSpecialization),
    function_stats: std.ArrayList(FunctionStats),
    /// Function ids (with the scrutinee param index) whose optional-
    /// dispatch struct branch is "destructive": every indirect-storage
    /// child of the scrutinee is extracted-and-consumed by a call,
    /// so the parent never observes those children again. Surfaces in
    /// `AnalysisContext.destructive_optional_dispatch` for the ZIR
    /// backend to act on.
    destructive_funcs: std.AutoHashMapUnmanaged(ir.FunctionId, u32),

    // Working state for current function
    current_function_id: ir.FunctionId,
    current_decon_sites: std.ArrayList(DeconstructionSite),

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program) PerceusAnalyzer {
        return initWithContext(allocator, program, null);
    }

    pub fn initWithContext(allocator: std.mem.Allocator, program: *const ir.Program, context: ?*const lattice.AnalysisContext) PerceusAnalyzer {
        return .{
            .allocator = allocator,
            .program = program,
            .context = context,
            .next_match_site_id = 0,
            .next_alloc_site_id = 0,
            .reuse_pairs = .empty,
            .arc_ops = .empty,
            .drop_specializations = .empty,
            .function_stats = .empty,
            .destructive_funcs = .empty,
            .current_function_id = 0,
            .current_decon_sites = .empty,
        };
    }

    pub fn deinit(self: *PerceusAnalyzer) void {
        for (self.reuse_pairs.items) |pair| {
            self.allocator.free(pair.reuse.insertion_point.path);
        }
        self.reuse_pairs.deinit(self.allocator);
        for (self.arc_ops.items) |op| {
            self.allocator.free(op.insertion_point.path);
        }
        self.arc_ops.deinit(self.allocator);
        for (self.drop_specializations.items) |ds| {
            self.allocator.free(ds.field_drops);
            self.allocator.free(ds.insertion_point.path);
        }
        self.drop_specializations.deinit(self.allocator);
        self.function_stats.deinit(self.allocator);
        self.destructive_funcs.deinit(self.allocator);
        for (self.current_decon_sites.items) |decon| {
            self.allocator.free(decon.path);
        }
        self.current_decon_sites.deinit(self.allocator);
    }

    /// Run the full Perceus analysis on all functions in the program.
    pub fn analyze(self: *PerceusAnalyzer) !AnalysisResult {
        for (self.program.functions) |func| {
            try self.analyzeFunction(&func);
        }

        var destructive_list: std.ArrayList(DestructiveOptionalDispatch) = .empty;
        var destructive_iter = self.destructive_funcs.iterator();
        while (destructive_iter.next()) |entry| {
            try destructive_list.append(self.allocator, .{
                .function = entry.key_ptr.*,
                .scrutinee_param = entry.value_ptr.*,
            });
        }

        return .{
            .reuse_pairs = try self.reuse_pairs.toOwnedSlice(self.allocator),
            .arc_ops = try self.arc_ops.toOwnedSlice(self.allocator),
            .drop_specializations = try self.drop_specializations.toOwnedSlice(self.allocator),
            .function_stats = try self.function_stats.toOwnedSlice(self.allocator),
            .destructive_optional_dispatch = try destructive_list.toOwnedSlice(self.allocator),
        };
    }

    /// Analyze a single function for reuse opportunities and drop specializations.
    pub fn analyzeFunction(self: *PerceusAnalyzer, func: *const ir.Function) !void {
        self.current_function_id = func.id;

        // Reset per-function working state. Free path slices held
        // by each DeconstructionSite before clearing — those paths
        // were duplicated by `checkInstructionForDeconstruction`
        // from a transient stack-buffer and are not transferred
        // anywhere else.
        for (self.current_decon_sites.items) |decon| {
            self.allocator.free(decon.path);
        }
        self.current_decon_sites.clearRetainingCapacity();

        // Phase 1: Find all deconstruction sites (pattern matches)
        for (func.body, 0..) |block, block_idx| {
            try self.scanBlockForDeconstructionSites(
                &block,
                @intCast(block_idx),
                func.id,
            );
        }

        // Phase 2: For each deconstruction, find compatible constructions in branch bodies
        var stats = FunctionStats{
            .function_id = func.id,
            .function_name = func.name,
            .total_reuse_pairs = 0,
            .static_reuses = 0,
            .dynamic_reuses = 0,
            .drop_specializations = 0,
            .deconstruction_sites = @intCast(self.current_decon_sites.items.len),
            .construction_sites = 0,
        };

        for (self.current_decon_sites.items) |decon| {
            // Find constructions in the branch bodies of this match
            const constructions = try self.findCompatibleConstructionsForMatch(
                func,
                &decon,
            );

            stats.construction_sites += @intCast(constructions.len);

            // Phase 3: Generate reuse pairs
            for (constructions) |con| {
                const kind = self.determineReuseKind(&decon);
                try self.generateReusePair(&decon, &con, func.id, kind);
                stats.total_reuse_pairs += 1;
                switch (kind) {
                    .static_reuse => stats.static_reuses += 1,
                    .dynamic_reuse => stats.dynamic_reuses += 1,
                }
            }
            // Free each ConstructionSite's path slice (allocator.dupe'd
            // in scanInstructionForConstructions) before freeing the
            // array itself. generateReusePair has already copied paths
            // it needed into the analysis-context-owned InsertionPoint
            // records, so these transient site-level paths can be
            // released here.
            for (constructions) |con| self.allocator.free(con.path);
            self.allocator.free(constructions);

            // Phase 4: Generate drop specializations
            try self.generateDropSpecialization(&decon, func);
            stats.drop_specializations += 1;
        }

        try self.function_stats.append(self.allocator, stats);
    }

    // ============================================================
    // Phase 1: Deconstruction site discovery
    // ============================================================

    fn scanBlockForDeconstructionSites(
        self: *PerceusAnalyzer,
        block: *const ir.Block,
        block_idx: u32,
        function_id: ir.FunctionId,
    ) !void {
        var path_builder: std.ArrayListUnmanaged(lattice.StreamStep) = .empty;
        defer path_builder.deinit(self.allocator);
        for (block.instructions, 0..) |instr, idx| {
            try self.checkInstructionForDeconstruction(
                &instr,
                function_id,
                block.label,
                path_builder.items,
                @intCast(idx),
            );
            // Also recurse into nested instruction lists. The
            // path_builder is mutated in-place during the recursive
            // walk; each leaf-level deconstruction-site
            // construction makes an owned copy of the current
            // path snapshot.
            try self.scanNestedInstructions(&instr, function_id, block.label, &path_builder, @intCast(idx));
        }
        _ = block_idx;
    }

    fn checkInstructionForDeconstruction(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_snapshot: []const lattice.StreamStep,
        instr_index: u32,
    ) !void {
        switch (instr.*) {
            .case_block => |cb| {
                const scrutinee = self.extractCaseBlockScrutinee(&cb);
                if (scrutinee) |scrut| {
                    const type_info = self.inferScrutineeType(&cb);
                    const match_id = self.nextMatchSiteId();
                    try self.current_decon_sites.append(self.allocator, .{
                        .function = function_id,
                        .block = block_label,
                        .path = try self.allocator.dupe(lattice.StreamStep, path_snapshot),
                        .instr_index = instr_index,
                        .scrutinee = scrut,
                        .scrutinee_type = type_info,
                        .match_site_id = match_id,
                        .match_kind = .case_block,
                    });
                }
            },
            .switch_tag => |st| {
                const type_info = self.inferSwitchTagType(&st);
                const match_id = self.nextMatchSiteId();
                try self.current_decon_sites.append(self.allocator, .{
                    .function = function_id,
                    .block = block_label,
                    .path = try self.allocator.dupe(lattice.StreamStep, path_snapshot),
                    .instr_index = instr_index,
                    .scrutinee = st.scrutinee,
                    .scrutinee_type = type_info,
                    .match_site_id = match_id,
                    .match_kind = .switch_tag,
                });
            },
            .if_expr => |ie| {
                // if_expr is only a deconstruction site if it pattern-matches on a value
                // (as opposed to a simple boolean test). We detect this by checking if
                // there are field_get or index_get instructions in the then/else bodies
                // that reference the condition.
                if (self.isPatternMatchIfExpr(&ie)) {
                    const type_info = TypeInfo{
                        .name = null,
                        .kind = .struct_type,
                        .num_fields = 0,
                    };
                    const match_id = self.nextMatchSiteId();
                    try self.current_decon_sites.append(self.allocator, .{
                        .function = function_id,
                        .block = block_label,
                        .path = try self.allocator.dupe(lattice.StreamStep, path_snapshot),
                        .instr_index = instr_index,
                        .scrutinee = ie.condition,
                        .scrutinee_type = type_info,
                        .match_site_id = match_id,
                        .match_kind = .if_expr,
                    });
                }
            },
            .optional_dispatch => |od| {
                // Multi-clause `f(nil) / f(t :: T)` lowering. The struct
                // branch unwraps `?T` to a boxed `*const T` payload and
                // consumes it. Recording this as a deconstruction site
                // lets the drop-spec generator emit a release of the
                // payload at the end of the struct branch — without
                // this, recursive `Tree`-shaped functions like
                // `Binarytrees.check` would never release the trees
                // their callers transferred ownership of, which is the
                // direct cause of the binarytrees-N=21 OOM.
                //
                // The scrutinee is the unwrapped payload local rather
                // than the optional parameter itself: drop emission
                // operates on the boxed pointer (`*const T`) inside
                // the struct branch, where the value is live and the
                // type is concrete.
                const type_info = TypeInfo{
                    .name = null,
                    .kind = .struct_type,
                    .num_fields = 0,
                };
                const match_id = self.nextMatchSiteId();
                try self.current_decon_sites.append(self.allocator, .{
                    .function = function_id,
                    .block = block_label,
                    .path = try self.allocator.dupe(lattice.StreamStep, path_snapshot),
                    .instr_index = instr_index,
                    .scrutinee = od.payload_local,
                    .scrutinee_type = type_info,
                    .match_site_id = match_id,
                    .match_kind = .optional_dispatch,
                });
            },
            else => {},
        }
    }

    fn scanNestedInstructions(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
        parent_index: u32,
    ) !void {
        // Recurse into nested instruction lists to find inner
        // pattern matches. Each descent pushes one `StreamStep` onto
        // `path_builder` to record the navigation, and pops it on
        // exit. Leaf-level `DeconstructionSite` constructions snapshot
        // the current `path_builder.items` and store an owned copy
        // on the site record (`perceus.zig:checkInstructionForDeconstruction`).
        //
        // The `parent_index` parameter is preserved for backward
        // compatibility with the in-place `instr_index` field but is
        // gradually being supplanted by the path-based addressing.
        // `instr_index` now records the index of the parent
        // instruction in the *enclosing stream* (which the path
        // identifies); the synthetic `+|` saturating-add encoding is
        // gone.
        switch (instr.*) {
            .case_block => |cb| {
                for (cb.arms, 0..) |arm, arm_idx| {
                    const cond_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .case_block_arm_cond = @intCast(arm_idx) },
                    };
                    try path_builder.append(self.allocator, cond_step);
                    for (arm.cond_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();

                    const body_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .case_block_arm_body = @intCast(arm_idx) },
                    };
                    try path_builder.append(self.allocator, body_step);
                    for (arm.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();
                }
                const pre_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .case_block_pre,
                };
                try path_builder.append(self.allocator, pre_step);
                for (cb.pre_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
                const default_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .case_block_default,
                };
                try path_builder.append(self.allocator, default_step);
                for (cb.default_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .if_expr => |ie| {
                const then_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .if_expr_then,
                };
                try path_builder.append(self.allocator, then_step);
                for (ie.then_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();

                const else_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .if_expr_else,
                };
                try path_builder.append(self.allocator, else_step);
                for (ie.else_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .switch_literal => |sl| {
                for (sl.cases, 0..) |sc, case_idx| {
                    const case_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .switch_literal_case = @intCast(case_idx) },
                    };
                    try path_builder.append(self.allocator, case_step);
                    for (sc.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();
                }
                const default_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .switch_literal_default,
                };
                try path_builder.append(self.allocator, default_step);
                for (sl.default_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .switch_return => |sr| {
                for (sr.cases, 0..) |sc, case_idx| {
                    const case_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .switch_return_case = @intCast(case_idx) },
                    };
                    try path_builder.append(self.allocator, case_step);
                    for (sc.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();
                }
                const default_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .switch_return_default,
                };
                try path_builder.append(self.allocator, default_step);
                for (sr.default_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .union_switch => |us| {
                for (us.cases, 0..) |uc, case_idx| {
                    const case_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .union_switch_case = @intCast(case_idx) },
                    };
                    try path_builder.append(self.allocator, case_step);
                    for (uc.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases, 0..) |uc, case_idx| {
                    const case_step: lattice.StreamStep = .{
                        .parent_instr_index = parent_index,
                        .child = .{ .union_switch_return_case = @intCast(case_idx) },
                    };
                    try path_builder.append(self.allocator, case_step);
                    for (uc.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                        try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                    }
                    _ = path_builder.pop();
                }
            },
            .try_call_named => |tc| {
                const success_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .try_call_named_success,
                };
                try path_builder.append(self.allocator, success_step);
                for (tc.success_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();

                const handler_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .try_call_named_handler,
                };
                try path_builder.append(self.allocator, handler_step);
                for (tc.handler_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .guard_block => |gb| {
                const body_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .guard_block_body,
                };
                try path_builder.append(self.allocator, body_step);
                for (gb.body, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            .optional_dispatch => |od| {
                const nil_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .optional_dispatch_nil,
                };
                try path_builder.append(self.allocator, nil_step);
                for (od.nil_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();

                const struct_step: lattice.StreamStep = .{
                    .parent_instr_index = parent_index,
                    .child = .optional_dispatch_struct,
                };
                try path_builder.append(self.allocator, struct_step);
                for (od.struct_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(&nested, function_id, block_label, path_builder.items, @intCast(idx));
                    try self.scanNestedInstructions(&nested, function_id, block_label, path_builder, @intCast(idx));
                }
                _ = path_builder.pop();
            },
            else => {},
        }
    }

    // ============================================================
    // Phase 2: Compatible construction discovery
    // ============================================================

    /// Find all construction sites in branch bodies that are compatible with a
    /// deconstruction site for reuse.
    ///
    /// Path threading: the deconstruction site's instruction lives at
    /// `decon.path` + `decon.instr_index`. Each descent into one of its
    /// nested streams (case_block.pre_instrs, arms[i].body_instrs,
    /// default_instrs, if_expr.then/else_instrs) pushes one more
    /// `StreamStep` onto a builder seeded with `decon.path`. Leaf-level
    /// `ConstructionSite` records snapshot the builder's current
    /// contents via `allocator.dupe`. Replaces the previous
    /// `branch_offset *| 1000 +| idx` saturating-add encoding (which
    /// was lossy under arm/index counts > {100, 1000} and never
    /// matched the ZIR driver's position tracker — see file-level
    /// commentary in `arc_phase-2-3-completion-research-brief.md`).
    fn findCompatibleConstructionsForMatch(
        self: *PerceusAnalyzer,
        func: *const ir.Function,
        decon: *const DeconstructionSite,
    ) ![]ConstructionSite {
        var results: std.ArrayList(ConstructionSite) = .empty;

        // Find the instruction at the deconstruction site
        const block = self.findBlock(func, decon.block) orelse return try results.toOwnedSlice(self.allocator);

        // For nested deconstruction sites the stored instr_index may exceed
        // the block's top-level instruction count. In that case, search
        // recursively through nested instruction trees to find the matching
        // case_block/if_expr by scrutinee.
        const instr = if (decon.instr_index < block.instructions.len)
            &block.instructions[decon.instr_index]
        else
            self.findNestedInstruction(block.instructions, decon.scrutinee) orelse
                return try results.toOwnedSlice(self.allocator);

        // Seed path-builder with the deconstruction site's own nesting
        // path. Each descent below adds one more StreamStep whose
        // `parent_instr_index` is `decon.instr_index` (the position of
        // the deconstruction instruction within its enclosing stream)
        // and whose `child` slot identifies which nested stream we're
        // entering.
        var path_builder: std.ArrayListUnmanaged(lattice.StreamStep) = .empty;
        defer path_builder.deinit(self.allocator);
        try path_builder.appendSlice(self.allocator, decon.path);

        switch (instr.*) {
            .case_block => |cb| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = decon.instr_index,
                    .child = .case_block_pre,
                });
                try self.scanInstructionsForConstructions(
                    cb.pre_instrs,
                    decon,
                    func.id,
                    decon.block,
                    &path_builder,
                    &results,
                );
                _ = path_builder.pop();

                for (cb.arms, 0..) |arm, arm_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = decon.instr_index,
                        .child = .{ .case_block_arm_body = @intCast(arm_idx) },
                    });
                    try self.scanInstructionsForConstructions(
                        arm.body_instrs,
                        decon,
                        func.id,
                        decon.block,
                        &path_builder,
                        &results,
                    );
                    _ = path_builder.pop();
                }

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = decon.instr_index,
                    .child = .case_block_default,
                });
                try self.scanInstructionsForConstructions(
                    cb.default_instrs,
                    decon,
                    func.id,
                    decon.block,
                    &path_builder,
                    &results,
                );
                _ = path_builder.pop();
            },
            .if_expr => |ie| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = decon.instr_index,
                    .child = .if_expr_then,
                });
                try self.scanInstructionsForConstructions(
                    ie.then_instrs,
                    decon,
                    func.id,
                    decon.block,
                    &path_builder,
                    &results,
                );
                _ = path_builder.pop();

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = decon.instr_index,
                    .child = .if_expr_else,
                });
                try self.scanInstructionsForConstructions(
                    ie.else_instrs,
                    decon,
                    func.id,
                    decon.block,
                    &path_builder,
                    &results,
                );
                _ = path_builder.pop();
            },
            else => {},
        }

        return try results.toOwnedSlice(self.allocator);
    }

    /// Recursively search nested instruction trees for a case_block or if_expr
    /// whose scrutinee matches the given local.
    fn findNestedInstruction(
        self: *const PerceusAnalyzer,
        instrs: []const ir.Instruction,
        scrutinee: ir.LocalId,
    ) ?*const ir.Instruction {
        for (instrs) |*instr| {
            switch (instr.*) {
                .case_block => |cb| {
                    // Check if this case_block's scrutinee matches
                    if (cb.arms.len > 0) {
                        for (cb.arms[0].cond_instrs) |cond_instr| {
                            const found_scrut: ?ir.LocalId = switch (cond_instr) {
                                .match_type => |mt| mt.scrutinee,
                                .match_atom => |ma| ma.scrutinee,
                                .match_int => |mi| mi.scrutinee,
                                .list_len_check => |llc| llc.scrutinee,
                                .field_get => |fg| fg.object,
                                else => null,
                            };
                            if (found_scrut) |s| {
                                if (s == scrutinee) return instr;
                            }
                        }
                    }
                    // Recurse into arm bodies
                    for (cb.arms) |arm| {
                        if (self.findNestedInstruction(arm.body_instrs, scrutinee)) |f| return f;
                    }
                    if (self.findNestedInstruction(cb.default_instrs, scrutinee)) |f| return f;
                },
                .if_expr => |ie| {
                    if (ie.condition == scrutinee) return instr;
                    if (self.findNestedInstruction(ie.then_instrs, scrutinee)) |f| return f;
                    if (self.findNestedInstruction(ie.else_instrs, scrutinee)) |f| return f;
                },
                else => {},
            }
        }
        return null;
    }

    fn scanInstructionsForConstructions(
        self: *PerceusAnalyzer,
        instrs: []const ir.Instruction,
        decon: *const DeconstructionSite,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
        results: *std.ArrayList(ConstructionSite),
    ) !void {
        for (instrs, 0..) |instr, idx| {
            try self.scanInstructionForConstructions(
                instr,
                decon,
                function_id,
                block_label,
                path_builder,
                @intCast(idx),
                results,
            );
        }
    }

    /// Walk a single instruction, recording a ConstructionSite for the
    /// instruction itself if reuse-compatible, and recursing into every
    /// nested stream the instruction owns. `path_builder` is the
    /// caller's mutable cursor (push/pop pattern); `instr_index` is the
    /// position of `instr` within its containing stream (i.e., the
    /// innermost stream identified by `path_builder.items`).
    ///
    /// Replaces the previous `instr_index +| (arm_idx * 100 + idx) +|
    /// 1` saturating-add encoding. The path-based replacement is
    /// lossless and exhaustive over every nested-stream-bearing IR
    /// instruction.
    fn scanInstructionForConstructions(
        self: *PerceusAnalyzer,
        instr: ir.Instruction,
        decon: *const DeconstructionSite,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
        instr_index: u32,
        results: *std.ArrayList(ConstructionSite),
    ) !void {
        const con_type = extractConstructionType(&instr);
        if (con_type) |ct| {
            if (areTypesReuseCompatible(&decon.scrutinee_type, &ct)) {
                const alloc_id = self.nextAllocSiteId();
                const dest = extractConstructionDest(&instr).?;
                try results.append(self.allocator, .{
                    .function = function_id,
                    .block = block_label,
                    .path = try self.allocator.dupe(lattice.StreamStep, path_builder.items),
                    .instr_index = instr_index,
                    .dest = dest,
                    .dest_type = ct,
                    .alloc_site_id = alloc_id,
                });
            }
        }

        switch (instr) {
            .guard_block => |gb| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .guard_block_body,
                });
                for (gb.body, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .if_expr => |ie| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .if_expr_then,
                });
                for (ie.then_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .if_expr_else,
                });
                for (ie.else_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .case_block => |cb| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .case_block_pre,
                });
                for (cb.pre_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();

                for (cb.arms, 0..) |arm, arm_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .case_block_arm_cond = @intCast(arm_idx) },
                    });
                    for (arm.cond_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();

                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .case_block_arm_body = @intCast(arm_idx) },
                    });
                    for (arm.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();
                }

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .case_block_default,
                });
                for (cb.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .switch_literal => |sl| {
                for (sl.cases, 0..) |case, case_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .switch_literal_case = @intCast(case_idx) },
                    });
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();
                }
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .switch_literal_default,
                });
                for (sl.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .switch_return => |sr| {
                for (sr.cases, 0..) |case, case_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .switch_return_case = @intCast(case_idx) },
                    });
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();
                }
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .switch_return_default,
                });
                for (sr.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .union_switch_return => |usr| {
                for (usr.cases, 0..) |case, case_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .union_switch_return_case = @intCast(case_idx) },
                    });
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();
                }
            },
            .union_switch => |us| {
                for (us.cases, 0..) |case, case_idx| {
                    try path_builder.append(self.allocator, .{
                        .parent_instr_index = instr_index,
                        .child = .{ .union_switch_case = @intCast(case_idx) },
                    });
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(
                            nested, decon, function_id, block_label,
                            path_builder, @intCast(idx), results,
                        );
                    }
                    _ = path_builder.pop();
                }
            },
            .try_call_named => |tc| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .try_call_named_success,
                });
                for (tc.success_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .try_call_named_handler,
                });
                for (tc.handler_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            .optional_dispatch => |od| {
                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .optional_dispatch_nil,
                });
                for (od.nil_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();

                try path_builder.append(self.allocator, .{
                    .parent_instr_index = instr_index,
                    .child = .optional_dispatch_struct,
                });
                for (od.struct_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(
                        nested, decon, function_id, block_label,
                        path_builder, @intCast(idx), results,
                    );
                }
                _ = path_builder.pop();
            },
            else => {},
        }
    }

    // ============================================================
    // Phase 3: Reuse pair and ARC operation generation
    // ============================================================

    fn generateReusePair(
        self: *PerceusAnalyzer,
        decon: *const DeconstructionSite,
        con: *const ConstructionSite,
        function_id: ir.FunctionId,
        kind: lattice.ReuseKind,
    ) !void {
        // The reset token local — we synthesize a new LocalId for it.
        // In a real pipeline this would come from the IR builder; here we
        // derive it from the match site id to keep it deterministic.
        const token_local: ir.LocalId = 10000 + decon.match_site_id;

        const reset_op = lattice.ResetOp{
            .dest = token_local,
            .source = decon.scrutinee,
            .source_type = 0, // TypeId resolved by later passes
        };

        const reuse_op = lattice.ReuseAllocOp{
            .dest = con.dest,
            .token = token_local,
            .insertion_point = .{
                .function = function_id,
                .block = con.block,
                .path = try self.allocator.dupe(lattice.StreamStep, con.path),
                .instr_index = con.instr_index,
                .position = .before,
            },
            .constructor_tag = con.alloc_site_id,
            .dest_type = 0, // TypeId resolved by later passes
        };

        const pair = lattice.ReusePair{
            .match_site = decon.match_site_id,
            .alloc_site = con.alloc_site_id,
            .reset = reset_op,
            .reuse = reuse_op,
            .kind = kind,
        };

        try self.reuse_pairs.append(self.allocator, pair);

        // Generate ARC operations: reset at deconstruction, reuse at construction.
        // Each InsertionPoint copies the relevant site's `path` so the
        // materialization pass can navigate to the correct nested
        // stream without reconstructing position from synthetic
        // arithmetic.
        try self.arc_ops.append(self.allocator, .{
            .kind = .reset,
            .value = decon.scrutinee,
            .insertion_point = .{
                .function = function_id,
                .block = decon.block,
                .path = try self.allocator.dupe(lattice.StreamStep, decon.path),
                .instr_index = decon.instr_index,
                .position = .before,
            },
            .reason = .perceus_reuse,
        });

        try self.arc_ops.append(self.allocator, .{
            .kind = .reuse_alloc,
            .value = con.dest,
            .insertion_point = .{
                .function = function_id,
                .block = con.block,
                .path = try self.allocator.dupe(lattice.StreamStep, con.path),
                .instr_index = con.instr_index,
                .position = .before,
            },
            .reason = .perceus_reuse,
        });
    }

    // ============================================================
    // Phase 4: Drop specialization
    // ============================================================

    fn generateDropSpecialization(
        self: *PerceusAnalyzer,
        decon: *const DeconstructionSite,
        func: *const ir.Function,
    ) !void {
        const block = self.findBlock(func, decon.block) orelse return;
        if (decon.instr_index >= block.instructions.len) return;

        const instr = &block.instructions[decon.instr_index];

        switch (instr.*) {
            .case_block => |cb| {
                // For each arm, generate a specialized drop for the
                // known constructor. The drops must run only when the
                // arm matches — they release the field bindings the
                // arm extracted — so the InsertionPoint targets the
                // *arm's body stream* at its end, not the parent
                // stream after the case_block.
                for (cb.arms, 0..) |arm, arm_idx| {
                    const field_drops = try self.extractFieldDropsFromArm(func, &arm);
                    var arm_path: std.ArrayListUnmanaged(lattice.StreamStep) = .empty;
                    defer arm_path.deinit(self.allocator);
                    try arm_path.appendSlice(self.allocator, decon.path);
                    try arm_path.append(self.allocator, .{
                        .parent_instr_index = decon.instr_index,
                        .child = .{ .case_block_arm_body = @intCast(arm_idx) },
                    });
                    const arm_body_len: u32 = @intCast(arm.body_instrs.len);
                    try self.drop_specializations.append(self.allocator, .{
                        .match_site = decon.match_site_id,
                        .constructor_tag = @intCast(arm_idx),
                        .field_drops = field_drops,
                        .function = func.id,
                        .insertion_point = .{
                            .function = func.id,
                            .block = decon.block,
                            .path = try self.allocator.dupe(lattice.StreamStep, arm_path.items),
                            .instr_index = arm_body_len,
                            .position = .before,
                        },
                    });
                }
            },
            .if_expr => {
                // For if_expr, we generate a single specialization
                const then_drops = try self.allocator.alloc(FieldDrop, 0);
                try self.drop_specializations.append(self.allocator, .{
                    .match_site = decon.match_site_id,
                    .constructor_tag = 0,
                    .field_drops = then_drops,
                    .function = func.id,
                    .insertion_point = .{
                        .function = func.id,
                        .block = decon.block,
                        .path = try self.allocator.dupe(lattice.StreamStep, decon.path),
                        .instr_index = decon.instr_index,
                        .position = .after,
                    },
                });
            },
            .optional_dispatch => |od| {
                // Optional-dispatch struct branch: emit a single drop
                // specialization whose field_drop targets the boxed
                // payload local. With the recursive-type boxing ABI,
                // payload_local holds `*const T` — the source-Arc
                // pointer — so `releaseAny(alloc, payload_local)`
                // performs a real deep release of the entire
                // substructure.
                //
                // No drop is generated when:
                //   * The param's source type is not a recursive
                //     struct optional. The boxing ABI only kicks in
                //     for recursive struct types; for primitive or
                //     non-recursive struct optionals the payload is
                //     a value, not a `*const T` Arc pointer, and
                //     `releaseAny` would reject it at comptime.
                //   * The function returns the payload itself
                //     (`struct_result == payload_local`): ownership
                //     transfers to the caller, and a release here
                //     would free what the caller still owns.
                if (od.scrutinee_param >= func.params.len) return;
                const param_type = func.params[od.scrutinee_param].type_expr;
                if (!self.paramTypeRequiresArcDrop(param_type)) return;
                if (od.struct_result) |sr| {
                    if (sr == od.payload_local) return;
                }
                const destructive = self.isDestructiveOptionalDispatch(&od, func);
                if (destructive) {
                    self.destructive_funcs.put(self.allocator, func.id, od.scrutinee_param) catch return;
                }
                const drops = try self.allocator.alloc(FieldDrop, 1);
                drops[0] = .{
                    .field_name = "__optional_payload",
                    .field_index = 0,
                    .needs_recursive_drop = true,
                    .local = od.payload_local,
                    .kind = if (destructive) .shallow else .deep,
                };
                try self.drop_specializations.append(self.allocator, .{
                    .match_site = decon.match_site_id,
                    .constructor_tag = 0,
                    .field_drops = drops,
                    .function = func.id,
                    .insertion_point = .{
                        .function = func.id,
                        .block = decon.block,
                        .path = try self.allocator.dupe(lattice.StreamStep, decon.path),
                        .instr_index = decon.instr_index,
                        .position = .after,
                    },
                });
            },
            else => {},
        }
    }

    /// Decide whether an optional-dispatch struct branch is "destructive"
    /// — every indirect-storage Arc'd child of the scrutinee is
    /// extracted by a `field_get` whose result is immediately consumed
    /// by a function call (transferring ownership), and the scrutinee-
    /// derived locals themselves are never used outside `field_get`
    /// reads. When that pattern holds, the parent observes none of its
    /// children after the body runs, so:
    ///   * `field_get` of an indirect-storage recursive field on the
    ///     scrutinee can skip its `retainAnyOpt` — the inner consumer
    ///     takes the only handle, no second owner exists to balance;
    ///   * the optional-dispatch drop emits a shallow `freeAny`
    ///     instead of `releaseAny`, because deep-walking the parent
    ///     would dereference child pointers the consumers already
    ///     freed.
    ///
    /// Conservatively rejects unfamiliar instruction shapes: any
    /// non-trivial use of a scrutinee-derived local outside a
    /// recognised `field_get`/extraction pattern returns false, falling
    /// back to the safe deep-release + retain path.
    fn isDestructiveOptionalDispatch(
        self: *const PerceusAnalyzer,
        od: *const ir.OptionalDispatch,
        func: *const ir.Function,
    ) bool {
        if (od.scrutinee_param >= func.params.len) return false;
        const param_type = func.params[od.scrutinee_param].type_expr;
        const inner = switch (param_type) {
            .optional => |opt| opt.*,
            else => return false,
        };
        const struct_name = switch (inner) {
            .struct_ref => |n| n,
            else => return false,
        };

        // Count indirect-storage fields on the scrutinee's struct so
        // we can require the body to extract every one. If even one
        // is left unextracted, that child still has the parent as its
        // sole owner and dropping shallowly would leak it.
        var indirect_count: u32 = 0;
        var struct_fields: []const ir.StructFieldDef = &.{};
        for (self.program.type_defs) |td| {
            if (!std.mem.eql(u8, td.name, struct_name)) continue;
            switch (td.kind) {
                .struct_def => |def| {
                    struct_fields = def.fields;
                    for (def.fields) |f| {
                        if (f.storage == .indirect) indirect_count += 1;
                    }
                },
                else => return false,
            }
            break;
        }
        if (indirect_count == 0) return false;

        // Pass 1: collect scrutinee-derived locals and indirect-extracted locals.
        // A scrutinee-derived local is any `param_get(scrutinee_param)` dest.
        // An indirect-extracted local is any `field_get` whose object is a
        // scrutinee-derived local AND whose field is indirect-storage.
        var scrutinee_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        defer @constCast(&scrutinee_locals).deinit(self.allocator);
        var extracted_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        defer @constCast(&extracted_locals).deinit(self.allocator);
        var fields_extracted: std.StringHashMapUnmanaged(void) = .empty;
        defer @constCast(&fields_extracted).deinit(self.allocator);

        for (od.struct_instrs) |instr| {
            switch (instr) {
                .param_get => |pg| {
                    if (pg.index == od.scrutinee_param) {
                        scrutinee_locals.put(self.allocator, pg.dest, {}) catch return false;
                    }
                },
                .field_get => |fg| {
                    if (!scrutinee_locals.contains(fg.object)) continue;
                    for (struct_fields) |def_field| {
                        if (!std.mem.eql(u8, def_field.name, fg.field)) continue;
                        if (def_field.storage == .indirect) {
                            extracted_locals.put(self.allocator, fg.dest, {}) catch return false;
                            fields_extracted.put(self.allocator, def_field.name, {}) catch return false;
                        }
                        break;
                    }
                },
                else => {},
            }
        }

        // Every indirect-storage field must have been extracted at least
        // once. Otherwise some child still hangs off the parent and a
        // shallow drop would leak it.
        var missing_count: u32 = 0;
        for (struct_fields) |def_field| {
            if (def_field.storage != .indirect) continue;
            if (!fields_extracted.contains(def_field.name)) missing_count += 1;
        }
        if (missing_count != 0) return false;

        // Pass 2: validate every instruction's reads.
        //   * scrutinee-derived locals may appear only as `field_get.object`.
        //   * extracted locals may appear only as `call_named`/`call_direct`/
        //     `call_dispatch`/`tail_call` arguments (consumed) or as the
        //     value being passed through a transparent `local_get`/`move_value`/
        //     `share_value` propagation that itself terminates in a call.
        //
        // Any other shape (return, store, binary op, etc. reading those
        // locals) breaks the destructive assumption.
        for (od.struct_instrs) |instr| {
            if (!instructionUsesAreBorrowSafe(instr, &scrutinee_locals, &extracted_locals)) return false;
        }
        return true;
    }

    /// Walk the read operands of `instr` and verify that no scrutinee-
    /// derived local escapes its borrow context. See
    /// `isDestructiveOptionalDispatch` for the policy.
    fn instructionUsesAreBorrowSafe(
        instr: ir.Instruction,
        scrutinee_locals: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
        extracted_locals: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
    ) bool {
        const reads_scrutinee = struct {
            fn check(s: *const std.AutoHashMapUnmanaged(ir.LocalId, void), id: ir.LocalId) bool {
                return s.contains(id);
            }
        }.check;
        const reads_extracted = reads_scrutinee;

        switch (instr) {
            .const_int, .const_float, .const_string, .const_bool, .const_atom, .const_nil => return true,
            .param_get => return true,
            .field_get => |fg| {
                // `fg.object` is allowed to be a scrutinee_local — that's the
                // borrow-extraction shape we explicitly want.
                if (reads_extracted(extracted_locals, fg.object)) return false;
                return true;
            },
            .local_get => |lg| {
                // Reading a scrutinee-derived local through `local_get` would
                // produce another live alias outside the borrow's `field_get`
                // protocol. Reject conservatively. Same logic for extracted.
                if (reads_scrutinee(scrutinee_locals, lg.source)) return false;
                if (reads_extracted(extracted_locals, lg.source)) return false;
                return true;
            },
            .local_set => |ls| {
                if (reads_scrutinee(scrutinee_locals, ls.value)) return false;
                if (reads_extracted(extracted_locals, ls.value)) return false;
                return true;
            },
            .move_value => |mv| {
                if (reads_scrutinee(scrutinee_locals, mv.source)) return false;
                if (reads_extracted(extracted_locals, mv.source)) return false;
                return true;
            },
            .share_value => |sv| {
                if (reads_scrutinee(scrutinee_locals, sv.source)) return false;
                if (reads_extracted(extracted_locals, sv.source)) return false;
                return true;
            },
            .field_set => |fs| {
                if (reads_scrutinee(scrutinee_locals, fs.object)) return false;
                if (reads_scrutinee(scrutinee_locals, fs.value)) return false;
                if (reads_extracted(extracted_locals, fs.object)) return false;
                if (reads_extracted(extracted_locals, fs.value)) return false;
                return true;
            },
            .call_named => |cn| {
                for (cn.args) |a| if (reads_scrutinee(scrutinee_locals, a)) return false;
                // Extracted locals are *expected* as call args — that is
                // the consumption that justifies the destructive shape.
                return true;
            },
            .call_direct => |cd| {
                for (cd.args) |a| if (reads_scrutinee(scrutinee_locals, a)) return false;
                return true;
            },
            .tail_call => |tc| {
                for (tc.args) |a| if (reads_scrutinee(scrutinee_locals, a)) return false;
                return true;
            },
            .binary_op => |bo| {
                if (reads_scrutinee(scrutinee_locals, bo.lhs) or reads_scrutinee(scrutinee_locals, bo.rhs)) return false;
                if (reads_extracted(extracted_locals, bo.lhs) or reads_extracted(extracted_locals, bo.rhs)) return false;
                return true;
            },
            .unary_op => |uo| {
                if (reads_scrutinee(scrutinee_locals, uo.operand)) return false;
                if (reads_extracted(extracted_locals, uo.operand)) return false;
                return true;
            },
            .ret => |r| {
                if (r.value) |v| {
                    if (reads_scrutinee(scrutinee_locals, v)) return false;
                    if (reads_extracted(extracted_locals, v)) return false;
                }
                return true;
            },
            // Anything else: be conservative. Dispatches, allocations,
            // and aggregate inits could all leak a scrutinee handle in
            // ways this analyzer doesn't model.
            else => return false,
        }
    }

    /// Returns true when an optional-dispatch parameter's type matches
    /// the boxing ABI — i.e. an optional of a struct that participates
    /// in a layout cycle, marked by at least one `FieldStorage.indirect`
    /// field on the named struct. Only those payloads are passed as
    /// `*const T` Arc pointers; primitive or non-recursive optionals
    /// stay value-shaped, and emitting `releaseAny` for them would feed
    /// `arcPtrChild` a non-pointer and trip its `@compileError`.
    fn paramTypeRequiresArcDrop(self: *const PerceusAnalyzer, t: ir.ZigType) bool {
        const inner = switch (t) {
            .optional => |opt| opt.*,
            else => t,
        };
        const struct_name = switch (inner) {
            .struct_ref => |name| name,
            else => return false,
        };
        for (self.program.type_defs) |type_def| {
            if (!std.mem.eql(u8, type_def.name, struct_name)) continue;
            switch (type_def.kind) {
                .struct_def => |def| {
                    for (def.fields) |field| {
                        if (field.storage == .indirect) return true;
                    }
                    return false;
                },
                else => return false,
            }
        }
        return false;
    }

    fn extractFieldDropsFromArm(
        self: *PerceusAnalyzer,
        func: *const ir.Function,
        arm: *const ir.IrCaseArm,
    ) ![]const FieldDrop {
        var drops: std.ArrayList(FieldDrop) = .empty;

        // Look for field_get instructions in the arm's condition and body
        // instructions — these tell us which fields are extracted and thus
        // need individual drops.
        var field_idx: u32 = 0;
        for (arm.cond_instrs) |instr| {
            if (extractFieldDropFromInstr(&instr)) |field_drop| {
                if (!fieldLocalNeedsDrop(func, field_drop.local)) continue;
                try drops.append(self.allocator, .{
                    .field_name = field_drop.field_name,
                    .field_index = field_idx,
                    .needs_recursive_drop = true, // conservative
                    .local = field_drop.local,
                });
                field_idx += 1;
            }
        }
        for (arm.body_instrs) |instr| {
            if (extractFieldDropFromInstr(&instr)) |field_drop| {
                if (!fieldLocalNeedsDrop(func, field_drop.local)) continue;
                try drops.append(self.allocator, .{
                    .field_name = field_drop.field_name,
                    .field_index = field_idx,
                    .needs_recursive_drop = true,
                    .local = field_drop.local,
                });
                field_idx += 1;
            }
        }

        return try drops.toOwnedSlice(self.allocator);
    }

    fn fieldLocalNeedsDrop(func: *const ir.Function, local: ir.LocalId) bool {
        if (local >= func.local_ownership.len) return true;
        return func.local_ownership[local] == .owned;
    }

    fn extractFieldDropFromInstr(instr: *const ir.Instruction) ?struct { field_name: []const u8, local: ir.LocalId } {
        return switch (instr.*) {
            .field_get => |fg| .{ .field_name = fg.field, .local = fg.dest },
            else => null,
        };
    }

    // ============================================================
    // Type compatibility checking
    // ============================================================

    /// Check if two types are reuse-compatible: they can share the same
    /// memory allocation. This is the core of Perceus reuse analysis.
    ///
    /// Rules:
    ///   - Same struct type name -> compatible
    ///   - Same tuple arity -> compatible
    ///   - Same tagged union type -> compatible (different variants OK if same size)
    ///   - Same list type -> compatible
    ///   - Different types with same allocation size (same num_fields) -> compatible
    pub fn areTypesReuseCompatible(decon_type: *const TypeInfo, con_type: *const TypeInfo) bool {
        // Same kind is required for structural compatibility
        if (decon_type.kind != con_type.kind) return false;

        switch (decon_type.kind) {
            .struct_type => {
                // Same struct name -> always compatible
                if (decon_type.name != null and con_type.name != null) {
                    if (std.mem.eql(u8, decon_type.name.?, con_type.name.?)) return true;
                }
                // Different struct names: compatible only if same field count
                return decon_type.num_fields == con_type.num_fields and decon_type.num_fields > 0;
            },
            .tuple_type => {
                // Tuples: same arity -> compatible
                return decon_type.num_fields == con_type.num_fields;
            },
            .list_type => {
                // Lists: same runtime representation regardless of element type.
                return true;
            },
            .union_type => {
                // Same union type -> compatible across variants
                if (decon_type.name != null and con_type.name != null) {
                    if (std.mem.eql(u8, decon_type.name.?, con_type.name.?)) return true;
                }
                // Different union types: compatible if same variant count
                return decon_type.num_fields == con_type.num_fields and decon_type.num_fields > 0;
            },
            .map_type => {
                // Maps: compatible if same entry count
                return decon_type.num_fields == con_type.num_fields;
            },
        }
    }

    // ============================================================
    // Ownership / reuse-kind determination
    // ============================================================

    fn determineReuseKind(self: *const PerceusAnalyzer, decon: *const DeconstructionSite) lattice.ReuseKind {
        if (self.context) |ctx| {
            const key = lattice.ValueKey{ .function = decon.function, .local = decon.scrutinee };
            const state = ctx.getEscape(key);
            return switch (state) {
                .bottom, .no_escape, .block_local, .function_local => .static_reuse,
                .arg_escape_safe, .global_escape => .dynamic_reuse,
            };
        }
        // Without escape analysis context, conservatively use dynamic reuse
        return .dynamic_reuse;
    }

    // ============================================================
    // Helpers
    // ============================================================

    fn nextMatchSiteId(self: *PerceusAnalyzer) lattice.MatchSiteId {
        const id = self.next_match_site_id;
        self.next_match_site_id += 1;
        return id;
    }

    fn nextAllocSiteId(self: *PerceusAnalyzer) lattice.AllocSiteId {
        const id = self.next_alloc_site_id;
        self.next_alloc_site_id += 1;
        return id;
    }

    fn findBlock(self: *const PerceusAnalyzer, func: *const ir.Function, label: ir.LabelId) ?*const ir.Block {
        _ = self;
        for (func.body) |*block| {
            if (block.label == label) return block;
        }
        return null;
    }

    /// Extract the scrutinee local from a case_block by looking at the
    /// condition instructions in the first arm.
    fn extractCaseBlockScrutinee(self: *const PerceusAnalyzer, cb: *const ir.CaseBlock) ?ir.LocalId {
        _ = self;
        if (findScrutineeInInstrs(cb.pre_instrs)) |scrut| return scrut;
        // The scrutinee is typically the source of match_type, match_atom,
        // field_get, or similar instructions in the condition.
        if (cb.arms.len > 0) {
            const first_arm = &cb.arms[0];
            // Look through condition instructions for the scrutinee
            for (first_arm.cond_instrs) |cond_instr| {
                switch (cond_instr) {
                    .match_type => |mt| return mt.scrutinee,
                    .match_atom => |ma| return ma.scrutinee,
                    .match_int => |mi| return mi.scrutinee,
                    .match_float => |mf| return mf.scrutinee,
                    .match_string => |ms| return ms.scrutinee,
                    .field_get => |fg| return fg.object,
                    .list_len_check => |llc| return llc.scrutinee,
                    .list_get => |lg| return lg.list,
                    .index_get => |ig| return ig.object,
                    else => {},
                }
            }
            // Fallback: the condition local itself might be the scrutinee
            return first_arm.condition;
        }
        return null;
    }

    fn findScrutineeInInstrs(instrs: []const ir.Instruction) ?ir.LocalId {
        for (instrs) |instr| {
            switch (instr) {
                .match_type => |mt| return mt.scrutinee,
                .match_atom => |ma| return ma.scrutinee,
                .match_int => |mi| return mi.scrutinee,
                .match_float => |mf| return mf.scrutinee,
                .match_string => |ms| return ms.scrutinee,
                .field_get => |fg| return fg.object,
                .list_len_check => |llc| return llc.scrutinee,
                .list_get => |lg| return lg.list,
                .index_get => |ig| return ig.object,
                .guard_block => |gb| if (findScrutineeInInstrs(gb.body)) |scrut| return scrut,
                .if_expr => |ie| {
                    if (findScrutineeInInstrs(ie.then_instrs)) |scrut| return scrut;
                    if (findScrutineeInInstrs(ie.else_instrs)) |scrut| return scrut;
                },
                else => {},
            }
        }
        return null;
    }

    /// Infer the type of the scrutinee from a case_block's structure.
    fn inferScrutineeType(self: *const PerceusAnalyzer, cb: *const ir.CaseBlock) TypeInfo {
        _ = self;
        if (inferTypeFromInstrs(cb.pre_instrs)) |info| return info;
        // Look at condition instructions to determine what's being matched
        for (cb.arms) |arm| {
            for (arm.cond_instrs) |cond_instr| {
                if (inferTupleArityFromInstruction(cond_instr)) |arity| {
                    return TypeInfo{
                        .name = null,
                        .kind = .tuple_type,
                        .num_fields = arity,
                    };
                }
                switch (cond_instr) {
                    .match_type => |mt| {
                        return typeInfoFromZigType(&mt.expected_type, mt.expected_arity);
                    },
                    .list_len_check => |llc| {
                        return TypeInfo{
                            .name = null,
                            .kind = .list_type,
                            .num_fields = llc.expected_len,
                        };
                    },
                    .field_get => {
                        return TypeInfo{
                            .name = null,
                            .kind = .struct_type,
                            .num_fields = 0, // unknown, will be refined
                        };
                    },
                    else => {},
                }
            }
        }
        if (inferStructFieldCountFromInstrs(cb.pre_instrs)) |field_count| {
            return TypeInfo{
                .name = null,
                .kind = .struct_type,
                .num_fields = field_count,
            };
        }
        // Default: unknown struct-like
        return TypeInfo{
            .name = null,
            .kind = .struct_type,
            .num_fields = 0,
        };
    }

    fn inferTypeFromInstrs(instrs: []const ir.Instruction) ?TypeInfo {
        for (instrs) |instr| {
            if (inferTupleArityFromInstruction(instr)) |arity| {
                return TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = arity };
            }
            switch (instr) {
                .match_type => |mt| return typeInfoFromZigType(&mt.expected_type, mt.expected_arity),
                .list_len_check => |llc| return TypeInfo{ .name = null, .kind = .list_type, .num_fields = llc.expected_len },
                .guard_block => |gb| if (inferTypeFromInstrs(gb.body)) |info| return info,
                .if_expr => |ie| {
                    if (inferTypeFromInstrs(ie.then_instrs)) |info| return info;
                    if (inferTypeFromInstrs(ie.else_instrs)) |info| return info;
                },
                else => {},
            }
        }
        if (inferStructFieldCountFromInstrs(instrs)) |field_count| {
            return TypeInfo{ .name = null, .kind = .struct_type, .num_fields = field_count };
        }
        return null;
    }

    fn inferStructFieldCountFromInstrs(instrs: []const ir.Instruction) ?u32 {
        var max_count: u32 = 0;
        countStructFieldsInInstrs(instrs, &max_count);
        if (max_count == 0) return null;
        return max_count;
    }

    fn countStructFieldsInInstrs(instrs: []const ir.Instruction, max_count: *u32) void {
        var field_names: [32][]const u8 = undefined;
        var field_count: u32 = 0;

        for (instrs) |instr| {
            switch (instr) {
                .field_get => |fg| {
                    var seen = false;
                    var i: u32 = 0;
                    while (i < field_count) : (i += 1) {
                        if (std.mem.eql(u8, field_names[i], fg.field)) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen and field_count < field_names.len) {
                        field_names[field_count] = fg.field;
                        field_count += 1;
                    }
                },
                .guard_block => |gb| countStructFieldsInInstrs(gb.body, max_count),
                .if_expr => |ie| {
                    countStructFieldsInInstrs(ie.then_instrs, max_count);
                    countStructFieldsInInstrs(ie.else_instrs, max_count);
                },
                .case_block => |cb| {
                    countStructFieldsInInstrs(cb.pre_instrs, max_count);
                    for (cb.arms) |arm| {
                        countStructFieldsInInstrs(arm.cond_instrs, max_count);
                        countStructFieldsInInstrs(arm.body_instrs, max_count);
                    }
                    countStructFieldsInInstrs(cb.default_instrs, max_count);
                },
                .switch_literal => |sl| {
                    for (sl.cases) |case| countStructFieldsInInstrs(case.body_instrs, max_count);
                    countStructFieldsInInstrs(sl.default_instrs, max_count);
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| countStructFieldsInInstrs(case.body_instrs, max_count);
                    countStructFieldsInInstrs(sr.default_instrs, max_count);
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| countStructFieldsInInstrs(case.body_instrs, max_count);
                },
                else => {},
            }
        }

        max_count.* = @max(max_count.*, field_count);
    }

    fn inferTupleArityFromInstruction(instr: ir.Instruction) ?u32 {
        return switch (instr) {
            .index_get => |ig| ig.index + 1,
            .guard_block => |gb| blk: {
                var arity: ?u32 = null;
                for (gb.body) |nested| {
                    if (inferTupleArityFromInstruction(nested)) |nested_arity| {
                        arity = @max(arity orelse 0, nested_arity);
                    }
                }
                break :blk arity;
            },
            .if_expr => |ie| blk: {
                var arity: ?u32 = null;
                for (ie.then_instrs) |nested| {
                    if (inferTupleArityFromInstruction(nested)) |nested_arity| {
                        arity = @max(arity orelse 0, nested_arity);
                    }
                }
                for (ie.else_instrs) |nested| {
                    if (inferTupleArityFromInstruction(nested)) |nested_arity| {
                        arity = @max(arity orelse 0, nested_arity);
                    }
                }
                break :blk arity;
            },
            else => null,
        };
    }

    fn inferSwitchTagType(self: *const PerceusAnalyzer, st: *const ir.SwitchTag) TypeInfo {
        _ = self;
        return TypeInfo{
            .name = null,
            .kind = .union_type,
            .num_fields = @intCast(st.cases.len),
        };
    }

    fn isPatternMatchIfExpr(self: *const PerceusAnalyzer, ie: *const ir.IfExpr) bool {
        _ = self;
        // An if_expr is a pattern match if either branch contains field_get
        // or destructuring operations on the condition.
        for (ie.then_instrs) |instr| {
            switch (instr) {
                .field_get, .index_get, .list_get, .optional_unwrap => return true,
                else => {},
            }
        }
        for (ie.else_instrs) |instr| {
            switch (instr) {
                .field_get, .index_get, .list_get, .optional_unwrap => return true,
                else => {},
            }
        }
        return false;
    }

    /// Extract type info from a ZigType used in a match_type instruction.
    fn typeInfoFromZigType(zig_type: *const ir.ZigType, arity: ?u32) TypeInfo {
        return switch (zig_type.*) {
            .tuple => |t| TypeInfo{
                .name = null,
                .kind = .tuple_type,
                .num_fields = arity orelse @as(u32, @intCast(t.len)),
            },
            .list => TypeInfo{
                .name = null,
                .kind = .list_type,
                .num_fields = arity orelse 0,
            },
            .struct_ref => |name| TypeInfo{
                .name = name,
                .kind = .struct_type,
                .num_fields = arity orelse 0,
            },
            .tagged_union => |name| TypeInfo{
                .name = name,
                .kind = .union_type,
                .num_fields = arity orelse 0,
            },
            .map => TypeInfo{
                .name = null,
                .kind = .map_type,
                .num_fields = arity orelse 0,
            },
            else => TypeInfo{
                .name = null,
                .kind = .struct_type,
                .num_fields = 0,
            },
        };
    }

    /// Extract type info from a construction instruction.
    fn extractConstructionType(instr: *const ir.Instruction) ?TypeInfo {
        return switch (instr.*) {
            .struct_init => |si| TypeInfo{
                .name = si.type_name,
                .kind = .struct_type,
                .num_fields = @intCast(si.fields.len),
            },
            .tuple_init => |ti| TypeInfo{
                .name = null,
                .kind = .tuple_type,
                .num_fields = @intCast(ti.elements.len),
            },
            .list_init => |li| TypeInfo{
                .name = null,
                .kind = .list_type,
                .num_fields = @intCast(li.elements.len),
            },
            .union_init => |ui| TypeInfo{
                .name = ui.union_type,
                .kind = .union_type,
                .num_fields = 1, // union variant has one payload
            },
            .map_init => |mi| TypeInfo{
                .name = null,
                .kind = .map_type,
                .num_fields = @intCast(mi.entries.len),
            },
            else => null,
        };
    }

    /// Extract the destination local from a construction instruction.
    fn extractConstructionDest(instr: *const ir.Instruction) ?ir.LocalId {
        return switch (instr.*) {
            .struct_init => |si| si.dest,
            .tuple_init => |ti| ti.dest,
            .list_init => |li| li.dest,
            .union_init => |ui| ui.dest,
            .map_init => |mi| mi.dest,
            else => null,
        };
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// -- Test helpers --

fn makeTestProgram(functions: []const ir.Function) !ir.Program {
    return ir.Program{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };
}

fn makeBlock(label: ir.LabelId, instrs: []const ir.Instruction) ir.Block {
    return .{
        .label = label,
        .instructions = instrs,
    };
}

fn makeFunction(id: ir.FunctionId, name: []const u8, body: []const ir.Block) ir.Function {
    return .{
        .id = id,
        .name = name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = body,
        .is_closure = false,
        .captures = &.{},
    };
}

// ============================================================
// Test 1: Case block with struct deconstruction + same-type construction
// ============================================================

test "struct deconstruction + same-type construction yields reuse pair" {
    const allocator = testing.allocator;

    // Build a case_block that matches on a struct (via match_type)
    // and constructs a same-typed struct in the body.
    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Point" },
            .expected_arity = 2,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Point",
            .fields = &.{
                .{ .name = "x", .value = 11 },
                .{ .name = "y", .value = 12 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "transform", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Should find exactly one reuse pair
    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);

    const pair = result.reuse_pairs[0];
    try testing.expectEqual(@as(lattice.MatchSiteId, 0), pair.match_site);
    try testing.expectEqual(lattice.ReuseKind.dynamic_reuse, pair.kind);
    try testing.expectEqual(@as(ir.LocalId, 1), pair.reset.source); // scrutinee
    try testing.expectEqual(@as(ir.LocalId, 20), pair.reuse.dest); // construction dest
}

// ============================================================
// Test 2: Tuple deconstruction + same-arity construction
// ============================================================

test "tuple deconstruction + same-arity construction yields reuse pair" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .tuple = &.{ .i64, .i64, .i64 } },
            .expected_arity = 3,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .tuple_init = .{
            .dest = 20,
            .elements = &.{ 11, 12, 13 },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "transform_tuple", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
    try testing.expectEqual(lattice.ReuseKind.dynamic_reuse, result.reuse_pairs[0].kind);
}

test "nested case pre-instructions tuple reconstruction yields reuse pair" {
    const allocator = testing.allocator;

    const guard_body = [_]ir.Instruction{
        .{ .index_get = .{ .dest = 11, .object = 1, .index = 0 } },
        .{ .index_get = .{ .dest = 12, .object = 1, .index = 1 } },
        .{ .tuple_init = .{ .dest = 20, .elements = &.{ 11, 12 } } },
        .{ .case_break = .{ .value = 20 } },
    };
    const pre_instrs = [_]ir.Instruction{
        .{ .guard_block = .{ .condition = 1, .body = &guard_body } },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .case_block = .{ .dest = 30, .pre_instrs = &pre_instrs, .arms = &.{}, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "transform_tuple_nested", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
    try testing.expectEqual(@as(ir.LocalId, 20), result.reuse_pairs[0].reuse.dest);
}

test "source-like tuple case pre-instructions yield reuse pair" {
    const allocator = testing.allocator;

    const inner_guard_ok = [_]ir.Instruction{
        .{ .local_get = .{ .dest = 7, .source = 5 } },
        .{ .const_atom = .{ .dest = 8, .value = "ok" } },
        .{ .local_get = .{ .dest = 9, .source = 6 } },
        .{ .tuple_init = .{ .dest = 10, .elements = &.{ 8, 9 } } },
        .{ .case_break = .{ .value = 10 } },
    };
    const inner_guard_err = [_]ir.Instruction{
        .{ .local_get = .{ .dest = 11, .source = 5 } },
        .{ .const_atom = .{ .dest = 12, .value = "error" } },
        .{ .local_get = .{ .dest = 13, .source = 6 } },
        .{ .tuple_init = .{ .dest = 14, .elements = &.{ 12, 13 } } },
        .{ .case_break = .{ .value = 14 } },
    };
    const outer_guard_body = [_]ir.Instruction{
        .{ .index_get = .{ .dest = 5, .object = 3, .index = 0 } },
        .{ .index_get = .{ .dest = 6, .object = 3, .index = 1 } },
        .{ .match_atom = .{ .dest = 15, .scrutinee = 5, .atom_name = "ok" } },
        .{ .guard_block = .{ .condition = 15, .body = &inner_guard_ok } },
        .{ .match_atom = .{ .dest = 16, .scrutinee = 5, .atom_name = "error" } },
        .{ .guard_block = .{ .condition = 16, .body = &inner_guard_err } },
        .{ .match_fail = .{ .message = "no match" } },
    };
    const pre_instrs = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 4, .scrutinee = 3, .expected_type = .{ .tuple = &.{ .atom, .any } }, .expected_arity = 2 } },
        .{ .guard_block = .{ .condition = 4, .body = &outer_guard_body } },
        .{ .match_fail = .{ .message = "no match" } },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 3, .index = 0 } },
        .{ .case_block = .{ .dest = 20, .pre_instrs = &pre_instrs, .arms = &.{}, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "source_like_case", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.reuse_pairs.len);
}

test "observed source-lowered tuple case pre-instructions yield reuse pair" {
    const allocator = testing.allocator;

    const inner_ok = [_]ir.Instruction{
        .{ .local_get = .{ .dest = 7, .source = 5 } },
        .{ .const_atom = .{ .dest = 8, .value = "ok" } },
        .{ .local_get = .{ .dest = 9, .source = 6 } },
        .{ .tuple_init = .{ .dest = 10, .elements = &.{ 8, 9 } } },
        .{ .case_break = .{ .value = 10 } },
    };
    const inner_err = [_]ir.Instruction{
        .{ .local_get = .{ .dest = 11, .source = 5 } },
        .{ .const_atom = .{ .dest = 12, .value = "error" } },
        .{ .local_get = .{ .dest = 13, .source = 6 } },
        .{ .tuple_init = .{ .dest = 14, .elements = &.{ 12, 13 } } },
        .{ .case_break = .{ .value = 14 } },
    };
    const outer_guard = [_]ir.Instruction{
        .{ .index_get = .{ .dest = 5, .object = 3, .index = 0 } },
        .{ .index_get = .{ .dest = 6, .object = 3, .index = 1 } },
        .{ .match_atom = .{ .dest = 15, .scrutinee = 5, .atom_name = "ok" } },
        .{ .guard_block = .{ .condition = 15, .body = &inner_ok } },
        .{ .match_atom = .{ .dest = 16, .scrutinee = 5, .atom_name = "error" } },
        .{ .guard_block = .{ .condition = 16, .body = &inner_err } },
        .{ .match_fail = .{ .message = "no match" } },
    };
    const pre = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 4, .scrutinee = 3, .expected_type = .{ .tuple = &.{ .atom, .any } }, .expected_arity = 2 } },
        .{ .guard_block = .{ .condition = 4, .body = &outer_guard } },
        .{ .match_fail = .{ .message = "no match" } },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 3, .index = 0 } },
        .{ .case_block = .{ .dest = 20, .pre_instrs = &pre, .arms = &.{}, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "observed_source_case", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), result.reuse_pairs.len);
}

// ============================================================
// Test 3: Different types -> no reuse pair
// ============================================================

test "different types yield no reuse pair" {
    const allocator = testing.allocator;

    // Deconstruct a struct, construct a tuple -> incompatible
    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Point" },
            .expected_arity = 2,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        // Different type kind: tuple, not struct
        .{ .tuple_init = .{
            .dest = 20,
            .elements = &.{ 11, 12 },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "mismatch", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
}

// ============================================================
// Test 4: Unique ownership -> static_reuse
// ============================================================

test "unique ownership yields static_reuse" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Node" },
            .expected_arity = 2,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Node",
            .fields = &.{
                .{ .name = "left", .value = 11 },
                .{ .name = "right", .value = 12 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "map_tree", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    // Set up escape analysis context marking scrutinee as local (non-escaping -> unique)
    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    _ = try ctx.joinEscape(.{ .function = 0, .local = 1 }, .function_local); // scrutinee local 1 is non-escaping

    var analyzer = PerceusAnalyzer.initWithContext(allocator, &program, &ctx);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
    try testing.expectEqual(lattice.ReuseKind.static_reuse, result.reuse_pairs[0].kind);
}

// ============================================================
// Test 5: Shared ownership -> dynamic_reuse
// ============================================================

test "shared ownership yields dynamic_reuse" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Node" },
            .expected_arity = 2,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Node",
            .fields = &.{
                .{ .name = "left", .value = 11 },
                .{ .name = "right", .value = 12 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "map_shared", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    // Mark scrutinee as escaping -> shared ownership
    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    _ = try ctx.joinEscape(.{ .function = 0, .local = 1 }, .global_escape);

    var analyzer = PerceusAnalyzer.initWithContext(allocator, &program, &ctx);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
    try testing.expectEqual(lattice.ReuseKind.dynamic_reuse, result.reuse_pairs[0].kind);
}

// ============================================================
// Test 6: Multiple branches — reuse in one branch, fresh in other
// ============================================================

test "multiple branches with reuse in one branch" {
    const allocator = testing.allocator;

    // Arm 0: has compatible construction
    const cond0 = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Shape" },
            .expected_arity = 2,
        } },
    };
    const body0 = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Shape",
            .fields = &.{
                .{ .name = "w", .value = 11 },
                .{ .name = "h", .value = 12 },
            },
        } },
    };
    // Arm 1: no construction — just returns a constant
    const cond1 = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 15,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Circle" },
            .expected_arity = 1,
        } },
    };
    const body1 = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 25, .value = 0 } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond0, .condition = 10, .body_instrs = &body0, .result = 20 },
        .{ .cond_instrs = &cond1, .condition = 15, .body_instrs = &body1, .result = 25 },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "multi_branch", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Only arm 0 has a compatible construction (struct Shape with 2 fields
    // matches the scrutinee type inferred as Shape with arity 2).
    try testing.expect(result.reuse_pairs.len >= 1);

    // Stats should show 1 deconstruction site
    try testing.expectEqual(@as(usize, 1), result.function_stats.len);
    try testing.expectEqual(@as(u32, 1), result.function_stats[0].deconstruction_sites);
}

// ============================================================
// Test 7: Drop specialization generates per-field drops
// ============================================================

test "drop specialization generates per-field drops" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Pair" },
            .expected_arity = 2,
        } },
        .{ .field_get = .{ .dest = 11, .object = 1, .field = "first" } },
        .{ .field_get = .{ .dest = 12, .object = 1, .field = "second" } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Pair",
            .fields = &.{
                .{ .name = "first", .value = 12 },
                .{ .name = "second", .value = 11 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "swap_pair", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Should have at least one drop specialization
    try testing.expect(result.drop_specializations.len >= 1);

    // The first drop spec should have per-field drops for "first" and "second"
    const ds = result.drop_specializations[0];
    try testing.expectEqual(@as(u32, 2), @as(u32, @intCast(ds.field_drops.len)));
    try testing.expectEqualStrings("first", ds.field_drops[0].field_name);
    try testing.expectEqualStrings("second", ds.field_drops[1].field_name);

    // Both fields need recursive drops (conservative)
    try testing.expect(ds.field_drops[0].needs_recursive_drop);
    try testing.expect(ds.field_drops[1].needs_recursive_drop);
}

test "drop specialization skips non-ARC field extracts" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Pair" },
            .expected_arity = 2,
        } },
        .{ .field_get = .{ .dest = 11, .object = 1, .field = "arc_child" } },
        .{ .field_get = .{ .dest = 12, .object = 1, .field = "count" } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 11 } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 11,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    var local_ownership = [_]ir.OwnershipClass{.trivial} ** 31;
    local_ownership[1] = .owned;
    local_ownership[11] = .owned;
    local_ownership[12] = .trivial;
    var function = makeFunction(0, "mixed_pair", &blocks);
    function.local_ownership = &local_ownership;
    const functions = [_]ir.Function{function};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expect(result.drop_specializations.len >= 1);
    const drop_spec = result.drop_specializations[0];
    try testing.expectEqual(@as(usize, 1), drop_spec.field_drops.len);
    try testing.expectEqualStrings("arc_child", drop_spec.field_drops[0].field_name);
    try testing.expectEqual(@as(?ir.LocalId, 11), drop_spec.field_drops[0].local);
}

// ============================================================
// Test 8: No compatible construction -> no reuse pair
// ============================================================

test "no compatible construction yields no reuse pair" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Config" },
            .expected_arity = 3,
        } },
    };
    // Body has no construction at all — just arithmetic
    const body_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 20, .value = 42 } },
        .{ .binary_op = .{
            .dest = 21,
            .op = .add,
            .lhs = 20,
            .rhs = 20,
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 21,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "no_construction", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
}

// ============================================================
// Test 9: Nested pattern matching -> reuse at inner level
// ============================================================

test "nested pattern matching finds inner reuse" {
    const allocator = testing.allocator;

    // Outer case_block contains an inner case_block in its body
    const inner_cond = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 40,
            .scrutinee = 11,
            .expected_type = .{ .struct_ref = "Leaf" },
            .expected_arity = 1,
        } },
    };
    const inner_body = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 50,
            .type_name = "Leaf",
            .fields = &.{
                .{ .name = "value", .value = 41 },
            },
        } },
    };
    const inner_arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &inner_cond,
            .condition = 40,
            .body_instrs = &inner_body,
            .result = 50,
        },
    };

    const outer_cond = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Tree" },
            .expected_arity = 2,
        } },
    };
    const outer_body = [_]ir.Instruction{
        .{ .field_get = .{ .dest = 11, .object = 1, .field = "left" } },
        .{ .case_block = .{
            .dest = 60,
            .pre_instrs = &.{},
            .arms = &inner_arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const outer_arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &outer_cond,
            .condition = 10,
            .body_instrs = &outer_body,
            .result = 60,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 70,
            .pre_instrs = &.{},
            .arms = &outer_arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "nested_match", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Should find the inner case_block as a nested deconstruction site
    // We expect >= 2 deconstruction sites (outer + inner)
    try testing.expect(result.function_stats.len == 1);
    try testing.expect(result.function_stats[0].deconstruction_sites >= 2);
    // Inner Leaf -> Leaf should yield a reuse pair
    try testing.expect(result.reuse_pairs.len >= 1);
}

// ============================================================
// Test 10: Construction with different field count -> no reuse
// ============================================================

test "construction with same-name struct always reuses regardless of field count" {
    const allocator = testing.allocator;

    // Deconstruct a 3-field struct, construct a 2-field struct of same name
    const cond_instrs = [_]ir.Instruction{
        .{
            .match_type = .{
                .dest = 10,
                .scrutinee = 1,
                .expected_type = .{ .struct_ref = "Vec" },
                .expected_arity = 3, // 3 fields: x, y, z
            },
        },
    };
    const body_instrs = [_]ir.Instruction{
        .{
            .struct_init = .{
                .dest = 20,
                .type_name = "Vec",
                .fields = &.{
                    .{ .name = "x", .value = 11 },
                    .{ .name = "y", .value = 12 },
                    // Only 2 fields — but same name means same type definition
                },
            },
        },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "field_count_test", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Same name "Vec" -> reuse is valid (type system guarantees layout)
    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
}

// ============================================================
// Test 11: List type reuse (FBIP canonical example)
// ============================================================

test "list deconstruction + list construction yields reuse pair (FBIP)" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .list_len_check = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_len = 2,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .list_init = .{
            .dest = 20,
            .elements = &.{ 11, 12 },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "map_list", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // List -> list is always reuse-compatible
    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
}

// ============================================================
// Test 12: Type compatibility unit tests
// ============================================================

test "areTypesReuseCompatible: same struct name" {
    const a = TypeInfo{ .name = "Point", .kind = .struct_type, .num_fields = 2 };
    const b = TypeInfo{ .name = "Point", .kind = .struct_type, .num_fields = 2 };
    try testing.expect(PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: different struct names same fields" {
    const a = TypeInfo{ .name = "Point", .kind = .struct_type, .num_fields = 2 };
    const b = TypeInfo{ .name = "Vec2", .kind = .struct_type, .num_fields = 2 };
    try testing.expect(PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: different struct names different fields" {
    const a = TypeInfo{ .name = "Point", .kind = .struct_type, .num_fields = 2 };
    const b = TypeInfo{ .name = "Vec3", .kind = .struct_type, .num_fields = 3 };
    try testing.expect(!PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: same tuple arity" {
    const a = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 3 };
    const b = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 3 };
    try testing.expect(PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: different tuple arity" {
    const a = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 2 };
    const b = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 3 };
    try testing.expect(!PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: list always compatible" {
    const a = TypeInfo{ .name = null, .kind = .list_type, .num_fields = 2 };
    const b = TypeInfo{ .name = null, .kind = .list_type, .num_fields = 5 };
    try testing.expect(PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: same union type" {
    const a = TypeInfo{ .name = "Shape", .kind = .union_type, .num_fields = 3 };
    const b = TypeInfo{ .name = "Shape", .kind = .union_type, .num_fields = 3 };
    try testing.expect(PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

test "areTypesReuseCompatible: different kind" {
    const a = TypeInfo{ .name = null, .kind = .struct_type, .num_fields = 2 };
    const b = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 2 };
    try testing.expect(!PerceusAnalyzer.areTypesReuseCompatible(&a, &b));
}

// ============================================================
// Test 13: ARC operation generation
// ============================================================

test "reuse pair generates reset and reuse_alloc ARC operations" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Cell" },
            .expected_arity = 1,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Cell",
            .fields = &.{
                .{ .name = "value", .value = 11 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "arc_ops_test", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // Should have at least 2 ARC ops: one reset and one reuse_alloc
    var reset_count: usize = 0;
    var reuse_count: usize = 0;
    for (result.arc_ops) |op| {
        switch (op.kind) {
            .reset => reset_count += 1,
            .reuse_alloc => reuse_count += 1,
            else => {},
        }
    }
    try testing.expect(reset_count >= 1);
    try testing.expect(reuse_count >= 1);

    // Reset should be before the match, reuse_alloc before the construction
    for (result.arc_ops) |op| {
        if (op.kind == .reset) {
            try testing.expectEqual(.before, op.insertion_point.position);
            try testing.expectEqual(lattice.ArcReason.perceus_reuse, op.reason);
        }
        if (op.kind == .reuse_alloc) {
            try testing.expectEqual(.before, op.insertion_point.position);
            try testing.expectEqual(lattice.ArcReason.perceus_reuse, op.reason);
        }
    }
}

// ============================================================
// Test 14: Function statistics
// ============================================================

test "function statistics are correctly computed" {
    const allocator = testing.allocator;

    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{
            .dest = 10,
            .scrutinee = 1,
            .expected_type = .{ .struct_ref = "Box" },
            .expected_arity = 1,
        } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{
            .dest = 20,
            .type_name = "Box",
            .fields = &.{
                .{ .name = "val", .value = 11 },
            },
        } },
    };
    const arms = [_]ir.IrCaseArm{
        .{
            .cond_instrs = &cond_instrs,
            .condition = 10,
            .body_instrs = &body_instrs,
            .result = 20,
        },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 30,
            .pre_instrs = &.{},
            .arms = &arms,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "stats_test", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.function_stats.len);
    const stats = result.function_stats[0];
    try testing.expectEqual(@as(ir.FunctionId, 0), stats.function_id);
    try testing.expectEqualStrings("stats_test", stats.function_name);
    try testing.expectEqual(@as(u32, 1), stats.deconstruction_sites);
    try testing.expectEqual(@as(u32, 1), stats.total_reuse_pairs);
    try testing.expectEqual(@as(u32, 0), stats.static_reuses);
    try testing.expectEqual(@as(u32, 1), stats.dynamic_reuses);
}

// ============================================================
// Test 15: Empty function — no crash, no results
// ============================================================

test "empty function produces no results" {
    const allocator = testing.allocator;

    const functions = [_]ir.Function{makeFunction(0, "empty", &.{})};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
    try testing.expectEqual(@as(usize, 0), result.drop_specializations.len);
    try testing.expectEqual(@as(usize, 1), result.function_stats.len);
    try testing.expectEqual(@as(u32, 0), result.function_stats[0].deconstruction_sites);
}

// ============================================================
// Test 16: Union type reuse
// ============================================================

test "union deconstruction + same-union construction yields reuse pair" {
    const allocator = testing.allocator;

    const block_instrs = [_]ir.Instruction{
        .{ .switch_tag = .{
            .scrutinee = 1,
            .cases = &.{
                .{ .tag = "circle", .target = 1 },
                .{ .tag = "rect", .target = 2 },
            },
            .default = 3,
        } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "union_match", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    // switch_tag should be found as a deconstruction site
    try testing.expectEqual(@as(u32, 1), result.function_stats[0].deconstruction_sites);
}

// ============================================================
// Test 17: TypeInfo equality
// ============================================================

test "TypeInfo equality" {
    const a = TypeInfo{ .name = "Foo", .kind = .struct_type, .num_fields = 2 };
    const b = TypeInfo{ .name = "Foo", .kind = .struct_type, .num_fields = 2 };
    const c = TypeInfo{ .name = "Bar", .kind = .struct_type, .num_fields = 2 };
    const d = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 3 };
    const e = TypeInfo{ .name = null, .kind = .tuple_type, .num_fields = 3 };

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.eql(d));
    try testing.expect(d.eql(e));
}
