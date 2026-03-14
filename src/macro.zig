const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");

// ============================================================
// Macro engine
//
// Performs hygienic macro expansion on the surface AST.
// Expansion is repeated to a fixed point.
//
// Key concepts:
//   - quote: captures AST as data
//   - unquote: splices values into quoted AST
//   - hygiene: generated names carry a generation counter
//     to avoid accidental capture
// ============================================================

pub const MacroEngine = struct {
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    graph: *const scope.ScopeGraph,
    generation: u32,
    max_expansions: u32,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *ast.StringInterner, graph: *const scope.ScopeGraph) MacroEngine {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .generation = 0,
            .max_expansions = 100,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *MacroEngine) void {
        self.errors.deinit(self.allocator);
    }

    // ============================================================
    // Fixed-point expansion
    // ============================================================

    /// Expand all macros in a program to a fixed point.
    /// Returns the expanded program.
    pub fn expandProgram(self: *MacroEngine, program: *const ast.Program) !ast.Program {
        var current_modules = program.modules;
        var current_top_items = program.top_items;
        var iteration: u32 = 0;

        while (iteration < self.max_expansions) : (iteration += 1) {
            var changed = false;

            // Expand modules
            var new_modules: std.ArrayList(ast.ModuleDecl) = .empty;
            for (current_modules) |mod| {
                const expanded = try self.expandModule(&mod);
                if (expanded.changed) changed = true;
                try new_modules.append(self.allocator, expanded.module);
            }

            // Expand top-level items
            var new_top_items: std.ArrayList(ast.TopItem) = .empty;
            for (current_top_items) |item| {
                const expanded = try self.expandTopItem(item);
                if (expanded.changed) changed = true;
                try new_top_items.append(self.allocator, expanded.item);
            }

            current_modules = try new_modules.toOwnedSlice(self.allocator);
            current_top_items = try new_top_items.toOwnedSlice(self.allocator);

            if (!changed) break;
        }

        if (iteration >= self.max_expansions) {
            try self.errors.append(self.allocator, .{
                .message = "macro expansion did not reach fixed point",
                .span = .{ .start = 0, .end = 0 },
            });
        }

        return .{
            .modules = current_modules,
            .top_items = current_top_items,
        };
    }

    // ============================================================
    // Module expansion
    // ============================================================

    const ExpandedModule = struct {
        module: ast.ModuleDecl,
        changed: bool,
    };

    fn expandModule(self: *MacroEngine, mod: *const ast.ModuleDecl) !ExpandedModule {
        var changed = false;
        var new_items: std.ArrayList(ast.ModuleItem) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    const expanded = try self.expandFunctionDecl(func);
                    if (expanded.changed) changed = true;
                    try new_items.append(self.allocator, .{ .function = expanded.decl });
                },
                .priv_function => |func| {
                    const expanded = try self.expandFunctionDecl(func);
                    if (expanded.changed) changed = true;
                    try new_items.append(self.allocator, .{ .priv_function = expanded.decl });
                },
                .macro => |mac| {
                    const expanded = try self.expandFunctionDecl(mac);
                    if (expanded.changed) changed = true;
                    try new_items.append(self.allocator, .{ .macro = expanded.decl });
                },
                else => try new_items.append(self.allocator, item),
            }
        }

        return .{
            .module = .{
                .meta = mod.meta,
                .name = mod.name,
                .items = try new_items.toOwnedSlice(self.allocator),
            },
            .changed = changed,
        };
    }

    // ============================================================
    // Top-level item expansion
    // ============================================================

    const ExpandedTopItem = struct {
        item: ast.TopItem,
        changed: bool,
    };

    fn expandTopItem(self: *MacroEngine, item: ast.TopItem) !ExpandedTopItem {
        switch (item) {
            .function => |func| {
                const expanded = try self.expandFunctionDecl(func);
                return .{ .item = .{ .function = expanded.decl }, .changed = expanded.changed };
            },
            .priv_function => |func| {
                const expanded = try self.expandFunctionDecl(func);
                return .{ .item = .{ .priv_function = expanded.decl }, .changed = expanded.changed };
            },
            .macro => |mac| {
                const expanded = try self.expandFunctionDecl(mac);
                return .{ .item = .{ .macro = expanded.decl }, .changed = expanded.changed };
            },
            else => return .{ .item = item, .changed = false },
        }
    }

    // ============================================================
    // Function declaration expansion
    // ============================================================

    const ExpandedDecl = struct {
        decl: *const ast.FunctionDecl,
        changed: bool,
    };

    fn expandFunctionDecl(self: *MacroEngine, func: *const ast.FunctionDecl) !ExpandedDecl {
        var changed = false;
        var new_clauses: std.ArrayList(ast.FunctionClause) = .empty;

        for (func.clauses) |clause| {
            const expanded = try self.expandBlock(clause.body);
            if (expanded.changed) changed = true;
            try new_clauses.append(self.allocator, .{
                .meta = clause.meta,
                .params = clause.params,
                .return_type = clause.return_type,
                .refinement = clause.refinement,
                .body = expanded.stmts,
            });
        }

        if (!changed) return .{ .decl = func, .changed = false };

        const new_func = try self.create(ast.FunctionDecl, .{
            .meta = func.meta,
            .name = func.name,
            .clauses = try new_clauses.toOwnedSlice(self.allocator),
            .visibility = func.visibility,
        });
        return .{ .decl = new_func, .changed = true };
    }

    // ============================================================
    // Block expansion
    // ============================================================

    const ExpandedBlock = struct {
        stmts: []const ast.Stmt,
        changed: bool,
    };

    fn expandBlock(self: *MacroEngine, stmts: []const ast.Stmt) anyerror!ExpandedBlock {
        var changed = false;
        var new_stmts: std.ArrayList(ast.Stmt) = .empty;

        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const expanded = try self.expandExpr(expr);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .expr = expanded.expr });
                },
                .assignment => |assign| {
                    const expanded = try self.expandExpr(assign.value);
                    if (expanded.changed) changed = true;
                    if (expanded.changed) {
                        try new_stmts.append(self.allocator, .{
                            .assignment = try self.create(ast.Assignment, .{
                                .meta = assign.meta,
                                .pattern = assign.pattern,
                                .value = expanded.expr,
                            }),
                        });
                    } else {
                        try new_stmts.append(self.allocator, stmt);
                    }
                },
                .function_decl => |func| {
                    const expanded = try self.expandFunctionDecl(func);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .function_decl = expanded.decl });
                },
                .macro_decl => |mac| {
                    const expanded = try self.expandFunctionDecl(mac);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .macro_decl = expanded.decl });
                },
                .import_decl => {
                    try new_stmts.append(self.allocator, stmt);
                },
            }
        }

        return .{
            .stmts = try new_stmts.toOwnedSlice(self.allocator),
            .changed = changed,
        };
    }

    // ============================================================
    // Expression expansion
    // ============================================================

    const ExpandedExpr = struct {
        expr: *const ast.Expr,
        changed: bool,
    };

    fn expandExpr(self: *MacroEngine, expr: *const ast.Expr) anyerror!ExpandedExpr {
        switch (expr.*) {
            // Quote expressions produce AST data — leave them as-is
            // (unquote inside quote is handled at expansion time)
            .quote_expr => return .{ .expr = expr, .changed = false },

            // Unquote outside of quote is an error
            .unquote_expr => {
                try self.errors.append(self.allocator, .{
                    .message = "unquote outside of quote",
                    .span = expr.getMeta().span,
                });
                return .{ .expr = expr, .changed = false };
            },

            // Check if this is a macro call
            .call => |call| {
                // Check if the callee is a known macro
                if (call.callee.* == .var_ref) {
                    const macro_family = self.findMacro(call.callee.var_ref.name, @intCast(call.args.len));
                    if (macro_family) |_| {
                        // Found a macro — expand it
                        const expanded = try self.expandMacroCall(expr);
                        return .{ .expr = expanded, .changed = true };
                    }
                }

                // Not a macro call — recurse into subexpressions
                return try self.expandCallExpr(expr);
            },

            // Recurse into compound expressions
            .if_expr => |ie| {
                var changed = false;
                const cond_exp = try self.expandExpr(ie.condition);
                if (cond_exp.changed) changed = true;

                const then_exp = try self.expandBlock(ie.then_block);
                if (then_exp.changed) changed = true;

                var else_exp: ?[]const ast.Stmt = ie.else_block;
                if (ie.else_block) |else_block| {
                    const e = try self.expandBlock(else_block);
                    if (e.changed) {
                        changed = true;
                        else_exp = e.stmts;
                    }
                }

                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .if_expr = .{
                            .meta = ie.meta,
                            .condition = cond_exp.expr,
                            .then_block = then_exp.stmts,
                            .else_block = else_exp,
                        },
                    }),
                    .changed = true,
                };
            },

            .case_expr => |ce| {
                var changed = false;
                const scrut_exp = try self.expandExpr(ce.scrutinee);
                if (scrut_exp.changed) changed = true;

                var new_clauses: std.ArrayList(ast.CaseClause) = .empty;
                for (ce.clauses) |clause| {
                    const body_exp = try self.expandBlock(clause.body);
                    if (body_exp.changed) changed = true;
                    try new_clauses.append(self.allocator, .{
                        .meta = clause.meta,
                        .pattern = clause.pattern,
                        .type_annotation = clause.type_annotation,
                        .guard = clause.guard,
                        .body = body_exp.stmts,
                    });
                }

                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .case_expr = .{
                            .meta = ce.meta,
                            .scrutinee = scrut_exp.expr,
                            .clauses = try new_clauses.toOwnedSlice(self.allocator),
                        },
                    }),
                    .changed = true,
                };
            },

            .binary_op => |bo| {
                const lhs = try self.expandExpr(bo.lhs);
                const rhs = try self.expandExpr(bo.rhs);
                if (!lhs.changed and !rhs.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .binary_op = .{
                            .meta = bo.meta,
                            .op = bo.op,
                            .lhs = lhs.expr,
                            .rhs = rhs.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            .unary_op => |uo| {
                const operand = try self.expandExpr(uo.operand);
                if (!operand.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .unary_op = .{
                            .meta = uo.meta,
                            .op = uo.op,
                            .operand = operand.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            .pipe => |pe| {
                const lhs = try self.expandExpr(pe.lhs);
                const rhs = try self.expandExpr(pe.rhs);
                if (!lhs.changed and !rhs.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .pipe = .{
                            .meta = pe.meta,
                            .lhs = lhs.expr,
                            .rhs = rhs.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            .block => |blk| {
                const expanded = try self.expandBlock(blk.stmts);
                if (!expanded.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .block = .{
                            .meta = blk.meta,
                            .stmts = expanded.stmts,
                        },
                    }),
                    .changed = true,
                };
            },

            // Leaf nodes — no expansion needed
            .int_literal,
            .float_literal,
            .string_literal,
            .string_interpolation,
            .atom_literal,
            .bool_literal,
            .nil_literal,
            .var_ref,
            .module_ref,
            .tuple,
            .list,
            .map,
            .struct_expr,
            .field_access,
            .unwrap,
            .with_expr,
            .cond_expr,
            .panic_expr,
            .intrinsic,
            => return .{ .expr = expr, .changed = false },
        }
    }

    fn expandCallExpr(self: *MacroEngine, expr: *const ast.Expr) !ExpandedExpr {
        const call = expr.call;
        var changed = false;

        const callee = try self.expandExpr(call.callee);
        if (callee.changed) changed = true;

        var new_args: std.ArrayList(*const ast.Expr) = .empty;
        for (call.args) |arg| {
            const expanded = try self.expandExpr(arg);
            if (expanded.changed) changed = true;
            try new_args.append(self.allocator, expanded.expr);
        }

        if (!changed) return .{ .expr = expr, .changed = false };
        return .{
            .expr = try self.create(ast.Expr, .{
                .call = .{
                    .meta = call.meta,
                    .callee = callee.expr,
                    .args = try new_args.toOwnedSlice(self.allocator),
                },
            }),
            .changed = true,
        };
    }

    // ============================================================
    // Macro call expansion
    // ============================================================

    fn expandMacroCall(self: *MacroEngine, expr: *const ast.Expr) !*const ast.Expr {
        const call = expr.call;
        const name = call.callee.var_ref.name;
        const arity: u32 = @intCast(call.args.len);

        const macro_family_id = self.findMacro(name, arity) orelse {
            try self.errors.append(self.allocator, .{
                .message = "macro not found",
                .span = call.meta.span,
            });
            return expr;
        };

        const family = &self.graph.macro_families.items[macro_family_id];

        if (family.clauses.items.len == 0) {
            try self.errors.append(self.allocator, .{
                .message = "macro has no clauses",
                .span = call.meta.span,
            });
            return expr;
        }

        // Use the first clause for now (pattern matching on macro args is Phase 4+)
        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // The macro body should be a quote expression
        // Evaluate by substituting unquote expressions with the call arguments
        if (clause.body.len == 1 and clause.body[0] == .expr) {
            const body_expr = clause.body[0].expr;
            if (body_expr.* == .quote_expr) {
                self.generation += 1;
                return try self.expandQuote(body_expr, call.args, clause.params);
            }
        }

        // If macro body is not a simple quote, return as-is for now
        try self.errors.append(self.allocator, .{
            .message = "macro body must be a quote expression",
            .span = call.meta.span,
        });
        return expr;
    }

    // ============================================================
    // Quote expansion with unquote substitution
    // ============================================================

    fn expandQuote(self: *MacroEngine, quote_expr: *const ast.Expr, args: []const *const ast.Expr, params: []const ast.Param) anyerror!*const ast.Expr {
        const quote = quote_expr.quote_expr;

        // Build parameter name -> argument mapping
        var param_map = std.AutoHashMap(ast.StringId, *const ast.Expr).init(self.allocator);
        defer param_map.deinit();

        for (params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    try param_map.put(param.pattern.bind.name, args[i]);
                }
            }
        }

        // Process the quoted block, replacing unquote expressions
        var new_stmts: std.ArrayList(ast.Stmt) = .empty;
        for (quote.body) |stmt| {
            const expanded = try self.substituteStmt(stmt, &param_map);
            try new_stmts.append(self.allocator, expanded);
        }

        // If the quote body is a single expression, unwrap it
        const expanded_stmts = try new_stmts.toOwnedSlice(self.allocator);
        if (expanded_stmts.len == 1 and expanded_stmts[0] == .expr) {
            return expanded_stmts[0].expr;
        }

        // Otherwise wrap in a block expression
        return try self.create(ast.Expr, .{
            .block = .{
                .meta = quote.meta,
                .stmts = expanded_stmts,
            },
        });
    }

    fn substituteStmt(self: *MacroEngine, stmt: ast.Stmt, param_map: *std.AutoHashMap(ast.StringId, *const ast.Expr)) anyerror!ast.Stmt {
        switch (stmt) {
            .expr => |expr| {
                const substituted = try self.substituteExpr(expr, param_map);
                return .{ .expr = substituted };
            },
            .assignment => |assign| {
                const substituted = try self.substituteExpr(assign.value, param_map);
                return .{
                    .assignment = try self.create(ast.Assignment, .{
                        .meta = assign.meta,
                        .pattern = assign.pattern,
                        .value = substituted,
                    }),
                };
            },
            else => return stmt,
        }
    }

    fn substituteExpr(self: *MacroEngine, expr: *const ast.Expr, param_map: *std.AutoHashMap(ast.StringId, *const ast.Expr)) anyerror!*const ast.Expr {
        switch (expr.*) {
            .unquote_expr => |ue| {
                // Replace unquote(param_name) with the corresponding argument
                if (ue.expr.* == .var_ref) {
                    if (param_map.get(ue.expr.var_ref.name)) |arg| {
                        return arg;
                    }
                }
                // If unquote refers to something else, evaluate the inner expression
                return ue.expr;
            },

            .if_expr => |ie| {
                const cond = try self.substituteExpr(ie.condition, param_map);
                var then_stmts: std.ArrayList(ast.Stmt) = .empty;
                for (ie.then_block) |s| {
                    try then_stmts.append(self.allocator, try self.substituteStmt(s, param_map));
                }
                var else_stmts: ?[]const ast.Stmt = null;
                if (ie.else_block) |else_block| {
                    var es: std.ArrayList(ast.Stmt) = .empty;
                    for (else_block) |s| {
                        try es.append(self.allocator, try self.substituteStmt(s, param_map));
                    }
                    else_stmts = try es.toOwnedSlice(self.allocator);
                }
                return try self.create(ast.Expr, .{
                    .if_expr = .{
                        .meta = ie.meta,
                        .condition = cond,
                        .then_block = try then_stmts.toOwnedSlice(self.allocator),
                        .else_block = else_stmts,
                    },
                });
            },

            .call => |call| {
                const callee = try self.substituteExpr(call.callee, param_map);
                var new_args: std.ArrayList(*const ast.Expr) = .empty;
                for (call.args) |arg| {
                    try new_args.append(self.allocator, try self.substituteExpr(arg, param_map));
                }
                return try self.create(ast.Expr, .{
                    .call = .{
                        .meta = call.meta,
                        .callee = callee,
                        .args = try new_args.toOwnedSlice(self.allocator),
                    },
                });
            },

            .binary_op => |bo| {
                return try self.create(ast.Expr, .{
                    .binary_op = .{
                        .meta = bo.meta,
                        .op = bo.op,
                        .lhs = try self.substituteExpr(bo.lhs, param_map),
                        .rhs = try self.substituteExpr(bo.rhs, param_map),
                    },
                });
            },

            .unary_op => |uo| {
                return try self.create(ast.Expr, .{
                    .unary_op = .{
                        .meta = uo.meta,
                        .op = uo.op,
                        .operand = try self.substituteExpr(uo.operand, param_map),
                    },
                });
            },

            .var_ref => |vr| {
                // Apply hygiene: rename bindings introduced by macro
                // For now, pass through (full hygiene requires generation tracking)
                _ = vr;
                return expr;
            },

            // Leaf nodes — no substitution needed
            else => return expr,
        }
    }

    // ============================================================
    // Hygienic name generation
    // ============================================================

    pub fn generateHygienicName(self: *MacroEngine, base_name: ast.StringId) !ast.StringId {
        const base = self.interner.get(base_name);
        const gen_name = try std.fmt.allocPrint(self.allocator, "{s}__gen{d}", .{ base, self.generation });
        return self.interner.intern(gen_name);
    }

    // ============================================================
    // Macro lookup
    // ============================================================

    fn findMacro(self: *MacroEngine, name: ast.StringId, arity: u32) ?scope.MacroFamilyId {
        // Search all scopes for a matching macro
        for (self.graph.scopes.items, 0..) |_, scope_idx| {
            const sid: scope.ScopeId = @intCast(scope_idx);
            const key = scope.FamilyKey{ .name = name, .arity = arity };
            const s = self.graph.getScope(sid);
            if (s.macros.get(key)) |mid| {
                return mid;
            }
        }
        return null;
    }

    // ============================================================
    // Allocation helper
    // ============================================================

    fn create(self: *MacroEngine, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "macro engine no-op on program without macros" {
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

    var engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // No macros — program should be unchanged
    try std.testing.expectEqual(@as(usize, 1), expanded.top_items.len);
    try std.testing.expect(expanded.top_items[0] == .function);
}

test "macro engine expands simple macro" {
    // Define a macro and use it
    const source =
        \\defmodule Test do
        \\  defmacro unless(expr, body) do
        \\    quote do
        \\      if not unquote(expr) do
        \\        unquote(body)
        \\      end
        \\    end
        \\  end
        \\
        \\  def foo(x :: i64) :: i64 do
        \\    unless(x > 0, 42)
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

    var engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Module should still exist
    try std.testing.expectEqual(@as(usize, 1), expanded.modules.len);
    // No errors
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
}

test "macro engine hygiene generates unique names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    const graph = scope.ScopeGraph.init(alloc);
    _ = graph;
    var graph2 = scope.ScopeGraph.init(alloc);
    defer graph2.deinit();

    var engine = MacroEngine.init(alloc, &interner, &graph2);
    defer engine.deinit();

    const base = try interner.intern("temp");
    engine.generation = 1;
    const hygienic1 = try engine.generateHygienicName(base);
    engine.generation = 2;
    const hygienic2 = try engine.generateHygienicName(base);

    // Different generations should produce different names
    try std.testing.expect(hygienic1 != hygienic2);

    const name1 = interner.get(hygienic1);
    const name2 = interner.get(hygienic2);
    try std.testing.expectEqualStrings("temp__gen1", name1);
    try std.testing.expectEqualStrings("temp__gen2", name2);
}

test "macro engine reaches fixed point" {
    const source =
        \\def foo() do
        \\  42
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

    var engine = MacroEngine.init(alloc, &parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Should reach fixed point immediately (no macros to expand)
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), expanded.top_items.len);
}
