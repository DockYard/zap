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

    return null;
}

/// Identifier of a syntactic callee. Resolved against the scope graph at
/// fixed-point time. Names are interned strings owned by the graph's
/// interner; the inference pass borrows them, never frees them.
const CalleeRef = struct {
    name: []const u8,
    arity: u32,
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
/// and `graph.macro_families[i].required_caps` to the inferred sets.
pub fn inferAndApply(allocator: Allocator, graph: *ScopeGraph, interner: *const ast.StringInterner) !void {
    var inference = try buildRecords(allocator, graph, interner);
    defer inference.deinit();

    propagate(&inference, graph, interner);

    for (graph.macro_families.items, 0..) |*family, idx| {
        family.required_caps = inference.macro_records[idx].inferred;
    }
    _ = graph.families.items;
    // Function families do not carry a `required_caps` field today; the
    // inference still walks their bodies so transitive callers (macros)
    // pick up the impure work, but we deliberately skip writing back to
    // `FunctionFamily` until callers have a use for it.
}

fn buildRecords(allocator: Allocator, graph: *ScopeGraph, interner: *const ast.StringInterner) !Inference {
    const function_records = try allocator.alloc(FamilyRecord, graph.families.items.len);
    @memset(function_records, .{});
    const macro_records = try allocator.alloc(FamilyRecord, graph.macro_families.items.len);
    @memset(macro_records, .{});

    for (graph.families.items, 0..) |*family, idx| {
        try walkFamilyClauses(allocator, &function_records[idx], family.clauses.items, interner);
        function_records[idx].inferred = function_records[idx].direct;
    }
    for (graph.macro_families.items, 0..) |*family, idx| {
        try walkFamilyClauses(allocator, &macro_records[idx], family.clauses.items, interner);
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
) !void {
    for (clauses) |clause_ref| {
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        if (clause.body) |body| {
            for (body) |stmt| try walkStmt(allocator, record, stmt, interner);
        }
    }
}

fn walkStmt(
    allocator: Allocator,
    record: *FamilyRecord,
    stmt: ast.Stmt,
    interner: *const ast.StringInterner,
) !void {
    switch (stmt) {
        .expr => |e| try walkExpr(allocator, record, e, interner),
        .assignment => |a| try walkExpr(allocator, record, a.value, interner),
        .function_decl, .macro_decl, .import_decl, .attribute => {},
    }
}

fn walkExpr(
    allocator: Allocator,
    record: *FamilyRecord,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
) error{OutOfMemory}!void {
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
        => {},

        .string_interpolation => |si| {
            for (si.parts) |part| {
                if (part == .expr) try walkExpr(allocator, record, part.expr, interner);
            }
        },

        .tuple => |t| for (t.elements) |elem| try walkExpr(allocator, record, elem, interner),
        .list => |l| for (l.elements) |elem| try walkExpr(allocator, record, elem, interner),
        .map => |m| {
            if (m.update_source) |src| try walkExpr(allocator, record, src, interner);
            for (m.fields) |entry| {
                try walkExpr(allocator, record, entry.key, interner);
                try walkExpr(allocator, record, entry.value, interner);
            }
        },
        .struct_expr => |s| {
            if (s.update_source) |src| try walkExpr(allocator, record, src, interner);
            for (s.fields) |field| try walkExpr(allocator, record, field.value, interner);
        },
        .range => |r| {
            try walkExpr(allocator, record, r.start, interner);
            try walkExpr(allocator, record, r.end, interner);
            if (r.step) |s| try walkExpr(allocator, record, s, interner);
        },

        .binary_op => |b| {
            try walkExpr(allocator, record, b.lhs, interner);
            try walkExpr(allocator, record, b.rhs, interner);
        },
        .unary_op => |u| try walkExpr(allocator, record, u.operand, interner),
        .pipe => |p| {
            try walkExpr(allocator, record, p.lhs, interner);
            try walkExpr(allocator, record, p.rhs, interner);
        },
        .unwrap => |u| try walkExpr(allocator, record, u.expr, interner),
        .error_pipe => |ep| {
            try walkExpr(allocator, record, ep.chain, interner);
            switch (ep.handler) {
                .block => |arms| {
                    for (arms) |arm| {
                        if (arm.guard) |g| try walkExpr(allocator, record, g, interner);
                        for (arm.body) |s| try walkStmt(allocator, record, s, interner);
                    }
                },
                .function => |f| try walkExpr(allocator, record, f, interner),
            }
        },
        .panic_expr => |pe| try walkExpr(allocator, record, pe.message, interner),
        .type_annotated => |ta| try walkExpr(allocator, record, ta.expr, interner),

        .call => |call| try walkCall(allocator, record, call, interner),
        .field_access => |fa| try walkExpr(allocator, record, fa.object, interner),

        .if_expr => |ie| {
            try walkExpr(allocator, record, ie.condition, interner);
            for (ie.then_block) |s| try walkStmt(allocator, record, s, interner);
            if (ie.else_block) |else_b| {
                for (else_b) |s| try walkStmt(allocator, record, s, interner);
            }
        },
        .case_expr => |ce| {
            try walkExpr(allocator, record, ce.scrutinee, interner);
            for (ce.clauses) |clause| {
                if (clause.guard) |g| try walkExpr(allocator, record, g, interner);
                for (clause.body) |s| try walkStmt(allocator, record, s, interner);
            }
        },
        .cond_expr => |ce| {
            for (ce.clauses) |clause| {
                try walkExpr(allocator, record, clause.condition, interner);
                for (clause.body) |s| try walkStmt(allocator, record, s, interner);
            }
        },
        .for_expr => |fe| {
            try walkExpr(allocator, record, fe.iterable, interner);
            if (fe.filter) |f| try walkExpr(allocator, record, f, interner);
            try walkExpr(allocator, record, fe.body, interner);
        },

        .list_cons_expr => |lc| {
            try walkExpr(allocator, record, lc.head, interner);
            try walkExpr(allocator, record, lc.tail, interner);
        },

        .quote_expr => |q| {
            for (q.body) |s| try walkStmt(allocator, record, s, interner);
        },
        .unquote_expr => |u| try walkExpr(allocator, record, u.expr, interner),
        .unquote_splicing_expr => |u| try walkExpr(allocator, record, u.expr, interner),

        .block => |b| for (b.stmts) |s| try walkStmt(allocator, record, s, interner),

        .intrinsic => |i| {
            for (i.args) |arg| try walkExpr(allocator, record, arg, interner);
        },

        .anonymous_function => |af| {
            for (af.decl.clauses) |clause| {
                if (clause.body) |body| {
                    for (body) |s| try walkStmt(allocator, record, s, interner);
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
) error{OutOfMemory}!void {
    // First, walk the callee subexpression and the arguments so any
    // capabilities buried inside compound expressions (e.g. an arg that
    // calls another intrinsic) are still picked up.
    try walkExpr(allocator, record, call.callee, interner);
    for (call.args) |arg| try walkExpr(allocator, record, arg, interner);

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
            try record.callees.append(allocator, .{ .name = name, .arity = arity });
        },
        .field_access => |fa| {
            // `:zig.X.Y(args)` — extract the trailing segments and look
            // them up. The CTFE interpreter recognises both single-name
            // (`:zig.file_read`) and dotted-name (`:zig.Prim.glob`) shapes.
            if (collectQualifiedName(allocator, fa, interner)) |joined| {
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
                    try record.callees.append(allocator, .{ .name = last, .arity = arity });
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
) ?QualifiedName {
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(allocator);

    var current_field = interner.get(fa.field);
    var current_object = fa.object;
    segments.append(allocator, current_field) catch return null;

    while (true) {
        switch (current_object.*) {
            .field_access => |inner| {
                current_field = interner.get(inner.field);
                segments.append(allocator, current_field) catch return null;
                current_object = inner.object;
            },
            .atom_literal => |atom| {
                const root_name = interner.get(atom.value);
                std.mem.reverse([]const u8, segments.items);
                const dotted = std.mem.join(allocator, ".", segments.items) catch return null;
                const last = if (segments.items.len > 0) segments.items[segments.items.len - 1] else null;
                return .{
                    .dotted = dotted,
                    .is_zig = std.mem.eql(u8, root_name, "zig"),
                    .last_segment = last,
                };
            },
            .var_ref => |vr| {
                const root_name = interner.get(vr.name);
                segments.append(allocator, root_name) catch return null;
                std.mem.reverse([]const u8, segments.items);
                const dotted = std.mem.join(allocator, ".", segments.items) catch return null;
                const last = if (segments.items.len > 0) segments.items[segments.items.len - 1] else null;
                return .{
                    .dotted = dotted,
                    .is_zig = false,
                    .last_segment = last,
                };
            },
            .struct_ref => {
                std.mem.reverse([]const u8, segments.items);
                const dotted = std.mem.join(allocator, ".", segments.items) catch return null;
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
fn propagate(inference: *Inference, graph: *const ScopeGraph, interner: *const ast.StringInterner) void {
    var changed = true;
    var iteration: u32 = 0;
    while (changed) : (iteration += 1) {
        std.debug.assert(iteration < 1024); // call graph is finite — fixed-point converges fast
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
