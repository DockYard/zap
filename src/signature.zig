//! Shared helpers for rendering function, macro, protocol, and union
//! signatures back into Zap-syntax strings. Used by both the in-tree
//! Zig doc generator and by reflection intrinsics that surface
//! per-clause signature strings to compile-time Zap code.
//!
//! The signature builder prefers the original source bytes for any
//! AST node whose span is intact — patterns, exprs, type expressions
//! — and only falls back to AST-driven rendering when no source slice
//! is reachable (e.g. macro-generated nodes with synthetic spans).
//! The fallback path covers every variant the signature builder has
//! historically needed; rare nodes render as `?`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const scope = @import("scope.zig");

/// Append-only string buffer. Mirrors the small helper used elsewhere
/// in the compiler for HTML and signature emission. Append errors from
/// the underlying allocator are propagated so callers never observe
/// successful truncated signatures. Callers that need to retain the
/// rendered bytes must use `toOwnedSlice`; `toSlice` is borrowed.
pub const Buffer = struct {
    list: std.ArrayListUnmanaged(u8),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Buffer {
        return .{ .list = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Buffer) void {
        self.list.deinit(self.alloc);
    }

    pub fn str(self: *Buffer, s: []const u8) Allocator.Error!void {
        try self.list.appendSlice(self.alloc, s);
    }

    pub fn char(self: *Buffer, c: u8) Allocator.Error!void {
        try self.list.append(self.alloc, c);
    }

    pub fn fmt(self: *Buffer, comptime f: []const u8, args: anytype) Allocator.Error!void {
        try self.list.print(self.alloc, f, args);
    }

    pub fn toSlice(self: *Buffer) []const u8 {
        return self.list.items;
    }

    pub fn toOwnedSlice(self: *Buffer) Allocator.Error![]const u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

fn appendOwnedSignature(
    alloc: Allocator,
    signatures: *std.ArrayListUnmanaged([]const u8),
    rendered: []const u8,
) Allocator.Error!void {
    errdefer alloc.free(rendered);
    try signatures.append(alloc, rendered);
}

fn appendOwnershipQualifier(buf: *Buffer, ownership: ast.Ownership, explicit: bool) Allocator.Error!void {
    if (!explicit) return;
    switch (ownership) {
        .shared => try buf.str("shared "),
        .unique => try buf.str("unique "),
        .borrowed => try buf.str("borrowed "),
    }
}

/// Build one signature string per function clause. The output is the
/// reverse of the Zap parser's input: `name(p1 :: T1, p2 :: T2) -> R`,
/// optionally followed by `if guard`. Multi-clause function families
/// produce multiple strings — the doc generator renders each one as
/// its own signature pill so pattern-matching dispatch is visible.
pub fn buildClauseSignatures(
    alloc: Allocator,
    function_name: []const u8,
    clauses: []const scope.FunctionClauseRef,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error![]const []const u8 {
    var signatures: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (signatures.items) |signature| alloc.free(signature);
        signatures.deinit(alloc);
    }

    for (clauses) |clause_ref| {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) continue;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        try appendOwnedSignature(alloc, &signatures, try buildClauseSignature(alloc, function_name, clause, interner, graph));
    }
    if (signatures.items.len == 0) {
        try appendOwnedSignature(alloc, &signatures, try std.fmt.allocPrint(alloc, "{s}()", .{function_name}));
    }
    return signatures.toOwnedSlice(alloc);
}

pub fn buildClauseSignature(
    alloc: Allocator,
    function_name: []const u8,
    clause: ast.FunctionClause,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error![]const u8 {
    var buf = Buffer.init(alloc);
    errdefer buf.deinit();

    try buf.str(function_name);
    try buf.char('(');
    for (clause.params, 0..) |param, i| {
        if (i > 0) try buf.str(", ");
        try appendPattern(&buf, param.pattern, interner, graph);
        if (param.type_annotation) |type_ann| {
            try buf.str(" :: ");
            try appendOwnershipQualifier(&buf, param.ownership, param.ownership_explicit);
            try appendTypeExpr(&buf, type_ann, interner);
        }
        if (param.default) |default_expr| {
            try buf.str(" = ");
            try appendExpr(&buf, default_expr, interner, graph);
        }
    }
    try buf.char(')');
    if (clause.return_type) |ret| {
        try buf.str(" -> ");
        try appendTypeExpr(&buf, ret, interner);
    }
    if (clause.refinement) |refinement| {
        try buf.str(" if ");
        try appendExpr(&buf, refinement, interner, graph);
    }
    return buf.toOwnedSlice();
}

pub fn buildProtocolFunctionSignature(
    alloc: Allocator,
    function_sig: ast.ProtocolFunctionSig,
    interner: *const ast.StringInterner,
) Allocator.Error![]const u8 {
    var buf = Buffer.init(alloc);
    errdefer buf.deinit();

    try buf.str(interner.get(function_sig.name));
    try buf.char('(');
    for (function_sig.params, 0..) |param, i| {
        if (i > 0) try buf.str(", ");
        try buf.str(interner.get(param.name));
        if (param.type_annotation) |type_annotation| {
            try buf.str(" :: ");
            try appendOwnershipQualifier(&buf, param.ownership, param.ownership_explicit);
            try appendTypeExpr(&buf, type_annotation, interner);
        }
    }
    try buf.char(')');
    if (function_sig.return_type) |return_type| {
        try buf.str(" -> ");
        try appendTypeExpr(&buf, return_type, interner);
    }
    return buf.toOwnedSlice();
}

pub fn buildUnionVariantSignature(
    alloc: Allocator,
    variant: ast.UnionVariant,
    interner: *const ast.StringInterner,
) Allocator.Error![]const u8 {
    var buf = Buffer.init(alloc);
    errdefer buf.deinit();

    try buf.str(interner.get(variant.name));
    if (variant.type_expr) |type_expr| {
        try buf.str(" :: ");
        try appendTypeExpr(&buf, type_expr, interner);
    }
    return buf.toOwnedSlice();
}

pub fn appendStructName(buf: *Buffer, name: ast.StructName, interner: *const ast.StringInterner) Allocator.Error!void {
    for (name.parts, 0..) |part, i| {
        if (i > 0) try buf.char('.');
        try buf.str(interner.get(part));
    }
}

pub fn appendTypeExpr(buf: *Buffer, type_expr: *const ast.TypeExpr, interner: *const ast.StringInterner) Allocator.Error!void {
    switch (type_expr.*) {
        .name => |n| {
            try buf.str(interner.get(n.name));
            try appendTypeArgs(buf, n.args, interner);
        },
        .variable => |v| try buf.str(interner.get(v.name)),
        .list => |l| {
            try buf.char('[');
            try appendTypeExpr(buf, l.element, interner);
            try buf.char(']');
        },
        .tuple => |t| {
            try buf.char('{');
            for (t.elements, 0..) |elem, i| {
                if (i > 0) try buf.str(", ");
                try appendTypeExpr(buf, elem, interner);
            }
            try buf.char('}');
        },
        .function => |f| {
            // A function-TYPE annotation renders in the current surface
            // syntax `fn(P...) -> R` (the form the parser accepts), NOT the
            // legacy `(P... -> R)`. Distinct from a function DECLARATION
            // signature `name(P...) -> R` built by `buildFunctionSignature`.
            try buf.str("fn(");
            for (f.params, 0..) |param, i| {
                if (i > 0) try buf.str(", ");
                try appendTypeExpr(buf, param, interner);
            }
            try buf.str(") -> ");
            try appendTypeExpr(buf, f.return_type, interner);
        },
        else => try buf.char('?'),
    }
}

fn appendTypeArgs(buf: *Buffer, args: []const *const ast.TypeExpr, interner: *const ast.StringInterner) Allocator.Error!void {
    if (args.len == 0) return;
    try buf.char('(');
    for (args, 0..) |arg, i| {
        if (i > 0) try buf.str(", ");
        try appendTypeExpr(buf, arg, interner);
    }
    try buf.char(')');
}

fn sourceSlice(meta: ast.NodeMeta, graph: *const scope.ScopeGraph) ?[]const u8 {
    const source_id = meta.span.source_id orelse return null;
    const source = graph.sourceContentById(source_id);
    if (source.len == 0) return null;
    if (meta.span.start >= meta.span.end) return null;
    if (meta.span.end > source.len) return null;
    return std.mem.trim(u8, source[meta.span.start..meta.span.end], " \t\r\n");
}

fn appendZapStringLiteral(buf: *Buffer, value: []const u8) Allocator.Error!void {
    try buf.char('"');
    for (value) |c| {
        switch (c) {
            '\\' => try buf.str("\\\\"),
            '"' => try buf.str("\\\""),
            '\n' => try buf.str("\\n"),
            '\r' => try buf.str("\\r"),
            '\t' => try buf.str("\\t"),
            else => try buf.char(c),
        }
    }
    try buf.char('"');
}

fn appendLiteralPattern(buf: *Buffer, literal: ast.LiteralPattern, interner: *const ast.StringInterner) Allocator.Error!void {
    switch (literal) {
        .int => |v| try buf.fmt("{d}", .{v.value}),
        .float => |v| try buf.fmt("{d}", .{v.value}),
        .string => |v| try appendZapStringLiteral(buf, interner.get(v.value)),
        .atom => |v| {
            try buf.char(':');
            try buf.str(interner.get(v.value));
        },
        .bool_lit => |v| try buf.str(if (v.value) "true" else "false"),
        .nil => try buf.str("nil"),
    }
}

pub fn appendPattern(
    buf: *Buffer,
    pattern: *const ast.Pattern,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error!void {
    if (sourceSlice(pattern.getMeta(), graph)) |text| {
        try buf.str(text);
        return;
    }
    switch (pattern.*) {
        .wildcard => try buf.char('_'),
        .bind => |v| try buf.str(interner.get(v.name)),
        .pin => |v| {
            try buf.char('^');
            try buf.str(interner.get(v.name));
        },
        .literal => |literal| try appendLiteralPattern(buf, literal, interner),
        .paren => |v| {
            try buf.char('(');
            try appendPattern(buf, v.inner, interner, graph);
            try buf.char(')');
        },
        .tuple => |v| {
            try buf.char('{');
            for (v.elements, 0..) |element, i| {
                if (i > 0) try buf.str(", ");
                try appendPattern(buf, element, interner, graph);
            }
            try buf.char('}');
        },
        .list => |v| {
            try buf.char('[');
            for (v.elements, 0..) |element, i| {
                if (i > 0) try buf.str(", ");
                try appendPattern(buf, element, interner, graph);
            }
            try buf.char(']');
        },
        .list_cons => |v| {
            try buf.char('[');
            for (v.heads, 0..) |head, i| {
                if (i > 0) try buf.str(", ");
                try appendPattern(buf, head, interner, graph);
            }
            if (v.heads.len > 0) try buf.str(" | ");
            try appendPattern(buf, v.tail, interner, graph);
            try buf.char(']');
        },
        .map => |v| {
            try buf.str("%{");
            for (v.fields, 0..) |field, i| {
                if (i > 0) try buf.str(", ");
                try appendExpr(buf, field.key, interner, graph);
                try buf.str(" => ");
                try appendPattern(buf, field.value, interner, graph);
            }
            try buf.char('}');
        },
        .struct_pattern => |v| {
            try buf.char('%');
            try appendStructName(buf, v.struct_name, interner);
            try buf.char('{');
            for (v.fields, 0..) |field, i| {
                if (i > 0) try buf.str(", ");
                try buf.str(interner.get(field.name));
                try buf.str(": ");
                try appendPattern(buf, field.pattern, interner, graph);
            }
            try buf.char('}');
        },
        .binary => |v| {
            try buf.str("<<");
            for (v.segments, 0..) |segment, i| {
                if (i > 0) try buf.str(", ");
                switch (segment.value) {
                    .pattern => |segment_pattern| try appendPattern(buf, segment_pattern, interner, graph),
                    .string_literal => |string_id| try appendZapStringLiteral(buf, interner.get(string_id)),
                    .expr => |expr| try appendExpr(buf, expr, interner, graph),
                }
            }
            try buf.str(">>");
        },
        .tagged_union_variant => |v| {
            try appendStructName(buf, v.qualifier, interner);
            if (v.payload) |payload| {
                try buf.char('(');
                try appendPattern(buf, payload, interner, graph);
                try buf.char(')');
            }
        },
    }
}

fn binaryOpString(op: ast.BinaryOp.Op) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem_op => "rem",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .and_op => "and",
        .or_op => "or",
        .concat => "<>",
        .in_op => "in",
        .not_in_op => "not in",
    };
}

pub fn appendExpr(
    buf: *Buffer,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) Allocator.Error!void {
    if (sourceSlice(expr.getMeta(), graph)) |text| {
        try buf.str(text);
        return;
    }
    switch (expr.*) {
        .int_literal => |v| try buf.fmt("{d}", .{v.value}),
        .float_literal => |v| try buf.fmt("{d}", .{v.value}),
        .string_literal => |v| try appendZapStringLiteral(buf, interner.get(v.value)),
        .atom_literal => |v| {
            try buf.char(':');
            try buf.str(interner.get(v.value));
        },
        .bool_literal => |v| try buf.str(if (v.value) "true" else "false"),
        .nil_literal => try buf.str("nil"),
        .var_ref => |v| try buf.str(interner.get(v.name)),
        .struct_ref => |v| try appendStructName(buf, v.name, interner),
        .type_annotated => |v| {
            try appendExpr(buf, v.expr, interner, graph);
            try buf.str(" :: ");
            try appendTypeExpr(buf, v.type_expr, interner);
        },
        .unary_op => |v| {
            try buf.str(switch (v.op) {
                .negate => "-",
                .not_op => "not ",
            });
            try appendExpr(buf, v.operand, interner, graph);
        },
        .binary_op => |v| {
            try appendExpr(buf, v.lhs, interner, graph);
            try buf.char(' ');
            try buf.str(binaryOpString(v.op));
            try buf.char(' ');
            try appendExpr(buf, v.rhs, interner, graph);
        },
        else => try buf.char('?'),
    }
}

test "Buffer append operations propagate allocation failure" {
    var str_failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var str_buffer = Buffer.init(str_failing_allocator.allocator());
    defer str_buffer.deinit();
    try std.testing.expectError(error.OutOfMemory, str_buffer.str("signature"));

    var char_failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var char_buffer = Buffer.init(char_failing_allocator.allocator());
    defer char_buffer.deinit();
    try std.testing.expectError(error.OutOfMemory, char_buffer.char('('));

    var fmt_failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var fmt_buffer = Buffer.init(fmt_failing_allocator.allocator());
    defer fmt_buffer.deinit();
    try std.testing.expectError(error.OutOfMemory, fmt_buffer.fmt("{d}", .{42}));
}

test "union variant signatures propagate allocation failure after partial render" {
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const payload_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("PayloadTypeNameLongEnoughToRequireBufferGrowth"),
        .args = &.{},
    } };
    const variant = ast.UnionVariant{
        .meta = meta,
        .name = try interner.intern("V"),
        .type_expr = &payload_type,
    };

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        buildUnionVariantSignature(failing_allocator.allocator(), variant, &interner),
    );
}

test "protocol function signatures retain named type arguments" {
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const element_type = ast.TypeExpr{ .variable = .{
        .meta = meta,
        .name = try interner.intern("element"),
    } };
    const atom_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("Atom"),
        .args = &.{},
    } };
    const enumerable_args = [_]*const ast.TypeExpr{&element_type};
    const enumerable_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("Enumerable"),
        .args = &enumerable_args,
    } };
    const return_elements = [_]*const ast.TypeExpr{
        &atom_type,
        &element_type,
        &enumerable_type,
    };
    const return_type = ast.TypeExpr{ .tuple = .{
        .meta = meta,
        .elements = &return_elements,
    } };
    const params = [_]ast.ProtocolParam{.{
        .meta = meta,
        .name = try interner.intern("state"),
        .type_annotation = null,
    }};
    const function_sig = ast.ProtocolFunctionSig{
        .meta = meta,
        .name = try interner.intern("next"),
        .params = &params,
        .return_type = &return_type,
    };

    const rendered = try buildProtocolFunctionSignature(allocator, function_sig, &interner);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("next(state) -> {Atom, element, Enumerable(element)}", rendered);
}

test "protocol function signatures render explicit ownership qualifiers" {
    const allocator = std.testing.allocator;
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const element_type = ast.TypeExpr{ .variable = .{
        .meta = meta,
        .name = try interner.intern("element"),
    } };
    const enumerable_args = [_]*const ast.TypeExpr{&element_type};
    const enumerable_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("Enumerable"),
        .args = &enumerable_args,
    } };
    const nil_type = ast.TypeExpr{ .name = .{
        .meta = meta,
        .name = try interner.intern("Nil"),
        .args = &.{},
    } };
    const params = [_]ast.ProtocolParam{.{
        .meta = meta,
        .name = try interner.intern("state"),
        .type_annotation = &enumerable_type,
        .ownership = .unique,
        .ownership_explicit = true,
    }};
    const function_sig = ast.ProtocolFunctionSig{
        .meta = meta,
        .name = try interner.intern("dispose"),
        .params = &params,
        .return_type = &nil_type,
    };

    const rendered = try buildProtocolFunctionSignature(allocator, function_sig, &interner);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("dispose(state :: unique Enumerable(element)) -> Nil", rendered);
}
