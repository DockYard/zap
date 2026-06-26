const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");
const generalized_escape = @import("generalized_escape.zig");
const interprocedural = @import("interprocedural.zig");
const region_solver = @import("region_solver.zig");
const lambda_sets = @import("lambda_sets.zig");
const perceus = @import("perceus.zig");
const arc_optimizer = @import("arc_optimizer.zig");
const diagnostics = @import("diagnostics.zig");
const ast = @import("ast.zig");
const frontend_policy = @import("frontend_policy.zig");

// ============================================================
// Analysis Pipeline Orchestrator
//
// Sequences all analysis structs and produces a `lattice.AnalysisContext`
// with the full analysis results consumed by the ZIR backend, type
// checker, and downstream passes.
// ============================================================

pub const PipelineResult = struct {
    context: lattice.AnalysisContext,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),

    pub fn deinit(self: *PipelineResult) void {
        self.diagnostics.deinit(self.context.allocator);
        self.context.deinit();
    }
};

/// Run the full analysis pipeline on an IR program.
///
/// Pipeline order:
///   1. Generalized escape analysis (all allocation sites)
///   2. Interprocedural summary computation (call graph, SCC, summaries)
///   3. Re-run escape analysis with interprocedural summaries (feedback loop)
///   4. Region solving per function (dom tree, LCA, multiplicity, storage modes)
///      — parallelized with Io.Group when io is provided
///   5. Lambda set specialization (0-CFA, contification)
///   6. Perceus reuse analysis (deconstruction/construction pairing)
///   7. Build legacy result for backward compat
pub fn runAnalysisPipeline(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
) !PipelineResult {
    return runAnalysisPipelineWithIo(alloc, program, null);
}

/// Run the analysis pipeline with optional Io for parallel execution.
pub fn runAnalysisPipelineWithIo(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    pio: ?std.Io,
) !PipelineResult {
    return runAnalysisPipelineWithIoAndPolicy(alloc, program, pio, frontend_policy.FrontendPassPolicy.full());
}

pub fn runAnalysisPipelineWithPolicy(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    policy: frontend_policy.FrontendPassPolicy,
) !PipelineResult {
    return runAnalysisPipelineWithIoAndPolicy(alloc, program, null, policy);
}

/// Run the analysis pipeline with explicit frontend pass policy. Semantic
/// analysis and closure-tier finalization always run; policy booleans only gate
/// optimization-only analysis metadata passes.
pub fn runAnalysisPipelineWithIoAndPolicy(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    pio: ?std.Io,
    policy: frontend_policy.FrontendPassPolicy,
) !PipelineResult {
    var work = try runRequiredAnalysisSemantics(alloc, program);
    errdefer work.deinit();

    if (policy.run_region_solver) {
        try runOptionalRegionSolver(alloc, program, pio, &work.context);
    }
    if (policy.run_lambda_specialization) {
        try runOptionalLambdaSpecialization(alloc, program, &work.context);
    }
    if (policy.run_perceus_reuse) {
        try runOptionalPerceusReuse(alloc, program, &work.context);
    }
    if (policy.run_arc_optimizer) {
        try runOptionalArcOptimization(alloc, program, &work.context);
    }
    try runClosureEnvironmentSemantics(program, &work.context);

    return .{
        .context = work.context,
        .diagnostics = work.diagnostics,
    };
}

const AnalysisPipelineWork = struct {
    context: lattice.AnalysisContext,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),

    fn deinit(self: *AnalysisPipelineWork) void {
        self.diagnostics.deinit(self.context.allocator);
        self.context.deinit();
    }
};

/// Semantic analysis required for correctness and diagnostics:
/// escape analysis, interprocedural summaries, refined escape, ownership
/// verification at merge points, and borrow diagnostics. Phase 3 may gate
/// later optimization stages, but these diagnostics must remain on.
fn runRequiredAnalysisSemantics(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
) !AnalysisPipelineWork {
    var pipeline_diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty;
    errdefer pipeline_diagnostics.deinit(alloc);

    // --------------------------------------------------------
    // Phase 1: Initial generalized escape analysis
    // --------------------------------------------------------
    var escape_analyzer = generalized_escape.GeneralizedEscapeAnalyzer.init(alloc, program.*);
    defer escape_analyzer.deinit();
    var ctx = try escape_analyzer.analyze();
    errdefer ctx.deinit();

    // --------------------------------------------------------
    // Phase 2: Interprocedural summary computation
    // --------------------------------------------------------
    var interproc = try interprocedural.InterproceduralAnalyzer.init(alloc, program);
    defer interproc.deinit();
    try interproc.analyze();

    // Copy interprocedural summaries into the analysis context.
    var summary_iter = interproc.summaries.iterator();
    while (summary_iter.next()) |entry| {
        try ctx.putFunctionSummaryClone(entry.key_ptr.*, entry.value_ptr.*);
    }

    // --------------------------------------------------------
    // Phase 3: Re-run escape with interprocedural summaries
    //          (feedback loop for refined call-site analysis)
    // --------------------------------------------------------
    var escape_analyzer2 = generalized_escape.GeneralizedEscapeAnalyzer.init(alloc, program.*);
    defer escape_analyzer2.deinit();
    // Inject summaries before analysis using the public API.
    try escape_analyzer2.setFunctionSummaries(&ctx.function_summaries);
    {
        var ctx2 = try escape_analyzer2.analyze();
        errdefer ctx2.deinit();

        // Replace context with refined results, keeping summaries.
        // First, preserve summaries from ctx into ctx2.
        var sum_iter3 = ctx.function_summaries.iterator();
        while (sum_iter3.next()) |entry| {
            if (!ctx2.function_summaries.contains(entry.key_ptr.*)) {
                try ctx2.putFunctionSummaryClone(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        ctx.deinit();
        ctx = ctx2;
    }

    // --------------------------------------------------------
    // Phase 3.5: Ownership verification at phi/merge points
    // --------------------------------------------------------
    // Scan for phi nodes and verify that ownership transitions at merge
    // points are legal per the ownership lattice (Research Plan §3.4).
    // Also verify share_value/move_value conversions.
    for (program.functions) |func| {
        for (func.body) |block| {
            try verifyOwnershipInInstrs(&pipeline_diagnostics, &ctx, program, func, block.instructions);
        }
    }

    try collectBorrowDiagnostics(alloc, &pipeline_diagnostics, &ctx, program);

    return .{
        .context = ctx,
        .diagnostics = pipeline_diagnostics,
    };
}

/// Optional region-placement analysis. It feeds allocation strategy and
/// downstream ARC optimization metadata; Debug policy skips it, while release
/// policies currently keep it enabled.
fn runOptionalRegionSolver(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    pio: ?std.Io,
    context: *lattice.AnalysisContext,
) !void {
    // --------------------------------------------------------
    // Phase 4: Region solving per function
    //   Parallelized with Io.Group when io is available.
    //   Each function's region solving is independent: it reads
    //   from the shared escape context and produces local results.
    //   Results are merged sequentially after all tasks complete.
    // --------------------------------------------------------
    if (pio != null and program.functions.len > 1) {
        // Parallel region solving
        const io_val = pio.?;
        const region_results = try alloc.alloc(RegionTaskResult, program.functions.len);
        defer {
            for (region_results) |*result| {
                result.deinit();
            }
            alloc.free(region_results);
        }

        // Initialize all results
        for (region_results) |*r| {
            r.* = .{};
        }

        // Extract per-function data and launch parallel tasks
        const func_escapes = try alloc.alloc(std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.EscapeState), program.functions.len);
        for (func_escapes) |*func_escape| {
            func_escape.* = .empty;
        }
        defer {
            for (func_escapes) |*fe| fe.deinit(alloc);
            alloc.free(func_escapes);
        }
        const func_alloc_sites_arr = try alloc.alloc(std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.AllocSiteId), program.functions.len);
        for (func_alloc_sites_arr) |*func_alloc_sites| {
            func_alloc_sites.* = .empty;
        }
        defer {
            for (func_alloc_sites_arr) |*fas| fas.deinit(alloc);
            alloc.free(func_alloc_sites_arr);
        }

        // Prepare per-function inputs (sequential — reads shared ctx)
        for (program.functions, 0..) |func, fi| {
            var es_iter = context.escape_states.iterator();
            while (es_iter.next()) |entry| {
                if (entry.key_ptr.function == func.id) {
                    try func_escapes[fi].put(alloc, entry.key_ptr.local, entry.value_ptr.*);
                }
            }

            var next_site: lattice.AllocSiteId = 0;
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    const maybe_dest: ?ir.LocalId = switch (instr) {
                        .struct_init => |si| si.dest,
                        .tuple_init => |ti| ti.dest,
                        .list_init => |li| li.dest,
                        .map_init => |mi| mi.dest,
                        .make_closure => |mc| mc.dest,
                        .union_init => |ui| ui.dest,
                        else => null,
                    };
                    if (maybe_dest) |dest| {
                        try func_alloc_sites_arr[fi].put(alloc, dest, next_site);
                        next_site += 1;
                    }
                }
            }
        }

        // Launch parallel region solving tasks
        var group: std.Io.Group = .init;
        for (program.functions, 0..) |*func, fi| {
            group.async(io_val, regionSolveTask, .{
                alloc, func, &func_escapes[fi], &func_alloc_sites_arr[fi], &region_results[fi],
            });
        }
        try group.await(io_val);

        try propagateRegionTaskFailures(region_results);

        // Merge results sequentially
        for (region_results) |*result| {
            switch (result.state) {
                .solved => {},
                .pending, .failed => unreachable,
            }

            var ra_iter = result.region_assignments.iterator();
            while (ra_iter.next()) |entry| {
                const vkey = lattice.ValueKey{ .function = result.func_id, .local = entry.key_ptr.* };
                try context.region_assignments.put(vkey, entry.value_ptr.*);
            }

            var ras_iter = result.alloc_summaries.iterator();
            while (ras_iter.next()) |entry| {
                try context.alloc_summaries.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            for (result.outlives_constraints.items) |c| {
                try context.outlives_constraints.append(alloc, c);
            }
        }
    } else {
        // Sequential fallback
        var solver = region_solver.RegionSolver.init(alloc);

        for (program.functions) |*func| {
            var func_escape: std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.EscapeState) = .empty;
            defer func_escape.deinit(alloc);
            var es_iter = context.escape_states.iterator();
            while (es_iter.next()) |entry| {
                if (entry.key_ptr.function == func.id) {
                    try func_escape.put(alloc, entry.key_ptr.local, entry.value_ptr.*);
                }
            }

            var func_alloc_sites: std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.AllocSiteId) = .empty;
            defer func_alloc_sites.deinit(alloc);
            {
                var next_site: lattice.AllocSiteId = 0;
                for (func.body) |block| {
                    for (block.instructions) |instr| {
                        const maybe_dest: ?ir.LocalId = switch (instr) {
                            .struct_init => |si| si.dest,
                            .tuple_init => |ti| ti.dest,
                            .list_init => |li| li.dest,
                            .map_init => |mi| mi.dest,
                            .make_closure => |mc| mc.dest,
                            .union_init => |ui| ui.dest,
                            else => null,
                        };
                        if (maybe_dest) |dest| {
                            try func_alloc_sites.put(alloc, dest, next_site);
                            next_site += 1;
                        }
                    }
                }
            }

            var region_result = try solver.solveFunction(func, &func_escape, &func_alloc_sites);
            defer region_result.deinit();

            var ra_iter = region_result.region_assignments.iterator();
            while (ra_iter.next()) |entry| {
                const vkey = lattice.ValueKey{ .function = func.id, .local = entry.key_ptr.* };
                try context.region_assignments.put(vkey, entry.value_ptr.*);
            }

            var ras_iter = region_result.alloc_summaries.iterator();
            while (ras_iter.next()) |entry| {
                try context.alloc_summaries.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            for (region_result.outlives_constraints.items) |c| {
                try context.outlives_constraints.append(alloc, c);
            }
        }
    }
}

/// Optional lambda-set specialization used by contification and closure
/// lowering decisions. Debug policy skips it; release policies keep it enabled.
fn runOptionalLambdaSpecialization(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    context: *lattice.AnalysisContext,
) !void {
    // --------------------------------------------------------
    // Phase 5: Lambda set specialization
    // --------------------------------------------------------
    var ls_analyzer = try lambda_sets.LambdaSetAnalyzer.init(alloc, program);
    defer ls_analyzer.deinit();
    try ls_analyzer.analyze();
    try ls_analyzer.populateContext(context);
}

/// Optional Perceus reuse analysis. It adds reuse/drop specialization metadata
/// consumed later for allocation and ARC optimization; Debug policy skips it.
fn runOptionalPerceusReuse(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    context: *lattice.AnalysisContext,
) !void {
    // --------------------------------------------------------
    // Phase 6: Perceus reuse analysis
    // --------------------------------------------------------
    var perceus_analyzer = perceus.PerceusAnalyzer.initWithContext(alloc, program, context);
    defer perceus_analyzer.deinit();
    const perceus_result = try perceus_analyzer.analyze();
    defer perceus_result.deinit(alloc);

    // Copy Perceus results into context. `perceus_result` owns the
    // InsertionPoint.path slices and frees them on deinit, so each
    // copy here must deep-clone the path to give the context its own
    // independently-owned slice. Without the clone, the context's
    // arc_ops / drop_specs / reuse_pairs would hold dangling pointers
    // after `perceus_result.deinit` runs.
    for (perceus_result.reuse_pairs) |pair| {
        var owned_pair = pair;
        owned_pair.reuse.insertion_point.path = try alloc.dupe(lattice.StreamStep, pair.reuse.insertion_point.path);
        try context.addReusePair(owned_pair);
    }
    for (perceus_result.arc_ops) |op| {
        var owned_op = op;
        owned_op.insertion_point.path = try alloc.dupe(lattice.StreamStep, op.insertion_point.path);
        try context.arc_ops.append(alloc, owned_op);
    }
    for (perceus_result.drop_specializations) |spec| {
        const copied_fields = try alloc.alloc(lattice.FieldDrop, spec.field_drops.len);
        @memcpy(copied_fields, spec.field_drops);
        var owned_ip = spec.insertion_point;
        owned_ip.path = try alloc.dupe(lattice.StreamStep, spec.insertion_point.path);
        try context.addDropSpecialization(.{
            .match_site = spec.match_site,
            .constructor_tag = spec.constructor_tag,
            .field_drops = copied_fields,
            .function = spec.function,
            .insertion_point = owned_ip,
        });
    }
    for (perceus_result.destructive_optional_dispatch) |entry| {
        try context.destructive_optional_dispatch.put(entry.function, entry.scrutinee_param);
    }

    // Back-propagate used_in_reset from Perceus to interprocedural summaries.
    // For each reuse pair, find which function parameters flow to the
    // deconstructed value (reset.source) and set used_in_reset = true.
    for (perceus_result.reuse_pairs) |pair| {
        const source_local = pair.reset.source;
        // Find which function this reset is in and check if source_local
        // derives from a parameter.
        for (program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .param_get => |pg| {
                            if (pg.dest == source_local) {
                                // The reset source is a parameter. Update the summary.
                                if (context.function_summaries.getPtr(func.id)) |summary| {
                                    if (pg.index < summary.param_summaries.len) {
                                        // Note: param_summaries is []const, so we need
                                        // to cast to mutable. This is safe because we
                                        // allocated the slice ourselves.
                                        const mutable: []lattice.ParamSummary = @constCast(summary.param_summaries);
                                        mutable[pg.index].used_in_reset = true;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }
}

/// Optional ARC optimization over analysis metadata. It preserves observable
/// semantics and only minimizes ARC operations; Debug policy skips it.
fn runOptionalArcOptimization(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
    context: *lattice.AnalysisContext,
) !void {
    // --------------------------------------------------------
    // Phase 6.5: ARC optimization
    // --------------------------------------------------------
    var arc_opt = arc_optimizer.ArcOptimizer.init(alloc, program, context);
    defer arc_opt.deinit();
    try arc_opt.optimize();
}

/// Semantic closure-tier finalization. This uses the current context to keep
/// direct-call, closure-environment, and callee parameter shapes in agreement.
fn runClosureEnvironmentSemantics(
    program: *const ir.Program,
    context: *lattice.AnalysisContext,
) !void {
    // --------------------------------------------------------
    // Phase 7: Compute closure environment tiers
    // --------------------------------------------------------
    for (program.functions) |func| {
        if (func.is_closure or func.captures.len > 0) {
            // If no `make_closure` instruction targets this function, the
            // captures are forwarded as plain prepended arguments at every
            // call site (HIR's direct-call lowering, see hir.zig
            // `target == .direct` branch). Treat such a function as
            // lambda-lifted: no `__closure_env` parameter, captures consumed
            // as ordinary positional parameters. This keeps the call-site
            // shape (call_direct with prepended capture args) and the
            // callee's parameter list in agreement.
            if (!try hasMakeClosureForFunction(context.allocator, program, func.id)) {
                try context.closure_tiers.put(func.id, .lambda_lifted);
                continue;
            }
            // Find the escape state for this closure's creation site.
            // Look through all functions for a make_closure that references this function.
            const escape = try findClosureEscape(context, program, func.id);
            const tier = lattice.escapeToClosureTier(escape, func.captures.len > 0);
            try context.closure_tiers.put(func.id, tier);
        }
    }
}

/// Result from a parallel region solving task. Mirrors the fields of
/// region_solver.FunctionRegionResult that get merged into AnalysisContext.
const RegionTaskState = union(enum) {
    pending,
    solved,
    failed: anyerror,
};

const RegionTaskResult = struct {
    state: RegionTaskState = .pending,
    func_id: ir.FunctionId = 0,
    region_assignments: std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.RegionId) = .empty,
    alloc_summaries: std.AutoArrayHashMapUnmanaged(lattice.AllocSiteId, lattice.AllocSiteSummary) = .empty,
    outlives_constraints: std.ArrayListUnmanaged(lattice.OutlivesConstraint) = .empty,
    task_alloc: std.mem.Allocator = undefined,

    fn deinit(self: *RegionTaskResult) void {
        switch (self.state) {
            .solved => {},
            .pending, .failed => return,
        }
        self.region_assignments.deinit(self.task_alloc);
        self.alloc_summaries.deinit(self.task_alloc);
        self.outlives_constraints.deinit(self.task_alloc);
    }
};

fn propagateRegionTaskFailures(region_results: []const RegionTaskResult) !void {
    for (region_results) |*result| {
        switch (result.state) {
            .solved => {},
            .failed => |err| return err,
            .pending => return error.RegionSolveTaskIncomplete,
        }
    }
}

fn regionSolveTask(
    alloc: std.mem.Allocator,
    func: *const ir.Function,
    func_escape: *const std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.EscapeState),
    func_alloc_sites: *const std.AutoArrayHashMapUnmanaged(ir.LocalId, lattice.AllocSiteId),
    result: *RegionTaskResult,
) void {
    var solver = region_solver.RegionSolver.init(alloc);
    var region_result = solver.solveFunction(func, func_escape, func_alloc_sites) catch |err| {
        result.func_id = func.id;
        result.state = .{ .failed = err };
        return;
    };
    // Transfer ownership of data to the result struct
    result.state = .solved;
    result.func_id = func.id;
    result.task_alloc = alloc;
    result.region_assignments = region_result.region_assignments;
    result.alloc_summaries = region_result.alloc_summaries;
    result.outlives_constraints = region_result.outlives_constraints;
    // Prevent the deferred deinit from freeing our data
    region_result.region_assignments = .empty;
    region_result.alloc_summaries = .empty;
    region_result.outlives_constraints = .empty;
    region_result.deinit();
}

fn unknownAnalysisSpan() ast.SourceSpan {
    return .{ .start = 0, .end = 0, .line = 0, .col = 0 };
}

fn addAnalysisDiagnostic(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
    severity: diagnostics.Severity,
    message: []const u8,
    code: ?[]const u8,
    label: ?[]const u8,
    help: ?[]const u8,
) !void {
    try out.append(alloc, .{
        .severity = severity,
        .message = message,
        .span = unknownAnalysisSpan(),
        .label = label,
        .help = help,
        .code = code,
    });
}

fn collectBorrowDiagnostics(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(diagnostics.Diagnostic),
    ctx: *const lattice.AnalysisContext,
    program: *const ir.Program,
) !void {
    var it = ctx.borrow_verdicts.iterator();
    while (it.next()) |entry| {
        const borrow_site = entry.key_ptr.*;
        const verdict = entry.value_ptr.*;
        switch (verdict) {
            .legal => {},
            .illegal => |illegal| {
                const reason = switch (illegal.reason) {
                    .returned_from_function => "borrowed value escapes by being returned from its function",
                    .stored_in_escaping_container => "borrowed value is stored in an escaping container or closure",
                    .passed_to_unknown_callee => "borrowed value is passed to a callee without a safe ownership summary",
                    .crosses_loop_boundary => "borrowed value crosses a loop boundary without proving loop invariance",
                    .crosses_merge_with_moved_source => "borrowed value is moved after the borrow becomes live",
                };
                const help = switch (illegal.reason) {
                    .returned_from_function => "return an owned value instead of borrowing it, or widen the value's ownership",
                    .stored_in_escaping_container => "store an owned/shared value in the escaping container instead of a borrow",
                    .passed_to_unknown_callee => "annotate or analyze the callee so the argument can be proven borrow-safe",
                    .crosses_loop_boundary => "make the borrowed value loop-invariant or change the code to pass ownership",
                    .crosses_merge_with_moved_source => "avoid moving the source while the borrow is still live",
                };
                _ = program;
                _ = borrow_site;
                try addAnalysisDiagnostic(
                    alloc,
                    out,
                    .@"error",
                    reason,
                    "E-BORROW",
                    "analysis rejected this borrow as unsafe",
                    help,
                );
            },
        }
    }
}

const InstructionStreamWalkControl = enum {
    continue_walk,
    stop_walk,
};

const InstructionStreamFrame = struct {
    stream: []const ir.Instruction,
    next_index: usize = 0,
};

const InstructionStreamWalker = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(InstructionStreamFrame) = .empty,
    child_streams: std.ArrayListUnmanaged([]const ir.Instruction) = .empty,

    fn init(allocator: std.mem.Allocator) InstructionStreamWalker {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *InstructionStreamWalker) void {
        self.stack.deinit(self.allocator);
        self.child_streams.deinit(self.allocator);
    }

    fn walk(
        self: *InstructionStreamWalker,
        root_stream: []const ir.Instruction,
        context: anytype,
        comptime visitFn: fn (
            ctx: @TypeOf(context),
            stream: []const ir.Instruction,
            instr: *const ir.Instruction,
        ) anyerror!InstructionStreamWalkControl,
    ) !InstructionStreamWalkControl {
        self.stack.clearRetainingCapacity();
        self.child_streams.clearRetainingCapacity();
        if (root_stream.len == 0) return .continue_walk;

        try self.stack.append(self.allocator, .{ .stream = root_stream });
        while (self.stack.items.len > 0) {
            const frame_index = self.stack.items.len - 1;
            if (self.stack.items[frame_index].next_index >= self.stack.items[frame_index].stream.len) {
                _ = self.stack.pop();
                continue;
            }

            const instr_index = self.stack.items[frame_index].next_index;
            self.stack.items[frame_index].next_index += 1;
            const current_stream = self.stack.items[frame_index].stream;
            const instr = &current_stream[instr_index];

            switch (try visitFn(context, current_stream, instr)) {
                .continue_walk => {},
                .stop_walk => return .stop_walk,
            }

            try self.pushInstructionChildren(instr);
        }

        return .continue_walk;
    }

    fn pushInstructionChildren(self: *InstructionStreamWalker, instr: *const ir.Instruction) !void {
        self.child_streams.clearRetainingCapacity();

        const ChildStreamCollector = struct {
            allocator: std.mem.Allocator,
            streams: *std.ArrayListUnmanaged([]const ir.Instruction),
            err: ?anyerror = null,

            fn onStream(ctx: *@This(), child: ir.ChildStream) void {
                if (ctx.err != null or child.stream.len == 0) return;
                ctx.streams.append(ctx.allocator, child.stream) catch |err| {
                    ctx.err = err;
                };
            }
        };

        var child_collector = ChildStreamCollector{
            .allocator = self.allocator,
            .streams = &self.child_streams,
        };
        ir.forEachChildStream(instr, &child_collector, ChildStreamCollector.onStream);
        if (child_collector.err) |err| return err;

        var stream_index = self.child_streams.items.len;
        while (stream_index > 0) {
            stream_index -= 1;
            try self.stack.append(self.allocator, .{ .stream = self.child_streams.items[stream_index] });
        }
    }
};

const AliasQuery = struct {
    local: ir.LocalId,
    stream: []const ir.Instruction,
};

const AliasQueryKey = struct {
    local: ir.LocalId,
    stream_ptr: usize,
    stream_len: usize,

    fn init(local: ir.LocalId, stream: []const ir.Instruction) AliasQueryKey {
        return .{
            .local = local,
            .stream_ptr = if (stream.len == 0) 0 else @intFromPtr(stream.ptr),
            .stream_len = stream.len,
        };
    }
};

const ClosureAliasResolver = struct {
    allocator: std.mem.Allocator,
    stream_walker: InstructionStreamWalker,
    query_stack: std.ArrayListUnmanaged(AliasQuery) = .empty,
    visited_queries: std.AutoArrayHashMapUnmanaged(AliasQueryKey, void) = .empty,

    fn init(allocator: std.mem.Allocator) ClosureAliasResolver {
        return .{
            .allocator = allocator,
            .stream_walker = InstructionStreamWalker.init(allocator),
        };
    }

    fn deinit(self: *ClosureAliasResolver) void {
        self.visited_queries.deinit(self.allocator);
        self.query_stack.deinit(self.allocator);
        self.stream_walker.deinit();
    }

    fn queueQuery(
        self: *ClosureAliasResolver,
        local: ir.LocalId,
        stream: []const ir.Instruction,
    ) !void {
        const visited_entry = try self.visited_queries.getOrPut(self.allocator, AliasQueryKey.init(local, stream));
        if (!visited_entry.found_existing) {
            try self.query_stack.append(self.allocator, .{
                .local = local,
                .stream = stream,
            });
        }
    }

    fn isAlias(
        self: *ClosureAliasResolver,
        local: ir.LocalId,
        closure_local: ir.LocalId,
        instrs: []const ir.Instruction,
    ) !bool {
        self.query_stack.clearRetainingCapacity();
        self.visited_queries.clearRetainingCapacity();
        try self.queueQuery(local, instrs);

        while (self.query_stack.pop()) |query| {
            if (query.local == closure_local) return true;

            const AliasDefinitionCollector = struct {
                resolver: *ClosureAliasResolver,
                target_local: ir.LocalId,
                closure_local: ir.LocalId,
                found: bool = false,

                fn queueSource(
                    ctx: *@This(),
                    source: ir.LocalId,
                    stream: []const ir.Instruction,
                ) !InstructionStreamWalkControl {
                    if (source == ctx.closure_local) {
                        ctx.found = true;
                        return .stop_walk;
                    }
                    try ctx.resolver.queueQuery(source, stream);
                    return .continue_walk;
                }

                fn visit(
                    ctx: *@This(),
                    stream: []const ir.Instruction,
                    instr: *const ir.Instruction,
                ) anyerror!InstructionStreamWalkControl {
                    switch (instr.*) {
                        .local_get => |lg| if (lg.dest == ctx.target_local) return try ctx.queueSource(lg.source, stream),
                        .local_set => |ls| if (ls.dest == ctx.target_local) return try ctx.queueSource(ls.value, stream),
                        .move_value => |mv| if (mv.dest == ctx.target_local) return try ctx.queueSource(mv.source, stream),
                        .share_value => |sv| if (sv.dest == ctx.target_local) return try ctx.queueSource(sv.source, stream),
                        else => {},
                    }
                    return .continue_walk;
                }
            };

            var definition_collector = AliasDefinitionCollector{
                .resolver = self,
                .target_local = query.local,
                .closure_local = closure_local,
            };
            _ = try self.stream_walker.walk(query.stream, &definition_collector, AliasDefinitionCollector.visit);
            if (definition_collector.found) return true;
        }

        return false;
    }
};

/// Does any `make_closure` instruction in the program target the given
/// function? If not, the function is only ever direct-called and its
/// captures are forwarded as ordinary arguments — i.e., it should be
/// classified as lambda-lifted regardless of its `is_closure` flag.
fn hasMakeClosureForFunction(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    target_func_id: ir.FunctionId,
) !bool {
    var walker = InstructionStreamWalker.init(allocator);
    defer walker.deinit();

    for (program.functions) |func| {
        for (func.body) |block| {
            if (try instrsContainMakeClosureForWithWalker(&walker, block.instructions, target_func_id)) return true;
        }
    }
    return false;
}

fn instrsContainMakeClosureFor(
    allocator: std.mem.Allocator,
    instrs: []const ir.Instruction,
    target_func_id: ir.FunctionId,
) !bool {
    return (try findMakeClosureForFunction(allocator, instrs, target_func_id)) != null;
}

fn instrsContainMakeClosureForWithWalker(
    walker: *InstructionStreamWalker,
    instrs: []const ir.Instruction,
    target_func_id: ir.FunctionId,
) !bool {
    return (try findMakeClosureForFunctionWithWalker(walker, instrs, target_func_id)) != null;
}

fn findMakeClosureForFunction(
    allocator: std.mem.Allocator,
    instrs: []const ir.Instruction,
    target_func_id: ir.FunctionId,
) !?ir.MakeClosure {
    var walker = InstructionStreamWalker.init(allocator);
    defer walker.deinit();
    return findMakeClosureForFunctionWithWalker(&walker, instrs, target_func_id);
}

fn findMakeClosureForFunctionWithWalker(
    walker: *InstructionStreamWalker,
    instrs: []const ir.Instruction,
    target_func_id: ir.FunctionId,
) !?ir.MakeClosure {
    const MakeClosureFinder = struct {
        target_func_id: ir.FunctionId,
        result: ?ir.MakeClosure = null,

        fn visit(
            ctx: *@This(),
            stream: []const ir.Instruction,
            instr: *const ir.Instruction,
        ) anyerror!InstructionStreamWalkControl {
            _ = stream;
            if (instr.* == .make_closure and instr.make_closure.function == ctx.target_func_id) {
                ctx.result = instr.make_closure;
                return .stop_walk;
            }
            return .continue_walk;
        }
    };

    var finder = MakeClosureFinder{ .target_func_id = target_func_id };
    _ = try walker.walk(instrs, &finder, MakeClosureFinder.visit);
    return finder.result;
}

/// Find the escape state for a closure's creation site by searching
/// for the make_closure instruction that targets this function.
/// Also checks for the call-local pattern: if the closure is only
/// ever called (never stored, passed, or returned), override to no_escape.
fn findClosureEscape(
    ctx: *const lattice.AnalysisContext,
    program: *const ir.Program,
    closure_func_id: ir.FunctionId,
) !lattice.EscapeState {
    var make_closure_walker = InstructionStreamWalker.init(ctx.allocator);
    defer make_closure_walker.deinit();

    for (program.functions) |func| {
        for (func.body) |block| {
            if (try findMakeClosureForFunctionWithWalker(&make_closure_walker, block.instructions, closure_func_id)) |mc| {
                // Check if this closure is only called locally
                // (never stored, passed as arg, or returned).
                if (try isCallLocalOnly(ctx.allocator, func, mc.dest, block.instructions)) {
                    return .no_escape;
                }
                if (try hasHardEscapeInFunction(ctx.allocator, func, mc.dest)) {
                    return .global_escape;
                }
                const vkey = lattice.ValueKey{
                    .function = func.id,
                    .local = mc.dest,
                };
                return ctx.getEscape(vkey);
            }
        }
    }
    // No make_closure found: the closure value is never allocated as a
    // first-class value (e.g., call-local where captures are forwarded
    // as arguments). Classify as no_escape so it gets immediate_invocation tier.
    return .no_escape;
}

/// Check if a closure (identified by its make_closure dest local) is only
/// ever used as the callee of call_closure instructions in the given instruction list.
/// If it's stored, passed as an argument, returned, or used in any other way, return false.
fn isCallLocalOnly(
    allocator: std.mem.Allocator,
    func: ir.Function,
    closure_local: ir.LocalId,
    start_instrs: []const ir.Instruction,
) !bool {
    // Track aliases: locals that hold the same value as closure_local.
    // Simple: just track the initial local and any direct copies.
    var scan_walker = InstructionStreamWalker.init(allocator);
    defer scan_walker.deinit();
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();

    var found_use = false;
    return (try isCallLocalInInstrsWithScratch(
        &scan_walker,
        &alias_resolver,
        closure_local,
        start_instrs,
        start_instrs,
        &found_use,
    )) and
        (try isCallLocalInAllBlocksWithScratch(&scan_walker, &alias_resolver, func, closure_local));
}

fn isCallLocalInAllBlocks(
    allocator: std.mem.Allocator,
    func: ir.Function,
    closure_local: ir.LocalId,
) !bool {
    var scan_walker = InstructionStreamWalker.init(allocator);
    defer scan_walker.deinit();
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();
    return isCallLocalInAllBlocksWithScratch(&scan_walker, &alias_resolver, func, closure_local);
}

fn isCallLocalInAllBlocksWithScratch(
    scan_walker: *InstructionStreamWalker,
    alias_resolver: *ClosureAliasResolver,
    func: ir.Function,
    closure_local: ir.LocalId,
) !bool {
    var found_use = false;
    for (func.body) |block| {
        if (!try isCallLocalInInstrsWithScratch(
            scan_walker,
            alias_resolver,
            closure_local,
            block.instructions,
            block.instructions,
            &found_use,
        )) return false;
    }
    return true;
}

fn isCallLocalInInstrs(
    allocator: std.mem.Allocator,
    closure_local: ir.LocalId,
    instrs: []const ir.Instruction,
    root_instrs: []const ir.Instruction,
    found_use: *bool,
) !bool {
    var scan_walker = InstructionStreamWalker.init(allocator);
    defer scan_walker.deinit();
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();
    return isCallLocalInInstrsWithScratch(
        &scan_walker,
        &alias_resolver,
        closure_local,
        instrs,
        root_instrs,
        found_use,
    );
}

fn isCallLocalInInstrsWithScratch(
    scan_walker: *InstructionStreamWalker,
    alias_resolver: *ClosureAliasResolver,
    closure_local: ir.LocalId,
    instrs: []const ir.Instruction,
    root_instrs: []const ir.Instruction,
    found_use: *bool,
) !bool {
    const CallLocalScan = struct {
        alias_resolver: *ClosureAliasResolver,
        closure_local: ir.LocalId,
        root_instrs: []const ir.Instruction,
        found_use: *bool,
        ok: bool = true,

        fn isAlias(ctx: *@This(), local: ir.LocalId) !bool {
            return ctx.alias_resolver.isAlias(local, ctx.closure_local, ctx.root_instrs);
        }

        fn rejectIfAlias(ctx: *@This(), local: ir.LocalId) !InstructionStreamWalkControl {
            if (try ctx.isAlias(local)) {
                ctx.ok = false;
                return .stop_walk;
            }
            return .continue_walk;
        }

        fn visit(
            ctx: *@This(),
            stream: []const ir.Instruction,
            instr: *const ir.Instruction,
        ) anyerror!InstructionStreamWalkControl {
            _ = stream;
            switch (instr.*) {
                .call_closure => |cc| {
                    if (try ctx.isAlias(cc.callee)) {
                        ctx.found_use.* = true;
                        // This is fine — closure is being called.
                        // But check if it's also passed as an argument.
                        for (cc.args) |arg| {
                            if (try ctx.isAlias(arg)) {
                                ctx.ok = false;
                                return .stop_walk;
                            }
                        }
                    }
                },
                // If the closure local appears as an argument to any call, it escapes.
                .call_direct => |cd| {
                    for (cd.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .call_named => |cn| {
                    for (cn.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .call_dispatch => |cd2| {
                    for (cd2.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .call_builtin => |cb| {
                    for (cb.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .tail_call => |tc| {
                    for (tc.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .try_call_named => |tc| {
                    for (tc.args) |arg| {
                        switch (try ctx.rejectIfAlias(arg)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                    switch (try ctx.rejectIfAlias(tc.input_local)) {
                        .continue_walk => {},
                        .stop_walk => return .stop_walk,
                    }
                },
                // If returned, it escapes.
                .ret => |r| {
                    if (r.value) |v| {
                        switch (try ctx.rejectIfAlias(v)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .cond_return => |cr| {
                    if (cr.value) |v| {
                        switch (try ctx.rejectIfAlias(v)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                // If stored in aggregate, it escapes.
                .tuple_init => |ti| {
                    for (ti.elements) |e| {
                        switch (try ctx.rejectIfAlias(e)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .list_init => |li| {
                    for (li.elements) |e| {
                        switch (try ctx.rejectIfAlias(e)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .struct_init => |si| {
                    for (si.fields) |f| {
                        switch (try ctx.rejectIfAlias(f.value)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .field_set => |fs| {
                    switch (try ctx.rejectIfAlias(fs.value)) {
                        .continue_walk => {},
                        .stop_walk => return .stop_walk,
                    }
                },
                else => {},
            }
            return .continue_walk;
        }
    };

    var scan = CallLocalScan{
        .alias_resolver = alias_resolver,
        .closure_local = closure_local,
        .root_instrs = root_instrs,
        .found_use = found_use,
    };
    _ = try scan_walker.walk(instrs, &scan, CallLocalScan.visit);
    return scan.ok;
}

fn isAliasOfClosure(
    allocator: std.mem.Allocator,
    local: ir.LocalId,
    closure_local: ir.LocalId,
    instrs: []const ir.Instruction,
) !bool {
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();
    return alias_resolver.isAlias(local, closure_local, instrs);
}

fn hasHardEscapeInFunction(
    allocator: std.mem.Allocator,
    func: ir.Function,
    closure_local: ir.LocalId,
) !bool {
    var scan_walker = InstructionStreamWalker.init(allocator);
    defer scan_walker.deinit();
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();

    for (func.body) |block| {
        if (try hasHardEscapeInInstrsWithScratch(
            &scan_walker,
            &alias_resolver,
            closure_local,
            block.instructions,
            block.instructions,
        )) return true;
    }
    return false;
}

fn hasHardEscapeInInstrs(
    allocator: std.mem.Allocator,
    closure_local: ir.LocalId,
    instrs: []const ir.Instruction,
    root_instrs: []const ir.Instruction,
) !bool {
    var scan_walker = InstructionStreamWalker.init(allocator);
    defer scan_walker.deinit();
    var alias_resolver = ClosureAliasResolver.init(allocator);
    defer alias_resolver.deinit();
    return hasHardEscapeInInstrsWithScratch(
        &scan_walker,
        &alias_resolver,
        closure_local,
        instrs,
        root_instrs,
    );
}

fn hasHardEscapeInInstrsWithScratch(
    scan_walker: *InstructionStreamWalker,
    alias_resolver: *ClosureAliasResolver,
    closure_local: ir.LocalId,
    instrs: []const ir.Instruction,
    root_instrs: []const ir.Instruction,
) !bool {
    const HardEscapeScan = struct {
        alias_resolver: *ClosureAliasResolver,
        closure_local: ir.LocalId,
        root_instrs: []const ir.Instruction,
        found: bool = false,

        fn isAlias(ctx: *@This(), local: ir.LocalId) !bool {
            return ctx.alias_resolver.isAlias(local, ctx.closure_local, ctx.root_instrs);
        }

        fn stopIfAlias(ctx: *@This(), local: ir.LocalId) !InstructionStreamWalkControl {
            if (try ctx.isAlias(local)) {
                ctx.found = true;
                return .stop_walk;
            }
            return .continue_walk;
        }

        fn visit(
            ctx: *@This(),
            stream: []const ir.Instruction,
            instr: *const ir.Instruction,
        ) anyerror!InstructionStreamWalkControl {
            _ = stream;
            switch (instr.*) {
                .ret => |r| if (r.value) |v| {
                    return try ctx.stopIfAlias(v);
                },
                .cond_return => |cr| if (cr.value) |v| {
                    return try ctx.stopIfAlias(v);
                },
                .tuple_init => |ti| {
                    for (ti.elements) |e| {
                        switch (try ctx.stopIfAlias(e)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .list_init => |li| {
                    for (li.elements) |e| {
                        switch (try ctx.stopIfAlias(e)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .struct_init => |si| {
                    for (si.fields) |f| {
                        switch (try ctx.stopIfAlias(f.value)) {
                            .continue_walk => {},
                            .stop_walk => return .stop_walk,
                        }
                    }
                },
                .field_set => |fs| return try ctx.stopIfAlias(fs.value),
                else => {},
            }
            return .continue_walk;
        }
    };

    var scan = HardEscapeScan{
        .alias_resolver = alias_resolver,
        .closure_local = closure_local,
        .root_instrs = root_instrs,
    };
    _ = try scan_walker.walk(instrs, &scan, HardEscapeScan.visit);
    return scan.found;
}

/// Verify ownership legality in a function's instructions.
/// Checks phi merges using mergeOwnership(), share_value/move_value
/// conversions using isOwnershipConversionLegal(), and captures.
fn verifyOwnershipInInstrs(
    out: *std.ArrayList(diagnostics.Diagnostic),
    ctx: *lattice.AnalysisContext,
    program: *const ir.Program,
    func: ir.Function,
    instrs: []const ir.Instruction,
) !void {
    const OwnershipVerifier = struct {
        out: *std.ArrayList(diagnostics.Diagnostic),
        ctx: *lattice.AnalysisContext,
        program: *const ir.Program,
        func: ir.Function,

        fn visit(
            verifier: *@This(),
            stream: []const ir.Instruction,
            instr: *const ir.Instruction,
        ) anyerror!InstructionStreamWalkControl {
            _ = stream;
            switch (instr.*) {
                // Phi nodes: verify all incoming sources have compatible ownership.
                // Uses the per-value ownership states populated by the escape analyzer.
                .phi => |p| {
                    if (p.sources.len >= 2) {
                        const first_key = lattice.ValueKey{ .function = verifier.func.id, .local = p.sources[0].value };
                        var merged_ownership = verifier.ctx.getOwnership(first_key);

                        for (p.sources[1..]) |src| {
                            const src_key = lattice.ValueKey{ .function = verifier.func.id, .local = src.value };
                            const src_ownership = verifier.ctx.getOwnership(src_key);
                            const merge_result = lattice.mergeOwnership(merged_ownership, src_ownership);
                            switch (merge_result) {
                                .ok => |o| merged_ownership = o,
                                .illegal => |err| {
                                    const message = switch (err) {
                                        .borrowed_promoted_to_owned => "ownership merge is illegal: borrowed values cannot be merged into an owning value",
                                        .different_unique_bindings => "ownership merge is illegal: distinct unique values cannot be merged at a phi node",
                                    };
                                    try addAnalysisDiagnostic(
                                        verifier.ctx.allocator,
                                        verifier.out,
                                        .@"error",
                                        message,
                                        "E-OWN-PHI",
                                        "illegal ownership merge detected at phi node",
                                        "insert an explicit share before the merge, or restructure control flow so ownership kinds agree",
                                    );
                                },
                            }
                        }

                        // Record the merged ownership for the phi dest.
                        const dest_key = lattice.ValueKey{ .function = verifier.func.id, .local = p.dest };
                        try verifier.ctx.setOwnership(dest_key, merged_ownership);
                    }
                },

                // share_value: unique→shared conversion. Legal per §3.4.
                // Verify using isOwnershipConversionLegal.
                .share_value => |sv| {
                    const src_key = lattice.ValueKey{ .function = verifier.func.id, .local = sv.source };
                    const src_ownership = verifier.ctx.getOwnership(src_key);
                    if (!lattice.isOwnershipConversionLegal(src_ownership, .shared)) {
                        try addAnalysisDiagnostic(
                            verifier.ctx.allocator,
                            verifier.out,
                            .@"error",
                            "ownership conversion is illegal: borrowed values cannot be promoted to shared ownership",
                            "E-OWN-SHARE",
                            "illegal share detected in IR ownership verification",
                            "keep the value borrowed, or create an owned/shared value before sharing it",
                        );
                    }
                    // Record dest as shared.
                    const dest_key = lattice.ValueKey{ .function = verifier.func.id, .local = sv.dest };
                    try verifier.ctx.setOwnership(dest_key, .shared);
                },

                // move_value: ownership transfer.
                .move_value => |mv| {
                    const src_key = lattice.ValueKey{ .function = verifier.func.id, .local = mv.source };
                    const src_ownership = verifier.ctx.getOwnership(src_key);
                    // Move is always legal for owned values (unique/shared).
                    // Illegal for borrowed (type checker enforces).
                    if (src_ownership == .borrowed) {
                        try addAnalysisDiagnostic(
                            verifier.ctx.allocator,
                            verifier.out,
                            .@"error",
                            "ownership transfer is illegal: borrowed values cannot be moved",
                            "E-OWN-MOVE",
                            "illegal move of borrowed value detected",
                            "pass or store an owned value instead of moving a borrow",
                        );
                    }
                    // Dest inherits source ownership.
                    const dest_key = lattice.ValueKey{ .function = verifier.func.id, .local = mv.dest };
                    try verifier.ctx.setOwnership(dest_key, src_ownership);
                },

                // make_closure: verify borrowed captures aren't in escaping closures.
                .make_closure => |mc| {
                    for (verifier.program.functions) |closure_func| {
                        if (closure_func.id != mc.function) continue;
                        for (closure_func.captures) |cap| {
                            if (cap.ownership == .borrowed) {
                                const closure_key = lattice.ValueKey{ .function = verifier.func.id, .local = mc.dest };
                                const escape = verifier.ctx.getEscape(closure_key);
                                if (escape.requiresHeap()) {
                                    try addAnalysisDiagnostic(
                                        verifier.ctx.allocator,
                                        verifier.out,
                                        .@"error",
                                        "borrowed capture is illegal in an escaping closure",
                                        "E-OWN-CAPTURE",
                                        "escaping closure captures a borrowed value",
                                        "capture an owned/shared value, or keep the closure non-escaping",
                                    );
                                }
                            }
                        }
                        break;
                    }
                },
                else => {},
            }
            return .continue_walk;
        }
    };

    var walker = InstructionStreamWalker.init(ctx.allocator);
    defer walker.deinit();
    var verifier = OwnershipVerifier{
        .out = out,
        .ctx = ctx,
        .program = program,
        .func = func,
    };
    _ = try walker.walk(instrs, &verifier, OwnershipVerifier.visit);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn buildNestedGuardChain(
    allocator: std.mem.Allocator,
    depth: usize,
    terminal: ir.Instruction,
) ![]ir.Instruction {
    const instructions = try allocator.alloc(ir.Instruction, depth + 1);
    errdefer allocator.free(instructions);

    instructions[depth] = terminal;
    var guard_index = depth;
    while (guard_index > 0) {
        guard_index -= 1;
        instructions[guard_index] = .{
            .guard_block = .{
                .condition = 0,
                .body = instructions[guard_index + 1 .. guard_index + 2],
            },
        };
    }

    return instructions;
}

test "make_closure query traverses deeply nested child streams without native recursion" {
    const allocator = testing.allocator;
    const deep_nesting_depth: usize = 16_384;

    const nested_chain = try buildNestedGuardChain(
        allocator,
        deep_nesting_depth,
        .{ .make_closure = .{ .dest = 7, .function = 42, .captures = &.{} } },
    );
    defer allocator.free(nested_chain);

    try testing.expect(try instrsContainMakeClosureFor(allocator, nested_chain[0..1], 42));
    try testing.expect(!try instrsContainMakeClosureFor(allocator, nested_chain[0..1], 43));

    const make_closure = (try findMakeClosureForFunction(allocator, nested_chain[0..1], 42)).?;
    try testing.expectEqual(@as(ir.LocalId, 7), make_closure.dest);
}

test "closure alias resolver resolves deep alias chains without a fixed depth cap" {
    const allocator = testing.allocator;
    const closure_local: ir.LocalId = 1;
    const alias_count: usize = 64;

    const instructions = try allocator.alloc(ir.Instruction, alias_count);
    defer allocator.free(instructions);

    for (instructions, 0..) |*instruction, alias_index| {
        const dest: ir.LocalId = @intCast(alias_index + 2);
        const source: ir.LocalId = if (alias_index == 0) closure_local else @intCast(alias_index + 1);
        instruction.* = .{ .local_set = .{ .dest = dest, .value = source } };
    }

    const deepest_alias: ir.LocalId = @intCast(alias_count + 1);
    try testing.expect(try isAliasOfClosure(allocator, deepest_alias, closure_local, instructions));
}

test "closure alias resolver terminates on cyclic aliases without false positives" {
    const allocator = testing.allocator;
    const closure_local: ir.LocalId = 1;
    const instructions = [_]ir.Instruction{
        .{ .local_set = .{ .dest = 2, .value = 3 } },
        .{ .move_value = .{ .dest = 3, .source = 2 } },
    };

    try testing.expect(!try isAliasOfClosure(allocator, 2, closure_local, &instructions));
    try testing.expect(!try isAliasOfClosure(allocator, 3, closure_local, &instructions));
}

test "ownership verifier traverses deeply nested child streams without native recursion" {
    const allocator = testing.allocator;
    const deep_nesting_depth: usize = 16_384;

    const nested_chain = try buildNestedGuardChain(
        allocator,
        deep_nesting_depth,
        .{ .move_value = .{ .dest = 2, .source = 1 } },
    );
    defer allocator.free(nested_chain);

    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = nested_chain[0..1] },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "deep_ownership_verify",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var context = lattice.AnalysisContext.init(allocator);
    defer context.deinit();
    try context.setOwnership(.{ .function = 0, .local = 1 }, .borrowed);

    var verifier_diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty;
    defer verifier_diagnostics.deinit(allocator);

    try verifyOwnershipInInstrs(&verifier_diagnostics, &context, &program, functions[0], nested_chain[0..1]);

    var found_move_diagnostic = false;
    for (verifier_diagnostics.items) |diag| {
        if (diag.code != null and std.mem.eql(u8, diag.code.?, "E-OWN-MOVE")) {
            found_move_diagnostic = true;
        }
    }
    try testing.expect(found_move_diagnostic);
}

fn expectOwnershipVerifierUpdateOom(instructions: []const ir.Instruction) !void {
    var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing_allocator.allocator();

    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = instructions },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "ownership_update_oom",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .void,
            .body = &blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var context = lattice.AnalysisContext.init(allocator);
    defer context.deinit();

    var verifier_diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty;
    defer verifier_diagnostics.deinit(allocator);

    failing_allocator.fail_index = failing_allocator.alloc_index + 1;
    try testing.expectError(
        error.OutOfMemory,
        verifyOwnershipInInstrs(&verifier_diagnostics, &context, &program, functions[0], instructions),
    );
}

test "ownership verifier propagates allocation failure while recording phi ownership" {
    const instructions = [_]ir.Instruction{
        .{ .phi = .{
            .dest = 3,
            .sources = &[_]ir.PhiSource{
                .{ .from_block = 0, .value = 1 },
                .{ .from_block = 1, .value = 2 },
            },
        } },
    };

    try expectOwnershipVerifierUpdateOom(&instructions);
}

test "ownership verifier propagates allocation failure while recording share ownership" {
    const instructions = [_]ir.Instruction{
        .{ .share_value = .{ .dest = 2, .source = 1 } },
    };

    try expectOwnershipVerifierUpdateOom(&instructions);
}

test "ownership verifier propagates allocation failure while recording move ownership" {
    const instructions = [_]ir.Instruction{
        .{ .move_value = .{ .dest = 2, .source = 1 } },
    };

    try expectOwnershipVerifierUpdateOom(&instructions);
}

const ParallelRegionSolverTestContext = struct {
    backing_allocator: std.mem.Allocator,
    fail_allocations_inside_tasks: bool = false,
    inside_group_task: bool = false,
    group_await_error: ?std.Io.Cancelable = null,
    group_token: u8 = 0,
    async_calls: usize = 0,
    await_calls: usize = 0,

    fn allocator(self: *ParallelRegionSolverTestContext) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn shouldFailAllocation(self: *const ParallelRegionSolverTestContext) bool {
        return self.fail_allocations_inside_tasks and self.inside_group_task;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(ctx));
        if (self.shouldFailAllocation()) return null;
        return self.backing_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(ctx));
        if (self.shouldFailAllocation()) return false;
        return self.backing_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(ctx));
        if (self.shouldFailAllocation()) return null;
        return self.backing_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(memory, alignment, return_address);
    }

    fn groupAsync(
        userdata: ?*anyopaque,
        group: *std.Io.Group,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque) void,
    ) void {
        _ = context_alignment;
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(userdata.?));
        self.async_calls += 1;
        group.token.store(@ptrCast(&self.group_token), .release);

        const previous_inside_group_task = self.inside_group_task;
        self.inside_group_task = true;
        defer self.inside_group_task = previous_inside_group_task;
        start(context.ptr);
    }

    fn groupAwait(
        userdata: ?*anyopaque,
        group: *std.Io.Group,
        token: *anyopaque,
    ) std.Io.Cancelable!void {
        _ = token;
        const self: *ParallelRegionSolverTestContext = @ptrCast(@alignCast(userdata.?));
        self.await_calls += 1;
        group.token.store(null, .release);
        if (self.group_await_error) |err| return err;
    }
};

fn parallelRegionSolverTestIo(
    context: *ParallelRegionSolverTestContext,
    vtable: *std.Io.VTable,
) std.Io {
    vtable.* = std.Io.failing.vtable.*;
    vtable.groupAsync = ParallelRegionSolverTestContext.groupAsync;
    vtable.groupAwait = ParallelRegionSolverTestContext.groupAwait;
    return .{
        .userdata = context,
        .vtable = vtable,
    };
}

fn expectParallelRegionSolverError(
    expected_error: anyerror,
    test_context: *ParallelRegionSolverTestContext,
) !void {
    const allocator = test_context.allocator();
    var fake_vtable = std.Io.failing.vtable.*;
    const fake_io = parallelRegionSolverTestIo(test_context, &fake_vtable);

    const first_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 1 } },
        .{ .ret = .{ .value = 0 } },
    };
    const first_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &first_instrs },
    };
    const second_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 2 } },
        .{ .ret = .{ .value = 0 } },
    };
    const second_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &second_instrs },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "parallel_region_first",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &first_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "parallel_region_second",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &second_blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var context = lattice.AnalysisContext.init(allocator);
    defer context.deinit();

    try testing.expectError(
        expected_error,
        runOptionalRegionSolver(allocator, &program, fake_io, &context),
    );
    try testing.expectEqual(@as(usize, 2), test_context.async_calls);
    try testing.expectEqual(@as(usize, 1), test_context.await_calls);
}

test "parallel region solver propagates worker task allocation failure" {
    var test_context = ParallelRegionSolverTestContext{
        .backing_allocator = testing.allocator,
        .fail_allocations_inside_tasks = true,
    };

    try expectParallelRegionSolverError(error.OutOfMemory, &test_context);
}

test "parallel region solver propagates recorded worker analysis failure" {
    const region_results = [_]RegionTaskResult{
        .{ .state = .{ .failed = error.AnalysisNestingLimitExceeded }, .func_id = 0 },
    };

    try testing.expectError(
        error.AnalysisNestingLimitExceeded,
        propagateRegionTaskFailures(&region_results),
    );
}

test "parallel region solver propagates group await failure" {
    var test_context = ParallelRegionSolverTestContext{
        .backing_allocator = testing.allocator,
        .group_await_error = error.Canceled,
    };

    try expectParallelRegionSolverError(error.Canceled, &test_context);
}

test "pipeline produces context for simple program" {
    const alloc = testing.allocator;

    // Build a simple program with one function.
    const main_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .ret = .{ .value = 0 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "main",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &main_blocks,
            .is_closure = false,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.context.closure_tiers.count());
}

test "pipeline classifies escaping closure tier" {
    const alloc = testing.allocator;

    // Program with a main function and a closure.
    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };
    const closure_params = [_]ir.Param{
        .{ .name = "y", .type_expr = .i64 },
    };
    const closure_captures = [_]ir.Capture{
        .{ .name = "x", .type_expr = .i64, .ownership = .shared },
    };

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 1, .captures = &[_]ir.LocalId{0} } },
        .{ .ret = .{ .value = 1 } }, // closure escapes (returned)
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };
    const main_params = [_]ir.Param{
        .{ .name = "x", .type_expr = .i64 },
    };

    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "make_adder",
            .scope_id = 0,
            .arity = 1,
            .params = &main_params,
            .return_type = .{ .function = .{ .params = &[_]ir.ZigType{.i64}, .return_type = &.i64 } },
            .body = &main_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "add_x",
            .scope_id = 0,
            .arity = 1,
            .params = &closure_params,
            .return_type = .i64,
            .body = &closure_blocks,
            .is_closure = true,
            .captures = &closure_captures,
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.escaping, result.context.closure_tiers.get(1).?);
}

test "pipeline non-escaping closure gets stack allocation" {
    const alloc = testing.allocator;

    // Closure that is called immediately (does not escape).
    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 10 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &.{}, .arg_modes = &.{}, .return_type = .i64 } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &main_instrs },
    };

    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "main",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &main_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "closure_fn",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &closure_blocks,
            .is_closure = true,
            .captures = &.{},
        },
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = 0,
    };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expect(result.context.closure_tiers.get(1).? != .escaping);
}

test "pipeline classifies non-capturing closure as lambda lifted" {
    const alloc = testing.allocator;

    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 10 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .ret = .{ .value = 0 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .{ .function = .{ .params = &.{}, .return_type = &.i64 } }, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "closure_fn", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.lambda_lifted, result.context.closure_tiers.get(1).?);
}

test "pipeline classifies capturing immediate call closure tier" {
    const alloc = testing.allocator;

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 1, .captures = &[_]ir.LocalId{0} } },
        .{ .const_int = .{ .dest = 2, .value = 10 } },
        .{ .call_closure = .{ .dest = 3, .callee = 1, .args = &[_]ir.LocalId{2}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 3 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &main_params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "add_x", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.immediate_invocation, result.context.closure_tiers.get(1).?);
}

test "pipeline classifies function-local closure tier for known-safe callee" {
    const alloc = testing.allocator;

    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &[_]ir.LocalId{1}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 2 } },
    };
    const apply_blocks = [_]ir.Block{.{ .label = 0, .instructions = &apply_instrs }};
    const apply_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .{ .function = .{ .params = &[_]ir.ZigType{.i64}, .return_type = &.i64 } } },
        .{ .name = "value", .type_expr = .i64 },
    };

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &[_]ir.LocalId{0} } },
        .{ .const_int = .{ .dest = 2, .value = 10 } },
        .{ .call_direct = .{ .dest = 3, .function = 1, .args = &[_]ir.LocalId{ 1, 2 }, .arg_modes = &[_]ir.ValueMode{ .share, .share } } },
        .{ .ret = .{ .value = 3 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &main_params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "apply", .scope_id = 0, .arity = 2, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "add_x", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.function_local, result.context.closure_tiers.get(2).?);
}

test "pipeline finds make_closure in switch_return default for closure tier" {
    const alloc = testing.allocator;

    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &[_]ir.LocalId{1}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 2 } },
    };
    const apply_blocks = [_]ir.Block{.{ .label = 0, .instructions = &apply_instrs }};
    const apply_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .{ .function = .{ .params = &[_]ir.ZigType{.i64}, .return_type = &.i64 } } },
        .{ .name = "value", .type_expr = .i64 },
    };

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const default_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &[_]ir.LocalId{0} } },
        .{ .const_int = .{ .dest = 2, .value = 10 } },
        .{ .call_direct = .{ .dest = 3, .function = 1, .args = &[_]ir.LocalId{ 1, 2 }, .arg_modes = &[_]ir.ValueMode{ .share, .share } } },
    };
    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .switch_return = .{
            .scrutinee_param = 0,
            .cases = &.{},
            .default_instrs = &default_instrs,
            .default_result = 3,
        } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &main_params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "apply", .scope_id = 0, .arity = 2, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "add_x", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.function_local, result.context.closure_tiers.get(2).?);
}

test "pipeline classifies aliased returned closure as escaping" {
    const alloc = testing.allocator;

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 1, .captures = &[_]ir.LocalId{0} } },
        .{ .local_set = .{ .dest = 2, .value = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &main_params, .return_type = .{ .function = .{ .params = &[_]ir.ZigType{.i64}, .return_type = &.i64 } }, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "add_x", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.escaping, result.context.closure_tiers.get(1).?);
}

test "pipeline preserves function-local tier through aliased known-safe call" {
    const alloc = testing.allocator;

    const apply_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 1 } },
        .{ .call_closure = .{ .dest = 2, .callee = 0, .args = &[_]ir.LocalId{1}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 2 } },
    };
    const apply_blocks = [_]ir.Block{.{ .label = 0, .instructions = &apply_instrs }};
    const apply_params = [_]ir.Param{
        .{ .name = "f", .type_expr = .{ .function = .{ .params = &[_]ir.ZigType{.i64}, .return_type = &.i64 } } },
        .{ .name = "value", .type_expr = .i64 },
    };

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 2, .captures = &[_]ir.LocalId{0} } },
        .{ .local_set = .{ .dest = 2, .value = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 10 } },
        .{ .call_direct = .{ .dest = 4, .function = 1, .args = &[_]ir.LocalId{ 2, 3 }, .arg_modes = &[_]ir.ValueMode{ .share, .share } } },
        .{ .ret = .{ .value = 4 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &main_params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "apply", .scope_id = 0, .arity = 2, .params = &apply_params, .return_type = .i64, .body = &apply_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "add_x", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expectEqual(lattice.ClosureEnvTier.function_local, result.context.closure_tiers.get(2).?);
}

test "pipeline emits diagnostic for borrowed capture in escaping closure" {
    const alloc = testing.allocator;

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &closure_instrs },
    };
    const closure_captures = [_]ir.Capture{
        .{ .name = "x", .type_expr = .i64, .ownership = .borrowed },
    };

    const outer_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 1, .captures = &[_]ir.LocalId{0} } },
        .{ .ret = .{ .value = 1 } },
    };
    const outer_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &outer_instrs },
    };
    const outer_params = [_]ir.Param{
        .{ .name = "x", .type_expr = .i64 },
    };

    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "outer",
            .scope_id = 0,
            .arity = 1,
            .params = &outer_params,
            .return_type = .{ .function = .{ .params = &[_]ir.ZigType{}, .return_type = &.i64 } },
            .body = &outer_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "inner",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &closure_blocks,
            .is_closure = true,
            .captures = &closure_captures,
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expect(result.diagnostics.items.len > 0);
    var found = false;
    for (result.diagnostics.items) |diag| {
        if (diag.code != null and std.mem.eql(u8, diag.code.?, "E-OWN-CAPTURE")) {
            found = true;
        }
    }
    try testing.expect(found);
}

test "pipeline emits diagnostic for unsafe borrow" {
    const alloc = testing.allocator;

    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .struct_init = .{ .dest = 1, .type_name = "S", .fields = &.{.{ .name = "x", .value = 0 }} } },
        .{ .call_named = .{ .dest = 2, .name = "store_global", .args = &.{1}, .arg_modes = &.{.move} } },
        .{ .call_named = .{ .dest = 3, .name = "read", .args = &.{1}, .arg_modes = &.{.borrow} } },
        .{ .ret = .{ .value = null } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "example",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expect(result.diagnostics.items.len > 0);
    var found = false;
    for (result.diagnostics.items) |diag| {
        if (diag.code != null and std.mem.eql(u8, diag.code.?, "E-BORROW")) {
            found = true;
        }
    }
    try testing.expect(found);
}

test "pipeline copies drop specializations into analysis context" {
    const alloc = testing.allocator;

    const instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 2,
            .pre_instrs = &.{},
            .arms = &[_]ir.IrCaseArm{
                .{
                    .condition = 0,
                    .cond_instrs = &[_]ir.Instruction{
                        .{ .field_get = .{ .dest = 1, .object = 0, .field = "value" } },
                    },
                    .body_instrs = &.{},
                    .result = null,
                },
            },
            .default_instrs = &.{},
            .default_result = null,
        } },
        .{ .ret = .{ .value = null } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const params = [_]ir.Param{.{ .name = "input", .type_expr = .any }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "drop_spec_test",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = .void,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var result = try runAnalysisPipeline(alloc, &program);
    defer result.deinit();

    try testing.expect(result.context.drop_specializations.items.len > 0);
}

test "debug policy skips optional analysis metadata passes" {
    const alloc = testing.allocator;

    const instrs = [_]ir.Instruction{
        .{ .case_block = .{
            .dest = 2,
            .pre_instrs = &.{},
            .arms = &[_]ir.IrCaseArm{
                .{
                    .condition = 0,
                    .cond_instrs = &[_]ir.Instruction{
                        .{ .field_get = .{ .dest = 1, .object = 0, .field = "value" } },
                    },
                    .body_instrs = &.{},
                    .result = null,
                },
            },
            .default_instrs = &.{},
            .default_result = null,
        } },
        .{ .ret = .{ .value = null } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const params = [_]ir.Param{.{ .name = "input", .type_expr = .any }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "debug_policy_test",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = .void,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var full_result = try runAnalysisPipeline(alloc, &program);
    defer full_result.deinit();
    try testing.expect(full_result.context.drop_specializations.items.len > 0);

    var debug_result = try runAnalysisPipelineWithPolicy(
        alloc,
        &program,
        frontend_policy.FrontendOptimizeMode.debug.passPolicy(),
    );
    defer debug_result.deinit();
    try testing.expectEqual(@as(usize, 0), debug_result.context.drop_specializations.items.len);
    try testing.expectEqual(@as(usize, 0), debug_result.context.reuse_pairs.items.len);
    try testing.expectEqual(@as(usize, 0), debug_result.context.arc_ops.items.len);
}
