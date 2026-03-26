const std = @import("std");
const ast = @import("ast.zig");

// ============================================================
// Desugaring pass
//
// Runs after macro expansion, before name resolution.
// Transforms syntactic sugar into core forms:
//
//   1. Pipe `x |> f(y)` → `f(x, y)`
//   2. Unwrap `expr!` → `case expr do {:ok, v} -> v; {:error, e} -> panic(e) end`
//   3. String interpolation `"hello #{name}"` → `"hello " <> to_string(name)`
// ============================================================

pub const Desugarer = struct {
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    to_string_id: ?ast.StringId,

    pub fn init(allocator: std.mem.Allocator, interner: *ast.StringInterner) Desugarer {
        return .{
            .allocator = allocator,
            .interner = interner,
            .to_string_id = interner.intern("to_string") catch null,
        };
    }

    // ============================================================
    // Program desugaring
    // ============================================================

    pub fn desugarProgram(self: *Desugarer, program: *const ast.Program) !ast.Program {
        var new_modules: std.ArrayList(ast.ModuleDecl) = .empty;
        for (program.modules) |mod| {
            try new_modules.append(self.allocator, try self.desugarModule(&mod));
        }

        var new_top_items: std.ArrayList(ast.TopItem) = .empty;
        for (program.top_items) |item| {
            try new_top_items.append(self.allocator, try self.desugarTopItem(item));
        }

        return .{
            .modules = try new_modules.toOwnedSlice(self.allocator),
            .top_items = try new_top_items.toOwnedSlice(self.allocator),
        };
    }

    fn desugarModule(self: *Desugarer, mod: *const ast.ModuleDecl) !ast.ModuleDecl {
        var new_items: std.ArrayList(ast.ModuleItem) = .empty;
        for (mod.items) |item| {
            try new_items.append(self.allocator, try self.desugarModuleItem(item));
        }
        return .{
            .meta = mod.meta,
            .name = mod.name,
            .parent = mod.parent,
            .items = try new_items.toOwnedSlice(self.allocator),
        };
    }

    fn desugarTopItem(self: *Desugarer, item: ast.TopItem) !ast.TopItem {
        return switch (item) {
            .function => |func| .{ .function = try self.desugarFunctionDecl(func) },
            .priv_function => |func| .{ .priv_function = try self.desugarFunctionDecl(func) },
            .macro => |mac| .{ .macro = try self.desugarFunctionDecl(mac) },
            else => item,
        };
    }

    fn desugarModuleItem(self: *Desugarer, item: ast.ModuleItem) !ast.ModuleItem {
        return switch (item) {
            .function => |func| .{ .function = try self.desugarFunctionDecl(func) },
            .priv_function => |func| .{ .priv_function = try self.desugarFunctionDecl(func) },
            .macro => |mac| .{ .macro = try self.desugarFunctionDecl(mac) },
            else => item,
        };
    }

    // ============================================================
    // Function declaration desugaring
    // ============================================================

    fn desugarFunctionDecl(self: *Desugarer, func: *const ast.FunctionDecl) !*const ast.FunctionDecl {
        var new_clauses: std.ArrayList(ast.FunctionClause) = .empty;
        for (func.clauses) |clause| {
            try new_clauses.append(self.allocator, .{
                .meta = clause.meta,
                .params = clause.params,
                .return_type = clause.return_type,
                .refinement = if (clause.refinement) |r| try self.desugarExpr(r) else null,
                .body = try self.desugarBlock(clause.body),
            });
        }
        return try self.create(ast.FunctionDecl, .{
            .meta = func.meta,
            .name = func.name,
            .clauses = try new_clauses.toOwnedSlice(self.allocator),
            .visibility = func.visibility,
        });
    }

    // ============================================================
    // Block desugaring
    // ============================================================

    fn desugarBlock(self: *Desugarer, stmts: []const ast.Stmt) anyerror![]const ast.Stmt {
        var new_stmts: std.ArrayList(ast.Stmt) = .empty;
        for (stmts) |stmt| {
            try new_stmts.append(self.allocator, try self.desugarStmt(stmt));
        }
        return new_stmts.toOwnedSlice(self.allocator);
    }

    fn desugarStmt(self: *Desugarer, stmt: ast.Stmt) anyerror!ast.Stmt {
        return switch (stmt) {
            .expr => |expr| .{ .expr = try self.desugarExpr(expr) },
            .assignment => |assign| .{
                .assignment = try self.create(ast.Assignment, .{
                    .meta = assign.meta,
                    .pattern = assign.pattern,
                    .value = try self.desugarExpr(assign.value),
                }),
            },
            .function_decl => |func| .{ .function_decl = try self.desugarFunctionDecl(func) },
            .macro_decl => |mac| .{ .macro_decl = try self.desugarFunctionDecl(mac) },
            .import_decl => stmt,
        };
    }

    // ============================================================
    // Expression desugaring
    // ============================================================

    fn desugarExpr(self: *Desugarer, expr: *const ast.Expr) anyerror!*const ast.Expr {
        switch (expr.*) {
            // Pipe: x |> f(y) → f(x, y)
            .pipe => |pe| {
                const lhs = try self.desugarExpr(pe.lhs);
                const rhs = try self.desugarExpr(pe.rhs);
                return self.desugarPipe(lhs, rhs, pe.meta);
            },

            // Unwrap: expr! → optional force-unwrap (panics if nil)
            .unwrap => |ue| {
                const inner = try self.desugarExpr(ue.expr);
                return try self.create(ast.Expr, .{
                    .unwrap = .{ .meta = ue.meta, .expr = inner },
                });
            },

            // String interpolation: "hello #{name}" → "hello " <> to_string(name)
            .string_interpolation => |si| {
                return self.desugarStringInterpolation(&si);
            },

            // Recurse into compound expressions
            .binary_op => |bo| {
                return try self.create(ast.Expr, .{
                    .binary_op = .{
                        .meta = bo.meta,
                        .op = bo.op,
                        .lhs = try self.desugarExpr(bo.lhs),
                        .rhs = try self.desugarExpr(bo.rhs),
                    },
                });
            },
            .unary_op => |uo| {
                return try self.create(ast.Expr, .{
                    .unary_op = .{
                        .meta = uo.meta,
                        .op = uo.op,
                        .operand = try self.desugarExpr(uo.operand),
                    },
                });
            },
            .call => |call| {
                const callee = try self.desugarExpr(call.callee);
                var new_args: std.ArrayList(*const ast.Expr) = .empty;
                for (call.args) |arg| {
                    try new_args.append(self.allocator, try self.desugarExpr(arg));
                }
                return try self.create(ast.Expr, .{
                    .call = .{
                        .meta = call.meta,
                        .callee = callee,
                        .args = try new_args.toOwnedSlice(self.allocator),
                    },
                });
            },
            // if_expr, cond_expr, and with_expr are expanded to case by the
            // macro engine (Kernel macros / special forms) before desugaring.
            // They should not reach this point.
            .case_expr => |ce| {
                var new_clauses: std.ArrayList(ast.CaseClause) = .empty;
                for (ce.clauses) |clause| {
                    try new_clauses.append(self.allocator, .{
                        .meta = clause.meta,
                        .pattern = clause.pattern,
                        .type_annotation = clause.type_annotation,
                        .guard = if (clause.guard) |g| try self.desugarExpr(g) else null,
                        .body = try self.desugarBlock(clause.body),
                    });
                }
                return try self.create(ast.Expr, .{
                    .case_expr = .{
                        .meta = ce.meta,
                        .scrutinee = try self.desugarExpr(ce.scrutinee),
                        .clauses = try new_clauses.toOwnedSlice(self.allocator),
                    },
                });
            },
            .block => |blk| {
                return try self.create(ast.Expr, .{
                    .block = .{
                        .meta = blk.meta,
                        .stmts = try self.desugarBlock(blk.stmts),
                    },
                });
            },

            // Leaf/passthrough nodes
            else => return expr,
        }
    }

    // ============================================================
    // Pipe desugaring: x |> f(y) → f(x, y)
    // ============================================================

    fn desugarPipe(self: *Desugarer, lhs: *const ast.Expr, rhs: *const ast.Expr, meta: ast.NodeMeta) !*const ast.Expr {
        switch (rhs.*) {
            .call => |call| {
                // Insert lhs as first argument
                var new_args: std.ArrayList(*const ast.Expr) = .empty;
                try new_args.append(self.allocator, lhs);
                for (call.args) |arg| {
                    try new_args.append(self.allocator, arg);
                }
                return try self.create(ast.Expr, .{
                    .call = .{
                        .meta = meta,
                        .callee = call.callee,
                        .args = try new_args.toOwnedSlice(self.allocator),
                    },
                });
            },
            .var_ref => {
                // x |> f → f(x)
                var args: std.ArrayList(*const ast.Expr) = .empty;
                try args.append(self.allocator, lhs);
                return try self.create(ast.Expr, .{
                    .call = .{
                        .meta = meta,
                        .callee = rhs,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                });
            },
            else => {
                // Can't pipe into this expression, leave as-is
                return try self.create(ast.Expr, .{
                    .call = .{
                        .meta = meta,
                        .callee = rhs,
                        .args = &.{lhs},
                    },
                });
            },
        }
    }

    // ============================================================
    // Unwrap desugaring: expr! → case expr do {:ok, v} -> v; {:error, e} -> panic(e) end
    // ============================================================

    fn desugarUnwrap(self: *Desugarer, inner: *const ast.Expr, meta: ast.NodeMeta) !*const ast.Expr {
        const v_name = try self.interner.intern("__unwrap_val");
        const e_name = try self.interner.intern("__unwrap_err");
        const ok_name = try self.interner.intern("ok");
        const error_name = try self.interner.intern("error");

        // Pattern {:ok, v}
        const ok_pattern = try self.create(ast.Pattern, .{
            .tuple = .{
                .meta = meta,
                .elements = try self.allocSlice(*const ast.Pattern, &.{
                    try self.create(ast.Pattern, .{ .literal = .{ .atom = .{ .meta = meta, .value = ok_name } } }),
                    try self.create(ast.Pattern, .{ .bind = .{ .meta = meta, .name = v_name } }),
                }),
            },
        });

        // Pattern {:error, e}
        const error_pattern = try self.create(ast.Pattern, .{
            .tuple = .{
                .meta = meta,
                .elements = try self.allocSlice(*const ast.Pattern, &.{
                    try self.create(ast.Pattern, .{ .literal = .{ .atom = .{ .meta = meta, .value = error_name } } }),
                    try self.create(ast.Pattern, .{ .bind = .{ .meta = meta, .name = e_name } }),
                }),
            },
        });

        // Body for ok: v
        const ok_body = try self.allocSlice(ast.Stmt, &.{
            .{ .expr = try self.create(ast.Expr, .{ .var_ref = .{ .meta = meta, .name = v_name } }) },
        });

        // Body for error: panic(e)
        const e_ref = try self.create(ast.Expr, .{ .var_ref = .{ .meta = meta, .name = e_name } });
        const error_body = try self.allocSlice(ast.Stmt, &.{
            .{ .expr = try self.create(ast.Expr, .{
                .panic_expr = .{ .meta = meta, .message = e_ref },
            }) },
        });

        const clauses = try self.allocSlice(ast.CaseClause, &.{
            .{ .meta = meta, .pattern = ok_pattern, .type_annotation = null, .guard = null, .body = ok_body },
            .{ .meta = meta, .pattern = error_pattern, .type_annotation = null, .guard = null, .body = error_body },
        });

        return try self.create(ast.Expr, .{
            .case_expr = .{
                .meta = meta,
                .scrutinee = inner,
                .clauses = clauses,
            },
        });
    }

    // ============================================================
    // String interpolation desugaring
    // ============================================================

    fn desugarStringInterpolation(self: *Desugarer, si: *const ast.StringInterpolation) !*const ast.Expr {
        var result: ?*const ast.Expr = null;

        for (si.parts) |part| {
            const part_expr: *const ast.Expr = switch (part) {
                .literal => |str_id| try self.create(ast.Expr, .{
                    .string_literal = .{ .meta = si.meta, .value = str_id },
                }),
                .expr => |expr| blk: {
                    const desugared = try self.desugarExpr(expr);
                    // Wrap in to_string() call
                    if (self.to_string_id) |ts_id| {
                        const callee = try self.create(ast.Expr, .{
                            .var_ref = .{ .meta = si.meta, .name = ts_id },
                        });
                        break :blk try self.create(ast.Expr, .{
                            .call = .{
                                .meta = si.meta,
                                .callee = callee,
                                .args = try self.allocSlice(*const ast.Expr, &.{desugared}),
                            },
                        });
                    } else {
                        break :blk desugared;
                    }
                },
            };

            if (result) |prev| {
                result = try self.create(ast.Expr, .{
                    .binary_op = .{
                        .meta = si.meta,
                        .op = .concat,
                        .lhs = prev,
                        .rhs = part_expr,
                    },
                });
            } else {
                result = part_expr;
            }
        }

        return result orelse try self.create(ast.Expr, .{
            .string_literal = .{
                .meta = si.meta,
                .value = try self.interner.intern(""),
            },
        });
    }

    // ============================================================
    // Allocation helpers
    // ============================================================

    fn create(self: *Desugarer, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    fn allocSlice(self: *Desugarer, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

test "desugar pipe operator" {
    const source =
        \\defmodule Test do
        \\  def foo(x) do
        \\    x |> bar(1)
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared = try desugarer.desugarProgram(&program);

    // Function should now have a call instead of a pipe
    const func = desugared.modules[0].items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    // Should be a call expression (pipe was desugared)
    try std.testing.expect(body[0].expr.* == .call);
    // Call should have 2 args (x inserted as first arg)
    try std.testing.expectEqual(@as(usize, 2), body[0].expr.call.args.len);
}

test "desugar unwrap operator" {
    const source =
        \\defmodule Test do
        \\  def foo(x) do
        \\    bar(x)!
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared = try desugarer.desugarProgram(&program);

    // Function body should now have an unwrap expression (passed through)
    const func = desugared.modules[0].items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0].expr.* == .unwrap);
    // Inner expression should be the call
    try std.testing.expect(body[0].expr.unwrap.expr.* == .call);
}

test "desugar no-op on simple expressions" {
    const source =
        \\defmodule Test do
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

    var desugarer = Desugarer.init(alloc, &parser.interner);
    const desugared = try desugarer.desugarProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), desugared.modules.len);
    const func = desugared.modules[0].items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body[0].expr.* == .binary_op);
}
