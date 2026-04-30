// ============================================================
// Generic AST visitor
//
// Single source of traversal for all the passes that walk the AST
// (desugar, attr_substitute, macro, resolver, types, hir,
// monomorphize, …). Each pass currently re-implements an exhaustive
// `switch (expr.*)` over every Expr/Pattern/Stmt variant — adding a
// new AST shape (or even a new variant on an existing union, like
// the index_get / list_head_get / list_tail_get / map_value_get
// destructure helpers added in the audit cycle) requires touching
// every walker, and missing one silently corrupts that pass's
// analysis.
//
// Design goals:
//
//   1. Default behaviour is "recurse into every child". A Context
//      that overrides nothing visits every reachable node.
//   2. Each variant gets its own optional visit hook so a pass can
//      override exactly the variants it cares about and inherit the
//      default recursion for everything else.
//   3. Adding a new AST variant only needs an update to this file —
//      every Context that doesn't override the new visit hook keeps
//      working without modification.
//   4. Comptime dispatch (no vtable / runtime indirection). The
//      hook lookup uses `@hasDecl` so unused hooks compile away.
//   5. Errors propagate with an `anyerror!void` return, matching the
//      existing pass signatures.
//
// Adoption pattern (per pass):
//
//   const ast_visitor = @import("ast_visitor.zig");
//
//   const MyPass = struct {
//       /// Optional: only define the hooks this pass cares about.
//       pub fn visitVarRef(self: *MyPass, vr: *const ast.VarRef) !void {
//           // pass-specific logic; no need to re-implement child
//           // recursion here — there are no children for var_ref.
//           _ = self; _ = vr;
//       }
//
//       pub fn visitCase(self: *MyPass, ce: *const ast.CaseExpr) !void {
//           // For variants with children, override only when you need
//           // pre/post hooks; the default visit will recurse for you.
//           // Here we save scope state, recurse, restore.
//           const saved = self.current_scope;
//           defer self.current_scope = saved;
//           // ... custom scope-stack logic ...
//           try ast_visitor.AstVisitor(MyPass).walkCase(self, ce);
//       }
//   };
//
//   // In the pass driver:
//   var pass = MyPass{};
//   try ast_visitor.AstVisitor(MyPass).visitProgram(&pass, &program);
//
// The same `AstVisitor(Context)` type provides public `walk*` helpers
// for every variant; a hook can call its own `walk*` to recurse after
// or before its custom logic.
// ============================================================

const std = @import("std");
const ast = @import("ast.zig");

/// Generate a visitor specialised to `Context`. The Context can carry
/// any per-pass state (scope stacks, accumulators, error lists). All
/// visit hooks are called with `*Context` so they can mutate that
/// state. Hooks that aren't defined fall through to the default
/// recursion implemented in `walk*`.
pub fn AstVisitor(comptime Context: type) type {
    return struct {
        const Self = @This();

        // ----------------------------------------------------------
        // Top-level entry points
        // ----------------------------------------------------------

        pub fn visitProgram(ctx: *Context, program: *const ast.Program) anyerror!void {
            if (@hasDecl(Context, "visitProgram")) {
                return Context.visitProgram(ctx, program);
            }
            try walkProgram(ctx, program);
        }

        pub fn walkProgram(ctx: *Context, program: *const ast.Program) anyerror!void {
            for (program.structs) |*decl| {
                try visitStructDecl(ctx, decl);
            }
            for (program.top_items) |item| {
                try visitTopItem(ctx, item);
            }
        }

        pub fn visitTopItem(ctx: *Context, item: ast.TopItem) anyerror!void {
            if (@hasDecl(Context, "visitTopItem")) {
                return Context.visitTopItem(ctx, item);
            }
            switch (item) {
                // Struct decls are visited via `program.structs`,
                // which is the canonical iteration order the collector
                // and other passes use. Skipping them here avoids
                // double-traversal when an AST also lists them in
                // `top_items`.
                .struct_decl, .priv_struct_decl => {},
                .protocol, .priv_protocol => {},
                .impl_decl, .priv_impl_decl => |impl_d| try visitImplDecl(ctx, impl_d),
                .type_decl, .opaque_decl, .union_decl => {},
                .function, .priv_function, .macro, .priv_macro => |func| try visitFunctionDecl(ctx, func),
                .attribute => |attr| try visitAttributeDecl(ctx, attr),
            }
        }

        pub fn visitStructDecl(ctx: *Context, decl: *const ast.StructDecl) anyerror!void {
            if (@hasDecl(Context, "visitStructDecl")) {
                return Context.visitStructDecl(ctx, decl);
            }
            try walkStructDecl(ctx, decl);
        }

        pub fn walkStructDecl(ctx: *Context, decl: *const ast.StructDecl) anyerror!void {
            for (decl.items) |item| {
                switch (item) {
                    .function, .priv_function, .macro, .priv_macro => |func| try visitFunctionDecl(ctx, func),
                    .struct_decl => |sd| try visitStructDecl(ctx, sd),
                    .attribute => |attr| try visitAttributeDecl(ctx, attr),
                    .struct_level_expr => |expr| try visitExpr(ctx, expr),
                    else => {},
                }
            }
        }

        pub fn visitImplDecl(ctx: *Context, decl: *const ast.ImplDecl) anyerror!void {
            if (@hasDecl(Context, "visitImplDecl")) {
                return Context.visitImplDecl(ctx, decl);
            }
            for (decl.functions) |func| {
                try visitFunctionDecl(ctx, func);
            }
        }

        pub fn visitFunctionDecl(ctx: *Context, decl: *const ast.FunctionDecl) anyerror!void {
            if (@hasDecl(Context, "visitFunctionDecl")) {
                return Context.visitFunctionDecl(ctx, decl);
            }
            try walkFunctionDecl(ctx, decl);
        }

        pub fn walkFunctionDecl(ctx: *Context, decl: *const ast.FunctionDecl) anyerror!void {
            for (decl.clauses) |clause| {
                try visitFunctionClause(ctx, &clause);
            }
        }

        pub fn visitFunctionClause(ctx: *Context, clause: *const ast.FunctionClause) anyerror!void {
            if (@hasDecl(Context, "visitFunctionClause")) {
                return Context.visitFunctionClause(ctx, clause);
            }
            try walkFunctionClause(ctx, clause);
        }

        pub fn walkFunctionClause(ctx: *Context, clause: *const ast.FunctionClause) anyerror!void {
            for (clause.params) |param| {
                try visitPattern(ctx, param.pattern);
            }
            if (clause.refinement) |r| try visitExpr(ctx, r);
            if (clause.body) |body| {
                try visitBlock(ctx, body);
            }
        }

        pub fn visitAttributeDecl(ctx: *Context, decl: *const ast.AttributeDecl) anyerror!void {
            if (@hasDecl(Context, "visitAttributeDecl")) {
                return Context.visitAttributeDecl(ctx, decl);
            }
            if (decl.value) |v| try visitExpr(ctx, v);
        }

        pub fn visitBlock(ctx: *Context, stmts: []const ast.Stmt) anyerror!void {
            if (@hasDecl(Context, "visitBlock")) {
                return Context.visitBlock(ctx, stmts);
            }
            for (stmts) |stmt| try visitStmt(ctx, stmt);
        }

        // ----------------------------------------------------------
        // Statements
        // ----------------------------------------------------------

        pub fn visitStmt(ctx: *Context, stmt: ast.Stmt) anyerror!void {
            if (@hasDecl(Context, "visitStmt")) {
                return Context.visitStmt(ctx, stmt);
            }
            switch (stmt) {
                .expr => |e| try visitExpr(ctx, e),
                .assignment => |a| try visitAssignment(ctx, a),
                .function_decl => |func| try visitFunctionDecl(ctx, func),
                .macro_decl => |func| try visitFunctionDecl(ctx, func),
                .import_decl => {},
            }
        }

        pub fn visitAssignment(ctx: *Context, a: *const ast.Assignment) anyerror!void {
            if (@hasDecl(Context, "visitAssignment")) {
                return Context.visitAssignment(ctx, a);
            }
            try visitPattern(ctx, a.pattern);
            try visitExpr(ctx, a.value);
        }

        // ----------------------------------------------------------
        // Expressions
        // ----------------------------------------------------------

        pub fn visitExpr(ctx: *Context, expr: *const ast.Expr) anyerror!void {
            if (@hasDecl(Context, "visitExpr")) {
                return Context.visitExpr(ctx, expr);
            }
            try walkExpr(ctx, expr);
        }

        pub fn walkExpr(ctx: *Context, expr: *const ast.Expr) anyerror!void {
            switch (expr.*) {
                .int_literal, .float_literal, .string_literal, .atom_literal, .bool_literal, .nil_literal, .var_ref, .struct_ref, .attr_ref, .function_ref, .intrinsic => {},
                .string_interpolation => |si| {
                    for (si.parts) |part| {
                        switch (part) {
                            .literal => {},
                            .expr => |e| try visitExpr(ctx, e),
                        }
                    }
                },
                .tuple => |t| for (t.elements) |elem| try visitExpr(ctx, elem),
                .list => |l| for (l.elements) |elem| try visitExpr(ctx, elem),
                .map => |m| for (m.fields) |field| {
                    try visitExpr(ctx, field.key);
                    try visitExpr(ctx, field.value);
                },
                .struct_expr => |se| {
                    if (se.update_source) |us| try visitExpr(ctx, us);
                    for (se.fields) |f| try visitExpr(ctx, f.value);
                },
                .range => |r| {
                    try visitExpr(ctx, r.start);
                    try visitExpr(ctx, r.end);
                    if (r.step) |s| try visitExpr(ctx, s);
                },
                .binary_op => |bo| {
                    try visitExpr(ctx, bo.lhs);
                    try visitExpr(ctx, bo.rhs);
                },
                .unary_op => |uo| try visitExpr(ctx, uo.operand),
                .call => |c| {
                    try visitExpr(ctx, c.callee);
                    for (c.args) |arg| try visitExpr(ctx, arg);
                },
                .field_access => |fa| try visitExpr(ctx, fa.object),
                .pipe => |p| {
                    try visitExpr(ctx, p.lhs);
                    try visitExpr(ctx, p.rhs);
                },
                .unwrap => |u| try visitExpr(ctx, u.expr),
                .if_expr => |ie| {
                    try visitExpr(ctx, ie.condition);
                    try visitBlock(ctx, ie.then_block);
                    if (ie.else_block) |eb| try visitBlock(ctx, eb);
                },
                .case_expr => |ce| try walkCase(ctx, &ce),
                .cond_expr => |co| {
                    for (co.clauses) |clause| {
                        try visitExpr(ctx, clause.condition);
                        try visitBlock(ctx, clause.body);
                    }
                },
                .for_expr => |fe| {
                    try visitPattern(ctx, fe.var_pattern);
                    try visitExpr(ctx, fe.iterable);
                    if (fe.filter) |f| try visitExpr(ctx, f);
                    try visitExpr(ctx, fe.body);
                },
                .list_cons_expr => |lce| {
                    try visitExpr(ctx, lce.head);
                    try visitExpr(ctx, lce.tail);
                },
                .quote_expr => |qe| try visitBlock(ctx, qe.body),
                .unquote_expr => |ue| try visitExpr(ctx, ue.expr),
                .unquote_splicing_expr => |ue| try visitExpr(ctx, ue.expr),
                .panic_expr => |pe| try visitExpr(ctx, pe.message),
                .error_pipe => |ep| {
                    try visitExpr(ctx, ep.chain);
                    switch (ep.handler) {
                        .function => |f| try visitExpr(ctx, f),
                        .block => |clauses| for (clauses) |clause| {
                            try visitPattern(ctx, clause.pattern);
                            try visitBlock(ctx, clause.body);
                        },
                    }
                },
                .block => |blk| try visitBlock(ctx, blk.stmts),
                .binary_literal => |bl| {
                    for (bl.segments) |seg| {
                        switch (seg.value) {
                            .expr => |e| try visitExpr(ctx, e),
                            .pattern => |p| try visitPattern(ctx, p),
                            .string_literal => {},
                        }
                    }
                },
                .anonymous_function => |anon| try visitFunctionDecl(ctx, anon.decl),
                .type_annotated => |ta| try visitExpr(ctx, ta.expr),
            }
        }

        pub fn walkCase(ctx: *Context, ce: *const ast.CaseExpr) anyerror!void {
            try visitExpr(ctx, ce.scrutinee);
            for (ce.clauses) |clause| {
                try visitPattern(ctx, clause.pattern);
                if (clause.guard) |g| try visitExpr(ctx, g);
                try visitBlock(ctx, clause.body);
            }
        }

        // ----------------------------------------------------------
        // Patterns
        // ----------------------------------------------------------

        pub fn visitPattern(ctx: *Context, pat: *const ast.Pattern) anyerror!void {
            if (@hasDecl(Context, "visitPattern")) {
                return Context.visitPattern(ctx, pat);
            }
            try walkPattern(ctx, pat);
        }

        pub fn walkPattern(ctx: *Context, pat: *const ast.Pattern) anyerror!void {
            switch (pat.*) {
                .wildcard, .bind, .literal => {},
                .tuple => |t| for (t.elements) |elem| try visitPattern(ctx, elem),
                .list => |l| for (l.elements) |elem| try visitPattern(ctx, elem),
                .list_cons => |lc| {
                    for (lc.heads) |h| try visitPattern(ctx, h);
                    try visitPattern(ctx, lc.tail);
                },
                .map => |m| for (m.fields) |field| try visitPattern(ctx, field.value),
                .struct_pattern => |sp| for (sp.fields) |f| try visitPattern(ctx, f.pattern),
                .pin => {},
                .paren => |p| try visitPattern(ctx, p.inner),
                .binary => |b| for (b.segments) |seg| {
                    switch (seg.value) {
                        .expr => |e| try visitExpr(ctx, e),
                        .pattern => |sp| try visitPattern(ctx, sp),
                        .string_literal => {},
                    }
                },
            }
        }
    };
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

test "AstVisitor counts every var_ref by default-recursing into all expression children" {
    const Counter = struct {
        ctx_self: *@This(),
        var_ref_count: u32,

        pub fn visitExpr(self: *@This(), expr: *const ast.Expr) anyerror!void {
            if (expr.* == .var_ref) self.var_ref_count += 1;
            try AstVisitor(@This()).walkExpr(self, expr);
        }
    };

    const source =
        \\pub struct M {
        \\  pub fn f(x :: i64, y :: i64) -> i64 {
        \\    a = x + y
        \\    z = a * x
        \\    z - y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var counter: Counter = .{ .ctx_self = undefined, .var_ref_count = 0 };
    counter.ctx_self = &counter;
    try AstVisitor(Counter).visitProgram(&counter, &program);

    // Expected references: x, y (in `x + y`), a, x (in `a * x`), z, y
    // (in `z - y`). The pattern bindings `a` and `z` aren't
    // expressions — the visitor visits patterns separately and the
    // counter only watches expression nodes.
    try std.testing.expectEqual(@as(u32, 6), counter.var_ref_count);
}

test "AstVisitor traverses patterns when the Context overrides visitPattern" {
    const PatternBindCollector = struct {
        names: std.ArrayList(ast.StringId),

        pub fn visitPattern(self: *@This(), pat: *const ast.Pattern) anyerror!void {
            if (pat.* == .bind) {
                try self.names.append(std.testing.allocator, pat.bind.name);
            }
            try AstVisitor(@This()).walkPattern(self, pat);
        }
    };

    const source =
        \\pub struct M {
        \\  pub fn g({a, b} :: {i64, i64}) -> i64 {
        \\    a + b
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector: PatternBindCollector = .{ .names = .empty };
    defer collector.names.deinit(std.testing.allocator);
    try AstVisitor(PatternBindCollector).visitProgram(&collector, &program);

    // The tuple-pattern parameter contains two bind patterns (`a`,
    // `b`); the visitor's default `walkFunctionClause` reaches them
    // via `visitPattern(param.pattern)`.
    try std.testing.expectEqual(@as(usize, 2), collector.names.items.len);
}
