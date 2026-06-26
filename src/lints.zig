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

const MAX_LINT_EXPR_DEPTH: u32 = 2048;

const StructItemFrame = struct {
    items: []const ast.StructItem,
    next_item: usize = 0,
};

const INLINE_STRUCT_ITEM_FRAME_CAPACITY: usize = 64;

const StructItemFrameStack = struct {
    allocator: std.mem.Allocator,
    inline_frames: [INLINE_STRUCT_ITEM_FRAME_CAPACITY]StructItemFrame = undefined,
    inline_len: usize = 0,
    heap_frames: std.ArrayListUnmanaged(StructItemFrame) = .empty,

    fn init(allocator: std.mem.Allocator) StructItemFrameStack {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StructItemFrameStack) void {
        self.heap_frames.deinit(self.allocator);
    }

    fn isEmpty(self: *const StructItemFrameStack) bool {
        return self.inline_len == 0 and self.heap_frames.items.len == 0;
    }

    fn push(self: *StructItemFrameStack, frame: StructItemFrame) !void {
        if (self.heap_frames.items.len == 0 and self.inline_len < INLINE_STRUCT_ITEM_FRAME_CAPACITY) {
            self.inline_frames[self.inline_len] = frame;
            self.inline_len += 1;
            return;
        }

        if (self.heap_frames.items.len == 0) {
            try self.spillInlineFrames();
        }
        try self.heap_frames.append(self.allocator, frame);
    }

    fn top(self: *StructItemFrameStack) *StructItemFrame {
        if (self.heap_frames.items.len > 0) {
            return &self.heap_frames.items[self.heap_frames.items.len - 1];
        }
        std.debug.assert(self.inline_len > 0);
        return &self.inline_frames[self.inline_len - 1];
    }

    fn pop(self: *StructItemFrameStack) void {
        if (self.heap_frames.items.len > 0) {
            _ = self.heap_frames.pop();
            return;
        }
        std.debug.assert(self.inline_len > 0);
        self.inline_len -= 1;
    }

    fn spillInlineFrames(self: *StructItemFrameStack) !void {
        try self.heap_frames.ensureTotalCapacity(self.allocator, self.inline_len + 1);
        for (self.inline_frames[0..self.inline_len]) |frame| {
            self.heap_frames.appendAssumeCapacity(frame);
        }
        self.inline_len = 0;
    }
};

const RaisesScanError = std.mem.Allocator.Error || error{
    LintAstWalkDepthExceeded,
};

const RaisesScanFrame = union(enum) {
    expr: ExprFrame,
    stmt: StmtFrame,
    stmts: StmtListFrame,
    case_clause: CaseClauseFrame,
    case_clauses: CaseClauseListFrame,

    const ExprFrame = struct {
        expr: *const ast.Expr,
        depth: u32,
    };

    const StmtFrame = struct {
        stmt: ast.Stmt,
        depth: u32,
    };

    const StmtListFrame = struct {
        stmts: []const ast.Stmt,
        depth: u32,
    };

    const CaseClauseFrame = struct {
        clause: ast.CaseClause,
        depth: u32,
    };

    const CaseClauseListFrame = struct {
        clauses: []const ast.CaseClause,
        depth: u32,
    };
};

const INLINE_RAISES_SCAN_FRAME_CAPACITY: usize = 64;

const RaisesScanFrameStack = struct {
    allocator: std.mem.Allocator,
    inline_frames: [INLINE_RAISES_SCAN_FRAME_CAPACITY]RaisesScanFrame = undefined,
    inline_len: usize = 0,
    heap_frames: std.ArrayListUnmanaged(RaisesScanFrame) = .empty,

    fn init(allocator: std.mem.Allocator) RaisesScanFrameStack {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RaisesScanFrameStack) void {
        self.heap_frames.deinit(self.allocator);
    }

    fn isEmpty(self: *const RaisesScanFrameStack) bool {
        return self.inline_len == 0 and self.heap_frames.items.len == 0;
    }

    fn push(self: *RaisesScanFrameStack, frame: RaisesScanFrame) std.mem.Allocator.Error!void {
        if (self.heap_frames.items.len == 0 and self.inline_len < INLINE_RAISES_SCAN_FRAME_CAPACITY) {
            self.inline_frames[self.inline_len] = frame;
            self.inline_len += 1;
            return;
        }

        if (self.heap_frames.items.len == 0) {
            try self.spillInlineFrames();
        }
        try self.heap_frames.append(self.allocator, frame);
    }

    fn pop(self: *RaisesScanFrameStack) RaisesScanFrame {
        if (self.heap_frames.items.len > 0) {
            return self.heap_frames.pop().?;
        }
        std.debug.assert(self.inline_len > 0);
        self.inline_len -= 1;
        return self.inline_frames[self.inline_len];
    }

    fn spillInlineFrames(self: *RaisesScanFrameStack) std.mem.Allocator.Error!void {
        try self.heap_frames.ensureTotalCapacity(self.allocator, self.inline_len + 1);
        for (self.inline_frames[0..self.inline_len]) |frame| {
            self.heap_frames.appendAssumeCapacity(frame);
        }
        self.inline_len = 0;
    }
};

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
/// still a `raise_expr`. Unlike the Phase 1.4
/// lints (which SKIP stdlib units), this is intended to run OVER `lib/*` to
/// confirm the stdlib is consistent under mandatory annotation. The lint
/// finding is warn-only; traversal/allocation failures are returned to the
/// caller so the compiler can report budget exhaustion or OOM instead of
/// guessing.
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
        var frames = StructItemFrameStack.init(self.engine.allocator);
        defer frames.deinit();

        try frames.push(.{ .items = items });
        while (!frames.isEmpty()) {
            var frame = frames.top();
            if (frame.next_item >= frame.items.len) {
                frames.pop();
                continue;
            }

            const item = frame.items[frame.next_item];
            frame.next_item += 1;

            switch (item) {
                // Only PUBLIC functions are part of the audited API surface.
                .function => |func| try self.lintPublicFunction(func),
                .struct_decl => |nested| try frames.push(.{ .items = nested.items }),
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
            if (try blockCanRaise(self.engine.allocator, body)) {
                try self.engine.warn(MISSING_RAISES_ROW_MESSAGE, clause.meta.span);
                // One warning per clause is enough.
            }
        }
    }
};

/// True when a statement list lexically contains a `raise` expression —
/// a conservative, syntactic over-approximation of "this body participates
/// in the abortive effect". Cross-function propagation through plain calls
/// is intentionally NOT counted here (the lint is syntactic and
/// pre-type-check); the type checker's `raises` inference is the
/// authoritative cross-function analysis.
fn blockCanRaise(allocator: std.mem.Allocator, stmts: []const ast.Stmt) RaisesScanError!bool {
    var scanner = RaisesScanner.init(allocator);
    defer scanner.deinit();
    return scanner.blockCanRaise(stmts);
}

fn exprCanRaise(allocator: std.mem.Allocator, expr: *const ast.Expr) RaisesScanError!bool {
    var scanner = RaisesScanner.init(allocator);
    defer scanner.deinit();
    return scanner.exprCanRaise(expr);
}

const RaisesScanner = struct {
    frames: RaisesScanFrameStack,

    fn init(allocator: std.mem.Allocator) RaisesScanner {
        return .{ .frames = RaisesScanFrameStack.init(allocator) };
    }

    fn deinit(self: *RaisesScanner) void {
        self.frames.deinit();
    }

    fn blockCanRaise(self: *RaisesScanner, stmts: []const ast.Stmt) RaisesScanError!bool {
        try self.pushStmts(stmts, 0);
        return self.run();
    }

    fn exprCanRaise(self: *RaisesScanner, expr: *const ast.Expr) RaisesScanError!bool {
        try self.pushExpr(expr, 0);
        return self.run();
    }

    fn run(self: *RaisesScanner) RaisesScanError!bool {
        while (!self.frames.isEmpty()) {
            switch (self.frames.pop()) {
                .expr => |frame| {
                    try checkExprDepth(frame.depth);
                    if (try self.visitExpr(frame.expr, frame.depth)) return true;
                },
                .stmt => |frame| try self.visitStmt(frame.stmt, frame.depth),
                .stmts => |frame| try self.pushStmtList(frame.stmts, frame.depth),
                .case_clause => |frame| try self.visitCaseClause(frame.clause, frame.depth),
                .case_clauses => |frame| try self.pushCaseClauseList(frame.clauses, frame.depth),
            }
        }
        return false;
    }

    fn checkExprDepth(depth: u32) RaisesScanError!void {
        if (depth >= MAX_LINT_EXPR_DEPTH) return error.LintAstWalkDepthExceeded;
    }

    fn childDepth(depth: u32) RaisesScanError!u32 {
        try checkExprDepth(depth);
        return depth + 1;
    }

    fn visitStmt(self: *RaisesScanner, stmt: ast.Stmt, depth: u32) RaisesScanError!void {
        switch (stmt) {
            .expr => |expr| try self.pushExpr(expr, depth),
            .assignment => |assignment| try self.pushExpr(assignment.value, depth),
            else => {},
        }
    }

    fn visitCaseClause(self: *RaisesScanner, clause: ast.CaseClause, depth: u32) RaisesScanError!void {
        try self.pushStmts(clause.body, depth);
        if (clause.guard) |guard| {
            try self.pushExpr(guard, depth);
        }
    }

    fn visitExpr(self: *RaisesScanner, expr: *const ast.Expr, depth: u32) RaisesScanError!bool {
        const next_depth = try childDepth(depth);
        switch (expr.*) {
            // The surface raise site.
            .raise_expr => return true,
            // Recurse into compound shapes that evaluate child expressions or
            // statement bodies. A `try` body is intentionally NOT counted here:
            // `try`/`rescue` discharges covered body effects, and uncovered
            // body effects remain the type checker's row-level responsibility.
            .block => |block| try self.pushStmts(block.stmts, next_depth),
            .call => |call| {
                try self.pushExprList(call.args, next_depth);
                try self.pushExpr(call.callee, next_depth);
            },
            .binary_op => |binary| {
                try self.pushExpr(binary.rhs, next_depth);
                try self.pushExpr(binary.lhs, next_depth);
            },
            .unary_op => |unary| try self.pushExpr(unary.operand, next_depth),
            .pipe => |pipe| {
                try self.pushExpr(pipe.rhs, next_depth);
                try self.pushExpr(pipe.lhs, next_depth);
            },
            .unwrap => |unwrap| try self.pushExpr(unwrap.expr, next_depth),
            .field_access => |field_access| try self.pushExpr(field_access.object, next_depth),
            .type_annotated => |type_annotated| try self.pushExpr(type_annotated.expr, next_depth),
            .panic_expr => |panic_expr| try self.pushExpr(panic_expr.message, next_depth),
            .tuple => |tuple| try self.pushExprList(tuple.elements, next_depth),
            .list => |list| try self.pushExprList(list.elements, next_depth),
            .map => |map| {
                for (0..map.fields.len) |index| {
                    const field = map.fields[map.fields.len - 1 - index];
                    try self.pushExpr(field.value, next_depth);
                    try self.pushExpr(field.key, next_depth);
                }
                if (map.update_source) |source| {
                    try self.pushExpr(source, next_depth);
                }
            },
            .struct_expr => |struct_expr| {
                for (0..struct_expr.fields.len) |index| {
                    const field = struct_expr.fields[struct_expr.fields.len - 1 - index];
                    try self.pushExpr(field.value, next_depth);
                }
                if (struct_expr.update_source) |source| {
                    try self.pushExpr(source, next_depth);
                }
            },
            .range => |range| {
                if (range.step) |step| {
                    try self.pushExpr(step, next_depth);
                }
                try self.pushExpr(range.end, next_depth);
                try self.pushExpr(range.start, next_depth);
            },
            .list_cons_expr => |list_cons| {
                try self.pushExpr(list_cons.tail, next_depth);
                try self.pushExpr(list_cons.head, next_depth);
            },
            .case_expr => |case_expr| {
                try self.pushCaseClauses(case_expr.clauses, next_depth);
                try self.pushExpr(case_expr.scrutinee, next_depth);
            },
            .if_expr => |if_expr| {
                if (if_expr.else_block) |else_block| {
                    try self.pushStmts(else_block, next_depth);
                }
                try self.pushStmts(if_expr.then_block, next_depth);
                try self.pushExpr(if_expr.condition, next_depth);
            },
            .cond_expr => |cond_expr| {
                for (0..cond_expr.clauses.len) |index| {
                    const clause = cond_expr.clauses[cond_expr.clauses.len - 1 - index];
                    try self.pushStmts(clause.body, next_depth);
                    try self.pushExpr(clause.condition, next_depth);
                }
            },
            .for_expr => |for_expr| {
                try self.pushExpr(for_expr.body, next_depth);
                if (for_expr.filter) |filter| {
                    try self.pushExpr(filter, next_depth);
                }
                try self.pushExpr(for_expr.iterable, next_depth);
            },
            .with_expr => |with_expr| {
                if (with_expr.else_clauses) |clauses| {
                    try self.pushCaseClauses(clauses, next_depth);
                }
                try self.pushStmts(with_expr.do_body, next_depth);
                for (0..with_expr.steps.len) |index| {
                    const step = with_expr.steps[with_expr.steps.len - 1 - index];
                    try self.pushExpr(step.expr, next_depth);
                }
            },
            .error_pipe => |error_pipe| {
                switch (error_pipe.handler) {
                    .block => |clauses| try self.pushCaseClauses(clauses, next_depth),
                    .function => |function| try self.pushExpr(function, next_depth),
                }
                try self.pushExpr(error_pipe.chain, next_depth);
            },
            .try_rescue => |try_rescue| {
                if (try_rescue.after_block) |after_block| {
                    try self.pushStmts(after_block, next_depth);
                }
                try self.pushCaseClauses(try_rescue.rescue_clauses, next_depth);
            },
            .string_interpolation => |string_interpolation| {
                for (0..string_interpolation.parts.len) |index| {
                    const part = string_interpolation.parts[string_interpolation.parts.len - 1 - index];
                    switch (part) {
                        .expr => |part_expr| try self.pushExpr(part_expr, next_depth),
                        .literal => {},
                    }
                }
            },
            .unquote_expr => |unquote| try self.pushExpr(unquote.expr, next_depth),
            .unquote_splicing_expr => |unquote_splicing| try self.pushExpr(unquote_splicing.expr, next_depth),
            .intrinsic => |intrinsic| try self.pushExprList(intrinsic.args, next_depth),
            .binary_literal => |binary_literal| {
                for (0..binary_literal.segments.len) |index| {
                    const segment = binary_literal.segments[binary_literal.segments.len - 1 - index];
                    switch (segment.value) {
                        .expr => |segment_expr| try self.pushExpr(segment_expr, next_depth),
                        .pattern, .string_literal => {},
                    }
                }
            },
            else => {},
        }
        return false;
    }

    fn pushExpr(self: *RaisesScanner, expr: *const ast.Expr, depth: u32) std.mem.Allocator.Error!void {
        try self.frames.push(.{ .expr = .{ .expr = expr, .depth = depth } });
    }

    fn pushStmts(self: *RaisesScanner, stmts: []const ast.Stmt, depth: u32) std.mem.Allocator.Error!void {
        try self.frames.push(.{ .stmts = .{ .stmts = stmts, .depth = depth } });
    }

    fn pushCaseClauses(self: *RaisesScanner, clauses: []const ast.CaseClause, depth: u32) std.mem.Allocator.Error!void {
        try self.frames.push(.{ .case_clauses = .{ .clauses = clauses, .depth = depth } });
    }

    fn pushExprList(self: *RaisesScanner, exprs: []const *const ast.Expr, depth: u32) std.mem.Allocator.Error!void {
        for (0..exprs.len) |index| {
            try self.pushExpr(exprs[exprs.len - 1 - index], depth);
        }
    }

    fn pushStmtList(self: *RaisesScanner, stmts: []const ast.Stmt, depth: u32) std.mem.Allocator.Error!void {
        for (0..stmts.len) |index| {
            const stmt = stmts[stmts.len - 1 - index];
            try self.frames.push(.{ .stmt = .{ .stmt = stmt, .depth = depth } });
        }
    }

    fn pushCaseClauseList(self: *RaisesScanner, clauses: []const ast.CaseClause, depth: u32) std.mem.Allocator.Error!void {
        for (0..clauses.len) |index| {
            const clause = clauses[clauses.len - 1 - index];
            try self.frames.push(.{ .case_clause = .{ .clause = clause, .depth = depth } });
        }
    }
};

/// Run the Phase 1.4 advisory lints over one parsed program, emitting
/// warn-only lint findings into `engine`. Traversal/allocation failures are
/// returned to the caller. `program` is a single source unit's AST (the caller
/// filters out stdlib units).
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
    expr_depth: u32 = 0,
    pattern_depth: u32 = 0,

    fn lintStructItems(self: *Linter, items: []const ast.StructItem) !void {
        var frames = StructItemFrameStack.init(self.engine.allocator);
        defer frames.deinit();

        try frames.push(.{ .items = items });
        while (!frames.isEmpty()) {
            var frame = frames.top();
            if (frame.next_item >= frame.items.len) {
                frames.pop();
                continue;
            }

            const item = frame.items[frame.next_item];
            frame.next_item += 1;

            switch (item) {
                .function => |func| try self.lintFunction(func, true),
                .priv_function => |func| try self.lintFunction(func, false),
                .struct_decl, .union_decl => {},
                // Nested structs are scheduled after their declaration item
                // is visited, preserving the old depth-first traversal order.
                else => {},
            }
            switch (item) {
                .struct_decl => |nested| try frames.push(.{ .items = nested.items }),
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
        if (self.expr_depth >= MAX_LINT_EXPR_DEPTH) return error.LintAstWalkDepthExceeded;
        self.expr_depth += 1;
        defer self.expr_depth -= 1;

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
        if (self.pattern_depth >= MAX_LINT_EXPR_DEPTH) return error.LintAstWalkDepthExceeded;
        self.pattern_depth += 1;
        defer self.pattern_depth -= 1;

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

const DEEPLY_NESTED_STRUCT_LINT_DEPTH: usize = 100_000;

fn makePublicRaiseFunction(
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
) !*const ast.FunctionDecl {
    const span = ast.SourceSpan{ .start = 0, .end = 1 };

    const message = try allocator.create(ast.Expr);
    message.* = .{ .string_literal = .{
        .meta = .{ .span = span },
        .value = try interner.intern("boom"),
    } };

    const raise_expr = try allocator.create(ast.Expr);
    raise_expr.* = .{ .raise_expr = .{
        .meta = .{ .span = span },
        .value = message,
    } };

    const body = try allocator.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = raise_expr };

    const clauses = try allocator.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = .{ .span = span },
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = body,
    };

    const function = try allocator.create(ast.FunctionDecl);
    function.* = .{
        .meta = .{ .span = span },
        .name = try interner.intern("run"),
        .clauses = clauses,
        .visibility = .public,
    };
    return function;
}

fn makePublicFunctionWithBody(
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    body: []const ast.Stmt,
) !*const ast.FunctionDecl {
    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const clauses = try allocator.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = .{ .span = span },
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = body,
    };

    const function = try allocator.create(ast.FunctionDecl);
    function.* = .{
        .meta = .{ .span = span },
        .name = try interner.intern("run"),
        .clauses = clauses,
        .visibility = .public,
    };
    return function;
}

fn makeDeepUnaryExpr(
    allocator: std.mem.Allocator,
    depth: usize,
) !*const ast.Expr {
    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    var expr = try allocator.create(ast.Expr);
    expr.* = .{ .int_literal = .{ .meta = .{ .span = span }, .value = 1 } };
    for (0..depth) |_| {
        const wrapper = try allocator.create(ast.Expr);
        wrapper.* = .{ .unary_op = .{
            .meta = .{ .span = span },
            .op = .not_op,
            .operand = expr,
        } };
        expr = wrapper;
    }
    return expr;
}

fn makeWideTupleExpr(
    allocator: std.mem.Allocator,
    width: usize,
) !*const ast.Expr {
    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const elements = try allocator.alloc(*const ast.Expr, width);
    for (elements) |*element| {
        const expr = try allocator.create(ast.Expr);
        expr.* = .{ .int_literal = .{ .meta = .{ .span = span }, .value = 1 } };
        element.* = expr;
    }

    const tuple = try allocator.create(ast.Expr);
    tuple.* = .{ .tuple = .{
        .meta = .{ .span = span },
        .elements = elements,
    } };
    return tuple;
}

fn makeDeeplyNestedStructProgram(
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    leaf_item: ast.StructItem,
) !ast.Program {
    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const struct_name_parts = try allocator.alloc(ast.StringId, 1);
    struct_name_parts[0] = try interner.intern("Nested");
    const struct_name = ast.StructName{
        .parts = struct_name_parts,
        .span = span,
    };

    var current_item = leaf_item;
    for (0..DEEPLY_NESTED_STRUCT_LINT_DEPTH) |_| {
        const items = try allocator.alloc(ast.StructItem, 1);
        items[0] = current_item;

        const struct_decl = try allocator.create(ast.StructDecl);
        struct_decl.* = .{
            .meta = .{ .span = span },
            .name = struct_name,
            .items = items,
        };
        current_item = .{ .struct_decl = struct_decl };
    }

    const root_struct = switch (current_item) {
        .struct_decl => |struct_decl| struct_decl,
        else => unreachable,
    };
    const top_items = try allocator.alloc(ast.TopItem, 1);
    top_items[0] = .{ .struct_decl = root_struct };

    return .{
        .structs = &.{},
        .top_items = top_items,
    };
}

test "mandatory raises lint walks deeply nested struct items without recursive stack growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    const function = try makePublicRaiseFunction(alloc, &interner);
    const program = try makeDeeplyNestedStructProgram(alloc, &interner, .{ .function = function });

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runMandatoryRaisesLint(&program, &interner, &engine);
    try std.testing.expectEqual(@as(usize, 1), engine.warningCount());
}

test "phase 1.4 lint walks deeply nested struct items without recursive stack growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    const function = try makePublicRaiseFunction(alloc, &interner);
    const program = try makeDeeplyNestedStructProgram(alloc, &interner, .{ .function = function });

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, &interner, &engine);
    try std.testing.expectEqual(@as(usize, 1), engine.warningCount());
}

test "mandatory raises scanner reports expression depth budget instead of a false raise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    const expr = try makeDeepUnaryExpr(alloc, MAX_LINT_EXPR_DEPTH + 8);
    try std.testing.expectError(error.LintAstWalkDepthExceeded, exprCanRaise(alloc, expr));

    const body = try alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = expr };
    const function = try makePublicFunctionWithBody(alloc, &interner, body);
    const top_items = try alloc.alloc(ast.TopItem, 1);
    top_items[0] = .{ .function = function };
    const program = ast.Program{
        .structs = &.{},
        .top_items = top_items,
    };

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try std.testing.expectError(error.LintAstWalkDepthExceeded, runMandatoryRaisesLint(&program, &interner, &engine));
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}

test "mandatory raises scanner propagates stack allocation OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    const expr = try makeWideTupleExpr(setup_alloc, INLINE_RAISES_SCAN_FRAME_CAPACITY + 8);
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const failing_alloc = failing_allocator.allocator();
    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, exprCanRaise(failing_alloc, expr));

    const body = try setup_alloc.alloc(ast.Stmt, 1);
    body[0] = .{ .expr = expr };
    const function = try makePublicFunctionWithBody(setup_alloc, &interner, body);
    const top_items = try setup_alloc.alloc(ast.TopItem, 1);
    top_items[0] = .{ .function = function };
    const program = ast.Program{
        .structs = &.{},
        .top_items = top_items,
    };

    var engine = diagnostics.DiagnosticEngine.init(failing_alloc);
    defer engine.deinit();
    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, runMandatoryRaisesLint(&program, &interner, &engine));
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}

test "missing-@code lint warns on pub error without @code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\pub error UncodedError {}
    ;
    var parser = try Parser.init(alloc, source);
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
    var parser = try Parser.init(alloc, source);
    const program = try parser.parseProgram();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, parser.interner, &engine);
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}

test "lint AST walkers report excessive depth before native stack overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expr = try makeDeepUnaryExpr(alloc, MAX_LINT_EXPR_DEPTH + 8);

    try std.testing.expectError(error.LintAstWalkDepthExceeded, exprCanRaise(alloc, expr));

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();
    var linter = Linter{ .interner = &interner, .engine = &engine };

    try std.testing.expectError(error.LintAstWalkDepthExceeded, linter.lintExpr(expr, true));
}

test "missing-@code lint exempts private error declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\error PrivateError {}
    ;
    var parser = try Parser.init(alloc, source);
    const program = try parser.parseProgram();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try runPhase14Lints(&program, parser.interner, &engine);
    try std.testing.expectEqual(@as(usize, 0), engine.warningCount());
}
