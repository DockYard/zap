//! Static inference of compile-time capability requirements.
//!
//! Walks every function and macro family's clause bodies, identifies direct
//! uses of capability-bearing intrinsics, builds a syntactic call graph, and
//! propagates capabilities to the fixed point. The result is written to each
//! `MacroFamily.required_caps` and `FunctionFamily.required_caps` so the
//! macro evaluator and CTFE interpreter can consult the inferred set without
//! the author writing a `@requires` annotation.

const std = @import("std");
const ast = @import("ast.zig");
const ctfe = @import("ctfe.zig");
const scope = @import("scope.zig");

const Allocator = std.mem.Allocator;
const CapabilitySet = ctfe.CapabilitySet;
const ScopeGraph = scope.ScopeGraph;

const MAX_CAPABILITY_AST_WALK_DEPTH: u32 = 2048;
const MAX_CAPABILITY_PROPAGATION_ITERATIONS: u32 = 1024;

/// Errors that make capability inference unable to produce a trustworthy set.
pub const Error = Allocator.Error || error{
    CapabilityAstWalkDepthExceeded,
    CapabilityPropagationBudgetExceeded,
};

/// Context for a failed inference run. When available, `span` points at the
/// expression or call edge whose analysis exceeded a bounded inference limit.
pub const Failure = struct {
    span: ?ast.SourceSpan = null,
};

/// Map a known intrinsic / `:zig.` builtin name to its capability set.
/// Returns null when the name carries no compile-time effects.
pub fn capabilityForBuiltin(name: []const u8) ?CapabilitySet {
    // Filesystem / env intrinsics — match both the unqualified macro-time
    // form and the qualified `:zig.` runtime form.
    if (std.mem.eql(u8, name, "read_file")) return CapabilitySet.pure_only.with(.read_file);
    if (std.mem.eql(u8, name, "Prim.glob")) return CapabilitySet.pure_only.with(.read_file);
    if (std.mem.eql(u8, name, "File.read")) return CapabilitySet.pure_only.with(.read_file);
    if (std.mem.eql(u8, name, "file_read")) return CapabilitySet.pure_only.with(.read_file);
    if (std.mem.eql(u8, name, "get_env")) return CapabilitySet.pure_only.with(.read_env);
    if (std.mem.eql(u8, name, "System.get_env")) return CapabilitySet.pure_only.with(.read_env);

    // Source-graph reflection.
    if (std.mem.eql(u8, name, "source_graph_structs")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "source_graph_protocols")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "source_graph_unions")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "source_graph_impls")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "struct_info")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "struct_functions")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "struct_macros")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "union_variants")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "protocol_required_functions")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "source_text")) return CapabilitySet.pure_only.with(.reflect_source);
    if (std.mem.eql(u8, name, "source_location")) return CapabilitySet.pure_only.with(.reflect_source);

    return null;
}

/// Identifier of a syntactic callee. Resolved against the scope graph at
/// fixed-point time. Names are interned strings owned by the graph's
/// interner; the inference pass borrows them, never frees them.
const CalleeRef = struct {
    name: []const u8,
    arity: u32,
    span: ?ast.SourceSpan = null,
};

const FamilyKind = enum { function, macro };

const FamilyId = struct {
    kind: FamilyKind,
    index: u32,
};

const FamilyRecord = struct {
    direct: CapabilitySet = .{},
    callees: std.ArrayListUnmanaged(CalleeRef) = .empty,
    inferred: CapabilitySet = .{},
};

/// Inference state. Owned by the caller; freed via `deinit`.
pub const Inference = struct {
    allocator: Allocator,
    function_records: []FamilyRecord,
    macro_records: []FamilyRecord,

    pub fn deinit(self: *Inference) void {
        for (self.function_records) |*r| r.callees.deinit(self.allocator);
        for (self.macro_records) |*r| r.callees.deinit(self.allocator);
        self.allocator.free(self.function_records);
        self.allocator.free(self.macro_records);
    }
};

/// Walk every family's body, build the direct-call table, then propagate
/// capabilities to the fixed point. Mutates `graph.families[i].required_caps`
/// and `graph.macro_families[i].required_caps` to the inferred sets. Unknown
/// or inapplicable calls are treated as no inferred capability, not errors.
/// When an error is returned, `failure` contains any available diagnostic
/// context for the compiler boundary.
pub fn inferAndApply(
    allocator: Allocator,
    graph: *ScopeGraph,
    interner: *const ast.StringInterner,
    failure: *Failure,
) Error!void {
    failure.* = .{};

    var inference = try buildRecords(allocator, graph, interner, failure);
    defer inference.deinit();

    try propagate(&inference, graph, interner, failure);

    for (graph.macro_families.items, 0..) |*family, idx| {
        family.required_caps = inference.macro_records[idx].inferred;
    }
    _ = graph.families.items;
    // Function families do not carry a `required_caps` field today; the
    // inference still walks their bodies so transitive callers (macros)
    // pick up the impure work, but we deliberately skip writing back to
    // `FunctionFamily` until callers have a use for it.
}

fn buildRecords(
    allocator: Allocator,
    graph: *ScopeGraph,
    interner: *const ast.StringInterner,
    failure: *Failure,
) Error!Inference {
    const function_records = try allocator.alloc(FamilyRecord, graph.families.items.len);
    @memset(function_records, .{});
    errdefer {
        for (function_records) |*record| record.callees.deinit(allocator);
        allocator.free(function_records);
    }

    const macro_records = try allocator.alloc(FamilyRecord, graph.macro_families.items.len);
    @memset(macro_records, .{});
    errdefer {
        for (macro_records) |*record| record.callees.deinit(allocator);
        allocator.free(macro_records);
    }

    for (graph.families.items, 0..) |*family, idx| {
        try walkFamilyClauses(allocator, &function_records[idx], family.clauses.items, interner, failure);
        function_records[idx].inferred = function_records[idx].direct;
    }
    for (graph.macro_families.items, 0..) |*family, idx| {
        try walkFamilyClauses(allocator, &macro_records[idx], family.clauses.items, interner, failure);
        macro_records[idx].inferred = macro_records[idx].direct;
    }

    return Inference{
        .allocator = allocator,
        .function_records = function_records,
        .macro_records = macro_records,
    };
}

fn walkFamilyClauses(
    allocator: Allocator,
    record: *FamilyRecord,
    clauses: []const scope.FunctionClauseRef,
    interner: *const ast.StringInterner,
    failure: *Failure,
) Error!void {
    for (clauses) |clause_ref| {
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        if (clause.body) |body| {
            for (body) |stmt| try walkStmt(allocator, record, stmt, interner, failure, 0);
        }
    }
}

fn walkStmt(
    allocator: Allocator,
    record: *FamilyRecord,
    stmt: ast.Stmt,
    interner: *const ast.StringInterner,
    failure: *Failure,
    depth: u32,
) Error!void {
    switch (stmt) {
        .expr => |e| try walkExpr(allocator, record, e, interner, failure, depth),
        .assignment => |a| try walkExpr(allocator, record, a.value, interner, failure, depth),
        .function_decl, .macro_decl, .import_decl, .attribute => {},
    }
}

fn walkExpr(
    allocator: Allocator,
    record: *FamilyRecord,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    failure: *Failure,
    depth: u32,
) Error!void {
    if (depth >= MAX_CAPABILITY_AST_WALK_DEPTH) {
        failure.span = expr.getMeta().debugSpan();
        return error.CapabilityAstWalkDepthExceeded;
    }
    const child_depth = depth + 1;

    switch (expr.*) {
        .int_literal,
        .float_literal,
        .string_literal,
        .atom_literal,
        .bool_literal,
        .nil_literal,
        .var_ref,
        .struct_ref,
        .attr_ref,
        .binary_literal,
        .function_ref,
        // Poison sentinel (Phase 4.b): a parse-error placeholder calls
        // nothing, so it contributes no capability requirement.
        .poison,
        => {},

        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expr) try walkExpr(allocator, record, part.expr, interner, failure, child_depth);
            }
        },

        .tuple => |t| for (t.elements) |elem| try walkExpr(allocator, record, elem, interner, failure, child_depth),
        .list => |l| for (l.elements) |elem| try walkExpr(allocator, record, elem, interner, failure, child_depth),
        .map => |m| {
            if (m.update_source) |src| try walkExpr(allocator, record, src, interner, failure, child_depth);
            for (m.fields) |entry| {
                try walkExpr(allocator, record, entry.key, interner, failure, child_depth);
                try walkExpr(allocator, record, entry.value, interner, failure, child_depth);
            }
        },
        .struct_expr => |s| {
            if (s.update_source) |src| try walkExpr(allocator, record, src, interner, failure, child_depth);
            for (s.fields) |field| try walkExpr(allocator, record, field.value, interner, failure, child_depth);
        },
        .range => |r| {
            try walkExpr(allocator, record, r.start, interner, failure, child_depth);
            try walkExpr(allocator, record, r.end, interner, failure, child_depth);
            if (r.step) |s| try walkExpr(allocator, record, s, interner, failure, child_depth);
        },

        .binary_op => |b| {
            try walkExpr(allocator, record, b.lhs, interner, failure, child_depth);
            try walkExpr(allocator, record, b.rhs, interner, failure, child_depth);
        },
        .unary_op => |u| try walkExpr(allocator, record, u.operand, interner, failure, child_depth),
        .pipe => |p| {
            try walkExpr(allocator, record, p.lhs, interner, failure, child_depth);
            try walkExpr(allocator, record, p.rhs, interner, failure, child_depth);
        },
        .unwrap => |u| try walkExpr(allocator, record, u.expr, interner, failure, child_depth),
        .try_rescue => |tr| {
            for (tr.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            for (tr.rescue_clauses) |clause| {
                if (clause.guard) |g| try walkExpr(allocator, record, g, interner, failure, child_depth);
                for (clause.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            }
            if (tr.after_block) |cleanup| {
                for (cleanup) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            }
        },
        .error_pipe => |ep| {
            try walkExpr(allocator, record, ep.chain, interner, failure, child_depth);
            switch (ep.handler) {
                .block => |arms| {
                    for (arms) |arm| {
                        if (arm.guard) |g| try walkExpr(allocator, record, g, interner, failure, child_depth);
                        for (arm.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
                    }
                },
                .function => |f| try walkExpr(allocator, record, f, interner, failure, child_depth),
            }
        },
        .panic_expr => |pe| try walkExpr(allocator, record, pe.message, interner, failure, child_depth),
        .raise_expr => |re| try walkExpr(allocator, record, re.value, interner, failure, child_depth),
        .type_annotated => |ta| try walkExpr(allocator, record, ta.expr, interner, failure, child_depth),

        .call => |call| try walkCall(allocator, record, call, interner, failure, child_depth),
        .field_access => |fa| try walkExpr(allocator, record, fa.object, interner, failure, child_depth),

        .if_expr => |ie| {
            try walkExpr(allocator, record, ie.condition, interner, failure, child_depth);
            for (ie.then_block) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            if (ie.else_block) |else_b| {
                for (else_b) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            }
        },
        .case_expr => |ce| {
            try walkExpr(allocator, record, ce.scrutinee, interner, failure, child_depth);
            for (ce.clauses) |clause| {
                if (clause.guard) |g| try walkExpr(allocator, record, g, interner, failure, child_depth);
                for (clause.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            }
        },
        .cond_expr => |ce| {
            for (ce.clauses) |clause| {
                try walkExpr(allocator, record, clause.condition, interner, failure, child_depth);
                for (clause.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            }
        },
        .for_expr => |fe| {
            try walkExpr(allocator, record, fe.iterable, interner, failure, child_depth);
            if (fe.filter) |f| try walkExpr(allocator, record, f, interner, failure, child_depth);
            try walkExpr(allocator, record, fe.body, interner, failure, child_depth);
        },
        .with_expr => |we| {
            // `with` is desugared before capability inference normally
            // runs; walk the step exprs, the do-body, and the else-clause
            // bodies/guards so any effectful call inside is recorded.
            for (we.steps) |step| try walkExpr(allocator, record, step.expr, interner, failure, child_depth);
            for (we.do_body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
            if (we.else_clauses) |clauses| {
                for (clauses) |clause| {
                    if (clause.guard) |g| try walkExpr(allocator, record, g, interner, failure, child_depth);
                    for (clause.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
                }
            }
        },

        .list_cons_expr => |lc| {
            try walkExpr(allocator, record, lc.head, interner, failure, child_depth);
            try walkExpr(allocator, record, lc.tail, interner, failure, child_depth);
        },

        .quote_expr => |q| {
            for (q.body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
        },
        .unquote_expr => |u| try walkExpr(allocator, record, u.expr, interner, failure, child_depth),
        .unquote_splicing_expr => |u| try walkExpr(allocator, record, u.expr, interner, failure, child_depth),

        .block => |b| for (b.stmts) |s| try walkStmt(allocator, record, s, interner, failure, child_depth),

        .intrinsic => |i| {
            for (i.args) |arg| try walkExpr(allocator, record, arg, interner, failure, child_depth);
        },

        .anonymous_function => |af| {
            for (af.decl.clauses) |clause| {
                if (clause.body) |body| {
                    for (body) |s| try walkStmt(allocator, record, s, interner, failure, child_depth);
                }
            }
        },
    }
}

fn walkCall(
    allocator: Allocator,
    record: *FamilyRecord,
    call: ast.CallExpr,
    interner: *const ast.StringInterner,
    failure: *Failure,
    depth: u32,
) Error!void {
    // First, walk the callee subexpression and the arguments so any
    // capabilities buried inside compound expressions (e.g. an arg that
    // calls another intrinsic) are still picked up.
    try walkExpr(allocator, record, call.callee, interner, failure, depth);
    for (call.args) |arg| try walkExpr(allocator, record, arg, interner, failure, depth);

    const arity: u32 = @intCast(call.args.len);

    switch (call.callee.*) {
        .var_ref => |vr| {
            const name = interner.get(vr.name);
            if (capabilityForBuiltin(name)) |caps| {
                record.direct.flags |= caps.flags;
                return;
            }
            // Otherwise it's a user-named callee — record it for the
            // fixed-point pass to resolve against the family table.
            try record.callees.append(allocator, .{
                .name = name,
                .arity = arity,
                .span = call.meta.debugSpan(),
            });
        },
        .field_access => |fa| {
            // `:zig.X.Y(args)` — extract the trailing segments and look
            // them up. The CTFE interpreter recognises both single-name
            // (`:zig.file_read`) and dotted-name (`:zig.Prim.glob`) shapes.
            if (try collectQualifiedName(allocator, fa, interner)) |joined| {
                defer allocator.free(joined.dotted);
                if (joined.is_zig) {
                    if (capabilityForBuiltin(joined.dotted)) |caps| {
                        record.direct.flags |= caps.flags;
                        return;
                    }
                    if (joined.last_segment) |last| {
                        if (capabilityForBuiltin(last)) |caps| {
                            record.direct.flags |= caps.flags;
                            return;
                        }
                    }
                    return; // unknown :zig.* — assume pure
                }
                // Cross-struct call — the trailing segment is the function
                // name; treat it like a var_ref callee for resolution.
                if (joined.last_segment) |last| {
                    try record.callees.append(allocator, .{
                        .name = last,
                        .arity = arity,
                        .span = call.meta.debugSpan(),
                    });
                }
            }
        },
        else => {},
    }
}

const QualifiedName = struct {
    dotted: []const u8,
    is_zig: bool,
    last_segment: ?[]const u8,
};

/// Collect a `field_access` chain into a dotted string and a flag for whether
/// the chain roots at the `:zig` atom literal. The dotted form omits the
/// `:zig` prefix when present. Caller frees `dotted`.
fn collectQualifiedName(
    allocator: Allocator,
    fa: ast.FieldAccess,
    interner: *const ast.StringInterner,
) Allocator.Error!?QualifiedName {
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(allocator);

    var current_field = interner.get(fa.field);
    var current_object = fa.object;
    try segments.append(allocator, current_field);

    while (true) {
        switch (current_object.*) {
            .field_access => |inner| {
                current_field = interner.get(inner.field);
                try segments.append(allocator, current_field);
                current_object = inner.object;
            },
            .atom_literal => |atom| {
                const root_name = interner.get(atom.value);
                std.mem.reverse([]const u8, segments.items);
                const dotted = try std.mem.join(allocator, ".", segments.items);
                const last = if (segments.items.len > 0) segments.items[segments.items.len - 1] else null;
                return .{
                    .dotted = dotted,
                    .is_zig = std.mem.eql(u8, root_name, "zig"),
                    .last_segment = last,
                };
            },
            .var_ref => |vr| {
                const root_name = interner.get(vr.name);
                try segments.append(allocator, root_name);
                std.mem.reverse([]const u8, segments.items);
                const dotted = try std.mem.join(allocator, ".", segments.items);
                const last = if (segments.items.len > 0) segments.items[segments.items.len - 1] else null;
                return .{
                    .dotted = dotted,
                    .is_zig = false,
                    .last_segment = last,
                };
            },
            .struct_ref => {
                std.mem.reverse([]const u8, segments.items);
                const dotted = try std.mem.join(allocator, ".", segments.items);
                const last = if (segments.items.len > 0) segments.items[segments.items.len - 1] else null;
                return .{
                    .dotted = dotted,
                    .is_zig = false,
                    .last_segment = last,
                };
            },
            else => return null,
        }
    }
}

/// Iterate the family graph until no capability set changes. For each
/// callee we union the caps of every family that matches the callee's
/// name+arity. The match is conservative (over-approximates) when more
/// than one family shares the same name+arity, which is rare in practice
/// and only ever inflates the inferred set.
fn propagate(
    inference: *Inference,
    graph: *const ScopeGraph,
    interner: *const ast.StringInterner,
    failure: *Failure,
) Error!void {
    return propagateWithBudget(
        inference,
        graph,
        interner,
        failure,
        MAX_CAPABILITY_PROPAGATION_ITERATIONS,
    );
}

fn propagateWithBudget(
    inference: *Inference,
    graph: *const ScopeGraph,
    interner: *const ast.StringInterner,
    failure: *Failure,
    max_iterations: u32,
) Error!void {
    var changed = true;
    var iteration: u32 = 0;
    while (changed) : (iteration += 1) {
        if (iteration >= max_iterations) {
            failure.span = propagationFailureSpan(inference);
            return error.CapabilityPropagationBudgetExceeded;
        }
        changed = false;

        for (inference.function_records) |*record| {
            const new_caps = unionCalleeCaps(record, inference, graph, interner);
            if (new_caps.flags != record.inferred.flags) {
                record.inferred = new_caps;
                changed = true;
            }
        }
        for (inference.macro_records) |*record| {
            const new_caps = unionCalleeCaps(record, inference, graph, interner);
            if (new_caps.flags != record.inferred.flags) {
                record.inferred = new_caps;
                changed = true;
            }
        }
    }
}

fn propagationFailureSpan(inference: *const Inference) ?ast.SourceSpan {
    for (inference.function_records) |record| {
        for (record.callees.items) |callee| {
            if (callee.span) |span| return span;
        }
    }
    for (inference.macro_records) |record| {
        for (record.callees.items) |callee| {
            if (callee.span) |span| return span;
        }
    }
    return null;
}

fn unionCalleeCaps(
    record: *const FamilyRecord,
    inference: *const Inference,
    graph: *const ScopeGraph,
    interner: *const ast.StringInterner,
) CapabilitySet {
    var caps = record.direct;
    for (record.callees.items) |callee| {
        for (graph.families.items, 0..) |*family, idx| {
            if (family.arity != callee.arity) continue;
            if (!std.mem.eql(u8, interner.get(family.name), callee.name)) continue;
            caps.flags |= inference.function_records[idx].inferred.flags;
        }
        for (graph.macro_families.items, 0..) |*family, idx| {
            if (family.arity != callee.arity) continue;
            if (!std.mem.eql(u8, interner.get(family.name), callee.name)) continue;
            caps.flags |= inference.macro_records[idx].inferred.flags;
        }
    }
    return caps;
}

fn buildFunctionPropagationChainForTest(
    allocator: Allocator,
    interner: *ast.StringInterner,
    graph: *ScopeGraph,
    chain_len: usize,
    edge_span: ast.SourceSpan,
) Allocator.Error!Inference {
    for (0..chain_len) |index| {
        const name = try std.fmt.allocPrint(allocator, "capability_chain_{d}", .{index});
        defer allocator.free(name);
        const name_id = try interner.intern(name);
        _ = try graph.createFamily(0, name_id, 0, .public);
    }

    const function_records = try allocator.alloc(FamilyRecord, chain_len);
    @memset(function_records, .{});
    errdefer {
        for (function_records) |*record| record.callees.deinit(allocator);
        allocator.free(function_records);
    }

    const macro_records = try allocator.alloc(FamilyRecord, 0);
    errdefer allocator.free(macro_records);

    for (0..chain_len) |index| {
        if (index + 1 < chain_len) {
            const callee_name = interner.get(graph.families.items[index + 1].name);
            try function_records[index].callees.append(allocator, .{
                .name = callee_name,
                .arity = 0,
                .span = edge_span,
            });
        } else {
            function_records[index].direct = CapabilitySet.pure_only.with(.read_file);
            function_records[index].inferred = function_records[index].direct;
        }
    }

    return .{
        .allocator = allocator,
        .function_records = function_records,
        .macro_records = macro_records,
    };
}

test "capability propagation reports budget exhaustion with call span" {
    const test_budget: u32 = 4;
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();
    var graph = try ScopeGraph.init(allocator);
    defer graph.deinit();

    const edge_span = ast.SourceSpan{ .start = 123, .end = 130, .line = 9, .col = 17 };
    var inference = try buildFunctionPropagationChainForTest(
        allocator,
        &interner,
        &graph,
        @intCast(test_budget + 1),
        edge_span,
    );
    defer inference.deinit();

    var failure: Failure = .{};
    try std.testing.expectError(
        error.CapabilityPropagationBudgetExceeded,
        propagateWithBudget(&inference, &graph, &interner, &failure, test_budget),
    );
    const failure_span = failure.span orelse return error.TestExpectedDiagnosticSpan;
    try std.testing.expectEqual(edge_span.start, failure_span.start);
    try std.testing.expectEqual(edge_span.end, failure_span.end);
    try std.testing.expectEqual(edge_span.line, failure_span.line);
    try std.testing.expectEqual(edge_span.col, failure_span.col);
}

test "capability propagation converges at the propagation budget boundary" {
    const test_budget: u32 = 4;
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();
    var graph = try ScopeGraph.init(allocator);
    defer graph.deinit();

    var inference = try buildFunctionPropagationChainForTest(
        allocator,
        &interner,
        &graph,
        @intCast(test_budget),
        .{ .start = 10, .end = 11, .line = 1, .col = 1 },
    );
    defer inference.deinit();

    var failure: Failure = .{};
    try propagateWithBudget(&inference, &graph, &interner, &failure, test_budget);
    try std.testing.expect(failure.span == null);
    try std.testing.expect(inference.function_records[0].inferred.has(.read_file));
}
