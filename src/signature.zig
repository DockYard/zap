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
/// in the compiler for HTML and signature emission. Errors from the
/// underlying allocator are intentionally swallowed — signature
/// rendering must never bring a build down because of an OOM during
/// formatting; partial output is acceptable in that pathological case.
pub const Buffer = struct {
    list: std.ArrayListUnmanaged(u8),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Buffer {
        return .{ .list = .empty, .alloc = alloc };
    }

    pub fn str(self: *Buffer, s: []const u8) void {
        self.list.appendSlice(self.alloc, s) catch {};
    }

    pub fn char(self: *Buffer, c: u8) void {
        self.list.append(self.alloc, c) catch {};
    }

    pub fn fmt(self: *Buffer, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.alloc, f, args) catch return;
        self.list.appendSlice(self.alloc, s) catch {};
    }

    pub fn toSlice(self: *Buffer) []const u8 {
        return self.list.items;
    }
};

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
) []const []const u8 {
    var signatures: std.ArrayListUnmanaged([]const u8) = .empty;
    for (clauses) |clause_ref| {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) continue;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        signatures.append(alloc, buildClauseSignature(alloc, function_name, clause, interner, graph)) catch {};
    }
    if (signatures.items.len == 0) {
        signatures.append(alloc, std.fmt.allocPrint(alloc, "{s}()", .{function_name}) catch function_name) catch {};
    }
    return signatures.toOwnedSlice(alloc) catch &.{};
}

pub fn buildClauseSignature(
    alloc: Allocator,
    function_name: []const u8,
    clause: ast.FunctionClause,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) []const u8 {
    var buf = Buffer.init(alloc);
    buf.str(function_name);
    buf.char('(');
    for (clause.params, 0..) |param, i| {
        if (i > 0) buf.str(", ");
        appendPattern(&buf, param.pattern, interner, graph);
        if (param.type_annotation) |type_ann| {
            buf.str(" :: ");
            appendTypeExpr(&buf, type_ann, interner);
        }
        if (param.default) |default_expr| {
            buf.str(" = ");
            appendExpr(&buf, default_expr, interner, graph);
        }
    }
    buf.char(')');
    if (clause.return_type) |ret| {
        buf.str(" -> ");
        appendTypeExpr(&buf, ret, interner);
    }
    if (clause.refinement) |refinement| {
        buf.str(" if ");
        appendExpr(&buf, refinement, interner, graph);
    }
    return buf.toSlice();
}

pub fn buildProtocolFunctionSignature(
    alloc: Allocator,
    function_sig: ast.ProtocolFunctionSig,
    interner: *const ast.StringInterner,
) []const u8 {
    var buf = Buffer.init(alloc);
    buf.str(interner.get(function_sig.name));
    buf.char('(');
    for (function_sig.params, 0..) |param, i| {
        if (i > 0) buf.str(", ");
        buf.str(interner.get(param.name));
        if (param.type_annotation) |type_annotation| {
            buf.str(" :: ");
            appendTypeExpr(&buf, type_annotation, interner);
        }
    }
    buf.char(')');
    if (function_sig.return_type) |return_type| {
        buf.str(" -> ");
        appendTypeExpr(&buf, return_type, interner);
    }
    return buf.toSlice();
}

pub fn buildUnionVariantSignature(
    alloc: Allocator,
    variant: ast.UnionVariant,
    interner: *const ast.StringInterner,
) []const u8 {
    var buf = Buffer.init(alloc);
    buf.str(interner.get(variant.name));
    if (variant.type_expr) |type_expr| {
        buf.str(" :: ");
        appendTypeExpr(&buf, type_expr, interner);
    }
    return buf.toSlice();
}

pub fn appendStructName(buf: *Buffer, name: ast.StructName, interner: *const ast.StringInterner) void {
    for (name.parts, 0..) |part, i| {
        if (i > 0) buf.char('.');
        buf.str(interner.get(part));
    }
}

pub fn appendTypeExpr(buf: *Buffer, type_expr: *const ast.TypeExpr, interner: *const ast.StringInterner) void {
    switch (type_expr.*) {
        .name => |n| buf.str(interner.get(n.name)),
        .variable => |v| buf.str(interner.get(v.name)),
        .list => |l| {
            buf.char('[');
            appendTypeExpr(buf, l.element, interner);
            buf.char(']');
        },
        .tuple => |t| {
            buf.char('{');
            for (t.elements, 0..) |elem, i| {
                if (i > 0) buf.str(", ");
                appendTypeExpr(buf, elem, interner);
            }
            buf.char('}');
        },
        .function => |f| {
            buf.char('(');
            for (f.params, 0..) |param, i| {
                if (i > 0) buf.str(", ");
                appendTypeExpr(buf, param, interner);
            }
            buf.str(") -> ");
            appendTypeExpr(buf, f.return_type, interner);
        },
        else => buf.char('?'),
    }
}

fn sourceSlice(meta: ast.NodeMeta, graph: *const scope.ScopeGraph) ?[]const u8 {
    const source_id = meta.span.source_id orelse return null;
    const source = graph.sourceContentById(source_id);
    if (source.len == 0) return null;
    if (meta.span.start >= meta.span.end) return null;
    if (meta.span.end > source.len) return null;
    return std.mem.trim(u8, source[meta.span.start..meta.span.end], " \t\r\n");
}

fn appendZapStringLiteral(buf: *Buffer, value: []const u8) void {
    buf.char('"');
    for (value) |c| {
        switch (c) {
            '\\' => buf.str("\\\\"),
            '"' => buf.str("\\\""),
            '\n' => buf.str("\\n"),
            '\r' => buf.str("\\r"),
            '\t' => buf.str("\\t"),
            else => buf.char(c),
        }
    }
    buf.char('"');
}

fn appendLiteralPattern(buf: *Buffer, literal: ast.LiteralPattern, interner: *const ast.StringInterner) void {
    switch (literal) {
        .int => |v| buf.fmt("{d}", .{v.value}),
        .float => |v| buf.fmt("{d}", .{v.value}),
        .string => |v| appendZapStringLiteral(buf, interner.get(v.value)),
        .atom => |v| {
            buf.char(':');
            buf.str(interner.get(v.value));
        },
        .bool_lit => |v| buf.str(if (v.value) "true" else "false"),
        .nil => buf.str("nil"),
    }
}

pub fn appendPattern(
    buf: *Buffer,
    pattern: *const ast.Pattern,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) void {
    if (sourceSlice(pattern.getMeta(), graph)) |text| {
        buf.str(text);
        return;
    }
    switch (pattern.*) {
        .wildcard => buf.char('_'),
        .bind => |v| buf.str(interner.get(v.name)),
        .pin => |v| {
            buf.char('^');
            buf.str(interner.get(v.name));
        },
        .literal => |literal| appendLiteralPattern(buf, literal, interner),
        .paren => |v| {
            buf.char('(');
            appendPattern(buf, v.inner, interner, graph);
            buf.char(')');
        },
        .tuple => |v| {
            buf.char('{');
            for (v.elements, 0..) |element, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, element, interner, graph);
            }
            buf.char('}');
        },
        .list => |v| {
            buf.char('[');
            for (v.elements, 0..) |element, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, element, interner, graph);
            }
            buf.char(']');
        },
        .list_cons => |v| {
            buf.char('[');
            for (v.heads, 0..) |head, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, head, interner, graph);
            }
            if (v.heads.len > 0) buf.str(" | ");
            appendPattern(buf, v.tail, interner, graph);
            buf.char(']');
        },
        .map => |v| {
            buf.str("%{");
            for (v.fields, 0..) |field, i| {
                if (i > 0) buf.str(", ");
                appendExpr(buf, field.key, interner, graph);
                buf.str(" => ");
                appendPattern(buf, field.value, interner, graph);
            }
            buf.char('}');
        },
        .struct_pattern => |v| {
            buf.char('%');
            appendStructName(buf, v.struct_name, interner);
            buf.char('{');
            for (v.fields, 0..) |field, i| {
                if (i > 0) buf.str(", ");
                buf.str(interner.get(field.name));
                buf.str(": ");
                appendPattern(buf, field.pattern, interner, graph);
            }
            buf.char('}');
        },
        .binary => |v| {
            buf.str("<<");
            for (v.segments, 0..) |segment, i| {
                if (i > 0) buf.str(", ");
                switch (segment.value) {
                    .pattern => |segment_pattern| appendPattern(buf, segment_pattern, interner, graph),
                    .string_literal => |string_id| appendZapStringLiteral(buf, interner.get(string_id)),
                    .expr => |expr| appendExpr(buf, expr, interner, graph),
                }
            }
            buf.str(">>");
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
    };
}

pub fn appendExpr(
    buf: *Buffer,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    graph: *const scope.ScopeGraph,
) void {
    if (sourceSlice(expr.getMeta(), graph)) |text| {
        buf.str(text);
        return;
    }
    switch (expr.*) {
        .int_literal => |v| buf.fmt("{d}", .{v.value}),
        .float_literal => |v| buf.fmt("{d}", .{v.value}),
        .string_literal => |v| appendZapStringLiteral(buf, interner.get(v.value)),
        .atom_literal => |v| {
            buf.char(':');
            buf.str(interner.get(v.value));
        },
        .bool_literal => |v| buf.str(if (v.value) "true" else "false"),
        .nil_literal => buf.str("nil"),
        .var_ref => |v| buf.str(interner.get(v.name)),
        .struct_ref => |v| appendStructName(buf, v.name, interner),
        .type_annotated => |v| {
            appendExpr(buf, v.expr, interner, graph);
            buf.str(" :: ");
            appendTypeExpr(buf, v.type_expr, interner);
        },
        .unary_op => |v| {
            buf.str(switch (v.op) {
                .negate => "-",
                .not_op => "not ",
            });
            appendExpr(buf, v.operand, interner, graph);
        },
        .binary_op => |v| {
            appendExpr(buf, v.lhs, interner, graph);
            buf.char(' ');
            buf.str(binaryOpString(v.op));
            buf.char(' ');
            appendExpr(buf, v.rhs, interner, graph);
        },
        else => buf.char('?'),
    }
}
