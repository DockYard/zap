const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");
const escape_lattice = @import("escape_lattice.zig");
const ir = @import("ir.zig");
const similarity = @import("similarity.zig");

// ============================================================
// Type representation
// ============================================================

pub const TypeId = u32;
pub const TypeVarId = u32;

pub const Ownership = enum {
    shared,
    unique,
    borrowed,
};

pub const QualifiedType = struct {
    type_id: TypeId,
    ownership: Ownership = .shared,

    pub fn init(type_id: TypeId, ownership: Ownership) QualifiedType {
        return .{ .type_id = type_id, .ownership = ownership };
    }
};

pub const BindingOwnershipState = enum {
    available,
    moved,
    borrowed,
};

pub const BindingOwnershipInfo = struct {
    qualified_type: QualifiedType,
    state: BindingOwnershipState = .available,
    active_borrows: u32 = 0,
};

pub const FunctionSignature = struct {
    params: []const TypeId,
    param_ownerships: []const Ownership,
    return_type: TypeId,
    return_ownership: Ownership = .shared,

    pub fn toFunctionType(self: FunctionSignature) Type.FunctionType {
        return .{
            .params = self.params,
            .return_type = self.return_type,
            .param_ownerships = self.param_ownerships,
            .return_ownership = self.return_ownership,
        };
    }
};

pub const Type = union(enum) {
    // Primitive types
    int: IntType,
    float: FloatType,
    bool_type,
    string_type,
    atom_type,
    nil_type,
    never,

    // Compound types
    tuple: TupleType,
    list: ListType,
    map: MapType,
    struct_type: StructType,
    union_type: UnionType,
    function: FunctionType,

    // Parametric
    type_var: TypeVarId,
    applied: AppliedType,

    // Tagged union
    tagged_union: TaggedUnionType,

    // Opaque
    opaque_type: OpaqueType,

    // Unknown (for inference)
    unknown,
    error_type,

    pub const IntType = struct {
        signedness: enum { signed, unsigned },
        bits: u16,
    };

    pub const FloatType = struct {
        bits: u16,
    };

    pub const TupleType = struct {
        elements: []const TypeId,
    };

    pub const ListType = struct {
        element: TypeId,
    };

    pub const MapType = struct {
        key: TypeId,
        value: TypeId,
    };

    pub const StructType = struct {
        name: ast.StringId,
        fields: []const StructField,
    };

    pub const StructField = struct {
        name: ast.StringId,
        type_id: TypeId,
    };

    pub const UnionType = struct {
        members: []const TypeId,
    };

    pub const FunctionType = struct {
        params: []const TypeId,
        return_type: TypeId,
        param_ownerships: ?[]const Ownership = null,
        return_ownership: Ownership = .shared,
    };

    pub const AppliedType = struct {
        base: TypeId,
        args: []const TypeId,
    };

    pub const TaggedUnionType = struct {
        name: ast.StringId,
        variants: []const TaggedUnionVariant,
    };
    pub const TaggedUnionVariant = struct {
        name: ast.StringId,
        type_id: ?TypeId = null, // null = unit variant
    };

    pub const OpaqueType = struct {
        name: ast.StringId,
        inner: TypeId,
    };
};

// ============================================================
// Type store
// ============================================================

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    interner: *const ast.StringInterner,
    name_to_type: std.AutoHashMap(ast.StringId, TypeId),
    next_var: TypeVarId,

    // Well-known type IDs
    pub const BOOL: TypeId = 0;
    pub const STRING: TypeId = 1;
    pub const ATOM: TypeId = 2;
    pub const NIL: TypeId = 3;
    pub const NEVER: TypeId = 4;
    pub const I64: TypeId = 5;
    pub const I32: TypeId = 6;
    pub const I16: TypeId = 7;
    pub const I8: TypeId = 8;
    pub const U64: TypeId = 9;
    pub const U32: TypeId = 10;
    pub const U16: TypeId = 11;
    pub const U8: TypeId = 12;
    pub const F64: TypeId = 13;
    pub const F32: TypeId = 14;
    pub const F16: TypeId = 15;
    pub const USIZE: TypeId = 16;
    pub const ISIZE: TypeId = 17;
    pub const UNKNOWN: TypeId = 18;
    pub const ERROR: TypeId = 19;

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .types = .empty,
            .interner = interner,
            .name_to_type = std.AutoHashMap(ast.StringId, TypeId).init(allocator),
            .next_var = 0,
        };
        store.registerBuiltins() catch {};
        return store;
    }

    pub fn deinit(self: *TypeStore) void {
        self.types.deinit(self.allocator);
        self.name_to_type.deinit();
    }

    fn registerBuiltins(self: *TypeStore) !void {
        // Must match the order of well-known IDs above
        try self.types.append(self.allocator, .bool_type); // 0
        try self.types.append(self.allocator, .string_type); // 1
        try self.types.append(self.allocator, .atom_type); // 2
        try self.types.append(self.allocator, .nil_type); // 3
        try self.types.append(self.allocator, .never); // 4
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 64 } }); // 5 - i64
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 32 } }); // 6 - i32
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 16 } }); // 7 - i16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 8 } }); // 8 - i8
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 64 } }); // 9 - u64
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 32 } }); // 10 - u32
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 16 } }); // 11 - u16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 8 } }); // 12 - u8
        try self.types.append(self.allocator, .{ .float = .{ .bits = 64 } }); // 13 - f64
        try self.types.append(self.allocator, .{ .float = .{ .bits = 32 } }); // 14 - f32
        try self.types.append(self.allocator, .{ .float = .{ .bits = 16 } }); // 15 - f16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 64 } }); // 16 - usize (platform)
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 64 } }); // 17 - isize (platform)
        try self.types.append(self.allocator, .unknown); // 18
        try self.types.append(self.allocator, .error_type); // 19
    }

    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(self.allocator, typ);
        return id;
    }

    pub fn addFunctionType(
        self: *TypeStore,
        params: []const TypeId,
        return_type: TypeId,
        param_ownerships: ?[]const Ownership,
        return_ownership: Ownership,
    ) !TypeId {
        return try self.addType(.{
            .function = .{
                .params = params,
                .return_type = return_type,
                .param_ownerships = param_ownerships,
                .return_ownership = return_ownership,
            },
        });
    }

    pub fn qualify(_: *const TypeStore, type_id: TypeId, ownership: Ownership) QualifiedType {
        return .{ .type_id = type_id, .ownership = ownership };
    }

    fn ownershipSlicesEqual(a: ?[]const Ownership, b: ?[]const Ownership) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        const lhs = a.?;
        const rhs = b.?;
        if (lhs.len != rhs.len) return false;
        for (lhs, rhs) |lhs_ownership, rhs_ownership| {
            if (lhs_ownership != rhs_ownership) return false;
        }
        return true;
    }

    pub fn getType(self: *const TypeStore, id: TypeId) Type {
        return self.types.items[id];
    }

    pub fn freshVar(self: *TypeStore) !TypeId {
        const var_id = self.next_var;
        self.next_var += 1;
        return try self.addType(.{ .type_var = var_id });
    }

    /// Resolve a type name string to a TypeId
    pub fn resolveTypeName(_: *const TypeStore, name: []const u8) ?TypeId {
        if (std.mem.eql(u8, name, "Bool")) return BOOL;
        if (std.mem.eql(u8, name, "String")) return STRING;
        if (std.mem.eql(u8, name, "Atom")) return ATOM;
        if (std.mem.eql(u8, name, "Nil")) return NIL;
        if (std.mem.eql(u8, name, "Never")) return NEVER;
        if (std.mem.eql(u8, name, "i64")) return I64;
        if (std.mem.eql(u8, name, "i32")) return I32;
        if (std.mem.eql(u8, name, "i16")) return I16;
        if (std.mem.eql(u8, name, "i8")) return I8;
        if (std.mem.eql(u8, name, "u64")) return U64;
        if (std.mem.eql(u8, name, "u32")) return U32;
        if (std.mem.eql(u8, name, "u16")) return U16;
        if (std.mem.eql(u8, name, "u8")) return U8;
        if (std.mem.eql(u8, name, "f64")) return F64;
        if (std.mem.eql(u8, name, "f32")) return F32;
        if (std.mem.eql(u8, name, "f16")) return F16;
        if (std.mem.eql(u8, name, "usize")) return USIZE;
        if (std.mem.eql(u8, name, "isize")) return ISIZE;
        if (std.mem.eql(u8, name, "Expr")) return UNKNOWN; // Macro meta-type
        return null;
    }

    /// Check if two types are compatible.
    /// Returns true if `a` can be used where `b` is expected (or vice versa).
    pub fn typeEquals(self: *const TypeStore, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        const ta = self.getType(a);
        const tb = self.getType(b);

        // Never is a subtype of everything
        if (ta == .never or tb == .never) return true;
        // Unknown matches anything (for inference)
        if (ta == .unknown or tb == .unknown) return true;

        // Structural tuple comparison
        if (ta == .tuple and tb == .tuple) {
            if (ta.tuple.elements.len != tb.tuple.elements.len) return false;
            for (ta.tuple.elements, tb.tuple.elements) |ea, eb| {
                if (!self.typeEquals(ea, eb)) return false;
            }
            return true;
        }

        // Structural list comparison
        if (ta == .list and tb == .list) {
            return self.typeEquals(ta.list.element, tb.list.element);
        }

        // Function comparison includes ownership metadata.
        if (ta == .function and tb == .function) {
            if (ta.function.params.len != tb.function.params.len) return false;
            for (ta.function.params, tb.function.params) |lhs_param, rhs_param| {
                if (!self.typeEquals(lhs_param, rhs_param)) return false;
            }
            if (!self.typeEquals(ta.function.return_type, tb.function.return_type)) return false;
            if (!ownershipSlicesEqual(ta.function.param_ownerships, tb.function.param_ownerships)) return false;
            return ta.function.return_ownership == tb.function.return_ownership;
        }

        // If either side is a union type, check if the other is a member.
        // e.g., String is compatible with String | nil
        if (tb == .union_type) {
            for (tb.union_type.members) |member| {
                if (self.typeEquals(a, member)) return true;
            }
        }
        if (ta == .union_type) {
            for (ta.union_type.members) |member| {
                if (self.typeEquals(member, b)) return true;
            }
        }

        return false;
    }

    /// Check if `sub` is a subtype of `super`
    pub fn isSubtype(self: *const TypeStore, sub: TypeId, super: TypeId) bool {
        if (sub == super) return true;
        const sub_t = self.getType(sub);
        const super_t = self.getType(super);

        // Never is a subtype of everything
        if (sub_t == .never) return true;

        // Union subtyping: sub is a subtype if it's a member of the union
        if (super_t == .union_type) {
            const ut = super_t.union_type;
            for (ut.members) |member| {
                if (self.isSubtype(sub, member)) return true;
            }
        }

        if (sub_t == .function and super_t == .function) {
            return self.typeEquals(sub, super);
        }

        return false;
    }
};

// ============================================================
// Type checker
// ============================================================

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    store: TypeStore,
    interner: *const ast.StringInterner,
    graph: *scope_mod.ScopeGraph,
    errors: std.ArrayList(Error),

    // Expression type mapping
    expr_types: std.AutoHashMap(usize, TypeId),

    // Current scope tracking for var_ref resolution
    current_scope: ?scope_mod.ScopeId,

    // Track which bindings are referenced (for unused variable warnings)
    referenced_bindings: std.AutoHashMap(scope_mod.BindingId, void),

    // Ownership metadata for bindings. Phase 1 stores the foundation here,
    // but enforcement comes later.
    ownership_bindings: std.AutoHashMap(scope_mod.BindingId, BindingOwnershipInfo),
    analysis_context: ?*const escape_lattice.AnalysisContext,
    analysis_program: ?*const ir.Program,

    // Number of stdlib lines prepended (bindings in these lines are skipped for unused checks)
    stdlib_line_count: u32 = 0,

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
        label: ?[]const u8 = null,
        help: ?[]const u8 = null,
        secondary_spans: []const @import("diagnostics.zig").SecondarySpan = &.{},
        /// When set, overrides the pipeline's default severity (e.g. --strict-types).
        /// Hard errors like "undefined type" are always .@"error" regardless of flags.
        severity: ?@import("diagnostics.zig").Severity = null,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner, graph: *scope_mod.ScopeGraph) TypeChecker {
        return .{
            .allocator = allocator,
            .store = TypeStore.init(allocator, interner),
            .interner = interner,
            .graph = graph,
            .errors = .empty,
            .expr_types = std.AutoHashMap(usize, TypeId).init(allocator),
            .current_scope = null,
            .referenced_bindings = std.AutoHashMap(scope_mod.BindingId, void).init(allocator),
            .ownership_bindings = std.AutoHashMap(scope_mod.BindingId, BindingOwnershipInfo).init(allocator),
            .analysis_context = null,
            .analysis_program = null,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.store.deinit();
        self.errors.deinit(self.allocator);
        self.expr_types.deinit();
        self.referenced_bindings.deinit();
        self.ownership_bindings.deinit();
    }

    pub fn setAnalysisContext(self: *TypeChecker, context: *const escape_lattice.AnalysisContext, program: *const ir.Program) void {
        self.analysis_context = context;
        self.analysis_program = program;
    }

    fn defaultOwnershipForType(self: *const TypeChecker, type_id: TypeId) Ownership {
        const typ = self.store.getType(type_id);
        return switch (typ) {
            .opaque_type => .unique,
            else => .shared,
        };
    }

    fn resolveParamOwnership(self: *const TypeChecker, param: ast.Param, resolved_type: TypeId) Ownership {
        if (param.ownership_explicit) {
            return switch (param.ownership) {
                .shared => .shared,
                .unique => .unique,
                .borrowed => .borrowed,
            };
        }
        return switch (param.ownership) {
            .shared => self.defaultOwnershipForType(resolved_type),
            .unique => .unique,
            .borrowed => .borrowed,
        };
    }

    fn mapAstOwnership(ownership: ast.Ownership) Ownership {
        return switch (ownership) {
            .shared => .shared,
            .unique => .unique,
            .borrowed => .borrowed,
        };
    }

    fn recordBindingOwnership(self: *TypeChecker, binding_id: scope_mod.BindingId, type_id: TypeId, ownership: Ownership) !void {
        try self.ownership_bindings.put(binding_id, .{
            .qualified_type = .{ .type_id = type_id, .ownership = ownership },
        });
    }

    fn recordBindingType(self: *TypeChecker, binding_id: scope_mod.BindingId, type_id: TypeId, source_span: ast.SourceSpan) !void {
        self.graph.bindings.items[binding_id].type_id = .{
            .type_id = type_id,
            .ownership = .shared,
            .source_span = source_span,
        };
        try self.recordBindingOwnership(binding_id, type_id, self.defaultOwnershipForType(type_id));
    }

    fn recordBindingQualifiedType(self: *TypeChecker, binding_id: scope_mod.BindingId, qualified_type: QualifiedType, source_span: ast.SourceSpan) !void {
        self.graph.bindings.items[binding_id].type_id = .{
            .type_id = qualified_type.type_id,
            .ownership = switch (qualified_type.ownership) {
                .shared => .shared,
                .unique => .unique,
                .borrowed => .borrowed,
            },
            .source_span = source_span,
        };
        try self.recordBindingOwnership(binding_id, qualified_type.type_id, qualified_type.ownership);
    }

    fn markBindingMoved(self: *TypeChecker, binding_id: scope_mod.BindingId) !void {
        if (self.ownership_bindings.getPtr(binding_id)) |info| {
            info.state = .moved;
            info.active_borrows = 0;
        }
    }

    fn beginBindingBorrow(self: *TypeChecker, binding_id: scope_mod.BindingId) !void {
        if (self.ownership_bindings.getPtr(binding_id)) |info| {
            info.state = .borrowed;
            info.active_borrows += 1;
        }
    }

    fn endBindingBorrow(self: *TypeChecker, binding_id: scope_mod.BindingId) !void {
        if (self.ownership_bindings.getPtr(binding_id)) |info| {
            if (info.active_borrows > 0) info.active_borrows -= 1;
            if (info.active_borrows == 0 and info.state == .borrowed) {
                info.state = .available;
            }
        }
    }

    fn ensureBindingAvailable(self: *TypeChecker, binding_id: scope_mod.BindingId, span: ast.SourceSpan) !bool {
        const info = self.ownership_bindings.get(binding_id) orelse return true;
        if (info.state == .moved) {
            const binding = self.graph.bindings.items[binding_id];
            const name = self.interner.get(binding.name);
            try self.addHardError(
                try std.fmt.allocPrint(self.allocator, "unique value `{s}` was already moved", .{name}),
                span,
                "used after move",
                "this binding must be reassigned or explicitly shared before it can be used again",
            );
            return false;
        }
        return true;
    }

    fn ensureBindingMovable(self: *TypeChecker, binding_id: scope_mod.BindingId, span: ast.SourceSpan) !bool {
        const info = self.ownership_bindings.get(binding_id) orelse return true;
        if (!try self.ensureBindingAvailable(binding_id, span)) return false;
        if (info.active_borrows > 0) {
            const binding = self.graph.bindings.items[binding_id];
            const name = self.interner.get(binding.name);
            try self.addHardError(
                try std.fmt.allocPrint(self.allocator, "cannot move `{s}` while it is borrowed", .{name}),
                span,
                "value is currently borrowed",
                "end the borrow before consuming this value",
            );
            return false;
        }
        return true;
    }

    fn applyCallOwnership(self: *TypeChecker, args: []const *const ast.Expr, fn_type: Type.FunctionType) ![]const scope_mod.BindingId {
        return self.applyCallOwnershipWithSafeParams(args, fn_type, null);
    }

    fn applyCallOwnershipWithSafeParams(self: *TypeChecker, args: []const *const ast.Expr, fn_type: Type.FunctionType, safe_closure_params: ?[]const bool) ![]const scope_mod.BindingId {
        const param_ownerships = fn_type.param_ownerships orelse return &[_]scope_mod.BindingId{};
        if (self.current_scope == null) return &[_]scope_mod.BindingId{};

        const scope_id = self.current_scope.?;
        const count = @min(args.len, param_ownerships.len);
        var borrowed: std.ArrayList(scope_mod.BindingId) = .empty;
        for (args[0..count], param_ownerships[0..count], 0..) |arg, ownership, idx| {
            if (arg.* == .var_ref) {
                if (self.resolveFunctionValueDecl(self.current_scope.?, arg.var_ref.name)) |decl| {
                    if (self.analysis_context != null and self.functionDeclCapturesBorrowed(decl)) {
                        const callee_allows = if (safe_closure_params) |flags|
                            idx < flags.len and flags[idx]
                        else
                            false;
                        if (!callee_allows) {
                            try self.addHardError(
                                "closure with borrowed captures cannot be passed as an argument",
                                arg.getMeta().span,
                                "borrowed capture escapes scope",
                                "call the closure locally instead of passing it beyond the borrow scope",
                            );
                            continue;
                        }
                    }
                }
            }
            if (arg.* != .var_ref) continue;
            const vr = arg.var_ref;
            const binding_id = self.graph.resolveBinding(scope_id, vr.name) orelse continue;

            switch (ownership) {
                .shared => {},
                .unique => {
                    if (self.ownership_bindings.get(binding_id)) |info| {
                        if (info.qualified_type.ownership == .shared) {
                            const binding = self.graph.bindings.items[binding_id];
                            const name = self.interner.get(binding.name);
                            try self.addHardError(
                                try std.fmt.allocPrint(self.allocator, "cannot pass shared value `{s}` to a unique parameter", .{name}),
                                vr.meta.span,
                                "expected unique ownership",
                                "this argument must be uniquely owned before it can be consumed by the callee",
                            );
                            continue;
                        }
                    }
                    if (try self.ensureBindingMovable(binding_id, vr.meta.span)) {
                        try self.markBindingMoved(binding_id);
                    }
                },
                .borrowed => {
                    if (try self.ensureBindingAvailable(binding_id, vr.meta.span)) {
                        try self.beginBindingBorrow(binding_id);
                        try borrowed.append(self.allocator, binding_id);
                    }
                },
            }
        }
        return try borrowed.toOwnedSlice(self.allocator);
    }

    fn endBorrowedBindings(self: *TypeChecker, borrowed_bindings: []const scope_mod.BindingId) !void {
        for (borrowed_bindings) |binding_id| {
            try self.endBindingBorrow(binding_id);
        }
    }

    fn borrowedBindingFromExpr(self: *TypeChecker, expr: *const ast.Expr) ?scope_mod.BindingId {
        if (self.current_scope == null) return null;
        return switch (expr.*) {
            .var_ref => |vr| blk: {
                const binding_id = self.graph.resolveBinding(self.current_scope.?, vr.name) orelse break :blk null;
                const info = self.ownership_bindings.get(binding_id) orelse break :blk null;
                if (info.qualified_type.ownership == .borrowed) break :blk binding_id;
                break :blk null;
            },
            else => null,
        };
    }

    fn sharedOwnershipSlice(self: *TypeChecker, len: usize) ![]const Ownership {
        const ownerships = try self.allocator.alloc(Ownership, len);
        for (ownerships) |*ownership| ownership.* = .shared;
        return ownerships;
    }

    fn buildFunctionType(self: *TypeChecker, params: []const TypeId, return_type: TypeId) !TypeId {
        const param_ownerships = try self.sharedOwnershipSlice(params.len);
        return try self.store.addFunctionType(params, return_type, param_ownerships, .shared);
    }

    fn resolveFamilySignature(self: *TypeChecker, scope_id: scope_mod.ScopeId, name: ast.StringId, arity: u32) !?FunctionSignature {
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];

        var param_types: std.ArrayList(TypeId) = .empty;
        var param_ownerships: std.ArrayList(Ownership) = .empty;
        for (clause.params) |param| {
            const param_type = if (param.type_annotation) |ann|
                try self.resolveTypeExpr(ann)
            else blk: {
                // Generated functions (e.g., __for_N) may lack type annotations.
                // Skip error for generated code (name starts with __ or zero span).
                const func_name = self.interner.get(name);
                const span = param.pattern.getMeta().span;
                const is_generated = std.mem.startsWith(u8, func_name, "__") or (span.start == 0 and span.end == 0);
                if (!is_generated) {
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "parameter requires a type annotation (e.g., `param :: Type`)", .{}),
                        span,
                        "missing type annotation",
                        null,
                    );
                }
                break :blk TypeStore.UNKNOWN;
            };
            try param_types.append(self.allocator, param_type);
            try param_ownerships.append(self.allocator, self.resolveParamOwnership(param, param_type));
        }

        const return_type = if (clause.return_type) |rt|
            try self.resolveTypeExpr(rt)
        else
            TypeStore.UNKNOWN;

        return .{
            .params = try param_types.toOwnedSlice(self.allocator),
            .param_ownerships = try param_ownerships.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .return_ownership = self.defaultOwnershipForType(return_type),
        };
    }

    fn resolveFunctionValueSignature(self: *TypeChecker, scope_id: scope_mod.ScopeId, name: ast.StringId) !?FunctionSignature {
        var current: ?scope_mod.ScopeId = scope_id;
        var found: ?FunctionSignature = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                if (found != null) return null;
                found = try self.resolveFamilySignature(sid, name, key.arity);
            }
            current = self.graph.getScope(sid).parent;
        }
        return found;
    }

    fn isScopeWithinFunctionRoot(self: *const TypeChecker, scope_id: scope_mod.ScopeId, root_scope: scope_mod.ScopeId) bool {
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            if (sid == root_scope) return true;
            current = self.graph.getScope(sid).parent;
        }
        return false;
    }

    fn functionDeclCapturesBorrowed(self: *TypeChecker, func: *const ast.FunctionDecl) bool {
        if (self.analysisFunctionByDecl(func)) |ir_func| {
            for (ir_func.captures) |capture| {
                if (capture.ownership == .borrowed) return true;
            }
        }
        const captured = self.capturedBindingsForFunctionDecl(func) catch return false;
        for (captured) |binding_id| {
            const binding = self.graph.bindings.items[binding_id];
            if (binding.type_id) |prov| if (prov.ownership == .borrowed) return true;
        }
        return false;
    }

    fn analysisFunctionIdByName(self: *const TypeChecker, bare_name: []const u8) ?ir.FunctionId {
        const program = self.analysis_program orelse return null;
        if (self.current_scope) |scope_id| {
            if (self.enclosingModuleQualifiedName(scope_id)) |qualified| {
                defer self.allocator.free(qualified);
                const full = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ qualified, bare_name }) catch return null;
                defer self.allocator.free(full);
                for (program.functions) |func| {
                    if (std.mem.eql(u8, func.name, full)) return func.id;
                }
            }
        }
        for (program.functions) |func| {
            if (std.mem.eql(u8, func.name, bare_name)) return func.id;
        }
        var best_id: ?ir.FunctionId = null;
        var best_score: usize = 0;
        for (program.functions) |func| {
            if (std.mem.endsWith(u8, func.name, bare_name) and func.name.len > bare_name.len and func.name[func.name.len - bare_name.len - 1] == '_' and func.name[func.name.len - bare_name.len - 2] == '_') {
                var score: usize = 1;
                if (self.current_scope) |scope_id| {
                    if (self.enclosingModuleQualifiedName(scope_id)) |qualified| {
                        defer self.allocator.free(qualified);
                        if (std.mem.startsWith(u8, func.name, qualified)) score += qualified.len;
                    }
                }
                if (score > best_score) {
                    best_score = score;
                    best_id = func.id;
                }
            }
        }
        return best_id;
    }

    fn analysisFunctionByDecl(self: *const TypeChecker, decl: *const ast.FunctionDecl) ?ir.Function {
        const name = self.interner.get(decl.name);
        const function_id = self.analysisFunctionIdByName(name) orelse return null;
        const program = self.analysis_program orelse return null;
        for (program.functions) |func| {
            if (func.id == function_id) return func;
        }
        return null;
    }

    fn closureEscapeForDecl(self: *const TypeChecker, decl: *const ast.FunctionDecl) ?escape_lattice.EscapeState {
        const function_id = self.analysisFunctionIdByName(self.interner.get(decl.name)) orelse return null;
        const ctx = self.analysis_context orelse return null;
        const program = self.analysis_program orelse return null;
        return self.findClosureEscape(ctx, program, function_id);
    }

    fn findClosureEscape(self: *const TypeChecker, ctx: *const escape_lattice.AnalysisContext, program: *const ir.Program, closure_func_id: ir.FunctionId) ?escape_lattice.EscapeState {
        _ = self;
        for (program.functions) |func| {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .make_closure => |mc| {
                            if (mc.function == closure_func_id) {
                                return ctx.getEscape(.{ .function = func.id, .local = mc.dest });
                            }
                        },
                        .if_expr => |ie| {
                            if (findClosureEscapeInInstrs(ctx, func.id, ie.then_instrs, closure_func_id)) |escape| return escape;
                            if (findClosureEscapeInInstrs(ctx, func.id, ie.else_instrs, closure_func_id)) |escape| return escape;
                        },
                        .case_block => |cb| {
                            if (findClosureEscapeInInstrs(ctx, func.id, cb.pre_instrs, closure_func_id)) |escape| return escape;
                            for (cb.arms) |arm| {
                                if (findClosureEscapeInInstrs(ctx, func.id, arm.cond_instrs, closure_func_id)) |escape| return escape;
                                if (findClosureEscapeInInstrs(ctx, func.id, arm.body_instrs, closure_func_id)) |escape| return escape;
                            }
                            if (findClosureEscapeInInstrs(ctx, func.id, cb.default_instrs, closure_func_id)) |escape| return escape;
                        },
                        else => {},
                    }
                }
            }
        }
        return .no_escape;
    }

    fn findClosureEscapeInInstrs(ctx: *const escape_lattice.AnalysisContext, func_id: ir.FunctionId, instrs: []const ir.Instruction, closure_func_id: ir.FunctionId) ?escape_lattice.EscapeState {
        for (instrs) |instr| {
            switch (instr) {
                .make_closure => |mc| {
                    if (mc.function == closure_func_id) {
                        return ctx.getEscape(.{ .function = func_id, .local = mc.dest });
                    }
                },
                .if_expr => |ie| {
                    if (findClosureEscapeInInstrs(ctx, func_id, ie.then_instrs, closure_func_id)) |escape| return escape;
                    if (findClosureEscapeInInstrs(ctx, func_id, ie.else_instrs, closure_func_id)) |escape| return escape;
                },
                .case_block => |cb| {
                    if (findClosureEscapeInInstrs(ctx, func_id, cb.pre_instrs, closure_func_id)) |escape| return escape;
                    for (cb.arms) |arm| {
                        if (findClosureEscapeInInstrs(ctx, func_id, arm.cond_instrs, closure_func_id)) |escape| return escape;
                        if (findClosureEscapeInInstrs(ctx, func_id, arm.body_instrs, closure_func_id)) |escape| return escape;
                    }
                    if (findClosureEscapeInInstrs(ctx, func_id, cb.default_instrs, closure_func_id)) |escape| return escape;
                },
                else => {},
            }
        }
        return null;
    }

    fn enclosingModuleQualifiedName(self: *const TypeChecker, scope_id: scope_mod.ScopeId) ?[]u8 {
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            for (self.graph.modules.items) |module| {
                if (module.scope_id != sid) continue;
                return self.moduleNameToString(module.name);
            }
            current = self.graph.getScope(sid).parent;
        }
        return null;
    }

    fn moduleNameToString(self: *const TypeChecker, name: ast.ModuleName) []u8 {
        if (name.parts.len == 0) return self.allocator.alloc(u8, 0) catch return &[_]u8{};
        var total_len: usize = 0;
        for (name.parts, 0..) |part, idx| {
            total_len += self.interner.get(part).len;
            if (idx > 0) total_len += 2;
        }
        const buffer = self.allocator.alloc(u8, total_len) catch return &[_]u8{};
        var offset: usize = 0;
        for (name.parts, 0..) |part, idx| {
            if (idx > 0) {
                buffer[offset] = '_';
                buffer[offset + 1] = '_';
                offset += 2;
            }
            const piece = self.interner.get(part);
            @memcpy(buffer[offset .. offset + piece.len], piece);
            offset += piece.len;
        }
        return buffer;
    }

    fn closureDeclFromExpr(self: *TypeChecker, expr: *const ast.Expr) ?*const ast.FunctionDecl {
        if (expr.* != .var_ref or self.current_scope == null) return null;
        return self.resolveFunctionValueDecl(self.current_scope.?, expr.var_ref.name);
    }

    fn safeClosureParamsForCurrentCallee(self: *const TypeChecker, callee_name: ast.StringId, arity: u32) ?[]const bool {
        if (self.current_scope) |scope_id| {
            if (self.graph.resolveFamily(scope_id, callee_name, arity)) |family_id| {
                return self.safeClosureParamsForFamily(family_id);
            }
        }

        const bare_name = self.interner.get(callee_name);
        const function_id = self.analysisFunctionIdByName(bare_name) orelse return null;
        const ctx = self.analysis_context orelse return null;
        const summary = ctx.function_summaries.get(function_id) orelse return null;
        const safe = self.allocator.alloc(bool, summary.param_summaries.len) catch return null;
        for (summary.param_summaries, 0..) |param_summary, i| {
            var returned = false;
            for (summary.return_summary.param_sources) |src_idx| {
                if (src_idx == i) {
                    returned = true;
                    break;
                }
            }
            safe[i] = !param_summary.escapes() and !returned;
        }
        return safe;
    }

    fn safeClosureParamsForFamily(self: *const TypeChecker, family_id: scope_mod.FunctionFamilyId) ?[]const bool {
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;

        const first_clause = family.clauses.items[0];
        if (first_clause.clause_index >= first_clause.decl.clauses.len) return null;
        const params = first_clause.decl.clauses[first_clause.clause_index].params;
        const safe = self.allocator.alloc(bool, params.len) catch return null;
        @memset(safe, true);

        for (family.clauses.items) |clause_ref| {
            if (clause_ref.clause_index >= clause_ref.decl.clauses.len) continue;
            const clause = clause_ref.decl.clauses[clause_ref.clause_index];
            for (clause.params, 0..) |param, idx| {
                const param_name = switch (param.pattern.*) {
                    .bind => |b| b.name,
                    else => continue,
                };
                if (!self.isClosureParamUsedLocally(clause.body orelse &.{}, param_name)) {
                    safe[idx] = false;
                }
            }
        }

        return safe;
    }

    fn isClosureParamUsedLocally(self: *const TypeChecker, body: []const ast.Stmt, param_name: ast.StringId) bool {
        for (body) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    if (self.exprUsesClosureParamUnsafely(expr, param_name, false)) return false;
                },
                .assignment => |assign| {
                    if (self.exprUsesClosureParamUnsafely(assign.value, param_name, false)) return false;
                },
                .function_decl, .macro_decl, .import_decl => {},
            }
        }
        return true;
    }

    fn exprUsesClosureParamUnsafely(self: *const TypeChecker, expr: *const ast.Expr, param_name: ast.StringId, allow_direct_callee: bool) bool {
        switch (expr.*) {
            .var_ref => |vr| return vr.name == param_name and !allow_direct_callee,
            .call => |call| {
                if (self.exprUsesClosureParamUnsafely(call.callee, param_name, true)) return true;
                for (call.args) |arg| {
                    if (self.exprUsesClosureParamUnsafely(arg, param_name, false)) return true;
                }
                return false;
            },
            .tuple => |tuple_expr| {
                for (tuple_expr.elements) |elem| {
                    if (self.exprUsesClosureParamUnsafely(elem, param_name, false)) return true;
                }
                return false;
            },
            .list => |list_expr| {
                for (list_expr.elements) |elem| {
                    if (self.exprUsesClosureParamUnsafely(elem, param_name, false)) return true;
                }
                return false;
            },
            .map => |map_expr| {
                for (map_expr.fields) |field| {
                    if (self.exprUsesClosureParamUnsafely(field.key, param_name, false)) return true;
                    if (self.exprUsesClosureParamUnsafely(field.value, param_name, false)) return true;
                }
                return false;
            },
            .struct_expr => |struct_expr| {
                if (struct_expr.update_source) |source| {
                    if (self.exprUsesClosureParamUnsafely(source, param_name, false)) return true;
                }
                for (struct_expr.fields) |field| {
                    if (self.exprUsesClosureParamUnsafely(field.value, param_name, false)) return true;
                }
                return false;
            },
            .binary_op => |bo| return self.exprUsesClosureParamUnsafely(bo.lhs, param_name, false) or self.exprUsesClosureParamUnsafely(bo.rhs, param_name, false),
            .unary_op => |uo| return self.exprUsesClosureParamUnsafely(uo.operand, param_name, false),
            .field_access => |fa| return self.exprUsesClosureParamUnsafely(fa.object, param_name, false),
            .pipe => |pipe| return self.exprUsesClosureParamUnsafely(pipe.lhs, param_name, false) or self.exprUsesClosureParamUnsafely(pipe.rhs, param_name, false),
            .unwrap => |uw| return self.exprUsesClosureParamUnsafely(uw.expr, param_name, false),
            .type_annotated => |ta| return self.exprUsesClosureParamUnsafely(ta.expr, param_name, false),
            .if_expr => |ie| {
                if (self.exprUsesClosureParamUnsafely(ie.condition, param_name, false)) return true;
                if (!self.isClosureParamUsedLocally(ie.then_block, param_name)) return true;
                if (ie.else_block) |else_block| if (!self.isClosureParamUsedLocally(else_block, param_name)) return true;
                return false;
            },
            .block => |block| return !self.isClosureParamUsedLocally(block.stmts, param_name),
            .cond_expr => |cond_expr| {
                for (cond_expr.clauses) |clause| {
                    if (self.exprUsesClosureParamUnsafely(clause.condition, param_name, false)) return true;
                    if (!self.isClosureParamUsedLocally(clause.body, param_name)) return true;
                }
                return false;
            },
            .case_expr, .panic_expr, .quote_expr, .unquote_expr, .intrinsic, .attr_ref, .binary_literal, .function_ref => return true,
            else => return false,
        }
    }

    fn ensureClosureValueCanEscape(self: *TypeChecker, expr: *const ast.Expr, context: []const u8) !void {
        const decl = self.closureDeclFromExpr(expr) orelse return;
        if (!self.functionDeclCapturesBorrowed(decl)) return;
        try self.addHardError(
            try std.fmt.allocPrint(self.allocator, "closure with borrowed captures cannot escape via {s}", .{context}),
            expr.getMeta().span,
            "borrowed capture escapes scope",
            "avoid storing or returning closures that capture borrowed values",
        );
    }

    fn collectCapturedBindingsFromExpr(self: *TypeChecker, expr: *const ast.Expr, function_scope: scope_mod.ScopeId, captured: *std.AutoHashMap(scope_mod.BindingId, void)) anyerror!void {
        switch (expr.*) {
            .var_ref => |vr| {
                const binding_id = self.graph.resolveBinding(function_scope, vr.name) orelse return;
                const binding = self.graph.bindings.items[binding_id];
                if (!self.isScopeWithinFunctionRoot(binding.scope_id, function_scope)) {
                    try captured.put(binding_id, {});
                }
            },
            .binary_op => |bo| {
                try self.collectCapturedBindingsFromExpr(bo.lhs, function_scope, captured);
                try self.collectCapturedBindingsFromExpr(bo.rhs, function_scope, captured);
            },
            .unary_op => |uo| try self.collectCapturedBindingsFromExpr(uo.operand, function_scope, captured),
            .call => |call| {
                try self.collectCapturedBindingsFromExpr(call.callee, function_scope, captured);
                for (call.args) |arg| try self.collectCapturedBindingsFromExpr(arg, function_scope, captured);
            },
            .field_access => |fa| try self.collectCapturedBindingsFromExpr(fa.object, function_scope, captured),
            .if_expr => |ie| {
                try self.collectCapturedBindingsFromExpr(ie.condition, function_scope, captured);
                for (ie.then_block) |stmt| try self.collectCapturedBindingsFromStmt(stmt, function_scope, captured);
                if (ie.else_block) |eb| for (eb) |stmt| try self.collectCapturedBindingsFromStmt(stmt, function_scope, captured);
            },
            .case_expr => |ce| {
                try self.collectCapturedBindingsFromExpr(ce.scrutinee, function_scope, captured);
                for (ce.clauses) |clause| {
                    if (clause.guard) |g| try self.collectCapturedBindingsFromExpr(g, function_scope, captured);
                    for (clause.body) |stmt| try self.collectCapturedBindingsFromStmt(stmt, function_scope, captured);
                }
            },
            .tuple => |items| for (items.elements) |item| try self.collectCapturedBindingsFromExpr(item, function_scope, captured),
            .list => |items| for (items.elements) |item| try self.collectCapturedBindingsFromExpr(item, function_scope, captured),
            .map => |items| for (items.fields) |item| {
                try self.collectCapturedBindingsFromExpr(item.key, function_scope, captured);
                try self.collectCapturedBindingsFromExpr(item.value, function_scope, captured);
            },
            .struct_expr => |sl| for (sl.fields) |field| try self.collectCapturedBindingsFromExpr(field.value, function_scope, captured),
            else => {},
        }
    }

    fn collectCapturedBindingsFromStmt(self: *TypeChecker, stmt: ast.Stmt, function_scope: scope_mod.ScopeId, captured: *std.AutoHashMap(scope_mod.BindingId, void)) anyerror!void {
        switch (stmt) {
            .expr => |e| try self.collectCapturedBindingsFromExpr(e, function_scope, captured),
            .assignment => |a| try self.collectCapturedBindingsFromExpr(a.value, function_scope, captured),
            .function_decl => {},
            else => {},
        }
    }

    fn capturedBindingsForFunctionDecl(self: *TypeChecker, func: *const ast.FunctionDecl) ![]scope_mod.BindingId {
        var captured = std.AutoHashMap(scope_mod.BindingId, void).init(self.allocator);
        defer captured.deinit();
        for (func.clauses) |clause| {
            const function_scope = self.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
            if (clause.body) |body| {
                for (body) |stmt| {
                    try self.collectCapturedBindingsFromStmt(stmt, function_scope, &captured);
                }
            }
        }
        var result = std.ArrayList(scope_mod.BindingId).empty;
        var it = captured.iterator();
        while (it.next()) |entry| {
            try result.append(self.allocator, entry.key_ptr.*);
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn resolveFunctionValueDecl(self: *TypeChecker, scope_id: scope_mod.ScopeId, name: ast.StringId) ?*const ast.FunctionDecl {
        var current: ?scope_mod.ScopeId = scope_id;
        var found: ?*const ast.FunctionDecl = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                const family = self.graph.getFamily(entry.value_ptr.*);
                if (family.clauses.items.len == 0) continue;
                const decl = family.clauses.items[0].decl;
                if (found != null and found != decl) return null;
                found = decl;
            }
            current = self.graph.getScope(sid).parent;
        }
        return found;
    }

    pub fn bindingOwnershipInfo(self: *const TypeChecker, binding_id: scope_mod.BindingId) ?BindingOwnershipInfo {
        return self.ownership_bindings.get(binding_id);
    }

    fn addError(self: *TypeChecker, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    fn addRichError(self: *TypeChecker, message: []const u8, span: ast.SourceSpan, label_text: ?[]const u8, help_text: ?[]const u8) !void {
        try self.errors.append(self.allocator, .{
            .message = message,
            .span = span,
            .label = label_text,
            .help = help_text,
        });
    }

    fn addHardError(self: *TypeChecker, message: []const u8, span: ast.SourceSpan, label_text: ?[]const u8, help_text: ?[]const u8) !void {
        try self.errors.append(self.allocator, .{
            .message = message,
            .span = span,
            .label = label_text,
            .help = help_text,
            .severity = .@"error",
        });
    }

    fn addFormattedError(self: *TypeChecker, span: ast.SourceSpan, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.addError(msg, span);
    }

    /// Convert a TypeId to a human-readable string
    pub fn typeToString(self: *const TypeChecker, type_id: TypeId) []const u8 {
        if (type_id == TypeStore.BOOL) return "Bool";
        if (type_id == TypeStore.STRING) return "String";
        if (type_id == TypeStore.ATOM) return "Atom";
        if (type_id == TypeStore.NIL) return "Nil";
        if (type_id == TypeStore.NEVER) return "Never";
        if (type_id == TypeStore.I64) return "i64";
        if (type_id == TypeStore.I32) return "i32";
        if (type_id == TypeStore.I16) return "i16";
        if (type_id == TypeStore.I8) return "i8";
        if (type_id == TypeStore.U64) return "u64";
        if (type_id == TypeStore.U32) return "u32";
        if (type_id == TypeStore.U16) return "u16";
        if (type_id == TypeStore.U8) return "u8";
        if (type_id == TypeStore.F64) return "f64";
        if (type_id == TypeStore.F32) return "f32";
        if (type_id == TypeStore.F16) return "f16";
        if (type_id == TypeStore.USIZE) return "usize";
        if (type_id == TypeStore.ISIZE) return "isize";
        if (type_id == TypeStore.UNKNOWN) return "{unknown}";
        if (type_id == TypeStore.ERROR) return "{error}";
        // Look up user-defined and compound types
        if (type_id < self.store.types.items.len) {
            const typ = self.store.types.items[type_id];
            switch (typ) {
                .struct_type => |st| return self.interner.get(st.name),
                .tagged_union => |tu| return self.interner.get(tu.name),
                .union_type => |ut| {
                    var buf: std.ArrayList(u8) = .empty;
                    for (ut.members, 0..) |member, i| {
                        if (i > 0) buf.appendSlice(self.allocator, " | ") catch return "{type}";
                        buf.appendSlice(self.allocator, self.typeToString(member)) catch return "{type}";
                    }
                    return buf.toOwnedSlice(self.allocator) catch return "{type}";
                },
                else => {},
            }
        }
        return "{type}";
    }

    // ============================================================
    // Program type checking
    // ============================================================

    pub fn checkProgram(self: *TypeChecker, program: *const ast.Program) !void {
        // Register user-defined types (structs, enums) from scope graph into TypeStore
        try self.registerUserTypes();

        for (program.modules) |*mod| {
            try self.checkModule(mod);
        }
        for (program.top_items) |item| {
            // Only `def main()` is allowed at the top level — all other functions must be inside a module
            switch (item) {
                .function => |func| {
                    const name = self.interner.get(func.name);
                    if (!std.mem.eql(u8, name, "main")) {
                        try self.addHardError(
                            try std.fmt.allocPrint(self.allocator, "top-level function `{s}` is not allowed — only `def main()` can be defined outside a module", .{name}),
                            func.meta.span,
                            "move this function into a `module` block",
                            "all functions except `main` must be defined inside a `module { ... }` block",
                        );
                    }
                },
                .priv_function => |func| {
                    const name = self.interner.get(func.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level private function `{s}` is not allowed — functions must be inside a module", .{name}),
                        func.meta.span,
                        "move this function into a `module` block",
                        "all functions must be defined inside a `module { ... }` block",
                    );
                },
                .macro => |mac| {
                    const name = self.interner.get(mac.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level macro `{s}` is not allowed — macros must be inside a module", .{name}),
                        mac.meta.span,
                        "move this macro into a `module` block",
                        "all macros must be defined inside a `module { ... }` block",
                    );
                },
                .priv_macro => |mac| {
                    const name = self.interner.get(mac.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level private macro `{s}` is not allowed — macros must be inside a module", .{name}),
                        mac.meta.span,
                        "move this macro into a `module` block",
                        "all macros must be defined inside a `module { ... }` block",
                    );
                },
                else => {},
            }
            try self.checkTopItem(item);
        }
    }

    fn registerUserTypes(self: *TypeChecker) !void {
        for (self.graph.types.items) |type_entry| {
            switch (type_entry.kind) {
                .struct_type => |sd| {
                    const name = sd.name orelse continue;
                    // Check if the name conflicts with a builtin type
                    const name_str = self.interner.get(name);
                    if (self.store.resolveTypeName(name_str) != null) {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{name_str}),
                            .span = sd.meta.span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{name_str}),
                            .severity = .warning,
                        });
                        continue; // builtin wins
                    }
                    // Build struct fields with resolved types
                    var fields: std.ArrayList(Type.StructField) = .empty;
                    // First collect parent fields if extends
                    if (sd.parent) |parent_name| {
                        if (self.graph.resolveTypeByName(parent_name)) |parent_scope_tid| {
                            const parent_entry = self.graph.types.items[parent_scope_tid];
                            if (parent_entry.kind == .struct_type) {
                                const parent_sd = parent_entry.kind.struct_type;
                                for (parent_sd.fields) |field| {
                                    const field_type = self.resolveTypeExpr(field.type_expr) catch TypeStore.UNKNOWN;
                                    try fields.append(self.allocator, .{
                                        .name = field.name,
                                        .type_id = field_type,
                                    });
                                }
                            }
                        }
                    }
                    // Then add own fields (may override parent defaults but type check happens here)
                    for (sd.fields) |field| {
                        const field_type = self.resolveTypeExpr(field.type_expr) catch TypeStore.UNKNOWN;
                        // Check if this field already exists from parent
                        var found_parent = false;
                        for (fields.items) |*pf| {
                            if (pf.name == field.name) {
                                // Validate type doesn't change
                                if (pf.type_id != field_type and pf.type_id != TypeStore.UNKNOWN and field_type != TypeStore.UNKNOWN) {
                                    try self.addHardError(
                                        try std.fmt.allocPrint(self.allocator, "field `{s}` type cannot be changed in extends", .{self.interner.get(field.name)}),
                                        field.meta.span,
                                        "type mismatch with parent field",
                                        "the parent struct defines this field with a different type",
                                    );
                                }
                                found_parent = true;
                                break;
                            }
                        }
                        if (!found_parent) {
                            try fields.append(self.allocator, .{
                                .name = field.name,
                                .type_id = field_type,
                            });
                        }
                    }
                    const type_id = try self.store.addType(.{ .struct_type = .{
                        .name = name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                    } });
                    try self.store.name_to_type.put(name, type_id);
                },
                .union_type => |ud| {
                    // Check if the name conflicts with a builtin type
                    const enum_name_str = self.interner.get(ud.name);
                    if (self.store.resolveTypeName(enum_name_str) != null) {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{enum_name_str}),
                            .span = ud.meta.span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{enum_name_str}),
                            .severity = .warning,
                        });
                        continue; // builtin wins
                    }
                    var variant_entries: std.ArrayList(Type.TaggedUnionVariant) = .empty;
                    for (ud.variants) |v| {
                        const vtype = if (v.type_expr) |te|
                            self.resolveTypeExpr(te) catch null
                        else
                            null;
                        try variant_entries.append(self.allocator, .{
                            .name = v.name,
                            .type_id = vtype,
                        });
                    }
                    const type_id = try self.store.addType(.{ .tagged_union = .{
                        .name = ud.name,
                        .variants = try variant_entries.toOwnedSlice(self.allocator),
                    } });
                    try self.store.name_to_type.put(ud.name, type_id);
                },
                .opaque_type => |opaque_body| {
                    const opaque_name_str = self.interner.get(type_entry.name);
                    if (self.store.resolveTypeName(opaque_name_str) != null) {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{opaque_name_str}),
                            .span = type_entry.kind.opaque_type.getMeta().span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{opaque_name_str}),
                            .severity = .warning,
                        });
                        continue;
                    }

                    const inner_type = try self.resolveTypeExpr(opaque_body);
                    const type_id = try self.store.addType(.{ .opaque_type = .{
                        .name = type_entry.name,
                        .inner = inner_type,
                    } });
                    try self.store.name_to_type.put(type_entry.name, type_id);
                },
                else => {},
            }
        }
    }

    pub fn checkUnusedBindings(self: *TypeChecker) !void {
        for (self.graph.bindings.items, 0..) |binding, i| {
            const bid: scope_mod.BindingId = @intCast(i);
            if (self.referenced_bindings.contains(bid)) continue;

            const name = self.interner.get(binding.name);
            if (name.len > 0 and name[0] == '_') continue; // _-prefix convention
            if (binding.scope_id == self.graph.prelude_scope) continue; // stdlib
            if (binding.span.line == 0) continue; // synthetic

            // Skip bindings from stdlib (before user source)
            if (self.stdlib_line_count > 0 and binding.span.line > 0 and binding.span.line <= self.stdlib_line_count) continue;

            // Skip bindings in case clause scopes (pattern match variables)
            const binding_scope = self.graph.getScope(binding.scope_id);
            if (binding_scope.kind == .case_clause) continue;

            try self.addRichError(
                try std.fmt.allocPrint(self.allocator, "variable `{s}` is unused", .{name}),
                binding.span,
                "defined here but never used",
                try std.fmt.allocPrint(self.allocator, "if this is intentional, prefix with underscore: `_{s}`", .{name}),
            );
        }
    }

    fn checkModule(self: *TypeChecker, mod: *const ast.ModuleDecl) !void {
        const prev_scope = self.current_scope;
        self.current_scope = self.graph.node_scope_map.get(mod.meta.span.start) orelse mod.meta.scope_id;
        defer self.current_scope = prev_scope;

        // Check module extends: validate overridden function return types match parent
        if (mod.parent) |parent_name| {
            try self.checkModuleExtendsSignatures(mod, parent_name);
        }

        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    try self.checkFunctionDecl(func);
                    if (self.current_scope) |cs| try self.checkDebugAttribute(func, cs);
                },
                .priv_function => |func| {
                    try self.checkFunctionDecl(func);
                    if (self.current_scope) |cs| try self.checkDebugAttribute(func, cs);
                },
                .macro, .priv_macro => |mac| {
                    // Mark macro params as referenced — they're used in quote/unquote,
                    // not via normal var_ref, so the unused-binding check can't see them.
                    // Macro bodies are compile-time code and are NOT type-checked.
                    for (mac.clauses) |clause| {
                        const macro_scope = self.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
                        for (clause.params) |param| {
                            if (param.pattern.* == .bind) {
                                if (self.graph.resolveBinding(macro_scope, param.pattern.bind.name)) |bid| {
                                    try self.referenced_bindings.put(bid, {});
                                }
                            }
                        }
                    }
                },
                .attribute => |attr| {
                    try self.checkAttributeDecl(attr);
                },
                else => {},
            }
        }
    }

    fn checkAttributeDecl(self: *TypeChecker, attr: *const ast.AttributeDecl) !void {
        // For typed attributes (@name :: Type = value), validate the value against the type
        if (attr.type_expr != null and attr.value != null) {
            const declared_type = self.resolveTypeExpr(attr.type_expr.?) catch return;
            const attr_name = self.interner.get(attr.name);

            // Infer the type of the value from its literal form
            const value_type = literalType(attr.value.?);

            if (declared_type != TypeStore.UNKNOWN and value_type != TypeStore.UNKNOWN) {
                if (declared_type != value_type) {
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator,
                            "@{s} declared as {s}, but value has type {s}",
                            .{ attr_name, self.typeToString(declared_type), self.typeToString(value_type) },
                        ),
                        attr.meta.span,
                        "type mismatch in attribute value",
                        "the value must match the declared type",
                    );
                }
            }
        } else if (attr.type_expr == null and attr.value == null) {
            // Marker attribute — valid
            // For @debug, validate that it's on a function with T -> T semantics
            // (This validation is done later when we see the function declaration)
        } else if (attr.type_expr == null and attr.value != null) {
            // Value attribute without type (e.g., @native = "ZestRuntime.reset") — valid
        } else {
            // Type without value — should not happen
            const attr_name = self.interner.get(attr.name);
            try self.addHardError(
                try std.fmt.allocPrint(self.allocator,
                    "@{s}: typed attributes must have both a type and a value",
                    .{attr_name},
                ),
                attr.meta.span,
                null,
                "use @name :: Type = value",
            );
        }
    }

    /// Check if a function has @debug attribute and validate pass-through semantics.
    fn checkDebugAttribute(self: *TypeChecker, func: *const ast.FunctionDecl, mod_scope: scope_mod.ScopeId) !void {
        if (func.clauses.len == 0) return;
        const arity: u32 = @intCast(func.clauses[0].params.len);
        const key = scope_mod.FamilyKey{ .name = func.name, .arity = arity };
        const parent = self.graph.scopes.items[mod_scope];
        const fid = parent.function_families.get(key) orelse return;
        const family = self.graph.families.items[fid];

        // Check if this function has @debug
        var has_debug = false;
        for (family.attributes.items) |attr| {
            if (std.mem.eql(u8, self.interner.get(attr.name), "debug")) {
                has_debug = true;
                break;
            }
        }

        if (!has_debug) return;

        // Validate: @debug functions must have exactly one parameter
        if (arity != 1) {
            try self.addHardError(
                try std.fmt.allocPrint(self.allocator,
                    "@debug function `{s}` must have exactly one parameter, found {d}",
                    .{ self.interner.get(func.name), arity },
                ),
                func.meta.span,
                "@debug requires pass-through semantics (T -> T)",
                "the function must take one argument and return the same type",
            );
            return;
        }

        // Validate: return type must match parameter type
        // (For now, we check that a return type is declared — the T -> T check
        // requires generic type resolution which is a future enhancement)
        for (func.clauses) |clause| {
            if (clause.return_type == null) {
                try self.addHardError(
                    try std.fmt.allocPrint(self.allocator,
                        "@debug function `{s}` must declare a return type",
                        .{self.interner.get(func.name)},
                    ),
                    func.meta.span,
                    "@debug requires explicit return type",
                    "add :: T after the parameter list",
                );
            }
        }
    }

    /// Infer the type of a literal expression for attribute type checking.
    fn literalType(expr: *const ast.Expr) TypeId {
        return switch (expr.*) {
            .int_literal => TypeStore.I64,
            .float_literal => TypeStore.F64,
            .string_literal => TypeStore.STRING,
            .atom_literal => TypeStore.ATOM,
            .bool_literal => TypeStore.BOOL,
            .nil_literal => TypeStore.NIL,
            else => TypeStore.UNKNOWN,
        };
    }

    fn checkModuleExtendsSignatures(self: *TypeChecker, mod: *const ast.ModuleDecl, parent_name: ast.StringId) !void {
        // Find parent module
        var parent_mod: ?*const ast.ModuleDecl = null;
        for (self.graph.modules.items) |mod_entry| {
            if (mod_entry.name.parts.len == 1 and mod_entry.name.parts[0] == parent_name) {
                parent_mod = mod_entry.decl;
                break;
            }
        }
        const p_mod = parent_mod orelse return;

        // Build map of parent function return types (name+arity → return type)
        for (p_mod.items) |p_item| {
            const p_func = switch (p_item) {
                .function => |f| f,
                else => continue,
            };
            for (p_func.clauses) |p_clause| {
                const p_return = if (p_clause.return_type) |rt|
                    self.resolveTypeExpr(rt) catch TypeStore.UNKNOWN
                else
                    TypeStore.UNKNOWN;
                if (p_return == TypeStore.UNKNOWN) continue;

                // Check if child has a matching override
                for (mod.items) |c_item| {
                    const c_func = switch (c_item) {
                        .function => |f| f,
                        else => continue,
                    };
                    if (c_func.name != p_func.name) continue;
                    for (c_func.clauses) |c_clause| {
                        if (c_clause.params.len != p_clause.params.len) continue;
                        const c_return = if (c_clause.return_type) |rt|
                            self.resolveTypeExpr(rt) catch TypeStore.UNKNOWN
                        else
                            TypeStore.UNKNOWN;
                        if (c_return == TypeStore.UNKNOWN) continue;
                        if (!self.store.typeEquals(p_return, c_return)) {
                            const p_name = self.interner.get(p_func.name);
                            try self.addHardError(
                                try std.fmt.allocPrint(self.allocator, "`{s}/{d}` returns `{s}` in parent, cannot return `{s}`", .{
                                    p_name,
                                    p_clause.params.len,
                                    self.typeToString(p_return),
                                    self.typeToString(c_return),
                                }),
                                c_clause.meta.span,
                                "return type mismatch",
                                "overridden functions must have the same return type as the parent",
                            );
                        }
                    }
                }
            }
        }
    }

    fn checkTopItem(self: *TypeChecker, item: ast.TopItem) !void {
        switch (item) {
            .function => |func| try self.checkFunctionDecl(func),
            .priv_function => |func| try self.checkFunctionDecl(func),
            .macro, .priv_macro => {}, // Macro bodies are compile-time code — not type-checked
            .module => {},
            .priv_module => {},
            else => {},
        }
    }

    // ============================================================
    // Function type checking
    // ============================================================

    fn checkFunctionDecl(self: *TypeChecker, func: *const ast.FunctionDecl) !void {
        for (func.clauses) |clause| {
            try self.checkFunctionClause(&clause);
        }
    }

    fn checkFunctionClause(self: *TypeChecker, clause: *const ast.FunctionClause) !void {
        const prev_scope = self.current_scope;
        self.current_scope = self.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
        defer self.current_scope = prev_scope;

        // Resolve parameter types and populate bindings
        for (clause.params) |param| {
            if (param.type_annotation) |ta| {
                const param_type = try self.resolveTypeExpr(ta);
                const qualified = QualifiedType.init(param_type, self.resolveParamOwnership(param, param_type));
                // Store type on the binding in scope graph if this is a bind pattern
                if (param.pattern.* == .bind) {
                    const bind_name = param.pattern.bind.name;
                    if (self.current_scope) |scope_id| {
                        if (self.graph.resolveBinding(scope_id, bind_name)) |bid| {
                            try self.recordBindingQualifiedType(bid, qualified, ta.getMeta().span);
                        }
                    }
                }
            } else {
                // Generated functions (span 0:0) may lack type annotations.
                // Only error for user-written functions with real source locations.
                const span = param.pattern.getMeta().span;
                if (span.start != 0 or span.end != 0) {
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "parameter requires a type annotation (e.g., `param :: Type`)", .{}),
                        span,
                        "missing type annotation",
                        null,
                    );
                }
            }
        }

        // Resolve return type — required for user-written functions.
        // Generated functions (span 0:0) may lack return type annotations.
        const declared_return = if (clause.return_type) |rt|
            try self.resolveTypeExpr(rt)
        else blk: {
            const span = clause.meta.span;
            if (span.start != 0 or span.end != 0) {
                try self.addHardError(
                    "missing return type annotation",
                    span,
                    "this function has no return type",
                    "add a return type: `def name(params) -> ReturnType do`",
                );
            }
            break :blk TypeStore.UNKNOWN;
        };

        // Check refinement is Bool
        if (clause.refinement) |ref| {
            const ref_type = try self.inferExpr(ref);
            if (ref_type != TypeStore.BOOL and ref_type != TypeStore.UNKNOWN and ref_type != TypeStore.ERROR) {
                try self.addRichError(
                    "refinement predicate must be Bool",
                    ref.getMeta().span,
                    try std.fmt.allocPrint(self.allocator, "this is a `{s}`, not a `Bool`", .{self.typeToString(ref_type)}),
                    "guard clauses must evaluate to `true` or `false`",
                );
            }
        }

        // Check body (skip for @native bodyless declarations)
        var body_type: TypeId = TypeStore.NIL;
        var last_expr: ?*const ast.Expr = null;
        if (clause.body) |body| {
            for (body) |stmt| {
                if (stmt == .expr) last_expr = stmt.expr;
                body_type = try self.checkStmt(stmt);
            }
        }

        if (last_expr) |expr| {
            if (self.borrowedBindingFromExpr(expr)) |binding_id| {
                const binding = self.graph.bindings.items[binding_id];
                const name = self.interner.get(binding.name);
                try self.addHardError(
                    try std.fmt.allocPrint(self.allocator, "borrowed value `{s}` cannot escape through return", .{name}),
                    expr.getMeta().span,
                    "borrowed value escapes scope",
                    "return a shared or unique value instead of a borrowed binding",
                );
            }
            if (expr.* == .var_ref) {
                if (try self.resolveFunctionValueSignature(self.current_scope orelse self.graph.prelude_scope, expr.var_ref.name)) |_| {
                    if (self.resolveFunctionValueDecl(self.current_scope orelse self.graph.prelude_scope, expr.var_ref.name)) |decl| {
                        if (self.analysis_context != null and self.functionDeclCapturesBorrowed(decl)) {
                            const escape = self.closureEscapeForDecl(decl);
                            const allowed = if (escape) |e|
                                e == .no_escape
                            else
                                false;
                            if (!allowed) {
                                try self.addHardError(
                                    "closure with borrowed captures cannot escape through return",
                                    expr.getMeta().span,
                                    "borrowed capture escapes scope",
                                    "avoid returning closures that capture borrowed values",
                                );
                            }
                        }
                    }
                }
            }
        }

        // Skip return type check for @native bodyless declarations
        if (clause.body == null) return;

        // Verify return type matches (suppress if either side is ERROR/UNKNOWN/type_var from cascading)
        const declared_is_checkable = declared_return != TypeStore.UNKNOWN and
            declared_return != TypeStore.ERROR and
            self.store.getType(declared_return) != .type_var;
        if (declared_is_checkable and body_type != TypeStore.UNKNOWN and body_type != TypeStore.ERROR) {
            if (!self.store.typeEquals(body_type, declared_return)) {
                const expected = self.typeToString(declared_return);
                const got = self.typeToString(body_type);
                const diagnostics = @import("diagnostics.zig");

                // Build secondary span pointing to the return type annotation
                const secondary = if (clause.return_type) |rt| blk: {
                    const spans = try self.allocator.alloc(diagnostics.SecondarySpan, 1);
                    spans[0] = .{
                        .span = rt.getMeta().span,
                        .label = try std.fmt.allocPrint(self.allocator, "return type `{s}` declared here", .{expected}),
                    };
                    break :blk spans;
                } else &[_]diagnostics.SecondarySpan{};

                try self.errors.append(self.allocator, .{
                    .message = try std.fmt.allocPrint(self.allocator, "this function returns the wrong type", .{}),
                    .span = clause.meta.span,
                    .label = try std.fmt.allocPrint(self.allocator, "expected `{s}`, got `{s}`", .{ expected, got }),
                    .help = try std.fmt.allocPrint(self.allocator, "the function is declared to return `{s}` but the body produces `{s}`", .{ expected, got }),
                    .secondary_spans = secondary,
                    .severity = .@"error",
                });
            }
        }
    }

    // ============================================================
    // Statement type checking
    // ============================================================

    fn checkStmt(self: *TypeChecker, stmt: ast.Stmt) anyerror!TypeId {
        return switch (stmt) {
            .expr => |expr| self.inferExpr(expr),
            .assignment => |assign| {
                try self.ensureClosureValueCanEscape(assign.value, "assignment");
                const value_type = try self.inferExpr(assign.value);
                // Store type on the target binding if it's a bind pattern
                if (assign.pattern.* == .bind) {
                    const bind_name = assign.pattern.bind.name;
                    if (self.current_scope) |scope_id| {
                        if (self.graph.resolveBinding(scope_id, bind_name)) |bid| {
                            try self.recordBindingType(bid, value_type, assign.value.getMeta().span);
                        }
                    }
                }
                return value_type;
            },
            .function_decl => |func| {
                try self.checkFunctionDecl(func);
                return TypeStore.NIL;
            },
            .macro_decl => |mac| {
                try self.checkFunctionDecl(mac);
                return TypeStore.NIL;
            },
            .import_decl => TypeStore.NIL,
        };
    }

    // ============================================================
    // Expression type inference
    // ============================================================

    fn inferExpr(self: *TypeChecker, expr: *const ast.Expr) anyerror!TypeId {
        return switch (expr.*) {
            .int_literal => TypeStore.I64,
            .float_literal => TypeStore.F64,
            .string_literal => TypeStore.STRING,
            .atom_literal => TypeStore.ATOM,
            .bool_literal => TypeStore.BOOL,
            .nil_literal => TypeStore.NIL,
            .var_ref => |vr| {
                // Resolve type from scope binding
                if (self.current_scope) |scope_id| {
                    if (self.graph.resolveBinding(scope_id, vr.name)) |bid| {
                        _ = try self.ensureBindingAvailable(bid, vr.meta.span);
                        self.referenced_bindings.put(bid, {}) catch {};
                        const binding = self.graph.bindings.items[bid];
                        if (binding.type_id) |prov| {
                            return prov.type_id;
                        }
                        return TypeStore.UNKNOWN;
                    }
                    // Variable not found — try "did you mean?"
                    const var_name = self.interner.get(vr.name);
                    const visible_ids = self.graph.collectVisibleBindingNames(scope_id, self.allocator) catch return TypeStore.UNKNOWN;
                    // Build string candidates from IDs
                    var candidates: std.ArrayList([]const u8) = .empty;
                    for (visible_ids) |sid| {
                        candidates.append(self.allocator, self.interner.get(sid)) catch {};
                    }
                    const candidate_slice = candidates.items;
                    if (similarity.findBestMatch(var_name, candidate_slice, similarity.SUGGESTION_THRESHOLD)) |suggestion| {
                        try self.addRichError(
                            try std.fmt.allocPrint(self.allocator, "I cannot find a variable named `{s}`", .{var_name}),
                            vr.meta.span,
                            "not found in this scope",
                            try std.fmt.allocPrint(self.allocator, "did you mean `{s}`?", .{suggestion}),
                        );
                    }

                    if (try self.resolveFunctionValueSignature(scope_id, vr.name)) |signature| {
                        if (self.resolveFunctionValueDecl(scope_id, vr.name)) |decl| {
                            const captured = try self.capturedBindingsForFunctionDecl(decl);
                            for (captured) |binding_id| {
                                const binding = self.graph.bindings.items[binding_id];
                                if (binding.type_id) |prov| {
                                    switch (prov.ownership) {
                                        .unique => if (try self.ensureBindingMovable(binding_id, vr.meta.span)) {
                                            try self.markBindingMoved(binding_id);
                                        },
                                        .borrowed => {},
                                        .shared => {},
                                    }
                                }
                            }
                        }
                        return try self.store.addFunctionType(
                            signature.params,
                            signature.return_type,
                            signature.param_ownerships,
                            signature.return_ownership,
                        );
                    }
                }
                return TypeStore.UNKNOWN;
            },

            .binary_op => |bo| self.inferBinaryOp(&bo),
            .unary_op => |uo| self.inferUnaryOp(&uo),
            .call => |call| self.inferCall(&call),

            .tuple => |t| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (t.elements) |elem| {
                    try self.ensureClosureValueCanEscape(elem, "tuple storage");
                    try elem_types.append(self.allocator, try self.inferExpr(elem));
                }
                return try self.store.addType(.{
                    .tuple = .{ .elements = try elem_types.toOwnedSlice(self.allocator) },
                });
            },

            .list => |l| {
                if (l.elements.len == 0) return TypeStore.UNKNOWN;
                for (l.elements) |elem| {
                    try self.ensureClosureValueCanEscape(elem, "list storage");
                }
                const elem_type = try self.inferExpr(l.elements[0]);
                return try self.store.addType(.{
                    .list = .{ .element = elem_type },
                });
            },

            // if_expr, cond_expr, pipe are desugared to case_expr
            // before the TypeChecker runs. If we see them, return UNKNOWN.
            .if_expr => |ie| {
                const cond_type = try self.inferExpr(ie.condition);
                if (cond_type != TypeStore.BOOL and cond_type != TypeStore.UNKNOWN and cond_type != TypeStore.ERROR) {
                    try self.addRichError(
                        try std.fmt.allocPrint(self.allocator, "this condition is a `{s}`, but `if` requires a `Bool`", .{self.typeToString(cond_type)}),
                        ie.meta.span,
                        try std.fmt.allocPrint(self.allocator, "this is a `{s}`", .{self.typeToString(cond_type)}),
                        "try comparing it: `if x > 0 do ...`",
                    );
                }
                var then_type: TypeId = TypeStore.NIL;
                for (ie.then_block) |stmt| {
                    then_type = try self.checkStmt(stmt);
                }
                if (ie.else_block) |else_block| {
                    var else_type: TypeId = TypeStore.NIL;
                    for (else_block) |stmt| {
                        else_type = try self.checkStmt(stmt);
                    }
                    if (self.store.typeEquals(then_type, else_type)) return then_type;
                    return TypeStore.UNKNOWN;
                }
                return then_type;
            },

            .case_expr => |ce| {
                const scrutinee_type = try self.inferExpr(ce.scrutinee);
                var result_type: TypeId = TypeStore.UNKNOWN;
                var has_wildcard = false;
                for (ce.clauses) |clause| {
                    // Check for wildcard/catch-all pattern
                    if (clause.pattern.* == .wildcard or clause.pattern.* == .bind) {
                        has_wildcard = true;
                    }
                    var clause_type: TypeId = TypeStore.NIL;
                    for (clause.body) |stmt| {
                        clause_type = try self.checkStmt(stmt);
                    }
                    if (result_type == TypeStore.UNKNOWN) {
                        result_type = clause_type;
                    }
                }
                // Enum exhaustiveness check
                if (!has_wildcard and scrutinee_type != TypeStore.UNKNOWN) {
                    const scrutinee_t = self.store.getType(scrutinee_type);
                    if (scrutinee_t == .tagged_union) {
                        const tu = scrutinee_t.tagged_union;
                        // Collect matched variants from case patterns
                        var matched_count: usize = 0;
                        for (tu.variants) |variant| {
                            var variant_matched = false;
                            for (ce.clauses) |clause| {
                                // Check for module_ref pattern matching enum variant
                                // e.g. Color.Red → literal atom pattern or module_ref pattern
                                if (clause.pattern.* == .literal) {
                                    if (clause.pattern.literal == .atom) {
                                        if (clause.pattern.literal.atom.value == variant.name) {
                                            variant_matched = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (variant_matched) matched_count += 1;
                        }
                        if (matched_count < tu.variants.len) {
                            // Find missing variants
                            var missing: std.ArrayList([]const u8) = .empty;
                            for (tu.variants) |variant| {
                                var found = false;
                                for (ce.clauses) |clause| {
                                    if (clause.pattern.* == .literal) {
                                        if (clause.pattern.literal == .atom) {
                                            if (clause.pattern.literal.atom.value == variant.name) {
                                                found = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (!found) {
                                    missing.append(self.allocator, self.interner.get(variant.name)) catch {};
                                }
                            }
                            if (missing.items.len > 0) {
                                const missing_str = std.mem.join(self.allocator, ", ", missing.items) catch "...";
                                try self.addHardError(
                                    try std.fmt.allocPrint(self.allocator, "non-exhaustive match on enum `{s}`", .{
                                        self.interner.get(tu.name),
                                    }),
                                    ce.meta.span,
                                    try std.fmt.allocPrint(self.allocator, "missing: {s}", .{missing_str}),
                                    "add the missing variants or a wildcard `_` pattern",
                                );
                            }
                        }
                    }
                }
                return result_type;
            },

            .block => |blk| {
                var result_type: TypeId = TypeStore.NIL;
                for (blk.stmts) |stmt| {
                    result_type = try self.checkStmt(stmt);
                }
                return result_type;
            },

            .function_ref => |fr| {
                // Create a function type with known arity, unknown param/return types
                const params = try self.allocator.alloc(TypeId, fr.arity);
                for (params) |*p| p.* = TypeStore.UNKNOWN;
                return try self.buildFunctionType(params, TypeStore.UNKNOWN);
            },
            .field_access => |fa| {
                // Check for enum variant access (e.g. Color.Red)
                if (fa.object.* == .module_ref) {
                    const parts = fa.object.module_ref.name.parts;
                    if (parts.len == 1) {
                        if (self.store.name_to_type.get(parts[0])) |tid| {
                            const t = self.store.getType(tid);
                            if (t == .tagged_union) {
                                // Validate variant name
                                var valid = false;
                                for (t.tagged_union.variants) |v| {
                                    if (v.name == fa.field) {
                                        valid = true;
                                        break;
                                    }
                                }
                                if (!valid) {
                                    try self.addHardError(
                                        try std.fmt.allocPrint(self.allocator, "`{s}` is not a variant of enum `{s}`", .{
                                            self.interner.get(fa.field),
                                            self.interner.get(t.tagged_union.name),
                                        }),
                                        fa.meta.span,
                                        "unknown variant",
                                        null,
                                    );
                                }
                                return tid;
                            }
                        }
                    }
                }
                // Infer object type; for known struct types, look up field type
                const obj_type = try self.inferExpr(fa.object);
                if (obj_type != TypeStore.UNKNOWN) {
                    const t = self.store.getType(obj_type);
                    if (t == .struct_type) {
                        // Look up the field's type in the struct definition
                        for (t.struct_type.fields) |field| {
                            if (field.name == fa.field) return field.type_id;
                        }
                    }
                }
                return TypeStore.UNKNOWN;
            },
            .map => |m| {
                // Infer key/value types from first entry
                if (m.fields.len > 0) {
                    for (m.fields) |field| {
                        try self.ensureClosureValueCanEscape(field.key, "map key storage");
                        try self.ensureClosureValueCanEscape(field.value, "map value storage");
                    }
                    _ = try self.inferExpr(m.fields[0].key);
                    _ = try self.inferExpr(m.fields[0].value);
                }
                return TypeStore.UNKNOWN;
            },
            .struct_expr => |se| {
                // Resolve struct type from module name annotation
                if (se.module_name.parts.len > 0) {
                    const type_name_id = se.module_name.parts[se.module_name.parts.len - 1];
                    if (self.store.name_to_type.get(type_name_id)) |tid| {
                        const typ = self.store.getType(tid);
                        if (typ == .struct_type) {
                            // Validate required fields are provided
                            const st = typ.struct_type;
                            for (st.fields) |req_field| {
                                var found = false;
                                for (se.fields) |provided| {
                                    if (provided.name == req_field.name) {
                                        try self.ensureClosureValueCanEscape(provided.value, "struct field storage");
                                        found = true;
                                        // Check field value type
                                        const val_type = try self.inferExpr(provided.value);
                                        if (val_type != TypeStore.UNKNOWN and req_field.type_id != TypeStore.UNKNOWN and
                                            !self.store.typeEquals(val_type, req_field.type_id))
                                        {
                                            try self.addRichError(
                                                try std.fmt.allocPrint(self.allocator, "field `{s}` expects `{s}`, got `{s}`", .{
                                                    self.interner.get(req_field.name),
                                                    self.typeToString(req_field.type_id),
                                                    self.typeToString(val_type),
                                                }),
                                                provided.value.getMeta().span,
                                                "type mismatch",
                                                null,
                                            );
                                        }
                                        break;
                                    }
                                }
                                if (!found) {
                                    // Check if field has a default in the AST
                                    var has_default = false;
                                    for (self.graph.types.items) |te| {
                                        if (te.kind == .struct_type) {
                                            const sd = te.kind.struct_type;
                                            if (sd.name) |n| {
                                                if (n == type_name_id) {
                                                    for (sd.fields) |f| {
                                                        if (f.name == req_field.name and f.default != null) {
                                                            has_default = true;
                                                            break;
                                                        }
                                                    }
                                                    // Also check parent fields for defaults
                                                    if (!has_default and sd.parent != null) {
                                                        // Parent fields don't have defaults accessible here,
                                                        // so we check the parent's AST
                                                        if (sd.parent) |parent_name| {
                                                            for (self.graph.types.items) |pte| {
                                                                if (pte.kind == .struct_type) {
                                                                    const psd = pte.kind.struct_type;
                                                                    if (psd.name) |pn| {
                                                                        if (pn == parent_name) {
                                                                            for (psd.fields) |pf| {
                                                                                if (pf.name == req_field.name and pf.default != null) {
                                                                                    has_default = true;
                                                                                    break;
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                    if (!has_default) {
                                        try self.addRichError(
                                            try std.fmt.allocPrint(self.allocator, "missing required field `{s}` in struct `{s}`", .{
                                                self.interner.get(req_field.name),
                                                self.interner.get(type_name_id),
                                            }),
                                            se.meta.span,
                                            "field not provided",
                                            try std.fmt.allocPrint(self.allocator, "add `{s}: <value>` to the struct literal", .{
                                                self.interner.get(req_field.name),
                                            }),
                                        );
                                    }
                                }
                            }
                            // Check for extra fields not in struct
                            for (se.fields) |provided| {
                                var found = false;
                                for (st.fields) |req_field| {
                                    if (req_field.name == provided.name) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    _ = try self.inferExpr(provided.value);
                                    try self.addRichError(
                                        try std.fmt.allocPrint(self.allocator, "unknown field `{s}` in struct `{s}`", .{
                                            self.interner.get(provided.name),
                                            self.interner.get(type_name_id),
                                        }),
                                        provided.value.getMeta().span,
                                        "not a field of this struct",
                                        null,
                                    );
                                }
                            }
                            return tid;
                        }
                    }
                }
                // Infer field values even if type unknown
                for (se.fields) |field| {
                    _ = try self.inferExpr(field.value);
                }
                return TypeStore.UNKNOWN;
            },
            .panic_expr => |pe| {
                _ = try self.inferExpr(pe.message);
                return TypeStore.NEVER;
            },
            .unwrap => TypeStore.UNKNOWN,
            .pipe => |pipe| {
                // Pipes are desugared before type checking, but we still need
                // to walk into children so var_refs get marked as referenced
                // (e.g., for unused binding detection in error_pipe chains).
                _ = try self.inferExpr(pipe.lhs);
                _ = try self.inferExpr(pipe.rhs);
                return TypeStore.UNKNOWN;
            },
            .module_ref => |mr| {
                // Check for enum variant access (e.g. Color.Red parsed as module_ref ["Color", "Red"])
                if (mr.name.parts.len == 2) {
                    if (self.store.name_to_type.get(mr.name.parts[0])) |tid| {
                        const t = self.store.getType(tid);
                        if (t == .tagged_union) {
                            // Validate variant name
                            var valid = false;
                            for (t.tagged_union.variants) |v| {
                                if (v.name == mr.name.parts[1]) {
                                    valid = true;
                                    break;
                                }
                            }
                            if (!valid) {
                                try self.addHardError(
                                    try std.fmt.allocPrint(self.allocator, "`{s}` is not a variant of enum `{s}`", .{
                                        self.interner.get(mr.name.parts[1]),
                                        self.interner.get(t.tagged_union.name),
                                    }),
                                    mr.meta.span,
                                    "unknown variant",
                                    null,
                                );
                            }
                            return tid;
                        }
                    }
                }
                return TypeStore.UNKNOWN;
            },
            .string_interpolation => TypeStore.STRING,
            .quote_expr => TypeStore.UNKNOWN,
            .unquote_expr, .unquote_splicing_expr => TypeStore.UNKNOWN,
            .cond_expr => TypeStore.UNKNOWN, // desugared before type checking
            .intrinsic => |intr| {
                // Recurse into intrinsic args so var_refs mark bindings as used
                for (intr.args) |arg| {
                    _ = try self.inferExpr(arg);
                }
                return TypeStore.UNKNOWN;
            },
            .attr_ref => TypeStore.UNKNOWN,
            .binary_literal => TypeStore.STRING, // binary literals produce []const u8
            .type_annotated => |ta| {
                // Infer the inner expression, but prefer the annotated type
                _ = try self.inferExpr(ta.expr);
                return try self.resolveTypeExpr(ta.type_expr);
            },
            // error_pipe: the chain may return a tagged union, but ~> handles the
            // Error variant, so the expression type is the Ok variant's inner type.
            .error_pipe => |ep| {
                const chain_type = try self.inferExpr(ep.chain);
                if (chain_type < self.store.types.items.len) {
                    const ct = self.store.types.items[chain_type];
                    if (ct == .tagged_union) {
                        const interner_mut: *ast.StringInterner = @constCast(self.interner);
                        const ok_name = interner_mut.intern("Ok") catch return chain_type;
                        for (ct.tagged_union.variants) |v| {
                            if (v.name == ok_name) {
                                return v.type_id orelse TypeStore.UNKNOWN;
                            }
                        }
                    }
                }
                return chain_type;
            },
            // error_pipe: infer the chain type as fallback.

            // for_expr is desugared before type checking; return UNKNOWN if we see it
            .for_expr => TypeStore.UNKNOWN,

            // list_cons_expr: infer from head type → list type
            .list_cons_expr => |lc| {
                const head_type = try self.inferExpr(lc.head);
                _ = try self.inferExpr(lc.tail);
                return try self.store.addType(.{
                    .list = .{ .element = head_type },
                });
            },
        };
    }

    fn inferBinaryOp(self: *TypeChecker, bo: *const ast.BinaryOp) !TypeId {
        const lhs = try self.inferExpr(bo.lhs);
        const rhs = try self.inferExpr(bo.rhs);

        return switch (bo.op) {
            // Arithmetic: both operands must be same numeric type
            .add, .sub, .mul, .div, .rem_op => {
                // Cascading suppression: if either operand is ERROR, propagate silently
                if (lhs == TypeStore.ERROR or rhs == TypeStore.ERROR) return TypeStore.ERROR;
                if (lhs == TypeStore.UNKNOWN or rhs == TypeStore.UNKNOWN) return if (lhs != TypeStore.UNKNOWN) lhs else rhs;
                if (!self.store.typeEquals(lhs, rhs)) {
                    const lhs_name = self.typeToString(lhs);
                    const rhs_name = self.typeToString(rhs);
                    try self.addRichError(
                        try std.fmt.allocPrint(self.allocator, "cannot perform arithmetic on `{s}` and `{s}`", .{ lhs_name, rhs_name }),
                        bo.meta.span,
                        "type mismatch between operands",
                        try std.fmt.allocPrint(self.allocator, "both operands must be the same numeric type, but the left is `{s}` and the right is `{s}`", .{ lhs_name, rhs_name }),
                    );
                    return TypeStore.ERROR;
                }
                return lhs;
            },
            // Comparison: returns Bool
            .equal, .not_equal, .less, .greater, .less_equal, .greater_equal => TypeStore.BOOL,
            // Logical: returns Bool
            .and_op, .or_op => TypeStore.BOOL,
            // String concat
            .concat => TypeStore.STRING,
        };
    }

    fn inferUnaryOp(self: *TypeChecker, uo: *const ast.UnaryOp) !TypeId {
        const operand_type = try self.inferExpr(uo.operand);
        return switch (uo.op) {
            .negate => operand_type,
            .not_op => TypeStore.BOOL,
        };
    }

    fn inferCall(self: *TypeChecker, call: *const ast.CallExpr) !TypeId {
        const arity: u32 = @intCast(call.args.len);

        // Special handling for direct function calls (callee is var_ref)
        if (call.callee.* == .var_ref) {
            const vr = call.callee.var_ref;

            if (self.current_scope) |scope_id| {
                // First check if it's a variable holding a function
                if (self.graph.resolveBinding(scope_id, vr.name)) |bid| {
                    self.referenced_bindings.put(bid, {}) catch {};
                    const binding = self.graph.bindings.items[bid];
                    if (binding.type_id) |prov| {
                        const t = self.store.getType(prov.type_id);
                        if (t == .function) {
                            for (call.args) |arg| _ = try self.inferExpr(arg);
                            const borrowed = try self.applyCallOwnership(call.args, t.function);
                            defer self.endBorrowedBindings(borrowed) catch {};
                            return t.function.return_type;
                        }
                    }
                }

                // Check function families
                if (try self.resolveFamilySignature(scope_id, vr.name, arity)) |signature| {
                    const safe_params = self.safeClosureParamsForCurrentCallee(vr.name, arity);
                    for (call.args, 0..) |arg, idx| {
                        if (arg.* != .var_ref) continue;
                        if (self.resolveFunctionValueDecl(scope_id, arg.var_ref.name)) |decl| {
                            if (self.analysis_context != null and self.functionDeclCapturesBorrowed(decl)) {
                                const callee_allows = if (safe_params) |flags|
                                    idx < flags.len and flags[idx]
                                else
                                    false;
                                if (!callee_allows) {
                                    try self.addHardError(
                                        "closure with borrowed captures cannot be passed as an argument",
                                        arg.getMeta().span,
                                        "borrowed capture escapes scope",
                                        "call the closure locally instead of passing it beyond the borrow scope",
                                    );
                                }
                            }
                        }
                    }
                    for (call.args, 0..) |arg, idx| {
                        const arg_type = try self.inferExpr(arg);
                        if (idx < signature.params.len) {
                            const expected = signature.params[idx];
                            if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR and !self.store.typeEquals(arg_type, expected)) {
                                try self.addRichError(
                                    try std.fmt.allocPrint(self.allocator, "argument {d} expects `{s}`, got `{s}`", .{ idx + 1, self.typeToString(expected), self.typeToString(arg_type) }),
                                    arg.getMeta().span,
                                    "argument type mismatch",
                                    null,
                                );
                            }
                        }
                    }
                    const borrowed = try self.applyCallOwnershipWithSafeParams(call.args, signature.toFunctionType(), safe_params);
                    defer self.endBorrowedBindings(borrowed) catch {};
                    return signature.return_type;
                }

                // Function not found — suggest alternatives
                const func_name = self.interner.get(vr.name);
                const visible = self.graph.collectVisibleFunctionNames(
                    scope_id,
                    self.allocator,
                ) catch &[_]scope_mod.FamilyKey{};

                var candidates: std.ArrayList([]const u8) = .empty;
                for (visible) |fk| {
                    if (fk.arity == arity) {
                        candidates.append(self.allocator, self.interner.get(fk.name)) catch {};
                    }
                }

                const help_text = if (similarity.findBestMatch(
                    func_name,
                    candidates.items,
                    similarity.SUGGESTION_THRESHOLD,
                )) |suggestion|
                    try std.fmt.allocPrint(self.allocator, "did you mean `{s}/{d}`?", .{ suggestion, arity })
                else
                    null;

                try self.addRichError(
                    try std.fmt.allocPrint(self.allocator, "I cannot find a function named `{s}/{d}`", .{ func_name, arity }),
                    call.meta.span,
                    "not found in this scope",
                    help_text,
                );

                for (call.args) |arg| _ = try self.inferExpr(arg);
                return TypeStore.UNKNOWN;
            }
        }

        // Module-qualified call: IO.puts(...) is a call with field_access callee
        if (call.callee.* == .field_access) {
            const fa = call.callee.field_access;
            // :zig.func(args) — bridge call; infer args to mark bindings as used
            if (fa.object.* == .atom_literal) {
                for (call.args) |arg| {
                    _ = try self.inferExpr(arg);
                    // Mark any var_ref args as referenced directly
                    if (arg.* == .var_ref) {
                        if (self.current_scope) |scope_id| {
                            if (self.graph.resolveBinding(scope_id, arg.var_ref.name)) |bid| {
                                self.referenced_bindings.put(bid, {}) catch {};
                            }
                        }
                    }
                }
                return TypeStore.UNKNOWN;
            }
            if (fa.object.* == .module_ref) {
                // Look up the module's scope and resolve the function there
                const mod_name = fa.object.module_ref.name;
                for (self.graph.modules.items) |mod_entry| {
                    if (mod_entry.name.parts.len == mod_name.parts.len) {
                        var match = true;
                        for (mod_entry.name.parts, mod_name.parts) |a, b| {
                            if (a != b) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            if (try self.resolveFamilySignature(mod_entry.scope_id, fa.field, arity)) |signature| {
                                for (call.args, 0..) |arg, idx| {
                                    const arg_type = try self.inferExpr(arg);
                                    if (idx < signature.params.len) {
                                        const expected = signature.params[idx];
                                        if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR and !self.store.typeEquals(arg_type, expected)) {
                                            try self.addRichError(
                                                try std.fmt.allocPrint(self.allocator, "argument {d} expects `{s}`, got `{s}`", .{ idx + 1, self.typeToString(expected), self.typeToString(arg_type) }),
                                                arg.getMeta().span,
                                                "argument type mismatch",
                                                null,
                                            );
                                        }
                                    }
                                }
                                return signature.return_type;
                            }
                            break;
                        }
                    }
                }
            }
        }

        // Non-var_ref callee (lambda, etc.) — original path
        const callee_type = try self.inferExpr(call.callee);
        if (callee_type != TypeStore.UNKNOWN and callee_type != TypeStore.ERROR) {
            const ct = self.store.getType(callee_type);
            if (ct == .function) {
                for (call.args) |arg| _ = try self.inferExpr(arg);
                const borrowed = try self.applyCallOwnership(call.args, ct.function);
                defer self.endBorrowedBindings(borrowed) catch {};
                return ct.function.return_type;
            }
        }

        for (call.args) |arg| _ = try self.inferExpr(arg);
        return TypeStore.UNKNOWN;
    }

    // ============================================================
    // Type expression resolution
    // ============================================================

    fn resolveTypeExpr(self: *TypeChecker, type_expr: *const ast.TypeExpr) anyerror!TypeId {
        return switch (type_expr.*) {
            .name => |tn| {
                const name = self.interner.get(tn.name);

                if (self.store.resolveTypeName(name)) |tid| {
                    if (tn.args.len > 0) {
                        // Generic type application
                        var arg_types: std.ArrayList(TypeId) = .empty;
                        for (tn.args) |arg| {
                            try arg_types.append(self.allocator, try self.resolveTypeExpr(arg));
                        }
                        return try self.store.addType(.{
                            .applied = .{
                                .base = tid,
                                .args = try arg_types.toOwnedSlice(self.allocator),
                            },
                        });
                    }
                    return tid;
                }
                // Check user-defined types registered in TypeStore
                if (self.store.name_to_type.get(tn.name)) |tid| {
                    return tid;
                }
                // Check user-defined types in scope graph (forward reference fallback)
                for (self.graph.types.items) |type_entry| {
                    const type_name = self.interner.get(type_entry.name);
                    if (std.mem.eql(u8, name, type_name)) {
                        return TypeStore.UNKNOWN; // Known user type, just can't resolve yet
                    }
                }

                // Unknown type — report error with suggestions
                var candidates: std.ArrayList([]const u8) = .empty;
                // Collect builtin type names
                const builtins = [_][]const u8{
                    "Bool", "String", "Atom",  "Nil", "Never",
                    "i64",  "i32",    "i16",   "i8",  "u64",
                    "u32",  "u16",    "u8",    "f64", "f32",
                    "f16",  "usize",  "isize",
                };
                for (&builtins) |b| {
                    candidates.append(self.allocator, b) catch {};
                }
                // Collect user-defined type names
                for (self.graph.types.items) |type_entry| {
                    candidates.append(self.allocator, self.interner.get(type_entry.name)) catch {};
                }

                const help_text = if (similarity.findBestMatch(
                    name,
                    candidates.items,
                    similarity.SUGGESTION_THRESHOLD,
                )) |suggestion|
                    try std.fmt.allocPrint(self.allocator, "did you mean `{s}`?", .{suggestion})
                else
                    null;

                try self.addHardError(
                    try std.fmt.allocPrint(self.allocator, "I cannot find a type named `{s}`", .{name}),
                    type_expr.getMeta().span,
                    "not found",
                    help_text,
                );
                return TypeStore.ERROR;
            },
            .variable => |tv| {
                // Check if this type variable name is a near-miss of a builtin type
                const var_name = self.interner.get(tv.name);
                const builtins = [_][]const u8{
                    "Bool", "String", "Atom",  "Nil", "Never",
                    "i64",  "i32",    "i16",   "i8",  "u64",
                    "u32",  "u16",    "u8",    "f64", "f32",
                    "f16",  "usize",  "isize",
                };
                // Use slightly relaxed threshold for short type names (floating point edge cases)
                if (similarity.findBestMatch(var_name, &builtins, similarity.SUGGESTION_THRESHOLD - 0.01)) |suggestion| {
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "I cannot find a type named `{s}`", .{var_name}),
                        type_expr.getMeta().span,
                        "treated as a type variable, but this looks like a typo",
                        try std.fmt.allocPrint(self.allocator, "did you mean `{s}`?", .{suggestion}),
                    );
                    return TypeStore.ERROR;
                }
                return try self.store.freshVar();
            },
            .tuple => |tt| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (tt.elements) |elem| {
                    try elem_types.append(self.allocator, try self.resolveTypeExpr(elem));
                }
                return try self.store.addType(.{
                    .tuple = .{ .elements = try elem_types.toOwnedSlice(self.allocator) },
                });
            },
            .list => |lt| {
                const elem_type = try self.resolveTypeExpr(lt.element);
                return try self.store.addType(.{
                    .list = .{ .element = elem_type },
                });
            },
            .union_type => |ut| {
                var member_types: std.ArrayList(TypeId) = .empty;
                for (ut.members) |member| {
                    try member_types.append(self.allocator, try self.resolveTypeExpr(member));
                }
                return try self.store.addType(.{
                    .union_type = .{ .members = try member_types.toOwnedSlice(self.allocator) },
                });
            },
            .function => |ft| {
                var param_types: std.ArrayList(TypeId) = .empty;
                for (ft.params) |param| {
                    try param_types.append(self.allocator, try self.resolveTypeExpr(param));
                }
                const return_type = try self.resolveTypeExpr(ft.return_type);
                const params = try param_types.toOwnedSlice(self.allocator);
                const param_ownerships = try self.allocator.alloc(Ownership, ft.param_ownerships.len);
                for (ft.param_ownerships, ft.param_ownerships_explicit, params, 0..) |ownership, explicit, param_type, idx| {
                    param_ownerships[idx] = if (explicit)
                        mapAstOwnership(ownership)
                    else if (mapAstOwnership(ownership) == .shared)
                        self.defaultOwnershipForType(param_type)
                    else
                        mapAstOwnership(ownership);
                }
                const ret_ownership = if (ft.return_ownership_explicit)
                    mapAstOwnership(ft.return_ownership)
                else if (mapAstOwnership(ft.return_ownership) == .shared)
                    self.defaultOwnershipForType(return_type)
                else
                    mapAstOwnership(ft.return_ownership);
                return try self.store.addFunctionType(params, return_type, param_ownerships, ret_ownership);
            },
            .never => TypeStore.NEVER,
            .literal => |lt| {
                return switch (lt.value) {
                    .int => TypeStore.I64,
                    .string => TypeStore.STRING,
                    .bool_val => TypeStore.BOOL,
                    .nil => TypeStore.NIL,
                };
            },
            .paren => |pt| self.resolveTypeExpr(pt.inner),
            .map => TypeStore.UNKNOWN,
            .struct_type => TypeStore.UNKNOWN,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "type store builtin types" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expect(store.getType(TypeStore.BOOL) == .bool_type);
    try std.testing.expect(store.getType(TypeStore.STRING) == .string_type);
    try std.testing.expect(store.getType(TypeStore.I64) == .int);
    try std.testing.expect(store.getType(TypeStore.F64) == .float);
    try std.testing.expect(store.getType(TypeStore.NEVER) == .never);
}

test "type store resolve builtin names" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expectEqual(TypeStore.I64, store.resolveTypeName("i64").?);
    try std.testing.expectEqual(TypeStore.BOOL, store.resolveTypeName("Bool").?);
    try std.testing.expectEqual(TypeStore.STRING, store.resolveTypeName("String").?);
    try std.testing.expect(store.resolveTypeName("Nonexistent") == null);
}

fn rerunWithEscapeAnalysis(
    alloc: std.mem.Allocator,
    interner: *ast.StringInterner,
    graph: *scope_mod.ScopeGraph,
    checker: *TypeChecker,
    program: *const ast.Program,
) !void {
    var hir_builder = @import("hir.zig").HirBuilder.init(alloc, interner, graph, &checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(program);

    var ir_builder = @import("ir.zig").IrBuilder.init(alloc, interner);
    ir_builder.type_store = &checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var pipeline_result = try @import("analysis_pipeline.zig").runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();

    checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    checker.errors.clearRetainingCapacity();
    try checker.checkProgram(program);
}

test "qualified type defaults to shared ownership" {
    const qualified = QualifiedType{ .type_id = TypeStore.STRING };

    try std.testing.expectEqual(TypeStore.STRING, qualified.type_id);
    try std.testing.expectEqual(Ownership.shared, qualified.ownership);
}

test "function type can carry ownership metadata" {
    const param_ownerships = [_]Ownership{ .unique, .borrowed };
    const fn_type = Type.FunctionType{
        .params = &.{ TypeStore.STRING, TypeStore.I64 },
        .return_type = TypeStore.BOOL,
        .param_ownerships = &param_ownerships,
        .return_ownership = .shared,
    };

    try std.testing.expectEqual(@as(usize, 2), fn_type.params.len);
    try std.testing.expectEqual(@as(usize, 2), fn_type.param_ownerships.?.len);
    try std.testing.expectEqual(Ownership.unique, fn_type.param_ownerships.?[0]);
    try std.testing.expectEqual(Ownership.borrowed, fn_type.param_ownerships.?[1]);
    try std.testing.expectEqual(Ownership.shared, fn_type.return_ownership);
}

test "binding ownership info starts available" {
    const binding = BindingOwnershipInfo{
        .qualified_type = .{ .type_id = TypeStore.I64, .ownership = .unique },
    };

    try std.testing.expectEqual(Ownership.unique, binding.qualified_type.ownership);
    try std.testing.expectEqual(BindingOwnershipState.available, binding.state);
    try std.testing.expectEqual(@as(u32, 0), binding.active_borrows);
}

test "type store qualify attaches ownership metadata" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const qualified = store.qualify(TypeStore.I64, .borrowed);

    try std.testing.expectEqual(TypeStore.I64, qualified.type_id);
    try std.testing.expectEqual(Ownership.borrowed, qualified.ownership);
}

test "type store addFunctionType preserves ownership metadata" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const param_ownerships = [_]Ownership{ .shared, .unique };
    const fn_type_id = try store.addFunctionType(&.{ TypeStore.STRING, TypeStore.I64 }, TypeStore.BOOL, &param_ownerships, .borrowed);
    const fn_type = store.getType(fn_type_id);

    try std.testing.expect(fn_type == .function);
    try std.testing.expectEqual(@as(usize, 2), fn_type.function.params.len);
    try std.testing.expectEqual(@as(usize, 2), fn_type.function.param_ownerships.?.len);
    try std.testing.expectEqual(Ownership.shared, fn_type.function.param_ownerships.?[0]);
    try std.testing.expectEqual(Ownership.unique, fn_type.function.param_ownerships.?[1]);
    try std.testing.expectEqual(Ownership.borrowed, fn_type.function.return_ownership);
}

test "type checker registers opaque types" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const handle_name = try parser.interner.intern("Handle");
    const handle_id = checker.store.name_to_type.get(handle_name).?;
    try std.testing.expect(checker.store.getType(handle_id) == .opaque_type);
}

test "function type equality includes ownership metadata" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const shared_param_ownerships = [_]Ownership{.shared};
    const unique_param_ownerships = [_]Ownership{.unique};

    const shared_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &shared_param_ownerships, .shared);
    const same_shared_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &shared_param_ownerships, .shared);
    const unique_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &unique_param_ownerships, .shared);
    const borrowed_return_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &shared_param_ownerships, .borrowed);

    try std.testing.expect(store.typeEquals(shared_fn, same_shared_fn));
    try std.testing.expect(!store.typeEquals(shared_fn, unique_fn));
    try std.testing.expect(!store.typeEquals(shared_fn, borrowed_return_fn));
}

test "function subtyping respects ownership metadata" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const shared_param_ownerships = [_]Ownership{.shared};
    const unique_param_ownerships = [_]Ownership{.unique};

    const shared_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &shared_param_ownerships, .shared);
    const same_shared_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &shared_param_ownerships, .shared);
    const unique_fn = try store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, &unique_param_ownerships, .shared);

    try std.testing.expect(store.isSubtype(shared_fn, same_shared_fn));
    try std.testing.expect(!store.isSubtype(shared_fn, unique_fn));
}

test "borrow state returns to available when borrow ends" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var graph = scope_mod.ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    var checker = TypeChecker.init(std.testing.allocator, &interner, &graph);
    defer checker.deinit();

    try checker.recordBindingOwnership(0, TypeStore.STRING, .unique);
    try checker.beginBindingBorrow(0);

    var info = checker.bindingOwnershipInfo(0).?;
    try std.testing.expectEqual(BindingOwnershipState.borrowed, info.state);
    try std.testing.expectEqual(@as(u32, 1), info.active_borrows);

    try checker.endBindingBorrow(0);
    info = checker.bindingOwnershipInfo(0).?;
    try std.testing.expectEqual(BindingOwnershipState.available, info.state);
    try std.testing.expectEqual(@as(u32, 0), info.active_borrows);
}

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "type check simple function" {
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    var hir_builder = @import("hir.zig").HirBuilder.init(alloc, parser.interner, &collector.graph, &checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);
    var ir_builder = @import("ir.zig").IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);
    var pipeline_result = try @import("analysis_pipeline.zig").runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();
    checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    checker.errors.clearRetainingCapacity();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check literals" {
    const source =
        \\pub module Test {
        \\  pub fn foo() -> i64 {
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check case expression" {
    const source =
        \\pub module Test {
        \\  pub fn foo(x :: Atom) -> Nil {
        \\    case x {
        \\      {:ok, v} -> v
        \\      {:error, e} -> e
        \\    }
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check arithmetic mismatch reported" {
    // String + i64 should produce a type error
    const source =
        \\pub module Test {
        \\  pub fn bad() -> i64 {
        \\    "hello" + 42
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    // Should report arithmetic type mismatch
    const err_msg = checker.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "arithmetic") != null or std.mem.indexOf(u8, err_msg, "cannot perform") != null);
}

test "typeToString returns human-readable names" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var graph = scope_mod.ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    var checker = TypeChecker.init(std.testing.allocator, &interner, &graph);
    defer checker.deinit();

    try std.testing.expectEqualStrings("i64", checker.typeToString(TypeStore.I64));
    try std.testing.expectEqualStrings("Bool", checker.typeToString(TypeStore.BOOL));
    try std.testing.expectEqualStrings("String", checker.typeToString(TypeStore.STRING));
    try std.testing.expectEqualStrings("{unknown}", checker.typeToString(TypeStore.UNKNOWN));
    try std.testing.expectEqualStrings("f64", checker.typeToString(TypeStore.F64));
}

test "type check var_ref resolves to parameter type" {
    // x is declared as i64, so x + 1 should not error (both i64)
    const source =
        \\pub module Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x + x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have no errors — x resolves to i64 from param type
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check if condition must be Bool" {
    // Using an integer as if condition should produce an error
    const source =
        \\pub module Test {
        \\  pub fn bad() -> i64 {
        \\    if 42 {
        \\      1
        \\    }
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err_msg = checker.errors.items[0].message;
    // New contextual message mentions the actual type and if requirement
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "but `if` requires a `Bool`") != null);
}

test "type check return type mismatch" {
    // Function declares i64 return but body returns a string
    const source =
        \\pub module Test {
        \\  pub fn bad() -> i64 {
        \\    "not a number"
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err_msg = checker.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "returns the wrong type") != null);
    // Rich label should contain the expected/got info
    const err_label = checker.errors.items[0].label orelse "";
    try std.testing.expect(std.mem.indexOf(u8, err_label, "i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_label, "String") != null);
}

test "type provenance tracks source span on typed parameter" {
    const source =
        \\pub module Test {
        \\  pub fn add(x :: i64) {
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Find the binding for x and check it has provenance
    var found_x = false;
    for (checker.graph.bindings.items) |binding| {
        const name = checker.interner.get(binding.name);
        if (std.mem.eql(u8, name, "x")) {
            try std.testing.expect(binding.type_id != null);
            const prov = binding.type_id.?;
            try std.testing.expectEqual(TypeStore.I64, prov.type_id);
            try std.testing.expect(prov.source_span.start > 0 or prov.source_span.end > 0);
            found_x = true;
        }
    }
    try std.testing.expect(found_x);
}

test "typed parameter records shared ownership metadata" {
    const source =
        \\pub module Test {
        \\  pub fn add(x :: i64) {
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_x = false;
    for (checker.graph.bindings.items, 0..) |binding, i| {
        const name = checker.interner.get(binding.name);
        if (std.mem.eql(u8, name, "x")) {
            const ownership = checker.bindingOwnershipInfo(@intCast(i)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(TypeStore.I64, ownership.qualified_type.type_id);
            try std.testing.expectEqual(Ownership.shared, ownership.qualified_type.ownership);
            try std.testing.expectEqual(BindingOwnershipState.available, ownership.state);
            found_x = true;
        }
    }

    try std.testing.expect(found_x);
}

test "function ref inference defaults param ownerships to shared" {
    const source =
        \\pub module Test {
        \\  pub fn main(args :: Nil) -> (Nil -> Nil) {
        \\    Foo.main/1
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |err| {
        std.debug.print("ERR_MSG: [{s}]\n", .{err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const main_func = program.modules[0].items[0].function;
    const fn_ref_expr = main_func.clauses[0].body.?[0].expr;
    const inferred = try checker.inferExpr(fn_ref_expr);
    const typ = checker.store.getType(inferred);

    try std.testing.expect(typ == .function);
    try std.testing.expectEqual(@as(usize, 1), typ.function.params.len);
    try std.testing.expectEqual(@as(usize, 1), typ.function.param_ownerships.?.len);
    try std.testing.expectEqual(Ownership.shared, typ.function.param_ownerships.?[0]);
    try std.testing.expectEqual(Ownership.shared, typ.function.return_ownership);
}

test "moved binding use reports ownership error" {
    const source =
        \\pub module Test {
        \\  pub fn echo(x :: String) {
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.modules[0].items[0].function.clauses[0];
    const expr = clause.body.?[0].expr;
    const scope_id = checker.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
    checker.current_scope = scope_id;

    const x_binding = checker.graph.resolveBinding(scope_id, clause.params[0].pattern.bind.name).?;
    try checker.recordBindingOwnership(x_binding, TypeStore.STRING, .unique);
    try checker.markBindingMoved(x_binding);

    _ = try checker.inferExpr(expr);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "already moved") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "unique function parameter ownership moves var_ref argument" {
    const source =
        \\pub module Test {
        \\  pub fn caller(f, x) {
        \\    f(x)
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.modules[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
    checker.current_scope = scope_id;

    const f_binding = checker.graph.resolveBinding(scope_id, clause.params[0].pattern.bind.name).?;
    const x_binding = checker.graph.resolveBinding(scope_id, clause.params[1].pattern.bind.name).?;

    const param_ownerships = try alloc.alloc(Ownership, 1);
    param_ownerships[0] = .unique;
    const fn_type_id = try checker.store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, param_ownerships, .shared);
    try checker.recordBindingType(f_binding, fn_type_id, clause.params[0].meta.span);
    try checker.recordBindingOwnership(f_binding, fn_type_id, .shared);
    try checker.recordBindingType(x_binding, TypeStore.STRING, clause.params[1].meta.span);
    try checker.recordBindingOwnership(x_binding, TypeStore.STRING, .unique);

    checker.errors.clearRetainingCapacity();

    _ = try checker.inferExpr(clause.body.?[0].expr);
    _ = try checker.inferExpr(clause.body.?[1].expr);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "shared binding cannot satisfy unique parameter ownership" {
    const source =
        \\pub module Test {
        \\  pub fn caller(f, x) {
        \\    f(x)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.modules[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
    checker.current_scope = scope_id;

    const f_binding = checker.graph.resolveBinding(scope_id, clause.params[0].pattern.bind.name).?;
    const x_binding = checker.graph.resolveBinding(scope_id, clause.params[1].pattern.bind.name).?;

    const param_ownerships = try alloc.alloc(Ownership, 1);
    param_ownerships[0] = .unique;
    const fn_type_id = try checker.store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, param_ownerships, .shared);
    try checker.recordBindingType(f_binding, fn_type_id, clause.params[0].meta.span);
    try checker.recordBindingOwnership(f_binding, fn_type_id, .shared);
    try checker.recordBindingType(x_binding, TypeStore.STRING, clause.params[1].meta.span);
    try checker.recordBindingOwnership(x_binding, TypeStore.STRING, .shared);

    _ = try checker.inferExpr(clause.body.?[0].expr);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "cannot pass shared value") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "named call with unique parameter moves opaque binding" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn take(handle :: Handle) {
        \\    handle
        \\  }
        \\
        \\  pub fn run(handle :: Handle) {
        \\    take(handle)
        \\    handle
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "borrowed param annotation keeps binding usable after call" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn inspect(handle :: borrowed Handle) -> Nil {
        \\    nil
        \\  }
        \\
        \\  pub fn run(handle :: Handle) -> Handle {
        \\    inspect(handle)
        \\    handle
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "borrowed value cannot escape through return" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn inspect(handle :: borrowed Handle) {
        \\    handle
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "cannot escape through return") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be returned" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: borrowed Handle) {
        \\    fn use() {
        \\      handle
        \\    }
        \\
        \\    use
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "borrowed captures") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "unique capture moves outer binding" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: unique Handle) {
        \\    fn use() {
        \\      handle
        \\    }
        \\
        \\    inspect(use)
        \\    handle
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be passed as argument" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn apply(f :: (-> Handle)) {
        \\    f
        \\  }
        \\
        \\  pub fn make(handle :: borrowed Handle) {
        \\    fn use() {
        \\      handle
        \\    }
        \\
        \\    apply(use)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "cannot be passed as an argument") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be assigned" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: borrowed Handle) {
        \\    fn use() {
        \\      handle
        \\    }
        \\
        \\    f = use
        \\    f
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "assignment") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be stored in tuple" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: borrowed Handle) {
        \\    fn use() {
        \\      handle
        \\    }
        \\
        \\    {use}
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "tuple storage") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture may be locally invoked" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make(handle :: borrowed Handle) -> Bool {
        \\    fn use() -> Bool {
        \\      handle == handle
        \\    }
        \\
        \\    use()
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "closure with borrowed capture may be passed to known-safe callee" {
    const source =
        \\pub module Test {
        \\  opaque Handle = String
        \\
        \\  pub fn apply(f :: (borrowed Handle -> Bool), handle :: borrowed Handle) -> Bool {
        \\    f(handle)
        \\  }
        \\
        \\  pub fn make(handle :: borrowed Handle) -> Bool {
        \\    fn use(h :: borrowed Handle) -> Bool {
        \\      h == handle
        \\    }
        \\
        \\    apply(use, handle)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "borrowed parameter does not move binding" {
    const source =
        \\pub module Test {
        \\  pub fn caller(f, x) {
        \\    f(x)
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.modules[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(clause.meta.span.start) orelse clause.meta.scope_id;
    checker.current_scope = scope_id;

    const f_binding = checker.graph.resolveBinding(scope_id, clause.params[0].pattern.bind.name).?;
    const x_binding = checker.graph.resolveBinding(scope_id, clause.params[1].pattern.bind.name).?;

    const param_ownerships = try alloc.alloc(Ownership, 1);
    param_ownerships[0] = .borrowed;
    const fn_type_id = try checker.store.addFunctionType(&.{TypeStore.STRING}, TypeStore.STRING, param_ownerships, .shared);
    try checker.recordBindingType(f_binding, fn_type_id, clause.params[0].meta.span);
    try checker.recordBindingOwnership(f_binding, fn_type_id, .shared);
    try checker.recordBindingType(x_binding, TypeStore.STRING, clause.params[1].meta.span);
    try checker.recordBindingOwnership(x_binding, TypeStore.STRING, .unique);

    checker.errors.clearRetainingCapacity();
    _ = try checker.inferExpr(clause.body.?[0].expr);
    checker.errors.clearRetainingCapacity();
    _ = try checker.inferExpr(clause.body.?[1].expr);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
    const ownership = checker.bindingOwnershipInfo(x_binding).?;
    try std.testing.expectEqual(BindingOwnershipState.available, ownership.state);
}

test "return type mismatch has secondary span" {
    const source =
        \\pub module Test {
        \\  pub fn bad() -> i64 {
        \\    "not a number"
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err = checker.errors.items[0];
    try std.testing.expect(err.secondary_spans.len > 0);
    const ss_label = err.secondary_spans[0].label;
    try std.testing.expect(std.mem.indexOf(u8, ss_label, "return type") != null);
    try std.testing.expect(std.mem.indexOf(u8, ss_label, "i64") != null);
}

test "undefined function suggests similar name" {
    const source =
        \\pub module Test {
        \\  pub fn foo(a, b) {
        \\    a + b
        \\  }
        \\  pub fn bar() {
        \\    fob(1, 2)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have exactly one error about "fob/2" not found
    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "fob/2") != null) {
            found_err = true;
            // Should suggest foo/2
            if (err.help) |help| {
                try std.testing.expect(std.mem.indexOf(u8, help, "foo/2") != null);
            }
        }
    }
    try std.testing.expect(found_err);
}

test "undefined function no suggestion for unrelated name" {
    const source =
        \\pub module Test {
        \\  pub fn foo(a) {
        \\    a
        \\  }
        \\  pub fn bar() {
        \\    zzzzz(1)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have error but no suggestion
    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "zzzzz/1") != null) {
            found_err = true;
            try std.testing.expect(err.help == null);
        }
    }
    try std.testing.expect(found_err);
}

test "valid function call produces no error" {
    const source =
        \\pub module Test {
        \\  pub fn foo(a, b) {
        \\    a + b
        \\  }
        \\  pub fn bar() {
        \\    foo(1, 2)
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // No "cannot find function" errors
    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "cannot find a function") == null);
    }
}

test "unused variable produces warning" {
    const source =
        \\pub module Test {
        \\  pub fn foo() {
        \\    x = 42
        \\    1
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    var found_unused = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "variable `x` is unused") != null) {
            found_unused = true;
            try std.testing.expect(err.help != null);
            try std.testing.expect(std.mem.indexOf(u8, err.help.?, "_x") != null);
        }
    }
    try std.testing.expect(found_unused);
}

test "underscore-prefixed variable no unused warning" {
    const source =
        \\pub module Test {
        \\  pub fn foo() {
        \\    _x = 42
        \\    1
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "_x") == null);
    }
}

test "used variable no unused warning" {
    const source =
        \\pub module Test {
        \\  pub fn foo() {
        \\    x = 42
        \\    x + 1
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "variable `x` is unused") == null);
    }
}

test "variable used in zig intrinsic call is not unused" {
    const source =
        \\pub module Test {
        \\  pub fn greet(name :: String) -> String {
        \\    :zig.to_atom(name)
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

    var desugarer = @import("desugar.zig").Desugarer.init(alloc, parser.interner);
    const desugared = try desugarer.desugarProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&desugared);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "variable `name` is unused") == null);
    }
}

test "unknown type name produces error" {
    const source =
        \\pub module Test {
        \\  pub fn foo(x :: Other) {
        \\    x
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "cannot find a type named `Other`") != null) {
            found_err = true;
        }
    }
    try std.testing.expect(found_err);
}

test "unused function parameter produces warning" {
    const source =
        \\pub module Test {
        \\  pub fn foo(x :: i64) {
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

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    var found_unused = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "variable `x` is unused") != null) {
            found_unused = true;
        }
    }
    try std.testing.expect(found_unused);
}
