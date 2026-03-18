const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Name resolver
//
// Walks the AST and resolves:
//   - Variable references to bindings in scope
//   - Type names to registered types
//   - Function calls to function families
//   - Module references via aliases
//
// Annotates AST nodes with scope_id information.
// ============================================================

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    graph: *scope_mod.ScopeGraph,
    interner: *const ast.StringInterner,
    errors: std.ArrayList(Error),
    current_scope: scope_mod.ScopeId,

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(allocator: std.mem.Allocator, graph: *scope_mod.ScopeGraph, interner: *const ast.StringInterner) Resolver {
        return .{
            .allocator = allocator,
            .graph = graph,
            .interner = interner,
            .errors = .empty,
            .current_scope = graph.prelude_scope,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.errors.deinit(self.allocator);
    }

    fn addError(self: *Resolver, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    // ============================================================
    // Program resolution
    // ============================================================

    pub fn resolveProgram(self: *Resolver, program: *const ast.Program) !void {
        // Resolve modules
        for (program.modules, 0..) |*mod, i| {
            // Find the module scope
            if (i < self.graph.modules.items.len) {
                const mod_entry = &self.graph.modules.items[i];
                const saved = self.current_scope;
                self.current_scope = mod_entry.scope_id;
                try self.resolveModule(mod);
                self.current_scope = saved;
            }
        }

        // Resolve top-level items
        for (program.top_items) |item| {
            try self.resolveTopItem(item);
        }
    }

    fn resolveModule(self: *Resolver, mod: *const ast.ModuleDecl) !void {
        for (mod.items) |item| {
            switch (item) {
                .function => |func| try self.resolveFunctionDecl(func),
                .priv_function => |func| try self.resolveFunctionDecl(func),
                .macro => |mac| try self.resolveFunctionDecl(mac),
                .type_decl => |td| try self.resolveTypeDecl(td),
                .opaque_decl => |od| try self.resolveOpaqueDecl(od),
                else => {},
            }
        }
    }

    fn resolveTopItem(self: *Resolver, item: ast.TopItem) !void {
        switch (item) {
            .function => |func| try self.resolveFunctionDecl(func),
            .priv_function => |func| try self.resolveFunctionDecl(func),
            .macro => |mac| try self.resolveFunctionDecl(mac),
            .type_decl => |td| try self.resolveTypeDecl(td),
            .opaque_decl => |od| try self.resolveOpaqueDecl(od),
            .struct_decl => {},
            .enum_decl => {},
            .module => {},
        }
    }

    // ============================================================
    // Type declaration resolution
    // ============================================================

    fn resolveTypeDecl(self: *Resolver, td: *const ast.TypeDecl) !void {
        try self.resolveTypeExpr(td.body);
    }

    fn resolveOpaqueDecl(self: *Resolver, od: *const ast.OpaqueDecl) !void {
        try self.resolveTypeExpr(od.body);
    }

    fn resolveTypeExpr(self: *Resolver, type_expr: *const ast.TypeExpr) anyerror!void {
        switch (type_expr.*) {
            .name => |tn| {
                // Verify the type name exists
                const name_str = self.interner.get(tn.name);
                if (!isBuiltinType(name_str)) {
                    var found = false;
                    for (self.graph.types.items) |te| {
                        if (te.name == tn.name) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // Type might be defined later or imported; soft warning for now
                    }
                }
                // Resolve type arguments
                for (tn.args) |arg| {
                    try self.resolveTypeExpr(arg);
                }
            },
            .tuple => |tt| {
                for (tt.elements) |elem| {
                    try self.resolveTypeExpr(elem);
                }
            },
            .list => |lt| {
                try self.resolveTypeExpr(lt.element);
            },
            .map => |mt| {
                for (mt.fields) |field| {
                    try self.resolveTypeExpr(field.key);
                    try self.resolveTypeExpr(field.value);
                }
            },
            .union_type => |ut| {
                for (ut.members) |member| {
                    try self.resolveTypeExpr(member);
                }
            },
            .function => |ft| {
                for (ft.params) |param| {
                    try self.resolveTypeExpr(param);
                }
                try self.resolveTypeExpr(ft.return_type);
            },
            .paren => |pt| {
                try self.resolveTypeExpr(pt.inner);
            },
            // Variable, literal, never, struct_type — no resolution needed
            .variable, .literal, .never, .struct_type => {},
        }
    }

    // ============================================================
    // Function declaration resolution
    // ============================================================

    fn resolveFunctionDecl(self: *Resolver, func: *const ast.FunctionDecl) !void {
        for (func.clauses) |clause| {
            // Create a function scope for resolution
            const fn_scope = try self.graph.createScope(self.current_scope, .function);
            const saved = self.current_scope;
            self.current_scope = fn_scope;

            // Resolve parameter patterns and types
            for (clause.params) |param| {
                try self.resolvePattern(param.pattern);
                if (param.type_annotation) |ta| {
                    try self.resolveTypeExpr(ta);
                }
            }

            // Resolve return type
            if (clause.return_type) |rt| {
                try self.resolveTypeExpr(rt);
            }

            // Resolve refinement
            if (clause.refinement) |ref| {
                try self.resolveExpr(ref);
            }

            // Resolve body
            try self.resolveBlock(clause.body);

            self.current_scope = saved;
        }
    }

    // ============================================================
    // Block resolution
    // ============================================================

    fn resolveBlock(self: *Resolver, stmts: []const ast.Stmt) anyerror!void {
        for (stmts) |stmt| {
            try self.resolveStmt(stmt);
        }
    }

    fn resolveStmt(self: *Resolver, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .expr => |expr| try self.resolveExpr(expr),
            .assignment => |assign| {
                try self.resolveExpr(assign.value);
                try self.resolvePattern(assign.pattern);
                // Create bindings for assigned variables
                try self.bindPattern(assign.pattern);
            },
            .function_decl => |func| try self.resolveFunctionDecl(func),
            .macro_decl => |mac| try self.resolveFunctionDecl(mac),
            .import_decl => {},
        }
    }

    // ============================================================
    // Expression resolution
    // ============================================================

    fn resolveExpr(self: *Resolver, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .var_ref => |vr| {
                // Check if variable is in scope
                if (self.graph.resolveBinding(self.current_scope, vr.name) == null) {
                    // Might be a function name — check function families
                    const name_str = self.interner.get(vr.name);
                    if (!isBuiltinFunction(name_str)) {
                        // Not found — could be a forward reference or error
                        // We'll let the type checker handle unresolved references
                    }
                }
            },
            .call => |call| {
                try self.resolveExpr(call.callee);
                for (call.args) |arg| {
                    try self.resolveExpr(arg);
                }
            },
            .binary_op => |bo| {
                try self.resolveExpr(bo.lhs);
                try self.resolveExpr(bo.rhs);
            },
            .unary_op => |uo| {
                try self.resolveExpr(uo.operand);
            },
            .if_expr => |ie| {
                try self.resolveExpr(ie.condition);
                const then_scope = try self.graph.createScope(self.current_scope, .block);
                const saved = self.current_scope;
                self.current_scope = then_scope;
                try self.resolveBlock(ie.then_block);
                self.current_scope = saved;

                if (ie.else_block) |else_block| {
                    const else_scope = try self.graph.createScope(self.current_scope, .block);
                    self.current_scope = else_scope;
                    try self.resolveBlock(else_block);
                    self.current_scope = saved;
                }
            },
            .case_expr => |ce| {
                try self.resolveExpr(ce.scrutinee);
                for (ce.clauses) |clause| {
                    const clause_scope = try self.graph.createScope(self.current_scope, .case_clause);
                    const saved = self.current_scope;
                    self.current_scope = clause_scope;
                    try self.resolvePattern(clause.pattern);
                    try self.bindPattern(clause.pattern);
                    if (clause.guard) |guard| try self.resolveExpr(guard);
                    try self.resolveBlock(clause.body);
                    self.current_scope = saved;
                }
            },
            .with_expr => |we| {
                const with_scope = try self.graph.createScope(self.current_scope, .block);
                const saved = self.current_scope;
                self.current_scope = with_scope;
                for (we.items) |item| {
                    switch (item) {
                        .bind => |b| {
                            try self.resolveExpr(b.source);
                            try self.resolvePattern(b.pattern);
                            try self.bindPattern(b.pattern);
                        },
                        .expr => |e| try self.resolveExpr(e),
                    }
                }
                try self.resolveBlock(we.body);
                self.current_scope = saved;
            },
            .cond_expr => |cond| {
                for (cond.clauses) |clause| {
                    try self.resolveExpr(clause.condition);
                    const clause_scope = try self.graph.createScope(self.current_scope, .block);
                    const saved = self.current_scope;
                    self.current_scope = clause_scope;
                    try self.resolveBlock(clause.body);
                    self.current_scope = saved;
                }
            },
            .block => |blk| {
                const blk_scope = try self.graph.createScope(self.current_scope, .block);
                const saved = self.current_scope;
                self.current_scope = blk_scope;
                try self.resolveBlock(blk.stmts);
                self.current_scope = saved;
            },
            .field_access => |fa| try self.resolveExpr(fa.object),
            .tuple => |t| {
                for (t.elements) |elem| try self.resolveExpr(elem);
            },
            .list => |l| {
                for (l.elements) |elem| try self.resolveExpr(elem);
            },
            .map => |m| {
                for (m.fields) |field| {
                    try self.resolveExpr(field.key);
                    try self.resolveExpr(field.value);
                }
            },
            .struct_expr => |se| {
                if (se.update_source) |us| try self.resolveExpr(us);
                for (se.fields) |field| try self.resolveExpr(field.value);
            },
            .panic_expr => |pe| try self.resolveExpr(pe.message),
            .pipe => |pipe| {
                try self.resolveExpr(pipe.lhs);
                try self.resolveExpr(pipe.rhs);
            },
            .unwrap => |uw| try self.resolveExpr(uw.expr),
            .quote_expr => |qe| try self.resolveBlock(qe.body),
            .unquote_expr => |ue| try self.resolveExpr(ue.expr),
            .type_annotated => |ta| {
                try self.resolveExpr(ta.expr);
            },
            // Literals and module refs — no resolution needed
            .int_literal, .float_literal, .string_literal,
            .string_interpolation, .atom_literal, .bool_literal,
            .nil_literal, .module_ref, .intrinsic,
            => {},
        }
    }

    // ============================================================
    // Pattern resolution
    // ============================================================

    fn resolvePattern(self: *Resolver, pattern: *const ast.Pattern) anyerror!void {
        switch (pattern.*) {
            .tuple => |t| {
                for (t.elements) |elem| try self.resolvePattern(elem);
            },
            .list => |l| {
                for (l.elements) |elem| try self.resolvePattern(elem);
            },
            .map => |m| {
                for (m.fields) |field| {
                    try self.resolveExpr(field.key);
                    try self.resolvePattern(field.value);
                }
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| try self.resolvePattern(field.pattern);
            },
            .paren => |p| try self.resolvePattern(p.inner),
            .pin => |pin| {
                // Pin references an existing variable
                if (self.graph.resolveBinding(self.current_scope, pin.name) == null) {
                    try self.addError("pinned variable not found in scope", pin.meta.span);
                }
            },
            .wildcard, .bind, .literal => {},
        }
    }

    /// Create bindings for variables introduced by a pattern
    fn bindPattern(self: *Resolver, pattern: *const ast.Pattern) !void {
        switch (pattern.*) {
            .bind => |b| {
                _ = try self.graph.createBinding(b.name, self.current_scope, .pattern_bind, b.meta.span);
            },
            .tuple => |t| {
                for (t.elements) |elem| try self.bindPattern(elem);
            },
            .list => |l| {
                for (l.elements) |elem| try self.bindPattern(elem);
            },
            .map => |m| {
                for (m.fields) |field| try self.bindPattern(field.value);
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| try self.bindPattern(field.pattern);
            },
            .paren => |p| try self.bindPattern(p.inner),
            .wildcard, .literal, .pin => {},
        }
    }

    // ============================================================
    // Built-in type and function checks
    // ============================================================

    fn isBuiltinType(name: []const u8) bool {
        const builtins = [_][]const u8{
            "i8", "i16", "i32", "i64",
            "u8", "u16", "u32", "u64",
            "f16", "f32", "f64",
            "usize", "isize",
            "Bool", "String", "Atom", "Nil",
            "Never", "AST",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }

    fn isBuiltinFunction(name: []const u8) bool {
        const builtins = [_][]const u8{
            "to_string", "int_to_string", "not",
            "i32_to_i64", "i64_to_i32",
        };
        for (builtins) |b| {
            if (std.mem.eql(u8, name, b)) return true;
        }
        return false;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "resolve simple function" {
    const source =
        \\def add(x :: i64, y :: i64) :: i64 do
        \\  x + y
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var resolver = Resolver.init(alloc, &collector.graph, &parser.interner);
    defer resolver.deinit();
    try resolver.resolveProgram(&program);

    // Should resolve without errors
    try std.testing.expectEqual(@as(usize, 0), resolver.errors.items.len);
}

test "resolve module with function" {
    const source =
        \\defmodule Math do
        \\  def add(x :: i64, y :: i64) :: i64 do
        \\    x + y
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var resolver = Resolver.init(alloc, &collector.graph, &parser.interner);
    defer resolver.deinit();
    try resolver.resolveProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), resolver.errors.items.len);
}

test "resolve case expression with bindings" {
    const source =
        \\def foo(x) do
        \\  case x do
        \\    {:ok, v} ->
        \\      v
        \\    {:error, e} ->
        \\      e
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var resolver = Resolver.init(alloc, &collector.graph, &parser.interner);
    defer resolver.deinit();
    try resolver.resolveProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), resolver.errors.items.len);
}

test "resolve assignment" {
    const source =
        \\def foo() do
        \\  x = 42
        \\  x
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var resolver = Resolver.init(alloc, &collector.graph, &parser.interner);
    defer resolver.deinit();
    try resolver.resolveProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), resolver.errors.items.len);
}
