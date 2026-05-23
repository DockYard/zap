//! Phase 1.4 / 1.5 warn-only lints.
//!
//! Three advisory lints that nudge code toward the structured error
//! system without breaking anything (every diagnostic is `.warning`
//! severity):
//!
//!   1. `raise "string-literal"` on a `pub fn` API surface — suggests a
//!      named `pub error` instead of the ad-hoc `RuntimeError` shorthand.
//!   2. Bare `{:ok, _}` / `{:error, _}` tuple PATTERNS in any function
//!      body — suggests migrating the producing code to `Result(t, e)`
//!      (and `Result.tuple_to_result/1` as the bridge).
//!   3. (Phase 1.5) A `pub error` declaration on the public API surface
//!      that omits `@code Zxxxx` — suggests assigning a stable numeric
//!      code, since codes are part of the public diagnostic surface and
//!      back `zap explain`. Private (`error`, non-`pub`) declarations are
//!      not flagged: they never reach a public boundary.
//!
//! The pass runs per source unit on the freshly parsed AST (BEFORE
//! desugar, so `raise "literal"` still carries its `raise_expr` + string
//! literal, `{:ok, _}` patterns are intact, and `error_decl` items still
//! carry their `code: ?StringId`). The compiler skips stdlib units so the
//! stdlib's own legacy idioms are not flagged — and stdlib `pub error`
//! types are seeded with `@code`s directly anyway.

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

pub const MISSING_CODE_PUB_ERROR_MESSAGE =
    "`pub error` on a public API surface without an `@code Zxxxx` — assign a " ++
    "stable numeric code (`@code Z3001` above the declaration) so callers and " ++
    "`zap explain` can reference it; codes are public diagnostic API";

pub const MISSING_RAISES_ROW_MESSAGE =
    "`pub fn` body can `raise`/propagate an error but the signature omits a " ++
    "`raises` row — annotate the function (`-> T raises E`) so callers see the " ++
    "effect on the public API surface (Phase 3.b: the `raises` row is a nominal " ++
    "effect; explicit rows make cross-function propagation auditable)";

/// Phase 3.b — mandatory-`raises` lint. Walks the public functions of a
/// (stdlib) program and warns, warn-only, when a `pub fn` clause's body can
/// `raise` (a `raise` expression) or propagate (`?`) an error but the clause
/// carries no explicit `raises` row. The point is to make the nominal
/// `raises` effect part of the audited public-API surface: a function that
/// participates in the abortive effect should advertise it.
///
/// Runs on the freshly-parsed AST (BEFORE desugar), so `raise <value>` is
/// still a `raise_expr` and `value?` a `try_expr`. Unlike the Phase 1.4
/// lints (which SKIP stdlib units), this is intended to run OVER `lib/*` to
/// confirm the stdlib is consistent under mandatory annotation. Warn-only:
/// it never blocks a build.
pub fn runMandatoryRaisesLint(
    program: *const ast.Program,
    interner: *const ast.StringInterner,
    engine: *diagnostics.DiagnosticEngine,
) !void {
    var linter = RaisesLinter{ .interner = interner, .engine = engine };
    for (program.structs) |struct_decl| {
        try linter.lintStructItems(struct_decl.items);
    }
    for (program.top_items) |top_item| {
        switch (top_item) {
            .struct_decl, .priv_struct_decl => |sd| try linter.lintStructItems(sd.items),
            .function => |func| try linter.lintPublicFunction(func),
            else => {},
        }
    }
}

/// Walks a function/struct tree flagging public functions whose body raises
/// or propagates without an explicit `raises` row.
const RaisesLinter = struct {
    interner: *const ast.StringInterner,
    engine: *diagnostics.DiagnosticEngine,

    fn lintStructItems(self: *RaisesLinter, items: []const ast.StructItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                // Only PUBLIC functions are part of the audited API surface.
                .function => |func| try self.lintPublicFunction(func),
                .struct_decl => |nested| try self.lintStructItems(nested.items),
                else => {},
            }
        }
    }

    fn lintPublicFunction(self: *RaisesLinter, func: *const ast.FunctionDecl) anyerror!void {
        for (func.clauses) |clause| {
            // An explicit row (even `raises ()`) discharges the lint —
            // the author has declared the effect surface.
            if (clause.raises != null) continue;
            // A bodyless declaration (protocol signature / forward decl)
            // has no raise sites to infer from.
            const body = clause.body orelse continue;
            if (blockCanRaise(body)) {
                try self.engine.warn(MISSING_RAISES_ROW_MESSAGE, clause.meta.span);
                // One warning per clause is enough.
            }
        }
    }
};

/// True when a statement list lexically contains a `raise` expression or a
/// `?` propagation (`try_expr`) — a conservative, syntactic over-approximation
/// of "this body participates in the abortive effect". Cross-function
/// propagation through plain calls is intentionally NOT counted here (the
/// lint is syntactic and pre-type-check); the type checker's `raises`
/// inference is the authoritative cross-function analysis.
fn blockCanRaise(stmts: []const ast.Stmt) bool {
    for (stmts) |stmt| {
        if (stmtCanRaise(stmt)) return true;
    }
    return false;
}

fn stmtCanRaise(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .expr => |e| exprCanRaise(e),
        .assignment => |a| exprCanRaise(a.value),
        else => false,
    };
}

fn exprCanRaise(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        // The two surface effect operators.
        .raise_expr => true,
        .try_expr => true,
        // Recurse into the common compound shapes a raising expression
        // can hide inside. A `try`/`rescue` is NOT a raise site here: it
        // DISCHARGES the body's effect (an unrescued type still surfaces
        // through the type checker's row, not this syntactic lint).
        .block => |b| blockCanRaise(b.stmts),
        .call => |c| {
            for (c.args) |arg| if (exprCanRaise(arg)) return true;
            return false;
        },
        .binary_op => |b| exprCanRaise(b.lhs) or exprCanRaise(b.rhs),
        .case_expr => |ce| {
            for (ce.clauses) |clause| {
                if (clause.body.len > 0 and blockCanRaise(clause.body)) return true;
            }
            return false;
        },
        .if_expr => |ie| (ie.then_block.len > 0 and blockCanRaise(ie.then_block)) or
            (if (ie.else_block) |eb| blockCanRaise(eb) else false),
        else => false,
    };
}

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
    for (program.top_items, 0..) |top_item, index| {
        switch (top_item) {
            .struct_decl, .priv_struct_decl => |sd| try linter.lintStructItems(sd.items),
            // Lint 3 (Phase 1.5): a `pub error` reaching the public API
            // surface without `@code`. `.error_decl` is the public form
            // (`pub error`); `.priv_error_decl` (`error`, non-`pub`) is
            // exempt because it never crosses a public boundary.
            //
            // The parser leaves `ErrorDecl.code` null and emits the
            // `@code Zxxxx` value as a separate preceding top-level
            // `attribute` item (the desugar folds it into the generated
            // `code/1` later). So at lint time we detect the code by
            // scanning the immediately-preceding contiguous attribute
            // items for one named `code` — mirroring the desugar's
            // `takePendingCodeAttribute`.
            .error_decl => |ed| if (!precedingCodeAttribute(linter.interner, program.top_items, index) and ed.code == null) {
                try linter.engine.warn(MISSING_CODE_PUB_ERROR_MESSAGE, ed.meta.span);
            },
            else => {},
        }
    }
}

/// True when the top item at `decl_index` is immediately preceded by a
/// `@code` attribute item (separated only by other attribute items such
/// as `@doc`). Mirrors `Desugarer.takePendingCodeAttribute` so the lint's
/// notion of "has a code" matches what the desugar will actually consume.
fn precedingCodeAttribute(
    interner: *const ast.StringInterner,
    top_items: []const ast.TopItem,
    decl_index: usize,
) bool {
    if (decl_index == 0) return false;
    var i: isize = @as(isize, @intCast(decl_index)) - 1;
    while (i >= 0) : (i -= 1) {
        const item = top_items[@intCast(i)];
        if (item != .attribute) return false;
        if (std.mem.eql(u8, interner.get(item.attribute.name), "code")) return true;
    }
    return false;
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
            .try_rescue => |tr| {
                try self.lintBlock(tr.body, is_public);
                for (tr.rescue_clauses) |clause| {
                    try self.lintBlock(clause.body, is_public);
                }
                if (tr.after_block) |cleanup| {
                    try self.lintBlock(cleanup, is_public);
                }
            },
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

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

test "missing-@code lint warns on pub error without @code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub error UncodedError {}
    ;
    var parser = Parser.init(alloc, source);
    const program = try parser.parseProgram();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, parser.interner, &engine);
    try std.testing.expectEqual(@as(usize, 1), engine.warningCount());
}

test "missing-@code lint is silent when @code is present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\@code Z3001
        \\pub error CodedError {}
    ;
    var parser = Parser.init(alloc, source);
    const program = try parser.parseProgram();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, parser.interner, &engine);
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}

test "missing-@code lint exempts private error declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\error PrivateError {}
    ;
    var parser = Parser.init(alloc, source);
    const program = try parser.parseProgram();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, parser.interner, &engine);
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}
