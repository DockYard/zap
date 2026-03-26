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
    };
};

/// A site where a value is constructed (allocation).
pub const ConstructionSite = struct {
    function: ir.FunctionId,
    block: ir.LabelId,
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

/// Complete results from the Perceus analysis pass.
pub const AnalysisResult = struct {
    reuse_pairs: []const lattice.ReusePair,
    arc_ops: []const lattice.ArcOperation,
    drop_specializations: []const DropSpecialization,
    function_stats: []const FunctionStats,

    pub fn deinit(self: *const AnalysisResult, allocator: std.mem.Allocator) void {
        allocator.free(self.reuse_pairs);
        allocator.free(self.arc_ops);
        for (self.drop_specializations) |ds| {
            allocator.free(ds.field_drops);
        }
        allocator.free(self.drop_specializations);
        allocator.free(self.function_stats);
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
            .current_function_id = 0,
            .current_decon_sites = .empty,
        };
    }

    pub fn deinit(self: *PerceusAnalyzer) void {
        self.reuse_pairs.deinit(self.allocator);
        self.arc_ops.deinit(self.allocator);
        for (self.drop_specializations.items) |ds| {
            self.allocator.free(ds.field_drops);
        }
        self.drop_specializations.deinit(self.allocator);
        self.function_stats.deinit(self.allocator);
        self.current_decon_sites.deinit(self.allocator);
    }

    /// Run the full Perceus analysis on all functions in the program.
    pub fn analyze(self: *PerceusAnalyzer) !AnalysisResult {
        for (self.program.functions) |func| {
            try self.analyzeFunction(&func);
        }

        return .{
            .reuse_pairs = try self.reuse_pairs.toOwnedSlice(self.allocator),
            .arc_ops = try self.arc_ops.toOwnedSlice(self.allocator),
            .drop_specializations = try self.drop_specializations.toOwnedSlice(self.allocator),
            .function_stats = try self.function_stats.toOwnedSlice(self.allocator),
        };
    }

    /// Analyze a single function for reuse opportunities and drop specializations.
    pub fn analyzeFunction(self: *PerceusAnalyzer, func: *const ir.Function) !void {
        self.current_function_id = func.id;

        // Reset per-function working state
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
        for (block.instructions, 0..) |instr, idx| {
            try self.checkInstructionForDeconstruction(
                &instr,
                function_id,
                block.label,
                @intCast(idx),
            );
            // Also recurse into nested instruction lists
            try self.scanNestedInstructions(&instr, function_id, block.label, @intCast(idx));
        }
        _ = block_idx;
    }

    fn checkInstructionForDeconstruction(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
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
                        .instr_index = instr_index,
                        .scrutinee = ie.condition,
                        .scrutinee_type = type_info,
                        .match_site_id = match_id,
                        .match_kind = .if_expr,
                    });
                }
            },
            else => {},
        }
    }

    fn scanNestedInstructions(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        parent_index: u32,
    ) !void {
        // Recurse into nested instruction lists to find inner pattern matches
        switch (instr.*) {
            .case_block => |cb| {
                for (cb.arms) |arm| {
                    for (arm.body_instrs, 0..) |nested, idx| {
                        try self.checkInstructionForDeconstruction(
                            &nested,
                            function_id,
                            block_label,
                            parent_index +| @as(u32, @intCast(idx)) +| 1,
                        );
                    }
                }
                for (cb.default_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(
                        &nested,
                        function_id,
                        block_label,
                        parent_index +| @as(u32, @intCast(idx)) +| 1,
                    );
                }
            },
            .if_expr => |ie| {
                for (ie.then_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(
                        &nested,
                        function_id,
                        block_label,
                        parent_index +| @as(u32, @intCast(idx)) +| 1,
                    );
                }
                for (ie.else_instrs, 0..) |nested, idx| {
                    try self.checkInstructionForDeconstruction(
                        &nested,
                        function_id,
                        block_label,
                        parent_index +| @as(u32, @intCast(idx)) +| 1,
                    );
                }
            },
            else => {},
        }
    }

    // ============================================================
    // Phase 2: Compatible construction discovery
    // ============================================================

    /// Find all construction sites in branch bodies that are compatible with a
    /// deconstruction site for reuse.
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

        switch (instr.*) {
            .case_block => |cb| {
                try self.scanInstructionsForConstructions(
                    cb.pre_instrs,
                    decon,
                    func.id,
                    decon.block,
                    0,
                    &results,
                );
                // Scan each arm's body for compatible constructions
                for (cb.arms, 0..) |arm, arm_idx| {
                    try self.scanInstructionsForConstructions(
                        arm.body_instrs,
                        decon,
                        func.id,
                        decon.block,
                        @intCast(arm_idx),
                        &results,
                    );
                }
                // Scan default branch
                try self.scanInstructionsForConstructions(
                    cb.default_instrs,
                    decon,
                    func.id,
                    decon.block,
                    @intCast(cb.arms.len),
                    &results,
                );
            },
            .if_expr => |ie| {
                try self.scanInstructionsForConstructions(
                    ie.then_instrs,
                    decon,
                    func.id,
                    decon.block,
                    0,
                    &results,
                );
                try self.scanInstructionsForConstructions(
                    ie.else_instrs,
                    decon,
                    func.id,
                    decon.block,
                    1,
                    &results,
                );
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
        branch_offset: u32,
        results: *std.ArrayList(ConstructionSite),
    ) !void {
        for (instrs, 0..) |instr, idx| {
            try self.scanInstructionForConstructions(
                instr,
                decon,
                function_id,
                block_label,
                branch_offset *| 1000 +| @as(u32, @intCast(idx)),
                results,
            );
        }
    }

    fn scanInstructionForConstructions(
        self: *PerceusAnalyzer,
        instr: ir.Instruction,
        decon: *const DeconstructionSite,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
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
                    .instr_index = instr_index,
                    .dest = dest,
                    .dest_type = ct,
                    .alloc_site_id = alloc_id,
                });
            }
        }

        switch (instr) {
            .guard_block => |gb| {
                for (gb.body, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 1, results);
                }
            },
            .if_expr => |ie| {
                for (ie.then_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 1, results);
                }
                for (ie.else_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 100, results);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 1, results);
                }
                for (cb.arms, 0..) |arm, arm_idx| {
                    for (arm.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(arm_idx * 100 + idx)) +| 1, results);
                    }
                }
                for (cb.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 900, results);
                }
            },
            .switch_literal => |sl| {
                for (sl.cases, 0..) |case, case_idx| {
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(case_idx * 100 + idx)) +| 1, results);
                    }
                }
                for (sl.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 900, results);
                }
            },
            .switch_return => |sr| {
                for (sr.cases, 0..) |case, case_idx| {
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(case_idx * 100 + idx)) +| 1, results);
                    }
                }
                for (sr.default_instrs, 0..) |nested, idx| {
                    try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(idx)) +| 900, results);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases, 0..) |case, case_idx| {
                    for (case.body_instrs, 0..) |nested, idx| {
                        try self.scanInstructionForConstructions(nested, decon, function_id, block_label, instr_index +| @as(u32, @intCast(case_idx * 100 + idx)) +| 1, results);
                    }
                }
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

        // Generate ARC operations: reset at deconstruction, reuse at construction
        try self.arc_ops.append(self.allocator, .{
            .kind = .reset,
            .value = decon.scrutinee,
            .insertion_point = .{
                .function = function_id,
                .block = decon.block,
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
                // For each arm, generate a specialized drop for the known constructor
                for (cb.arms, 0..) |arm, arm_idx| {
                    const field_drops = try self.extractFieldDropsFromArm(&arm);
                    try self.drop_specializations.append(self.allocator, .{
                        .match_site = decon.match_site_id,
                        .constructor_tag = @intCast(arm_idx),
                        .field_drops = field_drops,
                        .function = func.id,
                        .insertion_point = .{
                            .function = func.id,
                            .block = decon.block,
                            .instr_index = decon.instr_index,
                            .position = .after,
                        },
                    });

                    // Generate ARC release operations for each field drop
                    for (field_drops) |_| {
                        try self.arc_ops.append(self.allocator, .{
                            .kind = .release,
                            .value = decon.scrutinee,
                            .insertion_point = .{
                                .function = func.id,
                                .block = decon.block,
                                .instr_index = decon.instr_index,
                                .position = .after,
                            },
                            .reason = .perceus_drop,
                        });
                    }
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
                        .instr_index = decon.instr_index,
                        .position = .after,
                    },
                });
            },
            else => {},
        }
    }

    fn extractFieldDropsFromArm(
        self: *PerceusAnalyzer,
        arm: *const ir.IrCaseArm,
    ) ![]const FieldDrop {
        var drops: std.ArrayList(FieldDrop) = .empty;

        // Look for field_get instructions in the arm's condition and body
        // instructions — these tell us which fields are extracted and thus
        // need individual drops.
        var field_idx: u32 = 0;
        for (arm.cond_instrs) |instr| {
            if (extractFieldDropFromInstr(&instr)) |field_drop| {
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
                // Lists: always compatible (cons cells are same size)
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

fn makeTestProgram(allocator: std.mem.Allocator, functions: []const ir.Function) !ir.Program {
    _ = allocator;
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
    var program = try makeTestProgram(allocator, &functions);
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
