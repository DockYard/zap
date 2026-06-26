//! Attribute Substitution Pass
//!
//! Replaces @name references in function bodies with the stored attribute
//! constant values. Runs after collection (scope graph is populated) and
//! before macro expansion / type checking.
//!
//! For each function body, walks the AST looking for `attr_ref` nodes.
//! When found, looks up the attribute by name:
//!   1. Function-level attributes (attached to this function's family)
//!   2. Struct-level attributes (attached to the enclosing struct)
//! Replaces the attr_ref with the attribute's value expression.
//! Produces a compile error if the attribute is not found or is a marker.

const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const ctfe = @import("ctfe.zig");

const MAX_ATTRIBUTE_SUBSTITUTION_DEPTH: u32 = 512;

pub const SubstitutionError = struct {
    message: []const u8,
    span: ast.SourceSpan,
};

const SubstitutionOwner = struct {
    allocator: std.mem.Allocator,
    active: bool = true,
    expr_nodes: std.ArrayListUnmanaged(*const ast.Expr) = .empty,
    const_value_exprs: std.ArrayListUnmanaged(*const ast.Expr) = .empty,
    function_nodes: std.ArrayListUnmanaged(*const ast.FunctionDecl) = .empty,
    expr_slices: std.ArrayListUnmanaged([]const *const ast.Expr) = .empty,
    stmt_slices: std.ArrayListUnmanaged([]const ast.Stmt) = .empty,
    map_field_slices: std.ArrayListUnmanaged([]const ast.MapField) = .empty,
    struct_field_slices: std.ArrayListUnmanaged([]const ast.StructField) = .empty,
    case_clause_slices: std.ArrayListUnmanaged([]const ast.CaseClause) = .empty,
    cond_clause_slices: std.ArrayListUnmanaged([]const ast.CondClause) = .empty,
    with_step_slices: std.ArrayListUnmanaged([]const ast.WithStep) = .empty,
    function_clause_slices: std.ArrayListUnmanaged([]const ast.FunctionClause) = .empty,
    struct_item_slices: std.ArrayListUnmanaged([]const ast.StructItem) = .empty,
    struct_slices: std.ArrayListUnmanaged([]const ast.StructDecl) = .empty,

    fn init(allocator: std.mem.Allocator) SubstitutionOwner {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *SubstitutionOwner) void {
        if (self.active) {
            for (self.expr_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.stmt_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.map_field_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.struct_field_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.case_clause_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.cond_clause_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.with_step_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.function_clause_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.struct_item_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.struct_slices.items) |slice| freeOwnedSlice(self.allocator, slice);
            for (self.const_value_exprs.items) |expr| ctfe.deinitConstValueExpr(self.allocator, expr);
            for (self.expr_nodes.items) |expr| self.allocator.destroy(@constCast(expr));
            for (self.function_nodes.items) |function| self.allocator.destroy(@constCast(function));
        }

        self.expr_nodes.deinit(self.allocator);
        self.const_value_exprs.deinit(self.allocator);
        self.function_nodes.deinit(self.allocator);
        self.expr_slices.deinit(self.allocator);
        self.stmt_slices.deinit(self.allocator);
        self.map_field_slices.deinit(self.allocator);
        self.struct_field_slices.deinit(self.allocator);
        self.case_clause_slices.deinit(self.allocator);
        self.cond_clause_slices.deinit(self.allocator);
        self.with_step_slices.deinit(self.allocator);
        self.function_clause_slices.deinit(self.allocator);
        self.struct_item_slices.deinit(self.allocator);
        self.struct_slices.deinit(self.allocator);
    }

    fn release(self: *SubstitutionOwner) void {
        self.active = false;
    }

    fn createExpr(self: *SubstitutionOwner) error{OutOfMemory}!*ast.Expr {
        const expr = try self.allocator.create(ast.Expr);
        errdefer self.allocator.destroy(expr);
        try self.expr_nodes.append(self.allocator, expr);
        return expr;
    }

    fn adoptConstValueExpr(self: *SubstitutionOwner, expr: *const ast.Expr) error{OutOfMemory}!*const ast.Expr {
        errdefer ctfe.deinitConstValueExpr(self.allocator, expr);
        try self.const_value_exprs.append(self.allocator, expr);
        return expr;
    }

    fn createFunction(self: *SubstitutionOwner) error{OutOfMemory}!*ast.FunctionDecl {
        const function = try self.allocator.create(ast.FunctionDecl);
        errdefer self.allocator.destroy(function);
        try self.function_nodes.append(self.allocator, function);
        return function;
    }

    fn adoptExprSlice(self: *SubstitutionOwner, slice: []const *const ast.Expr) error{OutOfMemory}![]const *const ast.Expr {
        return self.adoptSlice(*const ast.Expr, &self.expr_slices, slice);
    }

    fn adoptStmtSlice(self: *SubstitutionOwner, slice: []const ast.Stmt) error{OutOfMemory}![]const ast.Stmt {
        return self.adoptSlice(ast.Stmt, &self.stmt_slices, slice);
    }

    fn adoptMapFieldSlice(self: *SubstitutionOwner, slice: []const ast.MapField) error{OutOfMemory}![]const ast.MapField {
        return self.adoptSlice(ast.MapField, &self.map_field_slices, slice);
    }

    fn adoptStructFieldSlice(self: *SubstitutionOwner, slice: []const ast.StructField) error{OutOfMemory}![]const ast.StructField {
        return self.adoptSlice(ast.StructField, &self.struct_field_slices, slice);
    }

    fn adoptCaseClauseSlice(self: *SubstitutionOwner, slice: []const ast.CaseClause) error{OutOfMemory}![]const ast.CaseClause {
        return self.adoptSlice(ast.CaseClause, &self.case_clause_slices, slice);
    }

    fn adoptCondClauseSlice(self: *SubstitutionOwner, slice: []const ast.CondClause) error{OutOfMemory}![]const ast.CondClause {
        return self.adoptSlice(ast.CondClause, &self.cond_clause_slices, slice);
    }

    fn adoptWithStepSlice(self: *SubstitutionOwner, slice: []const ast.WithStep) error{OutOfMemory}![]const ast.WithStep {
        return self.adoptSlice(ast.WithStep, &self.with_step_slices, slice);
    }

    fn adoptFunctionClauseSlice(self: *SubstitutionOwner, slice: []const ast.FunctionClause) error{OutOfMemory}![]const ast.FunctionClause {
        return self.adoptSlice(ast.FunctionClause, &self.function_clause_slices, slice);
    }

    fn adoptStructItemSlice(self: *SubstitutionOwner, slice: []const ast.StructItem) error{OutOfMemory}![]const ast.StructItem {
        return self.adoptSlice(ast.StructItem, &self.struct_item_slices, slice);
    }

    fn adoptStructSlice(self: *SubstitutionOwner, slice: []const ast.StructDecl) error{OutOfMemory}![]const ast.StructDecl {
        return self.adoptSlice(ast.StructDecl, &self.struct_slices, slice);
    }

    fn adoptSlice(
        self: *SubstitutionOwner,
        comptime Item: type,
        registry: *std.ArrayListUnmanaged([]const Item),
        slice: []const Item,
    ) error{OutOfMemory}![]const Item {
        errdefer freeOwnedSlice(self.allocator, slice);
        try registry.append(self.allocator, slice);
        return slice;
    }
};

fn freeOwnedSlice(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}

/// Substitute attribute references in all function bodies within a program.
/// Returns a new program AST with attr_ref nodes replaced by attribute values.
pub fn substituteAttributes(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    graph: *const scope.ScopeGraph,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
) !ast.Program {
    var owner = SubstitutionOwner.init(alloc);
    defer owner.deinit();

    var new_structs: std.ArrayListUnmanaged(ast.StructDecl) = .empty;
    defer new_structs.deinit(alloc);

    for (program.structs) |*mod| {
        const mod_scope = graph.node_scope_map.get(scope.ScopeGraph.spanKey(mod.meta.span)) orelse {
            try new_structs.append(alloc, mod.*);
            continue;
        };

        // Borrow struct-level attributes for this struct.
        var mod_attrs: []const scope.Attribute = &.{};
        for (graph.structs.items) |mod_entry| {
            if (mod_entry.scope_id == mod_scope) {
                mod_attrs = mod_entry.attributes.items;
                break;
            }
        }

        var new_items: std.ArrayListUnmanaged(ast.StructItem) = .empty;
        defer new_items.deinit(alloc);

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    // Borrow function-level attributes from the scope graph.
                    var func_attrs: []const scope.Attribute = &.{};
                    if (func.clauses.len > 0) {
                        const arity: u32 = @intCast(func.clauses[0].params.len);
                        const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                        const parent = graph.scopes.items[mod_scope];
                        if (parent.function_families.get(key)) |fid| {
                            const family = graph.families.items[fid];
                            func_attrs = family.attributes.items;
                        }
                    }

                    // Substitute attr_ref in function clauses
                    const new_func = try substituteInFunctionDepth(
                        &owner,
                        alloc,
                        func,
                        func_attrs,
                        mod_attrs,
                        interner,
                        errors,
                        0,
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
        const owned_items = try new_items.toOwnedSlice(alloc);
        new_mod.items = try owner.adoptStructItemSlice(owned_items);
        try new_structs.append(alloc, new_mod);
    }

    const owned_structs = try new_structs.toOwnedSlice(alloc);
    const substituted = ast.Program{
        .structs = try owner.adoptStructSlice(owned_structs),
        .top_items = program.top_items,
    };
    owner.release();
    return .{
        .structs = substituted.structs,
        .top_items = substituted.top_items,
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
    var owner = SubstitutionOwner.init(alloc);
    defer owner.deinit();
    const result = try substituteInFunctionDepth(&owner, alloc, func, func_attrs, mod_attrs, interner, errors, 0);
    owner.release();
    return result;
}

fn substituteInFunctionDepth(
    owner: *SubstitutionOwner,
    alloc: std.mem.Allocator,
    func: *const ast.FunctionDecl,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
    depth: u32,
) error{OutOfMemory}!*const ast.FunctionDecl {
    if (depth >= MAX_ATTRIBUTE_SUBSTITUTION_DEPTH) {
        try errors.append(alloc, .{
            .message = "attribute substitution exceeded maximum AST depth",
            .span = func.meta.span,
        });
        return func;
    }

    var new_clauses: std.ArrayListUnmanaged(ast.FunctionClause) = .empty;
    defer new_clauses.deinit(alloc);
    var changed = false;

    for (func.clauses) |clause| {
        if (clause.body) |body| {
            var new_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            defer new_body.deinit(alloc);
            for (body) |stmt| {
                switch (stmt) {
                    .expr => |expr| {
                        const new_expr = try substituteInExprDepth(owner, alloc, expr, func_attrs, mod_attrs, interner, errors, depth + 1);
                        if (new_expr != expr) changed = true;
                        try new_body.append(alloc, .{ .expr = new_expr });
                    },
                    else => try new_body.append(alloc, stmt),
                }
            }

            if (changed) {
                var new_clause = clause;
                const owned_body = try new_body.toOwnedSlice(alloc);
                new_clause.body = try owner.adoptStmtSlice(owned_body);
                try new_clauses.append(alloc, new_clause);
            } else {
                try new_clauses.append(alloc, clause);
            }
        } else {
            // Bodyless clause (protocol signature, forward decl) — pass through unchanged
            try new_clauses.append(alloc, clause);
        }
    }

    if (!changed) return func;

    const new_func = try owner.createFunction();
    const owned_clauses = try new_clauses.toOwnedSlice(alloc);
    new_func.* = .{
        .meta = func.meta,
        .name = func.name,
        .name_expr = func.name_expr,
        .clauses = try owner.adoptFunctionClauseSlice(owned_clauses),
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
    var owner = SubstitutionOwner.init(alloc);
    defer owner.deinit();
    const result = try substituteInExprDepth(&owner, alloc, expr, func_attrs, mod_attrs, interner, errors, 0);
    owner.release();
    return result;
}

fn substituteInExprDepth(
    owner: *SubstitutionOwner,
    alloc: std.mem.Allocator,
    expr: *const ast.Expr,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
    depth: u32,
) error{OutOfMemory}!*const ast.Expr {
    if (depth >= MAX_ATTRIBUTE_SUBSTITUTION_DEPTH) {
        try errors.append(alloc, .{
            .message = "attribute substitution exceeded maximum AST depth",
            .span = expr.getMeta().span,
        });
        return expr;
    }

    switch (expr.*) {
        .attr_ref => |ref| {
            const attr_name = interner.get(ref.name);

            // `@target` is the reserved comptime intrinsic surfacing the
            // compilation target as `{os, arch, abi}` atoms — NOT a
            // user-declared struct attribute. Leave it untouched here; the
            // HIR builder resolves `@target.<field>` to a comptime atom and
            // folds comparisons/`case` over it. (Without this guard the
            // attribute-substitution pass would reject `@target` as an
            // undefined attribute before HIR build ever runs.)
            if (std.mem.eql(u8, attr_name, "target")) {
                return expr;
            }

            // Look up in function-level attributes first, then struct-level
            const attr = findAttribute(ref.name, func_attrs) orelse
                findAttribute(ref.name, mod_attrs);

            if (attr) |a| {
                // Prefer CTFE-computed value over raw AST value
                if (a.computed_value) |cv| {
                    const converted = ctfe.constValueToExpr(alloc, cv, interner) catch |err| {
                        try recordComputedValueReificationError(
                            alloc,
                            attr_name,
                            ref.meta.span,
                            errors,
                            err,
                        );
                        return expr;
                    };
                    return owner.adoptConstValueExpr(converted);
                }
                if (a.value) |value| {
                    return value;
                } else {
                    // Marker attribute — can't be used as an expression
                    try appendSubstitutionErrorFmt(
                        alloc,
                        errors,
                        ref.meta.span,
                        "@{s} is a marker attribute and has no value — it cannot be used in an expression",
                        .{attr_name},
                    );
                    return expr;
                }
            } else {
                try appendSubstitutionErrorFmt(
                    alloc,
                    errors,
                    ref.meta.span,
                    "undefined attribute @{s} — define it with @{s} :: Type = value in the struct body",
                    .{ attr_name, attr_name },
                );
                return expr;
            }
        },
        // For compound expressions, recurse into children
        .call => |c| {
            const new_callee = try substituteInExprDepth(owner, alloc, c.callee, func_attrs, mod_attrs, interner, errors, depth + 1);
            var new_args: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            defer new_args.deinit(alloc);
            var args_changed = false;
            for (c.args) |arg| {
                const new_arg = try substituteInExprDepth(owner, alloc, arg, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_arg != arg) args_changed = true;
                try new_args.append(alloc, new_arg);
            }
            if (new_callee == c.callee and !args_changed) return expr;
            const owned_args = try new_args.toOwnedSlice(alloc);
            const adopted_args = try owner.adoptExprSlice(owned_args);
            const new_call = try owner.createExpr();
            new_call.* = .{ .call = .{
                .meta = c.meta,
                .callee = new_callee,
                .args = adopted_args,
            } };
            return new_call;
        },
        .binary_op => |b| {
            const new_lhs = try substituteInExprDepth(owner, alloc, b.lhs, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_rhs = try substituteInExprDepth(owner, alloc, b.rhs, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_lhs == b.lhs and new_rhs == b.rhs) return expr;
            const new_op = try owner.createExpr();
            new_op.* = .{ .binary_op = .{
                .meta = b.meta,
                .op = b.op,
                .lhs = new_lhs,
                .rhs = new_rhs,
            } };
            return new_op;
        },
        .unary_op => |u| {
            const new_operand = try substituteInExprDepth(owner, alloc, u.operand, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_operand == u.operand) return expr;
            const new_unary = try owner.createExpr();
            new_unary.* = .{ .unary_op = .{
                .meta = u.meta,
                .op = u.op,
                .operand = new_operand,
            } };
            return new_unary;
        },
        .pipe => |p| {
            const new_lhs = try substituteInExprDepth(owner, alloc, p.lhs, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_rhs = try substituteInExprDepth(owner, alloc, p.rhs, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_lhs == p.lhs and new_rhs == p.rhs) return expr;
            const new_pipe = try owner.createExpr();
            new_pipe.* = .{ .pipe = .{
                .meta = p.meta,
                .lhs = new_lhs,
                .rhs = new_rhs,
            } };
            return new_pipe;
        },
        .tuple => |t| {
            var new_elems: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            defer new_elems.deinit(alloc);
            var changed = false;
            for (t.elements) |elem| {
                const new_elem = try substituteInExprDepth(owner, alloc, elem, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_elem != elem) changed = true;
                try new_elems.append(alloc, new_elem);
            }
            if (!changed) return expr;
            const owned_elems = try new_elems.toOwnedSlice(alloc);
            const adopted_elems = try owner.adoptExprSlice(owned_elems);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .tuple = .{ .meta = t.meta, .elements = adopted_elems } };
            return new_expr;
        },
        .list => |l| {
            var new_elems: std.ArrayListUnmanaged(*const ast.Expr) = .empty;
            defer new_elems.deinit(alloc);
            var changed = false;
            for (l.elements) |elem| {
                const new_elem = try substituteInExprDepth(owner, alloc, elem, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_elem != elem) changed = true;
                try new_elems.append(alloc, new_elem);
            }
            if (!changed) return expr;
            const owned_elems = try new_elems.toOwnedSlice(alloc);
            const adopted_elems = try owner.adoptExprSlice(owned_elems);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .list = .{ .meta = l.meta, .elements = adopted_elems } };
            return new_expr;
        },
        .map => |m| {
            var new_fields: std.ArrayListUnmanaged(ast.MapField) = .empty;
            defer new_fields.deinit(alloc);
            var changed = false;
            for (m.fields) |field| {
                const new_key = try substituteInExprDepth(owner, alloc, field.key, func_attrs, mod_attrs, interner, errors, depth + 1);
                const new_val = try substituteInExprDepth(owner, alloc, field.value, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_key != field.key or new_val != field.value) changed = true;
                try new_fields.append(alloc, .{ .key = new_key, .value = new_val });
            }
            const new_update = if (m.update_source) |update_source|
                try substituteInExprDepth(owner, alloc, update_source, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            if (!changed and new_update == m.update_source) return expr;
            const owned_fields = try new_fields.toOwnedSlice(alloc);
            const adopted_fields = try owner.adoptMapFieldSlice(owned_fields);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .map = .{ .meta = m.meta, .update_source = new_update, .fields = adopted_fields } };
            return new_expr;
        },
        .struct_expr => |s| {
            var new_fields: std.ArrayListUnmanaged(ast.StructField) = .empty;
            defer new_fields.deinit(alloc);
            var changed = false;
            for (s.fields) |field| {
                const new_val = try substituteInExprDepth(owner, alloc, field.value, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_val != field.value) changed = true;
                try new_fields.append(alloc, .{ .name = field.name, .value = new_val });
            }
            const new_update = if (s.update_source) |us|
                try substituteInExprDepth(owner, alloc, us, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            if (!changed and new_update == s.update_source) return expr;
            const owned_fields = try new_fields.toOwnedSlice(alloc);
            const adopted_fields = try owner.adoptStructFieldSlice(owned_fields);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .struct_expr = .{
                .meta = s.meta,
                .struct_name = s.struct_name,
                .type_args = s.type_args,
                .type_args_parens_present = s.type_args_parens_present,
                .update_source = new_update,
                .fields = adopted_fields,
            } };
            return new_expr;
        },
        .field_access => |f| {
            const new_obj = try substituteInExprDepth(owner, alloc, f.object, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_obj == f.object) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .field_access = .{ .meta = f.meta, .object = new_obj, .field = f.field } };
            return new_expr;
        },
        .unwrap => |u| {
            const new_inner = try substituteInExprDepth(owner, alloc, u.expr, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_inner == u.expr) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .unwrap = .{ .meta = u.meta, .expr = new_inner } };
            return new_expr;
        },
        .type_annotated => |ta| {
            const new_inner = try substituteInExprDepth(owner, alloc, ta.expr, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_inner == ta.expr) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .type_annotated = .{ .meta = ta.meta, .expr = new_inner, .type_expr = ta.type_expr } };
            return new_expr;
        },
        .if_expr => |ie| {
            const new_cond = try substituteInExprDepth(owner, alloc, ie.condition, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_then = try substituteInStmtsDepth(owner, alloc, ie.then_block, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_else = if (ie.else_block) |eb|
                try substituteInStmtsDepth(owner, alloc, eb, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            if (new_cond == ie.condition and stmtsUnchanged(ie.then_block, new_then) and elseUnchanged(ie.else_block, new_else)) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .if_expr = .{ .meta = ie.meta, .condition = new_cond, .then_block = new_then, .else_block = new_else } };
            return new_expr;
        },
        .case_expr => |ce| {
            const new_scrutinee = try substituteInExprDepth(owner, alloc, ce.scrutinee, func_attrs, mod_attrs, interner, errors, depth + 1);
            var new_clauses: std.ArrayListUnmanaged(ast.CaseClause) = .empty;
            defer new_clauses.deinit(alloc);
            var changed = new_scrutinee != ce.scrutinee;
            for (ce.clauses) |clause| {
                const new_guard = if (clause.guard) |g|
                    try substituteInExprDepth(owner, alloc, g, func_attrs, mod_attrs, interner, errors, depth + 1)
                else
                    null;
                const new_body = try substituteInStmtsDepth(owner, alloc, clause.body, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_guard != clause.guard or !stmtsUnchanged(clause.body, new_body)) changed = true;
                var new_clause = clause;
                new_clause.guard = new_guard;
                new_clause.body = new_body;
                try new_clauses.append(alloc, new_clause);
            }
            if (!changed) return expr;
            const owned_clauses = try new_clauses.toOwnedSlice(alloc);
            const adopted_clauses = try owner.adoptCaseClauseSlice(owned_clauses);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .case_expr = .{ .meta = ce.meta, .scrutinee = new_scrutinee, .clauses = adopted_clauses } };
            return new_expr;
        },
        .cond_expr => |ce| {
            var new_clauses: std.ArrayListUnmanaged(ast.CondClause) = .empty;
            defer new_clauses.deinit(alloc);
            var changed = false;
            for (ce.clauses) |clause| {
                const new_cond = try substituteInExprDepth(owner, alloc, clause.condition, func_attrs, mod_attrs, interner, errors, depth + 1);
                const new_body = try substituteInStmtsDepth(owner, alloc, clause.body, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_cond != clause.condition or !stmtsUnchanged(clause.body, new_body)) changed = true;
                try new_clauses.append(alloc, .{ .meta = clause.meta, .condition = new_cond, .body = new_body });
            }
            if (!changed) return expr;
            const owned_clauses = try new_clauses.toOwnedSlice(alloc);
            const adopted_clauses = try owner.adoptCondClauseSlice(owned_clauses);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .cond_expr = .{ .meta = ce.meta, .clauses = adopted_clauses } };
            return new_expr;
        },
        .block => |b| {
            const new_stmts = try substituteInStmtsDepth(owner, alloc, b.stmts, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (stmtsUnchanged(b.stmts, new_stmts)) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .block = .{ .meta = b.meta, .stmts = new_stmts } };
            return new_expr;
        },
        .anonymous_function => |anon| {
            const new_decl = try substituteInFunctionDepth(owner, alloc, anon.decl, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_decl == anon.decl) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .anonymous_function = .{ .meta = anon.meta, .decl = new_decl } };
            return new_expr;
        },
        .for_expr => |fe| {
            const new_iterable = try substituteInExprDepth(owner, alloc, fe.iterable, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_filter = if (fe.filter) |f|
                try substituteInExprDepth(owner, alloc, f, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            const new_body = try substituteInExprDepth(owner, alloc, fe.body, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_iterable == fe.iterable and new_filter == fe.filter and new_body == fe.body) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .for_expr = .{ .meta = fe.meta, .var_pattern = fe.var_pattern, .var_type_annotation = fe.var_type_annotation, .iterable = new_iterable, .filter = new_filter, .body = new_body } };
            return new_expr;
        },
        .range => |re| {
            const new_start = try substituteInExprDepth(owner, alloc, re.start, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_end = try substituteInExprDepth(owner, alloc, re.end, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_step = if (re.step) |s|
                try substituteInExprDepth(owner, alloc, s, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            if (new_start == re.start and new_end == re.end and new_step == re.step) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .range = .{ .meta = re.meta, .start = new_start, .end = new_end, .step = new_step } };
            return new_expr;
        },
        .list_cons_expr => |lc| {
            const new_head = try substituteInExprDepth(owner, alloc, lc.head, func_attrs, mod_attrs, interner, errors, depth + 1);
            const new_tail = try substituteInExprDepth(owner, alloc, lc.tail, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_head == lc.head and new_tail == lc.tail) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .list_cons_expr = .{ .meta = lc.meta, .head = new_head, .tail = new_tail } };
            return new_expr;
        },
        .raise_expr => |re| {
            const new_value = try substituteInExprDepth(owner, alloc, re.value, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (new_value == re.value) return expr;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .raise_expr = .{ .meta = re.meta, .value = new_value } };
            return new_expr;
        },
        .with_expr => |we| {
            // `with` is desugared to nested `case` during macro expansion,
            // so attribute substitution rarely sees it; recurse into the
            // step exprs, the do-body, and the else-clause bodies/guards so
            // any `@attr` inside is substituted before the desugar runs.
            var new_steps: std.ArrayListUnmanaged(ast.WithStep) = .empty;
            defer new_steps.deinit(alloc);
            var new_else_clauses: std.ArrayListUnmanaged(ast.CaseClause) = .empty;
            defer new_else_clauses.deinit(alloc);
            var changed = false;
            for (we.steps) |step| {
                const new_step_expr = try substituteInExprDepth(owner, alloc, step.expr, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_step_expr != step.expr) changed = true;
                var new_step = step;
                new_step.expr = new_step_expr;
                try new_steps.append(alloc, new_step);
            }
            const new_do = try substituteInStmtsDepth(owner, alloc, we.do_body, func_attrs, mod_attrs, interner, errors, depth + 1);
            if (!stmtsUnchanged(we.do_body, new_do)) changed = true;
            if (we.else_clauses) |clauses| {
                for (clauses) |clause| {
                    const new_guard = if (clause.guard) |g|
                        try substituteInExprDepth(owner, alloc, g, func_attrs, mod_attrs, interner, errors, depth + 1)
                    else
                        null;
                    const new_clause_body = try substituteInStmtsDepth(owner, alloc, clause.body, func_attrs, mod_attrs, interner, errors, depth + 1);
                    if (new_guard != clause.guard or !stmtsUnchanged(clause.body, new_clause_body)) changed = true;
                    var new_clause = clause;
                    new_clause.guard = new_guard;
                    new_clause.body = new_clause_body;
                    try new_else_clauses.append(alloc, new_clause);
                }
            }
            if (!changed) return expr;
            const owned_steps = try new_steps.toOwnedSlice(alloc);
            const adopted_steps = try owner.adoptWithStepSlice(owned_steps);
            const adopted_else: ?[]const ast.CaseClause = if (we.else_clauses != null) blk: {
                const owned_else = try new_else_clauses.toOwnedSlice(alloc);
                break :blk try owner.adoptCaseClauseSlice(owned_else);
            } else null;
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .with_expr = .{
                .meta = we.meta,
                .steps = adopted_steps,
                .do_body = new_do,
                .else_clauses = adopted_else,
            } };
            return new_expr;
        },
        .try_rescue => |tr| {
            const new_body = try substituteInStmtsDepth(owner, alloc, tr.body, func_attrs, mod_attrs, interner, errors, depth + 1);
            var new_clauses: std.ArrayListUnmanaged(ast.CaseClause) = .empty;
            defer new_clauses.deinit(alloc);
            var changed = !stmtsUnchanged(tr.body, new_body);
            for (tr.rescue_clauses) |clause| {
                const new_guard = if (clause.guard) |g|
                    try substituteInExprDepth(owner, alloc, g, func_attrs, mod_attrs, interner, errors, depth + 1)
                else
                    null;
                const new_clause_body = try substituteInStmtsDepth(owner, alloc, clause.body, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_guard != clause.guard or !stmtsUnchanged(clause.body, new_clause_body)) changed = true;
                var new_clause = clause;
                new_clause.guard = new_guard;
                new_clause.body = new_clause_body;
                try new_clauses.append(alloc, new_clause);
            }
            const new_after = if (tr.after_block) |cleanup|
                try substituteInStmtsDepth(owner, alloc, cleanup, func_attrs, mod_attrs, interner, errors, depth + 1)
            else
                null;
            if (tr.after_block) |cleanup| {
                if (!stmtsUnchanged(cleanup, new_after.?)) changed = true;
            }
            if (!changed) return expr;
            const owned_clauses = try new_clauses.toOwnedSlice(alloc);
            const adopted_clauses = try owner.adoptCaseClauseSlice(owned_clauses);
            const new_expr = try owner.createExpr();
            new_expr.* = .{ .try_rescue = .{
                .meta = tr.meta,
                .body = new_body,
                .rescue_clauses = adopted_clauses,
                .after_block = new_after,
            } };
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
        .struct_ref,
        .intrinsic,
        .binary_literal,
        .function_ref,
        .quote_expr,
        .unquote_expr,
        .unquote_splicing_expr,
        .panic_expr,
        .error_pipe,
        // Poison sentinel (Phase 4.b): a parse-error placeholder has no
        // `@attr` to substitute — return it unchanged.
        .poison,
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
    var owner = SubstitutionOwner.init(alloc);
    defer owner.deinit();
    const result = try substituteInStmtsDepth(&owner, alloc, stmts, func_attrs, mod_attrs, interner, errors, 0);
    owner.release();
    return result;
}

fn substituteInStmtsDepth(
    owner: *SubstitutionOwner,
    alloc: std.mem.Allocator,
    stmts: []const ast.Stmt,
    func_attrs: []const scope.Attribute,
    mod_attrs: []const scope.Attribute,
    interner: *ast.StringInterner,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
    depth: u32,
) error{OutOfMemory}![]const ast.Stmt {
    if (depth >= MAX_ATTRIBUTE_SUBSTITUTION_DEPTH) {
        const span = if (stmts.len > 0) stmtSpan(stmts[0]) else ast.SourceSpan{ .start = 0, .end = 0 };
        try errors.append(alloc, .{
            .message = "attribute substitution exceeded maximum AST depth",
            .span = span,
        });
        return stmts;
    }

    var new_stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    defer new_stmts.deinit(alloc);
    var changed = false;
    for (stmts) |stmt| {
        switch (stmt) {
            .expr => |e| {
                const new_e = try substituteInExprDepth(owner, alloc, e, func_attrs, mod_attrs, interner, errors, depth + 1);
                if (new_e != e) changed = true;
                try new_stmts.append(alloc, .{ .expr = new_e });
            },
            else => try new_stmts.append(alloc, stmt),
        }
    }
    if (!changed) return stmts;
    const owned_stmts = try new_stmts.toOwnedSlice(alloc);
    return owner.adoptStmtSlice(owned_stmts);
}

fn stmtSpan(stmt: ast.Stmt) ast.SourceSpan {
    return switch (stmt) {
        .expr => |expr| expr.getMeta().span,
        .assignment => |assignment| assignment.meta.span,
        .function_decl => |function_decl| function_decl.meta.span,
        .macro_decl => |macro_decl| macro_decl.meta.span,
        .import_decl => |import_decl| import_decl.meta.span,
        .attribute => |attribute| attribute.meta.span,
    };
}

fn appendSubstitutionErrorFmt(
    alloc: std.mem.Allocator,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
    span: ast.SourceSpan,
    comptime message_fmt: []const u8,
    message_args: anytype,
) error{OutOfMemory}!void {
    const message = try std.fmt.allocPrint(alloc, message_fmt, message_args);
    errdefer alloc.free(message);

    try errors.append(alloc, .{
        .message = message,
        .span = span,
    });
}

fn recordComputedValueReificationError(
    alloc: std.mem.Allocator,
    attr_name: []const u8,
    span: ast.SourceSpan,
    errors: *std.ArrayListUnmanaged(SubstitutionError),
    err: anyerror,
) error{OutOfMemory}!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;

    const message = try std.fmt.allocPrint(
        alloc,
        "@{s} computed value cannot be converted to an expression: {s}",
        .{ attr_name, @errorName(err) },
    );
    errdefer alloc.free(message);

    try errors.append(alloc, .{
        .message = message,
        .span = span,
    });
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

const FailOnceAllocator = struct {
    backing_allocator: std.mem.Allocator,
    fail_index: usize,
    allocation_index: usize = 0,
    failed: bool = false,

    fn init(backing_allocator: std.mem.Allocator, fail_index: usize) FailOnceAllocator {
        return .{
            .backing_allocator = backing_allocator,
            .fail_index = fail_index,
        };
    }

    fn allocator(self: *FailOnceAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        const current_index = self.allocation_index;
        self.allocation_index += 1;
        if (!self.failed and current_index == self.fail_index) {
            self.failed = true;
            return null;
        }
        return self.backing_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        return self.backing_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        return self.backing_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(memory, alignment, return_address);
    }
};

test "attribute substitution reports excessive AST depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    var expr = try alloc.create(ast.Expr);
    expr.* = .{ .int_literal = .{ .meta = .{ .span = span }, .value = 1 } };
    for (0..MAX_ATTRIBUTE_SUBSTITUTION_DEPTH + 8) |_| {
        const wrapper = try alloc.create(ast.Expr);
        wrapper.* = .{ .unary_op = .{
            .meta = .{ .span = span },
            .op = .not_op,
            .operand = expr,
        } };
        expr = wrapper;
    }

    var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
    defer errors.deinit(alloc);
    _ = try substituteInExpr(alloc, expr, &.{}, &.{}, &interner, &errors);
    try std.testing.expect(errors.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, errors.items[0].message, "attribute substitution exceeded maximum AST depth") != null);
}

test "marker attribute diagnostic formatting propagates OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const attr_name = try interner.intern("debug");
    const attr_ref = try setup_alloc.create(ast.Expr);
    attr_ref.* = .{ .attr_ref = .{ .meta = .{ .span = span }, .name = attr_name } };

    const attrs = [_]scope.Attribute{.{ .name = attr_name }};

    var fail_once_allocator = FailOnceAllocator.init(std.testing.allocator, 0);
    const failing_alloc = fail_once_allocator.allocator();

    var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
    defer errors.deinit(failing_alloc);

    try std.testing.expectError(
        error.OutOfMemory,
        substituteInExpr(failing_alloc, attr_ref, attrs[0..], &.{}, &interner, &errors),
    );
    try std.testing.expect(fail_once_allocator.failed);
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "undefined attribute diagnostic formatting propagates OutOfMemory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const attr_name = try interner.intern("missing");
    const attr_ref = try setup_alloc.create(ast.Expr);
    attr_ref.* = .{ .attr_ref = .{ .meta = .{ .span = span }, .name = attr_name } };

    var fail_once_allocator = FailOnceAllocator.init(std.testing.allocator, 0);
    const failing_alloc = fail_once_allocator.allocator();

    var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
    defer errors.deinit(failing_alloc);

    try std.testing.expectError(
        error.OutOfMemory,
        substituteInExpr(failing_alloc, attr_ref, &.{}, &.{}, &interner, &errors),
    );
    try std.testing.expect(fail_once_allocator.failed);
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "substituteAttributes borrows scope attribute lists without scratch leaks" {
    const allocator = std.testing.allocator;

    var setup_arena = std.heap.ArenaAllocator.init(allocator);
    defer setup_arena.deinit();
    const setup_alloc = setup_arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    var graph = try scope.ScopeGraph.init(allocator);
    defer graph.deinit();

    const struct_name_id = try interner.intern("Example");
    const function_name_id = try interner.intern("value");
    const struct_attr_id = try interner.intern("struct_attr");
    const function_attr_id = try interner.intern("function_attr");
    const span = ast.SourceSpan{ .start = 10, .end = 20 };

    const literal_expr = try setup_alloc.create(ast.Expr);
    literal_expr.* = .{ .int_literal = .{ .meta = .{ .span = span }, .value = 42 } };
    const body = [_]ast.Stmt{.{ .expr = literal_expr }};
    const clauses = [_]ast.FunctionClause{.{
        .meta = .{ .span = .{ .start = 21, .end = 30 } },
        .params = &.{},
        .return_type = null,
        .refinement = null,
        .body = body[0..],
    }};
    const function_decl = try setup_alloc.create(ast.FunctionDecl);
    function_decl.* = .{
        .meta = .{ .span = .{ .start = 31, .end = 40 } },
        .name = function_name_id,
        .clauses = clauses[0..],
        .visibility = .public,
    };
    const items = [_]ast.StructItem{.{ .function = function_decl }};
    const name_parts = [_]ast.StringId{struct_name_id};
    const struct_decl = ast.StructDecl{
        .meta = .{ .span = span },
        .name = .{ .parts = name_parts[0..], .span = span },
        .items = items[0..],
    };
    const structs = [_]ast.StructDecl{struct_decl};
    const program = ast.Program{
        .structs = structs[0..],
        .top_items = &.{},
    };

    const struct_scope = try graph.createScope(graph.prelude_scope, .struct_scope);
    try graph.node_scope_map.put(scope.ScopeGraph.spanKey(span), struct_scope);
    try graph.registerStruct(struct_decl.name, struct_scope, &structs[0]);
    try graph.structs.items[0].attributes.append(allocator, .{
        .name = struct_attr_id,
        .value = literal_expr,
    });
    const family_id = try graph.createFamily(struct_scope, function_name_id, 0, .public);
    try graph.getFamilyMut(family_id).attributes.append(allocator, .{
        .name = function_attr_id,
        .value = literal_expr,
    });

    var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
    defer errors.deinit(allocator);

    const substituted = try substituteAttributes(allocator, &program, &graph, &interner, &errors);
    defer {
        freeOwnedSlice(allocator, substituted.structs[0].items);
        freeOwnedSlice(allocator, substituted.structs);
    }

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), substituted.structs.len);
    try std.testing.expectEqual(@as(usize, 1), substituted.structs[0].items.len);
}

test "replacement AST owner frees partial call replacement on allocation failure" {
    var setup_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup_arena.deinit();
    const setup_alloc = setup_arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const attr_name = try interner.intern("computed");
    const callee_name = try interner.intern("consume");

    const attr_ref = try setup_alloc.create(ast.Expr);
    attr_ref.* = .{ .attr_ref = .{ .meta = .{ .span = span }, .name = attr_name } };
    const callee = try setup_alloc.create(ast.Expr);
    callee.* = .{ .var_ref = .{ .meta = .{ .span = span }, .name = callee_name } };
    const args = [_]*const ast.Expr{attr_ref};
    const call = try setup_alloc.create(ast.Expr);
    call.* = .{ .call = .{
        .meta = .{ .span = span },
        .callee = callee,
        .args = args[0..],
    } };

    const computed_items = [_]ctfe.ConstValue{ .{ .int = 1 }, .{ .int = 2 } };
    const attrs = [_]scope.Attribute{.{
        .name = attr_name,
        .computed_value = .{ .list = computed_items[0..] },
    }};

    var saw_failure = false;
    var saw_late_failure = false;
    var saw_success_boundary = false;
    for (0..32) |fail_index| {
        var fail_once_allocator = FailOnceAllocator.init(std.testing.allocator, fail_index);
        const failing_alloc = fail_once_allocator.allocator();

        var owner = SubstitutionOwner.init(failing_alloc);
        defer owner.deinit();

        var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
        defer errors.deinit(failing_alloc);

        _ = substituteInExprDepth(&owner, failing_alloc, call, attrs[0..], &.{}, &interner, &errors, 0) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(fail_once_allocator.failed);
            try std.testing.expectEqual(@as(usize, 0), errors.items.len);
            saw_failure = true;
            if (fail_once_allocator.allocation_index >= 5) saw_late_failure = true;
            continue;
        };

        try std.testing.expectEqual(@as(usize, 0), errors.items.len);
        if (!fail_once_allocator.failed) {
            saw_success_boundary = true;
            break;
        }
    }

    try std.testing.expect(saw_failure);
    try std.testing.expect(saw_late_failure);
    try std.testing.expect(saw_success_boundary);
}

test "computed attribute reification OutOfMemory does not fall back to raw AST value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const setup_alloc = arena.allocator();

    var interner = ast.StringInterner.init(setup_alloc);
    defer interner.deinit();

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const attr_name = try interner.intern("bad");

    const raw_value = try setup_alloc.create(ast.Expr);
    raw_value.* = .{ .int_literal = .{ .meta = .{ .span = span }, .value = 42 } };

    const attr_ref = try setup_alloc.create(ast.Expr);
    attr_ref.* = .{ .attr_ref = .{ .meta = .{ .span = span }, .name = attr_name } };

    const attrs = [_]scope.Attribute{.{
        .name = attr_name,
        .value = raw_value,
        .computed_value = .{ .tuple = &.{.{ .int = 1 }} },
    }};

    var backing_buffer: [0]u8 = .{};
    var fixed_buffer = std.heap.FixedBufferAllocator.init(&backing_buffer);
    const failing_alloc = fixed_buffer.allocator();

    var errors: std.ArrayListUnmanaged(SubstitutionError) = .empty;
    defer errors.deinit(setup_alloc);

    try std.testing.expectError(
        error.OutOfMemory,
        substituteInExpr(failing_alloc, attr_ref, attrs[0..], &.{}, &interner, &errors),
    );
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}
