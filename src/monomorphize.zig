const std = @import("std");
const ast = @import("ast.zig");
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
    interner: *ast.StringInterner,
) !MonomorphResult {
    var ctx = MonomorphContext{
        .allocator = allocator,
        .store = store,
        .next_group_id = next_group_id,
        .interner = interner,
        .program = program,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(allocator),
        .specializations = std.AutoHashMap(u64, u32).init(allocator),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(allocator),
        .local_types = std.AutoHashMap(u32, TypeId).init(allocator),
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.new_groups.deinit(allocator);
    defer ctx.call_rewrites.deinit();
    defer ctx.local_types.deinit();

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

    // Phase B: Scan all call sites, collect instantiations, create specializations.
    // After the initial scan, rescan newly created specializations until no more
    // are produced (transitive closure — e.g. Enum.take calls List.take internally).
    for (program.modules, 0..) |mod, mod_idx| {
        ctx.current_scan_module_idx = mod_idx;
        for (mod.functions) |*group| {
            for (group.clauses) |clause| {
                ctx.local_types.clearRetainingCapacity();
                try ctx.scanBlock(clause.body);
            }
        }
    }
    ctx.current_scan_module_idx = null;
    for (program.top_functions) |*group| {
        for (group.clauses) |clause| {
            ctx.local_types.clearRetainingCapacity();
            try ctx.scanBlock(clause.body);
        }
    }

    // Transitive scan: rescan newly created specializations until fixpoint.
    // Each specialization may contain calls to other generic functions that
    // also need specialization (e.g. Enum.take → List.take).
    // Skip specializations that are still generic (contain type vars) — they
    // came from scanning generic function bodies before the skip was added
    // or from partial unifications, and their bodies would just create more
    // bogus generic specializations.
    // Transitive scan: rescan newly created specializations until fixpoint.
    {
        var scan_start: usize = 0;
        var transitive_iterations: u32 = 0;
        while (scan_start < ctx.new_groups.items.len) {
            transitive_iterations += 1;
            if (transitive_iterations > 10) break; // Safety limit
            const scan_end = ctx.new_groups.items.len;
            // Copy entries to scan since scanning may append to new_groups,
            // which can reallocate and invalidate the items slice.
            var entries_to_scan: std.ArrayListUnmanaged(NewGroupEntry) = .empty;
            for (ctx.new_groups.items[scan_start..scan_end]) |entry| {
                if (!isGenericGroup(store, &entry.group)) {
                    entries_to_scan.append(allocator, entry) catch break;
                }
            }
            for (entries_to_scan.items) |entry| {
                ctx.current_scan_module_idx = entry.target_module_idx;
                for (entry.group.clauses) |clause| {
                    ctx.current_scan_params = clause.params;
                    ctx.local_types.clearRetainingCapacity();
                    try ctx.scanBlock(clause.body);
                    ctx.current_scan_params = null;
                }
            }
            entries_to_scan.deinit(allocator);
            scan_start = scan_end;
        }
        ctx.current_scan_module_idx = null;
    }
    // Phase C: Build new program with specialized groups added.
    // Specializations are placed in the CALLING module (target_module_idx)
    // so that cross-module direct calls resolve within the same module's IR.
    // If target_module_idx is null, fall back to placing in the defining module.
    var new_modules: std.ArrayListUnmanaged(hir.Module) = .empty;
    for (program.modules, 0..) |mod, mod_idx| {
        var new_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
        for (mod.functions) |group| {
            try new_fns.append(allocator, group);
        }
        for (ctx.new_groups.items) |entry| {
            if (entry.target_module_idx) |target_idx| {
                // Cross-module: place in calling module
                if (target_idx == mod_idx) {
                    try new_fns.append(allocator, entry.group);
                }
            } else {
                // Intra-module: place in defining module
                for (mod.functions) |orig_group| {
                    if (entry.source_group_id == orig_group.id) {
                        try new_fns.append(allocator, entry.group);
                    }
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

    // Also handle top-level functions: add specializations and collect into new slice
    var new_top_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
    for (program.top_functions) |group| {
        try new_top_fns.append(allocator, group);
    }
    for (ctx.new_groups.items) |entry| {
        for (program.top_functions) |orig_group| {
            if (entry.source_group_id == orig_group.id) {
                try new_top_fns.append(allocator, entry.group);
            }
        }
    }

    // Phase D: Rewrite call sites in all expressions (modules + top functions)
    for (new_modules.items) |*mod| {
        for (mod.functions) |*group| {
            for (group.clauses) |clause| {
                ctx.rewriteBlock(clause.body);
            }
        }
    }
    for (new_top_fns.items) |*group| {
        for (group.clauses) |clause| {
            ctx.rewriteBlock(clause.body);
        }
    }

    return .{
        .program = .{
            .modules = try new_modules.toOwnedSlice(allocator),
            .top_functions = try new_top_fns.toOwnedSlice(allocator),
        },
        .specialization_count = @intCast(ctx.new_groups.items.len),
    };
}

const NewGroupEntry = struct {
    group: hir.FunctionGroup,
    source_group_id: u32,
    /// Module index where this specialization should be placed.
    /// For cross-module calls, this is the CALLING module, not the defining module.
    target_module_idx: ?usize = null,
};

const MonomorphContext = struct {
    allocator: Allocator,
    store: *TypeStore,
    next_group_id: *u32,
    interner: *ast.StringInterner,
    /// Reference to the whole HIR program for resolving named cross-module calls
    program: *const hir.Program,
    /// Current module index being scanned (for placing specializations)
    current_scan_module_idx: ?usize = null,
    /// Current function params during scan — used to resolve param_get types
    /// in specialized copies where cloneExpr may not have fully substituted types.
    current_scan_params: ?[]const hir.TypedParam = null,
    /// Tracks concrete types for local variables during scanning.
    /// When a local_set assigns from a call that was specialized, the local
    /// gets the concrete return type. Later local_get references can use this.
    local_types: std.AutoHashMap(u32, TypeId),
    /// Active substitution map during cloning. Set by cloneGroupWithSubs,
    /// used by cloneExpr/cloneDecision to substitute type_ids.
    current_subs: ?*const SubstitutionMap = null,
    /// Map from group_id → FunctionGroup for generic functions
    generic_groups: std.AutoHashMap(u32, *const hir.FunctionGroup),
    /// Map from hash(group_id, type_args) → specialized group_id
    specializations: std.AutoHashMap(u64, u32),
    /// Newly created specialized groups
    new_groups: std.ArrayListUnmanaged(NewGroupEntry),
    /// Map from (call_site_hash) → new_group_id for rewriting
    call_rewrites: std.AutoHashMap(u64, u32),

    /// Check if a named call targets a protocol (e.g., Enumerable.each).
    /// Returns the protocol name StringId if it matches a registered protocol.
    fn isProtocolCall(self: *const MonomorphContext, nc: hir.NamedCall) ?ast.StringId {
        const target_module = nc.module orelse return null;
        for (self.program.protocols) |proto| {
            const proto_str = self.interner.get(proto.name);
            if (std.mem.eql(u8, proto_str, target_module)) {
                return proto.name;
            }
        }
        return null;
    }

    /// Infer the target module name from a concrete type.
    /// list(T) → "List", map(K,V) → "Map", struct → struct name
    /// Map a concrete type to the module name that implements protocols
    /// for that type. Every type variant must have an explicit mapping —
    /// no silent fallthrough to null.
    /// Map a concrete type to the module name that implements protocols
    /// for that type. Uses the type system's variant names to derive
    /// the implementing module. New types (structs, unions) use their
    /// declared name directly.
    fn inferTargetModuleName(self: *const MonomorphContext, type_id: TypeId) ?[]const u8 {
        if (type_id >= self.store.types.items.len) return null;
        const typ = self.store.types.items[type_id];
        return switch (typ) {
            .list => "List",
            .map => "Map",
            .struct_type => |s| self.interner.get(s.name),
            .tagged_union => |tu| self.interner.get(tu.name),
            .union_type => null, // anonymous unions don't have module names
            .string_type => "String",
            .int => "Integer",
            .float => "Float",
            .bool_type => "Bool",
            .atom_type => "Atom",
            .tuple => "Tuple",
            .function => "Function",
            .nil_type => null,
            .never => null,
            .type_var, .applied, .opaque_type, .protocol_constraint,
            .unknown, .error_type,
            => null,
        };
    }

    /// Resolve a protocol dispatch: given a protocol name, function name,
    /// and concrete argument type, find the impl's function group ID.
    fn resolveProtocolDispatch(
        self: *const MonomorphContext,
        protocol_name: ast.StringId,
        function_name: []const u8,
        concrete_type: TypeId,
        arity: u32,
    ) ?u32 {
        const target_module_name = self.inferTargetModuleName(concrete_type) orelse return null;

        for (self.program.impls) |impl_info| {
            if (impl_info.protocol_name != protocol_name) continue;
            if (!std.mem.eql(u8, self.interner.get(impl_info.target_module), target_module_name)) continue;

            // Found the impl. Search its function groups for the matching function.
            for (impl_info.function_group_ids) |gid| {
                // Search top-level functions for this group ID
                for (self.program.top_functions) |*group| {
                    if (group.id == gid and
                        std.mem.eql(u8, self.interner.get(group.name), function_name) and
                        group.arity == arity)
                    {
                        return gid;
                    }
                }
            }
        }
        return null;
    }

    /// Resolve a named cross-module call (e.g., List.head) to a function group ID
    /// by searching all modules in the HIR program.
    fn resolveNamedCall(self: *const MonomorphContext, nc: hir.NamedCall, arity: u32) ?u32 {
        const target_module = nc.module orelse return null;
        for (self.program.modules) |mod| {
            // Check if this module's name matches the target
            if (mod.name.parts.len == 0) continue;
            const last_part = self.interner.get(mod.name.parts[mod.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, target_module)) continue;
            // Search for the function by name and arity
            for (mod.functions) |*group| {
                const group_name = self.interner.get(group.name);
                if (std.mem.eql(u8, group_name, nc.name) and group.arity == arity) {
                    return group.id;
                }
            }
        }
        return null;
    }

    fn scanBlock(self: *MonomorphContext, block: *const hir.Block) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| try self.scanExpr(e),
                .local_set => |ls| {
                    try self.scanExpr(ls.value);
                    // Track the concrete type of this local for later local_get resolution.
                    // After scanning, the value's type_id may have been updated to concrete.
                    const val_type = ls.value.type_id;
                    if (!self.store.containsTypeVars(val_type) and val_type != types_mod.TypeStore.UNKNOWN) {
                        try self.local_types.put(ls.index, val_type);
                    }
                },
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

                // Check if this calls a generic function or a protocol function
                const target_id = switch (call.target) {
                    .direct => |dc| dc.function_group_id,
                    .dispatch => |dp| dp.function_group_id,
                    .named => |nc| blk: {
                        // Check for protocol dispatch: Enumerable.each(list, callback)
                        if (self.isProtocolCall(nc)) |proto_name| {
                            // Find the concrete type from the first argument
                            if (call.args.len > 0) {
                                var arg_type = call.args[0].expr.type_id;
                                // Resolve local_get types
                                if (self.store.containsTypeVars(arg_type) and call.args[0].expr.kind == .local_get) {
                                    if (self.local_types.get(call.args[0].expr.kind.local_get)) |concrete| {
                                        arg_type = concrete;
                                    }
                                }
                                // Resolve param_get types
                                if (self.store.containsTypeVars(arg_type) and call.args[0].expr.kind == .param_get and self.current_scan_params != null) {
                                    const pidx = call.args[0].expr.kind.param_get;
                                    if (pidx < self.current_scan_params.?.len) {
                                        const scan_param_type = self.current_scan_params.?[pidx].type_id;
                                        if (!self.store.containsTypeVars(scan_param_type)) {
                                            arg_type = scan_param_type;
                                        }
                                    }
                                }
                                if (!self.store.containsTypeVars(arg_type) and arg_type != types_mod.TypeStore.UNKNOWN) {
                                    if (self.resolveProtocolDispatch(proto_name, nc.name, arg_type, @intCast(call.args.len))) |impl_gid| {
                                        // Don't record rewrite here — let the generic
                                        // specialization path handle it after unification.
                                        // The impl function is generic and needs monomorphization.
                                        break :blk impl_gid;
                                    }
                                }
                            }
                            return; // Can't resolve protocol dispatch — skip
                        }
                        const resolved = self.resolveNamedCall(nc, @intCast(call.args.len)) orelse return;
                        break :blk resolved;
                    },
                    else => return,
                };

                const generic_group = self.generic_groups.get(target_id) orelse {
                    return;
                };

                // Unify arg types with param types to find type variable bindings
                if (generic_group.clauses.len == 0) return;
                const first_clause = &generic_group.clauses[0];
                if (first_clause.params.len != call.args.len) return;

                var subs = SubstitutionMap.init(self.allocator);
                defer subs.deinit();

                // Unify argument types with parameter types. UNKNOWN arguments
                // are skipped rather than failing — partial unification allows
                // type variables to be bound from the arguments that ARE known
                // (e.g., binding element=i64 from the list arg even when the
                // callback arg is an unresolved function reference).
                for (first_clause.params, call.args) |param, arg| {
                    var arg_type = arg.expr.type_id;
                    // If the argument is a call that was already specialized,
                    // use the specialization's return type as the arg type.
                    // This handles nested calls like List.empty?(Enum.map([], f))
                    // where the inner call has a concrete return type.
                    if (self.store.containsTypeVars(arg_type) and arg.expr.kind == .call) {
                        if (self.call_rewrites.get(@intFromPtr(arg.expr))) |spec_id| {
                            for (self.new_groups.items) |entry| {
                                if (entry.group.id == spec_id and entry.group.clauses.len > 0) {
                                    const spec_ret = entry.group.clauses[0].return_type;
                                    if (!self.store.containsTypeVars(spec_ret)) {
                                        arg_type = spec_ret;
                                    }
                                    break;
                                }
                            }
                        }
                    }
                    // If the argument is a local_get, use the tracked concrete type
                    // from the local_set that assigned it.
                    if (self.store.containsTypeVars(arg_type) and arg.expr.kind == .local_get) {
                        if (self.local_types.get(arg.expr.kind.local_get)) |concrete| {
                            arg_type = concrete;
                        }
                    }
                    // If the argument is a param_get inside a specialized function,
                    // use the specialized param's concrete type instead of the
                    // expression type which may not have been substituted correctly.
                    if (arg.expr.kind == .param_get and self.current_scan_params != null) {
                        const pidx = arg.expr.kind.param_get;
                        if (pidx < self.current_scan_params.?.len) {
                            const scan_param_type = self.current_scan_params.?[pidx].type_id;
                            if (!self.store.containsTypeVars(scan_param_type)) {
                                arg_type = scan_param_type;
                            }
                        }
                    }
                    // Empty list default
                    if (arg_type == types_mod.TypeStore.UNKNOWN) {
                        const param_typ = self.store.getType(param.type_id);
                        if (std.meta.activeTag(param_typ) == .list) {
                            if (arg.expr.kind == .list_init) {
                                arg_type = self.store.addType(.{ .list = .{ .element = types_mod.TypeStore.I64 } }) catch types_mod.TypeStore.UNKNOWN;
                            }
                        }
                        // Empty map default
                        if (std.meta.activeTag(param_typ) == .map) {
                            if (arg.expr.kind == .map_init) {
                                arg_type = self.store.addType(.{ .map = .{ .key = types_mod.TypeStore.ATOM, .value = types_mod.TypeStore.I64 } }) catch types_mod.TypeStore.UNKNOWN;
                            }
                        }
                    }
                    if (arg_type == types_mod.TypeStore.UNKNOWN or arg_type == types_mod.TypeStore.ERROR) continue;
                    _ = self.store.unify(param.type_id, arg_type, &subs) catch {};
                }

                // Collect concrete type args sorted by type variable ID for determinism
                var type_args: std.ArrayListUnmanaged(TypeId) = .empty;
                defer type_args.deinit(self.allocator);
                var var_ids: std.ArrayListUnmanaged(types_mod.TypeVarId) = .empty;
                defer var_ids.deinit(self.allocator);
                var it = subs.bindings.iterator();
                while (it.next()) |entry| {
                    try var_ids.append(self.allocator, entry.key_ptr.*);
                }
                std.mem.sort(types_mod.TypeVarId, var_ids.items, {}, std.sort.asc(types_mod.TypeVarId));
                for (var_ids.items) |var_id| {
                    if (subs.bindings.get(var_id)) |concrete| {
                        try type_args.append(self.allocator, concrete);
                    }
                }

                if (type_args.items.len == 0) return; // Not actually generic

                // Skip if any type arg still contains type variables — this happens
                // when scanning inside generic function bodies where args are unresolved.
                // Creating such specializations produces bogus stubs (e.g. head__T).
                {
                    var has_vars = false;
                    for (type_args.items) |ta| {
                        if (self.store.containsTypeVars(ta)) {
                            has_vars = true;
                            break;
                        }
                    }
                    if (has_vars) return;
                }

                // Check if this instantiation already exists for THIS module.
                // Each calling module needs its own copy of the specialization
                // so that call_direct resolves within the module's own IR.
                const module_salt: u32 = if (self.current_scan_module_idx) |idx| @intCast(idx) else 0;
                const base_key = hashInstantiation(target_id, type_args.items);
                const key = base_key +% @as(u64, module_salt) *% 0x9E3779B97F4A7C15;
                if (self.specializations.get(key)) |existing_id| {
                    // Already have a specialization for this module — just record the rewrite
                    try self.call_rewrites.put(@intFromPtr(expr), existing_id);
                    // Update type_id for nested call resolution.
                    // Apply subs to the GENERIC GROUP's return type (which uses the
                    // same type var IDs as the subs), NOT expr.type_id (which uses
                    // different type var IDs from the HIR builder's scope).
                    if (self.store.containsTypeVars(expr.type_id)) {
                        const concrete_return = subs.applyToType(self.store, first_clause.return_type);
                        if (!self.store.containsTypeVars(concrete_return)) {
                            @constCast(expr).type_id = concrete_return;
                        }
                    }
                    return;
                }

                // Create specialized clone
                const new_id = self.next_group_id.*;
                self.next_group_id.* += 1;

                const specialized = try self.cloneGroupWithSubs(generic_group, &subs, new_id);
                try self.new_groups.append(self.allocator, .{
                    .group = specialized,
                    .source_group_id = target_id,
                    .target_module_idx = self.current_scan_module_idx,
                });
                try self.specializations.put(key, new_id);
                // Record this specific call expression for rewriting
                try self.call_rewrites.put(@intFromPtr(expr), new_id);

                // Update the call expression's type_id to the concrete return type.
                // Apply subs to the GENERIC GROUP's return type (first_clause.return_type)
                // which uses the same type var IDs as the subs map. Do NOT use
                // expr.type_id because the HIR builder resolves type vars in a separate
                // scope, producing different type var IDs that aren't in the subs.
                if (self.store.containsTypeVars(expr.type_id)) {
                    const concrete_return = subs.applyToType(self.store, first_clause.return_type);
                    if (!self.store.containsTypeVars(concrete_return)) {
                        @constCast(expr).type_id = concrete_return;
                    }
                }
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
                    if (arm.guard) |g| try self.scanExpr(g);
                    try self.scanBlock(arm.body);
                }
            },
            .match => |m| try self.scanExpr(m.scrutinee),
            .closure_create => |cc| {
                for (cc.captures) |cap| try self.scanExpr(cap.expr);
            },
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
        const saved_subs = self.current_subs;
        self.current_subs = subs;
        defer self.current_subs = saved_subs;

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
                    .default = if (param.default) |d| try self.cloneExpr(d) else null,
                };
            }

            try new_clauses.append(self.allocator, .{
                .params = new_params,
                .return_type = subs.applyToType(self.store, clause.return_type),
                .decision = try self.cloneDecision(clause.decision),
                .body = try self.cloneBlock(clause.body),
                .refinement = if (clause.refinement) |r| try self.cloneExpr(r) else null,
                .tuple_bindings = clause.tuple_bindings,
                .struct_bindings = clause.struct_bindings,
                .list_bindings = clause.list_bindings,
                .cons_tail_bindings = clause.cons_tail_bindings,
                .binary_bindings = clause.binary_bindings,
                .map_bindings = clause.map_bindings,
            });
        }

        // Include source module name in the mangled specialization name to prevent
        // name collisions. Without this, List.empty?__i64 and Enum.empty?__i64
        // produce the same local_name in the calling module, causing the ZIR builder's
        // deduplication to remove one — the surviving function then calls itself.
        const base_name = self.interner.get(group.name);
        const source_module_prefix = blk: {
            for (self.program.modules) |mod| {
                for (mod.functions) |*g| {
                    if (g.id == group.id) {
                        if (mod.name.parts.len > 0) {
                            break :blk self.interner.get(mod.name.parts[mod.name.parts.len - 1]);
                        }
                    }
                }
            }
            break :blk "";
        };
        const qualified_base = if (source_module_prefix.len > 0)
            std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_module_prefix, base_name }) catch base_name
        else
            base_name;
        const mangled_str = mangleName(self.allocator, qualified_base, self.store, subs) catch qualified_base;
        const mangled_name = self.interner.intern(mangled_str) catch group.name;

        return .{
            .id = new_id,
            .scope_id = group.scope_id,
            .name = mangled_name,
            .arity = group.arity,
            .is_local = group.is_local,
            .captures = group.captures,
            .clauses = try new_clauses.toOwnedSlice(self.allocator),
            .fallback_parent = group.fallback_parent,
        };
    }

    // -- Deep cloning for specialized copies -----------------------------------

    fn cloneBlock(self: *MonomorphContext, block: *const hir.Block) !*const hir.Block {
        var new_stmts: std.ArrayListUnmanaged(hir.Stmt) = .empty;
        for (block.stmts) |stmt| {
            try new_stmts.append(self.allocator, try self.cloneStmt(stmt));
        }
        const result = try self.allocator.create(hir.Block);
        result.* = .{
            .stmts = try new_stmts.toOwnedSlice(self.allocator),
            .result_type = if (self.current_subs) |subs|
                subs.applyToType(self.store, block.result_type)
            else
                block.result_type,
        };
        return result;
    }

    fn cloneStmt(self: *MonomorphContext, stmt: hir.Stmt) !hir.Stmt {
        return switch (stmt) {
            .expr => |e| .{ .expr = try self.cloneExpr(e) },
            .local_set => |ls| .{ .local_set = .{
                .index = ls.index,
                .value = try self.cloneExpr(ls.value),
            } },
            .function_group => |fg| .{ .function_group = fg }, // local fns: share, not specialized
        };
    }

    fn cloneExpr(self: *MonomorphContext, expr: *const hir.Expr) error{OutOfMemory}!*const hir.Expr {
        const result = try self.allocator.create(hir.Expr);
        const substituted_type = if (self.current_subs) |subs|
            subs.applyToType(self.store, expr.type_id)
        else
            expr.type_id;
        result.* = .{
            .kind = try self.cloneExprKind(expr.kind),
            .type_id = substituted_type,
            .span = expr.span,
        };
        return result;
    }

    fn cloneExprKind(self: *MonomorphContext, kind: hir.ExprKind) error{OutOfMemory}!hir.ExprKind {
        return switch (kind) {
            // Literals and refs — no heap pointers to clone
            .int_lit, .float_lit, .string_lit, .atom_lit, .bool_lit, .nil_lit => kind,
            .local_get, .param_get, .capture_get => kind,
            .never => kind,

            .binary => |b| .{ .binary = .{
                .op = b.op,
                .lhs = try self.cloneExpr(b.lhs),
                .rhs = try self.cloneExpr(b.rhs),
            } },
            .unary => |u| .{ .unary = .{
                .op = u.op,
                .operand = try self.cloneExpr(u.operand),
            } },
            .call => |c| blk: {
                var new_args = try self.allocator.alloc(hir.CallArg, c.args.len);
                for (c.args, 0..) |arg, i| {
                    new_args[i] = .{
                        .expr = try self.cloneExpr(arg.expr),
                        .mode = arg.mode,
                        .expected_type = if (self.current_subs) |subs|
                            subs.applyToType(self.store, arg.expected_type)
                        else
                            arg.expected_type,
                    };
                }
                break :blk .{ .call = .{ .target = c.target, .args = new_args } };
            },
            .tuple_init => |elems| blk: {
                var new_elems = try self.allocator.alloc(*const hir.Expr, elems.len);
                for (elems, 0..) |e, i| new_elems[i] = try self.cloneExpr(e);
                break :blk .{ .tuple_init = new_elems };
            },
            .list_init => |elems| blk: {
                var new_elems = try self.allocator.alloc(*const hir.Expr, elems.len);
                for (elems, 0..) |e, i| new_elems[i] = try self.cloneExpr(e);
                break :blk .{ .list_init = new_elems };
            },
            .list_cons => |lc| .{ .list_cons = .{
                .head = try self.cloneExpr(lc.head),
                .tail = try self.cloneExpr(lc.tail),
            } },
            .map_init => |entries| blk: {
                var new_entries = try self.allocator.alloc(hir.MapEntry, entries.len);
                for (entries, 0..) |entry, i| {
                    new_entries[i] = .{
                        .key = try self.cloneExpr(entry.key),
                        .value = try self.cloneExpr(entry.value),
                    };
                }
                break :blk .{ .map_init = new_entries };
            },
            .struct_init => |si| blk: {
                var new_fields = try self.allocator.alloc(hir.StructFieldInit, si.fields.len);
                for (si.fields, 0..) |f, i| {
                    new_fields[i] = .{ .name = f.name, .value = try self.cloneExpr(f.value) };
                }
                const substituted_struct_type = if (self.current_subs) |subs|
                    subs.applyToType(self.store, si.type_id)
                else
                    si.type_id;
                break :blk .{ .struct_init = .{ .type_id = substituted_struct_type, .fields = new_fields } };
            },
            .field_get => |fg| .{ .field_get = .{
                .object = try self.cloneExpr(fg.object),
                .field = fg.field,
            } },
            .branch => |br| .{ .branch = .{
                .condition = try self.cloneExpr(br.condition),
                .then_block = try self.cloneBlock(br.then_block),
                .else_block = if (br.else_block) |eb| try self.cloneBlock(eb) else null,
            } },
            .case => |cd| blk: {
                var new_arms = try self.allocator.alloc(hir.CaseArm, cd.arms.len);
                for (cd.arms, 0..) |arm, i| {
                    new_arms[i] = .{
                        .pattern = arm.pattern,
                        .guard = if (arm.guard) |g| try self.cloneExpr(g) else null,
                        .body = try self.cloneBlock(arm.body),
                        .bindings = arm.bindings,
                    };
                }
                break :blk .{ .case = .{ .scrutinee = try self.cloneExpr(cd.scrutinee), .arms = new_arms } };
            },
            .block => |b| .{ .block = (try self.cloneBlock(&b)).* },
            .panic => |e| .{ .panic = try self.cloneExpr(e) },
            .unwrap => |e| .{ .unwrap = try self.cloneExpr(e) },
            .union_init => |ui| .{ .union_init = .{
                .union_type_id = if (self.current_subs) |subs|
                    subs.applyToType(self.store, ui.union_type_id)
                else
                    ui.union_type_id,
                .variant_name = ui.variant_name,
                .value = try self.cloneExpr(ui.value),
            } },
            .error_pipe => |ep| blk: {
                var new_steps = try self.allocator.alloc(hir.ErrorPipeStep, ep.steps.len);
                for (ep.steps, 0..) |step, i| {
                    new_steps[i] = .{
                        .expr = try self.cloneExpr(step.expr),
                        .is_dispatched = step.is_dispatched,
                    };
                }
                break :blk .{ .error_pipe = .{ .steps = new_steps, .handler = try self.cloneExpr(ep.handler) } };
            },
            .match => |m| .{ .match = .{
                .scrutinee = try self.cloneExpr(m.scrutinee),
                .decision = try self.cloneDecision(m.decision),
            } },
            .closure_create => |cc| blk: {
                if (cc.captures.len == 0) break :blk kind;
                var new_captures = try self.allocator.alloc(hir.CaptureValue, cc.captures.len);
                for (cc.captures, 0..) |cap, i| {
                    new_captures[i] = .{
                        .expr = try self.cloneExpr(cap.expr),
                        .ownership = cap.ownership,
                    };
                }
                break :blk .{ .closure_create = .{
                    .function_group_id = cc.function_group_id,
                    .captures = new_captures,
                } };
            },
        };
    }

    // -- Decision tree deep cloning -------------------------------------------

    fn cloneDecision(self: *MonomorphContext, decision: *const hir.Decision) error{OutOfMemory}!*const hir.Decision {
        const result = try self.allocator.create(hir.Decision);
        result.* = switch (decision.*) {
            .success => |leaf| .{ .success = leaf },
            .failure => .failure,
            .guard => |g| .{ .guard = .{
                .condition = try self.cloneExpr(g.condition),
                .success = try self.cloneDecision(g.success),
                .failure = try self.cloneDecision(g.failure),
            } },
            .switch_tag => |s| blk: {
                var new_cases = try self.allocator.alloc(hir.SwitchCase, s.cases.len);
                for (s.cases, 0..) |case, i| {
                    new_cases[i] = .{
                        .tag = case.tag,
                        .bindings = case.bindings,
                        .next = try self.cloneDecision(case.next),
                    };
                }
                break :blk .{ .switch_tag = .{
                    .scrutinee = try self.cloneExpr(s.scrutinee),
                    .cases = new_cases,
                    .default = try self.cloneDecision(s.default),
                } };
            },
            .switch_literal => |s| blk: {
                var new_cases = try self.allocator.alloc(hir.LiteralCase, s.cases.len);
                for (s.cases, 0..) |case, i| {
                    new_cases[i] = .{
                        .value = case.value,
                        .next = try self.cloneDecision(case.next),
                    };
                }
                break :blk .{ .switch_literal = .{
                    .scrutinee = try self.cloneExpr(s.scrutinee),
                    .cases = new_cases,
                    .default = try self.cloneDecision(s.default),
                } };
            },
            .check_tuple => |ct| .{ .check_tuple = .{
                .scrutinee = try self.cloneExpr(ct.scrutinee),
                .expected_arity = ct.expected_arity,
                .element_scrutinee_ids = ct.element_scrutinee_ids,
                .success = try self.cloneDecision(ct.success),
                .failure = try self.cloneDecision(ct.failure),
            } },
            .check_list => |cl| .{ .check_list = .{
                .scrutinee = try self.cloneExpr(cl.scrutinee),
                .expected_length = cl.expected_length,
                .success = try self.cloneDecision(cl.success),
                .failure = try self.cloneDecision(cl.failure),
            } },
            .check_list_cons => |clc| .{ .check_list_cons = .{
                .scrutinee = try self.cloneExpr(clc.scrutinee),
                .head_count = clc.head_count,
                .head_scrutinee_ids = clc.head_scrutinee_ids,
                .tail_scrutinee_id = clc.tail_scrutinee_id,
                .success = try self.cloneDecision(clc.success),
                .failure = try self.cloneDecision(clc.failure),
            } },
            .check_binary => |cb| .{ .check_binary = .{
                .scrutinee = try self.cloneExpr(cb.scrutinee),
                .min_byte_size = cb.min_byte_size,
                .segments = cb.segments,
                .success = try self.cloneDecision(cb.success),
                .failure = try self.cloneDecision(cb.failure),
            } },
            .bind => |b| .{ .bind = .{
                .name = b.name,
                .local_index = b.local_index,
                .source = try self.cloneExpr(b.source),
                .next = try self.cloneDecision(b.next),
            } },
        };
        return result;
    }

    // -- Rewriting call sites -------------------------------------------------

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
                // Check if this specific call expression was recorded for rewriting
                // during the scan phase (using pointer identity).
                if (self.call_rewrites.get(@intFromPtr(expr))) |new_id| {
                    const mutable_expr: *hir.Expr = @constCast(expr);
                    switch (mutable_expr.kind) {
                        .call => |*c| {
                            switch (c.target) {
                                .direct => |*dc| dc.function_group_id = new_id,
                                .dispatch => |*dp| dp.function_group_id = new_id,
                                .named => {
                                    // Rewrite named cross-module call to direct call
                                    c.target = .{ .direct = .{
                                        .function_group_id = new_id,
                                        .clause_index = 0,
                                    } };
                                },
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
            .map_init => |entries| {
                for (entries) |entry| {
                    self.rewriteExpr(entry.key);
                    self.rewriteExpr(entry.value);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| self.rewriteExpr(field.value);
            },
            .field_get => |fg| self.rewriteExpr(fg.object),
            .block => |b| self.rewriteBlock(&b),
            .panic => |e| self.rewriteExpr(e),
            .unwrap => |e| self.rewriteExpr(e),
            .union_init => |ui| self.rewriteExpr(ui.value),
            .error_pipe => |ep| {
                for (ep.steps) |step| self.rewriteExpr(step.expr);
                self.rewriteExpr(ep.handler);
            },
            .case => |cd| {
                self.rewriteExpr(cd.scrutinee);
                for (cd.arms) |arm| {
                    if (arm.guard) |g| self.rewriteExpr(g);
                    self.rewriteBlock(arm.body);
                }
            },
            .match => |m| self.rewriteExpr(m.scrutinee),
            .closure_create => |cc| {
                for (cc.captures) |cap| self.rewriteExpr(cap.expr);
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
        .protocol_constraint => |pc| {
            // Protocol constraints with type var params are generic
            for (pc.type_params) |tp| {
                if (containsTypeVar(store, tp)) return true;
            }
            // Bare protocol constraint (no type params) is still generic
            return pc.type_params.len == 0;
        },
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

/// Generate a mangled name for a specialized function.
/// E.g. "length" with type args [String] → "length__String"
fn mangleName(allocator: Allocator, base_name: []const u8, store: *const TypeStore, subs: *const SubstitutionMap) ![]const u8 {
    if (subs.bindings.count() == 0) return base_name;

    // Collect and sort type variable IDs for deterministic name mangling
    var var_ids: std.ArrayListUnmanaged(types_mod.TypeVarId) = .empty;
    defer var_ids.deinit(allocator);
    var it = subs.bindings.iterator();
    while (it.next()) |entry| {
        try var_ids.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort(types_mod.TypeVarId, var_ids.items, {}, std.sort.asc(types_mod.TypeVarId));

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    try parts.appendSlice(allocator, base_name);
    try parts.appendSlice(allocator, "__");

    for (var_ids.items, 0..) |var_id, i| {
        if (i > 0) try parts.append(allocator, '_');
        const concrete_type = subs.bindings.get(var_id) orelse continue;
        const type_name = typeIdToMangledName(store, concrete_type);
        try parts.appendSlice(allocator, type_name);
    }

    return try parts.toOwnedSlice(allocator);
}

/// Convert a TypeId to a short mangled name for function specialization.
fn typeIdToMangledName(store: *const TypeStore, type_id: TypeId) []const u8 {
    const typ = store.getType(type_id);
    return switch (typ) {
        .int => |it| switch (it.bits) {
            8 => if (it.signedness == .signed) "i8" else "u8",
            16 => if (it.signedness == .signed) "i16" else "u16",
            32 => if (it.signedness == .signed) "i32" else "u32",
            64 => if (it.signedness == .signed) "i64" else "u64",
            else => "int",
        },
        .float => |ft| switch (ft.bits) {
            16 => "f16",
            32 => "f32",
            64 => "f64",
            else => "float",
        },
        .bool_type => "Bool",
        .string_type => "String",
        .atom_type => "Atom",
        .nil_type => "Nil",
        .list => "List",
        .map => "Map",
        .tuple => "Tuple",
        .function => "Fn",
        .unknown => "Any",
        else => "T",
    };
}
