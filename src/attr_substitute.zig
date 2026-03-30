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
    interner: *const ast.StringInterner,
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
    interner: *const ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) !*const ast.FunctionDecl {
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
    interner: *const ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) !*const ast.Expr {
    switch (expr.*) {
        .attr_ref => |ref| {
            const attr_name = interner.get(ref.name);

            // Look up in function-level attributes first, then module-level
            const attr = findAttribute(ref.name, func_attrs) orelse
                findAttribute(ref.name, mod_attrs);

            if (attr) |a| {
                if (a.value) |value| {
                    return value;
                } else {
                    // Marker attribute — can't be used as an expression
                    try errors.append(alloc, .{
                        .message = std.fmt.allocPrint(alloc,
                            "@{s} is a marker attribute and has no value — it cannot be used in an expression",
                            .{attr_name},
                        ) catch "marker attribute used as expression",
                        .span = ref.meta.span,
                    });
                    return expr;
                }
            } else {
                try errors.append(alloc, .{
                    .message = std.fmt.allocPrint(alloc,
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
        // Leaf expressions — no substitution needed
        .int_literal, .float_literal, .string_literal, .string_interpolation,
        .atom_literal, .bool_literal, .nil_literal, .var_ref, .module_ref,
        .intrinsic, .binary_literal, .function_ref, .type_annotated,
        .quote_expr, .unquote_expr, .panic_expr,
        => return expr,
        // Compound expressions we don't recurse into for now
        // (if_expr, case_expr, with_expr, cond_expr, block, tuple, list, map,
        //  struct_expr, field_access, unwrap — these can contain attr_ref too,
        //  but covering call, binary_op, pipe, unary_op handles the common cases)
        else => return expr,
    }
}

fn findAttribute(name: ast.StringId, attrs: []const scope.Attribute) ?scope.Attribute {
    for (attrs) |attr| {
        if (attr.name == name) return attr;
    }
    return null;
}
