const std = @import("std");
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");

const TypeId = types_mod.TypeId;
const TypeStore = types_mod.TypeStore;
const SubstitutionMap = types_mod.SubstitutionMap;
const Allocator = std.mem.Allocator;

const MAX_TOTAL_SPECIALIZATIONS: u32 = 8192;
const MAX_SPECIALIZATIONS_PER_GENERIC: u32 = 1024;
const MAX_TYPE_STRUCTURE_DEPTH: u32 = 128;
const MAX_TYPE_STRUCTURE_NODES: u32 = 512;
const MAX_HIR_STRUCTURE_DEPTH: u32 = 1024;
const MAX_HIR_STRUCTURE_NODES: u32 = 200_000;

pub const MonomorphError = struct {
    message: []const u8,
    span: ast.SourceSpan,
};

const TypeWalkError = types_mod.TypeGraphError || error{
    TypeStructureTooDeep,
    TypeStructureTooLarge,
};

const TypeMangleError = types_mod.TypeMangleError;

const HirWalkError = error{
    OutOfMemory,
    HirStructureTooDeep,
    HirStructureTooLarge,
};

const MonomorphWalkError = HirWalkError || TypeWalkError;
const NameMangleError = TypeWalkError || TypeMangleError;
const CloneGroupError = MonomorphWalkError || TypeMangleError;

const RuntimeTypePredicate = enum {
    concrete,
    monomorphization_ready,
};

const TypeTransformMode = union(enum) {
    default_unbound: TypeId,
    active_protocol_params,
};

const TypeTransformFrame = struct {
    type_id: TypeId,
    depth: u32,
    phase: enum { enter, exit },
};

const HirWalkBudget = struct {
    nodes_seen: u32 = 0,

    fn enter(self: *HirWalkBudget, depth: u32) HirWalkError!void {
        if (depth > MAX_HIR_STRUCTURE_DEPTH) return error.HirStructureTooDeep;
        self.nodes_seen += 1;
        if (self.nodes_seen > MAX_HIR_STRUCTURE_NODES) return error.HirStructureTooLarge;
    }
};

const TypeWalkItem = struct {
    type_id: TypeId,
    paired_type_id: ?TypeId = null,
    depth: u32,
    scalar_position: bool = false,
};

const TypeWalker = struct {
    allocator: Allocator,
    work: std.ArrayListUnmanaged(TypeWalkItem) = .empty,
    visited: std.AutoHashMap(u64, void),
    nodes_seen: u32 = 0,

    fn init(allocator: Allocator) TypeWalker {
        return .{
            .allocator = allocator,
            .visited = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    fn deinit(self: *TypeWalker) void {
        self.work.deinit(self.allocator);
        self.visited.deinit();
    }

    fn pushRoot(self: *TypeWalker, type_id: TypeId) TypeWalkError!void {
        try self.pushType(type_id, 0, false);
    }

    fn pushScalarRoot(self: *TypeWalker, type_id: TypeId) TypeWalkError!void {
        try self.pushType(type_id, 0, true);
    }

    fn pushPairRoot(self: *TypeWalker, left: TypeId, right: TypeId) TypeWalkError!void {
        try self.pushPair(left, right, 0);
    }

    fn pushType(self: *TypeWalker, type_id: TypeId, depth: u32, scalar_position: bool) TypeWalkError!void {
        try self.work.append(self.allocator, .{
            .type_id = type_id,
            .depth = depth,
            .scalar_position = scalar_position,
        });
    }

    fn pushPair(self: *TypeWalker, left: TypeId, right: TypeId, depth: u32) TypeWalkError!void {
        try self.work.append(self.allocator, .{
            .type_id = left,
            .paired_type_id = right,
            .depth = depth,
        });
    }

    fn next(self: *TypeWalker) TypeWalkError!?TypeWalkItem {
        while (self.work.pop()) |item| {
            if (item.depth > MAX_TYPE_STRUCTURE_DEPTH) return error.TypeStructureTooDeep;

            const key = visitKey(item);
            if (self.visited.contains(key)) continue;
            try self.visited.put(key, {});

            self.nodes_seen += 1;
            if (self.nodes_seen > MAX_TYPE_STRUCTURE_NODES) return error.TypeStructureTooLarge;

            return item;
        }
        return null;
    }

    fn pushStructuralChildren(self: *TypeWalker, store: *const TypeStore, item: TypeWalkItem) TypeWalkError!void {
        std.debug.assert(item.paired_type_id == null);
        const next_depth = item.depth + 1;
        switch (store.getType(item.type_id)) {
            .tuple => |tuple| for (tuple.elements) |child| {
                try self.pushType(child, next_depth, false);
            },
            .list => |list| try self.pushType(list.element, next_depth, false),
            .map => |map| {
                try self.pushType(map.key, next_depth, false);
                try self.pushType(map.value, next_depth, false);
            },
            .struct_type => |struct_type| {
                for (struct_type.type_params) |child| try self.pushType(child, next_depth, false);
                for (struct_type.fields) |field| try self.pushType(field.type_id, next_depth, false);
            },
            .union_type => |union_type| for (union_type.members) |child| {
                try self.pushType(child, next_depth, false);
            },
            .function => |function_type| {
                for (function_type.params) |child| try self.pushType(child, next_depth, false);
                try self.pushType(function_type.return_type, next_depth, false);
                if (function_type.effect_var) |effect_var| try self.pushType(effect_var, next_depth, false);
                for (function_type.raises_row) |child| try self.pushType(child, next_depth, false);
            },
            .applied => |applied| {
                try self.pushType(applied.base, next_depth, false);
                for (applied.args) |child| try self.pushType(child, next_depth, false);
            },
            .tagged_union => |tagged_union| {
                for (tagged_union.type_params) |child| try self.pushType(child, next_depth, false);
                for (tagged_union.variants) |variant| {
                    if (variant.type_id) |payload| try self.pushType(payload, next_depth, false);
                }
            },
            .opaque_type => |opaque_type| try self.pushType(opaque_type.inner, next_depth, false),
            .protocol_constraint => |constraint| for (constraint.type_params) |child| {
                try self.pushType(child, next_depth, false);
            },
            else => {},
        }
    }

    fn visitKey(item: TypeWalkItem) u64 {
        if (item.paired_type_id) |paired_type_id| {
            return (@as(u64, item.type_id) << 32) | @as(u64, paired_type_id);
        }
        return (@as(u64, item.type_id) << 1) | @intFromBool(item.scalar_position);
    }
};

/// Result of the monomorphization pass.
pub const MonomorphResult = struct {
    /// The transformed program with specialized function groups added.
    program: hir.Program,
    /// Number of specializations created.
    specialization_count: u32,
    /// Compile errors collected while refusing unbounded specialization growth.
    errors: []const MonomorphError = &.{},
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
        .specialization_counts = std.AutoHashMap(u32, u32).init(allocator),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(allocator),
        .local_types = std.AutoHashMap(u32, TypeId).init(allocator),
        .errors = .empty,
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.specialization_counts.deinit();
    defer ctx.new_groups.deinit(allocator);
    defer ctx.call_rewrites.deinit();
    defer ctx.local_types.deinit();

    // Phase A: Identify generic function groups (those with type_var params)
    for (program.structs) |mod| {
        for (mod.functions) |*group| {
            if (try ctx.isGenericGroup(group)) {
                try ctx.generic_groups.put(group.id, group);
            }
        }
    }
    for (program.top_functions) |*group| {
        if (try ctx.isGenericGroup(group)) {
            try ctx.generic_groups.put(group.id, group);
        }
    }

    if (ctx.errors.items.len > 0) {
        return .{
            .program = program.*,
            .specialization_count = @intCast(ctx.new_groups.items.len),
            .errors = try ctx.errors.toOwnedSlice(allocator),
        };
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
                ctx.current_scan_params = clause.params;
                ctx.local_types.clearRetainingCapacity();
                try ctx.scanBlock(clause.body);
                ctx.current_scan_params = null;
            }
        }
    }
    ctx.current_scan_struct_idx = null;
    for (program.top_functions) |*group| {
        for (group.clauses) |clause| {
            ctx.current_scan_params = clause.params;
            ctx.local_types.clearRetainingCapacity();
            try ctx.scanBlock(clause.body);
            ctx.current_scan_params = null;
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
            var entries_to_scan = try ctx.collectTransitiveScanEntries(ctx.new_groups.items[scan_start..scan_end]);
            defer entries_to_scan.deinit(allocator);
            for (entries_to_scan.items) |entry| {
                ctx.current_scan_struct_idx = entry.target_struct_idx;
                for (entry.group.clauses) |clause| {
                    ctx.current_scan_params = clause.params;
                    ctx.local_types.clearRetainingCapacity();
                    try ctx.scanBlock(clause.body);
                    ctx.current_scan_params = null;
                }
            }
            scan_start = scan_end;
        }
        ctx.current_scan_struct_idx = null;
    }

    if (ctx.errors.items.len > 0) {
        return .{
            .program = program.*,
            .specialization_count = @intCast(ctx.new_groups.items.len),
            .errors = try ctx.errors.toOwnedSlice(allocator),
        };
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
                try ctx.rewriteBlock(clause.body);
            }
        }
    }
    for (new_top_fns.items) |*group| {
        for (group.clauses) |clause| {
            try ctx.rewriteBlock(clause.body);
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
        .errors = try ctx.errors.toOwnedSlice(allocator),
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
    /// P3-J2 per-spawn manager-monomorphization axis. When set (only while
    /// `specializeSpawnManagers` clones a spawn-reachable subgraph for one
    /// reclamation model), maps each ORIGINAL top-level/struct function-group
    /// id in the reachable subgraph to its MODEL-SPECIALIZED clone id. The
    /// clone path (`cloneExprKindBudgeted`'s `.call` arm) consults it to
    /// redirect every resolvable intra-subgraph direct/named/dispatch call to
    /// the model clone, so a specialization is a closed subgraph that never
    /// re-enters the manifest-model originals. Null on the type-argument path
    /// (no redirect), keeping that path byte-for-byte unchanged. Indirect
    /// (`.closure`) and unresolved calls are left untouched — the deliberate
    /// hot/cold boundary (§2.3): cold callees keep manifest emission and
    /// dispatch through the per-process manager context at runtime.
    current_model_call_redirect: ?*const std.AutoHashMap(u32, u32) = null,
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
    /// Specializations created per source generic group.
    specialization_counts: std.AutoHashMap(u32, u32),
    /// Refusal diagnostics for unbounded specialization growth.
    errors: std.ArrayListUnmanaged(MonomorphError),

    fn appendError(self: *MonomorphContext, span: ast.SourceSpan, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    fn appendHirBudgetError(
        self: *MonomorphContext,
        span: ast.SourceSpan,
        operation: []const u8,
        err: HirWalkError,
    ) error{OutOfMemory}!void {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HirStructureTooDeep => try self.appendError(
                span,
                "monomorphization {s} exceeds maximum HIR nesting depth ({d})",
                .{ operation, MAX_HIR_STRUCTURE_DEPTH },
            ),
            error.HirStructureTooLarge => try self.appendError(
                span,
                "monomorphization {s} contains more than {d} HIR nodes",
                .{ operation, MAX_HIR_STRUCTURE_NODES },
            ),
        }
    }

    fn appendTypeBudgetError(
        self: *MonomorphContext,
        span: ast.SourceSpan,
        operation: []const u8,
        err: TypeWalkError,
    ) error{OutOfMemory}!void {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TypeStructureTooDeep => try self.appendError(
                span,
                "monomorphization {s} exceeds maximum type nesting depth ({d})",
                .{ operation, MAX_TYPE_STRUCTURE_DEPTH },
            ),
            error.TypeStructureTooLarge => try self.appendError(
                span,
                "monomorphization {s} contains more than {d} unique type nodes",
                .{ operation, MAX_TYPE_STRUCTURE_NODES },
            ),
            error.TypeGraphDepthLimitExceeded => try self.appendError(
                span,
                "monomorphization {s} exceeds the type graph traversal depth budget",
                .{operation},
            ),
            error.TypeGraphNodeLimitExceeded => try self.appendError(
                span,
                "monomorphization {s} exceeds the type graph traversal node budget",
                .{operation},
            ),
        }
    }

    fn appendWalkBudgetError(
        self: *MonomorphContext,
        span: ast.SourceSpan,
        operation: []const u8,
        err: MonomorphWalkError,
    ) error{OutOfMemory}!void {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HirStructureTooDeep => try self.appendError(
                span,
                "monomorphization {s} exceeds maximum HIR nesting depth ({d})",
                .{ operation, MAX_HIR_STRUCTURE_DEPTH },
            ),
            error.HirStructureTooLarge => try self.appendError(
                span,
                "monomorphization {s} contains more than {d} HIR nodes",
                .{ operation, MAX_HIR_STRUCTURE_NODES },
            ),
            error.TypeStructureTooDeep => try self.appendError(
                span,
                "monomorphization {s} exceeds maximum type nesting depth ({d})",
                .{ operation, MAX_TYPE_STRUCTURE_DEPTH },
            ),
            error.TypeStructureTooLarge => try self.appendError(
                span,
                "monomorphization {s} contains more than {d} unique type nodes",
                .{ operation, MAX_TYPE_STRUCTURE_NODES },
            ),
            error.TypeGraphDepthLimitExceeded => try self.appendError(
                span,
                "monomorphization {s} exceeds the type graph traversal depth budget",
                .{operation},
            ),
            error.TypeGraphNodeLimitExceeded => try self.appendError(
                span,
                "monomorphization {s} exceeds the type graph traversal node budget",
                .{operation},
            ),
        }
    }

    fn typeStructureWithinBudget(self: *MonomorphContext, root: TypeId) TypeWalkError!void {
        var walker = TypeWalker.init(self.allocator);
        defer walker.deinit();

        try walker.pushRoot(root);
        while (try walker.next()) |item| {
            try walker.pushStructuralChildren(self.store, item);
        }
    }

    fn isGenericGroup(self: *MonomorphContext, group: *const hir.FunctionGroup) error{OutOfMemory}!bool {
        return genericGroupContainsTypeVar(self.store, group, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TypeStructureTooDeep => {
                try self.appendError(
                    genericGroupSpan(group),
                    "monomorphization could not inspect generic `{s}/{d}` because its type signature exceeds maximum type nesting depth ({d})",
                    .{ self.interner.get(group.name), group.arity, MAX_TYPE_STRUCTURE_DEPTH },
                );
                return false;
            },
            error.TypeStructureTooLarge => {
                try self.appendError(
                    genericGroupSpan(group),
                    "monomorphization could not inspect generic `{s}/{d}` because its type signature contains more than {d} unique type nodes",
                    .{ self.interner.get(group.name), group.arity, MAX_TYPE_STRUCTURE_NODES },
                );
                return false;
            },
            error.TypeGraphDepthLimitExceeded => {
                try self.appendError(
                    genericGroupSpan(group),
                    "monomorphization could not inspect generic `{s}/{d}` because its type signature exceeds the type graph traversal depth budget",
                    .{ self.interner.get(group.name), group.arity },
                );
                return false;
            },
            error.TypeGraphNodeLimitExceeded => {
                try self.appendError(
                    genericGroupSpan(group),
                    "monomorphization could not inspect generic `{s}/{d}` because its type signature exceeds the type graph traversal node budget",
                    .{ self.interner.get(group.name), group.arity },
                );
                return false;
            },
        };
    }

    fn scalarTypeVarSetForReturn(
        self: *MonomorphContext,
        generic_group: *const hir.FunctionGroup,
        return_type: TypeId,
        span: ast.SourceSpan,
    ) error{OutOfMemory}!?std.AutoHashMap(types_mod.TypeVarId, void) {
        return scalarTypeVarSet(self.store, return_type, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TypeStructureTooDeep => {
                try self.appendError(
                    span,
                    "monomorphization return type walk for generic `{s}/{d}` exceeds maximum type nesting depth ({d})",
                    .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_DEPTH },
                );
                return null;
            },
            error.TypeStructureTooLarge => {
                try self.appendError(
                    span,
                    "monomorphization return type walk for generic `{s}/{d}` contains more than {d} unique type nodes",
                    .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_NODES },
                );
                return null;
            },
            error.TypeGraphDepthLimitExceeded => {
                try self.appendError(
                    span,
                    "monomorphization return type walk for generic `{s}/{d}` exceeds the type graph traversal depth budget",
                    .{ self.interner.get(generic_group.name), generic_group.arity },
                );
                return null;
            },
            error.TypeGraphNodeLimitExceeded => {
                try self.appendError(
                    span,
                    "monomorphization return type walk for generic `{s}/{d}` exceeds the type graph traversal node budget",
                    .{ self.interner.get(generic_group.name), generic_group.arity },
                );
                return null;
            },
        };
    }

    fn promoteContainerVarsForCall(
        self: *MonomorphContext,
        generic_group: *const hir.FunctionGroup,
        param_type: TypeId,
        arg_type: TypeId,
        scalar_return_vars: *const std.AutoHashMap(types_mod.TypeVarId, void),
        subs: *types_mod.SubstitutionMap,
        span: ast.SourceSpan,
    ) error{OutOfMemory}!bool {
        promoteContainerVarsExceptScalarReturn(self.store, param_type, arg_type, scalar_return_vars, subs, self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TypeStructureTooDeep => {
                try self.appendError(
                    span,
                    "monomorphization parameter/argument type walk for generic `{s}/{d}` exceeds maximum type nesting depth ({d})",
                    .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_DEPTH },
                );
                return false;
            },
            error.TypeStructureTooLarge => {
                try self.appendError(
                    span,
                    "monomorphization parameter/argument type walk for generic `{s}/{d}` contains more than {d} unique type nodes",
                    .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_NODES },
                );
                return false;
            },
            error.TypeGraphDepthLimitExceeded => {
                try self.appendError(
                    span,
                    "monomorphization parameter/argument type walk for generic `{s}/{d}` exceeds the type graph traversal depth budget",
                    .{ self.interner.get(generic_group.name), generic_group.arity },
                );
                return false;
            },
            error.TypeGraphNodeLimitExceeded => {
                try self.appendError(
                    span,
                    "monomorphization parameter/argument type walk for generic `{s}/{d}` exceeds the type graph traversal node budget",
                    .{ self.interner.get(generic_group.name), generic_group.arity },
                );
                return false;
            },
        };
        return true;
    }

    fn specializationWithinBudget(
        self: *MonomorphContext,
        generic_group: *const hir.FunctionGroup,
        type_args: []const TypeId,
        span: ast.SourceSpan,
    ) error{OutOfMemory}!bool {
        for (type_args) |type_arg| {
            self.typeStructureWithinBudget(type_arg) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TypeStructureTooDeep => {
                    try self.appendError(
                        span,
                        "monomorphization type argument for generic `{s}/{d}` exceeds maximum type nesting depth ({d})",
                        .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_DEPTH },
                    );
                    return false;
                },
                error.TypeStructureTooLarge => {
                    try self.appendError(
                        span,
                        "monomorphization type argument for generic `{s}/{d}` contains more than {d} unique type nodes",
                        .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_NODES },
                    );
                    return false;
                },
                error.TypeGraphDepthLimitExceeded => {
                    try self.appendError(
                        span,
                        "monomorphization type argument for generic `{s}/{d}` exceeds the type graph traversal depth budget",
                        .{ self.interner.get(generic_group.name), generic_group.arity },
                    );
                    return false;
                },
                error.TypeGraphNodeLimitExceeded => {
                    try self.appendError(
                        span,
                        "monomorphization type argument for generic `{s}/{d}` exceeds the type graph traversal node budget",
                        .{ self.interner.get(generic_group.name), generic_group.arity },
                    );
                    return false;
                },
            };
        }

        if (self.new_groups.items.len >= MAX_TOTAL_SPECIALIZATIONS) {
            try self.appendError(
                span,
                "monomorphization exceeded the total specialization limit while specializing `{s}/{d}`",
                .{ self.interner.get(generic_group.name), generic_group.arity },
            );
            return false;
        }

        const result = try self.specialization_counts.getOrPut(generic_group.id);
        if (!result.found_existing) result.value_ptr.* = 0;
        if (result.value_ptr.* >= MAX_SPECIALIZATIONS_PER_GENERIC) {
            try self.appendError(
                span,
                "monomorphization exceeded the per-generic specialization limit for `{s}/{d}`",
                .{ self.interner.get(generic_group.name), generic_group.arity },
            );
            return false;
        }
        result.value_ptr.* += 1;
        return true;
    }

    fn collectTransitiveScanEntries(
        self: *MonomorphContext,
        entries: []const NewGroupEntry,
    ) error{OutOfMemory}!std.ArrayListUnmanaged(NewGroupEntry) {
        var entries_to_scan: std.ArrayListUnmanaged(NewGroupEntry) = .empty;
        errdefer entries_to_scan.deinit(self.allocator);

        for (entries) |entry| {
            if (!try self.isGenericGroup(&entry.group)) {
                try entries_to_scan.append(self.allocator, entry);
            }
        }

        return entries_to_scan;
    }

    fn sameName(self: *const MonomorphContext, left: ast.StringId, right: ast.StringId) bool {
        return left == right or std.mem.eql(u8, self.interner.get(left), self.interner.get(right));
    }

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
            if (!self.sameName(impl_info.protocol_name, protocol_name)) continue;
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
            if (!self.sameName(impl_info.protocol_name, protocol_name)) continue;
            if (std.mem.eql(u8, self.interner.get(impl_info.target_struct), type_struct)) return true;
        }
        return false;
    }

    /// A parameter typed as a *bare* `protocol_constraint(P)` (one with no
    /// `type_params`, e.g. `e :: Error`) is a `dyn`-style existential: it
    /// lowers to a single `ProtocolBox`-taking body and every protocol-method
    /// call on it dispatches through the box vtable (`protocol_dispatch`).
    /// Such a parameter must NOT be monomorphized per concrete argument type —
    /// the whole point of the box is to avoid per-impl specialization, and
    /// substituting the parameter to a concrete struct leaves the body's
    /// protocol calls lowered against the `P` namespace (they were emitted
    /// existentially at HIR-build, when the receiver was still `P`), producing
    /// a broken `call_named P__method__N` that references the protocol type
    /// rather than a value (`expected pointer, found 'type'`).
    ///
    /// A *parametric* `protocol_constraint(P(args))` (one with `type_params`,
    /// e.g. `Enumerable(element)`) is the orthogonal "generic-with-bound" case:
    /// `HirBuilder.protocolDispatchStruct` devirtualizes its protocol calls to
    /// a `call_direct` against the concrete impl during HIR build, so per-
    /// instantiation specialization is both correct and required there. Only
    /// the bare/existential form returns true here.
    fn isExistentialProtocolConstraint(self: *const MonomorphContext, type_id: TypeId) bool {
        const typ = self.store.getType(type_id);
        return typ == .protocol_constraint and typ.protocol_constraint.type_params.len == 0;
    }

    fn protocolParamConcreteType(
        self: *const MonomorphContext,
        param_type: TypeId,
        arg_type: TypeId,
    ) TypeWalkError!?TypeId {
        // A collection whose element is a boxed `Callable` existential
        // (`[fn(i64) -> i64]` = `List(ProtocolBox)`) is a fully-defined
        // runtime type, so a parametric protocol parameter like
        // `Enumerable(element)` MUST bind `element = Callable` for it and
        // specialize — exactly as it does for `[i64]`. `isConcreteRuntimeType`
        // deliberately rejects a `protocol_constraint` element to keep the
        // bare-existential-PARAM (`e :: Error`) non-specialization rule, which
        // the `type_params.len == 0` guard below still enforces independently.
        // `typeArgIsMonomorphizationReady` accepts the boxed element while
        // still rejecting genuine free type variables. This is the same path
        // `[i64]` already takes; only the readiness predicate widens, so the
        // `Enumerable` devirtualization contract for non-closure lists is
        // untouched (the bound `element` stays `i64`/`String` there).
        if (!(try self.typeArgIsMonomorphizationReady(arg_type))) return null;

        const param_typ = self.store.getType(param_type);
        if (param_typ != .protocol_constraint) return null;
        // Bare protocol constraints are existentials (box-dispatched); never
        // pin them to a concrete argument type. See
        // `isExistentialProtocolConstraint` for the full rationale.
        if (param_typ.protocol_constraint.type_params.len == 0) return null;
        if (!self.typeImplementsProtocol(param_typ.protocol_constraint.protocol_name, arg_type)) return null;
        return arg_type;
    }

    fn bindProtocolTypeArgsFromImpl(
        self: *const MonomorphContext,
        constraint_type: TypeId,
        concrete_arg_type: TypeId,
        subs: *SubstitutionMap,
    ) TypeWalkError!void {
        const constraint = self.store.getType(constraint_type);
        if (constraint != .protocol_constraint) return;
        if (constraint.protocol_constraint.type_params.len == 0) return;

        const concrete_struct = self.store.typeToStructName(concrete_arg_type, self.interner) orelse return;
        for (self.program.impls) |impl_info| {
            if (!self.sameName(impl_info.protocol_name, constraint.protocol_constraint.protocol_name)) continue;
            if (impl_info.protocol_type_args.len != constraint.protocol_constraint.type_params.len) continue;
            if (!std.mem.eql(u8, self.interner.get(impl_info.target_struct), concrete_struct)) continue;
            if (impl_info.target_type_pattern == types_mod.TypeStore.UNKNOWN) continue;

            var impl_subs = SubstitutionMap.init(self.allocator);
            defer impl_subs.deinit();
            const unified = try self.store.unify(impl_info.target_type_pattern, concrete_arg_type, &impl_subs);
            if (!unified) continue;

            for (constraint.protocol_constraint.type_params, impl_info.protocol_type_args) |constraint_arg, impl_arg| {
                const concrete_protocol_arg = try impl_subs.applyToType(self.store, impl_arg);
                // A boxed `Callable` element is monomorphization-ready (it is a
                // `ProtocolBox` at runtime), so bind it as the protocol's
                // `element` type-arg just like a concrete `i64`. See
                // `protocolParamConcreteType` for why the widened predicate
                // preserves the `Enumerable`-devirtualization contract.
                if (!(try self.typeArgIsMonomorphizationReady(concrete_protocol_arg))) continue;
                _ = try self.store.unify(constraint_arg, concrete_protocol_arg, subs);
            }
            return;
        }
    }

    fn bindProtocolTypeArgsFromConstraintArg(
        self: *const MonomorphContext,
        constraint_type: TypeId,
        arg_type: TypeId,
        subs: *SubstitutionMap,
    ) TypeWalkError!void {
        const constraint = self.store.getType(constraint_type);
        if (constraint != .protocol_constraint) return;
        if (constraint.protocol_constraint.type_params.len == 0) return;

        const arg = self.store.getType(arg_type);
        if (arg != .protocol_constraint) return;
        if (!self.sameName(constraint.protocol_constraint.protocol_name, arg.protocol_constraint.protocol_name)) return;
        if (constraint.protocol_constraint.type_params.len != arg.protocol_constraint.type_params.len) return;

        for (constraint.protocol_constraint.type_params, arg.protocol_constraint.type_params) |constraint_arg, actual_arg| {
            if (try containsTypeVar(self.store, actual_arg, self.allocator)) continue;
            _ = try self.store.unify(constraint_arg, actual_arg, subs);
        }
    }

    fn defaultUnboundTypeVars(self: *const MonomorphContext, type_id: TypeId, default_type: TypeId) TypeWalkError!TypeId {
        return self.transformType(type_id, .{ .default_unbound = default_type });
    }

    fn transformType(
        self: *const MonomorphContext,
        root: TypeId,
        mode: TypeTransformMode,
    ) TypeWalkError!TypeId {
        var work: std.ArrayListUnmanaged(TypeTransformFrame) = .empty;
        defer work.deinit(self.allocator);
        var transformed = std.AutoHashMap(TypeId, TypeId).init(self.allocator);
        defer transformed.deinit();
        var visiting = std.AutoHashMap(TypeId, void).init(self.allocator);
        defer visiting.deinit();

        var nodes_seen: u32 = 0;
        try work.append(self.allocator, .{ .type_id = root, .depth = 0, .phase = .enter });
        while (work.pop()) |frame| {
            if (frame.depth > MAX_TYPE_STRUCTURE_DEPTH) return error.TypeStructureTooDeep;
            switch (frame.phase) {
                .enter => {
                    if (transformed.contains(frame.type_id)) continue;
                    if (visiting.contains(frame.type_id)) continue;
                    try visiting.put(frame.type_id, {});

                    nodes_seen += 1;
                    if (nodes_seen > MAX_TYPE_STRUCTURE_NODES) return error.TypeStructureTooLarge;

                    switch (self.store.getType(frame.type_id)) {
                        .type_var => {
                            const replacement = switch (mode) {
                                .default_unbound => |default_type| default_type,
                                .active_protocol_params => frame.type_id,
                            };
                            try transformed.put(frame.type_id, replacement);
                            _ = visiting.remove(frame.type_id);
                        },
                        .list, .tuple, .function, .map, .applied, .protocol_constraint => {
                            try work.append(self.allocator, .{ .type_id = frame.type_id, .depth = frame.depth, .phase = .exit });
                            try self.pushTypeTransformChildren(&work, frame.type_id, frame.depth + 1);
                        },
                        else => {
                            try transformed.put(frame.type_id, frame.type_id);
                            _ = visiting.remove(frame.type_id);
                        },
                    }
                },
                .exit => {
                    _ = visiting.remove(frame.type_id);
                    try transformed.put(frame.type_id, try self.finishTypeTransform(frame.type_id, mode, &transformed));
                },
            }
        }

        return transformed.get(root) orelse root;
    }

    fn pushTypeTransformChildren(
        self: *const MonomorphContext,
        work: *std.ArrayListUnmanaged(TypeTransformFrame),
        type_id: TypeId,
        depth: u32,
    ) TypeWalkError!void {
        switch (self.store.getType(type_id)) {
            .list => |list_type| try work.append(self.allocator, .{ .type_id = list_type.element, .depth = depth, .phase = .enter }),
            .tuple => |tuple_type| for (tuple_type.elements) |element| {
                try work.append(self.allocator, .{ .type_id = element, .depth = depth, .phase = .enter });
            },
            .function => |function_type| {
                for (function_type.params) |param| {
                    try work.append(self.allocator, .{ .type_id = param, .depth = depth, .phase = .enter });
                }
                try work.append(self.allocator, .{ .type_id = function_type.return_type, .depth = depth, .phase = .enter });
            },
            .map => |map_type| {
                try work.append(self.allocator, .{ .type_id = map_type.key, .depth = depth, .phase = .enter });
                try work.append(self.allocator, .{ .type_id = map_type.value, .depth = depth, .phase = .enter });
            },
            .applied => |applied_type| {
                try work.append(self.allocator, .{ .type_id = applied_type.base, .depth = depth, .phase = .enter });
                for (applied_type.args) |arg| {
                    try work.append(self.allocator, .{ .type_id = arg, .depth = depth, .phase = .enter });
                }
            },
            .protocol_constraint => |protocol_constraint| for (protocol_constraint.type_params) |type_param| {
                try work.append(self.allocator, .{ .type_id = type_param, .depth = depth, .phase = .enter });
            },
            else => {},
        }
    }

    fn transformedChild(transformed: *const std.AutoHashMap(TypeId, TypeId), type_id: TypeId) TypeId {
        return transformed.get(type_id) orelse type_id;
    }

    fn finishTypeTransform(
        self: *const MonomorphContext,
        type_id: TypeId,
        mode: TypeTransformMode,
        transformed: *const std.AutoHashMap(TypeId, TypeId),
    ) TypeWalkError!TypeId {
        return switch (self.store.getType(type_id)) {
            .list => |list_type| blk: {
                const element = transformedChild(transformed, list_type.element);
                if (element == list_type.element) break :blk type_id;
                break :blk try self.store.addType(.{ .list = .{ .element = element } });
            },
            .tuple => |tuple_type| blk: {
                var changed = false;
                for (tuple_type.elements) |element| {
                    if (transformedChild(transformed, element) != element) {
                        changed = true;
                        break;
                    }
                }
                if (!changed) break :blk type_id;

                const elements = try self.allocator.alloc(TypeId, tuple_type.elements.len);
                errdefer self.allocator.free(elements);
                for (tuple_type.elements, 0..) |element, index| {
                    elements[index] = transformedChild(transformed, element);
                }
                const type_count_before_insert = self.store.types.items.len;
                const new_type_id = try self.store.addType(.{ .tuple = .{ .elements = elements } });
                if (new_type_id < type_count_before_insert) self.allocator.free(elements);
                break :blk new_type_id;
            },
            .function => |function_type| blk: {
                var params_changed = false;
                for (function_type.params) |param| {
                    if (transformedChild(transformed, param) != param) {
                        params_changed = true;
                        break;
                    }
                }
                const return_type = transformedChild(transformed, function_type.return_type);
                if (!params_changed and return_type == function_type.return_type) break :blk type_id;

                var owned_params: ?[]TypeId = null;
                errdefer if (owned_params) |params| self.allocator.free(params);
                const params = if (params_changed) params_blk: {
                    const new_params = try self.allocator.alloc(TypeId, function_type.params.len);
                    owned_params = new_params;
                    for (function_type.params, 0..) |param, index| {
                        new_params[index] = transformedChild(transformed, param);
                    }
                    break :params_blk new_params;
                } else function_type.params;

                const type_count_before_insert = self.store.types.items.len;
                const new_type_id = try self.store.addType(.{ .function = .{
                    .params = params,
                    .return_type = return_type,
                    .param_ownerships = function_type.param_ownerships,
                    .return_ownership = function_type.return_ownership,
                    .raises = function_type.raises,
                    .effect_var = function_type.effect_var,
                    .raises_row = function_type.raises_row,
                } });
                if (new_type_id < type_count_before_insert) {
                    if (owned_params) |owned| self.allocator.free(owned);
                }
                break :blk new_type_id;
            },
            .map => |map_type| blk: {
                const key = transformedChild(transformed, map_type.key);
                const value = transformedChild(transformed, map_type.value);
                if (key == map_type.key and value == map_type.value) break :blk type_id;
                break :blk try self.store.addType(.{ .map = .{ .key = key, .value = value } });
            },
            .applied => |applied_type| blk: {
                const base = transformedChild(transformed, applied_type.base);
                var args_changed = base != applied_type.base;
                for (applied_type.args) |arg| {
                    if (transformedChild(transformed, arg) != arg) {
                        args_changed = true;
                        break;
                    }
                }
                if (!args_changed) break :blk type_id;

                const args = try self.allocator.alloc(TypeId, applied_type.args.len);
                errdefer self.allocator.free(args);
                for (applied_type.args, 0..) |arg, index| {
                    args[index] = transformedChild(transformed, arg);
                }
                const type_count_before_insert = self.store.types.items.len;
                const new_type_id = try self.store.addType(.{ .applied = .{ .base = base, .args = args } });
                if (new_type_id < type_count_before_insert) self.allocator.free(args);
                break :blk new_type_id;
            },
            .protocol_constraint => |protocol_constraint| blk: {
                var params_changed = false;
                for (protocol_constraint.type_params) |type_param| {
                    if (transformedChild(transformed, type_param) != type_param) {
                        params_changed = true;
                        break;
                    }
                }

                const candidate_type = if (params_changed) candidate_blk: {
                    const type_params = try self.allocator.alloc(TypeId, protocol_constraint.type_params.len);
                    errdefer self.allocator.free(type_params);
                    for (protocol_constraint.type_params, 0..) |type_param, index| {
                        type_params[index] = transformedChild(transformed, type_param);
                    }
                    const type_count_before_insert = self.store.types.items.len;
                    const new_type_id = try self.store.addType(.{ .protocol_constraint = .{
                        .protocol_name = protocol_constraint.protocol_name,
                        .type_params = type_params,
                    } });
                    if (new_type_id < type_count_before_insert) self.allocator.free(type_params);
                    break :candidate_blk new_type_id;
                } else type_id;

                break :blk switch (mode) {
                    .active_protocol_params => (try self.protocolConstraintReplacement(candidate_type)) orelse candidate_type,
                    .default_unbound => candidate_type,
                };
            },
            else => type_id,
        };
    }

    fn inferEmptyListProtocolReceiverType(
        self: *const MonomorphContext,
        constraint: types_mod.Type.ProtocolConstraintType,
        subs: ?*const SubstitutionMap,
        allow_default: bool,
    ) TypeWalkError!TypeId {
        const list_default = try self.store.addType(.{ .list = .{ .element = types_mod.TypeStore.I64 } });
        const list_struct = self.store.typeToStructName(list_default, self.interner) orelse return types_mod.TypeStore.UNKNOWN;

        for (self.program.impls) |impl_info| {
            if (!self.sameName(impl_info.protocol_name, constraint.protocol_name)) continue;
            if (impl_info.protocol_type_args.len != constraint.type_params.len) continue;
            if (!std.mem.eql(u8, self.interner.get(impl_info.target_struct), list_struct)) continue;

            var impl_subs = SubstitutionMap.init(self.allocator);
            defer impl_subs.deinit();

            for (impl_info.protocol_type_args, constraint.type_params) |impl_arg, constraint_arg| {
                const effective_constraint_arg = if (subs) |active_subs|
                    try active_subs.applyToType(self.store, constraint_arg)
                else
                    constraint_arg;
                if (!(try self.isConcreteRuntimeType(effective_constraint_arg))) continue;
                _ = try self.store.unify(impl_arg, effective_constraint_arg, &impl_subs);
            }

            var inferred = try impl_subs.applyToType(self.store, impl_info.target_type_pattern);
            if (!(try self.isConcreteRuntimeType(inferred)) and allow_default) {
                inferred = try self.defaultUnboundTypeVars(inferred, types_mod.TypeStore.I64);
            }
            if (try self.isConcreteRuntimeType(inferred)) return inferred;
            if (allow_default and self.typeImplementsProtocol(constraint.protocol_name, list_default)) return list_default;
        }

        return if (allow_default and self.typeImplementsProtocol(constraint.protocol_name, list_default))
            list_default
        else
            types_mod.TypeStore.UNKNOWN;
    }

    fn isConcreteRuntimeType(self: *const MonomorphContext, type_id: TypeId) TypeWalkError!bool {
        return self.runtimeTypePredicate(type_id, .concrete);
    }

    fn runtimeTypePredicate(
        self: *const MonomorphContext,
        type_id: TypeId,
        predicate: RuntimeTypePredicate,
    ) TypeWalkError!bool {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return false;
        var walker = TypeWalker.init(self.allocator);
        defer walker.deinit();

        try walker.pushRoot(type_id);
        while (try walker.next()) |item| {
            const next_depth = item.depth + 1;
            switch (self.store.getType(item.type_id)) {
                .unknown, .error_type, .type_var => return false,
                .protocol_constraint => {
                    if (predicate == .concrete) return false;
                },
                .list => |list_type| try walker.pushType(list_type.element, next_depth, false),
                .tuple => |tuple_type| {
                    for (tuple_type.elements) |element| try walker.pushType(element, next_depth, false);
                },
                .function => |function_type| {
                    for (function_type.params) |param| try walker.pushType(param, next_depth, false);
                    try walker.pushType(function_type.return_type, next_depth, false);
                },
                .map => |map_type| {
                    try walker.pushType(map_type.key, next_depth, false);
                    try walker.pushType(map_type.value, next_depth, false);
                },
                .applied => |applied_type| {
                    try walker.pushType(applied_type.base, next_depth, false);
                    for (applied_type.args) |arg| try walker.pushType(arg, next_depth, false);
                },
                .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .term_type => {},
                .struct_type, .union_type, .tagged_union, .opaque_type => {},
            }
        }
        return true;
    }

    /// Like `isConcreteRuntimeType`, but a `protocol_constraint` existential
    /// (`Callable({i64}, i64)`, `Error`) counts as concrete because it has a
    /// fully-defined runtime representation — the `ProtocolBox` fat pointer.
    ///
    /// WHY a separate predicate (rather than flipping `isConcreteRuntimeType`):
    /// `isConcreteRuntimeType` gates protocol-PARAMETER specialization
    /// (`protocolParamConcreteType`, the effect/Enumerable paths), where a
    /// bare existential param `e :: Error` must deliberately stay
    /// box-dispatched and NOT pin to a concrete arg. That contract is
    /// unchanged. This predicate is for the orthogonal question "is a derived
    /// type ARGUMENT ready to monomorphize a generic container function?" —
    /// e.g. `t -> Callable({i64}, i64)` when specializing `List.get` for a
    /// `[fn(i64) -> i64]` (i.e. `List(ProtocolBox)`). The boxed element is a
    /// concrete runtime type, so `List.get`/`List.set`/… MUST specialize for
    /// it (otherwise the call resolves to an un-emitted generic
    /// `List__get__2`). Containers recurse so `[fn(i64) -> i64]`'s element is
    /// recognized as ready. A free `type_var` is still NOT ready.
    fn typeArgIsMonomorphizationReady(self: *const MonomorphContext, type_id: TypeId) TypeWalkError!bool {
        return self.runtimeTypePredicate(type_id, .monomorphization_ready);
    }

    /// True when the function body currently being scanned is itself generic
    /// — at least one of its parameters still carries a free type variable.
    /// The empty-literal `i64` fallback in `resolveCallArgumentType` keys off
    /// this: that guess is only sound once the surrounding body is concrete
    /// (the transitive pass), never during the single generic pass over the
    /// original body. `current_scan_params` is null outside a scan, in which
    /// case there is no generic context to worry about.
    fn currentScanIsGeneric(self: *const MonomorphContext) TypeWalkError!bool {
        const params = self.current_scan_params orelse return false;
        for (params) |param| {
            if (try containsTypeVar(self.store, param.type_id, self.allocator)) return true;
        }
        return false;
    }

    fn resolveCallArgumentType(
        self: *const MonomorphContext,
        arg: hir.CallArg,
        param_type: ?TypeId,
        subs: ?*const SubstitutionMap,
        allow_default_empty_protocol_list: bool,
    ) TypeWalkError!TypeId {
        var arg_type = arg.expr.type_id;

        // If the argument is a call that was already specialized, use
        // the specialization's return type as the arg type. This handles
        // nested calls like List.empty?(Enum.map([], f)) where the inner
        // call has a concrete return type.
        if (!(try self.isConcreteRuntimeType(arg_type)) and arg.expr.kind == .call) {
            if (self.call_rewrites.get(@intFromPtr(arg.expr))) |spec_id| {
                for (self.new_groups.items) |entry| {
                    if (entry.group.id == spec_id and entry.group.clauses.len > 0) {
                        const spec_ret = entry.group.clauses[0].return_type;
                        if (try self.isConcreteRuntimeType(spec_ret)) {
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
        //
        // FCC unified model: a specialized combinator (`Enum.map` for a
        // `[fn(..) -> ..]`) carries a parameter whose type is a `List` of boxed
        // `Callable` existentials (`List(ProtocolBox)`) — fully runtime-defined
        // but NOT `isConcreteRuntimeType` (its element is a `protocol_constraint`).
        // When that parameter is forwarded into a recursive helper (`map_next`),
        // its concrete `List(Callable)` type MUST flow so the helper specializes
        // for the boxed element and the recursion targets the specialized copy.
        // `typeArgIsMonomorphizationReady` accepts the boxed-element collection
        // while still rejecting genuine free type variables.
        if (arg.expr.kind == .param_get and self.current_scan_params != null) {
            const pidx = arg.expr.kind.param_get;
            if (pidx < self.current_scan_params.?.len) {
                const scan_param_type = self.current_scan_params.?[pidx].type_id;
                if (try self.typeArgIsMonomorphizationReady(scan_param_type)) {
                    arg_type = scan_param_type;
                }
            }
        }

        // Monomorphized call sites carry substituted expected types on
        // their arguments. Use those when the expression itself is still
        // `any`/UNKNOWN. This is what lets recursive protocol helpers keep
        // the concrete state type returned by a protocol impl.
        //
        // FCC unified model: a boxed `Callable({A}, R)` argument (a
        // `protocol_constraint`) is NOT `isConcreteRuntimeType` by the narrow
        // predicate, but it IS a fully-defined runtime value — a `ProtocolBox`
        // existential. It must NOT be overwritten by the parameter's
        // `expected_type` (a `fn(A) -> R` function type, possibly carrying the
        // higher-order `effect_var`): doing so would erase the boxed-ness and
        // make the argument's type identical to the param's, so `unify`
        // short-circuits on type identity and never binds the `effect_var` —
        // leaving the higher-order callee unspecialized (the call site then
        // references a dropped generic group). The boxed existential's own
        // type is the truth; keep it.
        if (!(try self.isConcreteRuntimeType(arg_type)) and
            self.store.getType(arg_type) != .protocol_constraint and
            (try self.isConcreteRuntimeType(arg.expected_type)))
        {
            arg_type = arg.expected_type;
        }

        // Empty container literal: adopt the parameter's container type so
        // the call specializes the right way. The previous code defaulted
        // to `[i64]` / `Map(Atom,i64)` regardless of the parameter, which
        // silently picked the wrong overload (e.g. `[]` passed to `[String]`
        // specialized as `[i64]`). We only do this when the parameter is
        // fully concrete; if it still has type variables (generic context),
        // let the unifier handle it.
        if (!(try self.isConcreteRuntimeType(arg_type))) {
            if (param_type) |pt| {
                // The bare-`[]` / bare-`%{}` `i64` fallback is only a sound
                // default in a fully CONCRETE scan context. Inside a generic
                // body (a parameter still carries a free type variable) the
                // monomorphizer is making a single throwaway pass whose only
                // job is to find specializations fully pinned by concrete
                // arguments; the concrete instantiation of this very body is
                // re-scanned later with substituted params. Guessing `[i64]`
                // for an empty literal whose element is actually a shared,
                // not-yet-known type variable (e.g. `collect_next(collection,
                // [])` where `collection :: Enumerable(element)` and
                // `accumulator :: [element]`) binds that shared `element` to
                // `i64` and bakes a bogus `<i64>` specialization that then
                // poisons every downstream call's element type. Suppress the
                // fallback here and let the concrete transitive pass infer the
                // element from the real argument.
                const allow_empty_default = allow_default_empty_protocol_list and !(try self.currentScanIsGeneric());
                const effective_param_type = if (subs) |active_subs| try active_subs.applyToType(self.store, pt) else pt;
                const param_typ = self.store.getType(effective_param_type);
                switch (param_typ) {
                    .list => |list_t| {
                        if (arg.expr.kind == .list_init and (try self.isConcreteRuntimeType(list_t.element))) {
                            arg_type = effective_param_type;
                        } else if (arg.expr.kind == .list_init and
                            arg.expr.kind.list_init.len == 0 and
                            allow_empty_default)
                        {
                            const inferred = try self.defaultUnboundTypeVars(effective_param_type, types_mod.TypeStore.I64);
                            if (try self.isConcreteRuntimeType(inferred)) arg_type = inferred;
                        }
                    },
                    .map => |map_t| {
                        if (arg.expr.kind == .map_init and
                            (try self.isConcreteRuntimeType(map_t.key)) and
                            (try self.isConcreteRuntimeType(map_t.value)))
                        {
                            arg_type = effective_param_type;
                        } else if (arg.expr.kind == .map_init and
                            arg.expr.kind.map_init.len == 0 and
                            allow_empty_default)
                        {
                            const inferred = try self.defaultUnboundTypeVars(effective_param_type, types_mod.TypeStore.I64);
                            if (try self.isConcreteRuntimeType(inferred)) arg_type = inferred;
                        }
                    },
                    .protocol_constraint => |protocol_constraint| {
                        if (arg.expr.kind == .list_init and arg.expr.kind.list_init.len == 0) {
                            const inferred = try self.inferEmptyListProtocolReceiverType(
                                protocol_constraint,
                                subs,
                                allow_empty_default,
                            );
                            if (inferred != types_mod.TypeStore.UNKNOWN) arg_type = inferred;
                        }
                    },
                    else => {},
                }
            }
        }

        return arg_type;
    }

    fn effectiveExprType(self: *const MonomorphContext, expr: *const hir.Expr) TypeWalkError!TypeId {
        var type_id = expr.type_id;

        switch (expr.kind) {
            .local_get => |local| {
                if (self.local_types.get(local)) |tracked_type| {
                    type_id = tracked_type;
                }
            },
            .param_get => |param_index| {
                if (self.current_scan_params) |params| {
                    // Accept a boxed-element collection (`List(Callable)`) — a
                    // monomorphization-ready type that is not narrowly
                    // `isConcreteRuntimeType` — so a specialized combinator's
                    // boxed-`Callable` parameter type flows for nested calls.
                    if (param_index < params.len and (try self.typeArgIsMonomorphizationReady(params[param_index].type_id))) {
                        type_id = params[param_index].type_id;
                    }
                }
            },
            .call => {
                if (!(try self.isConcreteRuntimeType(type_id))) {
                    if (self.call_rewrites.get(@intFromPtr(expr))) |rewritten_group_id| {
                        if (self.findFunctionGroupById(rewritten_group_id)) |group| {
                            // FCC unified model: a devirtualized `Enumerable.next`
                            // over a `[fn(..) -> ..]` resolves to `List.next`
                            // whose return is `{Atom, Callable, List(Callable)}` —
                            // a fully runtime-defined tuple that is NOT narrowly
                            // `isConcreteRuntimeType` (its element is a
                            // `protocol_constraint`). Adopt it so the projected
                            // `next_state` records `List(Callable)` and the
                            // recursive combinator call re-specializes for the
                            // boxed element. `typeArgIsMonomorphizationReady`
                            // accepts the boxed-element tuple, rejects free vars.
                            if (group.clauses.len > 0 and (try self.typeArgIsMonomorphizationReady(group.clauses[0].return_type))) {
                                type_id = group.clauses[0].return_type;
                            }
                        }
                    }
                }
            },
            else => {},
        }

        return type_id;
    }

    fn cloneLocalTypes(self: *const MonomorphContext) !std.AutoHashMap(u32, TypeId) {
        var snapshot = std.AutoHashMap(u32, TypeId).init(self.allocator);
        var it = self.local_types.iterator();
        while (it.next()) |entry| {
            try snapshot.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return snapshot;
    }

    fn restoreLocalTypes(self: *MonomorphContext, snapshot: *std.AutoHashMap(u32, TypeId)) void {
        self.local_types.deinit();
        self.local_types = snapshot.*;
        snapshot.* = std.AutoHashMap(u32, TypeId).init(self.allocator);
    }

    fn recordCaseBindingType(
        self: *MonomorphContext,
        bindings: []const hir.CaseBinding,
        binding_index: *usize,
        type_id: TypeId,
    ) MonomorphWalkError!void {
        if (binding_index.* >= bindings.len) return;
        defer binding_index.* += 1;

        // FCC unified model: a case binding whose type is a `List` of boxed
        // `Callable` existentials (the `next_state` projected from a
        // protocol-impl `next/1` over a `[fn(..) -> ..]`) is a fully runtime-
        // defined type that MUST be tracked so the recursive combinator call on
        // it (`map_next(next_state, ...)`) re-specializes for the boxed element.
        // `typeArgIsMonomorphizationReady` accepts it while rejecting genuine
        // free type variables (a generic-context binding stays untracked).
        if (!(try self.typeArgIsMonomorphizationReady(type_id))) return;
        try self.local_types.put(bindings[binding_index.*].local_index, type_id);
    }

    fn recordCasePatternLocalTypesBudgeted(
        self: *MonomorphContext,
        pattern: *const hir.MatchPattern,
        parent_type: TypeId,
        bindings: []const hir.CaseBinding,
        binding_index: *usize,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!void {
        try budget.enter(depth);
        switch (pattern.*) {
            .wildcard, .literal, .pin => {},
            .bind => |name| {
                if (ast.isDiscardBindName(self.interner.get(name))) return;
                try self.recordCaseBindingType(bindings, binding_index, parent_type);
            },
            .tuple => |elements| {
                const parent_typ = self.store.getType(parent_type);
                for (elements, 0..) |element, element_index| {
                    const element_type = if (parent_typ == .tuple and element_index < parent_typ.tuple.elements.len)
                        parent_typ.tuple.elements[element_index]
                    else
                        types_mod.TypeStore.UNKNOWN;
                    try self.recordCasePatternLocalTypesBudgeted(element, element_type, bindings, binding_index, budget, depth + 1);
                }
            },
            .list => |elements| {
                const parent_typ = self.store.getType(parent_type);
                const element_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                for (elements) |element| {
                    try self.recordCasePatternLocalTypesBudgeted(element, element_type, bindings, binding_index, budget, depth + 1);
                }
            },
            .list_cons => |list_cons| {
                const parent_typ = self.store.getType(parent_type);
                const element_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                for (list_cons.heads) |head| {
                    try self.recordCasePatternLocalTypesBudgeted(head, element_type, bindings, binding_index, budget, depth + 1);
                }
                try self.recordCasePatternLocalTypesBudgeted(list_cons.tail, parent_type, bindings, binding_index, budget, depth + 1);
            },
            .struct_match => |struct_match| {
                const parent_typ = self.store.getType(parent_type);
                // Parametric receivers — `case b { %Box{value: v} -> v }`
                // on `b :: Box(i64)` — look through `.applied { base, args }`
                // to the underlying struct declaration and build the
                // per-instantiation substitution so each field-binding's
                // recorded local type is the substituted concrete type
                // (`i64`), not the raw type variable. Without this the
                // monomorphizer would record UNKNOWN for parametric
                // pattern bindings and subsequent argument-type
                // inference at nested calls would lose the instantiation.
                const struct_shape, const subs_opt = blk: {
                    if (parent_typ == .struct_type) {
                        break :blk .{ parent_typ.struct_type, @as(?SubstitutionMap, null) };
                    }
                    if (parent_typ == .applied) {
                        const base_typ = self.store.getType(parent_typ.applied.base);
                        if (base_typ != .struct_type) break :blk .{ types_mod.Type.StructType{ .name = 0, .fields = &.{} }, @as(?SubstitutionMap, null) };
                        const decl_struct = base_typ.struct_type;
                        var subs = SubstitutionMap.init(self.allocator);
                        const pair_count = @min(decl_struct.type_params.len, parent_typ.applied.args.len);
                        for (decl_struct.type_params[0..pair_count], parent_typ.applied.args[0..pair_count]) |formal_id, arg_id| {
                            const formal_typ = self.store.getType(formal_id);
                            if (formal_typ != .type_var) continue;
                            try subs.bind(formal_typ.type_var, arg_id);
                        }
                        break :blk .{ decl_struct, @as(?SubstitutionMap, subs) };
                    }
                    break :blk .{ types_mod.Type.StructType{ .name = 0, .fields = &.{} }, @as(?SubstitutionMap, null) };
                };
                var subs_mut = subs_opt;
                defer if (subs_mut) |*owned| owned.deinit();
                for (struct_match.field_bindings) |field| {
                    var field_type: TypeId = types_mod.TypeStore.UNKNOWN;
                    for (struct_shape.fields) |struct_field| {
                        if (struct_field.name == field.field_name) {
                            field_type = struct_field.type_id;
                            break;
                        }
                    }
                    if (subs_mut) |*subs| {
                        if (field_type != types_mod.TypeStore.UNKNOWN) {
                            field_type = try subs.applyToType(self.store, field_type);
                        }
                    }
                    try self.recordCasePatternLocalTypesBudgeted(field.pattern, field_type, bindings, binding_index, budget, depth + 1);
                }
            },
            .map_match => |map_match| {
                const parent_typ = self.store.getType(parent_type);
                const value_type = if (parent_typ == .map) parent_typ.map.value else types_mod.TypeStore.UNKNOWN;
                for (map_match.field_bindings) |field| {
                    try self.recordCasePatternLocalTypesBudgeted(field.pattern, value_type, bindings, binding_index, budget, depth + 1);
                }
            },
            .binary_match => |binary_match| {
                for (binary_match.segments) |segment| {
                    const segment_pattern = segment.pattern orelse continue;
                    if (segment_pattern.* != .bind) continue;
                    if (ast.isDiscardBindName(self.interner.get(segment_pattern.bind))) continue;
                    try self.recordCaseBindingType(bindings, binding_index, types_mod.TypeStore.UNKNOWN);
                }
            },
            .tagged_variant_match => |tvm| {
                // Resolve the variant's declared payload type through
                // the case scrutinee's tagged-union declaration, then
                // substitute any applied args before recording the
                // inner binding's local type. Mirrors the .struct_match
                // arm's parametric handling: an `Option(i64).Some(v)`
                // pattern records `v :: i64`, an `Option.None` pattern
                // records nothing (no payload, no bindings).
                if (tvm.payload == null) return;
                const payload_pat = tvm.payload.?;
                const parent_typ = self.store.getType(parent_type);
                const tagged_decl, const subs_opt = blk: {
                    if (parent_typ == .tagged_union) {
                        break :blk .{ parent_typ.tagged_union, @as(?SubstitutionMap, null) };
                    }
                    if (parent_typ == .applied) {
                        const base_typ = self.store.getType(parent_typ.applied.base);
                        if (base_typ != .tagged_union) break :blk .{
                            types_mod.Type.TaggedUnionType{ .name = 0, .variants = &.{}, .type_params = &.{} },
                            @as(?SubstitutionMap, null),
                        };
                        const decl_union = base_typ.tagged_union;
                        var subs = SubstitutionMap.init(self.allocator);
                        const pair_count = @min(decl_union.type_params.len, parent_typ.applied.args.len);
                        for (decl_union.type_params[0..pair_count], parent_typ.applied.args[0..pair_count]) |formal_id, arg_id| {
                            const formal_typ = self.store.getType(formal_id);
                            if (formal_typ != .type_var) continue;
                            try subs.bind(formal_typ.type_var, arg_id);
                        }
                        break :blk .{ decl_union, @as(?SubstitutionMap, subs) };
                    }
                    break :blk .{
                        types_mod.Type.TaggedUnionType{ .name = 0, .variants = &.{}, .type_params = &.{} },
                        @as(?SubstitutionMap, null),
                    };
                };
                var subs_mut = subs_opt;
                defer if (subs_mut) |*owned| owned.deinit();
                var payload_type: TypeId = types_mod.TypeStore.UNKNOWN;
                for (tagged_decl.variants) |variant| {
                    if (variant.name != tvm.variant_name) continue;
                    payload_type = variant.type_id orelse types_mod.TypeStore.UNKNOWN;
                    break;
                }
                if (subs_mut) |*subs| {
                    if (payload_type != types_mod.TypeStore.UNKNOWN) {
                        payload_type = try subs.applyToType(self.store, payload_type);
                    }
                }
                try self.recordCasePatternLocalTypesBudgeted(payload_pat, payload_type, bindings, binding_index, budget, depth + 1);
            },
        }
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
    /// True when `mod_name` (a possibly multi-segment struct name such as
    /// `Zap.CombinatorFactory`) is the struct addressed by `qualifier`, the
    /// textual `struct_name` carried on a `hir.NamedCall`. A cross-struct
    /// call's qualifier is produced by the HIR builder's `structNameToString`
    /// (segments joined with `_`, e.g. `Zap_CombinatorFactory`), but a call
    /// may also be qualified by the bare last segment or by the canonical
    /// dotted form. Mirror `HirBuilder.structNameMatchesCallQualifier` so the
    /// monomorphizer resolves cross-struct calls to multi-segment user structs
    /// identically to the HIR layer — without this, a generic method addressed
    /// as `Zap_Foo.method` never matches `mod.name.parts == ["Zap", "Foo"]`
    /// (whose last segment is `Foo`), so the call is never specialized and the
    /// caller emits a reference to a function that is never produced.
    fn structNameMatchesQualifier(self: *const MonomorphContext, mod_name: ast.StructName, qualifier: []const u8) Allocator.Error!bool {
        if (mod_name.parts.len == 0) return false;

        const last_part = self.interner.get(mod_name.parts[mod_name.parts.len - 1]);
        if (std.mem.eql(u8, last_part, qualifier)) return true;

        // Single-segment names are fully covered by the last-part check above.
        if (mod_name.parts.len == 1) return false;

        const underscore_joined = try mod_name.joinedWith(self.allocator, self.interner, "_");
        defer self.allocator.free(underscore_joined);
        if (std.mem.eql(u8, underscore_joined, qualifier)) return true;

        const dotted = try mod_name.joinedWith(self.allocator, self.interner, ".");
        defer self.allocator.free(dotted);
        if (std.mem.eql(u8, dotted, qualifier)) return true;

        return false;
    }

    fn resolveNamedCall(self: *const MonomorphContext, nc: hir.NamedCall, arity: u32) Allocator.Error!?u32 {
        const target_struct = nc.struct_name orelse return null;
        for (self.program.structs) |mod| {
            // Check if this struct's name matches the target. The qualifier may
            // be the bare last segment, the `_`-joined form (the HIR builder's
            // `structNameToString` output for cross-struct calls), or the
            // canonical dotted form — match all three for multi-segment user
            // structs (e.g. `Zap.CombinatorFactory`).
            if (!try self.structNameMatchesQualifier(mod.name, target_struct)) continue;
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

    fn callTargetClauseIndex(target: hir.CallTarget) usize {
        return switch (target) {
            .direct => |direct| if (direct.clause_index) |index| @intCast(index) else 0,
            .named => |named| if (named.clause_index) |index| @intCast(index) else 0,
            else => 0,
        };
    }

    fn callTargetParamType(
        self: *const MonomorphContext,
        target: hir.CallTarget,
        arity: usize,
        arg_index: usize,
    ) Allocator.Error!?TypeId {
        const group_id = switch (target) {
            .direct => |direct| direct.function_group_id,
            .dispatch => |dispatch| dispatch.function_group_id,
            .named => |named| (try self.resolveNamedCall(named, @intCast(arity))) orelse return null,
            else => return null,
        };
        const group = self.findFunctionGroupById(group_id) orelse return null;
        if (group.clauses.len == 0) return null;
        const clause_index = callTargetClauseIndex(target);
        if (clause_index >= group.clauses.len) return null;
        if (arg_index >= group.clauses[clause_index].params.len) return null;
        return group.clauses[clause_index].params[arg_index].type_id;
    }

    fn callTargetGroupId(self: *const MonomorphContext, target: hir.CallTarget, arity: usize) Allocator.Error!?u32 {
        return switch (target) {
            .direct => |direct| direct.function_group_id,
            .dispatch => |dispatch| dispatch.function_group_id,
            .named => |named| (try self.resolveNamedCall(named, @intCast(arity))) orelse return null,
            else => null,
        };
    }

    fn modeForOwnership(ownership: hir.Ownership) hir.ValueMode {
        return switch (ownership) {
            .shared => .share,
            .unique => .move,
            .borrowed => .borrow,
        };
    }

    fn applyTargetArgModes(self: *const MonomorphContext, target: hir.CallTarget, args: []hir.CallArg) Allocator.Error!void {
        const group_id = (try self.callTargetGroupId(target, args.len)) orelse return;
        const group = self.findFunctionGroupById(group_id) orelse return;
        if (group.clauses.len == 0) return;
        const clause_index = callTargetClauseIndex(target);
        if (clause_index >= group.clauses.len) return;
        const params = group.clauses[clause_index].params;
        const count = @min(args.len, params.len);
        for (args[0..count], params[0..count]) |*arg, param| {
            if (!param.ownership_explicit) continue;
            arg.mode = modeForOwnership(param.ownership);
        }
    }

    /// P3-J2 per-spawn manager-monomorphization: retarget one call to the
    /// model-specialized clone of its callee, if that callee is inside the
    /// spawn-reachable subgraph being cloned. `redirect` maps original group
    /// id → model-clone id (populated by `specializeSpawnManagers` for one
    /// reclamation model). Mirrors the type-argument rewrite in
    /// `rewriteExprBudgeted` exactly: `.direct`/`.dispatch` keep their variant
    /// with a new `function_group_id`; a `.named` call that resolves into the
    /// subgraph becomes a `.direct` call to the clone (carrying the resolved
    /// `clause_index`). Any target not in the subgraph — an indirect
    /// `.closure`, a `.builtin`, or a `.named`/`.direct` whose callee is a cold
    /// (unspecialized) function — is returned unchanged, which is exactly the
    /// hot/cold boundary: cold callees keep manifest emission and dispatch
    /// through the running process's manager context at runtime.
    fn redirectCallTargetForModel(
        self: *const MonomorphContext,
        target: hir.CallTarget,
        arity: usize,
        redirect: *const std.AutoHashMap(u32, u32),
    ) Allocator.Error!hir.CallTarget {
        switch (target) {
            .direct => |dc| {
                if (redirect.get(dc.function_group_id)) |clone_id| {
                    return .{ .direct = .{ .function_group_id = clone_id, .clause_index = dc.clause_index } };
                }
            },
            .dispatch => |dp| {
                if (redirect.get(dp.function_group_id)) |clone_id| {
                    var new_dispatch = dp;
                    new_dispatch.function_group_id = clone_id;
                    return .{ .dispatch = new_dispatch };
                }
            },
            .named => |nc| {
                const resolved = (try self.resolveNamedCall(nc, @intCast(arity))) orelse return target;
                if (redirect.get(resolved)) |clone_id| {
                    return .{ .direct = .{ .function_group_id = clone_id, .clause_index = nc.clause_index } };
                }
            },
            // `.closure` (indirect Callable — the cold boundary) and `.builtin`
            // are never model-redirected.
            .closure, .builtin => {},
        }
        return target;
    }

    fn scanBlock(self: *MonomorphContext, block: *const hir.Block) error{OutOfMemory}!void {
        var budget = HirWalkBudget{};
        self.scanBlockBudgeted(block, &budget, 0) catch |err| {
            try self.appendWalkBudgetError(blockSpan(block), "HIR scan", err);
        };
    }

    fn scanBlockBudgeted(
        self: *MonomorphContext,
        block: *const hir.Block,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!void {
        try budget.enter(depth);
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| try self.scanExprBudgeted(e, budget, depth + 1),
                .local_set => |ls| {
                    try self.scanExprBudgeted(ls.value, budget, depth + 1);
                    const val_type = try self.effectiveExprType(ls.value);
                    if (!(try self.store.containsTypeVars(val_type)) and val_type != types_mod.TypeStore.UNKNOWN) {
                        try self.local_types.put(ls.index, val_type);
                    }
                    // Also track the type when the value is a list_init with known element types
                    if (val_type == types_mod.TypeStore.UNKNOWN and ls.value.kind == .list_init) {
                        const elems = ls.value.kind.list_init;
                        if (elems.len > 0 and elems[0].type_id != types_mod.TypeStore.UNKNOWN) {
                            const inferred = try self.store.addType(.{ .list = .{ .element = elems[0].type_id } });
                            try self.local_types.put(ls.index, inferred);
                        }
                    }
                },
                .function_group => |fg| {
                    // Nested function groups (anonymous closures, named
                    // inner fns) have their own local index space — they
                    // reset HIR's `next_local` counter on entry. Without
                    // isolating the `local_types` map across that
                    // boundary, a nested `local_set idx=N` overwrites the
                    // outer scope's `local_types[N]`, corrupting type
                    // information for the caller's locals (e.g., the
                    // outer `pairs` at idx=0 gets clobbered by the
                    // closure's destructure-assigned `value_local` also
                    // at idx=0). Snapshot and restore around each clause
                    // so each function's local-type tracking stays
                    // isolated.
                    for (fg.clauses) |clause| {
                        var snapshot = try self.cloneLocalTypes();
                        defer snapshot.deinit();
                        self.local_types.clearRetainingCapacity();
                        try self.scanBlockBudgeted(clause.body, budget, depth + 1);
                        self.restoreLocalTypes(&snapshot);
                    }
                },
            }
        }
    }

    fn scanExpr(self: *MonomorphContext, expr: *const hir.Expr) error{OutOfMemory}!void {
        var budget = HirWalkBudget{};
        self.scanExprBudgeted(expr, &budget, 0) catch |err| {
            try self.appendWalkBudgetError(expr.span, "HIR expression scan", err);
        };
    }

    fn scanExprBudgeted(
        self: *MonomorphContext,
        expr: *const hir.Expr,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!void {
        try budget.enter(depth);
        switch (expr.kind) {
            .call => |call| {
                // Scan args first (may contain nested calls)
                for (call.args) |arg| {
                    try self.scanExprBudgeted(arg.expr, budget, depth + 1);
                }

                // An implicit value-call (`expr(args)`) carries its callee as a
                // `.closure` target — an arbitrary expression that yields the
                // callable. That callee expression may itself be a generic call
                // that needs specialization (e.g. the inline
                // `List.get(filtered, 0)(v)`: the callee `List.get(filtered, 0)`
                // over a freshly-monomorphized `[Callable]` list must specialize
                // `List.get` for the boxed element). The three resolvable
                // target kinds below (`.direct`/`.dispatch`/`.named`) name a
                // function group directly and have no callee subexpression;
                // only the `.closure` target does. Scan it so its nested calls
                // are specialized — otherwise the value-call's callee references
                // an un-produced generic specialization at ZIR emission. A
                // bound-local / param callee (`g = List.get(..); g(v)`) is
                // already covered because its producing `local_set` was scanned.
                if (call.target == .closure) {
                    try self.scanExprBudgeted(call.target.closure, budget, depth + 1);
                }

                // Check if this calls a generic function or a protocol function
                var protocol_resolved_target = false;
                const target_id = switch (call.target) {
                    .direct => |dc| dc.function_group_id,
                    .dispatch => |dp| dp.function_group_id,
                    .named => |nc| blk: {
                        // Check for protocol dispatch: Enumerable.each(list, callback)
                        if (self.isProtocolCall(nc)) |proto_name| {
                            // Find the concrete type from the first argument.
                            // FCC unified model: a receiver that is a collection
                            // of boxed `Callable` existentials (`List(Callable)`,
                            // the iteration state inside a specialized combinator
                            // over a `[fn(..) -> ..]`) is a fully runtime-defined
                            // type, so `Enumerable.next(state)` MUST devirtualize
                            // to the concrete `List.next` impl here — otherwise the
                            // clone keeps a generic protocol-dispatch target and
                            // the ZIR backend emits a bare `Enumerable` namespace
                            // reference (`zap_runtime has no member 'Enumerable'`).
                            // `typeArgIsMonomorphizationReady` accepts the boxed-
                            // element collection while rejecting free type vars.
                            if (call.args.len > 0) {
                                const arg_type = try self.resolveCallArgumentType(call.args[0], null, null, true);
                                if (try self.typeArgIsMonomorphizationReady(arg_type)) {
                                    if (self.resolveProtocolDispatch(proto_name, nc.name, arg_type, @intCast(call.args.len))) |impl_gid| {
                                        protocol_resolved_target = true;
                                        break :blk impl_gid;
                                    }
                                }
                            }
                            return; // Can't resolve protocol dispatch — skip
                        }
                        const resolved = (try self.resolveNamedCall(nc, @intCast(call.args.len))) orelse return;
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
                const selected_clause_index = callTargetClauseIndex(call.target);
                if (selected_clause_index >= generic_group.clauses.len) return;
                const selected_clause = &generic_group.clauses[selected_clause_index];
                if (selected_clause.params.len != call.args.len) return;

                var subs = SubstitutionMap.init(self.allocator);
                defer subs.deinit();

                const protocol_param_types = try self.allocator.alloc(TypeId, selected_clause.params.len);
                defer self.allocator.free(protocol_param_types);
                @memset(protocol_param_types, types_mod.TypeStore.UNKNOWN);

                // Unify argument types with parameter types. UNKNOWN arguments
                // are skipped rather than failing — partial unification allows
                // type variables to be bound from the arguments that ARE known
                // (e.g., binding element=i64 from the list arg even when the
                // callback arg is an unresolved function reference).
                for (0..2) |pass| {
                    const allow_default_empty_protocol_list = pass == 1;
                    for (selected_clause.params, call.args, 0..) |param, arg, param_index| {
                        const arg_type = try self.resolveCallArgumentType(
                            arg,
                            param.type_id,
                            &subs,
                            allow_default_empty_protocol_list,
                        );
                        if (arg_type == types_mod.TypeStore.UNKNOWN or arg_type == types_mod.TypeStore.ERROR) continue;
                        if (try self.protocolParamConcreteType(param.type_id, arg_type)) |concrete_protocol_type| {
                            protocol_param_types[param_index] = concrete_protocol_type;
                            try self.bindProtocolTypeArgsFromImpl(param.type_id, concrete_protocol_type, &subs);
                        }
                        try self.bindProtocolTypeArgsFromConstraintArg(param.type_id, arg_type, &subs);
                        _ = try self.store.unify(param.type_id, arg_type, &subs);
                    }
                }

                // FCC unified model — re-stamp a closure-literal callback's
                // higher-order parameter to the boxed `Callable` representation
                // when this combinator iterates a `[fn(..) -> ..]` (boxed
                // `Callable`) collection. See the helper for the full rationale.
                try self.restampClosureArgParamsForBoxedCallable(selected_clause.params, call.args, &subs);

                // Type variables can appear only in the return type for
                // constructor-shaped generic functions such as
                // `List.new_empty(capacity) -> List(t)`. Argument unification
                // has no way to bind `t` there, but the HIR expression may
                // already carry a concrete contextual type from `expr :: Type`
                // or another typed use site. Unify that concrete result type
                // against the generic return before deciding whether this call
                // has enough type arguments to specialize.
                {
                    const contextual_return = try self.effectiveExprType(expr);
                    if (try self.isConcreteRuntimeType(contextual_return)) {
                        _ = try self.store.unify(selected_clause.return_type, contextual_return, &subs);
                    }
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
                    const return_uses_var_as_scalar = try self.scalarTypeVarSetForReturn(generic_group, selected_clause.return_type, expr.span);
                    var return_scalar_set = return_uses_var_as_scalar orelse return;
                    defer return_scalar_set.deinit();
                    for (selected_clause.params, call.args) |param, arg| {
                        const arg_type = try self.resolveCallArgumentType(arg, param.type_id, &subs, true);
                        if (arg_type == types_mod.TypeStore.UNKNOWN or arg_type == types_mod.TypeStore.ERROR) continue;
                        if (!try self.promoteContainerVarsForCall(generic_group, param.type_id, arg_type, &return_scalar_set, &subs, expr.span)) return;
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
                if (try self.hasUnboundProtocolParams(selected_clause.params, protocol_param_types, &subs)) return;

                if (type_args.items.len == 0) return;

                // Skip if any type arg still contains type variables — this happens
                // when scanning inside generic function bodies where args are unresolved.
                // Creating such specializations produces bogus stubs (e.g. head__T).
                // A boxed `protocol_constraint` existential (`Callable({i64},
                // i64)` for a `[fn(i64) -> i64]` element) IS ready: it lowers
                // to `ProtocolBox`, so a container generic like `List.get`
                // must specialize for it. `typeArgIsMonomorphizationReady`
                // accepts it while still rejecting genuine free type vars.
                {
                    var has_unresolved_type = false;
                    for (type_args.items) |ta| {
                        if (!(try self.typeArgIsMonomorphizationReady(ta))) {
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
                    if (!(try self.isConcreteRuntimeType(expr.type_id))) {
                        const concrete_return = try subs.applyToType(self.store, selected_clause.return_type);
                        if (try self.isConcreteRuntimeType(concrete_return)) {
                            @constCast(expr).type_id = concrete_return;
                        }
                    }
                    return;
                }

                if (!try self.specializationWithinBudget(generic_group, type_args.items, expr.span)) return;

                // Create specialized clone
                const new_id = self.next_group_id.*;
                const specialized = self.cloneGroupWithSubs(generic_group, &subs, protocol_param_types, type_args.items, new_id, selected_clause_index) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.HirStructureTooDeep => {
                        try self.appendError(
                            expr.span,
                            "monomorphization clone for generic `{s}/{d}` exceeds maximum HIR nesting depth ({d})",
                            .{ self.interner.get(generic_group.name), generic_group.arity, MAX_HIR_STRUCTURE_DEPTH },
                        );
                        return;
                    },
                    error.HirStructureTooLarge => {
                        try self.appendError(
                            expr.span,
                            "monomorphization clone for generic `{s}/{d}` contains more than {d} HIR nodes",
                            .{ self.interner.get(generic_group.name), generic_group.arity, MAX_HIR_STRUCTURE_NODES },
                        );
                        return;
                    },
                    error.TypeStructureTooDeep => {
                        try self.appendError(
                            expr.span,
                            "monomorphization type substitution for generic `{s}/{d}` exceeds maximum type nesting depth ({d})",
                            .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_DEPTH },
                        );
                        return;
                    },
                    error.TypeStructureTooLarge => {
                        try self.appendError(
                            expr.span,
                            "monomorphization type substitution for generic `{s}/{d}` contains more than {d} unique type nodes",
                            .{ self.interner.get(generic_group.name), generic_group.arity, MAX_TYPE_STRUCTURE_NODES },
                        );
                        return;
                    },
                    error.TypeGraphDepthLimitExceeded => {
                        try self.appendError(
                            expr.span,
                            "monomorphization type graph traversal for generic `{s}/{d}` exceeds the substitution depth budget",
                            .{ self.interner.get(generic_group.name), generic_group.arity },
                        );
                        return;
                    },
                    error.TypeGraphNodeLimitExceeded => {
                        try self.appendError(
                            expr.span,
                            "monomorphization type graph traversal for generic `{s}/{d}` exceeds the substitution node budget",
                            .{ self.interner.get(generic_group.name), generic_group.arity },
                        );
                        return;
                    },
                    error.TypeMangleDepthLimitExceeded => {
                        try self.appendError(
                            expr.span,
                            "monomorphization could not build a specialization name for generic `{s}/{d}` because a type argument's canonical name exceeds the structural depth budget",
                            .{ self.interner.get(generic_group.name), generic_group.arity },
                        );
                        return;
                    },
                    error.TypeMangleNodeLimitExceeded => {
                        try self.appendError(
                            expr.span,
                            "monomorphization could not build a specialization name for generic `{s}/{d}` because a type argument's canonical name exceeds the structural node budget",
                            .{ self.interner.get(generic_group.name), generic_group.arity },
                        );
                        return;
                    },
                };
                self.next_group_id.* += 1;
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
                if (!(try self.isConcreteRuntimeType(expr.type_id))) {
                    const concrete_return = try subs.applyToType(self.store, selected_clause.return_type);
                    if (try self.isConcreteRuntimeType(concrete_return)) {
                        @constCast(expr).type_id = concrete_return;
                    }
                }
            },
            // Recurse into sub-expressions
            .binary => |b| {
                try self.scanExprBudgeted(b.lhs, budget, depth + 1);
                try self.scanExprBudgeted(b.rhs, budget, depth + 1);
            },
            .unary => |u| try self.scanExprBudgeted(u.operand, budget, depth + 1),
            .tuple_init => |elems| {
                for (elems) |e| try self.scanExprBudgeted(e, budget, depth + 1);
            },
            .list_init => |elems| {
                for (elems) |e| try self.scanExprBudgeted(e, budget, depth + 1);
            },
            .list_cons => |lc| {
                try self.scanExprBudgeted(lc.head, budget, depth + 1);
                try self.scanExprBudgeted(lc.tail, budget, depth + 1);
            },
            .map_init => |entries| {
                for (entries) |entry| {
                    try self.scanExprBudgeted(entry.key, budget, depth + 1);
                    try self.scanExprBudgeted(entry.value, budget, depth + 1);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| {
                    try self.scanExprBudgeted(field.value, budget, depth + 1);
                }
            },
            .field_get => |fg| try self.scanExprBudgeted(fg.object, budget, depth + 1),
            .tuple_index_get => |tig| try self.scanExprBudgeted(tig.object, budget, depth + 1),
            .list_index_get => |lig| try self.scanExprBudgeted(lig.list, budget, depth + 1),
            .list_head_get => |lhg| try self.scanExprBudgeted(lhg.list, budget, depth + 1),
            .list_tail_get => |ltg| try self.scanExprBudgeted(ltg.list, budget, depth + 1),
            .map_value_get => |mvg| {
                try self.scanExprBudgeted(mvg.map, budget, depth + 1);
                try self.scanExprBudgeted(mvg.key, budget, depth + 1);
            },
            .branch => |br| {
                try self.scanExprBudgeted(br.condition, budget, depth + 1);
                try self.scanBlockBudgeted(br.then_block, budget, depth + 1);
                if (br.else_block) |eb| try self.scanBlockBudgeted(eb, budget, depth + 1);
            },
            .block => |b| try self.scanBlockBudgeted(&b, budget, depth + 1),
            .panic => |e| try self.scanExprBudgeted(e, budget, depth + 1),
            .unwrap => |e| try self.scanExprBudgeted(e, budget, depth + 1),
            .ret_raise => |rr| try self.scanExprBudgeted(rr.stash_call, budget, depth + 1),
            .union_init => |ui| try self.scanExprBudgeted(ui.value, budget, depth + 1),
            .error_pipe => |ep| {
                for (ep.steps) |step| {
                    try self.scanExprBudgeted(step.expr, budget, depth + 1);
                }
                try self.scanExprBudgeted(ep.handler, budget, depth + 1);
            },
            .case => |cd| {
                try self.scanExprBudgeted(cd.scrutinee, budget, depth + 1);
                const scrutinee_type = try self.effectiveExprType(cd.scrutinee);
                for (cd.arms) |arm| {
                    var local_type_snapshot = try self.cloneLocalTypes();
                    defer local_type_snapshot.deinit();

                    if (arm.pattern) |pattern| {
                        var binding_index: usize = 0;
                        self.recordCasePatternLocalTypesBudgeted(pattern, scrutinee_type, arm.bindings, &binding_index, budget, depth + 1) catch |err| {
                            try self.appendWalkBudgetError(expr.span, "case pattern local type recording", err);
                            return;
                        };
                    }
                    if (arm.guard) |g| try self.scanExprBudgeted(g, budget, depth + 1);
                    try self.scanBlockBudgeted(arm.body, budget, depth + 1);
                    self.restoreLocalTypes(&local_type_snapshot);
                }
            },
            .try_rescue => |tr| {
                try self.scanBlockBudgeted(tr.body, budget, depth + 1);
                try self.scanExprBudgeted(tr.raise_occurred_call, budget, depth + 1);
                try self.scanExprBudgeted(tr.take_raise_call, budget, depth + 1);
                const error_type = try self.effectiveExprType(tr.take_raise_call);
                for (tr.arms) |arm| {
                    var local_type_snapshot = try self.cloneLocalTypes();
                    defer local_type_snapshot.deinit();
                    if (arm.pattern) |pattern| {
                        var binding_index: usize = 0;
                        self.recordCasePatternLocalTypesBudgeted(pattern, error_type, arm.bindings, &binding_index, budget, depth + 1) catch |err| {
                            try self.appendWalkBudgetError(expr.span, "rescue pattern local type recording", err);
                            return;
                        };
                    }
                    if (arm.guard) |g| try self.scanExprBudgeted(g, budget, depth + 1);
                    try self.scanBlockBudgeted(arm.body, budget, depth + 1);
                    self.restoreLocalTypes(&local_type_snapshot);
                }
                if (tr.after_block) |cleanup| try self.scanBlockBudgeted(cleanup, budget, depth + 1);
            },
            .match => |m| try self.scanExprBudgeted(m.scrutinee, budget, depth + 1),
            .closure_create => |cc| {
                for (cc.captures) |cap| try self.scanExprBudgeted(cap.expr, budget, depth + 1);
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
        subs: *const SubstitutionMap,
    ) TypeWalkError!bool {
        for (params, 0..) |param, param_index| {
            if (self.store.getType(param.type_id) != .protocol_constraint) continue;
            // Bare/existential protocol constraints (`e :: Error`) are
            // intentionally box-dispatched and carry no concrete substitution;
            // they must not block specialization driven by OTHER generic
            // params (e.g. `fn f(e :: Error, xs :: [t])` still specializes on
            // `t` while `e` stays a `ProtocolBox`). A parametric protocol
            // constraint blocks specialization only while its own type
            // arguments remain unresolved. `Enumerable(i64)` is already a
            // concrete protocol-box ABI shape; requiring a concrete impl type
            // there drops helper specializations such as
            // `Enum.dispose_and_return(state :: Enumerable(i64), value :: Bool)`.
            if (self.isExistentialProtocolConstraint(param.type_id)) continue;
            if (param_index < protocol_param_types.len and protocol_param_types[param_index] != types_mod.TypeStore.UNKNOWN) {
                continue;
            }
            const substituted_param_type = try subs.applyToType(self.store, param.type_id);
            if (self.store.getType(substituted_param_type) == .protocol_constraint) {
                continue;
            }
            if (try containsTypeVar(self.store, substituted_param_type, self.allocator)) return true;
        }
        return false;
    }

    fn protocolConstraintReplacement(self: *const MonomorphContext, constraint_type: TypeId) TypeWalkError!?TypeId {
        const source_params = self.current_protocol_source_param_types orelse return null;
        const concrete_params = self.current_protocol_param_types orelse return null;
        const constraint = self.store.getType(constraint_type);
        if (constraint != .protocol_constraint) return null;

        var replacement: TypeId = types_mod.TypeStore.UNKNOWN;
        var replacement_count: u32 = 0;
        for (source_params, 0..) |source_param, param_index| {
            if (param_index >= concrete_params.len) continue;
            if (concrete_params[param_index] == types_mod.TypeStore.UNKNOWN) continue;
            const source_param_type = if (self.current_subs) |subs|
                try subs.applyToType(self.store, source_param.type_id)
            else
                source_param.type_id;
            const source_type = self.store.getType(source_param_type);
            if (source_type != .protocol_constraint) continue;
            if (!self.sameName(source_type.protocol_constraint.protocol_name, constraint.protocol_constraint.protocol_name)) continue;
            if (!std.mem.eql(TypeId, source_type.protocol_constraint.type_params, constraint.protocol_constraint.type_params)) continue;
            replacement = concrete_params[param_index];
            replacement_count += 1;
        }

        return if (replacement_count == 1) replacement else null;
    }

    fn applyActiveProtocolParamTypes(self: *MonomorphContext, type_id: TypeId) TypeWalkError!TypeId {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return type_id;
        return self.transformType(type_id, .active_protocol_params);
    }

    /// FCC unified model: if `param_type` is a higher-order `fn(A) -> R`
    /// (`function`) whose polymorphic `effect_var` (#201) was bound by `subs`
    /// to a `Callable({A}, R)` existential, return that `Callable` constraint
    /// — the boxed representation this specialization receives. Otherwise
    /// return `param_type` unchanged. A higher-order param invoked with an
    /// INLINE/non-escaping closure binds its effect_var to a concrete
    /// `function` type (not a `Callable`), so this leaves the zero-overhead
    /// direct path's param a `function` (no boxing) — the #201 no-regression
    /// invariant. Only a boxed-`Callable` argument re-stamps the param.
    fn boxedCallableRepresentationForParam(
        self: *const MonomorphContext,
        param_type: TypeId,
        subs: *const SubstitutionMap,
    ) TypeWalkError!TypeId {
        const typ = self.store.getType(param_type);
        if (typ != .function) return param_type;
        const effect_var = typ.function.effect_var orelse return param_type;
        const resolved_effect = try subs.applyToType(self.store, effect_var);
        const resolved_typ = self.store.getType(resolved_effect);
        if (resolved_typ != .protocol_constraint) return param_type;
        if (!std.mem.eql(u8, self.interner.get(resolved_typ.protocol_constraint.protocol_name), "Callable")) return param_type;
        return resolved_effect;
    }

    /// A parametric `protocol_constraint` whose protocol is exactly `Callable`
    /// — the always-boxed first-class-closure existential. Keyed precisely on
    /// the protocol NAME so a parametric NON-`Callable` constraint
    /// (`Enumerable(i64)`) is excluded (it devirtualizes per-impl and must
    /// never be treated as a boxed `ProtocolBox` body — the V11 contract).
    fn protocolConstraintIsBoxedCallable(self: *const MonomorphContext, type_id: TypeId) bool {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return false;
        const typ = self.store.getType(type_id);
        if (typ != .protocol_constraint) return false;
        if (typ.protocol_constraint.type_params.len == 0) return false;
        return std.mem.eql(u8, self.interner.get(typ.protocol_constraint.protocol_name), "Callable");
    }

    /// Resolve the closure-literal `FunctionGroup` reachable from a callback
    /// argument expression. A closure literal lowers (in `hir.zig`
    /// `buildExpr.anonymous_function`) to a `block { function_group,
    /// closure_create }`; a directly-referenced closure value is a bare
    /// `closure_create`. Returns the lifted closure group in either shape, so
    /// the combinator-element re-stamp can reach its parameters. Returns null
    /// for any other argument (a `&Struct.fn/1` function reference, a
    /// pre-bound `local_get`, etc.) — those are not closure literals and must
    /// not be mutated.
    fn closureFunctionGroupForArg(self: *MonomorphContext, expr: *const hir.Expr) ?*const hir.FunctionGroup {
        switch (expr.kind) {
            .closure_create => |cc| return self.findFunctionGroupById(cc.function_group_id),
            .block => |b| {
                for (b.stmts) |stmt| {
                    if (stmt == .function_group) return stmt.function_group;
                }
                return null;
            },
            else => return null,
        }
    }

    /// FCC unified model — when a combinator (`Enum.map`/`each`/`reduce`/…)
    /// iterates a `[fn(A) -> R]` collection (a `List` of boxed `Callable`
    /// existentials), its callback receives each element as a boxed `Callable`
    /// (`ProtocolBox`), not a bare function pointer. A closure-literal callback
    /// `fn(f :: fn(A) -> R) -> B { f(x) }` declares its higher-order parameter
    /// `f` as a `fn(A) -> R` that the type checker made representation-
    /// polymorphic (a fresh `effect_var`, since `f` is invoked in the body).
    /// That polymorphism makes the lifted closure group GENERIC, so the IR
    /// builder skips it and its `make_closure` references an un-emitted
    /// function (`EmitFailed`). The closure is single-use (an anonymous literal
    /// passed directly to the combinator), so re-stamp the offending parameter
    /// IN PLACE to the boxed `Callable` representation the combinator binds for
    /// `element`: this makes the closure NON-generic (a `protocol_constraint`
    /// is specialize-ready) and routes the body's `f(x)` through the box `call`
    /// slot (`protocol_dispatch`).
    ///
    /// Driven entirely by the combinator's own `subs`: the callback parameter's
    /// substituted type (`fn(element) -> mapped` with `element = Callable`)
    /// supplies the exact boxed-`Callable` types to stamp. Keyed twice for
    /// precision: (1) the combinator's expected callback parameter at that
    /// position must be a boxed `Callable` (`protocolConstraintIsBoxedCallable`
    /// — so iterating `[i64]`/`[String]` leaves the closure param `i64`/`String`
    /// untouched), and (2) the closure's current parameter must itself be an
    /// effect-polymorphic `fn(..)` (a higher-order param that can be boxed —
    /// so a first-order callback param is never disturbed). A `&Struct.fn/1`
    /// function reference is not a closure literal and is skipped.
    fn restampClosureArgParamsForBoxedCallable(
        self: *MonomorphContext,
        params: []const hir.TypedParam,
        args: []const hir.CallArg,
        subs: *const SubstitutionMap,
    ) TypeWalkError!void {
        const pair_count = @min(params.len, args.len);
        for (params[0..pair_count], args[0..pair_count]) |param, arg| {
            const expected = try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, param.type_id));
            const expected_typ = self.store.getType(expected);
            if (expected_typ != .function) continue;

            const closure_group = self.closureFunctionGroupForArg(arg.expr) orelse continue;
            for (closure_group.clauses) |clause| {
                const restamp_count = @min(clause.params.len, expected_typ.function.params.len);
                for (clause.params[0..restamp_count], expected_typ.function.params[0..restamp_count]) |*closure_param, expected_param| {
                    if (!self.protocolConstraintIsBoxedCallable(expected_param)) continue;
                    const closure_param_typ = self.store.getType(closure_param.type_id);
                    if (closure_param_typ != .function) continue;
                    if (closure_param_typ.function.effect_var == null) continue;
                    @constCast(closure_param).type_id = expected_param;
                }
            }
        }
    }

    fn cloneGroupWithSubs(
        self: *MonomorphContext,
        group: *const hir.FunctionGroup,
        subs: *const SubstitutionMap,
        protocol_param_types: []const TypeId,
        type_args: []const TypeId,
        new_id: u32,
        source_clause_index: usize,
    ) CloneGroupError!hir.FunctionGroup {
        const saved_subs = self.current_subs;
        const saved_protocol_param_types = self.current_protocol_param_types;
        const saved_protocol_source_param_types = self.current_protocol_source_param_types;
        self.current_subs = subs;
        self.current_protocol_param_types = protocol_param_types;
        self.current_protocol_source_param_types = if (source_clause_index < group.clauses.len) group.clauses[source_clause_index].params else &.{};
        defer self.current_subs = saved_subs;
        defer self.current_protocol_param_types = saved_protocol_param_types;
        defer self.current_protocol_source_param_types = saved_protocol_source_param_types;

        var clone_budget = HirWalkBudget{};
        var new_clauses: std.ArrayListUnmanaged(hir.Clause) = .empty;
        for (group.clauses) |clause| {
            // Substitute types in params
            var new_params = try self.allocator.alloc(hir.TypedParam, clause.params.len);
            for (clause.params, 0..) |param, i| {
                const protocol_param_type = if (i < protocol_param_types.len) protocol_param_types[i] else types_mod.TypeStore.UNKNOWN;
                const substituted_param_type = if (protocol_param_type != types_mod.TypeStore.UNKNOWN)
                    protocol_param_type
                else
                    try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, param.type_id));
                new_params[i] = .{
                    .name = param.name,
                    // FCC unified model: a higher-order parameter whose declared
                    // `fn(A) -> R` type carries a polymorphic `effect_var` (#201)
                    // that `subs` bound to a `Callable({A}, R)` existential is
                    // receiving a BOXED closure argument in THIS specialization.
                    // Its runtime representation must be the boxed `Callable`
                    // (`protocol_box`), so the body's `f(v)` call dispatches
                    // through the box `call` slot (`protocol_dispatch`) rather
                    // than a direct `call_ref` on a function pointer. Re-stamp
                    // the param to that `Callable` constraint. This is also what
                    // makes the clone non-generic: leaving the `function` type
                    // with an effect_var that still mentions the (now-bound)
                    // type variable would make `isGenericGroup` re-classify the
                    // clone as generic and drop it.
                    .type_id = try self.boxedCallableRepresentationForParam(substituted_param_type, subs),
                    .ownership = param.ownership,
                    .ownership_explicit = param.ownership_explicit,
                    .pattern = param.pattern,
                    .default = if (param.default) |d| try self.cloneExprBudgeted(d, &clone_budget, 0) else null,
                };
            }

            try new_clauses.append(self.allocator, .{
                .params = new_params,
                .return_type = try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, clause.return_type)),
                .decision = try self.cloneDecisionBudgeted(clause.decision, &clone_budget, 0),
                .body = try self.cloneBlockBudgeted(clause.body, &clone_budget, 0),
                .refinement = if (clause.refinement) |r| try self.cloneExprBudgeted(r, &clone_budget, 0) else null,
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
            try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ source_struct_prefix, base_name })
        else
            base_name;
        defer if (source_struct_prefix.len > 0) self.allocator.free(qualified_base);

        const mangled_str = try mangleName(self.allocator, qualified_base, self.store, type_args);
        defer self.allocator.free(mangled_str);
        const mangled_name = try self.interner.intern(mangled_str);

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

    fn cloneBlock(self: *MonomorphContext, block: *const hir.Block) MonomorphWalkError!*const hir.Block {
        var budget = HirWalkBudget{};
        return self.cloneBlockBudgeted(block, &budget, 0);
    }

    fn cloneBlockBudgeted(
        self: *MonomorphContext,
        block: *const hir.Block,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!*const hir.Block {
        try budget.enter(depth);
        var new_stmts: std.ArrayListUnmanaged(hir.Stmt) = .empty;
        for (block.stmts) |stmt| {
            try new_stmts.append(self.allocator, try self.cloneStmtBudgeted(stmt, budget, depth + 1));
        }
        const result = try self.allocator.create(hir.Block);
        result.* = .{
            .stmts = try new_stmts.toOwnedSlice(self.allocator),
            .result_type = if (self.current_subs) |subs|
                try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, block.result_type))
            else
                try self.applyActiveProtocolParamTypes(block.result_type),
        };
        return result;
    }

    fn cloneStmtBudgeted(
        self: *MonomorphContext,
        stmt: hir.Stmt,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!hir.Stmt {
        try budget.enter(depth);
        return switch (stmt) {
            .expr => |e| .{ .expr = try self.cloneExprBudgeted(e, budget, depth + 1) },
            .local_set => |ls| .{ .local_set = .{
                .index = ls.index,
                .value = try self.cloneExprBudgeted(ls.value, budget, depth + 1),
            } },
            .function_group => |fg| .{ .function_group = fg }, // local fns: share, not specialized
        };
    }

    fn cloneExpr(self: *MonomorphContext, expr: *const hir.Expr) MonomorphWalkError!*const hir.Expr {
        var budget = HirWalkBudget{};
        return self.cloneExprBudgeted(expr, &budget, 0);
    }

    fn cloneExprBudgeted(
        self: *MonomorphContext,
        expr: *const hir.Expr,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!*const hir.Expr {
        try budget.enter(depth);
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
                break :blk try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, expr.type_id));
            }
            break :blk try self.applyActiveProtocolParamTypes(expr.type_id);
        };
        result.* = .{
            .kind = try self.cloneExprKindBudgeted(expr.kind, budget, depth),
            .type_id = substituted_type,
            .span = expr.span,
            .expansion = expr.expansion,
        };
        return result;
    }

    fn cloneExprKindBudgeted(
        self: *MonomorphContext,
        kind: hir.ExprKind,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!hir.ExprKind {
        return switch (kind) {
            // Literals and refs — no heap pointers to clone
            .int_lit, .float_lit, .string_lit, .atom_lit, .bool_lit, .nil_lit => kind,
            .local_get, .param_get, .capture_get => kind,
            .never => kind,

            .binary => |b| .{ .binary = .{
                .op = b.op,
                .lhs = try self.cloneExprBudgeted(b.lhs, budget, depth + 1),
                .rhs = try self.cloneExprBudgeted(b.rhs, budget, depth + 1),
            } },
            .unary => |u| .{ .unary = .{
                .op = u.op,
                .operand = try self.cloneExprBudgeted(u.operand, budget, depth + 1),
            } },
            .call => |c| blk: {
                var new_args = try self.allocator.alloc(hir.CallArg, c.args.len);
                for (c.args, 0..) |arg, i| {
                    const expected_type = (try self.callTargetParamType(c.target, c.args.len, i)) orelse arg.expected_type;
                    new_args[i] = .{
                        .expr = try self.cloneExprBudgeted(arg.expr, budget, depth + 1),
                        .mode = arg.mode,
                        .expected_type = if (self.current_subs) |subs|
                            try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, expected_type))
                        else
                            try self.applyActiveProtocolParamTypes(expected_type),
                    };
                }
                // #201 — for an indirect (closure) call the callee
                // expression carries the closure's static type. Clone it
                // through `cloneExpr` so its `type_id` is substituted by
                // the active monomorphization map: a polymorphic closure
                // parameter (`effect_var = tv`) resolves to the concrete
                // raising/pure closure type for THIS instance. Without
                // re-cloning, the call site keeps the un-substituted
                // polymorphic type and the `call_closure` lowering can't
                // tell whether to unwrap the closure's error union.
                const cloned_target: hir.CallTarget = switch (c.target) {
                    .closure => |callee| .{ .closure = try self.cloneExprBudgeted(callee, budget, depth + 1) },
                    else => c.target,
                };
                // P3-J2: when cloning a spawn-reachable subgraph for a
                // reclamation model, redirect resolvable direct/named/dispatch
                // calls to the model clones so the specialization stays a closed
                // subgraph. Indirect (`.closure`) targets are the cold boundary
                // and are never redirected.
                const new_target: hir.CallTarget = if (self.current_model_call_redirect) |redirect|
                    try self.redirectCallTargetForModel(cloned_target, c.args.len, redirect)
                else
                    cloned_target;
                try self.applyTargetArgModes(new_target, new_args);
                break :blk .{ .call = .{ .target = new_target, .args = new_args } };
            },
            .tuple_init => |elems| blk: {
                var new_elems = try self.allocator.alloc(*const hir.Expr, elems.len);
                for (elems, 0..) |e, i| new_elems[i] = try self.cloneExprBudgeted(e, budget, depth + 1);
                break :blk .{ .tuple_init = new_elems };
            },
            .list_init => |elems| blk: {
                var new_elems = try self.allocator.alloc(*const hir.Expr, elems.len);
                for (elems, 0..) |e, i| new_elems[i] = try self.cloneExprBudgeted(e, budget, depth + 1);
                break :blk .{ .list_init = new_elems };
            },
            .list_cons => |lc| .{ .list_cons = .{
                .head = try self.cloneExprBudgeted(lc.head, budget, depth + 1),
                .tail = try self.cloneExprBudgeted(lc.tail, budget, depth + 1),
            } },
            .map_init => |entries| blk: {
                var new_entries = try self.allocator.alloc(hir.MapEntry, entries.len);
                for (entries, 0..) |entry, i| {
                    new_entries[i] = .{
                        .key = try self.cloneExprBudgeted(entry.key, budget, depth + 1),
                        .value = try self.cloneExprBudgeted(entry.value, budget, depth + 1),
                    };
                }
                break :blk .{ .map_init = new_entries };
            },
            .struct_init => |si| blk: {
                var new_fields = try self.allocator.alloc(hir.StructFieldInit, si.fields.len);
                for (si.fields, 0..) |f, i| {
                    new_fields[i] = .{ .name = f.name, .value = try self.cloneExprBudgeted(f.value, budget, depth + 1) };
                }
                const substituted_struct_type = if (self.current_subs) |subs|
                    try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, si.type_id))
                else
                    try self.applyActiveProtocolParamTypes(si.type_id);
                break :blk .{ .struct_init = .{ .type_id = substituted_struct_type, .fields = new_fields } };
            },
            .field_get => |fg| .{ .field_get = .{
                .object = try self.cloneExprBudgeted(fg.object, budget, depth + 1),
                .field = fg.field,
            } },
            .tuple_index_get => |tig| .{ .tuple_index_get = .{
                .object = try self.cloneExprBudgeted(tig.object, budget, depth + 1),
                .index = tig.index,
            } },
            .list_index_get => |lig| .{ .list_index_get = .{
                .list = try self.cloneExprBudgeted(lig.list, budget, depth + 1),
                .index = lig.index,
            } },
            .list_head_get => |lhg| .{ .list_head_get = .{
                .list = try self.cloneExprBudgeted(lhg.list, budget, depth + 1),
            } },
            .list_tail_get => |ltg| .{ .list_tail_get = .{
                .list = try self.cloneExprBudgeted(ltg.list, budget, depth + 1),
                .start_index = ltg.start_index,
            } },
            .map_value_get => |mvg| .{ .map_value_get = .{
                .map = try self.cloneExprBudgeted(mvg.map, budget, depth + 1),
                .key = try self.cloneExprBudgeted(mvg.key, budget, depth + 1),
            } },
            .branch => |br| .{ .branch = .{
                .condition = try self.cloneExprBudgeted(br.condition, budget, depth + 1),
                .then_block = try self.cloneBlockBudgeted(br.then_block, budget, depth + 1),
                .else_block = if (br.else_block) |eb| try self.cloneBlockBudgeted(eb, budget, depth + 1) else null,
            } },
            .case => |cd| blk: {
                var new_arms = try self.allocator.alloc(hir.CaseArm, cd.arms.len);
                for (cd.arms, 0..) |arm, i| {
                    new_arms[i] = .{
                        .pattern = arm.pattern,
                        .guard = if (arm.guard) |g| try self.cloneExprBudgeted(g, budget, depth + 1) else null,
                        .body = try self.cloneBlockBudgeted(arm.body, budget, depth + 1),
                        .bindings = arm.bindings,
                    };
                }
                break :blk .{ .case = .{ .scrutinee = try self.cloneExprBudgeted(cd.scrutinee, budget, depth + 1), .arms = new_arms } };
            },
            .block => |b| .{ .block = (try self.cloneBlockBudgeted(&b, budget, depth + 1)).* },
            .panic => |e| .{ .panic = try self.cloneExprBudgeted(e, budget, depth + 1) },
            .unwrap => |e| .{ .unwrap = try self.cloneExprBudgeted(e, budget, depth + 1) },
            .ret_raise => |rr| .{ .ret_raise = .{ .stash_call = try self.cloneExprBudgeted(rr.stash_call, budget, depth + 1) } },
            .union_init => |ui| .{ .union_init = .{
                .union_type_id = if (self.current_subs) |subs|
                    try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, ui.union_type_id))
                else
                    try self.applyActiveProtocolParamTypes(ui.union_type_id),
                .variant_name = ui.variant_name,
                .value = try self.cloneExprBudgeted(ui.value, budget, depth + 1),
            } },
            .try_rescue => |tr| blk: {
                var new_arms = try self.allocator.alloc(hir.CaseArm, tr.arms.len);
                for (tr.arms, 0..) |arm, i| {
                    new_arms[i] = .{
                        .pattern = arm.pattern,
                        .guard = if (arm.guard) |g| try self.cloneExprBudgeted(g, budget, depth + 1) else null,
                        .body = try self.cloneBlockBudgeted(arm.body, budget, depth + 1),
                        .bindings = arm.bindings,
                    };
                }
                // Clone the per-arm rescue discriminators (Phase 3.a, #185).
                // The concrete target type names are nominal `pub error`
                // names that survive monomorphization unchanged, so a
                // shallow per-entry copy of the discriminator slice suffices
                // — only the owned name byte-slices are duplicated so the
                // clone never aliases the source program's storage.
                const new_discriminators = try self.allocator.alloc(hir.RescueDiscriminator, tr.arm_discriminators.len);
                for (tr.arm_discriminators, 0..) |disc, i| {
                    new_discriminators[i] = switch (disc) {
                        .catch_all => .catch_all,
                        .concrete => |c| .{ .concrete = .{
                            .target_type_name = try self.allocator.dupe(u8, c.target_type_name),
                            .needs_unbox = c.needs_unbox,
                        } },
                    };
                }
                break :blk .{ .try_rescue = .{
                    .body = try self.cloneBlockBudgeted(tr.body, budget, depth + 1),
                    .arms = new_arms,
                    .error_local = tr.error_local,
                    .raise_occurred_call = try self.cloneExprBudgeted(tr.raise_occurred_call, budget, depth + 1),
                    .take_raise_call = try self.cloneExprBudgeted(tr.take_raise_call, budget, depth + 1),
                    .after_block = if (tr.after_block) |cleanup| try self.cloneBlockBudgeted(cleanup, budget, depth + 1) else null,
                    .result_type_id = if (self.current_subs) |subs|
                        try self.applyActiveProtocolParamTypes(try subs.applyToType(self.store, tr.result_type_id))
                    else
                        try self.applyActiveProtocolParamTypes(tr.result_type_id),
                    .arm_discriminators = new_discriminators,
                } };
            },
            .error_pipe => |ep| blk: {
                var new_steps = try self.allocator.alloc(hir.ErrorPipeStep, ep.steps.len);
                for (ep.steps, 0..) |step, i| {
                    new_steps[i] = .{
                        .expr = try self.cloneExprBudgeted(step.expr, budget, depth + 1),
                        .is_dispatched = step.is_dispatched,
                    };
                }
                break :blk .{ .error_pipe = .{
                    .steps = new_steps,
                    .handler = try self.cloneExprBudgeted(ep.handler, budget, depth + 1),
                    .err_local = ep.err_local,
                } };
            },
            .match => |m| .{ .match = .{
                .scrutinee = try self.cloneExprBudgeted(m.scrutinee, budget, depth + 1),
                .decision = try self.cloneDecisionBudgeted(m.decision, budget, depth + 1),
            } },
            .closure_create => |cc| blk: {
                if (cc.captures.len == 0) break :blk kind;
                var new_captures = try self.allocator.alloc(hir.CaptureValue, cc.captures.len);
                for (cc.captures, 0..) |cap, i| {
                    new_captures[i] = .{
                        .expr = try self.cloneExprBudgeted(cap.expr, budget, depth + 1),
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

    fn cloneDecision(self: *MonomorphContext, decision: *const hir.Decision) MonomorphWalkError!*const hir.Decision {
        var budget = HirWalkBudget{};
        return self.cloneDecisionBudgeted(decision, &budget, 0);
    }

    fn cloneDecisionBudgeted(
        self: *MonomorphContext,
        decision: *const hir.Decision,
        budget: *HirWalkBudget,
        depth: u32,
    ) MonomorphWalkError!*const hir.Decision {
        try budget.enter(depth);
        const result = try self.allocator.create(hir.Decision);
        result.* = switch (decision.*) {
            .success => |leaf| .{ .success = leaf },
            .failure => .failure,
            .guard => |g| .{ .guard = .{
                .condition = try self.cloneExprBudgeted(g.condition, budget, depth + 1),
                .success = try self.cloneDecisionBudgeted(g.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(g.failure, budget, depth + 1),
            } },
            .switch_tag => |s| blk: {
                var new_cases = try self.allocator.alloc(hir.SwitchCase, s.cases.len);
                for (s.cases, 0..) |case, i| {
                    new_cases[i] = .{
                        .tag = case.tag,
                        .bindings = case.bindings,
                        .next = try self.cloneDecisionBudgeted(case.next, budget, depth + 1),
                    };
                }
                break :blk .{ .switch_tag = .{
                    .scrutinee = try self.cloneExprBudgeted(s.scrutinee, budget, depth + 1),
                    .cases = new_cases,
                    .default = try self.cloneDecisionBudgeted(s.default, budget, depth + 1),
                } };
            },
            .switch_literal => |s| blk: {
                var new_cases = try self.allocator.alloc(hir.LiteralCase, s.cases.len);
                for (s.cases, 0..) |case, i| {
                    new_cases[i] = .{
                        .value = case.value,
                        .next = try self.cloneDecisionBudgeted(case.next, budget, depth + 1),
                    };
                }
                break :blk .{ .switch_literal = .{
                    .scrutinee = try self.cloneExprBudgeted(s.scrutinee, budget, depth + 1),
                    .cases = new_cases,
                    .default = try self.cloneDecisionBudgeted(s.default, budget, depth + 1),
                } };
            },
            .check_tuple => |ct| .{ .check_tuple = .{
                .scrutinee = try self.cloneExprBudgeted(ct.scrutinee, budget, depth + 1),
                .expected_arity = ct.expected_arity,
                .element_scrutinee_ids = ct.element_scrutinee_ids,
                .success = try self.cloneDecisionBudgeted(ct.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(ct.failure, budget, depth + 1),
            } },
            .check_list => |cl| .{ .check_list = .{
                .scrutinee = try self.cloneExprBudgeted(cl.scrutinee, budget, depth + 1),
                .expected_length = cl.expected_length,
                .element_scrutinee_ids = cl.element_scrutinee_ids,
                .success = try self.cloneDecisionBudgeted(cl.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(cl.failure, budget, depth + 1),
            } },
            .check_list_cons => |clc| .{ .check_list_cons = .{
                .scrutinee = try self.cloneExprBudgeted(clc.scrutinee, budget, depth + 1),
                .head_count = clc.head_count,
                .head_scrutinee_ids = clc.head_scrutinee_ids,
                .tail_scrutinee_id = clc.tail_scrutinee_id,
                .success = try self.cloneDecisionBudgeted(clc.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(clc.failure, budget, depth + 1),
            } },
            .check_binary => |cb| .{ .check_binary = .{
                .scrutinee = try self.cloneExprBudgeted(cb.scrutinee, budget, depth + 1),
                .min_byte_size = cb.min_byte_size,
                .segments = cb.segments,
                .success = try self.cloneDecisionBudgeted(cb.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(cb.failure, budget, depth + 1),
            } },
            .bind => |b| .{ .bind = .{
                .name = b.name,
                .local_index = b.local_index,
                .source = try self.cloneExprBudgeted(b.source, budget, depth + 1),
                .next = try self.cloneDecisionBudgeted(b.next, budget, depth + 1),
            } },
            .extract_struct => |es| .{ .extract_struct = .{
                .scrutinee = try self.cloneExprBudgeted(es.scrutinee, budget, depth + 1),
                .fields = es.fields,
                .success = try self.cloneDecisionBudgeted(es.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(es.failure, budget, depth + 1),
            } },
            .extract_map => |em| .{ .extract_map = .{
                .scrutinee = try self.cloneExprBudgeted(em.scrutinee, budget, depth + 1),
                .keys = em.keys,
                .success = try self.cloneDecisionBudgeted(em.success, budget, depth + 1),
                .failure = try self.cloneDecisionBudgeted(em.failure, budget, depth + 1),
            } },
            .switch_variant => |sw| blk: {
                var new_cases = try self.allocator.alloc(hir.SwitchVariantCase, sw.cases.len);
                for (sw.cases, 0..) |case, i| {
                    new_cases[i] = .{
                        .variant_name = case.variant_name,
                        .has_payload = case.has_payload,
                        .payload_scrutinee_id = case.payload_scrutinee_id,
                        .next = try self.cloneDecisionBudgeted(case.next, budget, depth + 1),
                    };
                }
                break :blk .{ .switch_variant = .{
                    .scrutinee = try self.cloneExprBudgeted(sw.scrutinee, budget, depth + 1),
                    .receiver_name = sw.receiver_name,
                    .cases = new_cases,
                    .default = try self.cloneDecisionBudgeted(sw.default, budget, depth + 1),
                } };
            },
        };
        return result;
    }

    // -- Rewriting call sites -------------------------------------------------

    fn rewriteBlock(self: *MonomorphContext, block: *const hir.Block) error{OutOfMemory}!void {
        var budget = HirWalkBudget{};
        self.rewriteBlockBudgeted(block, &budget, 0) catch |err| {
            try self.appendHirBudgetError(blockSpan(block), "call-site rewrite", err);
        };
    }

    fn rewriteBlockBudgeted(
        self: *MonomorphContext,
        block: *const hir.Block,
        budget: *HirWalkBudget,
        depth: u32,
    ) HirWalkError!void {
        try budget.enter(depth);
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| try self.rewriteExprBudgeted(e, budget, depth + 1),
                .local_set => |ls| try self.rewriteExprBudgeted(ls.value, budget, depth + 1),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.rewriteBlockBudgeted(clause.body, budget, depth + 1);
                    }
                },
            }
        }
    }

    fn rewriteExpr(self: *MonomorphContext, expr: *const hir.Expr) error{OutOfMemory}!void {
        var budget = HirWalkBudget{};
        self.rewriteExprBudgeted(expr, &budget, 0) catch |err| {
            try self.appendHirBudgetError(expr.span, "HIR expression rewrite", err);
        };
    }

    fn rewriteExprBudgeted(
        self: *MonomorphContext,
        expr: *const hir.Expr,
        budget: *HirWalkBudget,
        depth: u32,
    ) HirWalkError!void {
        try budget.enter(depth);
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
                                .named => |nc| {
                                    // Rewrite named cross-struct call to direct call
                                    c.target = .{ .direct = .{
                                        .function_group_id = new_id,
                                        .clause_index = nc.clause_index,
                                    } };
                                },
                                else => {},
                            }
                            const mutable_args: []hir.CallArg = @constCast(c.args);
                            try self.applyTargetArgModes(c.target, mutable_args);
                        },
                        else => {},
                    }
                }

                // Recurse into args
                for (call.args) |arg| try self.rewriteExprBudgeted(arg.expr, budget, depth + 1);

                // Recurse into the callee of an implicit value-call
                // (`expr(args)` — a `.closure` target). The callee expression
                // may itself be a generic call that the scan recorded for
                // rewriting (e.g. the inline `List.get(filtered, 0)(v)`, whose
                // callee `List.get(filtered, 0)` specializes for the boxed
                // element). Without applying that rewrite here, the callee keeps
                // its generic `.named` target and the backend emits a reference
                // to the un-produced generic specialization. Mirrors the
                // callee-scan in `scanExpr`.
                if (call.target == .closure) {
                    try self.rewriteExprBudgeted(call.target.closure, budget, depth + 1);
                }
            },
            .binary => |b| {
                try self.rewriteExprBudgeted(b.lhs, budget, depth + 1);
                try self.rewriteExprBudgeted(b.rhs, budget, depth + 1);
            },
            .unary => |u| try self.rewriteExprBudgeted(u.operand, budget, depth + 1),
            .tuple_init => |elems| {
                for (elems) |e| try self.rewriteExprBudgeted(e, budget, depth + 1);
            },
            .list_init => |elems| {
                for (elems) |e| try self.rewriteExprBudgeted(e, budget, depth + 1);
            },
            .list_cons => |lc| {
                try self.rewriteExprBudgeted(lc.head, budget, depth + 1);
                try self.rewriteExprBudgeted(lc.tail, budget, depth + 1);
            },
            .branch => |br| {
                try self.rewriteExprBudgeted(br.condition, budget, depth + 1);
                try self.rewriteBlockBudgeted(br.then_block, budget, depth + 1);
                if (br.else_block) |eb| try self.rewriteBlockBudgeted(eb, budget, depth + 1);
            },
            .map_init => |entries| {
                for (entries) |entry| {
                    try self.rewriteExprBudgeted(entry.key, budget, depth + 1);
                    try self.rewriteExprBudgeted(entry.value, budget, depth + 1);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.rewriteExprBudgeted(field.value, budget, depth + 1);
            },
            .field_get => |fg| try self.rewriteExprBudgeted(fg.object, budget, depth + 1),
            .block => |b| try self.rewriteBlockBudgeted(&b, budget, depth + 1),
            .panic => |e| try self.rewriteExprBudgeted(e, budget, depth + 1),
            .unwrap => |e| try self.rewriteExprBudgeted(e, budget, depth + 1),
            .union_init => |ui| try self.rewriteExprBudgeted(ui.value, budget, depth + 1),
            .error_pipe => |ep| {
                for (ep.steps) |step| try self.rewriteExprBudgeted(step.expr, budget, depth + 1);
                try self.rewriteExprBudgeted(ep.handler, budget, depth + 1);
            },
            .case => |cd| {
                try self.rewriteExprBudgeted(cd.scrutinee, budget, depth + 1);
                for (cd.arms) |arm| {
                    if (arm.guard) |g| try self.rewriteExprBudgeted(g, budget, depth + 1);
                    try self.rewriteBlockBudgeted(arm.body, budget, depth + 1);
                }
            },
            .match => |m| try self.rewriteExprBudgeted(m.scrutinee, budget, depth + 1),
            .closure_create => |cc| {
                for (cc.captures) |cap| try self.rewriteExprBudgeted(cap.expr, budget, depth + 1);
            },
            // Destructuring projections and the propagating-raise/`?` lowerings
            // each wrap a sub-expression that may itself be a generic call
            // (e.g. `(Enum.map(list, &f/1))[0]`, or `Worker.run()?` whose
            // `ret_raise` stash call forwards a specialized result). Mirror the
            // `scanExpr` traversal so their call sites are rewired too.
            .tuple_index_get => |tig| try self.rewriteExprBudgeted(tig.object, budget, depth + 1),
            .list_index_get => |lig| try self.rewriteExprBudgeted(lig.list, budget, depth + 1),
            .list_head_get => |lhg| try self.rewriteExprBudgeted(lhg.list, budget, depth + 1),
            .list_tail_get => |ltg| try self.rewriteExprBudgeted(ltg.list, budget, depth + 1),
            .map_value_get => |mvg| {
                try self.rewriteExprBudgeted(mvg.map, budget, depth + 1);
                try self.rewriteExprBudgeted(mvg.key, budget, depth + 1);
            },
            .ret_raise => |rr| try self.rewriteExprBudgeted(rr.stash_call, budget, depth + 1),
            .try_rescue => |tr| {
                // Mirror the scan-phase traversal (`scanBlock` over the same
                // sub-expressions): a generic call inside a `try` body, a
                // rescue arm guard/body, or the `after` cleanup must have its
                // call site rewired to the monomorphized specialization just
                // like a call anywhere else. Without this arm, a combinator
                // call such as `Enum.map(list, &raising/1)` written inside a
                // `try { … } rescue { … }` keeps its generic `call_named`
                // target and the ZIR backend then references an unmangled
                // symbol (`Enum__map__2`) that was never emitted — the
                // specialization exists under its mangled name but the call
                // site never points at it. This is the rewrite-path analogue
                // of the `.try_rescue` arm in `scanExpr`/`cloneExpr`.
                try self.rewriteBlockBudgeted(tr.body, budget, depth + 1);
                for (tr.arms) |arm| {
                    if (arm.guard) |g| try self.rewriteExprBudgeted(g, budget, depth + 1);
                    try self.rewriteBlockBudgeted(arm.body, budget, depth + 1);
                }
                try self.rewriteExprBudgeted(tr.raise_occurred_call, budget, depth + 1);
                try self.rewriteExprBudgeted(tr.take_raise_call, budget, depth + 1);
                if (tr.after_block) |cleanup| try self.rewriteBlockBudgeted(cleanup, budget, depth + 1);
            },
            else => {},
        }
    }

    // ---------------------------------------------------------------------
    // P3-J2 per-spawn manager-monomorphization — spawn-reachable analysis.
    //
    // `collectSubgraphCallees` gathers the direct/named/dispatch callee group
    // ids of one function group and flags whether any indirect (`.closure`) or
    // unresolvable call was seen (the hot/cold boundary). The traversal mirrors
    // `rewriteExprBudgeted`/`rewriteBlockBudgeted` so it covers the same
    // positions the model clone reproduces. SOUNDNESS: an under-approximation
    // is safe — a callee not discovered simply remains a cold (manifest-
    // emission, runtime-dispatched) function instead of a hot model
    // specialization; it can never produce wrong codegen on a path we own.
    // ---------------------------------------------------------------------

    fn collectSubgraphCallees(
        self: *MonomorphContext,
        group: *const hir.FunctionGroup,
        callees: *std.AutoHashMap(u32, void),
        saw_cold_edge: *bool,
    ) HirWalkError!void {
        var budget = HirWalkBudget{};
        for (group.clauses) |clause| {
            try self.collectCalleesInBlock(clause.body, callees, saw_cold_edge, &budget, 0);
            if (clause.refinement) |refinement| {
                try self.collectCalleesInExpr(refinement, callees, saw_cold_edge, &budget, 0);
            }
            for (clause.params) |param| {
                if (param.default) |default_expr| {
                    try self.collectCalleesInExpr(default_expr, callees, saw_cold_edge, &budget, 0);
                }
            }
        }
    }

    fn collectCalleesInBlock(
        self: *MonomorphContext,
        block: *const hir.Block,
        callees: *std.AutoHashMap(u32, void),
        saw_cold_edge: *bool,
        budget: *HirWalkBudget,
        depth: u32,
    ) HirWalkError!void {
        try budget.enter(depth);
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |e| try self.collectCalleesInExpr(e, callees, saw_cold_edge, budget, depth + 1),
                .local_set => |ls| try self.collectCalleesInExpr(ls.value, callees, saw_cold_edge, budget, depth + 1),
                .function_group => |fg| {
                    // Nested local functions are SHARED by the clone (see
                    // `cloneStmtBudgeted`: "local fns: share, not specialized"),
                    // so they are cold for the model axis — but calls FROM their
                    // bodies to top-level subgraph functions are still hot edges
                    // worth discovering.
                    for (fg.clauses) |clause| {
                        try self.collectCalleesInBlock(clause.body, callees, saw_cold_edge, budget, depth + 1);
                    }
                },
            }
        }
    }

    fn collectCalleesInExpr(
        self: *MonomorphContext,
        expr: *const hir.Expr,
        callees: *std.AutoHashMap(u32, void),
        saw_cold_edge: *bool,
        budget: *HirWalkBudget,
        depth: u32,
    ) HirWalkError!void {
        try budget.enter(depth);
        switch (expr.kind) {
            .call => |call| {
                switch (call.target) {
                    .direct => |dc| try callees.put(dc.function_group_id, {}),
                    .dispatch => |dp| try callees.put(dp.function_group_id, {}),
                    .named => |nc| {
                        if (try self.resolveNamedCall(nc, @intCast(call.args.len))) |group_id| {
                            try callees.put(group_id, {});
                        } else {
                            // A named call that does not resolve to a program
                            // group (stdlib/runtime intrinsic, etc.) is a cold
                            // edge — its callee is not model-specialized.
                            saw_cold_edge.* = true;
                        }
                    },
                    // Indirect Callable existential — the defining cold boundary
                    // of §2.3; never followed for monomorphization.
                    .closure => saw_cold_edge.* = true,
                    // Compiler builtin — no user function group.
                    .builtin => {},
                }
                for (call.args) |arg| try self.collectCalleesInExpr(arg.expr, callees, saw_cold_edge, budget, depth + 1);
                if (call.target == .closure) {
                    try self.collectCalleesInExpr(call.target.closure, callees, saw_cold_edge, budget, depth + 1);
                }
            },
            .binary => |b| {
                try self.collectCalleesInExpr(b.lhs, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(b.rhs, callees, saw_cold_edge, budget, depth + 1);
            },
            .unary => |u| try self.collectCalleesInExpr(u.operand, callees, saw_cold_edge, budget, depth + 1),
            .tuple_init => |elems| for (elems) |e| try self.collectCalleesInExpr(e, callees, saw_cold_edge, budget, depth + 1),
            .list_init => |elems| for (elems) |e| try self.collectCalleesInExpr(e, callees, saw_cold_edge, budget, depth + 1),
            .list_cons => |lc| {
                try self.collectCalleesInExpr(lc.head, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(lc.tail, callees, saw_cold_edge, budget, depth + 1);
            },
            .map_init => |entries| for (entries) |entry| {
                try self.collectCalleesInExpr(entry.key, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(entry.value, callees, saw_cold_edge, budget, depth + 1);
            },
            .struct_init => |si| for (si.fields) |field| try self.collectCalleesInExpr(field.value, callees, saw_cold_edge, budget, depth + 1),
            .field_get => |fg| try self.collectCalleesInExpr(fg.object, callees, saw_cold_edge, budget, depth + 1),
            .tuple_index_get => |tig| try self.collectCalleesInExpr(tig.object, callees, saw_cold_edge, budget, depth + 1),
            .list_index_get => |lig| try self.collectCalleesInExpr(lig.list, callees, saw_cold_edge, budget, depth + 1),
            .list_head_get => |lhg| try self.collectCalleesInExpr(lhg.list, callees, saw_cold_edge, budget, depth + 1),
            .list_tail_get => |ltg| try self.collectCalleesInExpr(ltg.list, callees, saw_cold_edge, budget, depth + 1),
            .map_value_get => |mvg| {
                try self.collectCalleesInExpr(mvg.map, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(mvg.key, callees, saw_cold_edge, budget, depth + 1);
            },
            .branch => |br| {
                try self.collectCalleesInExpr(br.condition, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInBlock(br.then_block, callees, saw_cold_edge, budget, depth + 1);
                if (br.else_block) |eb| try self.collectCalleesInBlock(eb, callees, saw_cold_edge, budget, depth + 1);
            },
            .case => |cd| {
                try self.collectCalleesInExpr(cd.scrutinee, callees, saw_cold_edge, budget, depth + 1);
                for (cd.arms) |arm| {
                    if (arm.guard) |g| try self.collectCalleesInExpr(g, callees, saw_cold_edge, budget, depth + 1);
                    try self.collectCalleesInBlock(arm.body, callees, saw_cold_edge, budget, depth + 1);
                }
            },
            .match => |m| try self.collectCalleesInExpr(m.scrutinee, callees, saw_cold_edge, budget, depth + 1),
            .block => |b| try self.collectCalleesInBlock(&b, callees, saw_cold_edge, budget, depth + 1),
            .panic => |e| try self.collectCalleesInExpr(e, callees, saw_cold_edge, budget, depth + 1),
            .unwrap => |e| try self.collectCalleesInExpr(e, callees, saw_cold_edge, budget, depth + 1),
            .union_init => |ui| try self.collectCalleesInExpr(ui.value, callees, saw_cold_edge, budget, depth + 1),
            .error_pipe => |ep| {
                for (ep.steps) |step| try self.collectCalleesInExpr(step.expr, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(ep.handler, callees, saw_cold_edge, budget, depth + 1);
            },
            .closure_create => |cc| {
                // The closure BODY is a shared nested group (cold); its captured
                // argument expressions can still contain hot calls.
                for (cc.captures) |cap| try self.collectCalleesInExpr(cap.expr, callees, saw_cold_edge, budget, depth + 1);
            },
            .ret_raise => |rr| try self.collectCalleesInExpr(rr.stash_call, callees, saw_cold_edge, budget, depth + 1),
            .try_rescue => |tr| {
                try self.collectCalleesInBlock(tr.body, callees, saw_cold_edge, budget, depth + 1);
                for (tr.arms) |arm| {
                    if (arm.guard) |g| try self.collectCalleesInExpr(g, callees, saw_cold_edge, budget, depth + 1);
                    try self.collectCalleesInBlock(arm.body, callees, saw_cold_edge, budget, depth + 1);
                }
                try self.collectCalleesInExpr(tr.raise_occurred_call, callees, saw_cold_edge, budget, depth + 1);
                try self.collectCalleesInExpr(tr.take_raise_call, callees, saw_cold_edge, budget, depth + 1);
                if (tr.after_block) |cleanup| try self.collectCalleesInBlock(cleanup, callees, saw_cold_edge, budget, depth + 1);
            },
            else => {},
        }
    }
};

// =============================================================================
// P3-J2 — per-spawn manager-monomorphization axis.
//
// `zap-concurrency-research.md` §2.3 / plan §5 Phase 3 item 3.2. Per-spawn
// managers mean different processes run different reclamation MODELS. Naively
// that forces per-allocation dynamic dispatch (the E10 +13.8% hot-path tax —
// unacceptable). The resolved answer is the HYBRID: specialize the spawn-
// reachable call graph per reclamation MODEL (≤4: REFCOUNTED / BULK_OR_NEVER /
// INDIVIDUAL_NO_REFCOUNT / TRACED) so each specialization's memory-op codegen
// is comptime-shaped to that model (cost is CODE SIZE, folded by linker ICF —
// not dispatch); cold closure/existential paths fall through to the process
// manager's per-process context at runtime.
//
// This axis is a SEPARATE pass run AFTER `monomorphize` (the type-argument
// axis), so it clones fully-concrete functions and leaves the type-arg machine
// untouched. The specialization KEY is the reclamation MODEL, never the
// manager identity (Arena/NoOp/Leak all share BULK_OR_NEVER → share one
// specialization), so the worst case is ≤4 specializations of the spawn-
// reachable subgraph, not one per manager.
//
// DECISION GATE 0 (comptime-resolved manager at the spawn site — the ratified
// language rule) is enforced STRUCTURALLY: `SpawnManagerSpec.model` is an
// already-resolved `ReclamationModel` enum, so a spawn site whose `.manager`
// is not comptime-resolvable cannot appear in a plan. J3 builds the plan from
// the `spawn(f, .{ .manager = X })` surface (resolving X → model at the site,
// diagnosing a non-comptime X there); J2 consumes the plan and returns the
// entry→specialization mapping J3 uses to rewire the spawn sites.
// =============================================================================

/// One comptime-resolved spawn site's manager binding: the entry function
/// group and the reclamation model the spawned process runs under.
pub const SpawnManagerSpec = struct {
    /// The spawn entry function's HIR group id (the target of `spawn(f, …)`).
    entry_group_id: u32,
    /// The reclamation model the process spawned here runs under. Comptime-
    /// resolved — this is where Decision Gate 0 is discharged (an enum, not a
    /// runtime value).
    model: hir.ReclamationModel,
};

/// The plan handed to `specializeSpawnManagers`: the manifest (default) model
/// plus the per-spawn-site specs. An empty `specs` slice makes the whole pass
/// a no-op (the zero-cost gate: a non-spawning binary — or a binary that only
/// spawns under the manifest model — carries exactly one specialization,
/// identical to today).
pub const SpawnManagerPlan = struct {
    /// The manifest manager's reclamation model — the model ordinary, untagged
    /// functions already emit for. A spec whose model equals this needs no
    /// clone (the entry already emits correctly); its entry-specialization is
    /// recorded as identity.
    manifest_model: hir.ReclamationModel,
    specs: []const SpawnManagerSpec = &.{},
};

/// The resolved specialization for one `(entry, model)` pair. `specialized_group_id`
/// equals `entry_group_id` for manifest-model spawns (no clone needed) and the
/// fresh clone id otherwise. J3 rewires each spawn site's entry reference to
/// `specialized_group_id`.
pub const EntrySpecialization = struct {
    entry_group_id: u32,
    model: hir.ReclamationModel,
    specialized_group_id: u32,
};

pub const SpawnManagerResult = struct {
    /// The augmented program with the model specializations added.
    program: hir.Program,
    /// Total model-specialized clones created across all non-manifest models.
    specialization_count: u32,
    /// Distinct non-manifest reclamation models specialized (0..3; the total
    /// model count including the manifest is `model_count + 1`, capped at 4).
    model_count: u32,
    /// Per `(entry, model)` → specialized entry group id, for spawn-site rewiring.
    entry_specializations: []const EntrySpecialization = &.{},
    /// True when any spawn-reachable subgraph crossed a cold (indirect Callable
    /// / unresolved) edge — the paths that fall through to per-process manager
    /// dispatch at runtime rather than being monomorphized (§2.3).
    saw_cold_edge: bool = false,
    errors: []const MonomorphError = &.{},
    /// The ICF red flags (§2.3 requirement 4): one diagnostic per model
    /// specialization that is NOT structurally identical to its source modulo
    /// the ICF-tolerated differences. By construction this is always empty (the
    /// pass produces faithful identity clones); a non-empty slice means a
    /// model-dependent HIR transform leaked into a specialization body — a bug
    /// that would also make the specializations un-foldable by linker ICF.
    foldability_red_flags: []const MonomorphError = &.{},
};

/// Short, symbol-safe suffix for a reclamation model, used to mangle a model
/// specialization's name so the linker sees distinct symbols (which ICF then
/// folds when they differ only in header-emission ops).
fn modelSuffix(model: hir.ReclamationModel) []const u8 {
    return switch (model) {
        .refcounted => "refcounted",
        .bulk_or_never => "bulk_or_never",
        .individual_no_refcount => "individual_no_refcount",
        .traced => "traced",
    };
}

/// The struct index that defines `group_id`, or null when it is a top-level
/// function (or not found). A model clone is placed in the same container as
/// its original so cross-struct direct-call resolution matches the original's.
fn findGroupOriginContainer(program: *const hir.Program, group_id: u32) ?usize {
    for (program.structs, 0..) |mod, idx| {
        for (mod.functions) |g| {
            if (g.id == group_id) return idx;
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// ICF red-flag verifier (§2.3 requirement 4).
//
// The model specializations are IDENTITY clones of one source function: the
// only per-model differences are (a) the `reclamation_model` tag, (b) the
// model-suffixed name, and (c) call targets redirected to same-model clones.
// After codegen they therefore differ ONLY in header-emission (retain/release/
// free) ops — exactly what linker ICF folds. The research's early kill signal
// is "ICF cannot fold two model specializations of the same function → they
// differ in more than header ops → a semantic leak." Since the linker's ICF is
// downstream (and, on Darwin, the self-hosted Mach-O linker has none yet), the
// robust, target-independent form of that check is a COMPILE-TIME structural
// invariant: every model specialization must be structurally identical to its
// source modulo the three tolerated differences. `modelCloneStructurallyFoldable`
// is that check; a `false` result is the verifier red flag — it means a
// per-model HIR transform crept in where none should exist. By construction the
// pass never produces such a clone, so this is a guard that fires only on a
// future regression (a model-dependent body transform), caught at compile time
// rather than as a mysterious code-size blow-up when ICF fails to fold.
// -----------------------------------------------------------------------------

/// True when `clone` is structurally identical to `source` modulo the three
/// ICF-tolerated differences (reclamation model tag, name, and redirected
/// call-target ids). A `false` result is the ICF red flag. Coverage mirrors the
/// clone/collector traversal; call targets are compared by VARIANT only (the
/// redirected id is expected to differ), so a redirected clone compares equal
/// to its source, while a body that gained/lost a statement, changed an
/// operator, or changed control-flow shape does not.
pub fn modelCloneStructurallyFoldable(source: *const hir.FunctionGroup, clone: *const hir.FunctionGroup) bool {
    if (source.arity != clone.arity) return false;
    if (source.clauses.len != clone.clauses.len) return false;
    for (source.clauses, clone.clauses) |source_clause, clone_clause| {
        if (source_clause.params.len != clone_clause.params.len) return false;
        if ((source_clause.refinement == null) != (clone_clause.refinement == null)) return false;
        if (source_clause.refinement) |source_refinement| {
            if (!foldableExpr(source_refinement, clone_clause.refinement.?)) return false;
        }
        if (!foldableBlock(source_clause.body, clone_clause.body)) return false;
    }
    return true;
}

fn foldableBlock(a: *const hir.Block, b: *const hir.Block) bool {
    if (a.stmts.len != b.stmts.len) return false;
    for (a.stmts, b.stmts) |sa, sb| {
        if (@as(std.meta.Tag(hir.Stmt), sa) != @as(std.meta.Tag(hir.Stmt), sb)) return false;
        switch (sa) {
            .expr => |ea| if (!foldableExpr(ea, sb.expr)) return false,
            .local_set => |la| if (!foldableExpr(la.value, sb.local_set.value)) return false,
            .function_group => |ga| {
                const gb = sb.function_group;
                if (ga.clauses.len != gb.clauses.len) return false;
                for (ga.clauses, gb.clauses) |ca, cb| {
                    if (!foldableBlock(ca.body, cb.body)) return false;
                }
            },
        }
    }
    return true;
}

fn foldableExpr(a: *const hir.Expr, b: *const hir.Expr) bool {
    if (@as(std.meta.Tag(hir.ExprKind), a.kind) != @as(std.meta.Tag(hir.ExprKind), b.kind)) return false;
    return switch (a.kind) {
        .call => |ca| blk: {
            const cb = b.kind.call;
            // Call targets are compared by variant only: a redirected clone
            // legitimately points at a different (same-model) group id. The
            // model redirect ALSO rewrites a RESOLVABLE `.named` call into a
            // `.direct` call on the same-model clone (see
            // `redirectCallTargetForModel`'s `.named` arm), so a source `.named`
            // paired with a clone `.direct` is exactly that intended, ICF-neutral
            // redirect — both lower to a direct call to the resolved target — not
            // a semantic leak. Every OTHER variant mismatch (e.g. `.direct` ↔
            // `.closure`, a hot→cold boundary change) is a real structural
            // divergence and correctly flags.
            const source_target_tag = @as(std.meta.Tag(hir.CallTarget), ca.target);
            const clone_target_tag = @as(std.meta.Tag(hir.CallTarget), cb.target);
            if (source_target_tag != clone_target_tag) {
                const named_to_direct_redirect = source_target_tag == .named and clone_target_tag == .direct;
                if (!named_to_direct_redirect) break :blk false;
            }
            if (ca.args.len != cb.args.len) break :blk false;
            for (ca.args, cb.args) |arg_a, arg_b| {
                if (!foldableExpr(arg_a.expr, arg_b.expr)) break :blk false;
            }
            if (ca.target == .closure) {
                if (!foldableExpr(ca.target.closure, cb.target.closure)) break :blk false;
            }
            break :blk true;
        },
        .binary => |ba| ba.op == b.kind.binary.op and
            foldableExpr(ba.lhs, b.kind.binary.lhs) and
            foldableExpr(ba.rhs, b.kind.binary.rhs),
        .unary => |ua| ua.op == b.kind.unary.op and foldableExpr(ua.operand, b.kind.unary.operand),
        .tuple_init => |ea| blk: {
            const eb = b.kind.tuple_init;
            if (ea.len != eb.len) break :blk false;
            for (ea, eb) |x, y| if (!foldableExpr(x, y)) break :blk false;
            break :blk true;
        },
        .list_init => |ea| blk: {
            const eb = b.kind.list_init;
            if (ea.len != eb.len) break :blk false;
            for (ea, eb) |x, y| if (!foldableExpr(x, y)) break :blk false;
            break :blk true;
        },
        .list_cons => |la| foldableExpr(la.head, b.kind.list_cons.head) and
            foldableExpr(la.tail, b.kind.list_cons.tail),
        .field_get => |fa| foldableExpr(fa.object, b.kind.field_get.object),
        .branch => |bra| blk: {
            const brb = b.kind.branch;
            if (!foldableExpr(bra.condition, brb.condition)) break :blk false;
            if (!foldableBlock(bra.then_block, brb.then_block)) break :blk false;
            if ((bra.else_block == null) != (brb.else_block == null)) break :blk false;
            if (bra.else_block) |eb| break :blk foldableBlock(eb, brb.else_block.?);
            break :blk true;
        },
        .case => |cda| blk: {
            const cdb = b.kind.case;
            if (!foldableExpr(cda.scrutinee, cdb.scrutinee)) break :blk false;
            if (cda.arms.len != cdb.arms.len) break :blk false;
            for (cda.arms, cdb.arms) |arm_a, arm_b| {
                if (!foldableBlock(arm_a.body, arm_b.body)) break :blk false;
            }
            break :blk true;
        },
        .block => |blk_val| foldableBlock(&blk_val, &b.kind.block),
        .panic => |ea| foldableExpr(ea, b.kind.panic),
        .unwrap => |ea| foldableExpr(ea, b.kind.unwrap),
        .union_init => |ua| foldableExpr(ua.value, b.kind.union_init.value),
        // Leaves (literals, local/param/capture gets, never) and any node type
        // not structurally decomposed above: the tag match already established
        // structural equivalence for the identity-clone invariant.
        else => true,
    };
}

/// Run the per-spawn manager-monomorphization axis. See the section banner
/// above for the full design. Returns the augmented program plus the
/// entry→specialization mapping for spawn-site rewiring.
pub fn specializeSpawnManagers(
    allocator: Allocator,
    program: *const hir.Program,
    store: *TypeStore,
    next_group_id: *u32,
    interner: *ast.StringInterner,
    plan: SpawnManagerPlan,
) !SpawnManagerResult {
    // Zero-cost gate: no spawn model specs → the program is returned byte-for-
    // byte unchanged, so every downstream stage (HIR→IR→ZIR) is identical to a
    // pre-J2 build. This is the single-model / non-spawning no-op path.
    if (plan.specs.len == 0) {
        return .{ .program = program.*, .specialization_count = 0, .model_count = 0 };
    }

    var ctx = MonomorphContext{
        .allocator = allocator,
        .store = store,
        .next_group_id = next_group_id,
        .interner = interner,
        .program = program,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(allocator),
        .specializations = std.AutoHashMap(u64, u32).init(allocator),
        .specialization_counts = std.AutoHashMap(u32, u32).init(allocator),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(allocator),
        .local_types = std.AutoHashMap(u32, TypeId).init(allocator),
        .errors = .empty,
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.specialization_counts.deinit();
    defer ctx.new_groups.deinit(allocator);
    defer ctx.call_rewrites.deinit();
    defer ctx.local_types.deinit();

    var errors: std.ArrayListUnmanaged(MonomorphError) = .empty;
    errdefer errors.deinit(allocator);
    var entry_specializations: std.ArrayListUnmanaged(EntrySpecialization) = .empty;
    errdefer entry_specializations.deinit(allocator);
    // The clones to splice in, each tagged with its origin container.
    var clones: std.ArrayListUnmanaged(NewGroupEntry) = .empty;
    defer clones.deinit(allocator);
    // ICF red flags: model specializations that failed the structural-
    // foldability invariant (§2.3 requirement 4).
    var red_flags: std.ArrayListUnmanaged(MonomorphError) = .empty;
    errdefer red_flags.deinit(allocator);

    var saw_cold_edge = false;
    var model_count: u32 = 0;

    // The four Axis-A models are the complete key space, so the number of
    // distinct specializations is ≤4 by construction. Iterating the enum (not
    // the specs) also deduplicates managers that share a model.
    const all_models = [_]hir.ReclamationModel{
        .refcounted,
        .bulk_or_never,
        .individual_no_refcount,
        .traced,
    };

    for (all_models) |model| {
        // Manifest-model spawns need no clone: the entry already emits for the
        // manifest model. Record identity entry-specializations and move on.
        if (model == plan.manifest_model) {
            for (plan.specs) |spec| {
                if (spec.model != model) continue;
                if (findGroupOriginContainer(program, spec.entry_group_id) == null and
                    ctx.findFunctionGroupById(spec.entry_group_id) == null)
                {
                    try errors.append(allocator, .{
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "spawn manager plan references unknown entry function group id {d}",
                            .{spec.entry_group_id},
                        ),
                        .span = .{ .start = 0, .end = 0 },
                    });
                    continue;
                }
                try entry_specializations.append(allocator, .{
                    .entry_group_id = spec.entry_group_id,
                    .model = model,
                    .specialized_group_id = spec.entry_group_id,
                });
            }
            continue;
        }

        // Entries requesting THIS non-manifest model.
        var model_entries: std.ArrayListUnmanaged(u32) = .empty;
        defer model_entries.deinit(allocator);
        for (plan.specs) |spec| {
            if (spec.model == model) try model_entries.append(allocator, spec.entry_group_id);
        }
        if (model_entries.items.len == 0) continue;

        // 1. Spawn-reachable set: BFS from every entry of this model over
        //    resolvable direct/named/dispatch calls. Cold (indirect) edges stop
        //    the walk and set `saw_cold_edge`.
        var reachable = std.AutoHashMap(u32, void).init(allocator);
        defer reachable.deinit();
        var worklist: std.ArrayListUnmanaged(u32) = .empty;
        defer worklist.deinit(allocator);
        for (model_entries.items) |entry_id| {
            if (ctx.findFunctionGroupById(entry_id) == null) {
                try errors.append(allocator, .{
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "spawn manager plan references unknown entry function group id {d}",
                        .{entry_id},
                    ),
                    .span = .{ .start = 0, .end = 0 },
                });
                continue;
            }
            const gop = try reachable.getOrPut(entry_id);
            if (!gop.found_existing) try worklist.append(allocator, entry_id);
        }
        while (worklist.items.len > 0) {
            const group_id = worklist.items[worklist.items.len - 1];
            worklist.items.len -= 1;
            const group = ctx.findFunctionGroupById(group_id) orelse continue;
            var callees = std.AutoHashMap(u32, void).init(allocator);
            defer callees.deinit();
            try ctx.collectSubgraphCallees(group, &callees, &saw_cold_edge);
            var callee_it = callees.keyIterator();
            while (callee_it.next()) |callee_ptr| {
                const callee_id = callee_ptr.*;
                // Only clone groups that actually exist in the program. A callee
                // that resolves nowhere (runtime intrinsic, already a clone) is
                // a cold edge.
                if (ctx.findFunctionGroupById(callee_id) == null) continue;
                const gop = try reachable.getOrPut(callee_id);
                if (!gop.found_existing) try worklist.append(allocator, callee_id);
            }
        }
        if (reachable.count() == 0) continue;

        model_count += 1;

        // 2. Assign a fresh clone id to each reachable group and build the
        //    redirect map (original id → clone id).
        var redirect = std.AutoHashMap(u32, u32).init(allocator);
        defer redirect.deinit();
        var id_it = reachable.keyIterator();
        while (id_it.next()) |orig_ptr| {
            const clone_id = next_group_id.*;
            next_group_id.* += 1;
            try redirect.put(orig_ptr.*, clone_id);
        }

        // 3. Clone each reachable group with the redirect active (so intra-
        //    subgraph calls point at the clones) and the model tag set.
        ctx.current_model_call_redirect = &redirect;
        defer ctx.current_model_call_redirect = null;
        var clone_it = reachable.keyIterator();
        while (clone_it.next()) |orig_ptr| {
            const orig_id = orig_ptr.*;
            const orig = ctx.findFunctionGroupById(orig_id).?;
            const clone_id = redirect.get(orig_id).?;

            var empty_subs = SubstitutionMap.init(allocator);
            defer empty_subs.deinit();
            var cloned = try ctx.cloneGroupWithSubs(orig, &empty_subs, &[_]TypeId{}, &[_]TypeId{}, clone_id, 0);

            const base_name = interner.get(orig.name);
            const suffixed = try std.fmt.allocPrint(allocator, "{s}__mm_{s}", .{ base_name, modelSuffix(model) });
            defer allocator.free(suffixed);
            cloned.name = try interner.intern(suffixed);
            cloned.reclamation_model = model;

            // ICF red-flag verifier: the clone must be structurally identical
            // to its source modulo the tolerated differences. It always is (an
            // identity clone), so a failure here is a genuine semantic leak —
            // surface it as a diagnostic rather than let it become an
            // un-foldable code-size blow-up downstream.
            if (!modelCloneStructurallyFoldable(orig, &cloned)) {
                try red_flags.append(allocator, .{
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "ICF red flag: model specialization '{s}' ({s}) is not structurally " ++
                            "foldable with its source group {d} — a per-model transform leaked " ++
                            "into the function body where only header-emission ops should differ",
                        .{ interner.get(cloned.name), modelSuffix(model), orig_id },
                    ),
                    .span = genericGroupSpan(orig),
                });
            }

            try clones.append(allocator, .{
                .group = cloned,
                .source_group_id = orig_id,
                .target_struct_idx = findGroupOriginContainer(program, orig_id),
            });
        }

        // 4. Entry-specializations for this model's spawn sites.
        for (model_entries.items) |entry_id| {
            if (redirect.get(entry_id)) |specialized_id| {
                try entry_specializations.append(allocator, .{
                    .entry_group_id = entry_id,
                    .model = model,
                    .specialized_group_id = specialized_id,
                });
            }
        }
    }

    // 5. Splice the clones into their origin containers (same struct as their
    //    original, or top-level). `target_struct_idx` here means "the struct
    //    index that defines the source group," or null for a top-level source.
    var new_structs: std.ArrayListUnmanaged(hir.Struct) = .empty;
    errdefer new_structs.deinit(allocator);
    for (program.structs, 0..) |mod, mod_idx| {
        var new_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
        for (mod.functions) |group| try new_fns.append(allocator, group);
        for (clones.items) |entry| {
            if (entry.target_struct_idx) |idx| {
                if (idx == mod_idx) try new_fns.append(allocator, entry.group);
            }
        }
        try new_structs.append(allocator, .{
            .name = mod.name,
            .scope_id = mod.scope_id,
            .functions = try new_fns.toOwnedSlice(allocator),
            .types = mod.types,
        });
    }
    var new_top_fns: std.ArrayListUnmanaged(hir.FunctionGroup) = .empty;
    errdefer new_top_fns.deinit(allocator);
    for (program.top_functions) |group| try new_top_fns.append(allocator, group);
    for (clones.items) |entry| {
        if (entry.target_struct_idx == null) try new_top_fns.append(allocator, entry.group);
    }

    return .{
        .program = .{
            .structs = try new_structs.toOwnedSlice(allocator),
            .top_functions = try new_top_fns.toOwnedSlice(allocator),
            .protocols = program.protocols,
            .impls = program.impls,
        },
        .specialization_count = @intCast(clones.items.len),
        .model_count = model_count,
        .entry_specializations = try entry_specializations.toOwnedSlice(allocator),
        .saw_cold_edge = saw_cold_edge,
        .errors = try errors.toOwnedSlice(allocator),
        .foldability_red_flags = try red_flags.toOwnedSlice(allocator),
    };
}

// =============================================================================
// P3-J3 — spawn-site collection, resolution, and rewiring (ACTIVATES J2).
//
// Walks the post-monomorphize HIR for `spawn(f, .{ .manager = X })` sites — the
// `lib/process.zap` macro lowers each to the `ProcessRuntime.spawn_process_managed`
// INTRINSIC — resolves each site's comptime manager X to its reclamation MODEL
// + per-spawn registry INDEX (Decision Gate 0: a non-comptime manager is a
// compile error here), runs `specializeSpawnManagers` on the resulting plan,
// and REWIRES each site to enter its model's specialization under the chosen
// registry slot: `ProcessRuntime.spawn_process_at(clone, index)`.
//
// Recognition keys on the runtime INTRINSIC name — never a Zap library struct —
// so the compiler stays a general-purpose tool: the manager identity rides a
// first-class `Type` value the injected resolver decodes capability-driven.
// =============================================================================

/// The reclamation model + per-spawn registry index a `.manager = X` option
/// resolves to. Returned by the injected `SpawnManagerResolver`.
pub const ResolvedSpawnManager = struct {
    model: hir.ReclamationModel,
    registry_index: u32,
};

pub const SpawnManagerResolveError = error{ ManagerResolutionFailed, OutOfMemory };

/// Injected by the compiler pipeline: resolve a `.manager = X` manager type
/// name (a `Memory.X`) to its reclamation model + per-spawn registry index,
/// recording the manager for the registry plan + linking. The pipeline wires
/// this to the scope-graph adapter resolution + the memory-manager driver
/// (`declared_caps` → `elision.reclamationModel`); unit tests inject a double.
pub const SpawnManagerResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, manager_type_name: []const u8) SpawnManagerResolveError!ResolvedSpawnManager,

    pub fn resolve(self: SpawnManagerResolver, manager_type_name: []const u8) SpawnManagerResolveError!ResolvedSpawnManager {
        return self.resolveFn(self.context, manager_type_name);
    }
};

/// Intrinsic a `spawn(f, .{ .manager = X })` site lowers to — the marker the
/// pass recognizes + rewrites. A runtime PRIMITIVE name, not a Zap struct.
pub const MANAGED_SPAWN_BUILTIN = "ProcessRuntime.spawn_process_managed";
/// Intrinsic a resolved managed-spawn site is rewritten to.
pub const SPAWN_AT_BUILTIN = "ProcessRuntime.spawn_process_at";

/// One recognized + resolved managed-spawn site.
const ManagedSpawnSite = struct {
    /// The `spawn_process_managed` call expression (rewritten IN PLACE).
    call_expr: *const hir.Expr,
    /// The resolved real entry function group (the target of specialization).
    entry_group_id: u32,
    /// The `fn() -> Nil` type of the entry (reused for the rewired closure).
    entry_type_id: TypeId,
    /// The reclamation model + registry slot the manager resolved to.
    model: hir.ReclamationModel,
    registry_index: u32,
};

/// Run the P3-J3 spawn-manager wiring: collect + resolve managed-spawn sites,
/// specialize their reachable subgraphs per model (`specializeSpawnManagers`),
/// and rewire each site to `spawn_process_at(clone, index)`. When the program
/// has NO managed-spawn sites the pass is a byte-for-byte no-op (the zero-cost
/// gate — a single-manager / non-`.manager` binary is unchanged).
///
/// `resolver` is null in builds without manager plumbing; a managed-spawn site
/// found without a resolver, or with a non-comptime manager (Decision Gate 0),
/// is a diagnostic (never a silent miss). Any diagnostic leaves the program
/// UNMODIFIED — the driver reports the errors and aborts.
pub fn collectAndSpecializeSpawnManagers(
    allocator: Allocator,
    program: *const hir.Program,
    store: *TypeStore,
    next_group_id: *u32,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    manifest_model: hir.ReclamationModel,
) !SpawnManagerResult {
    var sites: std.ArrayListUnmanaged(ManagedSpawnSite) = .empty;
    defer sites.deinit(allocator);
    var errors: std.ArrayListUnmanaged(MonomorphError) = .empty;
    errdefer errors.deinit(allocator);

    try collectManagedSpawnSitesInProgram(allocator, program, interner, resolver, &sites, &errors);

    // Zero-cost gate: no managed-spawn sites (and no diagnostics) → the program
    // is returned unchanged, so every downstream stage is identical to a build
    // without per-spawn managers.
    if (sites.items.len == 0 or errors.items.len > 0) {
        return .{
            .program = program.*,
            .specialization_count = 0,
            .model_count = 0,
            .errors = try errors.toOwnedSlice(allocator),
        };
    }

    // Build the per-site specs (entry group → model) the J2 axis consumes.
    var specs: std.ArrayListUnmanaged(SpawnManagerSpec) = .empty;
    defer specs.deinit(allocator);
    for (sites.items) |site| {
        try specs.append(allocator, .{ .entry_group_id = site.entry_group_id, .model = site.model });
    }
    const plan = SpawnManagerPlan{ .manifest_model = manifest_model, .specs = specs.items };

    const spec_result = try specializeSpawnManagers(allocator, program, store, next_group_id, interner, plan);

    // Rewire each site: entry → the model's specialized clone, and the call →
    // `spawn_process_at` with the registry index. The site call_expr pointers
    // are STABLE across specialization — the caller bodies holding the spawn
    // sites are NOT cloned (only the spawn-reachable subgraph is), so the shared
    // Expr nodes are safe to mutate in place (the established HIR-rewrite pattern
    // in this module; see `rewriteExprBudgeted`).
    for (sites.items) |site| {
        const specialized_id = specializedGroupFor(spec_result.entry_specializations, site.entry_group_id, site.model) orelse site.entry_group_id;
        try rewriteManagedSpawnCall(allocator, site, specialized_id);
    }

    return spec_result;
}

fn specializedGroupFor(entry_specializations: []const EntrySpecialization, entry_group_id: u32, model: hir.ReclamationModel) ?u32 {
    for (entry_specializations) |spec| {
        if (spec.entry_group_id == entry_group_id and spec.model == model) return spec.specialized_group_id;
    }
    return null;
}

fn collectManagedSpawnSitesInProgram(
    allocator: Allocator,
    program: *const hir.Program,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    sites: *std.ArrayListUnmanaged(ManagedSpawnSite),
    errors: *std.ArrayListUnmanaged(MonomorphError),
) !void {
    for (program.structs) |mod| {
        for (mod.functions) |group| try collectSpawnSitesInGroup(allocator, program, interner, resolver, group, sites, errors);
    }
    for (program.top_functions) |group| try collectSpawnSitesInGroup(allocator, program, interner, resolver, group, sites, errors);
}

fn collectSpawnSitesInGroup(
    allocator: Allocator,
    program: *const hir.Program,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    group: hir.FunctionGroup,
    sites: *std.ArrayListUnmanaged(ManagedSpawnSite),
    errors: *std.ArrayListUnmanaged(MonomorphError),
) !void {
    for (group.clauses) |clause| {
        try collectSpawnSitesInBlock(allocator, program, interner, resolver, clause.body, sites, errors);
        if (clause.refinement) |refinement| try collectSpawnSitesInExpr(allocator, program, interner, resolver, refinement, sites, errors);
    }
}

fn collectSpawnSitesInBlock(
    allocator: Allocator,
    program: *const hir.Program,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    block: *const hir.Block,
    sites: *std.ArrayListUnmanaged(ManagedSpawnSite),
    errors: *std.ArrayListUnmanaged(MonomorphError),
) !void {
    for (block.stmts) |stmt| switch (stmt) {
        .expr => |expr| try collectSpawnSitesInExpr(allocator, program, interner, resolver, expr, sites, errors),
        .local_set => |ls| try collectSpawnSitesInExpr(allocator, program, interner, resolver, ls.value, sites, errors),
        // Nested groups (eta-wrappers, closures) can themselves hold spawn sites.
        .function_group => |nested| {
            for (nested.clauses) |clause| try collectSpawnSitesInBlock(allocator, program, interner, resolver, clause.body, sites, errors);
        },
    };
}

fn collectSpawnSitesInExpr(
    allocator: Allocator,
    program: *const hir.Program,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    expr: *const hir.Expr,
    sites: *std.ArrayListUnmanaged(ManagedSpawnSite),
    errors: *std.ArrayListUnmanaged(MonomorphError),
) anyerror!void {
    switch (expr.kind) {
        .call => |call| {
            if (call.target == .builtin and std.mem.eql(u8, call.target.builtin, MANAGED_SPAWN_BUILTIN)) {
                try recordManagedSpawnSite(allocator, program, interner, resolver, expr, call, sites, errors);
                return; // the managed-spawn's own args are consumed by the rewrite
            }
            for (call.args) |arg| try collectSpawnSitesInExpr(allocator, program, interner, resolver, arg.expr, sites, errors);
            if (call.target == .closure) try collectSpawnSitesInExpr(allocator, program, interner, resolver, call.target.closure, sites, errors);
        },
        .binary => |b| {
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, b.lhs, sites, errors);
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, b.rhs, sites, errors);
        },
        .unary => |u| try collectSpawnSitesInExpr(allocator, program, interner, resolver, u.operand, sites, errors),
        .tuple_init => |elems| for (elems) |e| try collectSpawnSitesInExpr(allocator, program, interner, resolver, e, sites, errors),
        .list_init => |elems| for (elems) |e| try collectSpawnSitesInExpr(allocator, program, interner, resolver, e, sites, errors),
        .list_cons => |lc| {
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, lc.head, sites, errors);
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, lc.tail, sites, errors);
        },
        .map_init => |entries| for (entries) |entry| {
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, entry.key, sites, errors);
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, entry.value, sites, errors);
        },
        .struct_init => |si| for (si.fields) |field| try collectSpawnSitesInExpr(allocator, program, interner, resolver, field.value, sites, errors),
        .field_get => |fg| try collectSpawnSitesInExpr(allocator, program, interner, resolver, fg.object, sites, errors),
        .branch => |br| {
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, br.condition, sites, errors);
            try collectSpawnSitesInBlock(allocator, program, interner, resolver, br.then_block, sites, errors);
            if (br.else_block) |eb| try collectSpawnSitesInBlock(allocator, program, interner, resolver, eb, sites, errors);
        },
        .case => |cd| {
            try collectSpawnSitesInExpr(allocator, program, interner, resolver, cd.scrutinee, sites, errors);
            for (cd.arms) |arm| try collectSpawnSitesInBlock(allocator, program, interner, resolver, arm.body, sites, errors);
        },
        .block => |blk| try collectSpawnSitesInBlock(allocator, program, interner, resolver, &blk, sites, errors),
        .panic => |e| try collectSpawnSitesInExpr(allocator, program, interner, resolver, e, sites, errors),
        .unwrap => |e| try collectSpawnSitesInExpr(allocator, program, interner, resolver, e, sites, errors),
        .union_init => |ui| try collectSpawnSitesInExpr(allocator, program, interner, resolver, ui.value, sites, errors),
        else => {},
    }
}

fn recordManagedSpawnSite(
    allocator: Allocator,
    program: *const hir.Program,
    interner: *ast.StringInterner,
    resolver: ?SpawnManagerResolver,
    call_expr: *const hir.Expr,
    call: hir.CallExpr,
    sites: *std.ArrayListUnmanaged(ManagedSpawnSite),
    errors: *std.ArrayListUnmanaged(MonomorphError),
) !void {
    if (call.args.len != 2) {
        try errors.append(allocator, .{
            .message = try allocator.dupe(u8, "internal error: managed spawn intrinsic must carry (entry, options)"),
            .span = call_expr.span,
        });
        return;
    }
    const entry_arg = call.args[0].expr;
    const options_arg = call.args[1].expr;

    const entry_group_id = extractSpawnEntryGroup(allocator, program, interner, entry_arg) orelse {
        try errors.append(allocator, .{
            .message = try allocator.dupe(u8, "Process.spawn entry must be a named (or capture-less) zero-parameter function"),
            .span = call_expr.span,
        });
        return;
    };

    const manager_type_name = extractManagerTypeName(interner, options_arg) orelse {
        // Decision Gate 0: the manager option is not a comptime-known Memory
        // manager type — it cannot be resolved to a reclamation model at compile
        // time, so it cannot select the process's specialization.
        try errors.append(allocator, .{
            .message = try allocator.dupe(
                u8,
                "Process.spawn manager option must be a comptime-known Memory manager type " ++
                    "(e.g. `.{ .manager = Memory.Arena }`). The manager selects the process's " ++
                    "reclamation model and codegen at the spawn site (Decision Gate 0); it cannot " ++
                    "be a runtime value.",
            ),
            .span = call_expr.span,
        });
        return;
    };

    const active_resolver = resolver orelse {
        try errors.append(allocator, .{
            .message = try std.fmt.allocPrint(
                allocator,
                "per-spawn memory manager '{s}' cannot be resolved in this build (no manager resolver wired)",
                .{manager_type_name},
            ),
            .span = call_expr.span,
        });
        return;
    };

    const resolved = active_resolver.resolve(manager_type_name) catch |err| {
        try errors.append(allocator, .{
            .message = try std.fmt.allocPrint(
                allocator,
                "could not resolve per-spawn memory manager '{s}': {s}",
                .{ manager_type_name, @errorName(err) },
            ),
            .span = call_expr.span,
        });
        return;
    };

    try sites.append(allocator, .{
        .call_expr = call_expr,
        .entry_group_id = entry_group_id,
        .entry_type_id = entry_arg.type_id,
        .model = resolved.model,
        .registry_index = resolved.registry_index,
    });
}

/// The `closure_create` a spawn entry argument reduces to — either the argument
/// itself (a bare 0-capture funcref) or the result expression of the eta-wrapper
/// block the desugarer produces for a `&Struct.fn/0` in argument position.
fn spawnEntryClosure(entry_arg: *const hir.Expr) ?hir.ClosureCreate {
    switch (entry_arg.kind) {
        .closure_create => |cc| return cc,
        .block => |blk| {
            if (blk.stmts.len == 0) return null;
            const last = blk.stmts[blk.stmts.len - 1];
            if (last == .expr and last.expr.kind == .closure_create) return last.expr.kind.closure_create;
            return null;
        },
        else => return null,
    }
}

/// Resolve a spawn entry argument to the REAL entry function group. Handles both
/// a direct 0-capture closure over a findable group and the desugarer's eta
/// wrapper (`fn() { RealStruct.real_fn() }`), whose forwarding call names the
/// real entry (the wrapper itself is a nested group `specializeSpawnManagers`
/// cannot see, so the real, findable entry is what the spec must carry).
fn extractSpawnEntryGroup(allocator: Allocator, program: *const hir.Program, interner: *ast.StringInterner, entry_arg: *const hir.Expr) ?u32 {
    const closure = spawnEntryClosure(entry_arg) orelse return null;
    if (findGroupInProgram(program, closure.function_group_id) != null) return closure.function_group_id;
    // Nested eta-wrapper: peer into its forwarding call.
    if (entry_arg.kind == .block) {
        for (entry_arg.kind.block.stmts) |stmt| {
            if (stmt == .function_group and stmt.function_group.id == closure.function_group_id) {
                const wrapper = stmt.function_group;
                if (wrapper.clauses.len == 0) return null;
                return forwardingCallGroup(allocator, program, interner, wrapper.clauses[0].body);
            }
        }
    }
    return null;
}

fn forwardingCallGroup(allocator: Allocator, program: *const hir.Program, interner: *ast.StringInterner, body: *const hir.Block) ?u32 {
    for (body.stmts) |stmt| {
        const expr = switch (stmt) {
            .expr => |e| e,
            .local_set => |ls| ls.value,
            else => continue,
        };
        if (expr.kind == .call) {
            switch (expr.kind.call.target) {
                .direct => |dc| return dc.function_group_id,
                .dispatch => |dp| return dp.function_group_id,
                .named => |nc| return resolveNamedCallGroup(allocator, program, interner, nc),
                else => {},
            }
        }
    }
    return null;
}

fn resolveNamedCallGroup(allocator: Allocator, program: *const hir.Program, interner: *ast.StringInterner, nc: hir.NamedCall) ?u32 {
    const struct_name = nc.struct_name orelse return null;
    for (program.structs) |mod| {
        // `joinedWith` always allocates (single-segment names dup), so the
        // dotted form is freeable uniformly.
        const dotted = mod.name.joinedWith(allocator, interner, ".") catch return null;
        defer allocator.free(dotted);
        if (!std.mem.eql(u8, dotted, struct_name)) continue;
        for (mod.functions) |group| {
            if (std.mem.eql(u8, interner.get(group.name), nc.name)) return group.id;
        }
    }
    return null;
}

/// Extract the `Memory.X` type NAME the spawn site's manager argument names.
/// Two surface shapes reduce to the same comptime-known first-class `Type`:
///
///   * The bare manager type — `Process.spawn(entry, Memory.Arena)`. The
///     argument IS the `Type` value (`hir.buildTypeValueExpr`: a struct-init
///     carrying a single `name` atom field), read directly by `typeValueName`.
///   * An options struct carrying a `.manager` field — the forward-compatible
///     shape reserved for future spawn options (`.manager` + siblings). The
///     field value is itself a `Type` value.
///
/// Returns null when neither shape names a comptime-known manager type (a
/// runtime value, a non-`Type` expression) — the Decision Gate 0 signal that
/// makes a non-comptime `.manager` a compile error at the call site.
fn extractManagerTypeName(interner: *ast.StringInterner, manager_arg: *const hir.Expr) ?[]const u8 {
    if (manager_arg.kind != .struct_init) return null;
    // Options-struct shape: a `.manager` field wins when present.
    for (manager_arg.kind.struct_init.fields) |field| {
        if (std.mem.eql(u8, interner.get(field.name), "manager")) {
            return typeValueName(interner, field.value);
        }
    }
    // Bare-manager shape: the argument itself is the `Type` value. A Type value
    // is a struct-init with a `name` field (never a `manager` field), so this
    // fallthrough is unambiguous with the options-struct branch above.
    return typeValueName(interner, manager_arg);
}

/// A first-class `Type` value lowers to a struct-init with a single `name`
/// atom field (`hir.buildTypeValueExpr`); recover that atom's string.
fn typeValueName(interner: *ast.StringInterner, expr: *const hir.Expr) ?[]const u8 {
    if (expr.kind != .struct_init) return null;
    for (expr.kind.struct_init.fields) |field| {
        if (std.mem.eql(u8, interner.get(field.name), "name")) {
            if (field.value.kind == .atom_lit) return interner.get(field.value.kind.atom_lit);
        }
    }
    return null;
}

fn findGroupInProgram(program: *const hir.Program, group_id: u32) ?*const hir.FunctionGroup {
    for (program.structs) |mod| {
        for (mod.functions) |*group| if (group.id == group_id) return group;
    }
    for (program.top_functions) |*group| if (group.id == group_id) return group;
    return null;
}

/// Rewrite a managed-spawn call IN PLACE to `spawn_process_at(clone, index)`:
/// the entry becomes a 0-capture closure over the model specialization (a bare
/// funcref the backend bakes into the spawn trampoline) and the registry index
/// a `u32` literal. Uses the module's `@constCast` HIR-mutation pattern — safe
/// because the caller body holding the site is shared (never cloned).
fn rewriteManagedSpawnCall(allocator: Allocator, site: ManagedSpawnSite, specialized_group_id: u32) !void {
    const closure_expr = try allocator.create(hir.Expr);
    closure_expr.* = .{
        .kind = .{ .closure_create = .{ .function_group_id = specialized_group_id, .captures = &.{} } },
        .type_id = site.entry_type_id,
        .span = site.call_expr.span,
    };
    const index_expr = try allocator.create(hir.Expr);
    index_expr.* = .{
        .kind = .{ .int_lit = @intCast(site.registry_index) },
        .type_id = types_mod.TypeStore.U32,
        .span = site.call_expr.span,
    };
    const new_args = try allocator.alloc(hir.CallArg, 2);
    new_args[0] = .{ .expr = closure_expr, .mode = .share, .expected_type = site.entry_type_id };
    new_args[1] = .{ .expr = index_expr, .mode = .share, .expected_type = types_mod.TypeStore.U32 };

    const mutable: *hir.Expr = @constCast(site.call_expr);
    switch (mutable.kind) {
        .call => |*c| {
            c.target = .{ .builtin = SPAWN_AT_BUILTIN };
            c.args = new_args;
        },
        else => {},
    }
}

/// Check if a function group has type variable parameters (is generic).
fn genericGroupContainsTypeVar(store: *const TypeStore, group: *const hir.FunctionGroup, allocator: Allocator) TypeWalkError!bool {
    if (group.clauses.len == 0) return false;
    const first_clause = &group.clauses[0];
    for (first_clause.params) |param| {
        if (try containsTypeVar(store, param.type_id, allocator)) return true;
    }
    // Also check return type
    if (try containsTypeVar(store, first_clause.return_type, allocator)) return true;
    return false;
}

/// Check if a TypeId contains any type variables.
fn containsTypeVar(store: *const TypeStore, type_id: TypeId, allocator: Allocator) TypeWalkError!bool {
    var walker = TypeWalker.init(allocator);
    defer walker.deinit();

    try walker.pushRoot(type_id);
    while (try walker.next()) |item| {
        const next_depth = item.depth + 1;
        switch (store.getType(item.type_id)) {
            .type_var => return true,
            .protocol_constraint => |pc| {
                // Protocol constraints lower to a protocol-box ABI shape once
                // their type arguments are concrete. Treat the constraint as
                // generic only when those arguments still contain free type
                // variables; otherwise transitive monomorphization must scan
                // the clone and emit helper specializations reachable from it.
                for (pc.type_params) |type_param| try walker.pushType(type_param, next_depth, false);
            },
            .list => |list_type| try walker.pushType(list_type.element, next_depth, false),
            .tuple => |tuple_type| {
                for (tuple_type.elements) |element| try walker.pushType(element, next_depth, false);
            },
            .function => |function_type| {
                for (function_type.params) |param| try walker.pushType(param, next_depth, false);
                try walker.pushType(function_type.return_type, next_depth, false);
                // A polymorphic effect marker is a free type variable (#201),
                // making the enclosing function type generic so it specializes
                // per closure-argument effect.
                if (function_type.effect_var) |effect_var| try walker.pushType(effect_var, next_depth, false);
            },
            .map => |map_type| {
                try walker.pushType(map_type.key, next_depth, false);
                try walker.pushType(map_type.value, next_depth, false);
            },
            .applied => |applied_type| {
                for (applied_type.args) |arg| try walker.pushType(arg, next_depth, false);
            },
            else => {},
        }
    }
    return false;
}

fn genericGroupSpan(group: *const hir.FunctionGroup) ast.SourceSpan {
    if (group.debug_span.start != group.debug_span.end) return group.debug_span;
    if (group.clauses.len > 0 and group.clauses[0].debug_span.start != group.clauses[0].debug_span.end) {
        return group.clauses[0].debug_span;
    }
    return .{ .start = 0, .end = 0 };
}

fn blockSpan(block: *const hir.Block) ast.SourceSpan {
    for (block.stmts) |stmt| {
        switch (stmt) {
            .expr => |expr| return expr.span,
            .local_set => |local_set| return local_set.value.span,
            .function_group => |group| return genericGroupSpan(group),
        }
    }
    return .{ .start = 0, .end = 0 };
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
) TypeWalkError!std.AutoHashMap(types_mod.TypeVarId, void) {
    var out = std.AutoHashMap(types_mod.TypeVarId, void).init(allocator);
    errdefer out.deinit();

    var walker = TypeWalker.init(allocator);
    defer walker.deinit();

    try walker.pushScalarRoot(type_id);
    while (try walker.next()) |item| {
        const next_depth = item.depth + 1;
        switch (store.getType(item.type_id)) {
            .type_var => |var_id| {
                if (item.scalar_position) try out.put(var_id, {});
            },
            .list => |list_type| try walker.pushType(list_type.element, next_depth, false),
            .map => |map_type| {
                try walker.pushType(map_type.key, next_depth, false);
                try walker.pushType(map_type.value, next_depth, false);
            },
            .tuple => |tuple_type| {
                for (tuple_type.elements) |element| try walker.pushType(element, next_depth, false);
            },
            .function => |function_type| {
                for (function_type.params) |param| try walker.pushType(param, next_depth, false);
                try walker.pushType(function_type.return_type, next_depth, false);
            },
            else => {},
        }
    }
    return out;
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
    allocator: Allocator,
) TypeWalkError!void {
    var walker = TypeWalker.init(allocator);
    defer walker.deinit();

    try walker.pushPairRoot(param_type, arg_type);
    while (try walker.next()) |item| {
        const paired_type_id = item.paired_type_id orelse unreachable;
        const param_typ = store.getType(item.type_id);
        const arg_typ = store.getType(paired_type_id);
        const next_depth = item.depth + 1;
        switch (param_typ) {
            .type_var => |var_id| {
                if (arg_typ == .term_type and !scalar_return_vars.contains(var_id)) {
                    if (subs.bindings.get(var_id)) |existing| {
                        if (store.getType(existing) == .term_type) continue;
                    }
                    try subs.bindings.put(var_id, types_mod.TypeStore.TERM);
                }
            },
            .list => |param_list| {
                if (arg_typ == .list) {
                    try walker.pushPair(param_list.element, arg_typ.list.element, next_depth);
                }
            },
            .map => |param_map| {
                if (arg_typ == .map) {
                    try walker.pushPair(param_map.key, arg_typ.map.key, next_depth);
                    try walker.pushPair(param_map.value, arg_typ.map.value, next_depth);
                }
            },
            .tuple => |param_tuple| {
                if (arg_typ == .tuple and param_tuple.elements.len == arg_typ.tuple.elements.len) {
                    for (param_tuple.elements, arg_typ.tuple.elements) |param_element, arg_element| {
                        try walker.pushPair(param_element, arg_element, next_depth);
                    }
                }
            },
            .function => |param_function| {
                if (arg_typ == .function and param_function.params.len == arg_typ.function.params.len) {
                    for (param_function.params, arg_typ.function.params) |param_child, arg_child| {
                        try walker.pushPair(param_child, arg_child, next_depth);
                    }
                    try walker.pushPair(param_function.return_type, arg_typ.function.return_type, next_depth);
                }
            },
            else => {},
        }
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
fn mangleName(allocator: Allocator, base_name: []const u8, store: *const TypeStore, type_args: []const TypeId) NameMangleError![]u8 {
    for (type_args) |concrete_type| {
        try typeStructureWithinMangleBudget(allocator, store, concrete_type);
    }

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(allocator);

    try parts.appendSlice(allocator, base_name);
    if (type_args.len > 0) {
        try parts.appendSlice(allocator, "__");
    }

    for (type_args, 0..) |concrete_type, i| {
        if (i > 0) try parts.append(allocator, '_');
        const type_name = try typeIdToMangledName(allocator, store, concrete_type);
        defer allocator.free(type_name);
        try parts.appendSlice(allocator, type_name);
    }

    return try parts.toOwnedSlice(allocator);
}

fn typeStructureWithinMangleBudget(allocator: Allocator, store: *const TypeStore, root: TypeId) TypeWalkError!void {
    var walker = TypeWalker.init(allocator);
    defer walker.deinit();

    try walker.pushRoot(root);
    while (try walker.next()) |item| {
        try walker.pushStructuralChildren(store, item);
    }
}

// ============================================================
// Parametric struct/union specialization tests (Phase 1.1.5.c)
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const HirBuilder = hir.HirBuilder;

fn initTestMonomorphContext(
    allocator: Allocator,
    store: *TypeStore,
    interner: *ast.StringInterner,
    program: *const hir.Program,
    next_group_id: *u32,
) MonomorphContext {
    return .{
        .allocator = allocator,
        .store = store,
        .next_group_id = next_group_id,
        .interner = interner,
        .program = program,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(allocator),
        .specializations = std.AutoHashMap(u64, u32).init(allocator),
        .specialization_counts = std.AutoHashMap(u32, u32).init(allocator),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(allocator),
        .local_types = std.AutoHashMap(u32, TypeId).init(allocator),
        .errors = .empty,
    };
}

fn deinitTestMonomorphContext(ctx: *MonomorphContext) void {
    ctx.generic_groups.deinit();
    ctx.specializations.deinit();
    ctx.specialization_counts.deinit();
    ctx.new_groups.deinit(ctx.allocator);
    ctx.call_rewrites.deinit();
    ctx.local_types.deinit();
    ctx.errors.deinit(ctx.allocator);
}

fn testExpr(
    allocator: Allocator,
    kind: hir.ExprKind,
    type_id: TypeId,
    span: ast.SourceSpan,
) !*const hir.Expr {
    const expr = try allocator.create(hir.Expr);
    expr.* = .{ .kind = kind, .type_id = type_id, .span = span };
    return expr;
}

fn deepUnaryExpr(
    allocator: Allocator,
    depth: u32,
    span: ast.SourceSpan,
) !*const hir.Expr {
    var current = try testExpr(allocator, .{ .bool_lit = true }, TypeStore.BOOL, span);
    for (0..depth) |_| {
        current = try testExpr(allocator, .{ .unary = .{
            .op = .not_op,
            .operand = current,
        } }, TypeStore.BOOL, span);
    }
    return current;
}

fn blockWithExpr(allocator: Allocator, expr: *const hir.Expr) !*const hir.Block {
    const stmts = try allocator.alloc(hir.Stmt, 1);
    stmts[0] = .{ .expr = expr };
    const block = try allocator.create(hir.Block);
    block.* = .{ .stmts = stmts, .result_type = expr.type_id };
    return block;
}

fn emptyBlock(allocator: Allocator) !*const hir.Block {
    const block = try allocator.create(hir.Block);
    block.* = .{ .stmts = &.{}, .result_type = TypeStore.NIL };
    return block;
}

fn deepTuplePattern(
    allocator: Allocator,
    depth: u32,
    bind_name: ast.StringId,
) !*const hir.MatchPattern {
    var current = try allocator.create(hir.MatchPattern);
    current.* = .{ .bind = bind_name };
    for (0..depth) |_| {
        const elements = try allocator.alloc(*const hir.MatchPattern, 1);
        elements[0] = current;
        const next = try allocator.create(hir.MatchPattern);
        next.* = .{ .tuple = elements };
        current = next;
    }
    return current;
}

fn deepBindDecision(
    allocator: Allocator,
    depth: u32,
    bind_name: ast.StringId,
    source_expr: *const hir.Expr,
) !*const hir.Decision {
    var current = try allocator.create(hir.Decision);
    current.* = .{ .success = .{ .bindings = &.{}, .body_index = 0 } };
    for (0..depth) |_| {
        const next = try allocator.create(hir.Decision);
        next.* = .{ .bind = .{
            .name = bind_name,
            .local_index = 0,
            .source = source_expr,
            .next = current,
        } };
        current = next;
    }
    return current;
}

fn deepListType(store: *TypeStore, depth: u32, leaf: TypeId) !TypeId {
    var current = leaf;
    for (0..depth) |_| {
        current = try store.addType(.{ .list = .{ .element = current } });
    }
    return current;
}

fn cyclicListType(store: *TypeStore, allocator: Allocator) !TypeId {
    const type_id: TypeId = @intCast(store.types.items.len);
    try store.types.append(allocator, .{ .list = .{ .element = type_id } });
    return type_id;
}

test "structNameMatchesQualifier preserves multi-segment match and no-match semantics" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const namespace_name = try interner.intern("Zap");
    const struct_name = try interner.intern("CombinatorFactory");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(std.testing.allocator, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const parts = [_]ast.StringId{ namespace_name, struct_name };
    const qualified_name = ast.StructName{
        .parts = &parts,
        .span = .{ .start = 0, .end = 0 },
    };

    try std.testing.expect(try ctx.structNameMatchesQualifier(qualified_name, "CombinatorFactory"));
    try std.testing.expect(try ctx.structNameMatchesQualifier(qualified_name, "Zap_CombinatorFactory"));
    try std.testing.expect(try ctx.structNameMatchesQualifier(qualified_name, "Zap.CombinatorFactory"));
    try std.testing.expect(!try ctx.structNameMatchesQualifier(qualified_name, "Zap.Other"));
}

test "structNameMatchesQualifier propagates multi-segment allocation failure" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const namespace_name = try interner.intern("Zap");
    const struct_name = try interner.intern("CombinatorFactory");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const parts = [_]ast.StringId{ namespace_name, struct_name };
    const qualified_name = ast.StructName{
        .parts = &parts,
        .span = .{ .start = 0, .end = 0 },
    };

    try std.testing.expectError(
        error.OutOfMemory,
        ctx.structNameMatchesQualifier(qualified_name, "Zap.Other"),
    );
}

test "resolveNamedCall propagates qualifier allocation failure" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const namespace_name = try interner.intern("Zap");
    const struct_name = try interner.intern("CombinatorFactory");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const parts = [_]ast.StringId{ namespace_name, struct_name };
    const structs = [_]hir.Struct{.{
        .name = .{
            .parts = &parts,
            .span = .{ .start = 0, .end = 0 },
        },
        .scope_id = 0,
        .functions = &.{},
        .types = &.{},
    }};
    const program = hir.Program{
        .structs = &structs,
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    try std.testing.expectError(
        error.OutOfMemory,
        ctx.resolveNamedCall(.{ .struct_name = "Zap.Other", .name = "make" }, 0),
    );
}

test "cloneGroupWithSubs propagates source-qualified name allocation OOM" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const struct_name = try interner.intern("Source");
    const function_name = try interner.intern("identity");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const group = hir.FunctionGroup{
        .id = 1,
        .scope_id = 0,
        .name = function_name,
        .arity = 0,
        .clauses = &.{},
        .fallback_parent = null,
    };
    const functions = [_]hir.FunctionGroup{group};
    const name_parts = [_]ast.StringId{struct_name};
    const structs = [_]hir.Struct{.{
        .name = .{ .parts = &name_parts, .span = .{ .start = 0, .end = 0 } },
        .scope_id = 0,
        .functions = &functions,
        .types = &.{},
    }};
    const program = hir.Program{
        .structs = &structs,
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };

    var subs = SubstitutionMap.init(std.testing.allocator);
    defer subs.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 2;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const type_args = [_]TypeId{TypeStore.I64};
    try std.testing.expectError(
        error.OutOfMemory,
        ctx.cloneGroupWithSubs(&functions[0], &subs, &.{}, &type_args, next_group_id, 0),
    );
}

test "typeIdToMangledName propagates allocation failure instead of T" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        typeIdToMangledName(failing_allocator.allocator(), &store, TypeStore.I64),
    );
}

test "typeIdToMangledName includes anonymous union member identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const union_members = [_]TypeId{ TypeStore.I64, TypeStore.STRING };
    const union_type = try store.addType(.{ .union_type = .{ .members = &union_members } });

    const union_name = try typeIdToMangledName(alloc, &store, union_type);
    try std.testing.expectEqualStrings("Union_i64_String", union_name);
}

test "typeIdToMangledName includes type variable identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const box_name = try interner.intern("Box");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const box_decl = try store.addType(.{ .struct_type = .{
        .name = box_name,
        .fields = &.{},
        .type_params = &.{},
    } });
    const type_var = try store.freshVar();
    const applied_args = try alloc.alloc(TypeId, 1);
    applied_args[0] = type_var;
    const box_type_var = try store.addType(.{ .applied = .{ .base = box_decl, .args = applied_args } });

    const box_type_var_name = try typeIdToMangledName(alloc, &store, box_type_var);
    try std.testing.expectEqualStrings("Box_TypeVar0", box_type_var_name);
}

test "mangleName rejects oversized type arguments before emitting partial names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const oversized_type = try deepListType(&store, MAX_TYPE_STRUCTURE_DEPTH + 2, TypeStore.I64);
    const type_args = [_]TypeId{oversized_type};

    try std.testing.expectError(
        error.TypeStructureTooDeep,
        mangleName(alloc, "identity", &store, &type_args),
    );
}

test "cloneGroupWithSubs does not fall back to base group name on mangle OOM" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const function_name = try interner.intern("identity");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const group = hir.FunctionGroup{
        .id = 1,
        .scope_id = 0,
        .name = function_name,
        .arity = 0,
        .clauses = &.{},
        .fallback_parent = null,
    };
    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{group},
        .protocols = &.{},
        .impls = &.{},
    };

    var subs = SubstitutionMap.init(std.testing.allocator);
    defer subs.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 2;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const type_args = [_]TypeId{TypeStore.I64};
    try std.testing.expectError(
        error.OutOfMemory,
        ctx.cloneGroupWithSubs(&group, &subs, &.{}, &type_args, next_group_id, 0),
    );
}

test "monomorphizer propagates transitive scan copy OOM" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    const function_name = try interner.intern("ready");

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 2;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const group = hir.FunctionGroup{
        .id = 1,
        .scope_id = 0,
        .name = function_name,
        .arity = 0,
        .clauses = &.{},
        .fallback_parent = null,
    };
    const entries = [_]NewGroupEntry{.{
        .group = group,
        .source_group_id = group.id,
        .target_struct_idx = null,
    }};

    try std.testing.expectError(error.OutOfMemory, ctx.collectTransitiveScanEntries(&entries));
}

test "monomorphizer checked type walkers report depth exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const deep_concrete = try deepListType(&store, MAX_TYPE_STRUCTURE_DEPTH + 2, TypeStore.I64);
    try std.testing.expectError(error.TypeStructureTooDeep, ctx.isConcreteRuntimeType(deep_concrete));
    try std.testing.expectError(error.TypeStructureTooDeep, ctx.typeArgIsMonomorphizationReady(deep_concrete));

    const type_var = try store.freshVar();
    const deep_unbound = try deepListType(&store, MAX_TYPE_STRUCTURE_DEPTH + 2, type_var);
    try std.testing.expectError(error.TypeStructureTooDeep, ctx.defaultUnboundTypeVars(deep_unbound, TypeStore.I64));
}

test "defaultUnboundTypeVars returns OOM instead of original type on allocation failure" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var store = try TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const type_var = try store.freshVar();
    const tuple_elements = try std.testing.allocator.alloc(TypeId, 1);
    defer std.testing.allocator.free(tuple_elements);
    tuple_elements[0] = type_var;
    const tuple_type = try store.addType(.{ .tuple = .{ .elements = tuple_elements } });

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    try std.testing.expectError(error.OutOfMemory, ctx.defaultUnboundTypeVars(tuple_type, TypeStore.I64));
}

test "protocol constraint replacement compares substituted source params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const enumerable_name = try interner.intern("Enumerable");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const element_var = try store.freshVar();
    const element_var_id = store.getType(element_var).type_var;

    const formal_args = try alloc.alloc(TypeId, 1);
    formal_args[0] = element_var;
    const enumerable_element = try store.addType(.{ .protocol_constraint = .{
        .protocol_name = enumerable_name,
        .type_params = formal_args,
    } });

    const concrete_args = try alloc.alloc(TypeId, 1);
    concrete_args[0] = TypeStore.I64;
    const enumerable_i64 = try store.addType(.{ .protocol_constraint = .{
        .protocol_name = enumerable_name,
        .type_params = concrete_args,
    } });
    const list_i64 = try store.addType(.{ .list = .{ .element = TypeStore.I64 } });

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();
    try subs.bind(element_var_id, TypeStore.I64);

    var next_group_id: u32 = 1;
    const source_params = [_]hir.TypedParam{
        .{ .name = null, .type_id = enumerable_element, .pattern = null },
    };
    const concrete_protocol_params = [_]TypeId{list_i64};
    const empty_program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
    };

    var ctx = MonomorphContext{
        .allocator = alloc,
        .store = &store,
        .next_group_id = &next_group_id,
        .interner = &interner,
        .program = &empty_program,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(alloc),
        .specializations = std.AutoHashMap(u64, u32).init(alloc),
        .specialization_counts = std.AutoHashMap(u32, u32).init(alloc),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(alloc),
        .local_types = std.AutoHashMap(u32, TypeId).init(alloc),
        .errors = .empty,
        .current_subs = &subs,
        .current_protocol_param_types = &concrete_protocol_params,
        .current_protocol_source_param_types = &source_params,
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.specialization_counts.deinit();
    defer ctx.new_groups.deinit(alloc);
    defer ctx.call_rewrites.deinit();
    defer ctx.local_types.deinit();
    defer ctx.errors.deinit(alloc);

    try std.testing.expectEqual(list_i64, (try ctx.protocolConstraintReplacement(enumerable_i64)).?);
}

test "monomorphizer rejects structurally oversized specialization type arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const function_name = try interner.intern("grow");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    var nested_type = TypeStore.I64;
    for (0..MAX_TYPE_STRUCTURE_DEPTH + 2) |_| {
        nested_type = try store.addType(.{ .list = .{ .element = nested_type } });
    }

    const empty_program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = MonomorphContext{
        .allocator = alloc,
        .store = &store,
        .next_group_id = &next_group_id,
        .interner = &interner,
        .program = &empty_program,
        .generic_groups = std.AutoHashMap(u32, *const hir.FunctionGroup).init(alloc),
        .specializations = std.AutoHashMap(u64, u32).init(alloc),
        .specialization_counts = std.AutoHashMap(u32, u32).init(alloc),
        .new_groups = .empty,
        .call_rewrites = std.AutoHashMap(u64, u32).init(alloc),
        .local_types = std.AutoHashMap(u32, TypeId).init(alloc),
        .errors = .empty,
    };
    defer ctx.generic_groups.deinit();
    defer ctx.specializations.deinit();
    defer ctx.specialization_counts.deinit();
    defer ctx.new_groups.deinit(alloc);
    defer ctx.call_rewrites.deinit();
    defer ctx.local_types.deinit();
    defer ctx.errors.deinit(alloc);

    const generic_group = hir.FunctionGroup{
        .id = 7,
        .scope_id = 0,
        .name = function_name,
        .arity = 1,
        .clauses = &.{},
        .fallback_parent = null,
    };
    const type_args = [_]TypeId{nested_type};

    const within_budget = try ctx.specializationWithinBudget(&generic_group, &type_args, .{ .start = 0, .end = 1 });
    try std.testing.expect(!within_budget);
    try std.testing.expect(ctx.errors.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "exceeds maximum type nesting depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "grow/1") != null);
}

test "monomorphizer reports oversized generic signatures during discovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const function_name = try interner.intern("pathological");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    var nested_type = try store.freshVar();
    for (0..MAX_TYPE_STRUCTURE_DEPTH + 2) |_| {
        nested_type = try store.addType(.{ .list = .{ .element = nested_type } });
    }

    const decision = try alloc.create(hir.Decision);
    decision.* = .{ .success = .{ .bindings = &.{}, .body_index = 0 } };
    const body = try alloc.create(hir.Block);
    body.* = .{ .stmts = &.{}, .result_type = TypeStore.NIL };

    const params = try alloc.alloc(hir.TypedParam, 1);
    params[0] = .{
        .name = null,
        .type_id = nested_type,
        .pattern = null,
    };
    const clauses = try alloc.alloc(hir.Clause, 1);
    clauses[0] = .{
        .params = params,
        .return_type = TypeStore.NIL,
        .debug_span = .{ .start = 11, .end = 19 },
        .decision = decision,
        .body = body,
        .refinement = null,
        .tuple_bindings = &.{},
    };
    const groups = try alloc.alloc(hir.FunctionGroup, 1);
    groups[0] = .{
        .id = 17,
        .scope_id = 0,
        .name = function_name,
        .arity = 1,
        .debug_span = .{ .start = 10, .end = 20 },
        .clauses = clauses,
        .fallback_parent = null,
    };
    const program = hir.Program{
        .structs = &.{},
        .top_functions = groups,
        .protocols = &.{},
        .impls = &.{},
    };

    var next_group_id: u32 = 18;
    const result = try monomorphize(alloc, &program, &store, &next_group_id, &interner);

    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(@as(usize, 10), result.errors[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "type signature exceeds maximum type nesting depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "pathological/1") != null);
}

test "monomorphizer type walkers terminate on cyclic type graphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const cyclic_list = try cyclicListType(&store, alloc);

    try std.testing.expect(!try containsTypeVar(&store, cyclic_list, alloc));

    var scalar_vars = try scalarTypeVarSet(&store, cyclic_list, alloc);
    defer scalar_vars.deinit();
    try std.testing.expectEqual(@as(u32, 0), scalar_vars.count());

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();
    try promoteContainerVarsExceptScalarReturn(&store, cyclic_list, cyclic_list, &scalar_vars, &subs, alloc);
    try std.testing.expectEqual(@as(u32, 0), subs.bindings.count());
}

test "protocol impl binding propagates TypeStore.unify OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const protocol_name = try interner.intern("Enumerable");
    const integer_name = try interner.intern("Integer");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const constraint_arg = try store.freshVar();
    const constraint_args = try alloc.alloc(TypeId, 1);
    constraint_args[0] = constraint_arg;
    const constraint_type = try store.addType(.{ .protocol_constraint = .{
        .protocol_name = protocol_name,
        .type_params = constraint_args,
    } });

    const impl_arg = try store.freshVar();
    const impl_args = try alloc.alloc(TypeId, 1);
    impl_args[0] = impl_arg;
    const target_pattern = try store.freshVar();
    const impls = try alloc.alloc(hir.ImplInfo, 1);
    impls[0] = .{
        .protocol_name = protocol_name,
        .protocol_type_args = impl_args,
        .target_struct = integer_name,
        .target_type_pattern = target_pattern,
        .impl_scope_id = 0,
        .function_group_ids = &.{},
    };

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = impls,
    };

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(failing_allocator.allocator(), &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    try std.testing.expectError(
        error.OutOfMemory,
        ctx.bindProtocolTypeArgsFromImpl(constraint_type, TypeStore.I64, &subs),
    );
}

test "generic call scan reports TypeStore.unify graph budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const function_name = try interner.intern("cycle");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const param_type = try cyclicListType(&store, alloc);
    const arg_type = try cyclicListType(&store, alloc);
    const span = ast.SourceSpan{ .start = 81, .end = 82 };

    const arg_expr = try testExpr(alloc, .nil_lit, arg_type, span);
    const args = try alloc.alloc(hir.CallArg, 1);
    args[0] = .{ .expr = arg_expr };
    const call_expr = try testExpr(alloc, .{ .call = .{
        .target = .{ .direct = .{ .function_group_id = 41 } },
        .args = args,
    } }, TypeStore.NIL, span);
    const block = try blockWithExpr(alloc, call_expr);

    const decision = try alloc.create(hir.Decision);
    decision.* = .{ .success = .{ .bindings = &.{}, .body_index = 0 } };
    const body = try emptyBlock(alloc);
    const params = try alloc.alloc(hir.TypedParam, 1);
    params[0] = .{
        .name = null,
        .type_id = param_type,
        .pattern = null,
    };
    const clauses = try alloc.alloc(hir.Clause, 1);
    clauses[0] = .{
        .params = params,
        .return_type = TypeStore.NIL,
        .decision = decision,
        .body = body,
        .refinement = null,
        .tuple_bindings = &.{},
    };
    const groups = try alloc.alloc(hir.FunctionGroup, 1);
    groups[0] = .{
        .id = 41,
        .scope_id = 0,
        .name = function_name,
        .arity = 1,
        .clauses = clauses,
        .fallback_parent = null,
    };
    const program = hir.Program{
        .structs = &.{},
        .top_functions = groups,
        .protocols = &.{},
        .impls = &.{},
    };

    var next_group_id: u32 = 42;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);
    try ctx.generic_groups.put(groups[0].id, &groups[0]);

    try ctx.scanBlock(block);

    try std.testing.expectEqual(@as(usize, 1), ctx.errors.items.len);
    try std.testing.expectEqual(@as(usize, 81), ctx.errors.items[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "type graph traversal depth budget") != null);
}

test "monomorphizer reports deep HIR expression scan budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const span = ast.SourceSpan{ .start = 41, .end = 42 };
    const expr = try deepUnaryExpr(alloc, MAX_HIR_STRUCTURE_DEPTH + 2, span);
    const block = try blockWithExpr(alloc, expr);

    try ctx.scanBlock(block);

    try std.testing.expectEqual(@as(usize, 1), ctx.errors.items.len);
    try std.testing.expectEqual(@as(usize, 41), ctx.errors.items[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "HIR scan exceeds maximum HIR nesting depth") != null);
}

test "monomorphizer reports deep pattern local type recording budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const bind_name = try interner.intern("value");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const span = ast.SourceSpan{ .start = 51, .end = 52 };
    const scrutinee = try testExpr(alloc, .{ .int_lit = 1 }, TypeStore.I64, span);
    const pattern = try deepTuplePattern(alloc, MAX_HIR_STRUCTURE_DEPTH + 2, bind_name);
    const bindings = try alloc.alloc(hir.CaseBinding, 1);
    bindings[0] = .{
        .name = bind_name,
        .local_index = 0,
        .kind = .extracted,
        .element_index = 0,
    };
    const arm_body = try emptyBlock(alloc);
    const arms = try alloc.alloc(hir.CaseArm, 1);
    arms[0] = .{
        .pattern = pattern,
        .guard = null,
        .body = arm_body,
        .bindings = bindings,
    };
    const case_expr = try testExpr(alloc, .{ .case = .{
        .scrutinee = scrutinee,
        .arms = arms,
    } }, TypeStore.I64, span);
    const block = try blockWithExpr(alloc, case_expr);

    try ctx.scanBlock(block);

    try std.testing.expectEqual(@as(usize, 1), ctx.errors.items.len);
    try std.testing.expectEqual(@as(usize, 51), ctx.errors.items[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "case pattern local type recording exceeds maximum HIR nesting depth") != null);
}

test "monomorphizer bounds deep decision cloning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const bind_name = try interner.intern("value");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const source_expr = try testExpr(alloc, .{ .int_lit = 1 }, TypeStore.I64, .{ .start = 61, .end = 62 });
    const decision = try deepBindDecision(alloc, MAX_HIR_STRUCTURE_DEPTH + 2, bind_name, source_expr);

    try std.testing.expectError(error.HirStructureTooDeep, ctx.cloneDecision(decision));
}

test "monomorphizer reports deep clone budget failure with generic context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const generic_name = try interner.intern("identity");
    const caller_name = try interner.intern("caller");
    const bind_name = try interner.intern("value");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const type_var = try store.freshVar();
    const source_expr = try testExpr(alloc, .{ .int_lit = 1 }, TypeStore.I64, .{ .start = 70, .end = 71 });
    const deep_decision = try deepBindDecision(alloc, MAX_HIR_STRUCTURE_DEPTH + 2, bind_name, source_expr);

    const generic_body_expr = try testExpr(alloc, .{ .param_get = 0 }, type_var, .{ .start = 72, .end = 73 });
    const generic_body = try blockWithExpr(alloc, generic_body_expr);
    const generic_params = try alloc.alloc(hir.TypedParam, 1);
    generic_params[0] = .{
        .name = null,
        .type_id = type_var,
        .pattern = null,
    };
    const generic_clauses = try alloc.alloc(hir.Clause, 1);
    generic_clauses[0] = .{
        .params = generic_params,
        .return_type = type_var,
        .debug_span = .{ .start = 70, .end = 80 },
        .decision = deep_decision,
        .body = generic_body,
        .refinement = null,
        .tuple_bindings = &.{},
    };

    const call_arg_expr = try testExpr(alloc, .{ .int_lit = 1 }, TypeStore.I64, .{ .start = 81, .end = 82 });
    const call_args = try alloc.alloc(hir.CallArg, 1);
    call_args[0] = .{ .expr = call_arg_expr, .expected_type = TypeStore.I64 };
    const call_expr = try testExpr(alloc, .{ .call = .{
        .target = .{ .direct = .{ .function_group_id = 1 } },
        .args = call_args,
    } }, TypeStore.I64, .{ .start = 81, .end = 82 });
    const caller_body = try blockWithExpr(alloc, call_expr);
    const caller_decision = try alloc.create(hir.Decision);
    caller_decision.* = .{ .success = .{ .bindings = &.{}, .body_index = 0 } };
    const caller_clauses = try alloc.alloc(hir.Clause, 1);
    caller_clauses[0] = .{
        .params = &.{},
        .return_type = TypeStore.I64,
        .debug_span = .{ .start = 81, .end = 90 },
        .decision = caller_decision,
        .body = caller_body,
        .refinement = null,
        .tuple_bindings = &.{},
    };

    const groups = try alloc.alloc(hir.FunctionGroup, 2);
    groups[0] = .{
        .id = 1,
        .scope_id = 0,
        .name = generic_name,
        .arity = 1,
        .debug_span = .{ .start = 70, .end = 80 },
        .clauses = generic_clauses,
        .fallback_parent = null,
    };
    groups[1] = .{
        .id = 2,
        .scope_id = 0,
        .name = caller_name,
        .arity = 0,
        .debug_span = .{ .start = 81, .end = 90 },
        .clauses = caller_clauses,
        .fallback_parent = null,
    };
    const program = hir.Program{
        .structs = &.{},
        .top_functions = groups,
        .protocols = &.{},
        .impls = &.{},
    };

    var next_group_id: u32 = 3;
    const result = try monomorphize(alloc, &program, &store, &next_group_id, &interner);

    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(@as(usize, 81), result.errors[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "clone for generic `identity/1` exceeds maximum HIR nesting depth") != null);
}

test "monomorphizer reports deep rewrite budget exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const program = hir.Program{
        .structs = &.{},
        .top_functions = &.{},
        .protocols = &.{},
        .impls = &.{},
    };
    var next_group_id: u32 = 1;
    var ctx = initTestMonomorphContext(alloc, &store, &interner, &program, &next_group_id);
    defer deinitTestMonomorphContext(&ctx);

    const span = ast.SourceSpan{ .start = 91, .end = 92 };
    const expr = try deepUnaryExpr(alloc, MAX_HIR_STRUCTURE_DEPTH + 2, span);
    const block = try blockWithExpr(alloc, expr);

    try ctx.rewriteBlock(block);

    try std.testing.expectEqual(@as(usize, 1), ctx.errors.items.len);
    try std.testing.expectEqual(@as(usize, 91), ctx.errors.items[0].span.start);
    try std.testing.expect(std.mem.indexOf(u8, ctx.errors.items[0].message, "call-site rewrite exceeds maximum HIR nesting depth") != null);
}

test "monomorphizer specializes generic helper on distinct parametric struct args" {
    // `unbox` is a generic helper taking `Box(T)` and returning `T`.
    // When the program calls `unbox(%Box(i64){value: 1})` and
    // `unbox(%Box(String){value: "x"})`, the monomorphizer must
    // emit two distinct specializations — one keyed on `Box(i64)`,
    // one on `Box(String)`. This is the property IR/ZIR emission
    // depends on to produce per-instantiation runtime types.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn unbox(b :: Box(t)) -> t {
        \\    b.value
        \\  }
        \\  pub fn use_int() -> i64 {
        \\    unbox(%Box(i64){value: 1})
        \\  }
        \\  pub fn use_str() -> String {
        \\    unbox(%Box(String){value: "x"})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = try types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    var next_id: u32 = builder.next_group_id;
    const result = try monomorphize(alloc, &hir_program, checker.store, &next_id, @constCast(parser.interner));

    // `unbox` is specialized once per concrete instantiation of the
    // type variable `t` (the parametric `Box(t)` parameter type
    // unifies through to its inner `t`, which is the binding the
    // monomorphizer keys off). The mangled clone names contain the
    // type-arg encoding chosen by `typeIdToMangledName` — `i64` for
    // i64 and `String` for String — and the calling-struct prefix
    // (`Demo_`) is what `compileStructByStruct` puts in front of
    // cross-struct specializations.
    var unbox_specializations: usize = 0;
    var found_i64 = false;
    var found_string = false;
    for (result.program.structs) |demo| {
        for (demo.functions) |group| {
            const name = parser.interner.get(group.name);
            if (std.mem.indexOf(u8, name, "unbox__") != null) {
                unbox_specializations += 1;
                if (std.mem.endsWith(u8, name, "__i64")) found_i64 = true;
                if (std.mem.endsWith(u8, name, "__String")) found_string = true;
            }
        }
    }
    try std.testing.expect(unbox_specializations >= 2);
    try std.testing.expect(found_i64);
    try std.testing.expect(found_string);
}

test "monomorphizer dedupes specializations for identical parametric args" {
    // Two call sites passing `Box(i64)` must produce one
    // specialization, not two — the hashInstantiation key is the
    // applied TypeId tuple, which TypeStore.addType structurally
    // dedupes, so re-instantiating Box(i64) at a fresh call site
    // returns the same TypeId and the same specialization.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn unbox(b :: Box(t)) -> t {
        \\    b.value
        \\  }
        \\  pub fn a() -> i64 {
        \\    unbox(%Box(i64){value: 1})
        \\  }
        \\  pub fn b() -> i64 {
        \\    unbox(%Box(i64){value: 2})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = try types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    var next_id: u32 = builder.next_group_id;
    const result = try monomorphize(alloc, &hir_program, checker.store, &next_id, @constCast(parser.interner));

    var unbox_specializations: usize = 0;
    for (result.program.structs) |demo| {
        for (demo.functions) |group| {
            const name = parser.interner.get(group.name);
            if (std.mem.indexOf(u8, name, "unbox__") != null) unbox_specializations += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), unbox_specializations);
}

test "monomorphizer transitively scans concrete protocol-constrained helper clones" {
    const source =
        \\pub protocol Enumerable(element) {
        \\  fn next(state :: unique Enumerable(element)) -> {Atom, element, Enumerable(element)}
        \\  fn dispose(state :: unique Enumerable(element)) -> Nil
        \\}
        \\
        \\pub struct Demo {
        \\  pub fn run(collection :: unique Enumerable(i64), expected :: i64) -> Bool {
        \\    member_next(collection, expected)
        \\  }
        \\
        \\  fn member_next(state :: unique Enumerable(element), expected :: element) -> Bool {
        \\    case Enumerable.next(state) {
        \\      {:done, _, _} -> false
        \\      {:cont, value, next_state} ->
        \\        case value == expected {
        \\          true -> dispose_and_return(next_state, true)
        \\          false -> member_next(next_state, expected)
        \\        }
        \\    }
        \\  }
        \\
        \\  fn dispose_and_return(state :: unique Enumerable(element), value :: result) -> result {
        \\    Enumerable.dispose(state)
        \\    value
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var desugarer = @import("desugar.zig").Desugarer.init(alloc, parser.interner, &collector.graph);
    const desugared = try desugarer.desugarProgram(&program);

    var checker = try types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&desugared);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&desugared);

    var next_id: u32 = builder.next_group_id;
    const result = try monomorphize(alloc, &hir_program, checker.store, &next_id, @constCast(parser.interner));

    var saw_member_next_specialization = false;
    var saw_dispose_and_return_specialization = false;
    for (result.program.structs) |module| {
        for (module.functions) |group| {
            const name = parser.interner.get(group.name);
            if (group.id < builder.next_group_id) continue;
            if (std.mem.indexOf(u8, name, "member_next") != null) {
                saw_member_next_specialization = true;
            }
            if (std.mem.indexOf(u8, name, "dispose_and_return") != null) {
                saw_dispose_and_return_specialization = true;
            }
        }
    }

    try std.testing.expect(saw_member_next_specialization);
    try std.testing.expect(saw_dispose_and_return_specialization);
}

fn hirBlockContainsDirectCallTo(block: *const hir.Block, target_group_id: u32) bool {
    for (block.stmts) |statement| {
        switch (statement) {
            .expr => |expression| if (hirExprContainsDirectCallTo(expression, target_group_id)) return true,
            .local_set => |local_set| if (hirExprContainsDirectCallTo(local_set.value, target_group_id)) return true,
            .function_group => |function_group| {
                for (function_group.clauses) |clause| {
                    if (hirBlockContainsDirectCallTo(clause.body, target_group_id)) return true;
                }
            },
        }
    }
    return false;
}

fn hirExprContainsDirectCallTo(expression: *const hir.Expr, target_group_id: u32) bool {
    switch (expression.kind) {
        .call => |call| {
            if (call.target == .direct and call.target.direct.function_group_id == target_group_id) return true;
            for (call.args) |argument| {
                if (hirExprContainsDirectCallTo(argument.expr, target_group_id)) return true;
            }
            if (call.target == .closure) {
                if (hirExprContainsDirectCallTo(call.target.closure, target_group_id)) return true;
            }
        },
        .tuple_init => |elements| for (elements) |element| {
            if (hirExprContainsDirectCallTo(element, target_group_id)) return true;
        },
        .list_init => |elements| for (elements) |element| {
            if (hirExprContainsDirectCallTo(element, target_group_id)) return true;
        },
        .list_cons => |list_cons| {
            if (hirExprContainsDirectCallTo(list_cons.head, target_group_id)) return true;
            if (hirExprContainsDirectCallTo(list_cons.tail, target_group_id)) return true;
        },
        .map_init => |entries| for (entries) |entry| {
            if (hirExprContainsDirectCallTo(entry.key, target_group_id)) return true;
            if (hirExprContainsDirectCallTo(entry.value, target_group_id)) return true;
        },
        .struct_init => |struct_init| for (struct_init.fields) |field| {
            if (hirExprContainsDirectCallTo(field.value, target_group_id)) return true;
        },
        .binary => |binary| {
            if (hirExprContainsDirectCallTo(binary.lhs, target_group_id)) return true;
            if (hirExprContainsDirectCallTo(binary.rhs, target_group_id)) return true;
        },
        .unary => |unary| if (hirExprContainsDirectCallTo(unary.operand, target_group_id)) return true,
        .field_get => |field_get| if (hirExprContainsDirectCallTo(field_get.object, target_group_id)) return true,
        .tuple_index_get => |tuple_index_get| if (hirExprContainsDirectCallTo(tuple_index_get.object, target_group_id)) return true,
        .list_index_get => |list_index_get| if (hirExprContainsDirectCallTo(list_index_get.list, target_group_id)) return true,
        .list_head_get => |list_head_get| if (hirExprContainsDirectCallTo(list_head_get.list, target_group_id)) return true,
        .list_tail_get => |list_tail_get| if (hirExprContainsDirectCallTo(list_tail_get.list, target_group_id)) return true,
        .map_value_get => |map_value_get| {
            if (hirExprContainsDirectCallTo(map_value_get.map, target_group_id)) return true;
            if (hirExprContainsDirectCallTo(map_value_get.key, target_group_id)) return true;
        },
        .branch => |branch| {
            if (hirExprContainsDirectCallTo(branch.condition, target_group_id)) return true;
            if (hirBlockContainsDirectCallTo(branch.then_block, target_group_id)) return true;
            if (branch.else_block) |else_block| {
                if (hirBlockContainsDirectCallTo(else_block, target_group_id)) return true;
            }
        },
        .case => |case_data| {
            if (hirExprContainsDirectCallTo(case_data.scrutinee, target_group_id)) return true;
            for (case_data.arms) |arm| {
                if (arm.guard) |guard| {
                    if (hirExprContainsDirectCallTo(guard, target_group_id)) return true;
                }
                if (hirBlockContainsDirectCallTo(arm.body, target_group_id)) return true;
            }
        },
        .block => |block| if (hirBlockContainsDirectCallTo(&block, target_group_id)) return true,
        .panic => |panic_expression| if (hirExprContainsDirectCallTo(panic_expression, target_group_id)) return true,
        .unwrap => |unwrap_expression| if (hirExprContainsDirectCallTo(unwrap_expression, target_group_id)) return true,
        .union_init => |union_init| if (hirExprContainsDirectCallTo(union_init.value, target_group_id)) return true,
        .error_pipe => |error_pipe| {
            for (error_pipe.steps) |step| {
                if (hirExprContainsDirectCallTo(step.expr, target_group_id)) return true;
            }
            if (hirExprContainsDirectCallTo(error_pipe.handler, target_group_id)) return true;
        },
        .try_rescue => |try_rescue| {
            if (hirBlockContainsDirectCallTo(try_rescue.body, target_group_id)) return true;
            for (try_rescue.arms) |arm| {
                if (arm.guard) |guard| {
                    if (hirExprContainsDirectCallTo(guard, target_group_id)) return true;
                }
                if (hirBlockContainsDirectCallTo(arm.body, target_group_id)) return true;
            }
            if (hirExprContainsDirectCallTo(try_rescue.raise_occurred_call, target_group_id)) return true;
            if (hirExprContainsDirectCallTo(try_rescue.take_raise_call, target_group_id)) return true;
            if (try_rescue.after_block) |after_block| {
                if (hirBlockContainsDirectCallTo(after_block, target_group_id)) return true;
            }
        },
        .ret_raise => |ret_raise| if (hirExprContainsDirectCallTo(ret_raise.stash_call, target_group_id)) return true,
        .match => |match| if (hirExprContainsDirectCallTo(match.scrutinee, target_group_id)) return true,
        .closure_create => |closure_create| for (closure_create.captures) |capture| {
            if (hirExprContainsDirectCallTo(capture.expr, target_group_id)) return true;
        },
        else => {},
    }
    return false;
}

test "monomorphizer rewrites erased protocol helper with concrete result type" {
    const source =
        \\pub protocol Enumerable(element) {
        \\  fn next(state :: unique Enumerable(element)) -> {Atom, element, Enumerable(element)}
        \\  fn dispose(state :: unique Enumerable(element)) -> Nil
        \\}
        \\
        \\pub struct Demo {
        \\  pub fn empty?(collection :: unique Enumerable(element)) -> Bool {
        \\    case Enumerable.next(collection) {
        \\      {:done, _, _} -> true
        \\      {:cont, _, next_state} -> dispose_and_return(next_state, false)
        \\    }
        \\  }
        \\
        \\  fn dispose_and_return(state :: unique Enumerable(element), value :: result) -> result {
        \\    Enumerable.dispose(state)
        \\    value
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var desugarer = @import("desugar.zig").Desugarer.init(alloc, parser.interner, &collector.graph);
    const desugared = try desugarer.desugarProgram(&program);

    var checker = try types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&desugared);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&desugared);

    var next_id: u32 = builder.next_group_id;
    const result = try monomorphize(alloc, &hir_program, checker.store, &next_id, @constCast(parser.interner));

    var dispose_specialization_id: ?u32 = null;
    var empty_group: ?*const hir.FunctionGroup = null;
    for (result.program.structs) |module| {
        for (module.functions) |*group| {
            const name = parser.interner.get(group.name);
            if (std.mem.eql(u8, name, "empty?")) {
                empty_group = group;
            }
            if (group.id >= builder.next_group_id and std.mem.indexOf(u8, name, "dispose_and_return") != null) {
                dispose_specialization_id = group.id;
            }
        }
    }

    const target_id = dispose_specialization_id orelse return error.TestUnexpectedResult;
    const group = empty_group orelse return error.TestUnexpectedResult;
    try std.testing.expect(group.clauses.len > 0);
    try std.testing.expect(hirBlockContainsDirectCallTo(group.clauses[0].body, target_id));
}

test "monomorphizer substitutes field-access type through cloned body" {
    // After specialization, the cloned `unbox` body's `b.value`
    // field_get must report the substituted type (`i64` or `String`),
    // not the raw type variable. This is what IR/ZIR lowering reads
    // to pick storage and emit per-instantiation field-get code.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn unbox(b :: Box(t)) -> t {
        \\    b.value
        \\  }
        \\  pub fn use_int() -> i64 {
        \\    unbox(%Box(i64){value: 1})
        \\  }
        \\  pub fn use_str() -> String {
        \\    unbox(%Box(String){value: "x"})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = try types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    var next_id: u32 = builder.next_group_id;
    const result = try monomorphize(alloc, &hir_program, checker.store, &next_id, @constCast(parser.interner));

    var int_return_seen = false;
    var string_return_seen = false;
    for (result.program.structs) |demo| {
        for (demo.functions) |group| {
            const name = parser.interner.get(group.name);
            if (std.mem.indexOf(u8, name, "unbox__") == null) continue;
            const clause = group.clauses[0];
            if (clause.return_type == types_mod.TypeStore.I64) int_return_seen = true;
            if (clause.return_type == types_mod.TypeStore.STRING) string_return_seen = true;

            // The body's first statement is the `b.value` field_get
            // expression. Its type_id, after cloning + substitution,
            // must match the clone's concrete return type. UNKNOWN
            // would mean the substitution didn't reach the field_get.
            const body_expr = clause.body.stmts[0].expr;
            try std.testing.expectEqual(clause.return_type, body_expr.type_id);
        }
    }
    try std.testing.expect(int_return_seen);
    try std.testing.expect(string_return_seen);
}

test "typeIdToMangledName encodes applied parametric types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const box_name = try interner.intern("Box");
    const pair_name = try interner.intern("Pair");

    var store = try TypeStore.init(alloc, &interner);
    defer store.deinit();

    const box_decl = try store.addType(.{ .struct_type = .{
        .name = box_name,
        .fields = &.{},
        .type_params = &.{},
    } });
    const pair_decl = try store.addType(.{ .struct_type = .{
        .name = pair_name,
        .fields = &.{},
        .type_params = &.{},
    } });

    const i64_args = try alloc.alloc(TypeId, 1);
    i64_args[0] = TypeStore.I64;
    const box_i64 = try store.addType(.{ .applied = .{ .base = box_decl, .args = i64_args } });
    const box_i64_name = try typeIdToMangledName(alloc, &store, box_i64);
    try std.testing.expectEqualStrings("Box_i64", box_i64_name);

    const string_args = try alloc.alloc(TypeId, 1);
    string_args[0] = TypeStore.STRING;
    const box_string = try store.addType(.{ .applied = .{ .base = box_decl, .args = string_args } });
    const box_string_name = try typeIdToMangledName(alloc, &store, box_string);
    try std.testing.expectEqualStrings("Box_String", box_string_name);

    const pair_args = try alloc.alloc(TypeId, 2);
    pair_args[0] = TypeStore.I64;
    pair_args[1] = TypeStore.STRING;
    const pair_i64_string = try store.addType(.{ .applied = .{ .base = pair_decl, .args = pair_args } });
    const pair_i64_string_name = try typeIdToMangledName(alloc, &store, pair_i64_string);
    try std.testing.expectEqualStrings("Pair_i64_String", pair_i64_string_name);
}

/// Convert a TypeId to a short mangled name for function
/// specialization. Delegates to the canonical `types.typeIdMangledName`
/// so the monomorphizer's specialization keys and the IR/ZIR
/// per-instantiation struct/union names stay in lockstep.
///
/// The caller owns the returned slice. Allocation failure is propagated
/// instead of being collapsed to a placeholder type name.
fn typeIdToMangledName(allocator: Allocator, store: *const TypeStore, type_id: TypeId) TypeMangleError![]u8 {
    return try types_mod.typeIdMangledName(allocator, store, type_id);
}

// =============================================================================
// P3-J2 — per-spawn manager-monomorphization pass tests.
// =============================================================================

/// Build a minimal zero-arity function group whose single clause body is
/// `body`. Everything the pass reads (id, name, clauses, reclamation_model) is
/// set; the rest is defaulted. Allocated from `allocator` (an arena in tests).
fn spawnTestGroup(
    allocator: Allocator,
    interner: *ast.StringInterner,
    id: u32,
    name: []const u8,
    body: *const hir.Block,
) !hir.FunctionGroup {
    const decision = try allocator.create(hir.Decision);
    decision.* = .{ .success = .{ .bindings = &.{}, .body_index = 0 } };
    const clauses = try allocator.alloc(hir.Clause, 1);
    clauses[0] = .{
        .params = &.{},
        .return_type = TypeStore.NIL,
        .decision = decision,
        .body = body,
        .refinement = null,
        .tuple_bindings = &.{},
    };
    return .{
        .id = id,
        .scope_id = 0,
        .name = try interner.intern(name),
        .arity = 0,
        .clauses = clauses,
        .fallback_parent = null,
    };
}

/// A body that directly calls `callee_id` (a hot, resolvable edge).
fn directCallBody(allocator: Allocator, callee_id: u32) !*const hir.Block {
    const call_expr = try testExpr(allocator, .{ .call = .{
        .target = .{ .direct = .{ .function_group_id = callee_id } },
        .args = &.{},
    } }, TypeStore.NIL, .{ .start = 0, .end = 0 });
    return blockWithExpr(allocator, call_expr);
}

/// A body that invokes a cross-struct function by NAME — the shape real stdlib
/// callers take (`Enum.sum` → `Range.count`). The model redirect resolves such a
/// named call to a same-model clone and rewrites it as a `.direct` call.
fn namedCallBody(allocator: Allocator, struct_name: []const u8, name: []const u8) !*const hir.Block {
    const call_expr = try testExpr(allocator, .{ .call = .{
        .target = .{ .named = .{ .struct_name = struct_name, .name = name } },
        .args = &.{},
    } }, TypeStore.NIL, .{ .start = 0, .end = 0 });
    return blockWithExpr(allocator, call_expr);
}

/// A body that invokes a value via an indirect closure call (the cold
/// boundary — never model-specialized).
fn closureCallBody(allocator: Allocator) !*const hir.Block {
    const callee = try testExpr(allocator, .{ .local_get = 0 }, TypeStore.NIL, .{ .start = 0, .end = 0 });
    const call_expr = try testExpr(allocator, .{ .call = .{
        .target = .{ .closure = callee },
        .args = &.{},
    } }, TypeStore.NIL, .{ .start = 0, .end = 0 });
    return blockWithExpr(allocator, call_expr);
}

fn findGroupById(program: *const hir.Program, id: u32) ?*const hir.FunctionGroup {
    for (program.top_functions) |*group| {
        if (group.id == id) return group;
    }
    for (program.structs) |*mod| {
        for (mod.functions) |*group| {
            if (group.id == id) return group;
        }
    }
    return null;
}

test "specializeSpawnManagers clones, tags, and redirects a two-function subgraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    // entry (id 1) directly calls helper (id 2). Both are spawn-reachable.
    const helper = try spawnTestGroup(allocator, &interner, 2, "helper", try emptyBlock(allocator));
    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try directCallBody(allocator, 2));

    const groups = try allocator.alloc(hir.FunctionGroup, 2);
    groups[0] = entry;
    groups[1] = helper;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 3;
    // Manifest = ARC; the spawn site runs under Arena (BULK_OR_NEVER).
    const plan = SpawnManagerPlan{
        .manifest_model = .refcounted,
        .specs = &[_]SpawnManagerSpec{.{ .entry_group_id = 1, .model = .bulk_or_never }},
    };

    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    // Two clones (entry + helper) of one model; no cold edge.
    try std.testing.expectEqual(@as(u32, 2), result.specialization_count);
    try std.testing.expectEqual(@as(u32, 1), result.model_count);
    try std.testing.expect(!result.saw_cold_edge);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    // Identity clones always pass the ICF foldability invariant.
    try std.testing.expectEqual(@as(usize, 0), result.foldability_red_flags.len);

    // The entry-specialization maps entry 1 → its Arena clone.
    try std.testing.expectEqual(@as(usize, 1), result.entry_specializations.len);
    const entry_spec = result.entry_specializations[0];
    try std.testing.expectEqual(@as(u32, 1), entry_spec.entry_group_id);
    try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, entry_spec.model);
    try std.testing.expect(entry_spec.specialized_group_id >= 3);

    // The entry clone is tagged Arena and named with the model suffix.
    const entry_clone = findGroupById(&result.program, entry_spec.specialized_group_id).?;
    try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, entry_clone.reclamation_model.?);
    try std.testing.expect(std.mem.endsWith(u8, interner.get(entry_clone.name), "__mm_bulk_or_never"));

    // The entry clone's direct call is REDIRECTED to the helper clone, never
    // back to the manifest-model original (id 2).
    const call = entry_clone.clauses[0].body.stmts[0].expr.kind.call;
    try std.testing.expect(call.target == .direct);
    const redirected_id = call.target.direct.function_group_id;
    try std.testing.expect(redirected_id != 2);
    const helper_clone = findGroupById(&result.program, redirected_id).?;
    try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, helper_clone.reclamation_model.?);
    try std.testing.expect(std.mem.endsWith(u8, interner.get(helper_clone.name), "__mm_bulk_or_never"));

    // The originals are untouched (still manifest-model / untagged).
    const original_entry = findGroupById(&result.program, 1).?;
    try std.testing.expectEqual(@as(?hir.ReclamationModel, null), original_entry.reclamation_model);
    const original_call = original_entry.clauses[0].body.stmts[0].expr.kind.call;
    try std.testing.expectEqual(@as(u32, 2), original_call.target.direct.function_group_id);
}

test "specializeSpawnManagers: manifest-model spawn needs no specialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    const helper = try spawnTestGroup(allocator, &interner, 2, "helper", try emptyBlock(allocator));
    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try directCallBody(allocator, 2));
    const groups = try allocator.alloc(hir.FunctionGroup, 2);
    groups[0] = entry;
    groups[1] = helper;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 3;
    const plan = SpawnManagerPlan{
        .manifest_model = .refcounted,
        .specs = &[_]SpawnManagerSpec{.{ .entry_group_id = 1, .model = .refcounted }},
    };
    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    // No clones; the entry already emits for the manifest (ARC) model.
    try std.testing.expectEqual(@as(u32, 0), result.specialization_count);
    try std.testing.expectEqual(@as(u32, 0), result.model_count);
    try std.testing.expectEqual(@as(usize, 2), result.program.top_functions.len);
    // Identity entry-specialization: the spawn site targets the entry as-is.
    try std.testing.expectEqual(@as(usize, 1), result.entry_specializations.len);
    try std.testing.expectEqual(@as(u32, 1), result.entry_specializations[0].specialized_group_id);
}

test "specializeSpawnManagers: empty plan is a zero-cost no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try emptyBlock(allocator));
    const groups = try allocator.alloc(hir.FunctionGroup, 1);
    groups[0] = entry;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 2;
    const plan = SpawnManagerPlan{ .manifest_model = .refcounted, .specs = &.{} };
    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    try std.testing.expectEqual(@as(u32, 0), result.specialization_count);
    try std.testing.expectEqual(@as(usize, 1), result.program.top_functions.len);
    try std.testing.expectEqual(@as(usize, 0), result.entry_specializations.len);
    // next_group_id untouched — no ids were minted.
    try std.testing.expectEqual(@as(u32, 2), next_group_id);
}

test "specializeSpawnManagers: indirect (closure) edge is the cold boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    // entry (id 1) invokes a value indirectly (closure); helper (id 2) is not
    // reached through a resolvable edge.
    const helper = try spawnTestGroup(allocator, &interner, 2, "helper", try emptyBlock(allocator));
    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try closureCallBody(allocator));
    const groups = try allocator.alloc(hir.FunctionGroup, 2);
    groups[0] = entry;
    groups[1] = helper;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 3;
    const plan = SpawnManagerPlan{
        .manifest_model = .refcounted,
        .specs = &[_]SpawnManagerSpec{.{ .entry_group_id = 1, .model = .bulk_or_never }},
    };
    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    // Only the entry is specialized; the closure edge is cold and flagged.
    try std.testing.expectEqual(@as(u32, 1), result.specialization_count);
    try std.testing.expect(result.saw_cold_edge);
}

test "specializeSpawnManagers: distinct models yield distinct specializations (<=4 bound)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    // Two independent spawn subgraphs: A(1)→helperA(3), B(2)→helperB(4).
    const helper_a = try spawnTestGroup(allocator, &interner, 3, "helper_a", try emptyBlock(allocator));
    const helper_b = try spawnTestGroup(allocator, &interner, 4, "helper_b", try emptyBlock(allocator));
    const entry_a = try spawnTestGroup(allocator, &interner, 1, "worker_a", try directCallBody(allocator, 3));
    const entry_b = try spawnTestGroup(allocator, &interner, 2, "worker_b", try directCallBody(allocator, 4));
    const groups = try allocator.alloc(hir.FunctionGroup, 4);
    groups[0] = entry_a;
    groups[1] = entry_b;
    groups[2] = helper_a;
    groups[3] = helper_b;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 5;
    const plan = SpawnManagerPlan{
        .manifest_model = .refcounted,
        .specs = &[_]SpawnManagerSpec{
            .{ .entry_group_id = 1, .model = .bulk_or_never },
            .{ .entry_group_id = 2, .model = .individual_no_refcount },
        },
    };
    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    // Two models, two subgraphs of two functions each → 4 clones.
    try std.testing.expectEqual(@as(u32, 2), result.model_count);
    try std.testing.expectEqual(@as(u32, 4), result.specialization_count);
    try std.testing.expectEqual(@as(usize, 2), result.entry_specializations.len);

    // Each entry clone carries its own model.
    for (result.entry_specializations) |spec| {
        const clone = findGroupById(&result.program, spec.specialized_group_id).?;
        try std.testing.expectEqual(spec.model, clone.reclamation_model.?);
        switch (spec.entry_group_id) {
            1 => try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, spec.model),
            2 => try std.testing.expectEqual(hir.ReclamationModel.individual_no_refcount, spec.model),
            else => return error.UnexpectedEntry,
        }
    }
}

test "specializeSpawnManagers: unknown entry id is a diagnostic, not a crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try emptyBlock(allocator));
    const groups = try allocator.alloc(hir.FunctionGroup, 1);
    groups[0] = entry;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 2;
    const plan = SpawnManagerPlan{
        .manifest_model = .refcounted,
        .specs = &[_]SpawnManagerSpec{.{ .entry_group_id = 999, .model = .bulk_or_never }},
    };
    const result = try specializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, plan);

    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "unknown entry") != null);
    try std.testing.expectEqual(@as(u32, 0), result.specialization_count);
}

test "modelCloneStructurallyFoldable: redirect-tolerant, flags real divergence (ICF red flag)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);

    // Source: a body directly calling group id 2.
    const source = try spawnTestGroup(allocator, &interner, 1, "worker", try directCallBody(allocator, 2));

    // A FAITHFUL clone whose call was redirected to a different (same-model)
    // group id. The redirected id differs but the structure is identical → the
    // verifier tolerates it (this is exactly what a real model clone looks like).
    const faithful_clone = try spawnTestGroup(allocator, &interner, 10, "worker__mm_bulk_or_never", try directCallBody(allocator, 99));
    try std.testing.expect(modelCloneStructurallyFoldable(&source, &faithful_clone));

    // A DIVERGENT "clone" whose body lost the call statement (a structural
    // difference beyond header ops) → NOT foldable → the ICF red flag fires.
    const empty_divergent = try spawnTestGroup(allocator, &interner, 11, "worker__mm_bulk_or_never", try emptyBlock(allocator));
    try std.testing.expect(!modelCloneStructurallyFoldable(&source, &empty_divergent));

    // A DIVERGENT clone whose call switched variant (direct → closure) — a
    // model-dependent lowering leak — is also flagged.
    const variant_divergent = try spawnTestGroup(allocator, &interner, 12, "worker__mm_bulk_or_never", try closureCallBody(allocator));
    try std.testing.expect(!modelCloneStructurallyFoldable(&source, &variant_divergent));
}

test "modelCloneStructurallyFoldable: a redirected named->direct call is foldable (real cross-struct clone shape)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);

    // Source calls a cross-struct function by NAME — the shape a real stdlib
    // caller takes (`Enum.sum` → `Range.count`). The `.named` targets that the
    // synthetic `directCallBody` tests never exercised are exactly where the
    // model redirect converts a call's VARIANT.
    const source = try spawnTestGroup(allocator, &interner, 1, "worker", try namedCallBody(allocator, "Range", "count"));

    // `redirectCallTargetForModel`'s `.named` arm rewrites a resolvable named
    // call into a `.direct` call on the same-model clone. The variant changed
    // (`.named` → `.direct`) but this is the intended, ICF-neutral redirect —
    // both lower to a direct call to the resolved target. The verifier MUST
    // tolerate it (the regression that fired on every real spawn-reachable
    // stdlib function before the fix).
    const redirected_clone = try spawnTestGroup(allocator, &interner, 10, "worker__mm_bulk_or_never", try directCallBody(allocator, 99));
    try std.testing.expect(modelCloneStructurallyFoldable(&source, &redirected_clone));

    // A named call rewritten to a CLOSURE (a hot→cold boundary change) is a real
    // structural divergence and must still flag — the tolerance is narrow: it
    // admits ONLY the `.named` → `.direct` redirect, nothing else.
    const closure_divergent = try spawnTestGroup(allocator, &interner, 11, "worker__mm_bulk_or_never", try closureCallBody(allocator));
    try std.testing.expect(!modelCloneStructurallyFoldable(&source, &closure_divergent));
}

// -- P3-J3: managed-spawn collection, resolution, rewiring ----------------------

/// Test double for the injected manager resolver: records the name it saw and
/// returns a fixed model + registry index (the driver's job in production).
const MockSpawnResolver = struct {
    model: hir.ReclamationModel,
    registry_index: u32,
    seen_name_buf: [64]u8 = undefined,
    seen_name_len: usize = 0,

    fn resolve(context: *anyopaque, manager_type_name: []const u8) SpawnManagerResolveError!ResolvedSpawnManager {
        const self: *MockSpawnResolver = @ptrCast(@alignCast(context));
        const n = @min(manager_type_name.len, self.seen_name_buf.len);
        @memcpy(self.seen_name_buf[0..n], manager_type_name[0..n]);
        self.seen_name_len = n;
        return .{ .model = self.model, .registry_index = self.registry_index };
    }

    fn seenName(self: *const MockSpawnResolver) []const u8 {
        return self.seen_name_buf[0..self.seen_name_len];
    }
};

const zero_span: ast.SourceSpan = .{ .start = 0, .end = 0 };

/// Build a first-class `Type` value expr (`Memory.<name>`) — a struct-init with
/// a single `name` atom field, exactly `hir.buildTypeValueExpr`'s shape.
fn typeValueExpr(allocator: Allocator, interner: *ast.StringInterner, type_name: []const u8) !*const hir.Expr {
    const name_field = try interner.intern("name");
    const fields = try allocator.alloc(hir.StructFieldInit, 1);
    fields[0] = .{ .name = name_field, .value = try testExpr(allocator, .{ .atom_lit = try interner.intern(type_name) }, TypeStore.UNKNOWN, zero_span) };
    return try testExpr(allocator, .{ .struct_init = .{ .type_id = TypeStore.UNKNOWN, .fields = fields } }, TypeStore.UNKNOWN, zero_span);
}

/// Build a `.{ .manager = <value> }` options struct-init expr.
fn spawnOptionsExpr(allocator: Allocator, interner: *ast.StringInterner, manager_value: *const hir.Expr) !*const hir.Expr {
    const manager_field = try interner.intern("manager");
    const fields = try allocator.alloc(hir.StructFieldInit, 1);
    fields[0] = .{ .name = manager_field, .value = manager_value };
    return try testExpr(allocator, .{ .struct_init = .{ .type_id = TypeStore.UNKNOWN, .fields = fields } }, TypeStore.UNKNOWN, zero_span);
}

/// A body with a managed-spawn call `spawn_process_managed(closure(entry_id), options)`.
fn managedSpawnBody(allocator: Allocator, entry_id: u32, options_expr: *const hir.Expr) !*const hir.Block {
    const entry_closure = try testExpr(allocator, .{ .closure_create = .{ .function_group_id = entry_id, .captures = &.{} } }, TypeStore.NIL, zero_span);
    const args = try allocator.alloc(hir.CallArg, 2);
    args[0] = .{ .expr = entry_closure };
    args[1] = .{ .expr = options_expr };
    const call = try testExpr(allocator, .{ .call = .{ .target = .{ .builtin = MANAGED_SPAWN_BUILTIN }, .args = args } }, TypeStore.UNKNOWN, zero_span);
    return blockWithExpr(allocator, call);
}

test "collectAndSpecializeSpawnManagers rewires a managed spawn to spawn_process_at and specializes the entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    // entry (id 1) is the spawned function; main (id 2) spawns it under Arena.
    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try emptyBlock(allocator));
    const options = try spawnOptionsExpr(allocator, &interner, try typeValueExpr(allocator, &interner, "Memory.Arena"));
    const main = try spawnTestGroup(allocator, &interner, 2, "main", try managedSpawnBody(allocator, 1, options));

    const groups = try allocator.alloc(hir.FunctionGroup, 2);
    groups[0] = entry;
    groups[1] = main;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var mock = MockSpawnResolver{ .model = .bulk_or_never, .registry_index = 1 };
    const resolver = SpawnManagerResolver{ .context = &mock, .resolveFn = MockSpawnResolver.resolve };

    var next_group_id: u32 = 3;
    const result = try collectAndSpecializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, resolver, .refcounted);

    // The manager option was resolved by NAME (capability-driven, no hardcoding).
    try std.testing.expectEqualStrings("Memory.Arena", mock.seenName());

    // A BULK_OR_NEVER specialization of the entry (id 1) was created.
    try std.testing.expectEqual(@as(usize, 1), result.entry_specializations.len);
    const spec = result.entry_specializations[0];
    try std.testing.expectEqual(@as(u32, 1), spec.entry_group_id);
    try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, spec.model);
    const clone = findGroupById(&result.program, spec.specialized_group_id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(hir.ReclamationModel.bulk_or_never, clone.reclamation_model.?);

    // The main body's managed-spawn call was rewritten to
    // `spawn_process_at(closure(clone), 1)`.
    const main_group = findGroupById(&result.program, 2) orelse return error.TestUnexpectedResult;
    const call_expr = main_group.clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expect(call_expr.kind.call.target == .builtin);
    try std.testing.expectEqualStrings(SPAWN_AT_BUILTIN, call_expr.kind.call.target.builtin);
    try std.testing.expectEqual(@as(usize, 2), call_expr.kind.call.args.len);

    const arg0 = call_expr.kind.call.args[0].expr;
    try std.testing.expect(arg0.kind == .closure_create);
    try std.testing.expectEqual(spec.specialized_group_id, arg0.kind.closure_create.function_group_id);

    const arg1 = call_expr.kind.call.args[1].expr;
    try std.testing.expect(arg1.kind == .int_lit);
    try std.testing.expectEqual(@as(i64, 1), arg1.kind.int_lit);
}

test "collectAndSpecializeSpawnManagers: no managed spawns is a byte-for-byte no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    const only = try spawnTestGroup(allocator, &interner, 1, "plain", try emptyBlock(allocator));
    const groups = try allocator.alloc(hir.FunctionGroup, 1);
    groups[0] = only;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var next_group_id: u32 = 2;
    // No resolver at all: with no managed-spawn sites, it is never consulted.
    const result = try collectAndSpecializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, null, .refcounted);
    try std.testing.expectEqual(@as(u32, 0), result.specialization_count);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
    try std.testing.expectEqual(@as(u32, 2), next_group_id); // unchanged
}

test "collectAndSpecializeSpawnManagers: a non-comptime manager is a Decision Gate 0 diagnostic (unmodified program)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interner = ast.StringInterner.init(allocator);
    var store = try TypeStore.init(allocator, &interner);

    // The manager option is a RUNTIME value (a local_get), not a comptime Type.
    const runtime_manager = try testExpr(allocator, .{ .local_get = 0 }, TypeStore.UNKNOWN, zero_span);
    const options = try spawnOptionsExpr(allocator, &interner, runtime_manager);
    const entry = try spawnTestGroup(allocator, &interner, 1, "worker", try emptyBlock(allocator));
    const main = try spawnTestGroup(allocator, &interner, 2, "main", try managedSpawnBody(allocator, 1, options));

    const groups = try allocator.alloc(hir.FunctionGroup, 2);
    groups[0] = entry;
    groups[1] = main;
    const program = hir.Program{ .structs = &.{}, .top_functions = groups };

    var mock = MockSpawnResolver{ .model = .bulk_or_never, .registry_index = 1 };
    const resolver = SpawnManagerResolver{ .context = &mock, .resolveFn = MockSpawnResolver.resolve };

    var next_group_id: u32 = 3;
    const result = try collectAndSpecializeSpawnManagers(allocator, &program, &store, &next_group_id, &interner, resolver, .refcounted);

    // Decision Gate 0: a diagnostic, and the program is left UNMODIFIED (the
    // managed-spawn call is not rewritten — the driver reports and aborts).
    try std.testing.expect(result.errors.len > 0);
    const main_group = findGroupById(&result.program, 2) orelse return error.TestUnexpectedResult;
    const call_expr = main_group.clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind.call.target == .builtin);
    try std.testing.expectEqualStrings(MANAGED_SPAWN_BUILTIN, call_expr.kind.call.target.builtin);
}
