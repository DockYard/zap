const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const ast_data = @import("ast_data.zig");
const ctfe = @import("ctfe.zig");

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
        // Validate macro type annotations before expansion
        try self.validateMacros();

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
                    // Try Kernel.fn macro first (Phase 5)
                    if (self.tryExpandDeclarationMacro("fn", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        // Bootstrap fallback: expand function body directly
                        const expanded = try self.expandFunctionDecl(func);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .function = expanded.decl });
                    }
                },
                .priv_function => |func| {
                    if (self.tryExpandDeclarationMacro("fn", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(func);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .priv_function = expanded.decl });
                    }
                },
                .macro => |mac| {
                    if (self.tryExpandDeclarationMacro("macro", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(mac);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .macro = expanded.decl });
                    }
                },
                .priv_macro => |mac| {
                    if (self.tryExpandDeclarationMacro("macro", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(mac);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .priv_macro = expanded.decl });
                    }
                },
                .struct_decl => {
                    // Try Kernel.struct macro (Phase 5)
                    if (self.tryExpandDeclarationMacro("struct", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        // Bootstrap fallback: pass through unchanged
                        try new_items.append(self.allocator, item);
                    }
                },
                .union_decl => {
                    // Try Kernel.union macro (Phase 5)
                    if (self.tryExpandDeclarationMacro("union", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        try new_items.append(self.allocator, item);
                    }
                },
                .use_decl => |ud| {
                    // Step 1: Always emit `import Module` for function access
                    const import_decl = try self.create(ast.ImportDecl, .{
                        .meta = ud.meta,
                        .module_path = ud.module_path,
                        .filter = null,
                    });
                    try new_items.append(self.allocator, .{ .import_decl = import_decl });
                    changed = true;

                    // Step 2: Look up Module.__using__/1 and inject returned items
                    if (self.tryExpandUsing(ud)) |using_items| {
                        for (using_items) |using_item| {
                            try new_items.append(self.allocator, using_item);
                        }
                    }
                },
                else => try new_items.append(self.allocator, item),
            }
        }

        // Also try expanding the module declaration itself through Kernel.module
        // (only if a Kernel macro for "module" exists)

        return .{
            .module = .{
                .meta = mod.meta,
                .name = mod.name,
                .parent = mod.parent,
                .items = try new_items.toOwnedSlice(self.allocator),
                .is_private = mod.is_private,
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
            .priv_macro => |mac| {
                const expanded = try self.expandFunctionDecl(mac);
                return .{ .item = .{ .priv_macro = expanded.decl }, .changed = expanded.changed };
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
            if (clause.body) |body| {
                const expanded = try self.expandBlock(body);
                if (expanded.changed) changed = true;
                try new_clauses.append(self.allocator, .{
                    .meta = clause.meta,
                    .params = clause.params,
                    .return_type = clause.return_type,
                    .refinement = clause.refinement,
                    .body = expanded.stmts,
                });
            } else {
                // @native bodyless declaration — pass through unchanged
                try new_clauses.append(self.allocator, clause);
            }
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

            // Unquote/unquote_splicing outside of quote is an error
            .unquote_expr, .unquote_splicing_expr => {
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
                // Bootstrap fallback: expand if to case.
                // Kernel.if macro provides the same behavior but allows user override.
                const cond_exp = (try self.expandExpr(ie.condition)).expr;
                const true_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = ie.meta, .value = true } } });
                const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = ie.meta, .value = false } } });

                var then_stmts: std.ArrayList(ast.Stmt) = .empty;
                for (ie.then_block) |s| try then_stmts.append(self.allocator, s);
                const then_body = try then_stmts.toOwnedSlice(self.allocator);

                var else_body: []const ast.Stmt = undefined;
                if (ie.else_block) |else_block| {
                    var es: std.ArrayList(ast.Stmt) = .empty;
                    for (else_block) |s| try es.append(self.allocator, s);
                    else_body = try es.toOwnedSlice(self.allocator);
                } else {
                    const nil_expr = try self.create(ast.Expr, .{ .nil_literal = .{ .meta = ie.meta } });
                    else_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = nil_expr }});
                }

                const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                clauses[0] = .{ .meta = ie.meta, .pattern = true_pat, .type_annotation = null, .guard = null, .body = then_body };
                clauses[1] = .{ .meta = ie.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = else_body };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .case_expr = .{ .meta = ie.meta, .scrutinee = cond_exp, .clauses = clauses },
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
                // Try Kernel operator macro first
                const macro_name = binopMacroName(bo.op);
                if (self.tryExpandBinaryMacro(macro_name, bo.lhs, bo.rhs, bo.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }
                if (self.tryExpandBinaryMacro(macro_name, bo.lhs, bo.rhs, bo.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                // Bootstrap fallback: and/or get short-circuit case expansion
                // (Kernel.and/or macros take precedence when available)
                if (bo.op == .and_op) {
                    const lhs_exp = (try self.expandExpr(bo.lhs)).expr;
                    const rhs_exp = (try self.expandExpr(bo.rhs)).expr;
                    const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = bo.meta, .value = false } } });
                    const wild_pat = try self.create(ast.Pattern, .{ .wildcard = .{ .meta = bo.meta } });
                    const false_expr = try self.create(ast.Expr, .{ .bool_literal = .{ .meta = bo.meta, .value = false } });
                    const false_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = false_expr }});
                    const rhs_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = rhs_exp }});
                    const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                    clauses[0] = .{ .meta = bo.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = false_body };
                    clauses[1] = .{ .meta = bo.meta, .pattern = wild_pat, .type_annotation = null, .guard = null, .body = rhs_body };
                    return .{ .expr = try self.create(ast.Expr, .{ .case_expr = .{ .meta = bo.meta, .scrutinee = lhs_exp, .clauses = clauses } }), .changed = true };
                }
                if (bo.op == .or_op) {
                    const lhs_exp = (try self.expandExpr(bo.lhs)).expr;
                    const rhs_exp = (try self.expandExpr(bo.rhs)).expr;
                    const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = bo.meta, .value = false } } });
                    const wild_pat = try self.create(ast.Pattern, .{ .wildcard = .{ .meta = bo.meta } });
                    const rhs_body2 = try self.allocSlice(ast.Stmt, &.{.{ .expr = rhs_exp }});
                    const lhs_body2 = try self.allocSlice(ast.Stmt, &.{.{ .expr = lhs_exp }});
                    const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                    clauses[0] = .{ .meta = bo.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = rhs_body2 };
                    clauses[1] = .{ .meta = bo.meta, .pattern = wild_pat, .type_annotation = null, .guard = null, .body = lhs_body2 };
                    return .{ .expr = try self.create(ast.Expr, .{ .case_expr = .{ .meta = bo.meta, .scrutinee = lhs_exp, .clauses = clauses } }), .changed = true };
                }

                // Bootstrap fallback: other operators pass through with recursive expansion
                const lhs = try self.expandExpr(bo.lhs);
                const rhs = try self.expandExpr(bo.rhs);
                if (!lhs.changed and !rhs.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .binary_op = .{ .meta = bo.meta, .op = bo.op, .lhs = lhs.expr, .rhs = rhs.expr },
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
                // Try Kernel.|> macro first
                if (self.tryExpandBinaryMacro("|>", pe.lhs, pe.rhs, pe.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                // Bootstrap fallback: desugar pipe directly
                const lhs = (try self.expandExpr(pe.lhs)).expr;
                const rhs = (try self.expandExpr(pe.rhs)).expr;

                switch (rhs.*) {
                    .call => |call| {
                        // x |> f(y) → f(x, y) — inject lhs as first arg
                        var new_args: std.ArrayList(*const ast.Expr) = .empty;
                        try new_args.append(self.allocator, lhs);
                        for (call.args) |arg| {
                            try new_args.append(self.allocator, arg);
                        }
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = call.callee,
                                    .args = try new_args.toOwnedSlice(self.allocator),
                                },
                            }),
                            .changed = true,
                        };
                    },
                    .var_ref => {
                        // x |> f → f(x)
                        const args = try self.allocSlice(*const ast.Expr, &.{lhs});
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = rhs,
                                    .args = args,
                                },
                            }),
                            .changed = true,
                        };
                    },
                    else => {
                        // Fallback: treat as f(x)
                        const args = try self.allocSlice(*const ast.Expr, &.{lhs});
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = rhs,
                                    .args = args,
                                },
                            }),
                            .changed = true,
                        };
                    },
                }
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

            .unwrap => |ue| {
                const inner = try self.expandExpr(ue.expr);
                if (!inner.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .unwrap = .{ .meta = ue.meta, .expr = inner.expr },
                    }),
                    .changed = true,
                };
            },

            .cond_expr => |conde| {
                // Bootstrap fallback: expand cond to nested case.
                // Kernel.cond macro (if defined) provides the same behavior.
                return .{
                    .expr = try self.condToNestedCase(conde.clauses, conde.meta),
                    .changed = true,
                };
            },

            .type_annotated => |ta| {
                const inner = try self.expandExpr(ta.expr);
                if (!inner.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .type_annotated = .{
                            .meta = ta.meta,
                            .expr = inner.expr,
                            .type_expr = ta.type_expr,
                        },
                    }),
                    .changed = true,
                };
            },

            // For comprehension — recurse into iterable, filter, body
            .for_expr => |fe| {
                var changed = false;
                const iterable = try self.expandExpr(fe.iterable);
                if (iterable.changed) changed = true;
                const filter = if (fe.filter) |f| blk: {
                    const exp = try self.expandExpr(f);
                    if (exp.changed) changed = true;
                    break :blk exp.expr;
                } else null;
                const body = try self.expandExpr(fe.body);
                if (body.changed) changed = true;
                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .for_expr = .{
                            .meta = fe.meta,
                            .var_name = fe.var_name,
                            .iterable = iterable.expr,
                            .filter = filter,
                            .body = body.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            // List cons expression — recurse into head and tail
            .list_cons_expr => |lc| {
                var changed = false;
                const head = try self.expandExpr(lc.head);
                if (head.changed) changed = true;
                const tail = try self.expandExpr(lc.tail);
                if (tail.changed) changed = true;
                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .list_cons_expr = .{
                            .meta = lc.meta,
                            .head = head.expr,
                            .tail = tail.expr,
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
            .function_ref,
            .panic_expr,
            .intrinsic,
            .attr_ref,
            .binary_literal,
            .error_pipe,
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

        // Fast path: bare quote body → use Phase 2 template expansion
        if ((clause.body orelse &.{}).len == 1 and (clause.body orelse &.{})[0] == .expr) {
            const body_expr = (clause.body orelse &.{})[0].expr;
            if (body_expr.* == .quote_expr) {
                self.generation += 1;
                return try self.expandQuote(body_expr, call.args, clause.params);
            }
        }

        // Phase 3: evaluate macro body as a function using the macro evaluator.
        // Convert the body and args to CtValue, run the evaluator, convert back.
        {
            const macro_eval = @import("macro_eval.zig");
            var store = ctfe.AllocationStore{};
            var env = macro_eval.Env.init(self.allocator, &store);
            defer env.deinit();

            // Bind macro parameters to CtValue representations of the arguments
            for (clause.params, 0..) |param, i| {
                if (i < call.args.len) {
                    if (param.pattern.* == .bind) {
                        const param_name = self.interner.get(param.pattern.bind.name);
                        const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, call.args[i]);
                        try env.bind(param_name, arg_ct);
                    }
                }
            }

            // Convert body statements to CtValue and evaluate them
            var result: ctfe.CtValue = .nil;
            for (clause.body orelse &.{}) |stmt| {
                const stmt_ct = try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt);
                result = macro_eval.eval(&env, stmt_ct) catch .nil;
            }

            // Convert the result back to ast.Expr
            if (result != .nil) {
                return ast_data.ctValueToExpr(self.allocator, self.interner, result) catch expr;
            }
        }

        return expr;
    }

    // ============================================================
    // Quote expansion with unquote substitution
    // ============================================================

    fn expandQuote(self: *MacroEngine, quote_expr: *const ast.Expr, args: []const *const ast.Expr, params: []const ast.Param) anyerror!*const ast.Expr {
        const quote = quote_expr.quote_expr;

        // Phase 2: Work through the CtValue data representation.
        // 1. Convert quoted body to CtValue tuples
        // 2. Build param name → CtValue arg mapping
        // 3. Walk CtValue tree substituting :unquote nodes
        // 4. Convert result back to ast.Expr

        var store = ctfe.AllocationStore{};

        // Convert each statement in the quote body to CtValue
        var body_vals = std.ArrayListUnmanaged(ctfe.CtValue){};
        for (quote.body) |stmt| {
            try body_vals.append(self.allocator, try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt));
        }

        // Build parameter name (string) → CtValue argument mapping
        var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
        defer param_map.deinit();

        for (params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    const name = self.interner.get(param.pattern.bind.name);
                    const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]);
                    try param_map.put(name, arg_ct);
                }
            }
        }

        // Substitute :unquote nodes in the CtValue tree
        var substituted_vals = std.ArrayListUnmanaged(ctfe.CtValue){};
        for (body_vals.items) |val| {
            try substituted_vals.append(self.allocator, try self.substituteCtValue(val, &param_map, &store));
        }

        // Convert back to ast.Expr
        if (substituted_vals.items.len == 1) {
            return ast_data.ctValueToExpr(self.allocator, self.interner, substituted_vals.items[0]);
        }

        // Multiple statements → wrap in block
        var stmts = std.ArrayListUnmanaged(ast.Stmt){};
        for (substituted_vals.items) |val| {
            const expr = try ast_data.ctValueToExpr(self.allocator, self.interner, val);
            try stmts.append(self.allocator, .{ .expr = expr });
        }
        return try self.create(ast.Expr, .{
            .block = .{
                .meta = quote.meta,
                .stmts = try stmts.toOwnedSlice(self.allocator),
            },
        });
    }

    /// Walk a CtValue tree, replacing {:unquote, _, [name]} nodes with
    /// the corresponding argument value from param_map.
    fn substituteCtValue(
        self: *MacroEngine,
        value: ctfe.CtValue,
        param_map: *std.StringHashMap(ctfe.CtValue),
        store: *ctfe.AllocationStore,
    ) anyerror!ctfe.CtValue {
        // Check if this is an :unquote node: {atom("unquote"), meta, [inner]}
        if (value == .tuple and value.tuple.elems.len == 3) {
            const form = value.tuple.elems[0];
            const args = value.tuple.elems[2];

            if (form == .atom and std.mem.eql(u8, form.atom, "unquote")) {
                if (args == .list and args.list.elems.len == 1) {
                    const inner = args.list.elems[0];
                    // If inner is a variable reference {:name, _, nil}, look up in param_map
                    if (inner == .tuple and inner.tuple.elems.len == 3) {
                        if (inner.tuple.elems[0] == .atom and inner.tuple.elems[2] == .nil) {
                            const var_name = inner.tuple.elems[0].atom;
                            if (param_map.get(var_name)) |replacement| {
                                return replacement;
                            }
                        }
                    }
                    // Not a param reference — return the inner value as-is
                    return inner;
                }
            }

            // Recurse into 3-tuple children
            const new_args = if (args == .list) blk: {
                var new_elems = try self.allocator.alloc(ctfe.CtValue, args.list.elems.len);
                for (args.list.elems, 0..) |elem, i| {
                    new_elems[i] = try self.substituteCtValue(elem, param_map, store);
                }
                const id = store.alloc(self.allocator, .list, null);
                break :blk ctfe.CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
            } else args;

            const new_tuple = try self.allocator.alloc(ctfe.CtValue, 3);
            new_tuple[0] = value.tuple.elems[0]; // form stays
            new_tuple[1] = value.tuple.elems[1]; // meta stays
            new_tuple[2] = new_args;
            const id = store.alloc(self.allocator, .tuple, null);
            return ctfe.CtValue{ .tuple = .{ .alloc_id = id, .elems = new_tuple } };
        }

        // Recurse into 2-tuples (keyword pairs like {:do, value})
        if (value == .tuple and value.tuple.elems.len == 2) {
            const new_elems = try self.allocator.alloc(ctfe.CtValue, 2);
            new_elems[0] = value.tuple.elems[0]; // key stays
            new_elems[1] = try self.substituteCtValue(value.tuple.elems[1], param_map, store);
            const id = store.alloc(self.allocator, .tuple, null);
            return ctfe.CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
        }

        // Recurse into bare lists — with unquote_splicing support
        if (value == .list) {
            var result_elems = std.ArrayListUnmanaged(ctfe.CtValue){};
            var changed = false;
            for (value.list.elems) |elem| {
                // Check for unquote_splicing: {:unquote_splicing, _, [list_expr]}
                if (elem == .tuple and elem.tuple.elems.len == 3) {
                    if (elem.tuple.elems[0] == .atom and std.mem.eql(u8, elem.tuple.elems[0].atom, "unquote_splicing")) {
                        if (elem.tuple.elems[2] == .list and elem.tuple.elems[2].list.elems.len == 1) {
                            const inner = elem.tuple.elems[2].list.elems[0];
                            // If inner is a variable, look up in param_map
                            if (inner == .tuple and inner.tuple.elems.len == 3 and inner.tuple.elems[0] == .atom and inner.tuple.elems[2] == .nil) {
                                if (param_map.get(inner.tuple.elems[0].atom)) |replacement| {
                                    // Splice the replacement list into our result
                                    if (replacement == .list) {
                                        for (replacement.list.elems) |splice_elem| {
                                            try result_elems.append(self.allocator, splice_elem);
                                        }
                                        changed = true;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
                const substituted = try self.substituteCtValue(elem, param_map, store);
                if (!substituted.eql(elem)) changed = true;
                try result_elems.append(self.allocator, substituted);
            }
            if (!changed) return value;
            const new_elems = try result_elems.toOwnedSlice(self.allocator);
            const id = store.alloc(self.allocator, .list, null);
            return ctfe.CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
        }

        // Leaf values — no substitution
        return value;
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
    // Operator and pipe macro expansion
    // ============================================================

    /// Map a binary operator to its Kernel macro name.
    fn binopMacroName(op: ast.BinaryOp.Op) []const u8 {
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
        };
    }

    /// Try to expand a binary expression (operator or pipe) through a Kernel macro.
    /// Returns the expanded expression, or null if no macro found (falls to bootstrap).
    fn tryExpandBinaryMacro(
        self: *MacroEngine,
        macro_name: []const u8,
        lhs: *const ast.Expr,
        rhs: *const ast.Expr,
        meta: ast.NodeMeta,
    ) ?*const ast.Expr {
        const name_id = self.interner.intern(macro_name) catch return null;
        const macro_id = self.findMacro(name_id, 2) orelse return null;

        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Skip identity macros (quote { unquote(left) OP unquote(right) })
        // to avoid infinite expansion loops
        if ((clause.body orelse &.{}).len == 1 and (clause.body orelse &.{})[0] == .expr) {
            const body_expr = (clause.body orelse &.{})[0].expr;
            if (body_expr.* == .quote_expr) {
                const qbody = body_expr.quote_expr.body;
                // Identity check: single binary_op or pipe with both sides unquoted
                if (qbody.len == 1 and qbody[0] == .expr) {
                    const qexpr = qbody[0].expr;
                    if (qexpr.* == .binary_op) {
                        if (qexpr.binary_op.lhs.* == .unquote_expr and qexpr.binary_op.rhs.* == .unquote_expr) {
                            return null; // Identity — skip
                        }
                    }
                    if (qexpr.* == .pipe) {
                        if (qexpr.pipe.lhs.* == .unquote_expr and qexpr.pipe.rhs.* == .unquote_expr) {
                            return null; // Identity — skip
                        }
                    }
                }
            }
        }

        // Non-identity macro — convert args to CtValue, expand through template or evaluator
        var store = ctfe.AllocationStore{};
        const lhs_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, lhs) catch return null;
        const rhs_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, rhs) catch return null;
        _ = meta;

        if ((clause.body orelse &.{}).len == 1 and (clause.body orelse &.{})[0] == .expr) {
            const body_expr = (clause.body orelse &.{})[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro
                var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer param_map.deinit();
                if (clause.params.len >= 1 and clause.params[0].pattern.* == .bind) {
                    param_map.put(self.interner.get(clause.params[0].pattern.bind.name), lhs_ct) catch return null;
                }
                if (clause.params.len >= 2 and clause.params[1].pattern.* == .bind) {
                    param_map.put(self.interner.get(clause.params[1].pattern.bind.name), rhs_ct) catch return null;
                }

                var body_vals = std.ArrayListUnmanaged(ctfe.CtValue){};
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                if (body_vals.items.len == 1) {
                    const interner_mut: *ast.StringInterner = @constCast(self.interner);
                    return ast_data.ctValueToExpr(self.allocator, interner_mut, body_vals.items[0]) catch null;
                }
            }
        }

        // Non-template macro body — evaluate through CTFE evaluator
        {
            const macro_eval = @import("macro_eval.zig");
            var env = macro_eval.Env.init(self.allocator, &store);
            defer env.deinit();

            // Bind params to CtValue arg representations
            if (clause.params.len >= 1 and clause.params[0].pattern.* == .bind) {
                env.bind(self.interner.get(clause.params[0].pattern.bind.name), lhs_ct) catch return null;
            }
            if (clause.params.len >= 2 and clause.params[1].pattern.* == .bind) {
                env.bind(self.interner.get(clause.params[1].pattern.bind.name), rhs_ct) catch return null;
            }

            // Evaluate the macro body
            var result: ctfe.CtValue = .nil;
            for (clause.body orelse &.{}) |stmt| {
                const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                result = macro_eval.eval(&env, stmt_ct) catch return null;
            }

            if (result != .nil) {
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                return ast_data.ctValueToExpr(self.allocator, interner_mut, result) catch null;
            }
        }

        return null;
    }

    // ============================================================
    // Macro lookup
    // ============================================================

    /// Try to expand a declaration (fn/macro/struct) through a Kernel macro.
    /// Returns the expanded ModuleItem if a Kernel macro exists, null otherwise.
    /// When null, the caller should use the bootstrap fallback.
    fn tryExpandDeclarationMacro(self: *MacroEngine, form_name: []const u8, item: ast.ModuleItem) ?ast.ModuleItem {
        // Look up a Kernel macro with the declaration form name (fn, module, struct, macro)
        const name_id = self.interner.intern(form_name) catch return null;
        const macro_id = self.findMacro(name_id, 1) orelse return null;

        // Found a Kernel declaration macro.
        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Skip identity macros: `quote { unquote(arg) }` — these just pass through
        // and the CtValue round-trip can lose information. Only expand macros that
        // do real work (non-trivial body).
        const clause_body = clause.body orelse return null;
        if (clause_body.len == 1 and clause_body[0] == .expr) {
            const body_expr = clause_body[0].expr;
            if (body_expr.* == .quote_expr) {
                const qbody = body_expr.quote_expr.body;
                if (qbody.len == 1 and qbody[0] == .expr and qbody[0].expr.* == .unquote_expr) {
                    // Identity macro: `quote { unquote(decl) }` — skip expansion
                    return null;
                }
            }
        }

        // Non-identity macro — convert declaration to CtValue and evaluate
        var store = ctfe.AllocationStore{};
        const item_ct = ast_data.moduleItemToCtValue(self.allocator, self.interner, &store, item) catch return null;

        if ((clause.body orelse &.{}).len == 1 and (clause.body orelse &.{})[0] == .expr) {
            const body_expr = (clause.body orelse &.{})[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro with real transformation
                var decl_param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer decl_param_map.deinit();
                for (clause.params) |param| {
                    if (param.pattern.* == .bind) {
                        const pname = self.interner.get(param.pattern.bind.name);
                        decl_param_map.put(pname, item_ct) catch return null;
                    }
                }

                var body_vals = std.ArrayListUnmanaged(ctfe.CtValue){};
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &decl_param_map, &store) catch return null) catch return null;
                }

                const result_ct = if (body_vals.items.len == 1) body_vals.items[0] else return null;
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                return ast_data.ctValueToModuleItem(self.allocator, interner_mut, result_ct) catch return null;
            }
        }

        // Non-template macro body — use the evaluator
        const macro_eval = @import("macro_eval.zig");
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();

        for (clause.params) |param| {
            if (param.pattern.* == .bind) {
                const pname = self.interner.get(param.pattern.bind.name);
                env.bind(pname, item_ct) catch return null;
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause.body orelse &.{}) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        if (result != .nil) {
            const interner_mut: *ast.StringInterner = @constCast(self.interner);
            return ast_data.ctValueToModuleItem(self.allocator, interner_mut, result) catch return null;
        }
        return null;
    }

    /// Try to expand `use Module` by calling Module.__using__/1.
    /// Returns injected module items if __using__ exists, null otherwise.
    fn tryExpandUsing(self: *MacroEngine, ud: *const ast.UseDecl) ?[]const ast.ModuleItem {
        // Build the __using__ name
        const using_name = self.interner.intern("__using__") catch return null;

        // Look up __using__ macro with arity 1
        const macro_id = self.findMacro(using_name, 1) orelse return null;

        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Build the opts argument: use the opts from UseDecl, or nil if none
        var store = ctfe.AllocationStore{};
        const opts_ct: ctfe.CtValue = if (ud.opts) |opts|
            ast_data.exprToCtValue(self.allocator, self.interner, &store, opts) catch return null
        else
            .nil;

        // Evaluate the __using__ macro body
        if ((clause.body orelse &.{}).len == 1 and (clause.body orelse &.{})[0] == .expr) {
            const body_expr = (clause.body orelse &.{})[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro: substitute opts into quote body
                var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer param_map.deinit();
                for (clause.params) |param| {
                    if (param.pattern.* == .bind) {
                        const pname = self.interner.get(param.pattern.bind.name);
                        param_map.put(pname, opts_ct) catch return null;
                    }
                }

                var body_vals = std.ArrayListUnmanaged(ctfe.CtValue){};
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                // Convert each result value to a module item
                var items: std.ArrayList(ast.ModuleItem) = .empty;
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                for (body_vals.items) |val| {
                    if (ast_data.ctValueToModuleItem(self.allocator, interner_mut, val) catch null) |mi| {
                        items.append(self.allocator, mi) catch return null;
                    }
                }
                return items.toOwnedSlice(self.allocator) catch return null;
            }
        }

        // Non-template macro body — use the evaluator
        const macro_eval = @import("macro_eval.zig");
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();

        for (clause.params) |param| {
            if (param.pattern.* == .bind) {
                const pname = self.interner.get(param.pattern.bind.name);
                env.bind(pname, opts_ct) catch return null;
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause.body orelse &.{}) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        if (result != .nil) {
            const interner_mut: *ast.StringInterner = @constCast(self.interner);
            // Result could be a single item or a block of items
            if (result == .tuple and result.tuple.elems.len == 3) {
                if (ast_data.ctValueToModuleItem(self.allocator, interner_mut, result) catch null) |mi| {
                    const items = self.allocator.alloc(ast.ModuleItem, 1) catch return null;
                    items[0] = mi;
                    return items;
                }
            }
            // Try as a list of items
            if (result == .list) {
                var items: std.ArrayList(ast.ModuleItem) = .empty;
                for (result.list.elems) |elem| {
                    if (ast_data.ctValueToModuleItem(self.allocator, interner_mut, elem) catch null) |mi| {
                        items.append(self.allocator, mi) catch return null;
                    }
                }
                return items.toOwnedSlice(self.allocator) catch return null;
            }
        }
        return null;
    }

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
    // Macro type validation
    // ============================================================

    /// Validate type annotations on macro definitions.
    /// Called before expansion to catch type errors early.
    fn validateMacros(self: *MacroEngine) !void {
        for (self.graph.macro_families.items) |family| {
            for (family.clauses.items) |clause_ref| {
                const clause = &clause_ref.decl.clauses[clause_ref.clause_index];
                const return_type = clause.return_type orelse continue;

                // Only validate macros with a quote body
                const body = clause.body orelse continue;
                if (body.len != 1) continue;
                switch (body[0]) {
                    .expr => |body_expr| {
                        switch (body_expr.*) {
                            .quote_expr => |qe| {
                                try self.validateQuoteBody(qe.body, return_type, clause.params);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Check that all terminal expressions in a quote body are compatible
    /// with the declared return type.
    fn validateQuoteBody(
        self: *MacroEngine,
        body: []const ast.Stmt,
        return_type: *const ast.TypeExpr,
        params: []const ast.Param,
    ) anyerror!void {
        if (body.len == 0) return;
        switch (body[body.len - 1]) {
            .expr => |expr| try self.validateTerminalExpr(expr, return_type, params),
            else => {},
        }
    }

    /// Validate that a terminal expression is compatible with the expected return type.
    fn validateTerminalExpr(
        self: *MacroEngine,
        expr: *const ast.Expr,
        return_type: *const ast.TypeExpr,
        params: []const ast.Param,
    ) anyerror!void {
        switch (expr.*) {
            .nil_literal => |nl| {
                if (!self.typeAllowsNil(return_type)) {
                    const type_name = self.getTypeName(return_type);
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "macro body returns 'nil' but declared return type is '{s}'",
                        .{type_name},
                    );
                    try self.errors.append(self.allocator, .{
                        .message = msg,
                        .span = nl.meta.span,
                    });
                }
            },
            .if_expr => |ie| {
                // Both branches must be compatible with the return type
                try self.validateQuoteBody(ie.then_block, return_type, params);
                if (ie.else_block) |else_block| {
                    try self.validateQuoteBody(else_block, return_type, params);
                } else {
                    // No else branch implicitly returns nil
                    if (!self.typeAllowsNil(return_type)) {
                        const type_name = self.getTypeName(return_type);
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "macro if-expression without else implicitly returns 'nil' but declared return type is '{s}'",
                            .{type_name},
                        );
                        try self.errors.append(self.allocator, .{
                            .message = msg,
                            .span = ie.meta.span,
                        });
                    }
                }
            },
            .unquote_expr => |ue| {
                // If unquoting a typed param, check param type against return type
                switch (ue.expr.*) {
                    .var_ref => |vr| {
                        for (params) |param| {
                            switch (param.pattern.*) {
                                .bind => |bind| {
                                    if (bind.name == vr.name) {
                                        if (param.type_annotation) |param_type| {
                                            if (!self.typesMatch(param_type, return_type)) {
                                                const pt = self.getTypeName(param_type);
                                                const rt = self.getTypeName(return_type);
                                                const msg = try std.fmt.allocPrint(
                                                    self.allocator,
                                                    "unquoted parameter type '{s}' does not match declared return type '{s}'",
                                                    .{ pt, rt },
                                                );
                                                try self.errors.append(self.allocator, .{
                                                    .message = msg,
                                                    .span = ue.meta.span,
                                                });
                                            }
                                        }
                                        break;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
            .unquote_splicing_expr => {
                // Splicing in return position — treated same as unquote for type validation
            },
            // For other expression types (binary_op, call, var_ref, literals),
            // we cannot determine types at the AST level — the type checker
            // will catch mismatches after expansion.
            else => {},
        }
    }

    /// Check if a type expression allows nil values.
    fn typeAllowsNil(self: *MacroEngine, type_expr: *const ast.TypeExpr) bool {
        switch (type_expr.*) {
            .name => |n| {
                const name = self.interner.get(n.name);
                return std.mem.eql(u8, name, "nil") or std.mem.eql(u8, name, "Nil");
            },
            .literal => |lit| {
                return lit.value == .nil;
            },
            .union_type => |u| {
                for (u.members) |member| {
                    if (self.typeAllowsNil(member)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if type `a` is compatible with type `b`.
    /// For union return types, `a` is compatible if it is a member of the union.
    fn typesMatch(self: *MacroEngine, a: *const ast.TypeExpr, b: *const ast.TypeExpr) bool {
        // Expr is a macro meta-type — it's compatible with any type
        if (self.isExprType(a) or self.isExprType(b)) return true;

        switch (b.*) {
            .union_type => |u| {
                // a is compatible if it matches any member of the union
                for (u.members) |member| {
                    if (self.typesMatch(a, member)) return true;
                }
                return false;
            },
            .name => |bn| {
                switch (a.*) {
                    .name => |an| return an.name == bn.name,
                    else => return false,
                }
            },
            .literal => |bl| {
                switch (a.*) {
                    .literal => |al| return std.meta.activeTag(al.value) == std.meta.activeTag(bl.value),
                    else => return false,
                }
            },
            else => return true, // For complex types, assume compatible
        }
    }

    /// Check if a type expression is the special macro meta-type `Expr`.
    fn isExprType(self: *MacroEngine, type_expr: *const ast.TypeExpr) bool {
        switch (type_expr.*) {
            .name => |n| return std.mem.eql(u8, self.interner.get(n.name), "Expr"),
            else => return false,
        }
    }

    /// Get a human-readable name for a type expression.
    fn getTypeName(self: *MacroEngine, type_expr: *const ast.TypeExpr) []const u8 {
        switch (type_expr.*) {
            .name => |n| return self.interner.get(n.name),
            .literal => |lit| {
                return switch (lit.value) {
                    .nil => "nil",
                    .bool_val => "Bool",
                    .int => "integer",
                    .string => "String",
                };
            },
            else => return "<complex type>",
        }
    }

    // ============================================================
    // Special form helpers
    // ============================================================

    /// Convert a block (slice of statements) to a single expression.
    /// Single-expression blocks return the expression directly.
    /// Multi-statement blocks are wrapped in a block expression.
    fn blockToExpr(self: *MacroEngine, stmts: []const ast.Stmt, meta: ast.NodeMeta) !*const ast.Expr {
        if (stmts.len == 1) {
            switch (stmts[0]) {
                .expr => |e| return e,
                else => {},
            }
        }
        return try self.create(ast.Expr, .{
            .block = .{ .meta = meta, .stmts = stmts },
        });
    }

    /// Convert cond clauses to nested if() calls.
    /// cond do c1 -> b1; c2 -> b2 end → if(c1, b1, if(c2, b2, nil))
    fn condToNestedCase(self: *MacroEngine, clauses: []const ast.CondClause, meta: ast.NodeMeta) anyerror!*const ast.Expr {
        if (clauses.len == 0) {
            return try self.create(ast.Expr, .{ .nil_literal = .{ .meta = meta } });
        }

        const clause = clauses[0];
        const true_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = meta, .value = true } } });
        const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = meta, .value = false } } });

        // Then body
        var then_stmts: std.ArrayList(ast.Stmt) = .empty;
        for (clause.body) |s| try then_stmts.append(self.allocator, s);

        // Else body: recursively expand remaining clauses
        const rest = try self.condToNestedCase(clauses[1..], meta);
        const else_stmts = try self.allocSlice(ast.Stmt, &.{.{ .expr = rest }});

        const case_clauses = try self.allocator.alloc(ast.CaseClause, 2);
        case_clauses[0] = .{ .meta = meta, .pattern = true_pat, .type_annotation = null, .guard = null, .body = try then_stmts.toOwnedSlice(self.allocator) };
        case_clauses[1] = .{ .meta = meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = else_stmts };

        return try self.create(ast.Expr, .{
            .case_expr = .{ .meta = meta, .scrutinee = clause.condition, .clauses = case_clauses },
        });
    }

    // ============================================================
    // Allocation helpers
    // ============================================================

    fn create(self: *MacroEngine, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    fn allocSlice(self: *MacroEngine, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "macro engine no-op on program without macros" {
    const source =
        \\pub module Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // No macros — program should be unchanged
    try std.testing.expectEqual(@as(usize, 1), expanded.modules.len);
    try std.testing.expect(expanded.modules[0].items[0] == .function);
}

test "macro engine expands simple macro" {
    // Define a macro and use it
    const source =
        \\pub module Test {
        \\  pub macro unless(expr, body) {
        \\    quote {
        \\      if not unquote(expr) {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> i64 {
        \\    unless(x > 0, 42)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
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
        \\pub module Test {
        \\  pub fn foo() {
        \\    42
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Should reach fixed point immediately (no macros to expand)
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), expanded.modules.len);
}

test "typed macro: nil in String return position is an error" {
    const source =
        \\pub module Test {
        \\  pub macro when_positive(value :: i64, result :: String) -> String {
        \\    quote {
        \\      if unquote(value) > 0 {
        \\        unquote(result)
        \\      } else {
        \\        nil
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(n :: i64) -> String {
        \\    when_positive(n, "yes")
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should have a type error: nil incompatible with String return type
    try std.testing.expect(engine.errors.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, engine.errors.items[0].message, "nil") != null);
}

test "typed macro: valid types produce no errors" {
    const source =
        \\pub module Test {
        \\  pub macro when_positive(value :: i64, result :: String) -> String {
        \\    quote {
        \\      if unquote(value) > 0 {
        \\        unquote(result)
        \\      } else {
        \\        "default"
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(n :: i64) -> String {
        \\    when_positive(n, "yes")
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // No errors — all types are compatible
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
}

test "typed macro: missing else branch is an error for non-nil return type" {
    const source =
        \\pub module Test {
        \\  pub macro unless(expr :: Bool, body :: i64) -> i64 {
        \\    quote {
        \\      if not unquote(expr) {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> i64 {
        \\    unless(x > 0, 42)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should error: if without else implicitly returns nil
    try std.testing.expect(engine.errors.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, engine.errors.items[0].message, "nil") != null);
}

test "typed macro: param type mismatch with return type" {
    const source =
        \\pub module Test {
        \\  pub macro wrap(value :: i64) -> String {
        \\    quote {
        \\      unquote(value)
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> String {
        \\    wrap(x)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should error: i64 param used as String return
    try std.testing.expect(engine.errors.items.len > 0);
}

test "macro substitution into case_expr and block" {
    // A macro that produces a case expression with unquote inside
    const source =
        \\pub module Test {
        \\  pub macro match_it(val :: Expr, fallback :: Expr) -> Nil {
        \\    quote {
        \\      case unquote(val) {
        \\        0 -> unquote(fallback)
        \\        x -> x
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(x :: i64) -> i64 {
        \\    match_it(x, 42)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // No errors — case_expr substitution should work
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
    // Module should still exist with expanded content
    try std.testing.expectEqual(@as(usize, 1), expanded.modules.len);
}
