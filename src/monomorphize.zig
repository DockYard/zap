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
    for (program.structs) |mod| {
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
    for (program.structs, 0..) |mod, mod_idx| {
        ctx.current_scan_struct_idx = mod_idx;
        for (mod.functions) |*group| {
            for (group.clauses) |clause| {
                ctx.local_types.clearRetainingCapacity();
                try ctx.scanBlock(clause.body);
            }
        }
    }
    ctx.current_scan_struct_idx = null;
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
        while (scan_start < ctx.new_groups.items.len) {
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
                ctx.current_scan_struct_idx = entry.target_struct_idx;
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
        ctx.current_scan_struct_idx = null;
    }
    // Phase C: Build new program with specialized groups added.
    // Specializations are placed in the CALLING struct (target_struct_idx)
    // so that cross-struct direct calls resolve within the same struct's IR.
    // If target_struct_idx is null, fall back to placing in the defining struct.
    var new_structs: std.ArrayListUnmanaged(hir.Struct) = .empty;
    for (program.structs, 0..) |mod, mod_idx| {
        var new_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
        for (mod.functions) |group| {
            try new_fns.append(allocator, group);
        }
        for (ctx.new_groups.items) |entry| {
            if (entry.target_struct_idx) |target_idx| {
                // Cross-struct: place in calling struct
                if (target_idx == mod_idx) {
                    try new_fns.append(allocator, entry.group);
                }
            } else {
                // Intra-struct: place in defining struct
                for (mod.functions) |orig_group| {
                    if (entry.source_group_id == orig_group.id) {
                        try new_fns.append(allocator, entry.group);
                    }
                }
            }
        }
        try new_structs.append(allocator, .{
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

    // Phase D: Rewrite call sites in all expressions (structs + top functions)
    for (new_structs.items) |*mod| {
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
            .structs = try new_structs.toOwnedSlice(allocator),
            .top_functions = try new_top_fns.toOwnedSlice(allocator),
            .protocols = program.protocols,
            .impls = program.impls,
        },
        .specialization_count = @intCast(ctx.new_groups.items.len),
    };
}

const NewGroupEntry = struct {
    group: hir.FunctionGroup,
    source_group_id: u32,
    /// Struct index where this specialization should be placed.
    /// For cross-struct calls, this is the CALLING struct, not the defining struct.
    target_struct_idx: ?usize = null,
};

const MonomorphContext = struct {
    allocator: Allocator,
    store: *TypeStore,
    next_group_id: *u32,
    interner: *ast.StringInterner,
    /// Reference to the whole HIR program for resolving named cross-struct calls
    program: *const hir.Program,
    /// Current struct index being scanned (for placing specializations)
    current_scan_struct_idx: ?usize = null,
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
    /// Concrete parameter types for protocol-constrained parameters in the
    /// group currently being cloned. Protocol constraints are positional:
    /// `concat(first :: Enumerable, second :: Enumerable)` may specialize
    /// the two `Enumerable` parameters to different concrete types, so this
    /// cannot be represented by a TypeId-keyed substitution map.
    current_protocol_param_types: ?[]const TypeId = null,
    /// Original parameter types for the group currently being cloned. Used
    /// with current_protocol_param_types to replace expression-level protocol
    /// constraints that flow out of protocol calls, e.g. the `next_state`
    /// binding from `Enumerable.next(state)`.
    current_protocol_source_param_types: ?[]const hir.TypedParam = null,
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
        const target_struct = nc.struct_name orelse return null;
        for (self.program.protocols) |proto| {
            const proto_str = self.interner.get(proto.name);
            if (std.mem.eql(u8, proto_str, target_struct)) {
                return proto.name;
            }
        }
        return null;
    }

    /// Resolve a protocol dispatch: given a protocol name, function name,
    /// and concrete argument type, find the impl's function group ID.
    /// Uses TypeStore.typeToStructName to get the type's canonical struct
    /// name, then matches against impl target structs.
    fn resolveProtocolDispatch(
        self: *const MonomorphContext,
        protocol_name: ast.StringId,
        function_name: []const u8,
        concrete_type: TypeId,
        arity: u32,
    ) ?u32 {
        const type_struct = self.store.typeToStructName(concrete_type, self.interner) orelse return null;
        for (self.program.impls) |impl_info| {
            if (impl_info.protocol_name != protocol_name) continue;
            if (!std.mem.eql(u8, self.interner.get(impl_info.target_struct), type_struct)) continue;

            // Found the impl. Search its function groups for the matching function.
            for (impl_info.function_group_ids) |gid| {
                const group = self.findFunctionGroupById(gid) orelse continue;
                if (std.mem.eql(u8, self.interner.get(group.name), function_name) and
                    group.arity == arity)
                {
                    return gid;
                }
            }
        }
        return null;
    }

    fn typeImplementsProtocol(
        self: *const MonomorphContext,
        protocol_name: ast.StringId,
        concrete_type: TypeId,
    ) bool {
        const type_struct = self.store.typeToStructName(concrete_type, self.interner) orelse return false;
        for (self.program.impls) |impl_info| {
            if (impl_info.protocol_name != protocol_name) continue;
            if (std.mem.eql(u8, self.interner.get(impl_info.target_struct), type_struct)) return true;
        }
        return false;
    }

    fn protocolParamConcreteType(
        self: *const MonomorphContext,
        param_type: TypeId,
        arg_type: TypeId,
    ) ?TypeId {
        if (!self.isConcreteRuntimeType(arg_type)) return null;

        const param_typ = self.store.getType(param_type);
        if (param_typ != .protocol_constraint) return null;
        if (!self.typeImplementsProtocol(param_typ.protocol_constraint.protocol_name, arg_type)) return null;
        return arg_type;
    }

    fn isConcreteRuntimeType(self: *const MonomorphContext, type_id: TypeId) bool {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return false;
        const typ = self.store.getType(type_id);
        return switch (typ) {
            .unknown, .error_type, .type_var, .protocol_constraint => false,
            .list => |list_type| self.isConcreteRuntimeType(list_type.element),
            .tuple => |tuple_type| {
                for (tuple_type.elements) |element| {
                    if (!self.isConcreteRuntimeType(element)) return false;
                }
                return true;
            },
            .function => |function_type| {
                for (function_type.params) |param| {
                    if (!self.isConcreteRuntimeType(param)) return false;
                }
                return self.isConcreteRuntimeType(function_type.return_type);
            },
            .map => |map_type| self.isConcreteRuntimeType(map_type.key) and
                self.isConcreteRuntimeType(map_type.value),
            .applied => |applied_type| {
                if (!self.isConcreteRuntimeType(applied_type.base)) return false;
                for (applied_type.args) |arg| {
                    if (!self.isConcreteRuntimeType(arg)) return false;
                }
                return true;
            },
            .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .term_type => true,
            .struct_type, .union_type, .tagged_union, .opaque_type => true,
        };
    }

    fn resolveCallArgumentType(
        self: *const MonomorphContext,
        arg: hir.CallArg,
        param_type: ?TypeId,
    ) TypeId {
        var arg_type = arg.expr.type_id;

        // If the argument is a call that was already specialized, use
        // the specialization's return type as the arg type. This handles
        // nested calls like List.empty?(Enum.map([], f)) where the inner
        // call has a concrete return type.
        if (self.store.containsTypeVars(arg_type) and arg.expr.kind == .call) {
            if (self.call_rewrites.get(@intFromPtr(arg.expr))) |spec_id| {
                for (self.new_groups.items) |entry| {
                    if (entry.group.id == spec_id and entry.group.clauses.len > 0) {
                        const spec_ret = entry.group.clauses[0].return_type;
                        if (self.isConcreteRuntimeType(spec_ret)) {
                            arg_type = spec_ret;
                        }
                        break;
                    }
                }
            }
        }

        // If the argument is a local_get, always check tracked types.
        // The expression's type_id may be UNKNOWN even when the local
        // was assigned a concrete type (struct lists, etc.).
        if (arg.expr.kind == .local_get) {
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
                if (self.isConcreteRuntimeType(scan_param_type)) {
                    arg_type = scan_param_type;
                }
            }
        }

        // Monomorphized call sites carry substituted expected types on
        // their arguments. Use those when the expression itself is still
        // `any`/UNKNOWN. This is what lets recursive protocol helpers keep
        // the concrete state type returned by a protocol impl.
        if (!self.isConcreteRuntimeType(arg_type) and self.isConcreteRuntimeType(arg.expected_type)) {
            arg_type = arg.expected_type;
        }

        // Empty container literal: adopt the parameter's container type so
        // the call specializes the right way. The previous code defaulted
        // to `[i64]` / `Map(Atom,i64)` regardless of the parameter, which
        // silently picked the wrong overload (e.g. `[]` passed to `[String]`
        // specialized as `[i64]`). We only do this when the parameter is
        // fully concrete; if it still has type variables (generic context),
        // let the unifier handle it.
        if (arg_type == types_mod.TypeStore.UNKNOWN) {
            if (param_type) |pt| {
                const param_typ = self.store.getType(pt);
                switch (param_typ) {
                    .list => |list_t| {
                        if (arg.expr.kind == .list_init and self.isConcreteRuntimeType(list_t.element)) {
                            arg_type = pt;
                        }
                    },
                    .map => |map_t| {
                        if (arg.expr.kind == .map_init and
                            self.isConcreteRuntimeType(map_t.key) and
                            self.isConcreteRuntimeType(map_t.value))
                        {
                            arg_type = pt;
                        }
                    },
                    else => {},
                }
            }
        }

        return arg_type;
    }

    fn findFunctionGroupById(self: *const MonomorphContext, group_id: u32) ?*const hir.FunctionGroup {
        for (self.program.structs) |*mod| {
            for (mod.functions) |*group| {
                if (group.id == group_id) return group;
            }
        }
        for (self.program.top_functions) |*group| {
            if (group.id == group_id) return group;
        }
        for (self.new_groups.items) |*entry| {
            if (entry.group.id == group_id) return &entry.group;
        }
        return null;
    }

    /// Resolve a named cross-struct call (e.g., List.head) to a function group ID
    /// by searching all structs in the HIR program.
    fn resolveNamedCall(self: *const MonomorphContext, nc: hir.NamedCall, arity: u32) ?u32 {
        const target_struct = nc.struct_name orelse return null;
        for (self.program.structs) |mod| {
            // Check if this struct's name matches the target
            if (mod.name.parts.len == 0) continue;
            const last_part = self.interner.get(mod.name.parts[mod.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, target_struct)) continue;
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
                    const val_type = ls.value.type_id;
                    if (!self.store.containsTypeVars(val_type) and val_type != types_mod.TypeStore.UNKNOWN) {
                        try self.local_types.put(ls.index, val_type);
                    }
                    // Also track the type when the value is a list_init with known element types
                    if (val_type == types_mod.TypeStore.UNKNOWN and ls.value.kind == .list_init) {
                        const elems = ls.value.kind.list_init;
                        if (elems.len > 0 and elems[0].type_id != types_mod.TypeStore.UNKNOWN) {
                            const inferred = self.store.addType(.{ .list = .{ .element = elems[0].type_id } }) catch types_mod.TypeStore.UNKNOWN;
                            if (inferred != types_mod.TypeStore.UNKNOWN) {
                                try self.local_types.put(ls.index, inferred);
                            }
                        }
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
                var protocol_resolved_target = false;
                const target_id = switch (call.target) {
                    .direct => |dc| dc.function_group_id,
                    .dispatch => |dp| dp.function_group_id,
                    .named => |nc| blk: {
                        // Check for protocol dispatch: Enumerable.each(list, callback)
                        if (self.isProtocolCall(nc)) |proto_name| {
                            // Find the concrete type from the first argument
                            if (call.args.len > 0) {
                                const arg_type = self.resolveCallArgumentType(call.args[0], null);
                                if (self.isConcreteRuntimeType(arg_type)) {
                                    if (self.resolveProtocolDispatch(proto_name, nc.name, arg_type, @intCast(call.args.len))) |impl_gid| {
                                        protocol_resolved_target = true;
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
                    if (protocol_resolved_target) {
                        try self.call_rewrites.put(@intFromPtr(expr), target_id);
                    }
                    return;
                };

                // Unify arg types with param types to find type variable bindings
                if (generic_group.clauses.len == 0) return;
                const first_clause = &generic_group.clauses[0];
                if (first_clause.params.len != call.args.len) return;

                var subs = SubstitutionMap.init(self.allocator);
                defer subs.deinit();

                const protocol_param_types = try self.allocator.alloc(TypeId, first_clause.params.len);
                defer self.allocator.free(protocol_param_types);
                @memset(protocol_param_types, types_mod.TypeStore.UNKNOWN);

                // Unify argument types with parameter types. UNKNOWN arguments
                // are skipped rather than failing — partial unification allows
                // type variables to be bound from the arguments that ARE known
                // (e.g., binding element=i64 from the list arg even when the
                // callback arg is an unresolved function reference).
                for (first_clause.params, call.args, 0..) |param, arg, param_index| {
                    const arg_type = self.resolveCallArgumentType(arg, param.type_id);
                    if (arg_type == types_mod.TypeStore.UNKNOWN or arg_type == types_mod.TypeStore.ERROR) continue;
                    if (self.protocolParamConcreteType(param.type_id, arg_type)) |concrete_protocol_type| {
                        protocol_param_types[param_index] = concrete_protocol_type;
                    }
                    _ = self.store.unify(param.type_id, arg_type, &subs) catch {};
                }

                // Promote typevar bindings to `Term` for typevars that
                // need it to keep specialization consistent with the
                // runtime helper's heterogeneous storage. The base
                // unifier treats `Term` as a coercing supertype so a
                // typevar paired with `Term` doesn't pin to the
                // storage. That keeps scalar typevar uses correct
                // (`Map.get`'s `default :: V` -> `V`, where
                // `MapGetReturnType` unwraps the runtime `Term` back
                // to the default's narrower type) but it leaves two
                // problems:
                //
                //   1. Container-returning functions whose typevar
                //      reappears under a container in the return type
                //      (`Map.update`/`Map.put`'s `%{K=>V}` ->
                //      `%{K=>V}`) materialise the value-arg's narrower
                //      type into the return container, mismatching the
                //      runtime's actual `Map(K, Term)` result.
                //
                //   2. Functions where the typevar never appears in the
                //      return at all (`Map.has_key`'s `V` only lives
                //      under the map param) leave `V` unbound, so the
                //      `containsTypeVars` filter below skips
                //      specialisation altogether — the caller then
                //      tries to invoke a non-existent specialisation
                //      and the build fails silently in the ZIR
                //      injection stage.
                //
                // Both cases collapse into: promote `V` -> `Term`
                // whenever `V` shows up as a container element-slot in
                // a param AND the return type does NOT use `V` as a
                // free scalar (i.e. the return either lacks `V` or
                // wraps `V` in a container too). Pure-scalar return-V
                // (Map.get-style) is the only configuration left
                // untouched, preserving its narrow-binding behaviour.
                {
                    const return_uses_var_as_scalar = scalarTypeVarSet(self.store, first_clause.return_type, self.allocator) catch null;
                    var return_scalar_set = return_uses_var_as_scalar orelse std.AutoHashMap(types_mod.TypeVarId, void).init(self.allocator);
                    defer return_scalar_set.deinit();
                    for (first_clause.params, call.args) |param, arg| {
                        const arg_type = self.resolveCallArgumentType(arg, param.type_id);
                        if (arg_type == types_mod.TypeStore.UNKNOWN or arg_type == types_mod.TypeStore.ERROR) continue;
                        promoteContainerVarsExceptScalarReturn(self.store, param.type_id, arg_type, &return_scalar_set, &subs);
                    }
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
                for (protocol_param_types) |protocol_type| {
                    if (protocol_type != types_mod.TypeStore.UNKNOWN) {
                        try type_args.append(self.allocator, protocol_type);
                    }
                }

                if (self.hasUnboundProtocolParams(first_clause.params, protocol_param_types)) return;

                if (type_args.items.len == 0) return;

                // Skip if any type arg still contains type variables — this happens
                // when scanning inside generic function bodies where args are unresolved.
                // Creating such specializations produces bogus stubs (e.g. head__T).
                {
                    var has_unresolved_type = false;
                    for (type_args.items) |ta| {
                        if (!self.isConcreteRuntimeType(ta)) {
                            has_unresolved_type = true;
                            break;
                        }
                    }
                    if (has_unresolved_type) return;
                }

                // Check if this instantiation already exists for THIS struct.
                // Each calling struct needs its own copy of the specialization
                // so that call_direct resolves within the struct's own IR.
                const struct_salt: u32 = if (self.current_scan_struct_idx) |idx| @intCast(idx) else 0;
                const base_key = hashInstantiation(target_id, type_args.items);
                const key = base_key +% @as(u64, struct_salt) *% 0x9E3779B97F4A7C15;
                if (self.specializations.get(key)) |existing_id| {
                    // Already have a specialization for this struct — just record the rewrite
                    try self.call_rewrites.put(@intFromPtr(expr), existing_id);
                    // Update type_id for nested call resolution.
                    // Apply subs to the GENERIC GROUP's return type (which uses the
                    // same type var IDs as the subs), NOT expr.type_id (which uses
                    // different type var IDs from the HIR builder's scope).
                    if (!self.isConcreteRuntimeType(expr.type_id)) {
                        const concrete_return = subs.applyToType(self.store, first_clause.return_type);
                        if (self.isConcreteRuntimeType(concrete_return)) {
                            @constCast(expr).type_id = concrete_return;
                        }
                    }
                    return;
                }

                // Create specialized clone
                const new_id = self.next_group_id.*;
                self.next_group_id.* += 1;

                const specialized = try self.cloneGroupWithSubs(generic_group, &subs, protocol_param_types, type_args.items, new_id);
                try self.new_groups.append(self.allocator, .{
                    .group = specialized,
                    .source_group_id = target_id,
                    .target_struct_idx = self.current_scan_struct_idx,
                });
                try self.specializations.put(key, new_id);
                // Record this specific call expression for rewriting
                try self.call_rewrites.put(@intFromPtr(expr), new_id);

                // Update the call expression's type_id to the concrete return type.
                // Apply subs to the GENERIC GROUP's return type (first_clause.return_type)
                // which uses the same type var IDs as the subs map. Do NOT use
                // expr.type_id because the HIR builder resolves type vars in a separate
                // scope, producing different type var IDs that aren't in the subs.
                if (!self.isConcreteRuntimeType(expr.type_id)) {
                    const concrete_return = subs.applyToType(self.store, first_clause.return_type);
                    if (self.isConcreteRuntimeType(concrete_return)) {
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
            .tuple_index_get => |tig| try self.scanExpr(tig.object),
            .list_index_get => |lig| try self.scanExpr(lig.list),
            .list_head_get => |lhg| try self.scanExpr(lhg.list),
            .list_tail_get => |ltg| try self.scanExpr(ltg.list),
            .map_value_get => |mvg| {
                try self.scanExpr(mvg.map);
                try self.scanExpr(mvg.key);
            },
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

    fn hasUnboundProtocolParams(
        self: *const MonomorphContext,
        params: []const hir.TypedParam,
        protocol_param_types: []const TypeId,
    ) bool {
        for (params, 0..) |param, param_index| {
            if (self.store.getType(param.type_id) != .protocol_constraint) continue;
            if (param_index >= protocol_param_types.len) return true;
            if (protocol_param_types[param_index] == types_mod.TypeStore.UNKNOWN) return true;
        }
        return false;
    }

    fn protocolConstraintReplacement(self: *const MonomorphContext, constraint_type: TypeId) ?TypeId {
        const source_params = self.current_protocol_source_param_types orelse return null;
        const concrete_params = self.current_protocol_param_types orelse return null;
        const constraint = self.store.getType(constraint_type);
        if (constraint != .protocol_constraint) return null;

        var replacement: TypeId = types_mod.TypeStore.UNKNOWN;
        var replacement_count: u32 = 0;
        for (source_params, 0..) |source_param, param_index| {
            if (param_index >= concrete_params.len) continue;
            if (concrete_params[param_index] == types_mod.TypeStore.UNKNOWN) continue;
            const source_type = self.store.getType(source_param.type_id);
            if (source_type != .protocol_constraint) continue;
            if (source_type.protocol_constraint.protocol_name != constraint.protocol_constraint.protocol_name) continue;
            if (!std.mem.eql(TypeId, source_type.protocol_constraint.type_params, constraint.protocol_constraint.type_params)) continue;
            replacement = concrete_params[param_index];
            replacement_count += 1;
        }

        return if (replacement_count == 1) replacement else null;
    }

    fn applyActiveProtocolParamTypes(self: *MonomorphContext, type_id: TypeId) error{OutOfMemory}!TypeId {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return type_id;
        const typ = self.store.getType(type_id);
        return switch (typ) {
            .protocol_constraint => |pc| blk: {
                var changed_params = false;
                const new_params = try self.allocator.alloc(TypeId, pc.type_params.len);
                for (pc.type_params, 0..) |type_param, index| {
                    const new_type_param = try self.applyActiveProtocolParamTypes(type_param);
                    new_params[index] = new_type_param;
                    if (new_type_param != type_param) changed_params = true;
                }

                const candidate_type = if (changed_params)
                    try self.store.addType(.{ .protocol_constraint = .{
                        .protocol_name = pc.protocol_name,
                        .type_params = new_params,
                    } })
                else blk2: {
                    self.allocator.free(new_params);
                    break :blk2 type_id;
                };

                break :blk self.protocolConstraintReplacement(candidate_type) orelse candidate_type;
            },
            .list => |list_type| blk: {
                const element = try self.applyActiveProtocolParamTypes(list_type.element);
                if (element == list_type.element) break :blk type_id;
                break :blk try self.store.addType(.{ .list = .{ .element = element } });
            },
            .tuple => |tuple_type| blk: {
                var changed = false;
                const elements = try self.allocator.alloc(TypeId, tuple_type.elements.len);
                for (tuple_type.elements, 0..) |element, index| {
                    const new_element = try self.applyActiveProtocolParamTypes(element);
                    elements[index] = new_element;
                    if (new_element != element) changed = true;
                }
                if (!changed) {
                    self.allocator.free(elements);
                    break :blk type_id;
                }
                break :blk try self.store.addType(.{ .tuple = .{ .elements = elements } });
            },
            .function => |function_type| blk: {
                var changed = false;
                const params = try self.allocator.alloc(TypeId, function_type.params.len);
                for (function_type.params, 0..) |param, index| {
                    const new_param = try self.applyActiveProtocolParamTypes(param);
                    params[index] = new_param;
                    if (new_param != param) changed = true;
                }
                const return_type = try self.applyActiveProtocolParamTypes(function_type.return_type);
                if (return_type != function_type.return_type) changed = true;
                if (!changed) {
                    self.allocator.free(params);
                    break :blk type_id;
                }
                break :blk try self.store.addType(.{ .function = .{
                    .params = params,
                    .return_type = return_type,
                    .param_ownerships = function_type.param_ownerships,
                    .return_ownership = function_type.return_ownership,
                } });
            },
            .map => |map_type| blk: {
                const key = try self.applyActiveProtocolParamTypes(map_type.key);
                const value = try self.applyActiveProtocolParamTypes(map_type.value);
                if (key == map_type.key and value == map_type.value) break :blk type_id;
                break :blk try self.store.addType(.{ .map = .{ .key = key, .value = value } });
            },
            .applied => |applied_type| blk: {
                var changed = false;
                const base = try self.applyActiveProtocolParamTypes(applied_type.base);
                if (base != applied_type.base) changed = true;
                const args = try self.allocator.alloc(TypeId, applied_type.args.len);
                for (applied_type.args, 0..) |arg, index| {
                    const new_arg = try self.applyActiveProtocolParamTypes(arg);
                    args[index] = new_arg;
                    if (new_arg != arg) changed = true;
                }
                if (!changed) {
                    self.allocator.free(args);
                    break :blk type_id;
                }
                break :blk try self.store.addType(.{ .applied = .{ .base = base, .args = args } });
            },
            else => type_id,
        };
    }

    fn cloneGroupWithSubs(
        self: *MonomorphContext,
        group: *const hir.FunctionGroup,
        subs: *const SubstitutionMap,
        protocol_param_types: []const TypeId,
        type_args: []const TypeId,
        new_id: u32,
    ) !hir.FunctionGroup {
        const saved_subs = self.current_subs;
        const saved_protocol_param_types = self.current_protocol_param_types;
        const saved_protocol_source_param_types = self.current_protocol_source_param_types;
        self.current_subs = subs;
        self.current_protocol_param_types = protocol_param_types;
        self.current_protocol_source_param_types = if (group.clauses.len > 0) group.clauses[0].params else &.{};
        defer self.current_subs = saved_subs;
        defer self.current_protocol_param_types = saved_protocol_param_types;
        defer self.current_protocol_source_param_types = saved_protocol_source_param_types;

        var new_clauses: std.ArrayListUnmanaged(hir.Clause) = .empty;
        for (group.clauses) |clause| {
            // Substitute types in params
            var new_params = try self.allocator.alloc(hir.TypedParam, clause.params.len);
            for (clause.params, 0..) |param, i| {
                const protocol_param_type = if (i < protocol_param_types.len) protocol_param_types[i] else types_mod.TypeStore.UNKNOWN;
                new_params[i] = .{
                    .name = param.name,
                    .type_id = if (protocol_param_type != types_mod.TypeStore.UNKNOWN)
                        protocol_param_type
                    else
                        try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, param.type_id)),
                    .ownership = param.ownership,
                    .pattern = param.pattern,
                    .default = if (param.default) |d| try self.cloneExpr(d) else null,
                };
            }

            try new_clauses.append(self.allocator, .{
                .params = new_params,
                .return_type = try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, clause.return_type)),
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

        // Include source struct name in the mangled specialization name to prevent
        // name collisions. Without this, List.empty?__i64 and Enum.empty?__i64
        // produce the same local_name in the calling struct, causing the ZIR builder's
        // deduplication to remove one — the surviving function then calls itself.
        const base_name = self.interner.get(group.name);
        const source_struct_prefix = blk: {
            for (self.program.structs) |mod| {
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
        const qualified_base = if (source_struct_prefix.len > 0)
            std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_struct_prefix, base_name }) catch base_name
        else
            base_name;
        const mangled_str = mangleName(self.allocator, qualified_base, self.store, type_args) catch qualified_base;
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
                try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, block.result_type))
            else
                try self.applyActiveProtocolParamTypes(block.result_type),
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
        const substituted_type = blk: {
            if (expr.kind == .param_get) {
                if (self.current_protocol_param_types) |protocol_param_types| {
                    const param_index = expr.kind.param_get;
                    if (param_index < protocol_param_types.len and
                        protocol_param_types[param_index] != types_mod.TypeStore.UNKNOWN)
                    {
                        break :blk protocol_param_types[param_index];
                    }
                }
            }
            if (self.current_subs) |subs| {
                break :blk try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, expr.type_id));
            }
            break :blk try self.applyActiveProtocolParamTypes(expr.type_id);
        };
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
                            try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, arg.expected_type))
                        else
                            try self.applyActiveProtocolParamTypes(arg.expected_type),
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
                    try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, si.type_id))
                else
                    try self.applyActiveProtocolParamTypes(si.type_id);
                break :blk .{ .struct_init = .{ .type_id = substituted_struct_type, .fields = new_fields } };
            },
            .field_get => |fg| .{ .field_get = .{
                .object = try self.cloneExpr(fg.object),
                .field = fg.field,
            } },
            .tuple_index_get => |tig| .{ .tuple_index_get = .{
                .object = try self.cloneExpr(tig.object),
                .index = tig.index,
            } },
            .list_index_get => |lig| .{ .list_index_get = .{
                .list = try self.cloneExpr(lig.list),
                .index = lig.index,
            } },
            .list_head_get => |lhg| .{ .list_head_get = .{
                .list = try self.cloneExpr(lhg.list),
            } },
            .list_tail_get => |ltg| .{ .list_tail_get = .{
                .list = try self.cloneExpr(ltg.list),
            } },
            .map_value_get => |mvg| .{ .map_value_get = .{
                .map = try self.cloneExpr(mvg.map),
                .key = try self.cloneExpr(mvg.key),
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
                    try self.applyActiveProtocolParamTypes(subs.applyToType(self.store, ui.union_type_id))
                else
                    try self.applyActiveProtocolParamTypes(ui.union_type_id),
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
                break :blk .{ .error_pipe = .{
                    .steps = new_steps,
                    .handler = try self.cloneExpr(ep.handler),
                    .err_local = ep.err_local,
                } };
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
                .element_scrutinee_ids = cl.element_scrutinee_ids,
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
            .extract_struct => |es| .{ .extract_struct = .{
                .scrutinee = try self.cloneExpr(es.scrutinee),
                .fields = es.fields,
                .success = try self.cloneDecision(es.success),
                .failure = try self.cloneDecision(es.failure),
            } },
            .extract_map => |em| .{ .extract_map = .{
                .scrutinee = try self.cloneExpr(em.scrutinee),
                .keys = em.keys,
                .success = try self.cloneDecision(em.success),
                .failure = try self.cloneDecision(em.failure),
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
                                    // Rewrite named cross-struct call to direct call
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

/// Collect typevars that appear at a SCALAR (top-level, not inside a
/// container) position within `type_id`. These are the typevars whose
/// binding directly determines the type's identity rather than the
/// element type of an enclosing container. Used to detect cases like
/// `Map.get`'s `-> V` return where promoting `V` to `Term` would
/// silently change the apparent return type at the IR level.
fn scalarTypeVarSet(
    store: *const TypeStore,
    type_id: TypeId,
    allocator: Allocator,
) !std.AutoHashMap(types_mod.TypeVarId, void) {
    var out = std.AutoHashMap(types_mod.TypeVarId, void).init(allocator);
    errdefer out.deinit();
    try collectScalarTypeVars(store, type_id, true, &out);
    return out;
}

fn collectScalarTypeVars(
    store: *const TypeStore,
    type_id: TypeId,
    is_scalar_position: bool,
    out: *std.AutoHashMap(types_mod.TypeVarId, void),
) error{OutOfMemory}!void {
    const typ = store.getType(type_id);
    switch (typ) {
        .type_var => |var_id| {
            if (is_scalar_position) try out.put(var_id, {});
        },
        .list => |lt| try collectScalarTypeVars(store, lt.element, false, out),
        .map => |mt| {
            try collectScalarTypeVars(store, mt.key, false, out);
            try collectScalarTypeVars(store, mt.value, false, out);
        },
        .tuple => |tt| {
            for (tt.elements) |elem| {
                try collectScalarTypeVars(store, elem, false, out);
            }
        },
        .function => |ft| {
            for (ft.params) |p| try collectScalarTypeVars(store, p, false, out);
            try collectScalarTypeVars(store, ft.return_type, false, out);
        },
        else => {},
    }
}

/// Walk param/arg types in lock-step. For every typevar position in
/// `param_type` whose `arg_type` counterpart is `Term`, force the
/// typevar's binding to `Term` — UNLESS the typevar is in
/// `scalar_return_vars` (i.e. it appears at a scalar position in the
/// function's return type, where binding to `Term` would change the
/// apparent return type at the IR level and break callers like
/// `Map.get` that rely on the runtime helper unwrapping back to the
/// default's narrower type).
fn promoteContainerVarsExceptScalarReturn(
    store: *const TypeStore,
    param_type: TypeId,
    arg_type: TypeId,
    scalar_return_vars: *const std.AutoHashMap(types_mod.TypeVarId, void),
    subs: *types_mod.SubstitutionMap,
) void {
    const param_typ = store.getType(param_type);
    const arg_typ = store.getType(arg_type);
    switch (param_typ) {
        .type_var => |var_id| {
            if (arg_typ == .term_type and !scalar_return_vars.contains(var_id)) {
                if (subs.bindings.get(var_id)) |existing| {
                    if (store.getType(existing) == .term_type) return;
                }
                subs.bind(var_id, types_mod.TypeStore.TERM);
            }
        },
        .list => |pt_list| {
            if (arg_typ == .list) {
                promoteContainerVarsExceptScalarReturn(store, pt_list.element, arg_typ.list.element, scalar_return_vars, subs);
            }
        },
        .map => |pt_map| {
            if (arg_typ == .map) {
                promoteContainerVarsExceptScalarReturn(store, pt_map.key, arg_typ.map.key, scalar_return_vars, subs);
                promoteContainerVarsExceptScalarReturn(store, pt_map.value, arg_typ.map.value, scalar_return_vars, subs);
            }
        },
        .tuple => |pt_tup| {
            if (arg_typ == .tuple and pt_tup.elements.len == arg_typ.tuple.elements.len) {
                for (pt_tup.elements, arg_typ.tuple.elements) |pe, ae| {
                    promoteContainerVarsExceptScalarReturn(store, pe, ae, scalar_return_vars, subs);
                }
            }
        },
        .function => |pt_fn| {
            if (arg_typ == .function and pt_fn.params.len == arg_typ.function.params.len) {
                for (pt_fn.params, arg_typ.function.params) |pp, ap| {
                    promoteContainerVarsExceptScalarReturn(store, pp, ap, scalar_return_vars, subs);
                }
                promoteContainerVarsExceptScalarReturn(store, pt_fn.return_type, arg_typ.function.return_type, scalar_return_vars, subs);
            }
        },
        else => {},
    }
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
fn mangleName(allocator: Allocator, base_name: []const u8, store: *const TypeStore, type_args: []const TypeId) ![]const u8 {
    if (type_args.len == 0) return base_name;

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    try parts.appendSlice(allocator, base_name);
    try parts.appendSlice(allocator, "__");

    for (type_args, 0..) |concrete_type, i| {
        if (i > 0) try parts.append(allocator, '_');
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
        .struct_type => |st| @constCast(store).interner.get(st.name),
        .tagged_union => |tu| @constCast(store).interner.get(tu.name),
        else => "T",
    };
}
