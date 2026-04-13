const std = @import("std");
const hir = @import("hir.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");

const TypeId = types_mod.TypeId;
const TypeStore = types_mod.TypeStore;
const SubstitutionMap = types_mod.SubstitutionMap;
const Allocator = std.mem.Allocator;

/// Result of the monomorphization pass.
pub const MonomorphResult = struct {
    /// The transformed program with specialized function groups added.
    program: hir.Program,
    /// Number of specializations created.
    specialization_count: u32,
};

/// Run the monomorphization pass on a HIR program.
///
/// For each function group with type-variable parameters, scans all call
/// sites in the program to find concrete instantiations. Creates specialized
/// copies of the generic function with concrete types substituted, and
/// rewires call sites to point to the specialized versions.
pub fn monomorphize(
    allocator: Allocator,
    program: *const hir.Program,
    store: *TypeStore,
    next_group_id: *u32,
) !MonomorphResult {
    var ctx = MonomorphContext{
        .allocator = allocator,
        .store = store,
        .next_group_id = next_group_id,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(allocator),
        .specializations = std.AutoHashMap(u64, u32).init(allocator),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(allocator),
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.new_groups.deinit(allocator);
    defer ctx.call_rewrites.deinit();

    // Phase A: Identify generic function groups (those with type_var params)
    for (program.modules) |mod| {
        for (mod.functions) |*group| {
            if (isGenericGroup(store, group)) {
                try ctx.generic_groups.put(group.id, group);
            }
        }
    }
    for (program.top_functions) |*group| {
        if (isGenericGroup(store, group)) {
            try ctx.generic_groups.put(group.id, group);
        }
    }

    // If no generic functions, return the program unchanged
    if (ctx.generic_groups.count() == 0) {
        return .{ .program = program.*, .specialization_count = 0 };
    }

    // Phase B: Scan all call sites, collect instantiations, create specializations
    for (program.modules) |mod| {
        for (mod.functions) |*group| {
            for (group.clauses) |clause| {
                try ctx.scanBlock(clause.body);
            }
        }
    }
    for (program.top_functions) |*group| {
        for (group.clauses) |clause| {
            try ctx.scanBlock(clause.body);
        }
    }

    // Phase C: Build new program with specialized groups added.
    // For each module, add any specializations that originated from its functions.
    var new_modules: std.ArrayListUnmanaged(hir.Module) = .empty;
    for (program.modules) |mod| {
        var new_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
        for (mod.functions) |group| {
            try new_fns.append(allocator, group);
        }
        // Add specializations of functions from this module
        for (ctx.new_groups.items) |entry| {
            // Check if the specialization's source group belongs to this module
            for (mod.functions) |orig_group| {
                if (entry.source_group_id == orig_group.id) {
                    try new_fns.append(allocator, entry.group);
                }
            }
        }
        try new_modules.append(allocator, .{
            .name = mod.name,
            .scope_id = mod.scope_id,
            .functions = try new_fns.toOwnedSlice(allocator),
            .types = mod.types,
        });
    }

    // Phase D: Rewrite call sites in all expressions
    for (new_modules.items) |*mod| {
        for (mod.functions) |*group| {
            for (group.clauses) |clause| {
                ctx.rewriteBlock(clause.body);
            }
        }
    }

    return .{
        .program = .{
            .modules = try new_modules.toOwnedSlice(allocator),
            .top_functions = program.top_functions,
        },
        .specialization_count = @intCast(ctx.new_groups.items.len),
    };
}

const NewGroupEntry = struct {
    group: hir.FunctionGroup,
    source_group_id: u32,
};

const MonomorphContext = struct {
    allocator: Allocator,
    store: *TypeStore,
    next_group_id: *u32,
    /// Map from group_id → FunctionGroup for generic functions
    generic_groups: std.AutoHashMap(u32, *const hir.FunctionGroup),
    /// Map from hash(group_id, type_args) → specialized group_id
    specializations: std.AutoHashMap(u64, u32),
    /// Newly created specialized groups
    new_groups: std.ArrayListUnmanaged(NewGroupEntry),
    /// Map from (call_site_hash) → new_group_id for rewriting
    call_rewrites: std.AutoHashMap(u64, u32),

    fn scanBlock(self: *MonomorphContext, block: *const hir.Block) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| try self.scanExpr(e),
                .local_set => |ls| try self.scanExpr(ls.value),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanBlock(clause.body);
                    }
                },
            }
        }
    }

    fn scanExpr(self: *MonomorphContext, expr: *const hir.Expr) error{OutOfMemory}!void {
        switch (expr.kind) {
            .call => |call| {
                // Scan args first (may contain nested calls)
                for (call.args) |arg| {
                    try self.scanExpr(arg.expr);
                }

                // Check if this calls a generic function
                const target_id = switch (call.target) {
                    .direct => |dc| dc.function_group_id,
                    .dispatch => |dp| dp.function_group_id,
                    else => return,
                };

                const generic_group = self.generic_groups.get(target_id) orelse return;

                // Unify arg types with param types to find type variable bindings
                if (generic_group.clauses.len == 0) return;
                const first_clause = &generic_group.clauses[0];
                if (first_clause.params.len != call.args.len) return;

                var subs = SubstitutionMap.init(self.allocator);
                defer subs.deinit();

                var can_specialize = true;
                for (first_clause.params, call.args) |param, arg| {
                    if (!(self.store.unify(param.type_id, arg.expr.type_id, &subs) catch false)) {
                        can_specialize = false;
                        break;
                    }
                }

                if (!can_specialize) return;

                // Collect concrete type args (the bound type variables)
                var type_args: std.ArrayListUnmanaged(TypeId) = .empty;
                defer type_args.deinit(self.allocator);
                var it = subs.bindings.iterator();
                while (it.next()) |entry| {
                    try type_args.append(self.allocator, entry.value_ptr.*);
                }

                if (type_args.items.len == 0) return; // Not actually generic

                // Check if this instantiation already exists
                const key = hashInstantiation(target_id, type_args.items);
                if (self.specializations.get(key)) |_| return;

                // Create specialized clone
                const new_id = self.next_group_id.*;
                self.next_group_id.* += 1;

                const specialized = try self.cloneGroupWithSubs(generic_group, &subs, new_id);
                try self.new_groups.append(self.allocator, .{
                    .group = specialized,
                    .source_group_id = target_id,
                });
                try self.specializations.put(key, new_id);
            },
            // Recurse into sub-expressions
            .binary => |b| {
                try self.scanExpr(b.lhs);
                try self.scanExpr(b.rhs);
            },
            .unary => |u| try self.scanExpr(u.operand),
            .tuple_init => |elems| {
                for (elems) |e| try self.scanExpr(e);
            },
            .list_init => |elems| {
                for (elems) |e| try self.scanExpr(e);
            },
            .list_cons => |lc| {
                try self.scanExpr(lc.head);
                try self.scanExpr(lc.tail);
            },
            .map_init => |entries| {
                for (entries) |entry| {
                    try self.scanExpr(entry.key);
                    try self.scanExpr(entry.value);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| {
                    try self.scanExpr(field.value);
                }
            },
            .field_get => |fg| try self.scanExpr(fg.object),
            .branch => |br| {
                try self.scanExpr(br.condition);
                try self.scanBlock(br.then_block);
                if (br.else_block) |eb| try self.scanBlock(eb);
            },
            .block => |b| try self.scanBlock(&b),
            .panic => |e| try self.scanExpr(e),
            .unwrap => |e| try self.scanExpr(e),
            .union_init => |ui| try self.scanExpr(ui.value),
            .error_pipe => |ep| {
                for (ep.steps) |step| {
                    try self.scanExpr(step.expr);
                }
                try self.scanExpr(ep.handler);
            },
            .case => |cd| {
                try self.scanExpr(cd.scrutinee);
                for (cd.arms) |arm| {
                    try self.scanBlock(arm.body);
                }
            },
            .match => |m| try self.scanExpr(m.scrutinee),
            .closure_create => {},
            // Literals and refs — no sub-expressions
            .int_lit, .float_lit, .string_lit, .atom_lit, .bool_lit, .nil_lit => {},
            .local_get, .param_get, .capture_get => {},
            .never => {},
        }
    }

    fn cloneGroupWithSubs(
        self: *MonomorphContext,
        group: *const hir.FunctionGroup,
        subs: *const SubstitutionMap,
        new_id: u32,
    ) !hir.FunctionGroup {
        var new_clauses: std.ArrayListUnmanaged(hir.Clause) = .empty;
        for (group.clauses) |clause| {
            // Substitute types in params
            var new_params = try self.allocator.alloc(hir.TypedParam, clause.params.len);
            for (clause.params, 0..) |param, i| {
                new_params[i] = .{
                    .name = param.name,
                    .type_id = subs.applyToType(self.store, param.type_id),
                    .ownership = param.ownership,
                    .pattern = param.pattern,
                    .default = param.default,
                };
            }

            try new_clauses.append(self.allocator, .{
                .params = new_params,
                .return_type = subs.applyToType(self.store, clause.return_type),
                .decision = clause.decision,
                .body = clause.body,
                .refinement = clause.refinement,
                .tuple_bindings = clause.tuple_bindings,
                .struct_bindings = clause.struct_bindings,
                .list_bindings = clause.list_bindings,
                .binary_bindings = clause.binary_bindings,
                .map_bindings = clause.map_bindings,
            });
        }

        return .{
            .id = new_id,
            .scope_id = group.scope_id,
            .name = group.name,
            .arity = group.arity,
            .is_local = group.is_local,
            .captures = group.captures,
            .clauses = try new_clauses.toOwnedSlice(self.allocator),
            .fallback_parent = group.fallback_parent,
        };
    }

    fn rewriteBlock(self: *MonomorphContext, block: *const hir.Block) void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| self.rewriteExpr(e),
                .local_set => |ls| self.rewriteExpr(ls.value),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        self.rewriteBlock(clause.body);
                    }
                },
            }
        }
    }

    fn rewriteExpr(self: *MonomorphContext, expr: *const hir.Expr) void {
        switch (expr.kind) {
            .call => |call| {
                // Rewrite call target if it points to a generic function
                const target_id = switch (call.target) {
                    .direct => |dc| dc.function_group_id,
                    .dispatch => |dp| dp.function_group_id,
                    else => return,
                };

                if (self.generic_groups.get(target_id) == null) return;

                // Find the specialization for this call's arg types
                const generic_group = self.generic_groups.get(target_id).?;
                if (generic_group.clauses.len == 0) return;
                const first_clause = &generic_group.clauses[0];
                if (first_clause.params.len != call.args.len) return;

                var subs = SubstitutionMap.init(self.allocator);
                defer subs.deinit();
                for (first_clause.params, call.args) |param, arg| {
                    _ = self.store.unify(param.type_id, arg.expr.type_id, &subs) catch {};
                }

                var type_args: std.ArrayListUnmanaged(TypeId) = .empty;
                defer type_args.deinit(self.allocator);
                var it = subs.bindings.iterator();
                while (it.next()) |entry| {
                    type_args.append(self.allocator, entry.value_ptr.*) catch {};
                }

                const key = hashInstantiation(target_id, type_args.items);
                if (self.specializations.get(key)) |new_id| {
                    // Rewrite the call target (cast away const for mutation)
                    const mutable_expr: *hir.Expr = @constCast(expr);
                    switch (mutable_expr.kind) {
                        .call => |*c| {
                            switch (c.target) {
                                .direct => |*dc| dc.function_group_id = new_id,
                                .dispatch => |*dp| dp.function_group_id = new_id,
                                else => {},
                            }
                        },
                        else => {},
                    }
                }

                // Recurse into args
                for (call.args) |arg| self.rewriteExpr(arg.expr);
            },
            .binary => |b| {
                self.rewriteExpr(b.lhs);
                self.rewriteExpr(b.rhs);
            },
            .unary => |u| self.rewriteExpr(u.operand),
            .tuple_init => |elems| {
                for (elems) |e| self.rewriteExpr(e);
            },
            .list_init => |elems| {
                for (elems) |e| self.rewriteExpr(e);
            },
            .list_cons => |lc| {
                self.rewriteExpr(lc.head);
                self.rewriteExpr(lc.tail);
            },
            .branch => |br| {
                self.rewriteExpr(br.condition);
                self.rewriteBlock(br.then_block);
                if (br.else_block) |eb| self.rewriteBlock(eb);
            },
            .block => |b| self.rewriteBlock(&b),
            .panic => |e| self.rewriteExpr(e),
            .unwrap => |e| self.rewriteExpr(e),
            .union_init => |ui| self.rewriteExpr(ui.value),
            .case => |cd| {
                self.rewriteExpr(cd.scrutinee);
                for (cd.arms) |arm| self.rewriteBlock(arm.body);
            },
            else => {},
        }
    }
};

/// Check if a function group has type variable parameters (is generic).
fn isGenericGroup(store: *const TypeStore, group: *const hir.FunctionGroup) bool {
    if (group.clauses.len == 0) return false;
    const first_clause = &group.clauses[0];
    for (first_clause.params) |param| {
        if (containsTypeVar(store, param.type_id)) return true;
    }
    // Also check return type
    if (containsTypeVar(store, first_clause.return_type)) return true;
    return false;
}

/// Check if a TypeId contains any type variables (recursively).
fn containsTypeVar(store: *const TypeStore, type_id: TypeId) bool {
    const typ = store.getType(type_id);
    return switch (typ) {
        .type_var => true,
        .list => |lt| containsTypeVar(store, lt.element),
        .tuple => |tt| {
            for (tt.elements) |elem| {
                if (containsTypeVar(store, elem)) return true;
            }
            return false;
        },
        .function => |ft| {
            for (ft.params) |param| {
                if (containsTypeVar(store, param)) return true;
            }
            return containsTypeVar(store, ft.return_type);
        },
        .map => |mt| containsTypeVar(store, mt.key) or containsTypeVar(store, mt.value),
        .applied => |at| {
            for (at.args) |arg| {
                if (containsTypeVar(store, arg)) return true;
            }
            return false;
        },
        else => false,
    };
}

/// Hash a (group_id, type_args) pair for deduplication.
fn hashInstantiation(group_id: u32, type_args: []const TypeId) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&group_id));
    for (type_args) |arg| {
        hasher.update(std.mem.asBytes(&arg));
    }
    return hasher.final();
}
