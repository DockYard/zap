//! Attribute Substitution Pass
//!
//! Replaces @name references in function bodies with the stored attribute
//! constant values. Runs after collection (scope graph is populated) and
//! before macro expansion / type checking.
//!
//! For each function body, walks the AST looking for `attr_ref` nodes.
//! When found, looks up the attribute by name:
//!   1. Function-level attributes (attached to this function's family)
//!   2. Module-level attributes (attached to the enclosing module)
//! Replaces the attr_ref with the attribute's value expression.
//! Produces a compile error if the attribute is not found or is a marker.

const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const ctfe = @import("ctfe.zig");

pub const SubstitutionError = struct {
    message: []const u8,
    span: ast.SourceSpan,
};

/// Substitute attribute references in all function bodies within a program.
/// Returns a new program AST with attr_ref nodes replaced by attribute values.
pub fn substituteAttributes(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    graph: *const scope.ScopeGraph,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) !ast.Program {
    var new_modules: std.ArrayListUnmanaged(ast.ModuleDecl) = .empty;

    for (program.modules) |*mod| {
        const mod_scope = graph.node_scope_map.get(mod.meta.span.start) orelse {
            try new_modules.append(alloc, mod.*);
            continue;
        };

        // Collect module-level attributes for this module
        var mod_attrs: std.ArrayListUnmanaged(scope.Attribute) = .empty;
        for (graph.modules.items) |mod_entry| {
            if (mod_entry.scope_id == mod_scope) {
                for (mod_entry.attributes.items) |attr| {
                    try mod_attrs.append(alloc, attr);
                }
                break;
            }
        }

        var new_items: std.ArrayListUnmanaged(ast.ModuleItem) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    // Find function-level attributes from the scope graph
                    var func_attrs: std.ArrayListUnmanaged(scope.Attribute) = .empty;
                    if (func.clauses.len > 0) {
                        const arity: u32 = @intCast(func.clauses[0].params.len);
                        const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                        const parent = graph.scopes.items[mod_scope];
                        if (parent.function_families.get(key)) |fid| {
                            const family = graph.families.items[fid];
                            for (family.attributes.items) |attr| {
                                try func_attrs.append(alloc, attr);
                            }
                        }
                    }

                    // Substitute attr_ref in function clauses
                    const new_func = try substituteInFunction(
                        alloc,
                        func,
                        func_attrs.items,
                        mod_attrs.items,
                        interner,
                        errors,
                    );
                    if (item == .function) {
                        try new_items.append(alloc, .{ .function = new_func });
                    } else {
                        try new_items.append(alloc, .{ .priv_function = new_func });
                    }
                },
                else => try new_items.append(alloc, item),
            }
        }

        var new_mod = mod.*;
        new_mod.items = try new_items.toOwnedSlice(alloc);
        try new_modules.append(alloc, new_mod);
    }

    return .{
        .modules = try new_modules.toOwnedSlice(alloc),
        .top_items = program.top_items,
    };
}

fn substituteInFunction(
    alloc: std.mem.Allocator,
    func: *const ast.FunctionDecl,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) error{OutOfMemory}!*const ast.FunctionDecl {
    var new_clauses: std.ArrayListUnmanaged(ast.FunctionClause) = .empty;
    var changed = false;

    for (func.clauses) |clause| {
        var new_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (clause.body) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const new_expr = try substituteInExpr(alloc, expr, func_attrs, mod_attrs, interner, errors);
                    if (new_expr != expr) changed = true;
                    try new_body.append(alloc, .{ .expr = new_expr });
                },
                else => try new_body.append(alloc, stmt),
            }
        }

        if (changed) {
            var new_clause = clause;
            new_clause.body = try new_body.toOwnedSlice(alloc);
            try new_clauses.append(alloc, new_clause);
        } else {
            try new_clauses.append(alloc, clause);
        }
    }

    if (!changed) return func;

    const new_func = try alloc.create(ast.FunctionDecl);
    new_func.* = .{
        .meta = func.meta,
        .name = func.name,
        .clauses = try new_clauses.toOwnedSlice(alloc),
        .visibility = func.visibility,
    };
    return new_func;
}

fn substituteInExpr(
    alloc: std.mem.Allocator,
    expr: *const ast.Expr,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) error{OutOfMemory}!*const ast.Expr {
    switch (expr.*) {
        .attr_ref => |ref| {
            const attr_name = interner.get(ref.name);

            // Look up in function-level attributes first, then module-level
            const attr = findAttribute(ref.name, func_attrs) orelse
                findAttribute(ref.name, mod_attrs);

            if (attr) |a| {
                // Prefer CTFE-computed value over raw AST value
                if (a.computed_value) |cv| {
                    return ctfe.constValueToExpr(alloc, cv, interner) catch {
                        // Fall back to AST value if reification fails
                        if (a.value) |value| return value;
                        try errors.append(alloc, .{
                            .message = std.fmt.allocPrint(
                                alloc,
                                "@{s} computed value cannot be converted to an expression",
                                .{attr_name},
                            ) catch "computed value reification failed",
                            .span = ref.meta.span,
                        });
                        return expr;
                    };
                }
                if (a.value) |value| {
                    return value;
                } else {
                    // Marker attribute — can't be used as an expression
                    try errors.append(alloc, .{
                        .message = std.fmt.allocPrint(
                            alloc,
                            "@{s} is a marker attribute and has no value — it cannot be used in an expression",
                            .{attr_name},
                        ) catch "marker attribute used as expression",
                        .span = ref.meta.span,
                    });
                    return expr;
                }
            } else {
                try errors.append(alloc, .{
                    .message = std.fmt.allocPrint(
                        alloc,
                        "undefined attribute @{s} — define it with @{s} :: Type = value in the module body",
                        .{ attr_name, attr_name },
                    ) catch "undefined attribute",
                    .span = ref.meta.span,
                });
                return expr;
            }
        },
        // For compound expressions, recurse into children
        .call => |c| {
            const new_callee = try substituteInExpr(alloc, c.callee, func_attrs, mod_attrs, interner, errors);
            var new_args: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            var args_changed = false;
            for (c.args) |arg| {
                const new_arg = try substituteInExpr(alloc, arg, func_attrs, mod_attrs, interner, errors);
                if (new_arg != arg) args_changed = true;
                try new_args.append(alloc, new_arg);
            }
            if (new_callee == c.callee and !args_changed) return expr;
            const new_call = try alloc.create(ast.Expr);
            new_call.* = .{ .call = .{
                .meta = c.meta,
                .callee = new_callee,
                .args = try new_args.toOwnedSlice(alloc),
            } };
            return new_call;
        },
        .binary_op => |b| {
            const new_lhs = try substituteInExpr(alloc, b.lhs, func_attrs, mod_attrs, interner, errors);
            const new_rhs = try substituteInExpr(alloc, b.rhs, func_attrs, mod_attrs, interner, errors);
            if (new_lhs == b.lhs and new_rhs == b.rhs) return expr;
            const new_op = try alloc.create(ast.Expr);
            new_op.* = .{ .binary_op = .{
                .meta = b.meta,
                .op = b.op,
                .lhs = new_lhs,
                .rhs = new_rhs,
            } };
            return new_op;
        },
        .unary_op => |u| {
            const new_operand = try substituteInExpr(alloc, u.operand, func_attrs, mod_attrs, interner, errors);
            if (new_operand == u.operand) return expr;
            const new_unary = try alloc.create(ast.Expr);
            new_unary.* = .{ .unary_op = .{
                .meta = u.meta,
                .op = u.op,
                .operand = new_operand,
            } };
            return new_unary;
        },
        .pipe => |p| {
            const new_lhs = try substituteInExpr(alloc, p.lhs, func_attrs, mod_attrs, interner, errors);
            const new_rhs = try substituteInExpr(alloc, p.rhs, func_attrs, mod_attrs, interner, errors);
            if (new_lhs == p.lhs and new_rhs == p.rhs) return expr;
            const new_pipe = try alloc.create(ast.Expr);
            new_pipe.* = .{ .pipe = .{
                .meta = p.meta,
                .lhs = new_lhs,
                .rhs = new_rhs,
            } };
            return new_pipe;
        },
        .tuple => |t| {
            var new_elems: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            var changed = false;
            for (t.elements) |elem| {
                const new_elem = try substituteInExpr(alloc, elem, func_attrs, mod_attrs, interner, errors);
                if (new_elem != elem) changed = true;
                try new_elems.append(alloc, new_elem);
            }
            if (!changed) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .tuple = .{ .meta = t.meta, .elements = try new_elems.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .list => |l| {
            var new_elems: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            var changed = false;
            for (l.elements) |elem| {
                const new_elem = try substituteInExpr(alloc, elem, func_attrs, mod_attrs, interner, errors);
                if (new_elem != elem) changed = true;
                try new_elems.append(alloc, new_elem);
            }
            if (!changed) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .list = .{ .meta = l.meta, .elements = try new_elems.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .map => |m| {
            var new_fields: std.ArrayListUnmanaged(ast.MapField) = .empty;
            var changed = false;
            for (m.fields) |field| {
                const new_key = try substituteInExpr(alloc, field.key, func_attrs, mod_attrs, interner, errors);
                const new_val = try substituteInExpr(alloc, field.value, func_attrs, mod_attrs, interner, errors);
                if (new_key != field.key or new_val != field.value) changed = true;
                try new_fields.append(alloc, .{ .key = new_key, .value = new_val });
            }
            if (!changed) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .map = .{ .meta = m.meta, .fields = try new_fields.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .struct_expr => |s| {
            var new_fields: std.ArrayListUnmanaged(ast.StructField) = .empty;
            var changed = false;
            for (s.fields) |field| {
                const new_val = try substituteInExpr(alloc, field.value, func_attrs, mod_attrs, interner, errors);
                if (new_val != field.value) changed = true;
                try new_fields.append(alloc, .{ .name = field.name, .value = new_val });
            }
            const new_update = if (s.update_source) |us|
                try substituteInExpr(alloc, us, func_attrs, mod_attrs, interner, errors)
            else
                null;
            if (!changed and new_update == s.update_source) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .struct_expr = .{ .meta = s.meta, .module_name = s.module_name, .update_source = new_update, .fields = try new_fields.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .field_access => |f| {
            const new_obj = try substituteInExpr(alloc, f.object, func_attrs, mod_attrs, interner, errors);
            if (new_obj == f.object) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .field_access = .{ .meta = f.meta, .object = new_obj, .field = f.field } };
            return new_expr;
        },
        .unwrap => |u| {
            const new_inner = try substituteInExpr(alloc, u.expr, func_attrs, mod_attrs, interner, errors);
            if (new_inner == u.expr) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .unwrap = .{ .meta = u.meta, .expr = new_inner } };
            return new_expr;
        },
        .type_annotated => |ta| {
            const new_inner = try substituteInExpr(alloc, ta.expr, func_attrs, mod_attrs, interner, errors);
            if (new_inner == ta.expr) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .type_annotated = .{ .meta = ta.meta, .expr = new_inner, .type_expr = ta.type_expr } };
            return new_expr;
        },
        .if_expr => |ie| {
            const new_cond = try substituteInExpr(alloc, ie.condition, func_attrs, mod_attrs, interner, errors);
            const new_then = try substituteInStmts(alloc, ie.then_block, func_attrs, mod_attrs, interner, errors);
            const new_else = if (ie.else_block) |eb|
                try substituteInStmts(alloc, eb, func_attrs, mod_attrs, interner, errors)
            else
                null;
            if (new_cond == ie.condition and stmtsUnchanged(ie.then_block, new_then) and elseUnchanged(ie.else_block, new_else)) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .if_expr = .{ .meta = ie.meta, .condition = new_cond, .then_block = new_then, .else_block = new_else } };
            return new_expr;
        },
        .case_expr => |ce| {
            const new_scrutinee = try substituteInExpr(alloc, ce.scrutinee, func_attrs, mod_attrs, interner, errors);
            var new_clauses: std.ArrayListUnmanaged(ast.CaseClause) = .empty;
            var changed = new_scrutinee != ce.scrutinee;
            for (ce.clauses) |clause| {
                const new_guard = if (clause.guard) |g|
                    try substituteInExpr(alloc, g, func_attrs, mod_attrs, interner, errors)
                else
                    null;
                const new_body = try substituteInStmts(alloc, clause.body, func_attrs, mod_attrs, interner, errors);
                if (new_guard != clause.guard or !stmtsUnchanged(clause.body, new_body)) changed = true;
                var new_clause = clause;
                new_clause.guard = new_guard;
                new_clause.body = new_body;
                try new_clauses.append(alloc, new_clause);
            }
            if (!changed) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .case_expr = .{ .meta = ce.meta, .scrutinee = new_scrutinee, .clauses = try new_clauses.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .cond_expr => |ce| {
            var new_clauses: std.ArrayListUnmanaged(ast.CondClause) = .empty;
            var changed = false;
            for (ce.clauses) |clause| {
                const new_cond = try substituteInExpr(alloc, clause.condition, func_attrs, mod_attrs, interner, errors);
                const new_body = try substituteInStmts(alloc, clause.body, func_attrs, mod_attrs, interner, errors);
                if (new_cond != clause.condition or !stmtsUnchanged(clause.body, new_body)) changed = true;
                try new_clauses.append(alloc, .{ .meta = clause.meta, .condition = new_cond, .body = new_body });
            }
            if (!changed) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .cond_expr = .{ .meta = ce.meta, .clauses = try new_clauses.toOwnedSlice(alloc) } };
            return new_expr;
        },
        .block => |b| {
            const new_stmts = try substituteInStmts(alloc, b.stmts, func_attrs, mod_attrs, interner, errors);
            if (stmtsUnchanged(b.stmts, new_stmts)) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .block = .{ .meta = b.meta, .stmts = new_stmts } };
            return new_expr;
        },
        .for_expr => |fe| {
            const new_iterable = try substituteInExpr(alloc, fe.iterable, func_attrs, mod_attrs, interner, errors);
            const new_filter = if (fe.filter) |f|
                try substituteInExpr(alloc, f, func_attrs, mod_attrs, interner, errors)
            else
                null;
            const new_body = try substituteInExpr(alloc, fe.body, func_attrs, mod_attrs, interner, errors);
            if (new_iterable == fe.iterable and new_filter == fe.filter and new_body == fe.body) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .for_expr = .{ .meta = fe.meta, .var_name = fe.var_name, .iterable = new_iterable, .filter = new_filter, .body = new_body } };
            return new_expr;
        },
        .list_cons_expr => |lc| {
            const new_head = try substituteInExpr(alloc, lc.head, func_attrs, mod_attrs, interner, errors);
            const new_tail = try substituteInExpr(alloc, lc.tail, func_attrs, mod_attrs, interner, errors);
            if (new_head == lc.head and new_tail == lc.tail) return expr;
            const new_expr = try alloc.create(ast.Expr);
            new_expr.* = .{ .list_cons_expr = .{ .meta = lc.meta, .head = new_head, .tail = new_tail } };
            return new_expr;
        },
        // Leaf expressions — no substitution needed
        .int_literal,
        .float_literal,
        .string_literal,
        .string_interpolation,
        .atom_literal,
        .bool_literal,
        .nil_literal,
        .var_ref,
        .module_ref,
        .intrinsic,
        .binary_literal,
        .function_ref,
        .quote_expr,
        .unquote_expr,
        .unquote_splicing_expr,
        .panic_expr,
        .error_pipe,
        => return expr,
    }
}

fn substituteInStmts(
    alloc: std.mem.Allocator,
    stmts: []const ast.Stmt,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) error{OutOfMemory}![]const ast.Stmt {
    var new_stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    var changed = false;
    for (stmts) |stmt| {
        switch (stmt) {
            .expr => |e| {
                const new_e = try substituteInExpr(alloc, e, func_attrs, mod_attrs, interner, errors);
                if (new_e != e) changed = true;
                try new_stmts.append(alloc, .{ .expr = new_e });
            },
            else => try new_stmts.append(alloc, stmt),
        }
    }
    if (!changed) return stmts;
    return new_stmts.toOwnedSlice(alloc);
}

fn stmtsUnchanged(old: []const ast.Stmt, new: []const ast.Stmt) bool {
    return old.ptr == new.ptr;
}

fn elseUnchanged(old: ?[]const ast.Stmt, new: ?[]const ast.Stmt) bool {
    if (old == null and new == null) return true;
    if (old == null or new == null) return false;
    return old.?.ptr == new.?.ptr;
}

fn findAttribute(name: ast.StringId, attrs: []const scope.Attribute) ?scope.Attribute {
    for (attrs) |attr| {
        if (attr.name == name) return attr;
    }
    return null;
}
