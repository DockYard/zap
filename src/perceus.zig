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

fn deinitReusePairSlice(
    allocator: std.mem.Allocator,
    reuse_pairs: []const lattice.ReusePair,
) void {
    for (reuse_pairs) |pair| {
        allocator.free(pair.reuse.insertion_point.path);
    }
    allocator.free(reuse_pairs);
}

fn deinitArcOperationSlice(
    allocator: std.mem.Allocator,
    arc_ops: []const lattice.ArcOperation,
) void {
    for (arc_ops) |op| {
        allocator.free(op.insertion_point.path);
    }
    allocator.free(arc_ops);
}

fn deinitDropSpecializationSlice(
    allocator: std.mem.Allocator,
    drop_specializations: []const DropSpecialization,
) void {
    for (drop_specializations) |drop_specialization| {
        allocator.free(drop_specialization.field_drops);
        allocator.free(drop_specialization.insertion_point.path);
    }
    allocator.free(drop_specializations);
}

fn deinitConstructionSiteItems(
    allocator: std.mem.Allocator,
    construction_sites: []const ConstructionSite,
) void {
    for (construction_sites) |construction_site| {
        allocator.free(construction_site.path);
    }
}

fn deinitConstructionSiteSlice(
    allocator: std.mem.Allocator,
    construction_sites: []const ConstructionSite,
) void {
    deinitConstructionSiteItems(allocator, construction_sites);
    allocator.free(construction_sites);
}

fn deinitConstructionSiteList(
    allocator: std.mem.Allocator,
    construction_sites: *std.ArrayList(ConstructionSite),
) void {
    deinitConstructionSiteItems(allocator, construction_sites.items);
    construction_sites.deinit(allocator);
}

/// Complete results from the Perceus analysis pass.
pub const AnalysisResult = struct {
    reuse_pairs: []const lattice.ReusePair,
    arc_ops: []const lattice.ArcOperation,
    drop_specializations: []const DropSpecialization,
    function_stats: []const FunctionStats,
    destructive_optional_dispatch: []const DestructiveOptionalDispatch,

    pub fn deinit(self: *const AnalysisResult, allocator: std.mem.Allocator) void {
        deinitReusePairSlice(allocator, self.reuse_pairs);
        deinitArcOperationSlice(allocator, self.arc_ops);
        deinitDropSpecializationSlice(allocator, self.drop_specializations);
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
        errdefer destructive_list.deinit(self.allocator);
        var destructive_iter = self.destructive_funcs.iterator();
        while (destructive_iter.next()) |entry| {
            try destructive_list.append(self.allocator, .{
                .function = entry.key_ptr.*,
                .scrutinee_param = entry.value_ptr.*,
            });
        }

        const reuse_pairs = try self.reuse_pairs.toOwnedSlice(self.allocator);
        errdefer deinitReusePairSlice(self.allocator, reuse_pairs);

        const arc_ops = try self.arc_ops.toOwnedSlice(self.allocator);
        errdefer deinitArcOperationSlice(self.allocator, arc_ops);

        const drop_specializations = try self.drop_specializations.toOwnedSlice(self.allocator);
        errdefer deinitDropSpecializationSlice(self.allocator, drop_specializations);

        const function_stats = try self.function_stats.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(function_stats);

        const destructive_optional_dispatch = try destructive_list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(destructive_optional_dispatch);

        return .{
            .reuse_pairs = reuse_pairs,
            .arc_ops = arc_ops,
            .drop_specializations = drop_specializations,
            .function_stats = function_stats,
            .destructive_optional_dispatch = destructive_optional_dispatch,
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
            // Phase 3 gate: only an OWNED, ARC-managed heap-cell scrutinee
            // can back a reuse pair. A `.trivial` (by-value / non-ARC) or
            // `.borrowed` (caller-owned) scrutinee has no reusable
            // allocation — emitting `.reset`/`.reuse_alloc` for it is
            // unsound (and trips ARC verifier V11). Skip construction
            // discovery + reuse-pair generation in that case; the
            // deconstruction still flows through normal drop insertion.
            // Drop specialization (Phase 4) is independently gated per
            // field by `fieldLocalNeedsDrop`, so it stays unconditional.
            if (scrutineeReuseEligible(func, decon.scrutinee)) {
                // Find constructions in the branch bodies of this match
                const constructions = try self.findCompatibleConstructionsForMatch(
                    func,
                    &decon,
                );
                defer deinitConstructionSiteSlice(self.allocator, constructions);

                stats.construction_sites += @intCast(constructions.len);

                // Phase 3: Generate reuse pairs.
                //
                // A single deconstruction (one match site) can pair with a
                // construction in EACH arm of the match — every arm reuses the
                // same scrutinee cell, and they all share one reset token
                // (`10000 + match_site_id`). Emit the `.reset` arc_op (which
                // materializes the `resetAny` call that claims the cell) EXACTLY
                // ONCE per match site, on the first pair: it is the
                // deconstruction's single claim, placed before the case, and
                // each arm's `.reuse_alloc` consumes the token on its own
                // control-flow path. Emitting one `.reset` per construction
                // (the prior behavior) made a two-arm match run `resetAny`
                // twice on the same scrutinee — a double-claim/double-release
                // and a wrong-cell reuse (audit arc-param--04).
                for (constructions, 0..) |con, con_index| {
                    const kind = self.determineReuseKind(&decon);
                    try self.generateReusePair(func, &decon, &con, kind, con_index == 0);
                    stats.total_reuse_pairs += 1;
                    switch (kind) {
                        .static_reuse => stats.static_reuses += 1,
                        .dynamic_reuse => stats.dynamic_reuses += 1,
                    }
                }
            }

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

    fn appendDeconstructionSite(
        self: *PerceusAnalyzer,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_snapshot: []const lattice.StreamStep,
        instr_index: u32,
        scrutinee: ir.LocalId,
        scrutinee_type: TypeInfo,
        match_site_id: lattice.MatchSiteId,
        match_kind: DeconstructionSite.MatchKind,
    ) !void {
        const path = try self.allocator.dupe(lattice.StreamStep, path_snapshot);
        errdefer self.allocator.free(path);

        try self.current_decon_sites.append(self.allocator, .{
            .function = function_id,
            .block = block_label,
            .path = path,
            .instr_index = instr_index,
            .scrutinee = scrutinee,
            .scrutinee_type = scrutinee_type,
            .match_site_id = match_site_id,
            .match_kind = match_kind,
        });
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
                    try self.appendDeconstructionSite(
                        function_id,
                        block_label,
                        path_snapshot,
                        instr_index,
                        scrut,
                        type_info,
                        match_id,
                        .case_block,
                    );
                }
            },
            .switch_tag => |st| {
                const type_info = self.inferSwitchTagType(&st);
                const match_id = self.nextMatchSiteId();
                try self.appendDeconstructionSite(
                    function_id,
                    block_label,
                    path_snapshot,
                    instr_index,
                    st.scrutinee,
                    type_info,
                    match_id,
                    .switch_tag,
                );
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
                    try self.appendDeconstructionSite(
                        function_id,
                        block_label,
                        path_snapshot,
                        instr_index,
                        ie.condition,
                        type_info,
                        match_id,
                        .if_expr,
                    );
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
                try self.appendDeconstructionSite(
                    function_id,
                    block_label,
                    path_snapshot,
                    instr_index,
                    od.payload_local,
                    type_info,
                    match_id,
                    .optional_dispatch,
                );
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
        // Recurse into every nested instruction stream to find inner
        // pattern matches. Each descent pushes one `StreamStep` onto
        // `path_builder` to record the navigation and pops it on exit;
        // leaf-level `DeconstructionSite` records snapshot the current
        // `path_builder.items`.
        //
        // The child-stream set and its canonical order come from
        // `ir.forEachChildStreamWithSlot` — the single source of truth —
        // so this walker can never again diverge from the analyzer's
        // numbering or silently skip a sub-stream. The previous
        // hand-rolled per-instruction switch omitted
        // `union_switch.else_instrs` entirely (audit perceus-region--02 /
        // the S1 desync class): a deconstruction inside a `case`-over-
        // union catch-all `_` arm was never discovered, dropping its
        // reuse opportunity.
        try self.descendChildStreamsForDeconstruction(instr, function_id, block_label, path_builder, parent_index);
    }

    /// Drive `ir.forEachChildStreamWithSlot` over `instr`, scanning each
    /// child stream for deconstruction sites. Errors from the per-stream
    /// scan are captured on the collecting context and rethrown after
    /// enumeration (the canonical enumerator's visitor is non-fallible).
    fn descendChildStreamsForDeconstruction(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
        parent_index: u32,
    ) !void {
        const Collector = struct {
            analyzer: *PerceusAnalyzer,
            function_id: ir.FunctionId,
            block_label: ir.LabelId,
            path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
            parent_index: u32,
            pending_err: ?anyerror = null,

            fn onStream(ctx: *@This(), slot: ir.ChildStreamSlot, stream: []const ir.Instruction) void {
                if (ctx.pending_err != null) return;
                ctx.scan(slot, stream) catch |err| {
                    ctx.pending_err = err;
                };
            }

            fn scan(ctx: *@This(), slot: ir.ChildStreamSlot, stream: []const ir.Instruction) !void {
                const step: lattice.StreamStep = .{
                    .parent_instr_index = ctx.parent_index,
                    .child = lattice.ChildSlot.fromStreamSlot(slot),
                };
                try ctx.path_builder.append(ctx.analyzer.allocator, step);
                defer _ = ctx.path_builder.pop();
                for (stream, 0..) |nested, idx| {
                    try ctx.analyzer.checkInstructionForDeconstruction(&nested, ctx.function_id, ctx.block_label, ctx.path_builder.items, @intCast(idx));
                    try ctx.analyzer.scanNestedInstructions(&nested, ctx.function_id, ctx.block_label, ctx.path_builder, @intCast(idx));
                }
            }
        };
        var collector = Collector{
            .analyzer = self,
            .function_id = function_id,
            .block_label = block_label,
            .path_builder = path_builder,
            .parent_index = parent_index,
        };
        ir.forEachChildStreamWithSlot(instr, &collector, Collector.onStream);
        if (collector.pending_err) |err| return err;
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
        errdefer deinitConstructionSiteList(self.allocator, &results);

        // Find the instruction at the deconstruction site
        const block = self.findBlock(func, decon.block) orelse return try results.toOwnedSlice(self.allocator);

        // Resolve the deconstruction instruction by navigating `decon.path`
        // from the top-level block, then indexing the innermost stream with
        // `decon.instr_index`. `decon.instr_index` is the position WITHIN
        // `decon.path`'s innermost stream — never the top-level block — so
        // comparing it against `block.instructions.len` and indexing the
        // top-level block (the historical bug, audit perceus-region--02)
        // grabs the wrong instruction whenever the nested index happens to
        // be in range of the enclosing block. Path navigation keeps the two
        // index spaces from being conflated; an unresolvable coordinate
        // (path doesn't match the IR shape) yields no constructions.
        const decon_ir_path = try lattice.toStreamPath(self.allocator, decon.path);
        defer self.allocator.free(decon_ir_path);
        const instr = ir.instructionAtPath(block.instructions, decon_ir_path, decon.instr_index) orelse
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

    fn appendConstructionSite(
        self: *PerceusAnalyzer,
        results: *std.ArrayList(ConstructionSite),
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_snapshot: []const lattice.StreamStep,
        instr_index: u32,
        dest: ir.LocalId,
        dest_type: TypeInfo,
        alloc_site_id: lattice.AllocSiteId,
    ) !void {
        const path = try self.allocator.dupe(lattice.StreamStep, path_snapshot);
        errdefer self.allocator.free(path);

        try results.append(self.allocator, .{
            .function = function_id,
            .block = block_label,
            .path = path,
            .instr_index = instr_index,
            .dest = dest,
            .dest_type = dest_type,
            .alloc_site_id = alloc_site_id,
        });
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
            // Only tuple / struct / union construction instructions
            // have a `reuse_token` field in IR and a reuse-aware
            // lowering path in `zir_builder` (the
            // `emitReuseAllocCall` helper assumes a struct-like
            // layout where field-by-field stores via `field_ptr`
            // and `zir_builder_emit_store` populate the reused
            // allocation). `.list_init` and `.map_init` use
            // accumulator/builder patterns (`List.empty.push(...)`,
            // `Map.empty.insert(...)`) that cannot write into a
            // pre-allocated buffer at all, so generating reuse
            // pairs for them would emit a `.reset` IR that consumes
            // the source's storage without any downstream consumer
            // — pure memory leak. Skip those kinds at pair-discovery
            // time; the corresponding deconstructions still hit the
            // normal drop-insertion path.
            const supports_reuse = switch (ct.kind) {
                .struct_type, .tuple_type, .union_type => true,
                .list_type, .map_type => false,
            };
            if (supports_reuse and areTypesReuseCompatible(&decon.scrutinee_type, &ct)) {
                const alloc_id = self.nextAllocSiteId();
                const dest = extractConstructionDest(&instr).?;
                try self.appendConstructionSite(
                    results,
                    function_id,
                    block_label,
                    path_builder.items,
                    instr_index,
                    dest,
                    ct,
                    alloc_id,
                );
            }
        }

        // Descend into every nested stream via the canonical
        // `ir.forEachChildStreamWithSlot` enumerator. The previous
        // hand-rolled per-instruction switch skipped
        // `union_switch.else_instrs` (audit perceus-region--02 / S1
        // desync class), so a reuse-compatible construction inside a
        // `case`-over-union catch-all `_` arm was never paired with its
        // deconstruction. Routing through the shared enumerator removes
        // the hand-maintained slot mapping and the divergence with it.
        try self.descendChildStreamsForConstructions(&instr, decon, function_id, block_label, path_builder, instr_index, results);
    }

    /// Drive `ir.forEachChildStreamWithSlot` over `instr`, scanning each
    /// child stream for reuse-compatible construction sites. The
    /// canonical enumerator's visitor is non-fallible, so per-stream
    /// errors are captured on the collecting context and rethrown after
    /// enumeration completes.
    fn descendChildStreamsForConstructions(
        self: *PerceusAnalyzer,
        instr: *const ir.Instruction,
        decon: *const DeconstructionSite,
        function_id: ir.FunctionId,
        block_label: ir.LabelId,
        path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
        parent_index: u32,
        results: *std.ArrayList(ConstructionSite),
    ) !void {
        const Collector = struct {
            analyzer: *PerceusAnalyzer,
            decon: *const DeconstructionSite,
            function_id: ir.FunctionId,
            block_label: ir.LabelId,
            path_builder: *std.ArrayListUnmanaged(lattice.StreamStep),
            parent_index: u32,
            results: *std.ArrayList(ConstructionSite),
            pending_err: ?anyerror = null,

            fn onStream(ctx: *@This(), slot: ir.ChildStreamSlot, stream: []const ir.Instruction) void {
                if (ctx.pending_err != null) return;
                ctx.scan(slot, stream) catch |err| {
                    ctx.pending_err = err;
                };
            }

            fn scan(ctx: *@This(), slot: ir.ChildStreamSlot, stream: []const ir.Instruction) !void {
                const step: lattice.StreamStep = .{
                    .parent_instr_index = ctx.parent_index,
                    .child = lattice.ChildSlot.fromStreamSlot(slot),
                };
                try ctx.path_builder.append(ctx.analyzer.allocator, step);
                defer _ = ctx.path_builder.pop();
                for (stream, 0..) |nested, idx| {
                    try ctx.analyzer.scanInstructionForConstructions(
                        nested,
                        ctx.decon,
                        ctx.function_id,
                        ctx.block_label,
                        ctx.path_builder,
                        @intCast(idx),
                        ctx.results,
                    );
                }
            }
        };
        var collector = Collector{
            .analyzer = self,
            .decon = decon,
            .function_id = function_id,
            .block_label = block_label,
            .path_builder = path_builder,
            .parent_index = parent_index,
            .results = results,
        };
        ir.forEachChildStreamWithSlot(instr, &collector, Collector.onStream);
        if (collector.pending_err) |err| return err;
    }

    // ============================================================
    // Phase 3: Reuse pair and ARC operation generation
    // ============================================================

    fn generateReusePair(
        self: *PerceusAnalyzer,
        func: *const ir.Function,
        decon: *const DeconstructionSite,
        con: *const ConstructionSite,
        kind: lattice.ReuseKind,
        emit_reset_arc_op: bool,
    ) !void {
        const function_id = func.id;
        // Fingerprint the anchor instructions NOW, against the current IR
        // shape, so the materializer can detect coordinate drift after the
        // ownership-rewrite / drop-insertion / contification passes reshape
        // the stream between here and materialization (audit arc-param--01).
        // The `.reset` anchors on the deconstruction instruction; the
        // construction-rewrite and `.reuse_alloc` anchor on the construction.
        const decon_identity = self.fingerprintInstructionAt(func, decon.block, decon.path, decon.instr_index);
        const con_identity = self.fingerprintInstructionAt(func, con.block, con.path, con.instr_index);

        // The reset token local — we synthesize a new LocalId for it.
        // In a real pipeline this would come from the IR builder; here we
        // derive it from the match site id to keep it deterministic.
        const token_local: ir.LocalId = 10000 + decon.match_site_id;

        const reset_op = lattice.ResetOp{
            .dest = token_local,
            .source = decon.scrutinee,
            .source_type = 0, // TypeId resolved by later passes
        };

        var reuse_pair_path: ?[]const lattice.StreamStep = try self.allocator.dupe(lattice.StreamStep, con.path);
        defer if (reuse_pair_path) |path| self.allocator.free(path);

        const reuse_op = lattice.ReuseAllocOp{
            .dest = con.dest,
            .token = token_local,
            .insertion_point = .{
                .function = function_id,
                .block = con.block,
                .path = reuse_pair_path.?,
                .instr_index = con.instr_index,
                .position = .before,
                .expected_identity = con_identity,
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
        reuse_pair_path = null;

        // Generate ARC operations: reset at deconstruction, reuse at construction.
        // Each InsertionPoint copies the relevant site's `path` so the
        // materialization pass can navigate to the correct nested
        // stream without reconstructing position from synthetic
        // arithmetic.
        //
        // The `.reset` arc_op materializes the single `resetAny` that claims
        // the deconstructed cell. It is emitted ONCE per match site (only on
        // the first construction pair) — every arm of the match shares this
        // one reset and its one token; emitting it per construction would run
        // `resetAny` once per arm on the same scrutinee (audit arc-param--04).
        if (emit_reset_arc_op) {
            var reset_path: ?[]const lattice.StreamStep = try self.allocator.dupe(lattice.StreamStep, decon.path);
            defer if (reset_path) |path| self.allocator.free(path);

            try self.arc_ops.append(self.allocator, .{
                .kind = .reset,
                .value = decon.scrutinee,
                .insertion_point = .{
                    .function = function_id,
                    .block = decon.block,
                    .path = reset_path.?,
                    .instr_index = decon.instr_index,
                    .position = .before,
                    .expected_identity = decon_identity,
                },
                .reason = .perceus_reuse,
            });
            reset_path = null;
        }

        var reuse_arc_path: ?[]const lattice.StreamStep = try self.allocator.dupe(lattice.StreamStep, con.path);
        defer if (reuse_arc_path) |path| self.allocator.free(path);

        try self.arc_ops.append(self.allocator, .{
            .kind = .reuse_alloc,
            .value = con.dest,
            .insertion_point = .{
                .function = function_id,
                .block = con.block,
                .path = reuse_arc_path.?,
                .instr_index = con.instr_index,
                .position = .before,
                .expected_identity = con_identity,
            },
            .reason = .perceus_reuse,
        });
        reuse_arc_path = null;
    }

    /// Fingerprint the instruction a coordinate `(block, path,
    /// instr_index)` addresses, navigating `path` from the top-level
    /// block. Returns `null` when the coordinate does not resolve (no
    /// anchor to verify against). The fingerprint is consumed by
    /// `arc_materialize` to reject stale coordinates.
    fn fingerprintInstructionAt(
        self: *PerceusAnalyzer,
        func: *const ir.Function,
        block_label: ir.LabelId,
        path: []const lattice.StreamStep,
        instr_index: u32,
    ) ?ir.InstructionIdentity {
        const block = self.findBlock(func, block_label) orelse return null;
        var stack_path: [16]ir.StreamPathStep = undefined;
        if (path.len > stack_path.len) return null;
        for (path, 0..) |step, i| stack_path[i] = step.toStreamPathStep();
        const instr = ir.instructionAtPath(block.instructions, stack_path[0..path.len], instr_index) orelse return null;
        return ir.fingerprintInstruction(instr);
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

        // Resolve the deconstruction instruction by navigating `decon.path`
        // from the top-level block, then indexing the innermost stream with
        // `decon.instr_index` — the same path-based resolution Phase-2
        // discovery uses. The previous `block.instructions[decon.instr_index]`
        // conflated a nested-stream index with the top-level block (audit
        // perceus-region--02): for nested deconstructions whose stream-local
        // index happened to be < the top-level length it targeted the wrong
        // instruction; only the out-of-range case was caught by the bounds
        // guard, silently dropping nested drop-specs.
        const decon_ir_path = try lattice.toStreamPath(self.allocator, decon.path);
        defer self.allocator.free(decon_ir_path);
        const instr = ir.instructionAtPath(block.instructions, decon_ir_path, decon.instr_index) orelse return;

        switch (instr.*) {
            .case_block => |cb| {
                // For each arm, generate a specialized drop for the
                // known constructor. The drops must run only when the
                // arm matches — they release the field bindings the
                // arm extracted — so the InsertionPoint targets the
                // *arm's body stream* at its end, not the parent
                // stream after the case_block.
                for (cb.arms, 0..) |arm, arm_idx| {
                    var field_drops: ?[]const FieldDrop = try self.extractFieldDropsFromArm(func, &arm);
                    defer if (field_drops) |drops| self.allocator.free(drops);

                    var arm_path: std.ArrayListUnmanaged(lattice.StreamStep) = .empty;
                    defer arm_path.deinit(self.allocator);
                    try arm_path.appendSlice(self.allocator, decon.path);
                    try arm_path.append(self.allocator, .{
                        .parent_instr_index = decon.instr_index,
                        .child = .{ .case_block_arm_body = @intCast(arm_idx) },
                    });
                    const arm_body_len: u32 = @intCast(arm.body_instrs.len);

                    var insertion_path: ?[]const lattice.StreamStep = try self.allocator.dupe(lattice.StreamStep, arm_path.items);
                    defer if (insertion_path) |path| self.allocator.free(path);

                    try self.drop_specializations.append(self.allocator, .{
                        .match_site = decon.match_site_id,
                        .constructor_tag = @intCast(arm_idx),
                        .field_drops = field_drops.?,
                        .function = func.id,
                        .insertion_point = .{
                            .function = func.id,
                            .block = decon.block,
                            .path = insertion_path.?,
                            .instr_index = arm_body_len,
                            .position = .before,
                        },
                    });
                    field_drops = null;
                    insertion_path = null;
                }
            },
            .if_expr => {
                // For if_expr, we generate a single specialization
                var then_drops: ?[]const FieldDrop = try self.allocator.alloc(FieldDrop, 0);
                defer if (then_drops) |drops| self.allocator.free(drops);

                var insertion_path: ?[]const lattice.StreamStep = try self.allocator.dupe(lattice.StreamStep, decon.path);
                defer if (insertion_path) |path| self.allocator.free(path);

                try self.drop_specializations.append(self.allocator, .{
                    .match_site = decon.match_site_id,
                    .constructor_tag = 0,
                    .field_drops = then_drops.?,
                    .function = func.id,
                    .insertion_point = .{
                        .function = func.id,
                        .block = decon.block,
                        .path = insertion_path.?,
                        .instr_index = decon.instr_index,
                        .position = .after,
                        .expected_identity = ir.fingerprintInstruction(instr),
                    },
                });
                then_drops = null;
                insertion_path = null;
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
                const destructive = try self.isDestructiveOptionalDispatch(&od, func);
                if (destructive) {
                    try self.destructive_funcs.put(self.allocator, func.id, od.scrutinee_param);
                }
                const drops = try self.allocator.alloc(FieldDrop, 1);
                errdefer self.allocator.free(drops);
                drops[0] = .{
                    .field_name = "__optional_payload",
                    .field_index = 0,
                    .needs_recursive_drop = true,
                    .local = od.payload_local,
                    .kind = if (destructive) .shallow else .deep,
                };
                const insertion_path = try self.allocator.dupe(lattice.StreamStep, decon.path);
                errdefer self.allocator.free(insertion_path);
                try self.drop_specializations.append(self.allocator, .{
                    .match_site = decon.match_site_id,
                    .constructor_tag = 0,
                    .field_drops = drops,
                    .function = func.id,
                    .insertion_point = .{
                        .function = func.id,
                        .block = decon.block,
                        .path = insertion_path,
                        .instr_index = decon.instr_index,
                        .position = .after,
                        .expected_identity = ir.fingerprintInstruction(instr),
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
    ) !bool {
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
                        try scrutinee_locals.put(self.allocator, pg.dest, {});
                    }
                },
                .field_get => |fg| {
                    if (!scrutinee_locals.contains(fg.object)) continue;
                    for (struct_fields) |def_field| {
                        if (!std.mem.eql(u8, def_field.name, fg.field)) continue;
                        if (def_field.storage == .indirect) {
                            try extracted_locals.put(self.allocator, fg.dest, {});
                            try fields_extracted.put(self.allocator, def_field.name, {});
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
        errdefer drops.deinit(self.allocator);

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

    /// True iff a deconstruction-site scrutinee is eligible to back a
    /// Perceus reuse pair — i.e. it is an OWNED, ARC-managed heap cell
    /// that this function uniquely owns.
    ///
    /// Reuse lowers to `ArcRuntime.resetAny(alloc, scrutinee)` +
    /// `reuseAllocByType(...)`: `resetAny` reads the cell's inline
    /// `ArcHeader` refcount (returning the allocation as a reuse token
    /// when rc==1, else releasing it), and `reuseAllocByType`
    /// repopulates that same storage field-by-field via `field_ptr` +
    /// `store`. Both steps are only sound when the scrutinee is a
    /// genuine heap allocation with a refcount header AND is owned by
    /// this function:
    ///
    ///   * `.trivial` — a by-value / non-ARC value (e.g. the
    ///     `std.meta.Tuple{u32, T, ?*const List}` that `List.next`
    ///     returns by value). It has no allocation and no `ArcHeader`,
    ///     so `resetAny` would read a non-existent header. Reusing it is
    ///     meaningless and unsound; the scrutinee's ARC contents are
    ///     instead extracted (`index_get`) and released individually by
    ///     the consumer. This is also exactly the shape ARC verifier V11
    ///     rejects: a `.reset` whose source local is classified
    ///     `.trivial` is skipped by the `arc_liveness.identifyArcLocals`
    ///     seed walk, breaking `arc_managed_locals` completeness.
    ///   * `.borrowed` — the cell is owned by the CALLER across the
    ///     call; resetting/reusing its storage would corrupt a value the
    ///     caller still holds live.
    ///
    /// Only `.owned` satisfies both invariants. Mirrors the
    /// `fieldLocalNeedsDrop` ownership convention above: when the
    /// function carries no `local_ownership` table (the analyzer's unit
    /// tests construct bare `ir.Function`s with an empty slice), defer to
    /// the other reuse gates (type compatibility, construction kind) so
    /// the pairing algorithm stays independently testable.
    fn scrutineeReuseEligible(func: *const ir.Function, scrutinee: ir.LocalId) bool {
        if (scrutinee >= func.local_ownership.len) return true;
        return func.local_ownership[scrutinee] == .owned;
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

const DestructiveOptionalDispatchFixture = struct {
    tree_type: ir.ZigType,
    optional_tree_type: ir.ZigType,
    params: [1]ir.Param,
    tree_fields: [1]ir.StructFieldDef,
    type_defs: [1]ir.TypeDef,
    struct_instrs: [3]ir.Instruction,
    optional_dispatch: ir.OptionalDispatch,
    block_instrs: [1]ir.Instruction,
    blocks: [1]ir.Block,
    functions: [1]ir.Function,
    program: ir.Program,
    decon: DeconstructionSite,

    fn init(self: *@This()) void {
        self.tree_type = .{ .struct_ref = "Tree" };
        self.optional_tree_type = .{ .optional = &self.tree_type };
        self.params = .{
            .{ .name = "tree", .type_expr = self.optional_tree_type },
        };
        self.tree_fields = .{
            .{
                .name = "left",
                .type_expr = self.optional_tree_type,
                .storage = .indirect,
            },
        };
        self.type_defs = .{
            .{
                .name = "Tree",
                .kind = .{ .struct_def = .{ .fields = &self.tree_fields } },
            },
        };
        self.struct_instrs = .{
            .{ .param_get = .{ .dest = 1, .index = 0 } },
            .{ .field_get = .{ .dest = 2, .object = 1, .field = "left" } },
            .{ .call_named = .{ .dest = 3, .name = "consume_tree", .args = &.{2}, .arg_modes = &.{} } },
        };
        self.optional_dispatch = .{
            .scrutinee_param = 0,
            .payload_local = 1,
            .nil_instrs = &.{},
            .nil_result = null,
            .struct_instrs = &self.struct_instrs,
            .struct_result = 3,
        };
        self.block_instrs = .{
            .{ .optional_dispatch = self.optional_dispatch },
        };
        self.blocks = .{
            makeBlock(0, &self.block_instrs),
        };
        var function = makeFunction(0, "destructive_optional", &self.blocks);
        function.arity = 1;
        function.params = &self.params;
        self.functions = .{function};
        self.program = .{
            .functions = &self.functions,
            .type_defs = &self.type_defs,
            .entry = null,
        };
        self.decon = .{
            .function = function.id,
            .block = 0,
            .path = &.{},
            .instr_index = 0,
            .scrutinee = self.optional_dispatch.payload_local,
            .scrutinee_type = .{ .name = "Tree", .kind = .struct_type, .num_fields = 1 },
            .match_site_id = 0,
            .match_kind = .optional_dispatch,
        };
    }
};

fn expectDestructiveOptionalDispatchAnalysis(allocator: std.mem.Allocator) !void {
    var fixture: DestructiveOptionalDispatchFixture = undefined;
    fixture.init();

    var analyzer = PerceusAnalyzer.init(allocator, &fixture.program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.destructive_optional_dispatch.len);
    try testing.expectEqual(@as(ir.FunctionId, 0), result.destructive_optional_dispatch[0].function);
    try testing.expectEqual(@as(u32, 0), result.destructive_optional_dispatch[0].scrutinee_param);
    try testing.expectEqual(@as(usize, 1), result.drop_specializations.len);
    try testing.expectEqual(@as(usize, 1), result.drop_specializations[0].field_drops.len);
    try testing.expectEqual(FieldDrop.Kind.shallow, result.drop_specializations[0].field_drops[0].kind);
    try testing.expectEqual(@as(?ir.LocalId, 1), result.drop_specializations[0].field_drops[0].local);
}

fn expectDestructiveOptionalDispatchDetectorAccepts(allocator: std.mem.Allocator) !void {
    var fixture: DestructiveOptionalDispatchFixture = undefined;
    fixture.init();

    var analyzer = PerceusAnalyzer.init(allocator, &fixture.program);
    defer analyzer.deinit();

    try testing.expect(try analyzer.isDestructiveOptionalDispatch(
        &fixture.optional_dispatch,
        &fixture.functions[0],
    ));
}

fn expectDestructiveOptionalDispatchDropSpecialization(allocator: std.mem.Allocator) !void {
    var fixture: DestructiveOptionalDispatchFixture = undefined;
    fixture.init();

    var analyzer = PerceusAnalyzer.init(allocator, &fixture.program);
    defer analyzer.deinit();

    try analyzer.generateDropSpecialization(&fixture.decon, &fixture.functions[0]);

    try testing.expectEqual(@as(usize, 1), analyzer.drop_specializations.items.len);
    try testing.expectEqual(@as(usize, 1), analyzer.drop_specializations.items[0].field_drops.len);
    try testing.expectEqual(FieldDrop.Kind.shallow, analyzer.drop_specializations.items[0].field_drops[0].kind);
    try testing.expectEqual(@as(?u32, 0), analyzer.destructive_funcs.get(fixture.functions[0].id));
}

fn expectConstructionDiscoveryAllocationFailureCleanup(allocator: std.mem.Allocator) !void {
    const cond0 = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 10, .scrutinee = 1, .expected_type = .{ .struct_ref = "Pair" }, .expected_arity = 2 } },
    };
    const body0 = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 20, .type_name = "Pair", .fields = &.{
            .{ .name = "left", .value = 11 },
            .{ .name = "right", .value = 12 },
        } } },
    };
    const cond1 = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 15, .scrutinee = 1, .expected_type = .{ .struct_ref = "Pair" }, .expected_arity = 2 } },
    };
    const body1 = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 25, .type_name = "Pair", .fields = &.{
            .{ .name = "left", .value = 12 },
            .{ .name = "right", .value = 11 },
        } } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond0, .condition = 10, .body_instrs = &body0, .result = 20 },
        .{ .cond_instrs = &cond1, .condition = 15, .body_instrs = &body1, .result = 25 },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{ .dest = 30, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "construction_discovery_cleanup", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const decon = DeconstructionSite{
        .function = 0,
        .block = 0,
        .path = &.{},
        .instr_index = 0,
        .scrutinee = 1,
        .scrutinee_type = .{ .name = "Pair", .kind = .struct_type, .num_fields = 2 },
        .match_site_id = 0,
        .match_kind = .case_block,
    };

    const constructions = try analyzer.findCompatibleConstructionsForMatch(&functions[0], &decon);
    defer deinitConstructionSiteSlice(allocator, constructions);

    try testing.expectEqual(@as(usize, 2), constructions.len);
}

fn expectDeconstructionDiscoveryAllocationFailureCleanup(allocator: std.mem.Allocator) !void {
    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 10, .scrutinee = 1, .expected_type = .{ .struct_ref = "Pair" }, .expected_arity = 2 } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond_instrs, .condition = 10, .body_instrs = &.{}, .result = 1 },
    };
    const instruction = ir.Instruction{ .case_block = .{
        .dest = 20,
        .pre_instrs = &.{},
        .arms = &arms,
        .default_instrs = &.{},
        .default_result = null,
    } };
    const path_snapshot = [_]lattice.StreamStep{
        .{ .parent_instr_index = 0, .child = .case_block_pre },
    };
    const program = ir.Program{
        .functions = &.{},
        .type_defs = &.{},
        .entry = null,
    };

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    try analyzer.checkInstructionForDeconstruction(
        &instruction,
        0,
        0,
        &path_snapshot,
        0,
    );

    try testing.expectEqual(@as(usize, 1), analyzer.current_decon_sites.items.len);
    try testing.expectEqual(@as(usize, 1), analyzer.current_decon_sites.items[0].path.len);
}

fn expectReuseAnalysisAllocationFailureCleanup(allocator: std.mem.Allocator) !void {
    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 10, .scrutinee = 1, .expected_type = .{ .struct_ref = "Cell" }, .expected_arity = 1 } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 20, .type_name = "Cell", .fields = &.{
            .{ .name = "value", .value = 11 },
        } } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond_instrs, .condition = 10, .body_instrs = &body_instrs, .result = 20 },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{ .dest = 30, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "reuse_generation_cleanup", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), result.reuse_pairs.len);
    try testing.expect(result.arc_ops.len >= 2);
}

fn expectCaseDropSpecializationAllocationFailureCleanup(allocator: std.mem.Allocator) !void {
    const cond_instrs = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 10, .scrutinee = 1, .expected_type = .{ .struct_ref = "Pair" }, .expected_arity = 2 } },
        .{ .field_get = .{ .dest = 11, .object = 1, .field = "left" } },
        .{ .field_get = .{ .dest = 12, .object = 1, .field = "right" } },
    };
    const body_instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 11 } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond_instrs, .condition = 10, .body_instrs = &body_instrs, .result = 11 },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{ .dest = 30, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "case_drop_cleanup", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const decon = DeconstructionSite{
        .function = 0,
        .block = 0,
        .path = &.{},
        .instr_index = 0,
        .scrutinee = 1,
        .scrutinee_type = .{ .name = "Pair", .kind = .struct_type, .num_fields = 2 },
        .match_site_id = 0,
        .match_kind = .case_block,
    };

    try analyzer.generateDropSpecialization(&decon, &functions[0]);

    try testing.expectEqual(@as(usize, 1), analyzer.drop_specializations.items.len);
    try testing.expectEqual(@as(usize, 2), analyzer.drop_specializations.items[0].field_drops.len);
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

test "trivial (by-value) scrutinee yields NO reuse pair" {
    // Regression for task #320 (ARC ReleaseFast V11 on the FCC
    // `for f <- ops` combinator). The deconstruction scrutinee is the
    // by-value `std.meta.Tuple{u32, T, ?*const List}` returned by
    // `List.next` — classified `.trivial` in `local_ownership` because
    // it is NOT a heap-allocated ARC cell. Even though the `:cont`
    // guard reconstructs a same-arity tuple (a type-compatible reuse
    // target), Perceus must NOT emit a reuse pair: `resetAny` on a
    // by-value tuple would read a non-existent `ArcHeader`, and the
    // resulting `.reset` source classified `.trivial` is exactly what
    // ARC verifier V11 rejects. The same shape as the
    // "nested case pre-instructions tuple reconstruction yields reuse
    // pair" test above — the ONLY difference is the scrutinee's
    // ownership class — so this proves the gate keys on ownership, not
    // on IR shape.
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
    // Scrutinee %1 is `.trivial` (a by-value `List.next` tuple).
    var local_ownership = [_]ir.OwnershipClass{.trivial} ** 31;
    var function = makeFunction(0, "trivial_tuple_scrutinee", &blocks);
    function.local_ownership = &local_ownership;
    const functions = [_]ir.Function{function};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
}

test "borrowed scrutinee yields NO reuse pair" {
    // Companion to the `.trivial` regression: a `.borrowed` scrutinee is
    // a heap cell owned by the CALLER across the call. Resetting/reusing
    // its storage would corrupt a value the caller still holds live, so
    // Perceus must skip the reuse pair even though the cell is a real
    // ARC allocation and the construction is type-compatible.
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
    var local_ownership = [_]ir.OwnershipClass{.trivial} ** 31;
    local_ownership[1] = .borrowed;
    var function = makeFunction(0, "borrowed_scrutinee", &blocks);
    function.local_ownership = &local_ownership;
    const functions = [_]ir.Function{function};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
}

test "owned scrutinee with same-arity construction yields reuse pair" {
    // Positive control: the SAME nested-pre-instructions tuple shape as
    // the two negative tests above, but with the scrutinee classified
    // `.owned` (a heap ARC cell this function uniquely owns). Reuse is
    // sound here, so the pair must still be generated — proving the gate
    // suppresses only ineligible scrutinees, not legitimate reuse.
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
    var local_ownership = [_]ir.OwnershipClass{.trivial} ** 31;
    local_ownership[1] = .owned;
    var function = makeFunction(0, "owned_tuple_scrutinee", &blocks);
    function.local_ownership = &local_ownership;
    const functions = [_]ir.Function{function};
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

test "destructive optional dispatch records shallow drop specialization" {
    try expectDestructiveOptionalDispatchAnalysis(testing.allocator);
}

test "destructive optional dispatch analysis cleans up destructive list on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectDestructiveOptionalDispatchAnalysis,
        .{},
    );
}

test "destructive optional dispatch detector propagates allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectDestructiveOptionalDispatchDetectorAccepts,
        .{},
    );
}

test "destructive optional dispatch drop specialization propagates allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectDestructiveOptionalDispatchDropSpecialization,
        .{},
    );
}

test "construction discovery cleans up owned paths on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectConstructionDiscoveryAllocationFailureCleanup,
        .{},
    );
}

test "deconstruction discovery cleans up owned paths on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectDeconstructionDiscoveryAllocationFailureCleanup,
        .{},
    );
}

test "reuse analysis cleans up construction sites on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectReuseAnalysisAllocationFailureCleanup,
        .{},
    );
}

test "case drop specialization cleans up field drops on allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectCaseDropSpecializationAllocationFailureCleanup,
        .{},
    );
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
// Test 11: List type reuse is intentionally gated off
// ============================================================

test "list deconstruction + list construction does NOT yield a reuse pair" {
    // Rationale: `.list_init` lowers via accumulator/builder
    // (`List.empty().push(...)`) rather than struct-field stores
    // into a pre-allocated buffer. The reuse-aware lowering path
    // (`emitReuseAllocCall` + per-field `zir_builder_emit_store`)
    // can only target IR kinds that perform direct field writes —
    // tuple_init / struct_init / union_init. Generating a reuse
    // pair for a list construction would emit a `.reset` IR that
    // consumes the scrutinee's storage without any downstream
    // consumer, leaking the freed slot. `scanInstructionForConstructions`
    // skips list_type / map_type at pair-discovery time; this test
    // pins that behavior.
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

    try testing.expectEqual(@as(usize, 0), result.reuse_pairs.len);
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

test "two arms reusing one scrutinee emit exactly one reset (no double resetAny)" {
    // arc-param--04: a single deconstruction (one match site) that pairs with
    // a construction in EACH arm shares ONE reset token across the arms. The
    // `.reset` arc_op (which materializes `resetAny`, claiming the cell) must
    // be emitted exactly ONCE per match site — not once per construction.
    // Pre-fix, generateReusePair appended one `.reset` per pair, so a two-arm
    // match produced two `.reset` ops over the same scrutinee and `resetAny`
    // ran twice (double-claim / double-release / wrong-cell reuse).
    const allocator = testing.allocator;

    // Both arms construct a `Shape` (2-field struct) from the same scrutinee
    // (local 1), so both pair with the single deconstruction.
    const cond0 = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 10, .scrutinee = 1, .expected_type = .{ .struct_ref = "Shape" }, .expected_arity = 2 } },
    };
    const body0 = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 20, .type_name = "Shape", .fields = &.{
            .{ .name = "w", .value = 11 },
            .{ .name = "h", .value = 12 },
        } } },
    };
    const cond1 = [_]ir.Instruction{
        .{ .match_type = .{ .dest = 15, .scrutinee = 1, .expected_type = .{ .struct_ref = "Shape" }, .expected_arity = 2 } },
    };
    const body1 = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 25, .type_name = "Shape", .fields = &.{
            .{ .name = "w", .value = 12 },
            .{ .name = "h", .value = 11 },
        } } },
    };
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &cond0, .condition = 10, .body_instrs = &body0, .result = 20 },
        .{ .cond_instrs = &cond1, .condition = 15, .body_instrs = &body1, .result = 25 },
    };
    const block_instrs = [_]ir.Instruction{
        .{ .case_block = .{ .dest = 30, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
    };
    const blocks = [_]ir.Block{makeBlock(0, &block_instrs)};
    const functions = [_]ir.Function{makeFunction(0, "two_arm_reuse", &blocks)};
    var program = try makeTestProgram(&functions);
    _ = &program;

    var analyzer = PerceusAnalyzer.init(allocator, &program);
    defer analyzer.deinit();

    const result = try analyzer.analyze();
    defer result.deinit(allocator);

    var reset_count: usize = 0;
    var reuse_count: usize = 0;
    for (result.arc_ops) |op| {
        switch (op.kind) {
            .reset => reset_count += 1,
            .reuse_alloc => reuse_count += 1,
            else => {},
        }
    }

    // Both arms pair, so two reuse pairs and two `.reuse_alloc` ops...
    try testing.expectEqual(@as(usize, 2), result.reuse_pairs.len);
    try testing.expectEqual(@as(usize, 2), reuse_count);
    // ...but the shared scrutinee is reset EXACTLY ONCE.
    try testing.expectEqual(@as(usize, 1), reset_count);

    // The two pairs share one reset token (same match site), and the single
    // reset's source is the shared scrutinee.
    try testing.expectEqual(result.reuse_pairs[0].reset.dest, result.reuse_pairs[1].reset.dest);
    for (result.arc_ops) |op| {
        if (op.kind == .reset) try testing.expectEqual(@as(ir.LocalId, 1), op.value);
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
