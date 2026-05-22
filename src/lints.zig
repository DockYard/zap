//! Phase 1.4 warn-only lints.
//!
//! Two advisory lints that nudge code toward the structured error system
//! without breaking anything (every diagnostic is `.warning` severity):
//!
//!   1. `raise "string-literal"` on a `pub fn` API surface — suggests a
//!      named `pub error` instead of the ad-hoc `RuntimeError` shorthand.
//!   2. Bare `{:ok, _}` / `{:error, _}` tuple PATTERNS in any function
//!      body — suggests migrating the producing code to `Result(t, e)`
//!      (and `Result.tuple_to_result/1` as the bridge).
//!
//! The pass runs per source unit on the freshly parsed AST (BEFORE
//! desugar, so `raise "literal"` still carries its `raise_expr` + string
//! literal and `{:ok, _}` patterns are intact). The compiler skips stdlib
//! units so the stdlib's own legacy idioms are not flagged.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const RAISE_STRING_PUB_API_MESSAGE =
    "`raise \"string\"` on a `pub` API surface — prefer a named `pub error` " ++
    "so callers can match on the error type (this raises a `RuntimeError`)";

pub const BARE_OK_TUPLE_MESSAGE =
    "bare `{:ok, _}` tuple pattern — consider migrating to `Result(t, e)` " ++
    "(`Result.tuple_to_result/1` bridges legacy tuples)";

pub const BARE_ERROR_TUPLE_MESSAGE =
    "bare `{:error, _}` tuple pattern — consider migrating to `Result(t, e)` " ++
    "(`Result.tuple_to_result/1` bridges legacy tuples)";

/// Run the Phase 1.4 advisory lints over one parsed program, emitting
/// warn-only diagnostics into `engine`. `program` is a single source
/// unit's AST (the caller filters out stdlib units).
pub fn runPhase14Lints(
    program: *const ast.Program,
    interner: *const ast.StringInterner,
    engine: *diagnostics.DiagnosticEngine,
) !void {
    var linter = Linter{ .interner = interner, .engine = engine };
    for (program.structs) |struct_decl| {
        try linter.lintStructItems(struct_decl.items);
    }
    for (program.top_items) |top_item| {
        switch (top_item) {
            .struct_decl, .priv_struct_decl => |sd| try linter.lintStructItems(sd.items),
            else => {},
        }
    }
}

const Linter = struct {
    interner: *const ast.StringInterner,
    engine: *diagnostics.DiagnosticEngine,

    fn lintStructItems(self: *Linter, items: []const ast.StructItem) !void {
        for (items) |item| {
            switch (item) {
                .function => |func| try self.lintFunction(func, true),
                .priv_function => |func| try self.lintFunction(func, false),
                .struct_decl, .union_decl => {},
                // Nested structs are reached through the top-level walk; a
                // struct item that nests another struct re-enters via its
                // own `items` here.
                else => {},
            }
            switch (item) {
                .struct_decl => |nested| try self.lintStructItems(nested.items),
                else => {},
            }
        }
    }

    fn lintFunction(self: *Linter, func: *const ast.FunctionDecl, is_public: bool) !void {
        for (func.clauses) |clause| {
            if (clause.body) |body| {
                try self.lintBlock(body, is_public);
            }
        }
    }

    fn lintBlock(self: *Linter, stmts: []const ast.Stmt, is_public: bool) anyerror!void {
        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.lintExpr(expr, is_public),
                .assignment => |assign| {
                    try self.lintPattern(assign.pattern);
                    try self.lintExpr(assign.value, is_public);
                },
                else => {},
            }
        }
    }

    fn lintExpr(self: *Linter, expr: *const ast.Expr, is_public: bool) anyerror!void {
        switch (expr.*) {
            .raise_expr => |re| {
                // Lint 1: `raise "literal"` on a public API surface.
                if (is_public and isStringLiteral(re.value)) {
                    try self.engine.warn(RAISE_STRING_PUB_API_MESSAGE, re.meta.span);
                }
                try self.lintExpr(re.value, is_public);
            },
            .case_expr => |ce| {
                try self.lintExpr(ce.scrutinee, is_public);
                for (ce.clauses) |clause| {
                    try self.lintPattern(clause.pattern);
                    try self.lintBlock(clause.body, is_public);
                }
            },
            .if_expr => |ie| {
                try self.lintExpr(ie.condition, is_public);
                try self.lintBlock(ie.then_block, is_public);
                if (ie.else_block) |eb| try self.lintBlock(eb, is_public);
            },
            .cond_expr => |ce| {
                for (ce.clauses) |clause| {
                    try self.lintExpr(clause.condition, is_public);
                    try self.lintBlock(clause.body, is_public);
                }
            },
            .block => |b| try self.lintBlock(b.stmts, is_public),
            .call => |c| {
                try self.lintExpr(c.callee, is_public);
                for (c.args) |arg| try self.lintExpr(arg, is_public);
            },
            .binary_op => |bo| {
                try self.lintExpr(bo.lhs, is_public);
                try self.lintExpr(bo.rhs, is_public);
            },
            .unary_op => |uo| try self.lintExpr(uo.operand, is_public),
            .pipe => |p| {
                try self.lintExpr(p.lhs, is_public);
                try self.lintExpr(p.rhs, is_public);
            },
            .field_access => |fa| try self.lintExpr(fa.object, is_public),
            .type_annotated => |ta| try self.lintExpr(ta.expr, is_public),
            .panic_expr => |pe| try self.lintExpr(pe.message, is_public),
            .try_expr => |te| try self.lintExpr(te.value, is_public),
            .tuple => |t| for (t.elements) |elem| try self.lintExpr(elem, is_public),
            .list => |l| for (l.elements) |elem| try self.lintExpr(elem, is_public),
            else => {},
        }
    }

    fn lintPattern(self: *Linter, pattern: *const ast.Pattern) anyerror!void {
        switch (pattern.*) {
            .tuple => |tp| {
                // Lint 2: bare `{:ok, _}` / `{:error, _}` tuple patterns.
                if (tp.elements.len >= 1 and tp.elements[0].* == .literal) {
                    const lit = tp.elements[0].*.literal;
                    if (lit == .atom) {
                        const atom_text = self.interner.get(lit.atom.value);
                        if (std.mem.eql(u8, atom_text, "ok")) {
                            try self.engine.warn(BARE_OK_TUPLE_MESSAGE, tp.meta.span);
                        } else if (std.mem.eql(u8, atom_text, "error")) {
                            try self.engine.warn(BARE_ERROR_TUPLE_MESSAGE, tp.meta.span);
                        }
                    }
                }
                for (tp.elements) |elem| try self.lintPattern(elem);
            },
            .list => |lp| for (lp.elements) |elem| try self.lintPattern(elem),
            .list_cons => |lc| {
                for (lc.heads) |h| try self.lintPattern(h);
                try self.lintPattern(lc.tail);
            },
            .paren => |pp| try self.lintPattern(pp.inner),
            else => {},
        }
    }
};

fn isStringLiteral(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .string_literal, .string_interpolation => true,
        else => false,
    };
}
