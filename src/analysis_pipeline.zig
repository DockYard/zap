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

// ============================================================
// Analysis Pipeline Orchestrator
//
// Sequences all analysis modules and produces both:
// 1. A legacy escape_analysis.Result for backward compat with
//    codegen.zig and types.zig
// 2. A lattice.AnalysisContext with full analysis results for
//    future use by the ZIR backend
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
///   5. Lambda set specialization (0-CFA, contification)
///   6. Perceus reuse analysis (deconstruction/construction pairing)
///   7. Build legacy result for backward compat
pub fn runAnalysisPipeline(
    alloc: std.mem.Allocator,
    program: *const ir.Program,
) !PipelineResult {
    var pipeline_diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty;
    errdefer pipeline_diagnostics.deinit(alloc);

    // --------------------------------------------------------
    // Phase 1: Initial generalized escape analysis
    // --------------------------------------------------------
    var escape_analyzer = generalized_escape.GeneralizedEscapeAnalyzer.init(alloc, program.*);
    defer escape_analyzer.deinit();
    var ctx = try escape_analyzer.analyze();

    // --------------------------------------------------------
    // Phase 2: Interprocedural summary computation
    // --------------------------------------------------------
    var interproc = try interprocedural.InterproceduralAnalyzer.init(alloc, program);
    defer interproc.deinit();
    try interproc.analyze();

    // Copy interprocedural summaries into the analysis context.
    var summary_iter = interproc.summaries.iterator();
    while (summary_iter.next()) |entry| {
        try ctx.function_summaries.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    // --------------------------------------------------------
    // Phase 3: Re-run escape with interprocedural summaries
    //          (feedback loop for refined call-site analysis)
    // --------------------------------------------------------
    var escape_analyzer2 = generalized_escape.GeneralizedEscapeAnalyzer.init(alloc, program.*);
    defer escape_analyzer2.deinit();
    // Inject summaries before analysis using the public API.
    try escape_analyzer2.setFunctionSummaries(&ctx.function_summaries);
    var ctx2 = try escape_analyzer2.analyze();

    // Replace context with refined results, keeping summaries.
    // First, preserve summaries from ctx into ctx2.
    var sum_iter3 = ctx.function_summaries.iterator();
    while (sum_iter3.next()) |entry| {
        if (!ctx2.function_summaries.contains(entry.key_ptr.*)) {
            try ctx2.function_summaries.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    ctx.deinit();
    ctx = ctx2;

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

    // --------------------------------------------------------
    // Phase 4: Region solving per function
    // --------------------------------------------------------
    var solver = region_solver.RegionSolver.init(alloc);

    for (program.functions) |*func| {
        // Extract per-function escape states.
        var func_escape = std.AutoArrayHashMap(ir.LocalId, lattice.EscapeState).init(alloc);
        defer func_escape.deinit();
        var es_iter = ctx.escape_states.iterator();
        while (es_iter.next()) |entry| {
            if (entry.key_ptr.function == func.id) {
                try func_escape.put(entry.key_ptr.local, entry.value_ptr.*);
            }
        }

        // Extract per-function alloc sites by scanning IR for allocating instructions.
        var func_alloc_sites = std.AutoArrayHashMap(ir.LocalId, lattice.AllocSiteId).init(alloc);
        defer func_alloc_sites.deinit();
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
                        try func_alloc_sites.put(dest, next_site);
                        next_site += 1;
                    }
                }
            }
        }

        // Run region solver on this function.
        var region_result = solver.solveFunction(func, &func_escape, &func_alloc_sites) catch {
            // If region solving fails for a function (e.g., empty function),
            // continue with other functions.
            continue;
        };
        defer region_result.deinit();

        // Merge region assignments back into context.
        var ra_iter = region_result.region_assignments.iterator();
        while (ra_iter.next()) |entry| {
            const vkey = lattice.ValueKey{ .function = func.id, .local = entry.key_ptr.* };
            try ctx.region_assignments.put(vkey, entry.value_ptr.*);
        }

        // Merge updated alloc summaries.
        var ras_iter = region_result.alloc_summaries.iterator();
        while (ras_iter.next()) |entry| {
            try ctx.alloc_summaries.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Merge outlives constraints.
        for (region_result.outlives_constraints.items) |c| {
            try ctx.outlives_constraints.append(alloc, c);
        }
    }

    // --------------------------------------------------------
    // Phase 5: Lambda set specialization
    // --------------------------------------------------------
    var ls_analyzer = try lambda_sets.LambdaSetAnalyzer.init(alloc, program);
    defer ls_analyzer.deinit();
    try ls_analyzer.analyze();
    try ls_analyzer.populateContext(&ctx);

    // --------------------------------------------------------
    // Phase 6: Perceus reuse analysis
    // --------------------------------------------------------
    var perceus_analyzer = perceus.PerceusAnalyzer.initWithContext(alloc, program, &ctx);
    defer perceus_analyzer.deinit();
    const perceus_result = try perceus_analyzer.analyze();
    defer perceus_result.deinit(alloc);

    // Copy Perceus results into context.
    for (perceus_result.reuse_pairs) |pair| {
        try ctx.addReusePair(pair);
    }
    for (perceus_result.arc_ops) |op| {
        try ctx.arc_ops.append(alloc, op);
    }
    for (perceus_result.drop_specializations) |spec| {
        const copied_fields = try alloc.alloc(lattice.FieldDrop, spec.field_drops.len);
        @memcpy(copied_fields, spec.field_drops);
        try ctx.addDropSpecialization(.{
            .match_site = spec.match_site,
            .constructor_tag = spec.constructor_tag,
            .field_drops = copied_fields,
            .function = spec.function,
            .insertion_point = spec.insertion_point,
        });
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
                                if (ctx.function_summaries.getPtr(func.id)) |summary| {
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

    // --------------------------------------------------------
    // Phase 6.5: ARC optimization
    // --------------------------------------------------------
    var arc_opt = arc_optimizer.ArcOptimizer.init(alloc, program, &ctx);
    defer arc_opt.deinit();
    try arc_opt.optimize();

    // --------------------------------------------------------
    // Phase 7: Compute closure environment tiers
    // --------------------------------------------------------
    for (program.functions) |func| {
        if (func.is_closure or func.captures.len > 0) {
            // Find the escape state for this closure's creation site.
            // Look through all functions for a make_closure that references this function.
            const escape = findClosureEscape(&ctx, program, func.id);
            const tier = lattice.escapeToClosureTier(escape, func.captures.len > 0);
            try ctx.closure_tiers.put(func.id, tier);
        }
    }

    return .{
        .context = ctx,
        .diagnostics = pipeline_diagnostics,
    };
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

/// Find the escape state for a closure's creation site by searching
/// for the make_closure instruction that targets this function.
/// Also checks for the call-local pattern: if the closure is only
/// ever called (never stored, passed, or returned), override to no_escape.
fn findClosureEscape(
    ctx: *const lattice.AnalysisContext,
    program: *const ir.Program,
    closure_func_id: ir.FunctionId,
) lattice.EscapeState {
    for (program.functions) |func| {
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .make_closure => |mc| {
                        if (mc.function == closure_func_id) {
                            // Check if this closure is only called locally
                            // (never stored, passed as arg, or returned).
                            if (isCallLocalOnly(func, mc.dest, block.instructions)) {
                                return .no_escape;
                            }
                            if (hasHardEscapeInFunction(func, mc.dest)) {
                                return .global_escape;
                            }
                            const vkey = lattice.ValueKey{
                                .function = func.id,
                                .local = mc.dest,
                            };
                            return ctx.getEscape(vkey);
                        }
                    },
                    // Check nested instructions.
                    .if_expr => |ie| {
                        if (findClosureEscapeInInstrs(ctx, func.id, ie.then_instrs, closure_func_id)) |e| return e;
                        if (findClosureEscapeInInstrs(ctx, func.id, ie.else_instrs, closure_func_id)) |e| return e;
                    },
                    .case_block => |cb| {
                        if (findClosureEscapeInInstrs(ctx, func.id, cb.pre_instrs, closure_func_id)) |e| return e;
                        for (cb.arms) |arm| {
                            if (findClosureEscapeInInstrs(ctx, func.id, arm.cond_instrs, closure_func_id)) |e| return e;
                            if (findClosureEscapeInInstrs(ctx, func.id, arm.body_instrs, closure_func_id)) |e| return e;
                        }
                        if (findClosureEscapeInInstrs(ctx, func.id, cb.default_instrs, closure_func_id)) |e| return e;
                    },
                    else => {},
                }
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
fn isCallLocalOnly(func: ir.Function, closure_local: ir.LocalId, start_instrs: []const ir.Instruction) bool {
    // Track aliases: locals that hold the same value as closure_local.
    // Simple: just track the initial local and any direct copies.
    var found_use = false;
    return isCallLocalInInstrs(closure_local, start_instrs, start_instrs, &found_use) and
        isCallLocalInAllBlocks(func, closure_local);
}

fn isCallLocalInAllBlocks(func: ir.Function, closure_local: ir.LocalId) bool {
    var found_use = false;
    for (func.body) |block| {
        if (!isCallLocalInInstrs(closure_local, block.instructions, block.instructions, &found_use)) return false;
    }
    return true;
}

fn isCallLocalInInstrs(closure_local: ir.LocalId, instrs: []const ir.Instruction, root_instrs: []const ir.Instruction, found_use: *bool) bool {
    for (instrs) |instr| {
        switch (instr) {
            .call_closure => |cc| {
                if (isAliasOfClosure(cc.callee, closure_local, root_instrs, 0)) {
                    found_use.* = true;
                    // This is fine — closure is being called.
                    // But check if it's also passed as an argument.
                    for (cc.args) |arg| {
                        if (isAliasOfClosure(arg, closure_local, root_instrs, 0)) return false; // Passed as arg too!
                    }
                }
            },
            // If the closure local appears as an argument to any call, it escapes.
            .call_direct => |cd| {
                for (cd.args) |arg| {
                    if (isAliasOfClosure(arg, closure_local, root_instrs, 0)) return false;
                }
            },
            .call_named => |cn| {
                for (cn.args) |arg| {
                    if (isAliasOfClosure(arg, closure_local, root_instrs, 0)) return false;
                }
            },
            .call_dispatch => |cd2| {
                for (cd2.args) |arg| {
                    if (isAliasOfClosure(arg, closure_local, root_instrs, 0)) return false;
                }
            },
            .call_builtin => |cb| {
                for (cb.args) |arg| {
                    if (isAliasOfClosure(arg, closure_local, root_instrs, 0)) return false;
                }
            },
            // If returned, it escapes.
            .ret => |r| {
                if (r.value) |v| {
                    if (isAliasOfClosure(v, closure_local, root_instrs, 0)) return false;
                }
            },
            .cond_return => |cr| {
                if (cr.value) |v| {
                    if (isAliasOfClosure(v, closure_local, root_instrs, 0)) return false;
                }
            },
            // If stored in aggregate, it escapes.
            .tuple_init => |ti| {
                for (ti.elements) |e| {
                    if (isAliasOfClosure(e, closure_local, root_instrs, 0)) return false;
                }
            },
            .list_init => |li| {
                for (li.elements) |e| {
                    if (isAliasOfClosure(e, closure_local, root_instrs, 0)) return false;
                }
            },
            .struct_init => |si| {
                for (si.fields) |f| {
                    if (isAliasOfClosure(f.value, closure_local, root_instrs, 0)) return false;
                }
            },
            .field_set => |fs| {
                if (isAliasOfClosure(fs.value, closure_local, root_instrs, 0)) return false;
            },
            // Recurse into nested instructions.
            .if_expr => |ie| {
                if (!isCallLocalInInstrs(closure_local, ie.then_instrs, root_instrs, found_use)) return false;
                if (!isCallLocalInInstrs(closure_local, ie.else_instrs, root_instrs, found_use)) return false;
            },
            .case_block => |cb| {
                if (!isCallLocalInInstrs(closure_local, cb.pre_instrs, root_instrs, found_use)) return false;
                for (cb.arms) |arm| {
                    if (!isCallLocalInInstrs(closure_local, arm.cond_instrs, root_instrs, found_use)) return false;
                    if (!isCallLocalInInstrs(closure_local, arm.body_instrs, root_instrs, found_use)) return false;
                }
                if (!isCallLocalInInstrs(closure_local, cb.default_instrs, root_instrs, found_use)) return false;
            },
            .guard_block => |gb| {
                if (!isCallLocalInInstrs(closure_local, gb.body, root_instrs, found_use)) return false;
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    if (!isCallLocalInInstrs(closure_local, c.body_instrs, root_instrs, found_use)) return false;
                }
                if (!isCallLocalInInstrs(closure_local, sl.default_instrs, root_instrs, found_use)) return false;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    if (!isCallLocalInInstrs(closure_local, c.body_instrs, root_instrs, found_use)) return false;
                }
                if (!isCallLocalInInstrs(closure_local, sr.default_instrs, root_instrs, found_use)) return false;
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    if (!isCallLocalInInstrs(closure_local, c.body_instrs, root_instrs, found_use)) return false;
                }
            },
            else => {},
        }
    }
    return true;
}

fn isAliasOfClosure(local: ir.LocalId, closure_local: ir.LocalId, instrs: []const ir.Instruction, depth: u8) bool {
    if (local == closure_local) return true;
    if (depth > 32) return false;
    for (instrs) |instr| {
        switch (instr) {
            .local_get => |lg| if (lg.dest == local) return isAliasOfClosure(lg.source, closure_local, instrs, depth + 1),
            .local_set => |ls| if (ls.dest == local) return isAliasOfClosure(ls.value, closure_local, instrs, depth + 1),
            .move_value => |mv| if (mv.dest == local) return isAliasOfClosure(mv.source, closure_local, instrs, depth + 1),
            .share_value => |sv| if (sv.dest == local) return isAliasOfClosure(sv.source, closure_local, instrs, depth + 1),
            .if_expr => |ie| {
                if (isAliasOfClosure(local, closure_local, ie.then_instrs, depth)) return true;
                if (isAliasOfClosure(local, closure_local, ie.else_instrs, depth)) return true;
            },
            .case_block => |cb| {
                if (isAliasOfClosure(local, closure_local, cb.pre_instrs, depth)) return true;
                for (cb.arms) |arm| {
                    if (isAliasOfClosure(local, closure_local, arm.cond_instrs, depth)) return true;
                    if (isAliasOfClosure(local, closure_local, arm.body_instrs, depth)) return true;
                }
                if (isAliasOfClosure(local, closure_local, cb.default_instrs, depth)) return true;
            },
            .guard_block => |gb| if (isAliasOfClosure(local, closure_local, gb.body, depth)) return true,
            .switch_literal => |sl| {
                for (sl.cases) |c| if (isAliasOfClosure(local, closure_local, c.body_instrs, depth)) return true;
                if (isAliasOfClosure(local, closure_local, sl.default_instrs, depth)) return true;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| if (isAliasOfClosure(local, closure_local, c.body_instrs, depth)) return true;
                if (isAliasOfClosure(local, closure_local, sr.default_instrs, depth)) return true;
            },
            .union_switch_return => |usr| for (usr.cases) |c| if (isAliasOfClosure(local, closure_local, c.body_instrs, depth)) return true,
            else => {},
        }
    }
    return false;
}

fn hasHardEscapeInFunction(func: ir.Function, closure_local: ir.LocalId) bool {
    for (func.body) |block| {
        if (hasHardEscapeInInstrs(closure_local, block.instructions, block.instructions)) return true;
    }
    return false;
}

fn hasHardEscapeInInstrs(closure_local: ir.LocalId, instrs: []const ir.Instruction, root_instrs: []const ir.Instruction) bool {
    for (instrs) |instr| {
        switch (instr) {
            .ret => |r| if (r.value) |v| {
                if (isAliasOfClosure(v, closure_local, root_instrs, 0)) return true;
            },
            .cond_return => |cr| if (cr.value) |v| {
                if (isAliasOfClosure(v, closure_local, root_instrs, 0)) return true;
            },
            .tuple_init => |ti| {
                for (ti.elements) |e| if (isAliasOfClosure(e, closure_local, root_instrs, 0)) return true;
            },
            .list_init => |li| {
                for (li.elements) |e| if (isAliasOfClosure(e, closure_local, root_instrs, 0)) return true;
            },
            .struct_init => |si| {
                for (si.fields) |f| if (isAliasOfClosure(f.value, closure_local, root_instrs, 0)) return true;
            },
            .field_set => |fs| if (isAliasOfClosure(fs.value, closure_local, root_instrs, 0)) return true,
            .if_expr => |ie| {
                if (hasHardEscapeInInstrs(closure_local, ie.then_instrs, root_instrs)) return true;
                if (hasHardEscapeInInstrs(closure_local, ie.else_instrs, root_instrs)) return true;
            },
            .case_block => |cb| {
                if (hasHardEscapeInInstrs(closure_local, cb.pre_instrs, root_instrs)) return true;
                for (cb.arms) |arm| {
                    if (hasHardEscapeInInstrs(closure_local, arm.cond_instrs, root_instrs)) return true;
                    if (hasHardEscapeInInstrs(closure_local, arm.body_instrs, root_instrs)) return true;
                }
                if (hasHardEscapeInInstrs(closure_local, cb.default_instrs, root_instrs)) return true;
            },
            .guard_block => |gb| if (hasHardEscapeInInstrs(closure_local, gb.body, root_instrs)) return true,
            .switch_literal => |sl| {
                for (sl.cases) |c| if (hasHardEscapeInInstrs(closure_local, c.body_instrs, root_instrs)) return true;
                if (hasHardEscapeInInstrs(closure_local, sl.default_instrs, root_instrs)) return true;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| if (hasHardEscapeInInstrs(closure_local, c.body_instrs, root_instrs)) return true;
                if (hasHardEscapeInInstrs(closure_local, sr.default_instrs, root_instrs)) return true;
            },
            .union_switch_return => |usr| for (usr.cases) |c| if (hasHardEscapeInInstrs(closure_local, c.body_instrs, root_instrs)) return true,
            else => {},
        }
    }
    return false;
}

fn findClosureEscapeInInstrs(
    ctx: *const lattice.AnalysisContext,
    func_id: ir.FunctionId,
    instrs: []const ir.Instruction,
    closure_func_id: ir.FunctionId,
) ?lattice.EscapeState {
    for (instrs) |instr| {
        switch (instr) {
            .make_closure => |mc| {
                if (mc.function == closure_func_id) {
                    const vkey = lattice.ValueKey{
                        .function = func_id,
                        .local = mc.dest,
                    };
                    return ctx.getEscape(vkey);
                }
            },
            .if_expr => |ie| {
                if (findClosureEscapeInInstrs(ctx, func_id, ie.then_instrs, closure_func_id)) |e| return e;
                if (findClosureEscapeInInstrs(ctx, func_id, ie.else_instrs, closure_func_id)) |e| return e;
            },
            .case_block => |cb| {
                if (findClosureEscapeInInstrs(ctx, func_id, cb.pre_instrs, closure_func_id)) |e| return e;
                for (cb.arms) |arm| {
                    if (findClosureEscapeInInstrs(ctx, func_id, arm.cond_instrs, closure_func_id)) |e| return e;
                    if (findClosureEscapeInInstrs(ctx, func_id, arm.body_instrs, closure_func_id)) |e| return e;
                }
                if (findClosureEscapeInInstrs(ctx, func_id, cb.default_instrs, closure_func_id)) |e| return e;
            },
            else => {},
        }
    }
    return null;
}

/// Verify ownership legality in a function's instructions.
/// Checks phi merges using mergeOwnership(), share_value/move_value
/// conversions using isOwnershipConversionLegal(), and captures.
fn verifyOwnershipInInstrs(
    out: *std.ArrayList(diagnostics.Diagnostic),
    ctx: *const lattice.AnalysisContext,
    program: *const ir.Program,
    func: ir.Function,
    instrs: []const ir.Instruction,
) !void {
    for (instrs) |instr| {
        switch (instr) {
            // Phi nodes: verify all incoming sources have compatible ownership.
            // Uses the per-value ownership states populated by the escape analyzer.
            .phi => |p| {
                if (p.sources.len >= 2) {
                    const first_key = lattice.ValueKey{ .function = func.id, .local = p.sources[0].value };
                    var merged_ownership = ctx.getOwnership(first_key);

                    for (p.sources[1..]) |src| {
                        const src_key = lattice.ValueKey{ .function = func.id, .local = src.value };
                        const src_ownership = ctx.getOwnership(src_key);
                        const merge_result = lattice.mergeOwnership(merged_ownership, src_ownership);
                        switch (merge_result) {
                            .ok => |o| merged_ownership = o,
                            .illegal => |err| {
                                const message = switch (err) {
                                    .borrowed_promoted_to_owned => "ownership merge is illegal: borrowed values cannot be merged into an owning value",
                                    .different_unique_bindings => "ownership merge is illegal: distinct unique values cannot be merged at a phi node",
                                };
                                try addAnalysisDiagnostic(
                                    ctx.allocator,
                                    out,
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
                    const dest_key = lattice.ValueKey{ .function = func.id, .local = p.dest };
                    // setOwnership can fail on allocation; ignore in verifier pass.
                    @constCast(ctx).setOwnership(dest_key, merged_ownership) catch {};
                }
            },

            // share_value: unique→shared conversion. Legal per §3.4.
            // Verify using isOwnershipConversionLegal.
            .share_value => |sv| {
                const src_key = lattice.ValueKey{ .function = func.id, .local = sv.source };
                const src_ownership = ctx.getOwnership(src_key);
                if (!lattice.isOwnershipConversionLegal(src_ownership, .shared)) {
                    try addAnalysisDiagnostic(
                        ctx.allocator,
                        out,
                        .@"error",
                        "ownership conversion is illegal: borrowed values cannot be promoted to shared ownership",
                        "E-OWN-SHARE",
                        "illegal share detected in IR ownership verification",
                        "keep the value borrowed, or create an owned/shared value before sharing it",
                    );
                }
                // Record dest as shared.
                const dest_key = lattice.ValueKey{ .function = func.id, .local = sv.dest };
                @constCast(ctx).setOwnership(dest_key, .shared) catch {};
            },

            // move_value: ownership transfer.
            .move_value => |mv| {
                const src_key = lattice.ValueKey{ .function = func.id, .local = mv.source };
                const src_ownership = ctx.getOwnership(src_key);
                // Move is always legal for owned values (unique/shared).
                // Illegal for borrowed (type checker enforces).
                if (src_ownership == .borrowed) {
                    try addAnalysisDiagnostic(
                        ctx.allocator,
                        out,
                        .@"error",
                        "ownership transfer is illegal: borrowed values cannot be moved",
                        "E-OWN-MOVE",
                        "illegal move of borrowed value detected",
                        "pass or store an owned value instead of moving a borrow",
                    );
                }
                // Dest inherits source ownership.
                const dest_key = lattice.ValueKey{ .function = func.id, .local = mv.dest };
                @constCast(ctx).setOwnership(dest_key, src_ownership) catch {};
            },

            // make_closure: verify borrowed captures aren't in escaping closures.
            .make_closure => |mc| {
                for (program.functions) |closure_func| {
                    if (closure_func.id != mc.function) continue;
                    for (closure_func.captures) |cap| {
                        if (cap.ownership == .borrowed) {
                            const closure_key = lattice.ValueKey{ .function = func.id, .local = mc.dest };
                            const escape = ctx.getEscape(closure_key);
                            if (escape.requiresHeap()) {
                                try addAnalysisDiagnostic(
                                    ctx.allocator,
                                    out,
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

            // Recurse into nested instruction lists.
            .if_expr => |ie| {
                try verifyOwnershipInInstrs(out, ctx, program, func, ie.then_instrs);
                try verifyOwnershipInInstrs(out, ctx, program, func, ie.else_instrs);
            },
            .case_block => |cb| {
                try verifyOwnershipInInstrs(out, ctx, program, func, cb.pre_instrs);
                for (cb.arms) |arm| {
                    try verifyOwnershipInInstrs(out, ctx, program, func, arm.cond_instrs);
                    try verifyOwnershipInInstrs(out, ctx, program, func, arm.body_instrs);
                }
                try verifyOwnershipInInstrs(out, ctx, program, func, cb.default_instrs);
            },
            .guard_block => |gb| {
                try verifyOwnershipInInstrs(out, ctx, program, func, gb.body);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    try verifyOwnershipInInstrs(out, ctx, program, func, c.body_instrs);
                }
                try verifyOwnershipInInstrs(out, ctx, program, func, sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    try verifyOwnershipInInstrs(out, ctx, program, func, c.body_instrs);
                }
                try verifyOwnershipInInstrs(out, ctx, program, func, sr.default_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    try verifyOwnershipInInstrs(out, ctx, program, func, c.body_instrs);
                }
            },
            else => {},
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

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
