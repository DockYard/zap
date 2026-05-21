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
    /// Heterogeneous value type. Stand-in for `runtime.Term` when a
    /// list or map literal contains elements/values whose static types
    /// disagree. Construction sites lower to `Term.from(value)`;
    /// consumers unwrap via `Term.to(T, default)`.
    term_type,

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

    // Protocol constraint
    protocol_constraint: ProtocolConstraintType,

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
        /// Formal type-parameter slots declared on the struct header,
        /// one fresh `type_var` TypeId per name in `StructDecl.type_params`.
        /// Empty for concrete structs (the common case).
        ///
        /// At a use site like `Box(i64)` the type checker builds a
        /// `SubstitutionMap` binding `type_params[i]` -> `args[i]` and
        /// applies it through field type expressions. The same
        /// `type_var` IDs appear inside `fields[*].type_id` wherever
        /// the source mentioned the formal name (e.g. `value :: T`).
        type_params: []const TypeId = &.{},
    };

    pub const StructField = struct {
        name: ast.StringId,
        type_id: TypeId,
        default_expr: ?*const ast.Expr = null,
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
        /// Formal type-parameter slots declared on the union header,
        /// one fresh `type_var` TypeId per name in `UnionDecl.type_params`.
        /// Empty for concrete unions (the common case).
        ///
        /// At a use site like `Option(i64).Some(42)` the type checker
        /// builds a `SubstitutionMap` binding `type_params[i]` -> `args[i]`
        /// and applies it through variant payload types.
        type_params: []const TypeId = &.{},
    };
    pub const TaggedUnionVariant = struct {
        name: ast.StringId,
        type_id: ?TypeId = null, // null = unit variant
    };

    pub const OpaqueType = struct {
        name: ast.StringId,
        inner: TypeId,
    };

    pub const ProtocolConstraintType = struct {
        protocol_name: ast.StringId,
        type_params: []const TypeId,
    };
};

const ProtocolDispatchResolution = union(enum) {
    not_protocol,
    concrete: ast.StructName,
    constrained,
    invalid,
};

// ============================================================
// Type store
// ============================================================

/// Inferred signature for a compiler-generated function (e.g., __for_N helpers).
/// Populated by the type checker from call-site argument types; read by the HIR
/// builder when param/return annotations are null.
pub const InferredSignature = struct {
    param_types: []const TypeId,
    return_type: TypeId,
};

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    interner: *const ast.StringInterner,
    name_to_type: std.AutoHashMap(ast.StringId, TypeId),
    next_var: TypeVarId,
    /// Inferred signatures for generated functions, keyed by function name StringId.
    inferred_signatures: std.AutoHashMap(ast.StringId, InferredSignature),
    /// Struct TypeIds whose `field :: Type = expr` defaults have
    /// already been validated by `TypeChecker.validateStructFieldDefaults`.
    /// Lives on the TypeStore (not the TypeChecker) because the
    /// per-struct compilation pipeline in `compileStructByStruct`
    /// creates a fresh TypeChecker per struct against a shared
    /// TypeStore — without the store-scoped guard, the validator
    /// re-checks every previously-registered struct on every pass
    /// and the same diagnostic prints N times for N structs.
    validated_default_struct_ids: std.AutoHashMap(TypeId, void),

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
    pub const TERM: TypeId = 20;
    pub const I128: TypeId = 21;
    pub const U128: TypeId = 22;
    pub const F80: TypeId = 23;
    pub const F128: TypeId = 24;
    pub const VOID: TypeId = NIL;

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .types = .empty,
            .interner = interner,
            .name_to_type = std.AutoHashMap(ast.StringId, TypeId).init(allocator),
            .next_var = 0,
            .inferred_signatures = std.AutoHashMap(ast.StringId, InferredSignature).init(allocator),
            .validated_default_struct_ids = std.AutoHashMap(TypeId, void).init(allocator),
        };
        store.registerBuiltins() catch {};
        return store;
    }

    pub fn deinit(self: *TypeStore) void {
        self.types.deinit(self.allocator);
        self.name_to_type.deinit();
        self.inferred_signatures.deinit();
        self.validated_default_struct_ids.deinit();
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
        try self.types.append(self.allocator, .term_type); // 20
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 128 } }); // 21 - i128
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 128 } }); // 22 - u128
        try self.types.append(self.allocator, .{ .float = .{ .bits = 80 } }); // 23 - f80
        try self.types.append(self.allocator, .{ .float = .{ .bits = 128 } }); // 24 - f128
    }

    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        // Structural deduplication (InternPool pattern).
        switch (typ) {
            .type_var, .unknown, .error_type => {},
            else => {
                for (self.types.items, 0..) |existing, idx| {
                    if (typeStructEq(existing, typ)) return @intCast(idx);
                }
            },
        }
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(self.allocator, typ);
        return id;
    }

    fn typeStructEq(a: Type, b: Type) bool {
        const at = std.meta.activeTag(a);
        const bt = std.meta.activeTag(b);
        if (at != bt) return false;
        return switch (a) {
            .int => |i| i.signedness == b.int.signedness and i.bits == b.int.bits,
            .float => |f| f.bits == b.float.bits,
            .bool_type, .string_type, .atom_type, .nil_type, .never, .unknown, .error_type, .term_type => true,
            .type_var => false,
            .list => |l| l.element == b.list.element,
            .tuple => |t| std.mem.eql(TypeId, t.elements, b.tuple.elements),
            .function => |f| f.return_type == b.function.return_type and std.mem.eql(TypeId, f.params, b.function.params) and ownershipSlicesEqual(f.param_ownerships, b.function.param_ownerships) and f.return_ownership == b.function.return_ownership,
            .map => |m| m.key == b.map.key and m.value == b.map.value,
            .struct_type => |s| s.name == b.struct_type.name,
            .tagged_union => |t| t.name == b.tagged_union.name,
            .opaque_type => |o| o.name == b.opaque_type.name,
            .applied => |ap| ap.base == b.applied.base and std.mem.eql(TypeId, ap.args, b.applied.args),
            .union_type => |u| std.mem.eql(TypeId, u.members, b.union_type.members),
            .protocol_constraint => |pc| pc.protocol_name == b.protocol_constraint.protocol_name and std.mem.eql(TypeId, pc.type_params, b.protocol_constraint.type_params),
        };
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
        // `Term` is the surface name for the dynamic-value type that
        // arises when a compile-time map literal mixes value types
        // (e.g. baked reflection summaries with both `String` doc
        // text and `Bool` is_private). It's distinct from `any`
        // (which maps to UNKNOWN) — Term is the actual unioned-value
        // category produced by heterogeneous CtValue maps.
        if (std.mem.eql(u8, name, "Term")) return TERM;
        if (std.mem.eql(u8, name, "Bool")) return BOOL;
        if (std.mem.eql(u8, name, "String")) return STRING;
        if (std.mem.eql(u8, name, "Atom")) return ATOM;
        if (std.mem.eql(u8, name, "Nil")) return NIL;
        if (std.mem.eql(u8, name, "Void")) return VOID;
        if (std.mem.eql(u8, name, "Never")) return NEVER;
        if (std.mem.eql(u8, name, "i128")) return I128;
        if (std.mem.eql(u8, name, "i64")) return I64;
        if (std.mem.eql(u8, name, "i32")) return I32;
        if (std.mem.eql(u8, name, "i16")) return I16;
        if (std.mem.eql(u8, name, "i8")) return I8;
        if (std.mem.eql(u8, name, "u128")) return U128;
        if (std.mem.eql(u8, name, "u64")) return U64;
        if (std.mem.eql(u8, name, "u32")) return U32;
        if (std.mem.eql(u8, name, "u16")) return U16;
        if (std.mem.eql(u8, name, "u8")) return U8;
        if (std.mem.eql(u8, name, "f128")) return F128;
        if (std.mem.eql(u8, name, "f80")) return F80;
        if (std.mem.eql(u8, name, "f64")) return F64;
        if (std.mem.eql(u8, name, "f32")) return F32;
        if (std.mem.eql(u8, name, "f16")) return F16;
        if (std.mem.eql(u8, name, "usize")) return USIZE;
        if (std.mem.eql(u8, name, "isize")) return ISIZE;
        // Macro meta-types — see `ast.MacroSpliceKind`. The type
        // checker treats all splice categories as UNKNOWN (no
        // constraint) because the actual validation lives in the
        // macro engine, where the bound CtValue's shape can be
        // checked at expansion time. Adding a name here without a
        // corresponding entry in `MacroSpliceKind.fromName` would
        // silently widen the meta-type set; keep the two in sync.
        if (ast.MacroSpliceKind.fromName(name) != null) return UNKNOWN;
        if (std.mem.eql(u8, name, "any")) return UNKNOWN;
        return null;
    }

    /// Get the canonical struct name for a type.
    /// For user-defined types (structs, unions), returns the declared name.
    /// For built-in types, returns the language-defined struct name.
    /// Returns null for types that don't have a corresponding struct
    /// (nil, never, type variables, etc.).
    pub fn typeToStructName(self: *const TypeStore, type_id: TypeId, interner: *const ast.StringInterner) ?[]const u8 {
        if (type_id >= self.types.items.len) return null;
        const typ = self.types.items[type_id];
        return switch (typ) {
            .struct_type => |s| interner.get(s.name),
            .tagged_union => |tu| interner.get(tu.name),
            .list => "List",
            .map => "Map",
            .string_type => "String",
            .int => "Integer",
            .float => "Float",
            .bool_type => "Bool",
            .atom_type => "Atom",
            .tuple => "Tuple",
            .function => "Function",
            else => null,
        };
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
        // `Term` accepts any concrete type — heterogeneous-storage
        // values wrap/unwrap at the codegen boundary, so a position
        // expecting `Term` is satisfied by every concrete type and a
        // position expecting a concrete type is satisfied by `Term`
        // (the runtime helper handles the unwrap with a default).
        // Without this the monomorphic-call check at `inferCall`
        // flags every heterogeneous tuple/list literal — e.g. the
        // keyword list `[name: "Brian", age: 42]` whose element type
        // collapses to `{Atom, Term}` — as a type mismatch against a
        // declared `[{Atom, i64}]` parameter, even though unify (the
        // generic path) already accepts the call.
        if (ta == .term_type or tb == .term_type) return true;
        // Generic signatures compare structurally even when fresh type-variable
        // IDs differ across separate resolution passes.
        if (ta == .type_var and tb == .type_var) return true;

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

        // Protocol constraints match any type — verification deferred to monomorphization
        if (ta == .protocol_constraint or tb == .protocol_constraint) return true;

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

        // Parametric type comparison: two applications are equal
        // when both base and every argument compare structurally.
        if (ta == .applied and tb == .applied) {
            if (ta.applied.base != tb.applied.base and !self.typeEquals(ta.applied.base, tb.applied.base)) return false;
            if (ta.applied.args.len != tb.applied.args.len) return false;
            for (ta.applied.args, tb.applied.args) |arg_a, arg_b| {
                if (!self.typeEquals(arg_a, arg_b)) return false;
            }
            return true;
        }
        // An applied instantiation `Box(i64)` matches the bare
        // declaration `Box`. The bare-declaration form represents
        // "any specialisation of this declaration" — that's how
        // user code today writes generic return types like
        // `pub fn build() -> Box` and how impl-method signatures
        // resolve protocol receivers. Symmetric in both
        // directions so the comparison rule is reversible.
        if (ta == .applied and (tb == .struct_type or tb == .tagged_union)) {
            if (ta.applied.base == b) return true;
        }
        if (tb == .applied and (ta == .struct_type or ta == .tagged_union)) {
            if (tb.applied.base == a) return true;
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

    /// Check if a value of type `from` can be implicitly widened to type `to`.
    /// Widening is a fallback after exact overload selection and never crosses
    /// numeric families:
    ///   Signed integers: i8→i16→i32→i64→i128
    ///   Unsigned integers: u8→u16→u32→u64→u128
    ///   Floats: f16→f32→f64→f80→f128
    /// No signed↔unsigned or int↔float widening is implicit.
    pub fn canWidenTo(self: *const TypeStore, from: TypeId, to: TypeId) bool {
        return self.wideningCost(from, to) != null;
    }

    /// Return the bit-width delta for a valid implicit widening. Lower costs
    /// are more specific during overload fallback (`i8 -> i16` beats
    /// `i8 -> i64`). Null means no implicit widening is permitted.
    pub fn wideningCost(self: *const TypeStore, from: TypeId, to: TypeId) ?u32 {
        if (from == to) return null;
        if (from == UNKNOWN or to == UNKNOWN) return null;
        const from_t = self.getType(from);
        const to_t = self.getType(to);

        // Integer widening
        if (from_t == .int and to_t == .int) {
            const f = from_t.int;
            const t = to_t.int;
            if (f.signedness == t.signedness) {
                if (t.bits > f.bits) return @as(u32, t.bits - f.bits);
                return null;
            }
            return null;
        }

        // Float widening
        if (from_t == .float and to_t == .float) {
            if (to_t.float.bits > from_t.float.bits) return @as(u32, to_t.float.bits - from_t.float.bits);
            return null;
        }

        return null;
    }

    /// Score a call argument against an expected parameter type.
    /// Exact compatibility is 0; widening fallback is 1 + bit delta; null
    /// means the argument cannot satisfy the parameter.
    pub fn callMatchCost(self: *const TypeStore, actual: TypeId, expected: TypeId) ?u32 {
        if (expected == UNKNOWN or actual == UNKNOWN or actual == ERROR) return 0;
        if (self.typeEquals(actual, expected)) return 0;
        if (self.wideningCost(actual, expected)) |cost| return cost + 1;
        return null;
    }

    // ============================================================
    // Type unification
    // ============================================================

    /// Check whether `type_id` contains any type variables (`.type_var`) in its structure.
    /// Used to determine whether a function signature is generic and requires unification.
    pub fn containsTypeVars(self: *const TypeStore, type_id: TypeId) bool {
        const typ = self.getType(type_id);
        return switch (typ) {
            .type_var => true,
            .list => |list_type| self.containsTypeVars(list_type.element),
            .tuple => |tuple_type| {
                for (tuple_type.elements) |element| {
                    if (self.containsTypeVars(element)) return true;
                }
                return false;
            },
            .function => |function_type| {
                for (function_type.params) |param| {
                    if (self.containsTypeVars(param)) return true;
                }
                return self.containsTypeVars(function_type.return_type);
            },
            .map => |map_type| {
                return self.containsTypeVars(map_type.key) or
                    self.containsTypeVars(map_type.value);
            },
            .applied => |applied_type| {
                if (self.containsTypeVars(applied_type.base)) return true;
                for (applied_type.args) |arg| {
                    if (self.containsTypeVars(arg)) return true;
                }
                return false;
            },
            .protocol_constraint => |pc| {
                for (pc.type_params) |tp| {
                    if (self.containsTypeVars(tp)) return true;
                }
                return false;
            },
            // Primitives and non-compound types cannot contain type variables
            .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .unknown, .error_type, .term_type => false,
            .struct_type, .union_type, .tagged_union, .opaque_type => false,
        };
    }

    /// Check whether `var_id` occurs anywhere inside the type referenced by `type_id`.
    /// Used as an occurs check to prevent constructing infinite types during unification.
    pub fn occursIn(self: *const TypeStore, var_id: TypeVarId, type_id: TypeId, subs: *const SubstitutionMap) bool {
        const typ = self.getType(type_id);
        return switch (typ) {
            .type_var => |other_var_id| {
                if (other_var_id == var_id) return true;
                // If this var is already bound, check what it's bound to
                if (subs.resolve(other_var_id)) |resolved| {
                    return self.occursIn(var_id, resolved, subs);
                }
                return false;
            },
            .list => |list_type| self.occursIn(var_id, list_type.element, subs),
            .tuple => |tuple_type| {
                for (tuple_type.elements) |element| {
                    if (self.occursIn(var_id, element, subs)) return true;
                }
                return false;
            },
            .function => |function_type| {
                for (function_type.params) |param| {
                    if (self.occursIn(var_id, param, subs)) return true;
                }
                return self.occursIn(var_id, function_type.return_type, subs);
            },
            .map => |map_type| {
                return self.occursIn(var_id, map_type.key, subs) or
                    self.occursIn(var_id, map_type.value, subs);
            },
            .applied => |applied_type| {
                if (self.occursIn(var_id, applied_type.base, subs)) return true;
                for (applied_type.args) |arg| {
                    if (self.occursIn(var_id, arg, subs)) return true;
                }
                return false;
            },
            .protocol_constraint => |pc| {
                for (pc.type_params) |tp| {
                    if (self.occursIn(var_id, tp, subs)) return true;
                }
                return false;
            },
            // Primitives and non-compound types cannot contain type variables
            .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .unknown, .error_type, .term_type => false,
            .struct_type, .union_type, .tagged_union, .opaque_type => false,
        };
    }

    /// Resolve a type_id through existing substitutions to its current representative.
    /// If the type is a type variable that is bound, follow the chain.
    fn resolveTypeVar(self: *const TypeStore, type_id: TypeId, subs: *const SubstitutionMap) TypeId {
        const typ = self.getType(type_id);
        if (typ == .type_var) {
            if (subs.resolve(typ.type_var)) |resolved| {
                return self.resolveTypeVar(resolved, subs);
            }
        }
        return type_id;
    }

    /// Unify two types, populating `subs` with type variable bindings.
    /// Returns true if the types can be unified, false if they are incompatible.
    ///
    /// Rules:
    /// - If both type IDs are identical, they unify trivially.
    /// - UNKNOWN unifies with anything (wildcard for inference).
    /// - A type variable binds to the other type (with occurs check).
    /// - Compound types (list, tuple, function, map) unify structurally.
    /// - Primitives must match exactly.
    pub fn unify(self: *const TypeStore, a: TypeId, b: TypeId, subs: *SubstitutionMap) !bool {
        // Resolve both sides through any existing substitutions
        const resolved_a = self.resolveTypeVar(a, subs);
        const resolved_b = self.resolveTypeVar(b, subs);

        // Identical type IDs always unify
        if (resolved_a == resolved_b) return true;

        const type_a = self.getType(resolved_a);
        const type_b = self.getType(resolved_b);

        // UNKNOWN unifies with anything
        if (type_a == .unknown or type_b == .unknown) return true;

        // `Term` unifies with any concrete type without binding the
        // typevar — heterogeneous storage tolerates every value type
        // via runtime wrapping, so a typevar constrained by `Term` is
        // free to bind to a more specific concrete type later (e.g.
        // the caller's expected default type), with the wrap/unwrap
        // inserted at the codegen boundary. Likewise, when `Term`
        // appears on the rhs of an already-concrete typevar the
        // unification succeeds without altering the binding.
        //
        // Record the Term constraint on any typevar side so that
        // `applyToReturnType` can later promote container-position
        // occurrences of the typevar back to `Term`. Without this,
        // a heterogeneous-map argument to `Map.update(map :: %{K=>V},
        // key :: K, value :: V) -> %{K=>V}` would "lose" the `Term`
        // constraint on `V` once a subsequent scalar argument like
        // `value="Bob"` (String) bound `V → String`, and the call's
        // return type would collapse to `%{Atom=>String}` instead of
        // remaining `%{Atom=>Term}`.
        if (type_a == .term_type or type_b == .term_type) {
            if (type_a == .type_var) subs.markTermConstrained(type_a.type_var);
            if (type_b == .type_var) subs.markTermConstrained(type_b.type_var);
            return true;
        }

        // If a is a type variable, bind it to b (with occurs check)
        if (type_a == .type_var) {
            if (self.occursIn(type_a.type_var, resolved_b, subs)) return false;
            subs.bind(type_a.type_var, resolved_b);
            return true;
        }

        // If b is a type variable, bind it to a (with occurs check)
        if (type_b == .type_var) {
            if (self.occursIn(type_b.type_var, resolved_a, subs)) return false;
            subs.bind(type_b.type_var, resolved_a);
            return true;
        }

        // Protocol constraints accept any type — dispatch verified at monomorphization
        if (type_a == .protocol_constraint or type_b == .protocol_constraint) return true;

        // Both are list types: unify element types
        if (type_a == .list and type_b == .list) {
            return self.unify(type_a.list.element, type_b.list.element, subs);
        }

        // Both are tuple types: must have same length, unify pairwise
        if (type_a == .tuple and type_b == .tuple) {
            if (type_a.tuple.elements.len != type_b.tuple.elements.len) return false;
            for (type_a.tuple.elements, type_b.tuple.elements) |elem_a, elem_b| {
                if (!try self.unify(elem_a, elem_b, subs)) return false;
            }
            return true;
        }

        // Both are function types: must have same param count, unify params and return
        if (type_a == .function and type_b == .function) {
            if (type_a.function.params.len != type_b.function.params.len) return false;
            for (type_a.function.params, type_b.function.params) |param_a, param_b| {
                if (!try self.unify(param_a, param_b, subs)) return false;
            }
            return self.unify(type_a.function.return_type, type_b.function.return_type, subs);
        }

        // Both are map types: unify key and value types
        if (type_a == .map and type_b == .map) {
            if (!try self.unify(type_a.map.key, type_b.map.key, subs)) return false;
            return self.unify(type_a.map.value, type_b.map.value, subs);
        }

        // Both are the same primitive kind: check they're structurally identical
        // (int with matching signedness/bits, float with matching bits, etc.)
        if (type_a == .int and type_b == .int) {
            return type_a.int.signedness == type_b.int.signedness and
                type_a.int.bits == type_b.int.bits;
        }
        if (type_a == .float and type_b == .float) {
            return type_a.float.bits == type_b.float.bits;
        }
        if (type_a == .bool_type and type_b == .bool_type) return true;
        if (type_a == .string_type and type_b == .string_type) return true;
        if (type_a == .atom_type and type_b == .atom_type) return true;
        if (type_a == .nil_type and type_b == .nil_type) return true;
        if (type_a == .never and type_b == .never) return true;

        // Incompatible types
        return false;
    }
};

// ============================================================
// Substitution map for type variable bindings
// ============================================================

pub const SubstitutionMap = struct {
    bindings: std.AutoHashMap(TypeVarId, TypeId),
    /// Type variables that were unified against `Term` at some point
    /// during the call's argument check. These are *not* bound in
    /// `bindings` because the existing unify rule treats `Term` as a
    /// universal acceptor without binding the typevar (so that a
    /// later argument supplying a more specific concrete type can
    /// still bind the var, e.g. the scalar default of `Map.get`).
    /// We track the constraint separately so the *return-type*
    /// resolver can decide, position-by-position, whether the
    /// typevar should resolve to its concrete binding (scalar
    /// positions, e.g. `default :: V` flowing into `-> V`) or stay
    /// as `Term` (container positions, e.g. `-> %{K=>V}` for
    /// `Map.update` against a heterogeneous map). Mirrors the
    /// monomorphizer's `promoteContainerVarsExceptScalarReturn`
    /// logic at the type-checker layer.
    term_constrained: std.AutoHashMap(TypeVarId, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SubstitutionMap {
        return .{
            .bindings = std.AutoHashMap(TypeVarId, TypeId).init(allocator),
            .term_constrained = std.AutoHashMap(TypeVarId, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubstitutionMap) void {
        self.bindings.deinit();
        self.term_constrained.deinit();
    }

    /// Bind a type variable to a concrete type.
    pub fn bind(self: *SubstitutionMap, var_id: TypeVarId, type_id: TypeId) void {
        self.bindings.put(var_id, type_id) catch {};
    }

    /// Mark a type variable as Term-constrained — i.e. it appeared at
    /// a position where the argument type was `Term`. Recorded so
    /// `applyToReturnType` can promote container-position
    /// occurrences back to `Term` even when the var also acquired a
    /// concrete binding from a scalar argument.
    pub fn markTermConstrained(self: *SubstitutionMap, var_id: TypeVarId) void {
        self.term_constrained.put(var_id, {}) catch {};
    }

    pub fn isTermConstrained(self: *const SubstitutionMap, var_id: TypeVarId) bool {
        return self.term_constrained.contains(var_id);
    }

    /// Look up the binding for a type variable.
    /// Returns null if the variable is unbound.
    pub fn resolve(self: *const SubstitutionMap, var_id: TypeVarId) ?TypeId {
        return self.bindings.get(var_id);
    }

    /// Apply all substitutions to a type, recursively replacing type variables
    /// with their bound types. Returns a new TypeId for compound types where
    /// substitutions occurred; returns the original TypeId for primitives or
    /// unbound variables.
    pub fn applyToType(self: *const SubstitutionMap, store: *TypeStore, type_id: TypeId) TypeId {
        const typ = store.getType(type_id);
        return switch (typ) {
            .type_var => |var_id| {
                if (self.resolve(var_id)) |bound_type| {
                    // Recursively apply in case the bound type also contains vars
                    return self.applyToType(store, bound_type);
                }
                return type_id;
            },
            .list => |list_type| {
                const new_element = self.applyToType(store, list_type.element);
                if (new_element == list_type.element) return type_id;
                return store.addType(.{ .list = .{ .element = new_element } }) catch type_id;
            },
            .tuple => |tuple_type| {
                var changed = false;
                const new_elements = store.allocator.alloc(TypeId, tuple_type.elements.len) catch return type_id;
                for (tuple_type.elements, 0..) |element, index| {
                    const new_element = self.applyToType(store, element);
                    new_elements[index] = new_element;
                    if (new_element != element) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_elements);
                    return type_id;
                }
                return store.addType(.{ .tuple = .{ .elements = new_elements } }) catch type_id;
            },
            .function => |function_type| {
                var changed = false;
                const new_params = store.allocator.alloc(TypeId, function_type.params.len) catch return type_id;
                for (function_type.params, 0..) |param, index| {
                    const new_param = self.applyToType(store, param);
                    new_params[index] = new_param;
                    if (new_param != param) changed = true;
                }
                const new_return = self.applyToType(store, function_type.return_type);
                if (new_return != function_type.return_type) changed = true;
                if (!changed) {
                    store.allocator.free(new_params);
                    return type_id;
                }
                return store.addType(.{ .function = .{
                    .params = new_params,
                    .return_type = new_return,
                    .param_ownerships = function_type.param_ownerships,
                    .return_ownership = function_type.return_ownership,
                } }) catch type_id;
            },
            .map => |map_type| {
                const new_key = self.applyToType(store, map_type.key);
                const new_value = self.applyToType(store, map_type.value);
                if (new_key == map_type.key and new_value == map_type.value) return type_id;
                return store.addType(.{ .map = .{
                    .key = new_key,
                    .value = new_value,
                } }) catch type_id;
            },
            .protocol_constraint => |pc| {
                var changed = false;
                const new_params = store.allocator.alloc(TypeId, pc.type_params.len) catch return type_id;
                for (pc.type_params, 0..) |tp, index| {
                    const new_tp = self.applyToType(store, tp);
                    new_params[index] = new_tp;
                    if (new_tp != tp) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_params);
                    return type_id;
                }
                return store.addType(.{ .protocol_constraint = .{
                    .protocol_name = pc.protocol_name,
                    .type_params = new_params,
                } }) catch type_id;
            },
            .applied => |applied_type| {
                // A parametric type instantiation `Box(T)` -> `Box(i64)`:
                // substitute every formal `type_var` in `args` so nested
                // generics like `Box(Option(T))` rewrite their inner
                // arguments at the call site. The `base` field already
                // points at a declaration's StructType / TaggedUnionType
                // — those declarations are immutable; only the
                // instantiation's argument tuple changes.
                var changed = false;
                const new_args = store.allocator.alloc(TypeId, applied_type.args.len) catch return type_id;
                for (applied_type.args, 0..) |arg, index| {
                    const new_arg = self.applyToType(store, arg);
                    new_args[index] = new_arg;
                    if (new_arg != arg) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_args);
                    return type_id;
                }
                return store.addType(.{ .applied = .{
                    .base = applied_type.base,
                    .args = new_args,
                } }) catch type_id;
            },
            // Primitives and other types pass through unchanged
            .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .unknown, .error_type, .term_type => type_id,
            // Nominal-type declarations (struct, union, tagged-union,
            // opaque) are *declarations*, not instantiations — their
            // field/variant payload types are fixed by the source. An
            // instantiation lives in `.applied { base, args }`. Pass
            // these through unchanged.
            .struct_type, .union_type, .tagged_union, .opaque_type => type_id,
        };
    }

    /// Apply substitutions to a return-type, distinguishing scalar
    /// from container positions. Type variables that were
    /// `Term`-constrained during argument unification are promoted
    /// to `Term` at container positions; at scalar positions they
    /// fall back to whatever concrete binding the substitution map
    /// recorded (so `Map.get(map :: %{K=>V}, key :: K, default :: V)
    /// -> V` still types as the default's concrete type, while
    /// `Map.update(... ) -> %{K=>V}` types as `%{K=>Term}` when the
    /// map was heterogeneous).
    ///
    /// Mirrors `monomorphize.promoteContainerVarsExceptScalarReturn`
    /// at the type-checker layer so call-site argument validation
    /// agrees with the eventual specialised signature.
    pub fn applyToReturnType(self: *const SubstitutionMap, store: *TypeStore, type_id: TypeId) TypeId {
        return self.applyToReturnTypeImpl(store, type_id, true);
    }

    fn applyToReturnTypeImpl(self: *const SubstitutionMap, store: *TypeStore, type_id: TypeId, scalar_position: bool) TypeId {
        const typ = store.getType(type_id);
        return switch (typ) {
            .type_var => |var_id| {
                // At container positions, a Term-constrained typevar
                // resolves to `Term` regardless of any concrete
                // binding it picked up from a scalar argument.
                if (!scalar_position and self.isTermConstrained(var_id)) {
                    return TypeStore.TERM;
                }
                if (self.resolve(var_id)) |bound_type| {
                    return self.applyToReturnTypeImpl(store, bound_type, scalar_position);
                }
                return type_id;
            },
            .list => |list_type| {
                const new_element = self.applyToReturnTypeImpl(store, list_type.element, false);
                if (new_element == list_type.element) return type_id;
                return store.addType(.{ .list = .{ .element = new_element } }) catch type_id;
            },
            .tuple => |tuple_type| {
                var changed = false;
                const new_elements = store.allocator.alloc(TypeId, tuple_type.elements.len) catch return type_id;
                for (tuple_type.elements, 0..) |element, index| {
                    const new_element = self.applyToReturnTypeImpl(store, element, false);
                    new_elements[index] = new_element;
                    if (new_element != element) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_elements);
                    return type_id;
                }
                return store.addType(.{ .tuple = .{ .elements = new_elements } }) catch type_id;
            },
            .function => |function_type| {
                var changed = false;
                const new_params = store.allocator.alloc(TypeId, function_type.params.len) catch return type_id;
                for (function_type.params, 0..) |param, index| {
                    const new_param = self.applyToReturnTypeImpl(store, param, false);
                    new_params[index] = new_param;
                    if (new_param != param) changed = true;
                }
                const new_return = self.applyToReturnTypeImpl(store, function_type.return_type, scalar_position);
                if (new_return != function_type.return_type) changed = true;
                if (!changed) {
                    store.allocator.free(new_params);
                    return type_id;
                }
                return store.addType(.{ .function = .{
                    .params = new_params,
                    .return_type = new_return,
                    .param_ownerships = function_type.param_ownerships,
                    .return_ownership = function_type.return_ownership,
                } }) catch type_id;
            },
            .map => |map_type| {
                const new_key = self.applyToReturnTypeImpl(store, map_type.key, false);
                const new_value = self.applyToReturnTypeImpl(store, map_type.value, false);
                if (new_key == map_type.key and new_value == map_type.value) return type_id;
                return store.addType(.{ .map = .{
                    .key = new_key,
                    .value = new_value,
                } }) catch type_id;
            },
            .protocol_constraint => |pc| {
                var changed = false;
                const new_params = store.allocator.alloc(TypeId, pc.type_params.len) catch return type_id;
                for (pc.type_params, 0..) |tp, index| {
                    const new_tp = self.applyToReturnTypeImpl(store, tp, false);
                    new_params[index] = new_tp;
                    if (new_tp != tp) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_params);
                    return type_id;
                }
                return store.addType(.{ .protocol_constraint = .{
                    .protocol_name = pc.protocol_name,
                    .type_params = new_params,
                } }) catch type_id;
            },
            .applied => |applied_type| {
                // Generic instantiation arguments are *container*
                // positions for Term-promotion purposes — mirrors how
                // a list element or map value is treated.
                var changed = false;
                const new_args = store.allocator.alloc(TypeId, applied_type.args.len) catch return type_id;
                for (applied_type.args, 0..) |arg, index| {
                    const new_arg = self.applyToReturnTypeImpl(store, arg, false);
                    new_args[index] = new_arg;
                    if (new_arg != arg) changed = true;
                }
                if (!changed) {
                    store.allocator.free(new_args);
                    return type_id;
                }
                return store.addType(.{ .applied = .{
                    .base = applied_type.base,
                    .args = new_args,
                } }) catch type_id;
            },
            .int, .float, .bool_type, .string_type, .atom_type, .nil_type, .never, .unknown, .error_type, .term_type => type_id,
            // Nominal-type declarations pass through; instantiations
            // travel through `.applied`.
            .struct_type, .union_type, .tagged_union, .opaque_type => type_id,
        };
    }
};

// ============================================================

/// Apply the same Zig-identifier mangling that `ir.mangleSymbolForZig` uses.
/// Kept here (rather than imported) to avoid cyclic dep between types.zig
/// and ir.zig — the type checker queries the analysis IR by name, so it
/// needs to reproduce the same mangling at lookup time.
fn mangleNameForIr(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (name.len == 0) return allocator.dupe(u8, name) catch null;
    var needs_mangle = false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => {},
            else => {
                needs_mangle = true;
                break;
            },
        }
    }
    if (!needs_mangle) return allocator.dupe(u8, name) catch null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (name) |c| {
        const piece: []const u8 = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => &.{c},
            '+' => "_plus",
            '-' => "_minus",
            '*' => "_star",
            '/' => "_slash",
            '<' => "_lt",
            '>' => "_gt",
            '=' => "_eq",
            '|' => "_pipe",
            '&' => "_amp",
            '^' => "_caret",
            '~' => "_tilde",
            '%' => "_pct",
            '@' => "_at",
            '#' => "_hash",
            '$' => "_dollar",
            '.' => "_dot",
            ':' => "_colon",
            else => "_x",
        };
        buf.appendSlice(allocator, piece) catch return null;
    }
    return buf.toOwnedSlice(allocator) catch null;
}

/// Join a multi-segment struct name with `_` (single underscore), matching
/// `IrBuilder.structNameToPrefix`. Returns `null` only on allocation failure.
fn joinStructNameWithUnderscore(allocator: std.mem.Allocator, interner: *const ast.StringInterner, name: ast.StructName) ?[]u8 {
    if (name.parts.len == 0) return null;
    const joined = name.joinedWith(allocator, interner, "_") catch return null;
    return @constCast(joined);
}

// ============================================================
// Type checker
// ============================================================

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    store: *TypeStore,
    owns_store: bool = true,
    interner: *const ast.StringInterner,
    graph: *scope_mod.ScopeGraph,
    errors: std.ArrayList(Error),

    // Expression type mapping. Used as a memo cache by `inferExpr` to
    // collapse the O(2^N) redundant re-inference of nested-call AST
    // pointers across the ~14 sites in `inferCall` that all walk the
    // same arg slice. The cache only persists for the duration of a
    // single top-level `inferExpr` invocation — `infer_depth` tracks
    // recursion depth and the cache is cleared when depth returns to
    // zero so external callers (e.g. tests that manipulate ownership
    // state between `inferExpr` calls) always get fresh side-effect
    // handling. See task #15 PART 2 for the full diagnosis.
    expr_types: std.AutoHashMap(usize, TypeId),
    infer_depth: u32 = 0,

    // Current scope tracking for var_ref resolution
    current_scope: ?scope_mod.ScopeId,

    // Track which bindings are referenced (for unused variable warnings)
    referenced_bindings: std.AutoHashMap(scope_mod.BindingId, void),

    // Ownership metadata for bindings. Phase 1 stores the foundation here,
    // but enforcement comes later.
    ownership_bindings: std.AutoHashMap(scope_mod.BindingId, BindingOwnershipInfo),
    analysis_context: ?*const escape_lattice.AnalysisContext,
    analysis_program: ?*const ir.Program,

    /// Maps type variable names to TypeIds within the current function scope.
    /// Reset at the start of each function clause check so that `a` in
    /// `fn foo(x :: a) -> a` refers to the same type variable.
    type_var_scope: std.StringHashMap(TypeId),

    /// Set when checking the body of an `impl Protocol for Target(K, V)`
    /// block — the impl's declared type parameters are pre-bound into
    /// `type_var_scope` at the start of every clause check so references
    /// like `K` and `V` in the impl's function signatures resolve to the
    /// impl's own type variables (consistent across params and return).
    current_impl: ?*const ast.ImplDecl = null,

    // Number of stdlib lines prepended (bindings in these lines are skipped for unused checks)
    stdlib_line_count: u32 = 0,

    /// Names of synthetic helpers whose declaration is currently being
    /// type-checked. Guards against the recursive helper call that desugar
    /// emits inside `__for_N` triggering an infinite eager re-check loop.
    eager_helper_in_flight: std.AutoHashMap(ast.StringId, void) = undefined,

    /// Build-manifest CTFE compiles `build.zap` before target/dependency
    /// sources are known. In that pass, first-class `Type` and `Function`
    /// values may intentionally name declarations outside the manifest graph.
    /// Regular project compilation keeps this false so type references remain
    /// strict everywhere else.
    allow_external_static_references: bool = false,

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
        label: ?[]const u8 = null,
        help: ?[]const u8 = null,
        secondary_spans: []const @import("diagnostics.zig").SecondarySpan = &.{},
        /// Optional override for the diagnostic severity. Defaults to
        /// `.@"error"` at the pipeline. Used by checks that intentionally
        /// emit at a different severity (e.g. lints).
        severity: ?@import("diagnostics.zig").Severity = null,
    };

    const ResolvedCallSignature = struct {
        signature: FunctionSignature,
        family_id: scope_mod.FunctionFamilyId,
        clause_index: u32,
    };

    const TypeReference = struct {
        type_id: TypeId,
        name: ast.StringId,
    };

    const FunctionReferenceTarget = struct {
        scope_id: scope_mod.ScopeId,
        family_id: scope_mod.FunctionFamilyId,
        declared_arity: u32,
    };

    const StaticFunctionValue = struct {
        struct_name: ast.StructName,
        function_name: ast.StringId,
        arity: u32,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner, graph: *scope_mod.ScopeGraph) TypeChecker {
        const store = allocator.create(TypeStore) catch @panic("OOM");
        store.* = TypeStore.init(allocator, interner);
        return .{
            .allocator = allocator,
            .store = store,
            .owns_store = true,
            .interner = interner,
            .graph = graph,
            .errors = .empty,
            .expr_types = std.AutoHashMap(usize, TypeId).init(allocator),
            .current_scope = null,
            .referenced_bindings = std.AutoHashMap(scope_mod.BindingId, void).init(allocator),
            .ownership_bindings = std.AutoHashMap(scope_mod.BindingId, BindingOwnershipInfo).init(allocator),
            .analysis_context = null,
            .analysis_program = null,
            .type_var_scope = std.StringHashMap(TypeId).init(allocator),
            .eager_helper_in_flight = std.AutoHashMap(ast.StringId, void).init(allocator),
            .allow_external_static_references = false,
        };
    }

    pub fn initWithSharedStore(allocator: std.mem.Allocator, shared_store: *TypeStore, interner: *const ast.StringInterner, graph: *scope_mod.ScopeGraph) TypeChecker {
        return .{
            .allocator = allocator,
            .store = shared_store,
            .owns_store = false,
            .interner = interner,
            .graph = graph,
            .errors = .empty,
            .expr_types = std.AutoHashMap(usize, TypeId).init(allocator),
            .current_scope = null,
            .referenced_bindings = std.AutoHashMap(scope_mod.BindingId, void).init(allocator),
            .ownership_bindings = std.AutoHashMap(scope_mod.BindingId, BindingOwnershipInfo).init(allocator),
            .analysis_context = null,
            .analysis_program = null,
            .type_var_scope = std.StringHashMap(TypeId).init(allocator),
            .eager_helper_in_flight = std.AutoHashMap(ast.StringId, void).init(allocator),
            .allow_external_static_references = false,
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        if (self.owns_store) {
            self.store.deinit();
            self.allocator.destroy(self.store);
        }
        self.errors.deinit(self.allocator);
        self.expr_types.deinit();
        self.referenced_bindings.deinit();
        self.ownership_bindings.deinit();
        self.type_var_scope.deinit();
        self.eager_helper_in_flight.deinit();
    }

    pub fn setAnalysisContext(self: *TypeChecker, context: *const escape_lattice.AnalysisContext, program: *const ir.Program) void {
        self.analysis_context = context;
        self.analysis_program = program;
    }

    fn isNativeTypeName(self: *const TypeChecker, kind: scope_mod.NativeTypeKind, name: ast.StringId) bool {
        const registered = self.graph.nativeTypeStructName(kind) orelse return false;
        return registered == name or std.mem.eql(u8, self.interner.get(registered), self.interner.get(name));
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

    /// Walk a compound parameter pattern and record each inner bind's
    /// type by indexing into the annotation. Wraps
    /// `recordAssignmentBindingTypes` with a `containsTypeVars` guard
    /// — generic function annotations like `pub fn f([h | t] :: [a])`
    /// must NOT pin the bindings to a concrete type, otherwise the
    /// monomorphizer specialises against the wrong shape and other
    /// call sites mismatch.
    fn recordParamBindingTypes(
        self: *TypeChecker,
        pat: *const ast.Pattern,
        parent_type: TypeId,
        source_span: ast.SourceSpan,
    ) !void {
        if (parent_type == TypeStore.UNKNOWN or parent_type == TypeStore.ERROR) return;
        if (self.store.containsTypeVars(parent_type)) return;
        try self.recordAssignmentBindingTypes(pat, parent_type, source_span);
    }

    /// Walk an assignment LHS pattern and record each inner bind's type
    /// against the scope-graph binding the collector created for it. The
    /// inferred type for each bind comes from indexing the parent type
    /// (e.g. tuple element types, list element type, struct field types,
    /// map value type). Mirrors `HirBuilder.lowerAssignmentDestructure`.
    fn recordAssignmentBindingTypes(
        self: *TypeChecker,
        pat: *const ast.Pattern,
        parent_type: TypeId,
        source_span: ast.SourceSpan,
    ) !void {
        switch (pat.*) {
            .wildcard, .literal, .pin => {},
            .paren => |inner| try self.recordAssignmentBindingTypes(inner.inner, parent_type, source_span),
            .bind => |b| {
                if (self.current_scope) |scope_id| {
                    if (self.graph.resolveBindingHygienic(scope_id, b.name, b.meta.scopes)) |bid| {
                        try self.recordBindingType(bid, parent_type, source_span);
                    }
                }
            },
            .tuple => |tp| {
                const parent_typ = self.store.getType(parent_type);
                for (tp.elements, 0..) |sub_pat, idx| {
                    const elem_type = if (parent_typ == .tuple and idx < parent_typ.tuple.elements.len)
                        parent_typ.tuple.elements[idx]
                    else
                        TypeStore.UNKNOWN;
                    try self.recordAssignmentBindingTypes(sub_pat, elem_type, source_span);
                }
            },
            .list => |lp| {
                const parent_typ = self.store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else TypeStore.UNKNOWN;
                for (lp.elements) |sub_pat| {
                    try self.recordAssignmentBindingTypes(sub_pat, elem_type, source_span);
                }
            },
            .list_cons => |lc| {
                const parent_typ = self.store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else TypeStore.UNKNOWN;
                for (lc.heads) |head_pat| {
                    try self.recordAssignmentBindingTypes(head_pat, elem_type, source_span);
                }
                try self.recordAssignmentBindingTypes(lc.tail, parent_type, source_span);
            },
            .struct_pattern => |sp| {
                const parent_typ = self.store.getType(parent_type);
                // The parser routes the `%{key: pat, ...}` shape into
                // `.struct_pattern` (with an empty struct_name) for both
                // struct and map destructuring — they share syntax. When
                // the annotation says the value is a Map(K, V), each
                // field-pattern binds to the map's value type, not a
                // struct field type.
                if (parent_typ == .map and sp.struct_name.parts.len == 0) {
                    const value_type = parent_typ.map.value;
                    for (sp.fields) |field| {
                        try self.recordAssignmentBindingTypes(field.pattern, value_type, source_span);
                    }
                    return;
                }
                for (sp.fields) |field| {
                    var field_type: TypeId = TypeStore.UNKNOWN;
                    if (parent_typ == .struct_type) {
                        for (parent_typ.struct_type.fields) |sf| {
                            if (sf.name == field.name) {
                                field_type = sf.type_id;
                                break;
                            }
                        }
                    }
                    try self.recordAssignmentBindingTypes(field.pattern, field_type, source_span);
                }
            },
            .map => |mp| {
                const parent_typ = self.store.getType(parent_type);
                const value_type = if (parent_typ == .map) parent_typ.map.value else TypeStore.UNKNOWN;
                for (mp.fields) |field| {
                    try self.recordAssignmentBindingTypes(field.value, value_type, source_span);
                }
            },
            .binary => {},
        }
    }

    /// Walk a case pattern and record each inner bind's type by indexing
    /// the scrutinee type. Mirrors `recordAssignmentBindingTypes` but
    /// adapted for case patterns, which add literal/wildcard/atom
    /// variants (no bindings) plus tagged-tuple destructuring where the
    /// leading element is an atom literal but the remaining elements
    /// still index into the scrutinee's tuple type. Skipped entirely if
    /// `parent_type` contains type variables — pinning a generic
    /// function's case-binding to a concrete inferred type would
    /// poison the function's monomorphization for other call sites.
    fn recordCasePatternBindingTypes(
        self: *TypeChecker,
        pat: *const ast.Pattern,
        parent_type: TypeId,
        source_span: ast.SourceSpan,
    ) !void {
        if (parent_type == TypeStore.UNKNOWN or parent_type == TypeStore.ERROR) return;
        if (self.store.containsTypeVars(parent_type)) return;
        switch (pat.*) {
            .wildcard, .literal, .pin => {},
            .paren => |inner| try self.recordCasePatternBindingTypes(inner.inner, parent_type, source_span),
            .bind => |b| {
                if (self.current_scope) |scope_id| {
                    if (self.graph.resolveBindingHygienic(scope_id, b.name, b.meta.scopes)) |bid| {
                        try self.recordBindingType(bid, parent_type, source_span);
                    }
                }
            },
            .tuple => |tp| {
                const parent_typ = self.store.getType(parent_type);
                for (tp.elements, 0..) |sub_pat, idx| {
                    const elem_type = if (parent_typ == .tuple and idx < parent_typ.tuple.elements.len)
                        parent_typ.tuple.elements[idx]
                    else
                        TypeStore.UNKNOWN;
                    try self.recordCasePatternBindingTypes(sub_pat, elem_type, source_span);
                }
            },
            .list => |lp| {
                const parent_typ = self.store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else TypeStore.UNKNOWN;
                for (lp.elements) |sub_pat| {
                    try self.recordCasePatternBindingTypes(sub_pat, elem_type, source_span);
                }
            },
            .list_cons => |lc| {
                const parent_typ = self.store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else TypeStore.UNKNOWN;
                for (lc.heads) |head_pat| {
                    try self.recordCasePatternBindingTypes(head_pat, elem_type, source_span);
                }
                try self.recordCasePatternBindingTypes(lc.tail, parent_type, source_span);
            },
            .struct_pattern => |sp| {
                const parent_typ = self.store.getType(parent_type);
                // Mirror `recordAssignmentBindingTypes`: a `%{key: pat}`
                // pattern parses as `.struct_pattern` with empty
                // struct_name; when matched against a Map(K, V), bind
                // each inner pattern to the map's value type.
                if (parent_typ == .map and sp.struct_name.parts.len == 0) {
                    const value_type = parent_typ.map.value;
                    for (sp.fields) |field| {
                        try self.recordCasePatternBindingTypes(field.pattern, value_type, source_span);
                    }
                    return;
                }
                for (sp.fields) |field| {
                    var field_type: TypeId = TypeStore.UNKNOWN;
                    if (parent_typ == .struct_type) {
                        for (parent_typ.struct_type.fields) |sf| {
                            if (sf.name == field.name) {
                                field_type = sf.type_id;
                                break;
                            }
                        }
                    }
                    try self.recordCasePatternBindingTypes(field.pattern, field_type, source_span);
                }
            },
            .map => |mp| {
                const parent_typ = self.store.getType(parent_type);
                const value_type = if (parent_typ == .map) parent_typ.map.value else TypeStore.UNKNOWN;
                for (mp.fields) |field| {
                    try self.recordCasePatternBindingTypes(field.value, value_type, source_span);
                }
            },
            .binary => {},
        }
    }

    /// Type-check a single case clause: switch into the clause's scope
    /// (registered by the collector) so pattern-bound names resolve to
    /// the case-clause's bindings, flow the scrutinee type into the
    /// pattern, then check the body. Mirrors how `checkFunctionClause`
    /// handles function clause scopes.
    fn checkCaseClause(
        self: *TypeChecker,
        clause: ast.CaseClause,
        scrutinee_type: TypeId,
    ) !TypeId {
        const prev_scope = self.current_scope;
        defer self.current_scope = prev_scope;
        if (self.graph.resolveClauseScope(clause.meta)) |clause_scope| {
            self.current_scope = clause_scope;
        }

        try self.recordCasePatternBindingTypes(clause.pattern, scrutinee_type, clause.meta.span);

        var clause_type: TypeId = TypeStore.NIL;
        for (clause.body) |stmt| {
            clause_type = try self.checkStmt(stmt);
        }
        return clause_type;
    }

    /// Resolve a protocol-qualified call target without conflating
    /// "this qualifier is not a protocol" with "this is a protocol call
    /// whose first argument is not known to satisfy the protocol".
    ///
    /// A concrete first argument dispatches to its impl target. A first
    /// argument already constrained by the exact same protocol keeps
    /// the protocol qualifier so generic protocol helpers can type-check.
    /// Any other first argument is invalid; callers must report a hard
    /// diagnostic and must not fall back to the protocol's abstract
    /// signature as if the argument were accepted.
    fn resolveProtocolDispatch(
        self: *TypeChecker,
        protocol_name: ast.StructName,
        first_arg: *const ast.Expr,
    ) !ProtocolDispatchResolution {
        if (self.graph.findProtocol(protocol_name) == null) return .not_protocol;

        const arg_type = try self.inferExpr(first_arg);
        if (arg_type == TypeStore.UNKNOWN or arg_type == TypeStore.ERROR) return .invalid;

        if (self.protocolConstraintMatches(arg_type, protocol_name)) {
            return .constrained;
        }

        if (self.implTargetForProtocolArgument(protocol_name, arg_type)) |target| {
            return .{ .concrete = target };
        }

        return .invalid;
    }

    fn protocolConstraintMatches(self: *const TypeChecker, type_id: TypeId, protocol_name: ast.StructName) bool {
        if (protocol_name.parts.len == 0) return false;
        const typ = self.store.getType(type_id);
        if (typ != .protocol_constraint) return false;
        return self.structNameMatchesTypeName(protocol_name, self.interner.get(typ.protocol_constraint.protocol_name));
    }

    fn implTargetForProtocolArgument(self: *const TypeChecker, protocol_name: ast.StructName, arg_type: TypeId) ?ast.StructName {
        const target_type_name = self.store.typeToStructName(arg_type, self.interner) orelse return null;
        for (self.graph.impls.items) |entry| {
            if (!self.structNamesEqual(entry.protocol_name, protocol_name)) continue;
            if (self.structNameMatchesTypeName(entry.target_type, target_type_name)) return entry.target_type;
        }
        return null;
    }

    fn implTargetForProtocolId(self: *const TypeChecker, protocol_name: ast.StringId, arg_type: TypeId) ?ast.StructName {
        const target_type_name = self.store.typeToStructName(arg_type, self.interner) orelse return null;
        const protocol_type_name = self.interner.get(protocol_name);
        for (self.graph.impls.items) |entry| {
            if (!self.structNameMatchesTypeName(entry.protocol_name, protocol_type_name)) continue;
            if (self.structNameMatchesTypeName(entry.target_type, target_type_name)) return entry.target_type;
        }
        return null;
    }

    fn resolveNominalStructRefType(self: *TypeChecker, struct_name: ast.StructName) !?TypeId {
        if (struct_name.parts.len == 0) return null;

        const full_name = try self.internDottedStructName(struct_name);
        if (self.store.name_to_type.get(full_name)) |type_id| return type_id;

        if (struct_name.parts.len == 1) {
            if (self.store.name_to_type.get(struct_name.parts[0])) |type_id| return type_id;
        }

        return null;
    }

    fn resolveFirstClassTypeStructType(self: *TypeChecker) ?TypeId {
        const type_name = self.interner.lookupExisting("Type") orelse return null;
        const type_id = self.store.name_to_type.get(type_name) orelse return null;
        const typ = self.store.getType(type_id);
        if (typ != .struct_type) return null;
        const fields = typ.struct_type.fields;
        if (fields.len != 1) return null;
        if (!std.mem.eql(u8, self.interner.get(fields[0].name), "name")) return null;
        if (fields[0].type_id != TypeStore.ATOM) return null;
        return type_id;
    }

    fn resolveFirstClassFunctionStructType(self: *TypeChecker) ?TypeId {
        const function_name = self.interner.lookupExisting("Function") orelse return null;
        const function_type_id = self.store.name_to_type.get(function_name) orelse return null;
        const function_type = self.store.getType(function_type_id);
        if (function_type != .struct_type) return null;
        if (function_type.struct_type.fields.len != 3) return null;

        const type_type_id = self.resolveFirstClassTypeStructType() orelse return null;
        var has_struct = false;
        var has_name = false;
        var has_arity = false;
        for (function_type.struct_type.fields) |field| {
            const field_name = self.interner.get(field.name);
            if (std.mem.eql(u8, field_name, "struct")) {
                if (field.type_id != type_type_id) return null;
                has_struct = true;
            } else if (std.mem.eql(u8, field_name, "name")) {
                if (field.type_id != TypeStore.ATOM) return null;
                has_name = true;
            } else if (std.mem.eql(u8, field_name, "arity")) {
                if (field.type_id != TypeStore.U8) return null;
                has_arity = true;
            } else {
                return null;
            }
        }
        return if (has_struct and has_name and has_arity) function_type_id else null;
    }

    fn isFirstClassFunctionStructType(self: *TypeChecker, type_id: TypeId) bool {
        return if (self.resolveFirstClassFunctionStructType()) |function_type_id|
            self.store.typeEquals(type_id, function_type_id)
        else
            false;
    }

    fn narrowedFunctionArity(arity: u32) u32 {
        const narrowed: u8 = @truncate(arity);
        return @intCast(narrowed);
    }

    fn resolveTypeReferenceTarget(self: *TypeChecker, struct_name: ast.StructName) !?TypeReference {
        if (struct_name.parts.len == 0) return null;

        const type_name = try self.internDottedStructName(struct_name);
        const type_name_text = self.interner.get(type_name);
        if (struct_name.parts.len == 1) {
            if (self.store.resolveTypeName(type_name_text)) |type_id| {
                if (type_id != TypeStore.UNKNOWN) {
                    return .{ .type_id = type_id, .name = type_name };
                }
            }
        }

        if (self.store.name_to_type.get(type_name)) |type_id| {
            return .{ .type_id = type_id, .name = type_name };
        }

        if (struct_name.parts.len == 1) {
            if (self.store.name_to_type.get(struct_name.parts[0])) |type_id| {
                return .{ .type_id = type_id, .name = struct_name.parts[0] };
            }
        }

        if (self.graph.findStructScope(struct_name) != null) {
            return .{ .type_id = TypeStore.UNKNOWN, .name = type_name };
        }

        if (self.allow_external_static_references) {
            return .{ .type_id = TypeStore.UNKNOWN, .name = type_name };
        }

        return null;
    }

    fn reportUnknownTypeReference(self: *TypeChecker, struct_name: ast.StructName, span: ast.SourceSpan) !void {
        const type_text = struct_name.joinedWith(self.allocator, self.interner, ".") catch "{type}";
        try self.addHardError(
            try std.fmt.allocPrint(self.allocator, "I cannot find a type named `{s}`", .{type_text}),
            span,
            "not found",
            "type references must name a known builtin type or declared struct",
        );
    }

    fn currentStructScope(self: *const TypeChecker) ?scope_mod.ScopeId {
        var current = self.current_scope;
        while (current) |scope_id| {
            const scope = self.graph.getScope(scope_id);
            if (scope.kind == .struct_scope) return scope_id;
            current = scope.parent;
        }
        return null;
    }

    fn isCrossStructReference(self: *const TypeChecker, target_scope: scope_mod.ScopeId) bool {
        const current_struct_scope = self.currentStructScope() orelse return true;
        return current_struct_scope != target_scope;
    }

    fn resolveFunctionReferenceTarget(
        self: *TypeChecker,
        struct_name: ?ast.StructName,
        function_name: ast.StringId,
        arity: u32,
        span: ast.SourceSpan,
        require_public_cross_struct: bool,
    ) !?FunctionReferenceTarget {
        const lookup_arity = narrowedFunctionArity(arity);
        const target_scope: scope_mod.ScopeId = if (struct_name) |name| blk: {
            const struct_scope = self.graph.findStructScope(name) orelse {
                try self.reportUnknownTypeReference(name, span);
                return null;
            };
            break :blk struct_scope;
        } else if (self.current_scope) |scope_id|
            scope_id
        else
            return null;

        const resolved = self.graph.resolveFamilyAllowingDefaults(target_scope, function_name, lookup_arity) orelse {
            const function_text = self.interner.get(function_name);
            const target_text = if (struct_name) |name|
                name.joinedWith(self.allocator, self.interner, ".") catch "{struct}"
            else
                null;
            const message = if (target_text) |struct_text|
                try std.fmt.allocPrint(self.allocator, "I cannot find a function named `{s}.{s}/{d}`", .{ struct_text, function_text, lookup_arity })
            else
                try std.fmt.allocPrint(self.allocator, "I cannot find a function named `{s}/{d}`", .{ function_text, lookup_arity });
            try self.addRichError(
                message,
                span,
                "not found",
                null,
            );
            return null;
        };

        const family = self.graph.getFamily(resolved.family_id);
        if (require_public_cross_struct and family.visibility != .public and self.isCrossStructReference(family.scope_id)) {
            const function_text = self.interner.get(function_name);
            const target_text = if (struct_name) |name|
                name.joinedWith(self.allocator, self.interner, ".") catch "{struct}"
            else
                self.currentStructNameText() orelse "{struct}";
            try self.addHardError(
                try std.fmt.allocPrint(self.allocator, "`{s}.{s}/{d}` is private", .{ target_text, function_text, lookup_arity }),
                span,
                "private function",
                "cross-struct function references can only target public functions",
            );
            return null;
        }

        return .{
            .scope_id = target_scope,
            .family_id = resolved.family_id,
            .declared_arity = resolved.declared_arity,
        };
    }

    fn currentStructNameText(self: *const TypeChecker) ?[]const u8 {
        const scope_id = self.currentStructScope() orelse return null;
        for (self.graph.structs.items) |entry| {
            if (entry.scope_id != scope_id) continue;
            return entry.name.joinedWith(self.allocator, self.interner, ".") catch null;
        }
        return null;
    }

    /// Integer literals are contextually typed: a bare literal can
    /// satisfy any declared integer type, with narrowing handled by
    /// the downstream typed position. This matches existing Zap
    /// behavior for struct fields such as `Function.arity :: u8`.
    fn acceptsIntegerLiteralForExpectedType(self: *const TypeChecker, expr: *const ast.Expr, expected: TypeId) bool {
        if (expr.* != .int_literal) return false;
        if (expected >= self.store.types.items.len) return false;
        const expected_type = self.store.getType(expected);
        return expected_type == .int;
    }

    fn blockTailIntegerLiteralCanSatisfyExpectedType(self: *const TypeChecker, stmts: []const ast.Stmt, expected: TypeId) bool {
        if (stmts.len == 0) return false;
        const last = stmts[stmts.len - 1];
        if (last != .expr) return false;
        return self.exprTailIntegerLiteralCanSatisfyExpectedType(last.expr, expected);
    }

    fn exprTailIntegerLiteralCanSatisfyExpectedType(self: *const TypeChecker, expr: *const ast.Expr, expected: TypeId) bool {
        if (self.acceptsIntegerLiteralForExpectedType(expr, expected)) return true;
        return switch (expr.*) {
            .if_expr => |if_expr| blk: {
                if (!self.blockTailIntegerLiteralCanSatisfyExpectedType(if_expr.then_block, expected)) break :blk false;
                const else_block = if_expr.else_block orelse break :blk false;
                break :blk self.blockTailIntegerLiteralCanSatisfyExpectedType(else_block, expected);
            },
            .case_expr => |case_expr| blk: {
                if (case_expr.clauses.len == 0) break :blk false;
                for (case_expr.clauses) |case_clause| {
                    if (!self.blockTailIntegerLiteralCanSatisfyExpectedType(case_clause.body, expected)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }

    fn structExprFieldValue(self: *const TypeChecker, struct_expr: ast.StructExpr, field_name_text: []const u8) ?*const ast.Expr {
        for (struct_expr.fields) |field| {
            if (std.mem.eql(u8, self.interner.get(field.name), field_name_text)) return field.value;
        }
        return null;
    }

    fn dottedTypeNameToStructName(self: *TypeChecker, type_name: ast.StringId, span: ast.SourceSpan) !ast.StructName {
        const type_name_text = self.interner.get(type_name);
        var parts: std.ArrayList(ast.StringId) = .empty;
        var iterator = std.mem.splitScalar(u8, type_name_text, '.');
        const interner_mut = @constCast(self.interner);
        while (iterator.next()) |part_text| {
            try parts.append(self.allocator, try interner_mut.intern(part_text));
        }
        return .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .span = span,
        };
    }

    fn staticTypeValueName(self: *TypeChecker, expr: *const ast.Expr) !?ast.StringId {
        return switch (expr.*) {
            .struct_ref => |struct_ref| if (try self.resolveTypeReferenceTarget(struct_ref.name)) |target|
                target.name
            else
                null,
            .struct_expr => |struct_expr| blk: {
                const type_struct_id = self.resolveFirstClassTypeStructType() orelse break :blk null;
                const resolved_type_id = (try self.resolveNominalStructRefType(struct_expr.struct_name)) orelse break :blk null;
                if (!self.store.typeEquals(type_struct_id, resolved_type_id)) break :blk null;
                const name_value = self.structExprFieldValue(struct_expr, "name") orelse break :blk null;
                if (name_value.* != .atom_literal) break :blk null;
                break :blk name_value.atom_literal.value;
            },
            else => null,
        };
    }

    fn staticNonNegativeArityLiteral(expr: *const ast.Expr) ?u32 {
        if (expr.* != .int_literal) return null;
        if (expr.int_literal.value < 0) return null;
        const unsigned_value: u64 = @intCast(expr.int_literal.value);
        return @truncate(unsigned_value);
    }

    fn validateStaticFunctionStructExpr(self: *TypeChecker, struct_expr: ast.StructExpr, function_type_id: TypeId) !void {
        const resolved_type_id = (try self.resolveNominalStructRefType(struct_expr.struct_name)) orelse return;
        if (!self.store.typeEquals(resolved_type_id, function_type_id)) return;

        const static_value = (try self.staticFunctionStructValue(struct_expr)) orelse return;
        if (self.allow_external_static_references and self.graph.findStructScope(static_value.struct_name) == null) {
            return;
        }
        _ = try self.resolveFunctionReferenceTarget(
            static_value.struct_name,
            static_value.function_name,
            static_value.arity,
            struct_expr.meta.span,
            true,
        );
    }

    fn staticFunctionStructValue(self: *TypeChecker, struct_expr: ast.StructExpr) !?StaticFunctionValue {
        const function_type_id = self.resolveFirstClassFunctionStructType() orelse return null;
        const resolved_type_id = (try self.resolveNominalStructRefType(struct_expr.struct_name)) orelse return null;
        if (!self.store.typeEquals(resolved_type_id, function_type_id)) return null;

        const struct_value = self.structExprFieldValue(struct_expr, "struct") orelse return null;
        const name_value = self.structExprFieldValue(struct_expr, "name") orelse return null;
        const arity_value = self.structExprFieldValue(struct_expr, "arity") orelse return null;
        const target_type_name = (try self.staticTypeValueName(struct_value)) orelse return null;
        if (name_value.* != .atom_literal) return null;
        const raw_arity = staticNonNegativeArityLiteral(arity_value) orelse return null;

        return .{
            .struct_name = try self.dottedTypeNameToStructName(target_type_name, struct_value.getMeta().span),
            .function_name = name_value.atom_literal.value,
            .arity = raw_arity,
        };
    }

    fn isFieldlessStructType(self: *const TypeChecker, type_id: TypeId) bool {
        if (type_id >= self.store.types.items.len) return false;
        const typ = self.store.getType(type_id);
        return typ == .struct_type and typ.struct_type.fields.len == 0;
    }

    fn structNameMatchesTypeName(self: *const TypeChecker, struct_name: ast.StructName, type_name: []const u8) bool {
        if (struct_name.parts.len == 0) return false;
        if (struct_name.parts.len == 1) {
            return std.mem.eql(u8, self.interner.get(struct_name.parts[0]), type_name);
        }

        const dotted_name = struct_name.joinedWith(self.allocator, self.interner, ".") catch return false;
        defer self.allocator.free(dotted_name);
        return std.mem.eql(u8, dotted_name, type_name);
    }

    fn internDottedStructName(self: *TypeChecker, struct_name: ast.StructName) !ast.StringId {
        if (struct_name.parts.len == 0) return 0;
        if (struct_name.parts.len == 1) return struct_name.parts[0];

        var name_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer name_buf.deinit(self.allocator);
        for (struct_name.parts, 0..) |part, index| {
            if (index > 0) try name_buf.append(self.allocator, '.');
            try name_buf.appendSlice(self.allocator, self.interner.get(part));
        }
        const interner_mut = @constCast(self.interner);
        return try interner_mut.intern(name_buf.items);
    }

    fn resolveTaggedUnionVariantReference(self: *TypeChecker, struct_name: ast.StructName, span: ast.SourceSpan) !?TypeId {
        if (struct_name.parts.len < 2) return null;

        const union_name = ast.StructName{
            .parts = struct_name.parts[0 .. struct_name.parts.len - 1],
            .span = struct_name.span,
        };
        const variant_name = struct_name.parts[struct_name.parts.len - 1];
        return try self.resolveTaggedUnionVariant(union_name, variant_name, span);
    }

    fn resolveTaggedUnionVariant(self: *TypeChecker, union_name: ast.StructName, variant_name: ast.StringId, span: ast.SourceSpan) !?TypeId {
        const union_type_name = try self.internDottedStructName(union_name);
        const union_type_id = self.store.name_to_type.get(union_type_name) orelse return null;
        const union_type = self.store.getType(union_type_id);
        if (union_type != .tagged_union) return null;

        for (union_type.tagged_union.variants) |variant| {
            if (variant.name == variant_name) return union_type_id;
        }

        try self.addHardError(
            try std.fmt.allocPrint(self.allocator, "`{s}` is not a variant of enum `{s}`", .{
                self.interner.get(variant_name),
                self.interner.get(union_type.tagged_union.name),
            }),
            span,
            "unknown variant",
            null,
        );
        return union_type_id;
    }

    fn structNamesEqual(_: *const TypeChecker, lhs: ast.StructName, rhs: ast.StructName) bool {
        if (lhs.parts.len != rhs.parts.len) return false;
        for (lhs.parts, rhs.parts) |left_part, right_part| {
            if (left_part != right_part) return false;
        }
        return true;
    }

    fn reportInvalidProtocolDispatch(self: *TypeChecker, protocol_name: ast.StructName, arg: *const ast.Expr) !void {
        const protocol_text = protocol_name.joinedWith(self.allocator, self.interner, ".") catch self.interner.get(protocol_name.parts[protocol_name.parts.len - 1]);
        try self.addHardError(
            try std.fmt.allocPrint(self.allocator, "first argument to protocol `{s}` does not satisfy `{s}`", .{ protocol_text, protocol_text }),
            arg.getMeta().span,
            "protocol dispatch requires an exact protocol constraint or a concrete impl",
            try std.fmt.allocPrint(self.allocator, "annotate the value with `{s}` or pass a type that implements `{s}`", .{ protocol_text, protocol_text }),
        );
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
            const binding_id = self.graph.resolveBindingHygienic(scope_id, vr.name, vr.meta.scopes) orelse continue;

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
                const binding_id = self.graph.resolveBindingHygienic(self.current_scope.?, vr.name, vr.meta.scopes) orelse break :blk null;
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

    fn resolveClauseSignature(
        self: *TypeChecker,
        name: ast.StringId,
        arity: u32,
        declared_arity: u32,
        clause_ref: scope_mod.FunctionClauseRef,
    ) !?FunctionSignature {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        const truncate_to_call_arity = declared_arity != arity;

        // If the resolved family is an impl function, temporarily activate
        // that impl's type-parameter scope so references like `K`/`V` in
        // the impl signature resolve to the impl's type variables instead
        // of failing as unknown types. Without this, any call site that
        // type-checks `Map.next/1` from outside the impl block would fail
        // because the type checker can't see the impl's K, V.
        const prev_impl = self.current_impl;
        defer self.current_impl = prev_impl;
        for (self.graph.impls.items) |impl_entry| {
            for (impl_entry.decl.functions) |func| {
                if (func == clause_ref.decl) {
                    self.current_impl = impl_entry.decl;
                    break;
                }
            }
            if (self.current_impl != prev_impl) break;
        }
        // Mirror the per-clause pre-population that buildClause does, so
        // resolveTypeExpr below sees the impl's K, V already bound.
        if (self.current_impl) |impl_d| {
            self.type_var_scope.clearRetainingCapacity();
            for (impl_d.type_params) |tp_name_id| {
                const tp_name = self.interner.get(tp_name_id);
                const fresh = self.store.freshVar() catch continue;
                self.type_var_scope.put(tp_name, fresh) catch {};
            }
        }

        var param_types: std.ArrayList(TypeId) = .empty;
        var param_ownerships: std.ArrayList(Ownership) = .empty;
        for (clause.params) |param| {
            const param_type = if (param.type_annotation) |ann|
                try self.resolveTypeExpr(ann)
            else blk: {
                // Infer type from literal patterns — string, int, float, atom,
                // bool, nil patterns carry their type implicitly, just like
                // Elixir's `def foo("w")` or `def foo(0)`.
                if (param.pattern.* == .literal) {
                    break :blk switch (param.pattern.literal) {
                        .string => self.store.addType(.string_type) catch TypeStore.UNKNOWN,
                        .int => self.store.addType(.{ .int = .{ .signedness = .signed, .bits = 64 } }) catch TypeStore.UNKNOWN,
                        .float => self.store.addType(.{ .float = .{ .bits = 64 } }) catch TypeStore.UNKNOWN,
                        .atom => self.store.addType(.atom_type) catch TypeStore.UNKNOWN,
                        .bool_lit => self.store.addType(.bool_type) catch TypeStore.UNKNOWN,
                        .nil => self.store.addType(.nil_type) catch TypeStore.UNKNOWN,
                    };
                }
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

        // When the call site supplied fewer arguments than the
        // declared arity, the caller is relying on default values for
        // the trailing parameters. Truncate the signature to the
        // call-site arity so the per-argument check runs only over
        // actually-supplied arguments (the defaults are inlined by
        // the codegen backend, not by the type checker). Without
        // truncation, the bare-call resolver in `inferCall` would
        // already have rejected the call as `name/N` not found.
        if (truncate_to_call_arity) {
            const call_arity = arity;
            param_types.shrinkRetainingCapacity(call_arity);
            param_ownerships.shrinkRetainingCapacity(call_arity);
        }

        return .{
            .params = try param_types.toOwnedSlice(self.allocator),
            .param_ownerships = try param_ownerships.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .return_ownership = self.defaultOwnershipForType(return_type),
        };
    }

    fn resolveFamilySignature(self: *TypeChecker, scope_id: scope_mod.ScopeId, name: ast.StringId, arity: u32) !?FunctionSignature {
        // Allow calls with fewer arguments than the declared arity when
        // every trailing parameter has a default value. The codegen
        // backend inlines the defaults at the call site, so the type
        // checker only needs to validate the supplied arguments and
        // return a signature truncated to the call-site arity.
        const resolved = self.graph.resolveFamilyAllowingDefaults(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(resolved.family_id);
        if (family.clauses.items.len == 0) return null;
        return try self.resolveClauseSignature(name, arity, resolved.declared_arity, family.clauses.items[0]);
    }

    fn resolveFamilyCallSignature(
        self: *TypeChecker,
        scope_id: scope_mod.ScopeId,
        name: ast.StringId,
        arity: u32,
        arg_types: []const TypeId,
    ) !?ResolvedCallSignature {
        const resolved = self.graph.resolveFamilyAllowingDefaults(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(resolved.family_id);
        if (family.clauses.items.len == 0) return null;

        var best_signature: ?FunctionSignature = null;
        var best_clause_index: u32 = 0;
        var best_cost: u32 = std.math.maxInt(u32);
        var best_rank: u32 = std.math.maxInt(u32);

        for (family.clauses.items, 0..) |clause_ref, family_clause_index| {
            const signature = (try self.resolveClauseSignature(name, arity, resolved.declared_arity, clause_ref)) orelse continue;
            const cost = self.signatureCallMatchCost(signature, arg_types) orelse continue;
            if (best_signature == null or cost < best_cost) {
                best_signature = signature;
                best_clause_index = @intCast(family_clause_index);
                best_cost = cost;
                best_rank = self.signatureCanonicalParamRank(signature, arg_types);
            } else if (cost == best_cost) {
                const rank = self.signatureCanonicalParamRank(signature, arg_types);
                if (rank < best_rank) {
                    best_signature = signature;
                    best_clause_index = @intCast(family_clause_index);
                    best_rank = rank;
                }
            }
        }

        if (best_signature) |signature| {
            return .{
                .signature = signature,
                .family_id = resolved.family_id,
                .clause_index = best_clause_index,
            };
        }

        const fallback = (try self.resolveClauseSignature(name, arity, resolved.declared_arity, family.clauses.items[0])) orelse return null;
        return .{
            .signature = fallback,
            .family_id = resolved.family_id,
            .clause_index = 0,
        };
    }

    fn signatureCallMatchCost(self: *const TypeChecker, signature: FunctionSignature, arg_types: []const TypeId) ?u32 {
        var total: u32 = 0;
        const count = @min(signature.params.len, arg_types.len);
        for (arg_types[0..count], signature.params[0..count]) |arg_type, expected| {
            const cost = self.callMatchCost(arg_type, expected) orelse return null;
            total +|= cost;
        }
        return total;
    }

    fn signatureCanonicalParamRank(self: *const TypeChecker, signature: FunctionSignature, arg_types: []const TypeId) u32 {
        var total: u32 = 0;
        const count = @min(signature.params.len, arg_types.len);
        for (arg_types[0..count], signature.params[0..count]) |arg_type, expected| {
            if (arg_type != TypeStore.UNKNOWN) continue;
            total +|= self.canonicalTypeRank(expected);
        }
        return total;
    }

    fn canonicalTypeRank(self: *const TypeChecker, type_id: TypeId) u32 {
        const typ = self.store.getType(type_id);
        return switch (typ) {
            .int => |int_info| blk: {
                const bits = @as(i32, int_info.bits);
                const dist: u32 = @intCast(if (bits >= 64) bits - 64 else 64 - bits);
                const sign_penalty: u32 = if (int_info.signedness == .signed) 0 else 1;
                break :blk dist * 2 + sign_penalty;
            },
            .float => |float_info| blk: {
                const bits = @as(i32, float_info.bits);
                const dist: u32 = @intCast(if (bits >= 64) bits - 64 else 64 - bits);
                break :blk @as(u32, 256) + dist;
            },
            else => 1024,
        };
    }

    fn callMatchCost(self: *const TypeChecker, actual: TypeId, expected: TypeId) ?u32 {
        if (expected == TypeStore.UNKNOWN or actual == TypeStore.UNKNOWN or actual == TypeStore.ERROR) return 0;

        const expected_type = self.store.getType(expected);
        const actual_type = self.store.getType(actual);
        if (expected_type == .protocol_constraint) {
            if (actual_type == .protocol_constraint) {
                if (actual_type.protocol_constraint.protocol_name == expected_type.protocol_constraint.protocol_name) return 0;
                return null;
            }

            if (self.implTargetForProtocolId(expected_type.protocol_constraint.protocol_name, actual) != null) return 0;
            return null;
        }

        if (actual_type == .protocol_constraint) {
            if (expected_type == .type_var) return 0;
            return null;
        }

        if (self.store.containsTypeVars(expected) or self.store.containsTypeVars(actual)) return 0;
        if (expected_type == .type_var or actual_type == .type_var) return 0;

        return self.store.callMatchCost(actual, expected);
    }

    fn isTypeVar(self: *const TypeChecker, type_id: TypeId) bool {
        if (type_id >= self.store.types.items.len) return false;
        return self.store.getType(type_id) == .type_var;
    }

    fn isConcreteNumeric(self: *const TypeChecker, type_id: TypeId) bool {
        if (type_id >= self.store.types.items.len) return false;
        return switch (self.store.getType(type_id)) {
            .int, .float => true,
            else => false,
        };
    }

    fn arithmeticResultForTypeVarOperand(self: *const TypeChecker, lhs: TypeId, rhs: TypeId) ?TypeId {
        const lhs_is_var = self.isTypeVar(lhs);
        const rhs_is_var = self.isTypeVar(rhs);
        if (lhs_is_var and rhs_is_var) return lhs;
        if (lhs_is_var and self.isConcreteNumeric(rhs)) return rhs;
        if (rhs_is_var and self.isConcreteNumeric(lhs)) return lhs;
        return null;
    }

    fn inferCallArgTypes(self: *TypeChecker, args: []const *const ast.Expr) ![]const TypeId {
        const arg_types = try self.allocator.alloc(TypeId, args.len);
        for (args, 0..) |arg, idx| {
            arg_types[idx] = try self.inferExpr(arg);
        }
        return arg_types;
    }

    /// True when `name` denotes a compiler-generated helper whose body and
    /// parameter list are entirely under the desugar pass's control. The
    /// type checker may eagerly recurse into such helpers because the body
    /// has no external dependencies that haven't already been processed.
    fn isSyntheticHelperName(self: *const TypeChecker, name: ast.StringId) bool {
        const text = self.interner.get(name);
        return std.mem.startsWith(u8, text, "__for_");
    }

    /// Resolve the AST `FunctionDecl` registered for `name`/`arity` in the
    /// scope graph, if any. Returns the same node the type checker would
    /// recurse into via the normal struct-member walk, so calling
    /// `checkFunctionDecl` on the result mirrors a regular pass.
    fn lookupFunctionDecl(self: *const TypeChecker, scope_id: scope_mod.ScopeId, name: ast.StringId, arity: u32) ?*const ast.FunctionDecl {
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        return family.clauses.items[0].decl;
    }

    fn resolveFunctionRefSignature(self: *TypeChecker, fr: ast.FunctionRefExpr) !?FunctionSignature {
        if (self.allow_external_static_references) {
            if (fr.struct_name) |struct_name| {
                if (self.graph.findStructScope(struct_name) == null) return null;
            }
        }

        const target = (try self.resolveFunctionReferenceTarget(
            fr.struct_name,
            fr.function,
            fr.arity,
            fr.meta.span,
            true,
        )) orelse return null;

        const family = self.graph.getFamily(target.family_id);
        if (family.clauses.items.len == 0) {
            return null;
        }
        return try self.resolveClauseSignature(fr.function, narrowedFunctionArity(fr.arity), target.declared_arity, family.clauses.items[0]);
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

    /// Resolve a Zap function `bare_name` of given `arity` to its IR FunctionId.
    /// IR function names are `{struct_prefix}__{mangled_name}__{arity}` (or
    /// `{mangled_name}__{arity}` for top-level), so we match by the full
    /// suffix `{name}__{arity}`. We always require an arity match — the
    /// previous heuristic matched any `__{name}` regardless of arity, which
    /// silently picked the wrong overload (e.g. `f/1` vs `f/2`).
    fn analysisFunctionIdByName(self: *const TypeChecker, bare_name: []const u8, arity: u32) ?ir.FunctionId {
        const program = self.analysis_program orelse return null;
        const mangled = mangleNameForIr(self.allocator, bare_name) orelse return null;
        defer self.allocator.free(mangled);
        const arity_suffix = std.fmt.allocPrint(self.allocator, "__{s}__{d}", .{ mangled, arity }) catch return null;
        defer self.allocator.free(arity_suffix);

        if (self.current_scope) |scope_id| {
            if (self.enclosingStructIrPrefix(scope_id)) |prefix| {
                defer self.allocator.free(prefix);
                const full = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, arity_suffix }) catch return null;
                defer self.allocator.free(full);
                for (program.functions) |func| {
                    if (std.mem.eql(u8, func.name, full)) return func.id;
                }
            }
        }

        const top_level = std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled, arity }) catch return null;
        defer self.allocator.free(top_level);
        for (program.functions) |func| {
            if (std.mem.eql(u8, func.name, top_level)) return func.id;
        }
        return null;
    }

    /// Build a struct's IR-name prefix from a scope's enclosing struct.
    /// Multi-segment struct names join with `_` (single underscore) to match
    /// IR's `structNameToPrefix` — distinct from `enclosingStructQualifiedName`
    /// which joins with `__` for type-system display.
    fn enclosingStructIrPrefix(self: *const TypeChecker, scope_id: scope_mod.ScopeId) ?[]u8 {
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            for (self.graph.structs.items) |struct_decl| {
                if (struct_decl.scope_id != sid) continue;
                return joinStructNameWithUnderscore(self.allocator, self.interner, struct_decl.name);
            }
            current = self.graph.getScope(sid).parent;
        }
        return null;
    }

    fn analysisFunctionByDecl(self: *const TypeChecker, decl: *const ast.FunctionDecl) ?ir.Function {
        const name = self.interner.get(decl.name);
        const arity = if (decl.clauses.len > 0) @as(u32, @intCast(decl.clauses[0].params.len)) else 0;
        const function_id = self.analysisFunctionIdByName(name, arity) orelse return null;
        const program = self.analysis_program orelse return null;
        for (program.functions) |func| {
            if (func.id == function_id) return func;
        }
        return null;
    }

    fn closureEscapeForDecl(self: *const TypeChecker, decl: *const ast.FunctionDecl) ?escape_lattice.EscapeState {
        const arity = if (decl.clauses.len > 0) @as(u32, @intCast(decl.clauses[0].params.len)) else 0;
        const function_id = self.analysisFunctionIdByName(self.interner.get(decl.name), arity) orelse return null;
        const ctx = self.analysis_context orelse return null;
        const program = self.analysis_program orelse return null;
        return findClosureEscape(ctx, program, function_id);
    }

    fn findClosureEscape(ctx: *const escape_lattice.AnalysisContext, program: *const ir.Program, closure_func_id: ir.FunctionId) ?escape_lattice.EscapeState {
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

    fn enclosingStructQualifiedName(self: *const TypeChecker, scope_id: scope_mod.ScopeId) ?[]u8 {
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            for (self.graph.structs.items) |struct_decl| {
                if (struct_decl.scope_id != sid) continue;
                return self.structNameToString(struct_decl.name);
            }
            current = self.graph.getScope(sid).parent;
        }
        return null;
    }

    fn structNameToString(self: *const TypeChecker, name: ast.StructName) []u8 {
        const joined = name.joinedWith(self.allocator, self.interner, "__") catch return &[_]u8{};
        return @constCast(joined);
    }

    fn closureDeclFromExpr(self: *TypeChecker, expr: *const ast.Expr) ?*const ast.FunctionDecl {
        switch (expr.*) {
            .anonymous_function => |anon| return anon.decl,
            .var_ref => |vr| {
                if (self.current_scope == null) return null;
                return self.resolveFunctionValueDecl(self.current_scope.?, vr.name);
            },
            else => return null,
        }
    }

    fn safeClosureParamsForCurrentCallee(self: *const TypeChecker, callee_name: ast.StringId, arity: u32) ?[]const bool {
        if (self.current_scope) |scope_id| {
            if (self.graph.resolveFamily(scope_id, callee_name, arity)) |family_id| {
                return self.safeClosureParamsForFamily(family_id);
            }
        }

        const bare_name = self.interner.get(callee_name);
        const function_id = self.analysisFunctionIdByName(bare_name, arity) orelse return null;
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
                .attribute => |attr| {
                    if (attr.value) |value| {
                        if (self.exprUsesClosureParamUnsafely(value, param_name, false)) return false;
                    }
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
            .anonymous_function => return false,
            .case_expr, .panic_expr, .quote_expr, .unquote_expr, .intrinsic, .attr_ref, .binary_literal, .function_ref => return true,
            else => return false,
        }
    }

    /// Unify two type IDs for the purpose of typing a heterogeneous
    /// collection. Disagreeing scalars collapse to `TERM`; tuples of
    /// equal arity unify component-wise; lists/maps unify recursively.
    /// Mirrors `hir.unifyForCollection`.
    fn unifyForCollection(self: *TypeChecker, a: TypeId, b: TypeId) TypeId {
        if (a == b) return a;
        if (a == TypeStore.UNKNOWN) return b;
        if (b == TypeStore.UNKNOWN) return a;
        if (a == TypeStore.TERM or b == TypeStore.TERM) return TypeStore.TERM;
        const ta = self.store.getType(a);
        const tb = self.store.getType(b);
        if (ta == .tuple and tb == .tuple and ta.tuple.elements.len == tb.tuple.elements.len) {
            var any_changed = false;
            const unified = self.allocator.alloc(TypeId, ta.tuple.elements.len) catch return TypeStore.TERM;
            for (ta.tuple.elements, tb.tuple.elements, 0..) |ea, eb, i| {
                const u = self.unifyForCollection(ea, eb);
                if (u != ea) any_changed = true;
                unified[i] = u;
            }
            if (!any_changed) return a;
            return self.store.addType(.{ .tuple = .{ .elements = unified } }) catch TypeStore.TERM;
        }
        if (ta == .list and tb == .list) {
            const u = self.unifyForCollection(ta.list.element, tb.list.element);
            if (u == ta.list.element) return a;
            return self.store.addType(.{ .list = .{ .element = u } }) catch TypeStore.TERM;
        }
        if (ta == .map and tb == .map) {
            const uk = self.unifyForCollection(ta.map.key, tb.map.key);
            const uv = self.unifyForCollection(ta.map.value, tb.map.value);
            if (uk == ta.map.key and uv == ta.map.value) return a;
            return self.store.addType(.{ .map = .{ .key = uk, .value = uv } }) catch TypeStore.TERM;
        }
        return TypeStore.TERM;
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
                const binding_id = self.graph.resolveBindingHygienic(function_scope, vr.name, vr.meta.scopes) orelse return;
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
            .anonymous_function => |anon| {
                // Recurse into the nested closure with the SAME outer
                // function_scope so any binding the inner closure captures
                // from the outer's scope is still classified as captured.
                // Without this, a closure-of-closure that leaks a borrowed
                // capture through its inner body bypasses borrow validation.
                for (anon.decl.clauses) |clause| {
                    if (clause.refinement) |r| try self.collectCapturedBindingsFromExpr(r, function_scope, captured);
                    if (clause.body) |body| {
                        for (body) |stmt| try self.collectCapturedBindingsFromStmt(stmt, function_scope, captured);
                    }
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
            const function_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
        if (type_id == TypeStore.I128) return "i128";
        if (type_id == TypeStore.I64) return "i64";
        if (type_id == TypeStore.I32) return "i32";
        if (type_id == TypeStore.I16) return "i16";
        if (type_id == TypeStore.I8) return "i8";
        if (type_id == TypeStore.U128) return "u128";
        if (type_id == TypeStore.U64) return "u64";
        if (type_id == TypeStore.U32) return "u32";
        if (type_id == TypeStore.U16) return "u16";
        if (type_id == TypeStore.U8) return "u8";
        if (type_id == TypeStore.F128) return "f128";
        if (type_id == TypeStore.F80) return "f80";
        if (type_id == TypeStore.F64) return "f64";
        if (type_id == TypeStore.F32) return "f32";
        if (type_id == TypeStore.F16) return "f16";
        if (type_id == TypeStore.USIZE) return "usize";
        if (type_id == TypeStore.ISIZE) return "isize";
        if (type_id == TypeStore.UNKNOWN) return "{unknown}";
        if (type_id == TypeStore.ERROR) return "{error}";
        if (type_id == TypeStore.TERM) return "Term";
        // Look up user-defined and compound types
        if (type_id < self.store.types.items.len) {
            const typ = self.store.types.items[type_id];
            switch (typ) {
                .struct_type => |st| return self.interner.get(st.name),
                .tagged_union => |tu| return self.interner.get(tu.name),
                .list => |lt| {
                    return std.fmt.allocPrint(self.allocator, "[{s}]", .{self.typeToString(lt.element)}) catch "{type}";
                },
                .map => |mt| {
                    return std.fmt.allocPrint(self.allocator, "%{{{s} => {s}}}", .{ self.typeToString(mt.key), self.typeToString(mt.value) }) catch "{type}";
                },
                .tuple => |tt| {
                    var buf: std.ArrayList(u8) = .empty;
                    buf.appendSlice(self.allocator, "{") catch return "{type}";
                    for (tt.elements, 0..) |element, idx| {
                        if (idx > 0) buf.appendSlice(self.allocator, ", ") catch return "{type}";
                        buf.appendSlice(self.allocator, self.typeToString(element)) catch return "{type}";
                    }
                    buf.appendSlice(self.allocator, "}") catch return "{type}";
                    return buf.toOwnedSlice(self.allocator) catch return "{type}";
                },
                .function => |ft| {
                    var buf: std.ArrayList(u8) = .empty;
                    buf.appendSlice(self.allocator, "(") catch return "{type}";
                    for (ft.params, 0..) |param, idx| {
                        if (idx > 0) buf.appendSlice(self.allocator, ", ") catch return "{type}";
                        buf.appendSlice(self.allocator, self.typeToString(param)) catch return "{type}";
                    }
                    buf.appendSlice(self.allocator, " -> ") catch return "{type}";
                    buf.appendSlice(self.allocator, self.typeToString(ft.return_type)) catch return "{type}";
                    buf.appendSlice(self.allocator, ")") catch return "{type}";
                    return buf.toOwnedSlice(self.allocator) catch return "{type}";
                },
                .protocol_constraint => |pc| return self.interner.get(pc.protocol_name),
                .union_type => |ut| {
                    var buf: std.ArrayList(u8) = .empty;
                    for (ut.members, 0..) |member, i| {
                        if (i > 0) buf.appendSlice(self.allocator, " | ") catch return "{type}";
                        buf.appendSlice(self.allocator, self.typeToString(member)) catch return "{type}";
                    }
                    return buf.toOwnedSlice(self.allocator) catch return "{type}";
                },
                .applied => |ap| {
                    var buf: std.ArrayList(u8) = .empty;
                    const base_text = self.typeToString(ap.base);
                    buf.appendSlice(self.allocator, base_text) catch return "{type}";
                    buf.append(self.allocator, '(') catch return "{type}";
                    for (ap.args, 0..) |arg, idx| {
                        if (idx > 0) buf.appendSlice(self.allocator, ", ") catch return "{type}";
                        buf.appendSlice(self.allocator, self.typeToString(arg)) catch return "{type}";
                    }
                    buf.append(self.allocator, ')') catch return "{type}";
                    return buf.toOwnedSlice(self.allocator) catch return "{type}";
                },
                .type_var => return "{type_var}",
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

        // Diagnose recursive struct types that have no finite base case
        // before any other check runs against them. Without this, the
        // user gets Zig's late "struct has infinite size" message at
        // codegen, which lands far from the actual mistake.
        try self.checkUninhabitedRecursiveTypes();

        // Type-check every field default expression against its
        // declared field type. Defaults are a general `pub struct`
        // feature (Phase 1.1 of the error-system roadmap) — running
        // the check here, immediately after the struct types are
        // registered, lets the user see a clean Zap diagnostic at
        // the default expression instead of a Zig-backend "expected
        // type" message lifted from the implicit construction site.
        try self.validateStructFieldDefaults();

        for (program.structs) |*mod| {
            try self.checkStruct(mod);
        }
        for (program.top_items) |item| {
            // Only `def main()` is allowed at the top level — all other functions must be inside a struct
            switch (item) {
                .function => |func| {
                    const name = self.interner.get(func.name);
                    if (!std.mem.eql(u8, name, "main")) {
                        try self.addHardError(
                            try std.fmt.allocPrint(self.allocator, "top-level function `{s}` is not allowed — only `def main()` can be defined outside a struct", .{name}),
                            func.meta.span,
                            "move this function into a `struct` block",
                            "all functions except `main` must be defined inside a `struct { ... }` block",
                        );
                    }
                },
                .priv_function => |func| {
                    const name = self.interner.get(func.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level private function `{s}` is not allowed — functions must be inside a struct", .{name}),
                        func.meta.span,
                        "move this function into a `struct` block",
                        "all functions must be defined inside a `struct { ... }` block",
                    );
                },
                .macro => |mac| {
                    const name = self.interner.get(mac.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level macro `{s}` is not allowed — macros must be inside a struct", .{name}),
                        mac.meta.span,
                        "move this macro into a `struct` block",
                        "all macros must be defined inside a `struct { ... }` block",
                    );
                },
                .priv_macro => |mac| {
                    const name = self.interner.get(mac.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level private macro `{s}` is not allowed — macros must be inside a struct", .{name}),
                        mac.meta.span,
                        "move this macro into a `struct` block",
                        "all macros must be defined inside a `struct { ... }` block",
                    );
                },
                else => {},
            }
            try self.checkTopItem(item);
        }
    }

    /// Type-check every `pub struct` field default expression against
    /// its declared field type. This runs after `registerUserTypes()`
    /// populates `TypeStore.types` with the resolved field types so
    /// `inferExpr` can validate the default against a concrete type.
    ///
    /// The mismatched case (`x :: i64 = "wrong"`) emits a rich
    /// diagnostic with a caret on the default expression — not on the
    /// containing struct — so the user lands directly on the offending
    /// value. Contextually-typed expressions whose static type cannot
    /// be pinned without an expected-type push (the empty list `[]`
    /// being the canonical example) are accepted here; HIR's
    /// `appendStructDefaults` stamps the field's expected type on
    /// those UNKNOWN-typed expressions when the default is lowered at
    /// every construction site.
    ///
    /// Inter-field references (`field_b :: T = self.field_a + 1`) are
    /// deliberately disallowed in v1 — defaults evaluate at the
    /// construction-site lexical scope, which does not bind `self`.
    /// Users who need cross-field defaults write a constructor
    /// function. This is consistent with Elixir's earliest `defstruct`
    /// shape and avoids forcing a field-evaluation-order semantics
    /// into a Phase-1 feature.
    fn validateStructFieldDefaults(self: *TypeChecker) !void {
        const prev_scope = self.current_scope;
        defer self.current_scope = prev_scope;

        // Dedupe by registered TypeId across the whole lifetime of
        // this `TypeChecker`. The compiler pipeline reruns
        // `checkProgram` after escape analysis (and CTFE re-runs the
        // checker against its own program), so a per-call HashMap
        // would re-emit the same diagnostic on every replay. Using a
        // checker-scoped set keeps each struct validated exactly
        // once, regardless of how many times `checkProgram` fires.
        // Validating the same struct twice would also be redundant
        // even within a single run — the scope graph holds one
        // `TypeEntry` per declaration site, and a type imported under
        // multiple aliases reaches us through several entries that
        // all collapse onto the same TypeId.

        for (self.graph.types.items) |type_entry| {
            if (type_entry.kind != .struct_type) continue;
            const struct_decl = type_entry.kind.struct_type;
            const registered_type_id = self.store.name_to_type.get(type_entry.name) orelse continue;
            if (registered_type_id >= self.store.types.items.len) continue;
            const registered = self.store.getType(registered_type_id);
            if (registered != .struct_type) continue;
            const gop = try self.store.validated_default_struct_ids.getOrPut(registered_type_id);
            if (gop.found_existing) continue;

            // Default expressions evaluate at the construction site,
            // not inside the struct body. Resolve them at the struct's
            // declaration scope: that gives them access to the
            // struct's siblings (other types, helper functions in the
            // enclosing module) without binding `self` or other
            // fields.
            self.current_scope = type_entry.scope_id;

            for (struct_decl.fields) |field_decl| {
                const default_expr = field_decl.default orelse continue;
                const field_type_id = self.findRegisteredFieldType(registered.struct_type, field_decl.name) orelse continue;
                if (field_type_id == TypeStore.UNKNOWN) continue;

                const inferred = self.inferExpr(default_expr) catch TypeStore.UNKNOWN;
                if (inferred == TypeStore.UNKNOWN) continue;
                if (self.store.typeEquals(inferred, field_type_id)) continue;
                if (self.acceptsIntegerLiteralForExpectedType(default_expr, field_type_id)) continue;
                if (self.store.canWidenTo(inferred, field_type_id)) continue;

                const field_name = self.interner.get(field_decl.name);
                // `typeToString` returns either a static slice (for
                // primitives) or an arena-allocated buffer (for
                // compound types). Either way the TypeChecker's
                // allocator owns the result — we do not free here,
                // matching every other diagnostic site in this file.
                const declared_name = self.typeToString(field_type_id);
                const provided_name = self.typeToString(inferred);

                try self.addRichError(
                    try std.fmt.allocPrint(
                        self.allocator,
                        "field `{s}` declares type `{s}` but its default value has type `{s}`",
                        .{ field_name, declared_name, provided_name },
                    ),
                    default_expr.getMeta().span,
                    "default value type does not match the declared field type",
                    try std.fmt.allocPrint(
                        self.allocator,
                        "either change the default to a `{s}` value or change the field type to `{s}`",
                        .{ declared_name, provided_name },
                    ),
                );
            }
        }
    }

    /// Look up a registered struct field's resolved `TypeId` by name.
    /// Used by `validateStructFieldDefaults` to pair an AST-level
    /// `StructFieldDecl` with its already-resolved field type without
    /// re-running `resolveTypeExpr`.
    fn findRegisteredFieldType(_: *const TypeChecker, struct_type: Type.StructType, field_name: ast.StringId) ?TypeId {
        for (struct_type.fields) |field| {
            if (field.name == field_name) return field.type_id;
        }
        return null;
    }

    /// Number of formal type parameters declared on a registered
    /// nominal type. Returns 0 for non-parametric structs/unions and
    /// for any non-nominal entry (primitives, applied instances,
    /// etc.) — these do not accept generic application directly.
    fn parametricTypeArity(self: *const TypeChecker, type_id: TypeId) usize {
        const typ = self.store.getType(type_id);
        return switch (typ) {
            .struct_type => |st| st.type_params.len,
            .tagged_union => |tu| tu.type_params.len,
            else => 0,
        };
    }

    /// Diagnostic for `Box(i64, String)` when `Box` declared `Box(T)`,
    /// or `Box()` when at least one argument was expected.
    fn reportParametricArityMismatch(
        self: *TypeChecker,
        name: []const u8,
        expected: usize,
        actual: usize,
        span: ast.SourceSpan,
    ) !void {
        const word = if (expected == 1) "parameter" else "parameters";
        try self.addRichError(
            try std.fmt.allocPrint(
                self.allocator,
                "`{s}` expects {d} type {s}, got {d}",
                .{ name, expected, word, actual },
            ),
            span,
            try std.fmt.allocPrint(self.allocator, "wrong number of type arguments", .{}),
            try std.fmt.allocPrint(
                self.allocator,
                "supply {d} type argument{s} (one per declared parameter)",
                .{ expected, if (expected == 1) "" else "s" },
            ),
        );
    }

    /// Per-instantiation state for a struct literal: the
    /// substitution map (formal type_var -> concrete arg) and the
    /// final TypeId to record on the literal. Concrete (non-
    /// parametric) struct literals get an empty substitution and the
    /// declaration TypeId.
    const StructLiteralInstantiation = struct {
        substitution: SubstitutionMap,
        literal_type_id: TypeId,

        fn deinit(self: *StructLiteralInstantiation) void {
            self.substitution.deinit();
        }
    };

    /// Validate a struct literal's optional type-argument list
    /// against the declaration's formal `type_params` and build a
    /// SubstitutionMap from formal type_var -> concrete arg. Emits
    /// rich diagnostics for arity mismatch / non-parametric
    /// instantiation, and falls back to the best partial
    /// substitution so downstream field checks still surface useful
    /// errors instead of cascading silence.
    fn buildStructLiteralInstantiation(
        self: *TypeChecker,
        struct_expr: ast.StructExpr,
        struct_type: Type.StructType,
        type_name_id: ast.StringId,
    ) !StructLiteralInstantiation {
        var instantiation: StructLiteralInstantiation = .{
            .substitution = SubstitutionMap.init(self.allocator),
            .literal_type_id = self.store.name_to_type.get(type_name_id) orelse TypeStore.UNKNOWN,
        };

        const formal_arity = struct_type.type_params.len;
        const provided_arity = struct_expr.type_args.len;

        // Concrete struct literal: empty subst, return declaration id.
        if (formal_arity == 0 and provided_arity == 0) return instantiation;

        // Non-parametric struct that was passed `(...)` anyway.
        if (formal_arity == 0 and provided_arity > 0) {
            const struct_name_text = self.interner.get(type_name_id);
            try self.reportNonParametricInstantiation(struct_name_text, provided_arity, struct_expr.meta.span);
            return instantiation;
        }

        // Parametric struct with no explicit `(...)` at the literal.
        // 1.1.5.c will add HIR-side context-driven inference (target
        // type annotations, function return types); here in the
        // type-checker we accept the missing args and leave every
        // formal type_var unbound — downstream field validation
        // therefore behaves exactly as it did before this commit
        // (field types stay as type_vars and the unify path is
        // permissive). This is intentionally additive: parametric
        // structs without explicit type-args at the literal must
        // still type-check today so existing impl bodies, which
        // never write the type-arg syntax, keep working.
        if (formal_arity > 0 and provided_arity == 0) return instantiation;

        // Arity mismatch.
        if (formal_arity != provided_arity) {
            const struct_name_text = self.interner.get(type_name_id);
            try self.reportParametricArityMismatch(struct_name_text, formal_arity, provided_arity, struct_expr.meta.span);
            // Still try to bind whatever positions we can — gives
            // better cascading diagnostics on the field expressions.
        }

        // Resolve each type-arg expression and bind it against the
        // matching formal type_var. Extra args are ignored beyond
        // `formal_arity`; missing args leave the corresponding formal
        // unbound. Both shapes already triggered a diagnostic above.
        const pair_count = @min(formal_arity, provided_arity);
        var resolved_args: std.ArrayList(TypeId) = .empty;
        for (struct_expr.type_args, 0..) |type_arg_expr, idx| {
            const resolved_arg = try self.resolveTypeExpr(type_arg_expr);
            try resolved_args.append(self.allocator, resolved_arg);
            if (idx < pair_count) {
                const formal_type_id = struct_type.type_params[idx];
                const formal_typ = self.store.getType(formal_type_id);
                if (formal_typ == .type_var) {
                    instantiation.substitution.bind(formal_typ.type_var, resolved_arg);
                }
            }
        }

        // Build the canonical `.applied { base, args }` instance for
        // this literal. We always materialise it — even on arity
        // mismatch — so downstream consumers see a concrete TypeId
        // instead of falling back to the bare declaration.
        const base_type_id = self.store.name_to_type.get(type_name_id) orelse TypeStore.UNKNOWN;
        const args_slice = try resolved_args.toOwnedSlice(self.allocator);
        instantiation.literal_type_id = try self.store.addType(.{
            .applied = .{
                .base = base_type_id,
                .args = args_slice,
            },
        });
        return instantiation;
    }

    /// Diagnostic for `Plain(i64)` when `Plain` has no type
    /// parameters declared.
    fn reportNonParametricInstantiation(
        self: *TypeChecker,
        name: []const u8,
        actual: usize,
        span: ast.SourceSpan,
    ) !void {
        try self.addRichError(
            try std.fmt.allocPrint(
                self.allocator,
                "`{s}` does not take type parameters",
                .{name},
            ),
            span,
            try std.fmt.allocPrint(
                self.allocator,
                "applied {d} type argument{s} to a concrete type",
                .{ actual, if (actual == 1) "" else "s" },
            ),
            try std.fmt.allocPrint(
                self.allocator,
                "drop the parenthesised type arguments — `{s}` is not parametric",
                .{name},
            ),
        );
    }

    /// Snapshot of an entry list captured from `type_var_scope` so a
    /// nested pass can install its own bindings and restore the
    /// caller's bindings on exit.
    const TypeVarScopeEntry = struct {
        name: []const u8,
        type_id: TypeId,
    };

    /// Copy every (name -> TypeId) pair currently in `type_var_scope`
    /// into a fresh slice. The returned slice borrows from the
    /// existing interner strings (no allocation per entry beyond the
    /// outer slice), so it stays valid as long as the interner does.
    fn snapshotTypeVarScope(self: *TypeChecker) ![]TypeVarScopeEntry {
        const count = self.type_var_scope.count();
        const entries = try self.allocator.alloc(TypeVarScopeEntry, count);
        var iterator = self.type_var_scope.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            entries[index] = .{ .name = entry.key_ptr.*, .type_id = entry.value_ptr.* };
        }
        return entries;
    }

    /// Restore a previously snapshotted scope: clears the live scope,
    /// re-installs every entry, and frees the snapshot slice.
    fn restoreTypeVarScope(self: *TypeChecker, entries: []TypeVarScopeEntry) void {
        self.type_var_scope.clearRetainingCapacity();
        for (entries) |entry| {
            self.type_var_scope.put(entry.name, entry.type_id) catch {};
        }
        self.allocator.free(entries);
    }

    fn registerUserTypes(self: *TypeChecker) !void {
        // Pass 1 — forward-declare every user-defined nominal type so
        // its name is in `name_to_type` BEFORE any field/variant
        // resolution runs. Without this, a `pub struct Tree { left ::
        // Tree | nil }` would type-check `Tree` inside its own field
        // expression and find no entry — the union member would
        // resolve to `TypeStore.UNKNOWN`, the recursive edge would be
        // invisible to `analyzeStructFieldStorage`, and the field
        // would stay `.direct` storage and blow up at struct-decl
        // layout time. The placeholder entries written here get
        // overwritten in pass 2 with the resolved field/variant
        // lists; the `TypeId`s never change, so any `name_to_type`
        // lookup made during pass 2 yields a stable identity.
        for (self.graph.types.items) |type_entry| {
            switch (type_entry.kind) {
                .struct_type => {
                    const name = type_entry.name;
                    if (self.store.name_to_type.get(name) != null) continue;
                    const name_str = self.interner.get(name);
                    if (self.store.resolveTypeName(name_str)) |builtin_type_id| {
                        if (builtin_type_id != TypeStore.UNKNOWN) continue; // builtin wins; pass 2 will diagnose
                    }
                    const type_id = try self.store.addType(.{ .struct_type = .{
                        .name = name,
                        .fields = &.{},
                    } });
                    try self.store.name_to_type.put(name, type_id);
                },
                .union_type => |ud| {
                    if (self.store.name_to_type.get(ud.name) != null) continue;
                    const enum_name_str = self.interner.get(ud.name);
                    if (self.store.resolveTypeName(enum_name_str)) |builtin_type_id| {
                        if (builtin_type_id != TypeStore.UNKNOWN) continue;
                    }
                    const type_id = try self.store.addType(.{ .tagged_union = .{
                        .name = ud.name,
                        .variants = &.{},
                    } });
                    try self.store.name_to_type.put(ud.name, type_id);
                },
                .opaque_type => {
                    if (self.store.name_to_type.get(type_entry.name) != null) continue;
                    const opaque_name_str = self.interner.get(type_entry.name);
                    if (self.store.resolveTypeName(opaque_name_str)) |builtin_type_id| {
                        if (builtin_type_id != TypeStore.UNKNOWN) continue;
                    }
                    // Inner is a real TypeId field, not a slice — use
                    // `UNKNOWN` as the placeholder; pass 2 overwrites.
                    const type_id = try self.store.addType(.{ .opaque_type = .{
                        .name = type_entry.name,
                        .inner = TypeStore.UNKNOWN,
                    } });
                    try self.store.name_to_type.put(type_entry.name, type_id);
                },
                else => {},
            }
        }

        // Pass 2 — resolve fields/variants/inner with every user-
        // defined nominal name now visible. Diagnoses builtin-shadow
        // collisions that pass 1 silently skipped.
        for (self.graph.types.items) |type_entry| {
            switch (type_entry.kind) {
                .struct_type => |sd| {
                    const name = type_entry.name;
                    const name_str = self.interner.get(name);
                    if ((if (self.store.resolveTypeName(name_str)) |builtin_type_id| builtin_type_id != TypeStore.UNKNOWN else false) and
                        self.store.name_to_type.get(name) == null)
                    {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{name_str}),
                            .span = sd.meta.span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{name_str}),
                            .severity = .warning,
                        });
                        continue;
                    }
                    const type_id = self.store.name_to_type.get(name) orelse continue;
                    // Pre-bind formal type parameters (e.g. `T` in
                    // `pub struct Box(T)`) as fresh type variables so
                    // any reference to `T` inside the struct's field
                    // type expressions resolves to the same TypeVar
                    // TypeId. We save and restore the surrounding
                    // type_var_scope so per-decl bindings don't leak
                    // into sibling declarations or function clauses.
                    var formal_type_params: std.ArrayList(TypeId) = .empty;
                    const saved_type_var_scope = try self.snapshotTypeVarScope();
                    defer self.restoreTypeVarScope(saved_type_var_scope);
                    self.type_var_scope.clearRetainingCapacity();
                    for (sd.type_params) |formal_name_id| {
                        const formal_name = self.interner.get(formal_name_id);
                        const fresh_type_id = try self.store.freshVar();
                        try self.type_var_scope.put(formal_name, fresh_type_id);
                        try formal_type_params.append(self.allocator, fresh_type_id);
                    }

                    // Build struct fields with resolved types. Parent
                    // fields come first, then own fields (extending
                    // parent fields type-check here).
                    var fields: std.ArrayList(Type.StructField) = .empty;
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
                                        .default_expr = field.default,
                                    });
                                }
                            }
                        }
                    }
                    for (sd.fields) |field| {
                        const field_type = self.resolveTypeExpr(field.type_expr) catch TypeStore.UNKNOWN;
                        const default = field.default;
                        var found_parent = false;
                        for (fields.items) |*pf| {
                            if (pf.name == field.name) {
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
                                .default_expr = default,
                            });
                        }
                    }
                    self.store.types.items[type_id] = .{ .struct_type = .{
                        .name = name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                        .type_params = try formal_type_params.toOwnedSlice(self.allocator),
                    } };
                },
                .union_type => |ud| {
                    const enum_name_str = self.interner.get(ud.name);
                    if ((if (self.store.resolveTypeName(enum_name_str)) |builtin_type_id| builtin_type_id != TypeStore.UNKNOWN else false) and
                        self.store.name_to_type.get(ud.name) == null)
                    {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{enum_name_str}),
                            .span = ud.meta.span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{enum_name_str}),
                            .severity = .warning,
                        });
                        continue;
                    }
                    const type_id = self.store.name_to_type.get(ud.name) orelse continue;
                    // Pre-bind formal type parameters (e.g. `T` in
                    // `pub union Option(T)`) as fresh type variables
                    // so any reference to `T` inside the union's
                    // variant payload type expressions resolves to
                    // the same TypeVar TypeId.
                    var formal_type_params: std.ArrayList(TypeId) = .empty;
                    const saved_type_var_scope = try self.snapshotTypeVarScope();
                    defer self.restoreTypeVarScope(saved_type_var_scope);
                    self.type_var_scope.clearRetainingCapacity();
                    for (ud.type_params) |formal_name_id| {
                        const formal_name = self.interner.get(formal_name_id);
                        const fresh_type_id = try self.store.freshVar();
                        try self.type_var_scope.put(formal_name, fresh_type_id);
                        try formal_type_params.append(self.allocator, fresh_type_id);
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
                    self.store.types.items[type_id] = .{ .tagged_union = .{
                        .name = ud.name,
                        .variants = try variant_entries.toOwnedSlice(self.allocator),
                        .type_params = try formal_type_params.toOwnedSlice(self.allocator),
                    } };
                },
                .opaque_type => |opaque_body| {
                    const opaque_name_str = self.interner.get(type_entry.name);
                    if ((if (self.store.resolveTypeName(opaque_name_str)) |builtin_type_id| builtin_type_id != TypeStore.UNKNOWN else false) and
                        self.store.name_to_type.get(type_entry.name) == null)
                    {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{opaque_name_str}),
                            .span = type_entry.kind.opaque_type.getMeta().span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{opaque_name_str}),
                            .severity = .warning,
                        });
                        continue;
                    }
                    const type_id = self.store.name_to_type.get(type_entry.name) orelse continue;
                    const inner_type = try self.resolveTypeExpr(opaque_body);
                    self.store.types.items[type_id] = .{ .opaque_type = .{
                        .name = type_entry.name,
                        .inner = inner_type,
                    } };
                },
                else => {},
            }
        }
    }

    /// Check if a binding is shadowed by a later binding with the same name
    /// that IS referenced. This handles the case where the scope collector creates
    /// duplicate bindings (e.g., function parameters in :zig bridge call scopes).
    fn isBindingShadowed(self: *const TypeChecker, binding: scope_mod.Binding, bid: scope_mod.BindingId) bool {
        for (self.graph.bindings.items[bid + 1 ..], (bid + 1)..) |other, other_i| {
            if (other.name == binding.name and self.referenced_bindings.contains(@intCast(other_i))) {
                return true;
            }
        }
        return false;
    }

    fn isSyntheticSpan(span: ast.SourceSpan) bool {
        return span.start == 0 and span.end == 0 and span.line == 0;
    }

    fn isDisallowedUnderscoreFunctionCall(self: *const TypeChecker, name: ast.StringId, meta: ast.NodeMeta) bool {
        const text = self.interner.get(name);
        if (text.len == 0 or text[0] != '_') return false;
        return !(self.isSyntheticHelperName(name) and isSyntheticSpan(meta.span));
    }

    /// Single-`_`-prefixed bindings declare "I won't read this" — a
    /// later read contradicts the declaration. `__name` (double prefix)
    /// stays in the language-hook namespace and is fine to read.
    fn isReservedUnderscoreReadName(text: []const u8) bool {
        if (text.len == 0 or text[0] != '_') return false;
        if (text.len >= 2 and text[1] == '_') return false;
        return true;
    }

    fn rejectUnderscoreVarRead(self: *TypeChecker, name: ast.StringId, span: ast.SourceSpan) !void {
        const text = self.interner.get(name);
        if (!isReservedUnderscoreReadName(text)) return;
        try self.addRichError(
            try std.fmt.allocPrint(self.allocator, "cannot read `{s}` — single-underscore-prefixed bindings are intentionally unused", .{text}),
            span,
            "underscore-prefixed identifiers may only be assigned to, not read",
            try std.fmt.allocPrint(self.allocator, "drop the leading `_` if you need the value (rename to `{s}`)", .{text[1..]}),
        );
    }

    fn rejectUnderscoreCall(self: *TypeChecker, name: []const u8, arity: u32, span: ast.SourceSpan) !void {
        try self.addRichError(
            try std.fmt.allocPrint(self.allocator, "cannot call underscore-prefixed function `{s}/{d}`", .{ name, arity }),
            span,
            "underscore-prefixed function names are reserved for unused-warning suppression",
            "rename the function to a callable name before calling it directly",
        );
    }

    fn validateMacroBodyDoesNotCallUnderscoreFunctions(self: *TypeChecker, mac: *const ast.FunctionDecl) anyerror!void {
        for (mac.clauses) |clause| {
            if (clause.body) |body| {
                for (body) |stmt| {
                    try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                }
            }
        }
    }

    fn validateStmtDoesNotCallUnderscoreFunctions(self: *TypeChecker, stmt: ast.Stmt) anyerror!void {
        switch (stmt) {
            .expr => |expr| try self.validateExprDoesNotCallUnderscoreFunctions(expr),
            .assignment => |assignment| try self.validateExprDoesNotCallUnderscoreFunctions(assignment.value),
            .function_decl => |func| try self.validateFunctionBodyDoesNotCallUnderscoreFunctions(func),
            .macro_decl => |mac| try self.validateMacroBodyDoesNotCallUnderscoreFunctions(mac),
            .attribute => |attr| if (attr.value) |value| try self.validateExprDoesNotCallUnderscoreFunctions(value),
            .import_decl => {},
        }
    }

    fn validateFunctionBodyDoesNotCallUnderscoreFunctions(self: *TypeChecker, func: *const ast.FunctionDecl) anyerror!void {
        for (func.clauses) |clause| {
            if (clause.body) |body| {
                for (body) |stmt| {
                    try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                }
            }
        }
    }

    fn validateExprDoesNotCallUnderscoreFunctions(self: *TypeChecker, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .call => |call| {
                const arity: u32 = @intCast(call.args.len);
                if (call.callee.* == .var_ref) {
                    const name_id = call.callee.var_ref.name;
                    if (self.isDisallowedUnderscoreFunctionCall(name_id, call.callee.var_ref.meta)) {
                        try self.rejectUnderscoreCall(self.interner.get(name_id), arity, call.meta.span);
                    }
                } else if (call.callee.* == .field_access) {
                    const field_id = call.callee.field_access.field;
                    if (self.isDisallowedUnderscoreFunctionCall(field_id, call.callee.field_access.meta)) {
                        try self.rejectUnderscoreCall(self.interner.get(field_id), arity, call.meta.span);
                    }
                }
                try self.validateExprDoesNotCallUnderscoreFunctions(call.callee);
                for (call.args) |arg| try self.validateExprDoesNotCallUnderscoreFunctions(arg);
            },
            .binary_op => |op| {
                try self.validateExprDoesNotCallUnderscoreFunctions(op.lhs);
                try self.validateExprDoesNotCallUnderscoreFunctions(op.rhs);
            },
            .unary_op => |op| try self.validateExprDoesNotCallUnderscoreFunctions(op.operand),
            .pipe => |pipe| {
                try self.validateExprDoesNotCallUnderscoreFunctions(pipe.lhs);
                try self.validateExprDoesNotCallUnderscoreFunctions(pipe.rhs);
            },
            .unwrap => |unwrap| try self.validateExprDoesNotCallUnderscoreFunctions(unwrap.expr),
            .tuple => |tuple| for (tuple.elements) |element| try self.validateExprDoesNotCallUnderscoreFunctions(element),
            .list => |list| for (list.elements) |element| try self.validateExprDoesNotCallUnderscoreFunctions(element),
            .map => |map| {
                if (map.update_source) |source| try self.validateExprDoesNotCallUnderscoreFunctions(source);
                for (map.fields) |field| {
                    try self.validateExprDoesNotCallUnderscoreFunctions(field.key);
                    try self.validateExprDoesNotCallUnderscoreFunctions(field.value);
                }
            },
            .struct_expr => |struct_expr| {
                if (struct_expr.update_source) |source| try self.validateExprDoesNotCallUnderscoreFunctions(source);
                for (struct_expr.fields) |field| try self.validateExprDoesNotCallUnderscoreFunctions(field.value);
            },
            .range => |range| {
                try self.validateExprDoesNotCallUnderscoreFunctions(range.start);
                try self.validateExprDoesNotCallUnderscoreFunctions(range.end);
                if (range.step) |step| try self.validateExprDoesNotCallUnderscoreFunctions(step);
            },
            .field_access => |field_access| try self.validateExprDoesNotCallUnderscoreFunctions(field_access.object),
            .if_expr => |if_expr| {
                try self.validateExprDoesNotCallUnderscoreFunctions(if_expr.condition);
                for (if_expr.then_block) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                if (if_expr.else_block) |else_block| {
                    for (else_block) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                }
            },
            .case_expr => |case_expr| {
                try self.validateExprDoesNotCallUnderscoreFunctions(case_expr.scrutinee);
                for (case_expr.clauses) |clause| {
                    if (clause.guard) |guard| try self.validateExprDoesNotCallUnderscoreFunctions(guard);
                    try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(clause.pattern);
                    for (clause.body) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                }
            },
            .cond_expr => |cond_expr| {
                for (cond_expr.clauses) |clause| {
                    try self.validateExprDoesNotCallUnderscoreFunctions(clause.condition);
                    for (clause.body) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                }
            },
            .for_expr => |for_expr| {
                try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(for_expr.var_pattern);
                try self.validateExprDoesNotCallUnderscoreFunctions(for_expr.iterable);
                if (for_expr.filter) |filter| try self.validateExprDoesNotCallUnderscoreFunctions(filter);
                try self.validateExprDoesNotCallUnderscoreFunctions(for_expr.body);
            },
            .list_cons_expr => |list_cons| {
                try self.validateExprDoesNotCallUnderscoreFunctions(list_cons.head);
                try self.validateExprDoesNotCallUnderscoreFunctions(list_cons.tail);
            },
            .quote_expr => |quote_expr| {
                for (quote_expr.body) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
            },
            .unquote_expr => |unquote| try self.validateExprDoesNotCallUnderscoreFunctions(unquote.expr),
            .unquote_splicing_expr => |unquote_splicing| try self.validateExprDoesNotCallUnderscoreFunctions(unquote_splicing.expr),
            .panic_expr => |panic_expr| try self.validateExprDoesNotCallUnderscoreFunctions(panic_expr.message),
            .error_pipe => |error_pipe| {
                try self.validateExprDoesNotCallUnderscoreFunctions(error_pipe.chain);
                switch (error_pipe.handler) {
                    .block => |clauses| for (clauses) |clause| {
                        if (clause.guard) |guard| try self.validateExprDoesNotCallUnderscoreFunctions(guard);
                        try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(clause.pattern);
                        for (clause.body) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt);
                    },
                    .function => |function| try self.validateExprDoesNotCallUnderscoreFunctions(function),
                }
            },
            .block => |block| for (block.stmts) |stmt| try self.validateStmtDoesNotCallUnderscoreFunctions(stmt),
            .intrinsic => |intrinsic| for (intrinsic.args) |arg| try self.validateExprDoesNotCallUnderscoreFunctions(arg),
            .binary_literal => |binary_literal| for (binary_literal.segments) |segment| try self.validateBinarySegmentDoesNotCallUnderscoreFunctions(segment),
            .anonymous_function => |anonymous_function| try self.validateFunctionBodyDoesNotCallUnderscoreFunctions(anonymous_function.decl),
            .type_annotated => |type_annotated| try self.validateExprDoesNotCallUnderscoreFunctions(type_annotated.expr),
            .string_interpolation => |interpolation| for (interpolation.parts) |part| {
                switch (part) {
                    .expr => |part_expr| try self.validateExprDoesNotCallUnderscoreFunctions(part_expr),
                    .literal => {},
                }
            },
            .int_literal,
            .float_literal,
            .string_literal,
            .atom_literal,
            .bool_literal,
            .nil_literal,
            .var_ref,
            .struct_ref,
            .attr_ref,
            .function_ref,
            => {},
        }
    }

    fn validatePatternExpressionsDoNotCallUnderscoreFunctions(self: *TypeChecker, pattern: *const ast.Pattern) anyerror!void {
        switch (pattern.*) {
            .tuple => |tuple| for (tuple.elements) |element| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(element),
            .list => |list| for (list.elements) |element| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(element),
            .list_cons => |list_cons| {
                for (list_cons.heads) |head| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(head);
                try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(list_cons.tail);
            },
            .map => |map| for (map.fields) |field| {
                try self.validateExprDoesNotCallUnderscoreFunctions(field.key);
                try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(field.value);
            },
            .struct_pattern => |struct_pattern| for (struct_pattern.fields) |field| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(field.pattern),
            .pin => {},
            .paren => |paren| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(paren.inner),
            .binary => |binary| for (binary.segments) |segment| try self.validateBinarySegmentDoesNotCallUnderscoreFunctions(segment),
            .wildcard,
            .bind,
            .literal,
            => {},
        }
    }

    fn validateBinarySegmentDoesNotCallUnderscoreFunctions(self: *TypeChecker, segment: ast.BinarySegment) anyerror!void {
        switch (segment.value) {
            .expr => |expr| try self.validateExprDoesNotCallUnderscoreFunctions(expr),
            .pattern => |pattern| try self.validatePatternExpressionsDoNotCallUnderscoreFunctions(pattern),
            .string_literal => {},
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
            // Skip bindings that are shadowed by a later binding with the same name
            // in a child scope. The shadowing binding takes the references, leaving
            // the original appearing "unused". This happens with function parameters
            // in :zig bridge calls where the scope collector creates duplicate bindings.
            if (self.isBindingShadowed(binding, bid)) continue;

            try self.addRichError(
                try std.fmt.allocPrint(self.allocator, "variable `{s}` is unused", .{name}),
                binding.span,
                "defined here but never used",
                try std.fmt.allocPrint(self.allocator, "if this is intentional, prefix with underscore: `_{s}`", .{name}),
            );
        }
    }

    /// Diagnose recursive struct types that have no finite base case.
    /// A struct is "inhabitable" iff every required field can take a
    /// finitely-sized value: primitives are always fine, optional /
    /// list / map / atom / `any` / `term` are always fine (each has a
    /// natural empty inhabitant), and a `struct_ref X` is fine iff
    /// `X` is itself inhabitable. Fixpoint propagation closes over
    /// any cycle: a struct stays uninhabitable iff every constructor
    /// path forces another instance from its own SCC.
    ///
    /// Without this, programs like
    ///
    ///   pub struct Tree { left :: Tree, right :: Tree }
    ///
    /// reach Sema and trip Zig's `struct has infinite size`
    /// diagnostic — accurate but not actionable. The friendly
    /// message points at the structural problem (no nil escape, no
    /// list, no tagged-union leaf) instead of the layout symptom.
    fn checkUninhabitedRecursiveTypes(self: *TypeChecker) !void {
        const ts = self.store;
        // Collect every struct's TypeId so the fixpoint can be keyed
        // on a small dense set rather than re-scanning `types.items`
        // each pass.
        var struct_ids: std.ArrayListUnmanaged(TypeId) = .empty;
        defer struct_ids.deinit(self.allocator);
        for (ts.types.items, 0..) |typ, i| {
            if (typ != .struct_type) continue;
            try struct_ids.append(self.allocator, @intCast(i));
        }

        // Fixpoint: start every struct as uninhabitable, mark those
        // whose every field is inhabitable, repeat until stable.
        var inhabitable: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
        defer inhabitable.deinit(self.allocator);

        var changed = true;
        while (changed) {
            changed = false;
            for (struct_ids.items) |sid| {
                if (inhabitable.contains(sid)) continue;
                const st = ts.types.items[sid].struct_type;
                var all_ok = true;
                for (st.fields) |f| {
                    if (!self.typeIdInhabitable(f.type_id, &inhabitable)) {
                        all_ok = false;
                        break;
                    }
                }
                if (all_ok) {
                    try inhabitable.put(self.allocator, sid, {});
                    changed = true;
                }
            }
        }

        // Anything still uninhabitable is a recursive structural
        // dead end. Locate the source span via the scope graph and
        // emit a friendly diagnostic.
        for (struct_ids.items) |sid| {
            if (inhabitable.contains(sid)) continue;
            const st = ts.types.items[sid].struct_type;
            const name_str = self.interner.get(st.name);
            const span = self.findStructDeclSpan(st.name) orelse continue;
            try self.addHardError(
                try std.fmt.allocPrint(
                    self.allocator,
                    "recursive type `{s}` has no finite base case",
                    .{name_str},
                ),
                span,
                "every constructor of this type requires another instance of itself",
                "make at least one cycle field optional (`T | nil`), a list (`[T]`), or a map; or split the type into a tagged union with a leaf variant",
            );
        }
    }

    /// True iff a value of `type_id` can be constructed in finite
    /// space without dragging in an uninhabitable struct. Container
    /// types (`?T`, `[T]`, `Map(K, V)`) are inhabited by their
    /// natural empty values regardless of `T`'s inhabitability —
    /// that's what breaks a recursive cycle. Tuples are inhabited
    /// iff every element is. `struct_ref` is inhabited iff the
    /// referenced struct's id is in `inhabitable`.
    fn typeIdInhabitable(
        self: *const TypeChecker,
        type_id: TypeId,
        inhabitable: *const std.AutoHashMapUnmanaged(TypeId, void),
    ) bool {
        if (type_id >= self.store.types.items.len) return true;
        const typ = self.store.types.items[type_id];
        return switch (typ) {
            .struct_type => inhabitable.contains(type_id),
            .union_type => |ut| blk: {
                // A union is inhabitable iff at least one member is.
                for (ut.members) |m| {
                    if (self.typeIdInhabitable(m, inhabitable)) break :blk true;
                }
                break :blk false;
            },
            .tuple => |tt| blk: {
                for (tt.elements) |elem| {
                    if (!self.typeIdInhabitable(elem, inhabitable)) break :blk false;
                }
                break :blk true;
            },
            .applied => |at| self.typeIdInhabitable(at.base, inhabitable),
            // Optional, list, and map all have natural empty values
            // — they break recursion cycles regardless of payload.
            // Tagged unions, opaque types, and protocol constraints
            // are treated as inhabited from the structural-recursion
            // perspective (they don't lay out by value here).
            .list,
            .map,
            .tagged_union,
            .opaque_type,
            .protocol_constraint,
            => true,
            // Primitives, atoms, strings, function refs, type vars,
            // unknown placeholder — all naturally inhabited.
            else => true,
        };
    }

    /// Look up a struct declaration's source span by `StringId`. The
    /// scope graph keeps every struct decl with its `meta.span`;
    /// matching by the leaf name is enough for top-level and nested
    /// declarations because Zap requires unique struct names within
    /// each scope.
    fn findStructDeclSpan(self: *const TypeChecker, name: ast.StringId) ?ast.SourceSpan {
        for (self.graph.types.items) |type_entry| {
            switch (type_entry.kind) {
                .struct_type => |sd| {
                    if (type_entry.name == name) return sd.meta.span;
                },
                else => {},
            }
        }
        return null;
    }

    fn checkStruct(self: *TypeChecker, mod: *const ast.StructDecl) !void {
        const prev_scope = self.current_scope;
        self.current_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(mod.meta.span)) orelse mod.meta.scope_id;
        defer self.current_scope = prev_scope;

        // Check struct extends: validate overridden function return types match parent
        if (mod.parent) |parent_name| {
            try self.checkStructExtendsSignatures(mod, parent_name);
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
                    try self.validateMacroBodyDoesNotCallUnderscoreFunctions(mac);
                    // Macro bodies are compile-time templates that the
                    // macro engine evaluates at expansion time, not
                    // code the type checker analyses. Every binding
                    // introduced inside a macro clause — parameters,
                    // top-level let-bindings, and let-bindings inside
                    // any nested construct (if/case/cond/for branches,
                    // blocks, anonymous functions) — is consumed by
                    // the macro engine and is typically referenced via
                    // `unquote(name)` inside a `quote { ... }` template
                    // rather than the var_ref path the unused-binding
                    // check tracks.
                    //
                    // Mark every binding registered in the macro
                    // clause's scope or any descendant scope as
                    // referenced. We walk the scope graph rather than
                    // the AST because not every scope-creating
                    // construct (e.g. `if` then/else branches) is
                    // registered in `node_scope_map`, which would make
                    // an AST-driven walk unable to locate the right
                    // binding scope. Bindings are far cheaper to
                    // enumerate than to retrace through the AST.
                    for (mac.clauses) |clause| {
                        const macro_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
                        try self.markBindingsInScopeSubtree(macro_scope);
                    }
                },
                .attribute => |attr| {
                    try self.checkAttributeDecl(attr);
                },
                .struct_level_expr => |expr| {
                    _ = try self.inferExpr(expr);
                },
                else => {},
            }
        }
    }

    /// Insert every binding registered in `root_scope` or any
    /// descendant scope into `referenced_bindings`. Used when handling
    /// macro declarations so that compile-time-only bindings inside
    /// macro bodies aren't reported as unused (see the `.macro` /
    /// `.priv_macro` arm in `checkStruct`).
    ///
    /// The scope graph stores parent links but no children list, so
    /// descendant detection walks each scope's parent chain upward
    /// looking for `root_scope`. Scope IDs are dense u32 indices into
    /// `graph.scopes`, so this is a single linear pass over scopes
    /// followed by a linear pass over bindings — cheap relative to the
    /// surrounding type-check work.
    fn markBindingsInScopeSubtree(self: *TypeChecker, root_scope: scope_mod.ScopeId) !void {
        var in_subtree = std.AutoHashMap(scope_mod.ScopeId, void).init(self.allocator);
        defer in_subtree.deinit();

        try in_subtree.put(root_scope, {});
        // Multiple sweeps so a child whose parent has not yet been
        // marked still gets included. Scopes are appended in
        // creation order, and a scope's parent is always created
        // before it, so a single forward pass suffices — but we run
        // until a sweep adds nothing to be robust to any future
        // ordering change in the collector.
        var changed = true;
        while (changed) {
            changed = false;
            for (self.graph.scopes.items) |s| {
                if (in_subtree.contains(s.id)) continue;
                const parent = s.parent orelse continue;
                if (in_subtree.contains(parent)) {
                    try in_subtree.put(s.id, {});
                    changed = true;
                }
            }
        }

        for (self.graph.bindings.items) |binding| {
            if (in_subtree.contains(binding.scope_id)) {
                try self.referenced_bindings.put(binding.id, {});
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
                        try std.fmt.allocPrint(
                            self.allocator,
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
            // Value-only attribute (e.g., a heredoc `@doc`) — valid
        } else {
            // Type without value — should not happen
            const attr_name = self.interner.get(attr.name);
            try self.addHardError(
                try std.fmt.allocPrint(
                    self.allocator,
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
                try std.fmt.allocPrint(
                    self.allocator,
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
                    try std.fmt.allocPrint(
                        self.allocator,
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

    fn checkStructExtendsSignatures(self: *TypeChecker, mod: *const ast.StructDecl, parent_name: ast.StringId) !void {
        // Find parent struct
        var parent_mod: ?*const ast.StructDecl = null;
        for (self.graph.structs.items) |mod_entry| {
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
            .macro, .priv_macro => |mac| try self.validateMacroBodyDoesNotCallUnderscoreFunctions(mac),
            .struct_decl, .priv_struct_decl => {},
            .impl_decl, .priv_impl_decl => |impl_d| {
                const prev_impl = self.current_impl;
                self.current_impl = impl_d;
                defer self.current_impl = prev_impl;
                for (impl_d.functions) |func| {
                    try self.checkFunctionDecl(func);
                }
            },
            else => {},
        }
    }

    // ============================================================
    // Function type checking
    // ============================================================

    fn checkFunctionDecl(self: *TypeChecker, func: *const ast.FunctionDecl) !void {
        for (func.clauses) |clause| {
            try self.checkFunctionClause(func, &clause);
        }
    }

    /// Recursively traverse statements to infer and record binding types.
    /// Handles nested blocks, case expressions, and if expressions that
    /// may contain assignments in macro-generated test function bodies.
    fn inferBodyBindings(self: *TypeChecker, stmts: []const ast.Stmt) void {
        for (stmts) |stmt| {
            switch (stmt) {
                .assignment => |assign| {
                    const value_type = self.inferExpr(assign.value) catch TypeStore.UNKNOWN;
                    if (value_type != TypeStore.UNKNOWN and value_type != TypeStore.ERROR) {
                        if (assign.pattern.* == .bind) {
                            if (self.current_scope) |scope_id| {
                                if (self.graph.resolveBindingHygienic(scope_id, assign.pattern.bind.name, assign.pattern.bind.meta.scopes)) |bid| {
                                    self.recordBindingType(bid, value_type, assign.value.getMeta().span) catch {};
                                }
                            }
                        }
                    }
                },
                .expr => |expr| {
                    // Recursively traverse blocks and compound expressions
                    self.inferExprBindings(expr);
                },
                else => {},
            }
        }
    }

    /// Recursively traverse an expression to find nested assignments in blocks.
    fn inferExprBindings(self: *TypeChecker, expr: *const ast.Expr) void {
        switch (expr.*) {
            .block => |blk| {
                // Enter the block's scope so bindings created inside are visible
                const prev_scope = self.current_scope;
                const block_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(blk.meta.span));
                if (block_scope) |bs| {
                    self.current_scope = bs;
                }
                self.inferBodyBindings(blk.stmts);
                self.current_scope = prev_scope;
            },
            .case_expr => |ce| {
                _ = self.inferExpr(ce.scrutinee) catch {};
                for (ce.clauses) |clause| {
                    self.inferBodyBindings(clause.body);
                }
            },
            .if_expr => |ie| {
                _ = self.inferExpr(ie.condition) catch {};
                self.inferBodyBindings(ie.then_block);
                if (ie.else_block) |else_block| {
                    self.inferBodyBindings(else_block);
                }
            },
            .call => {
                _ = self.inferExpr(expr) catch {};
            },
            else => {},
        }
    }

    fn isAnonymousFunctionDecl(self: *const TypeChecker, func: *const ast.FunctionDecl) bool {
        return std.mem.startsWith(u8, self.interner.get(func.name), "__anon_fn_");
    }

    fn isStringListType(self: *const TypeChecker, type_id: TypeId) bool {
        if (type_id >= self.store.types.items.len) return false;
        const typ = self.store.getType(type_id);
        return typ == .list and self.store.typeEquals(typ.list.element, TypeStore.STRING);
    }

    fn validateMainEntrypointReturnType(self: *TypeChecker, func: *const ast.FunctionDecl, clause: *const ast.FunctionClause, declared_return: TypeId) !void {
        if (!std.mem.eql(u8, self.interner.get(func.name), "main")) return;
        if (clause.params.len != 1) return;
        const args_type_expr = clause.params[0].type_annotation orelse return;
        const args_type = try self.resolveTypeExpr(args_type_expr);
        if (!self.isStringListType(args_type)) return;
        if (declared_return == TypeStore.UNKNOWN or declared_return == TypeStore.ERROR) return;

        if (self.store.typeEquals(declared_return, TypeStore.U8)) {
            return;
        }

        const got = self.typeToString(declared_return);
        try self.addHardError(
            try std.fmt.allocPrint(self.allocator, "executable main/1 must return `u8`, got `{s}`", .{got}),
            clause.meta.span,
            "invalid main/1 return type",
            "return `u8` to set the process exit code",
        );
    }

    fn checkFunctionClause(self: *TypeChecker, func: *const ast.FunctionDecl, clause: *const ast.FunctionClause) !void {
        const prev_scope = self.current_scope;
        self.current_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
        defer self.current_scope = prev_scope;

        // Each function clause gets its own type variable scope so that
        // `a` in `fn foo(x :: a) -> a` refers to the same type variable.
        self.type_var_scope.clearRetainingCapacity();

        // Inside an impl block, pre-bind the impl's declared type
        // parameters so subsequent param/return resolution sees them as
        // type variables (regardless of name casing). Without this, a
        // reference like `K` in `pub fn next(map :: Map(K, V)) -> ... K`
        // would resolve as an unknown concrete type because the parser
        // emits an uppercase identifier as `.name`, not `.variable`.
        if (self.current_impl) |impl_d| {
            for (impl_d.type_params) |tp_name_id| {
                const tp_name = self.interner.get(tp_name_id);
                if (!self.type_var_scope.contains(tp_name)) {
                    const fresh = self.store.freshVar() catch continue;
                    self.type_var_scope.put(tp_name, fresh) catch {};
                }
            }
        }

        const is_anon = self.isAnonymousFunctionDecl(func);

        // Synthetic helpers (e.g. for-comp `__for_N`) have no source-level
        // annotations, so their parameter types come from `inferred_signatures`,
        // which the type checker populates when external call sites are
        // processed. Looking it up once here lets the body see the right
        // `__state` type for protocol dispatch on `Enumerable.next(__state)`.
        const inferred_sig = self.store.inferred_signatures.get(func.name);

        // Resolve parameter types and populate bindings
        for (clause.params, 0..) |param, param_idx| {
            if (param.type_annotation) |ta| {
                const param_type = try self.resolveTypeExpr(ta);
                const qualified = QualifiedType.init(param_type, self.resolveParamOwnership(param, param_type));
                // Store type on the binding in scope graph if this is a bind pattern
                if (param.pattern.* == .bind) {
                    const bind_name = param.pattern.bind.name;
                    if (self.current_scope) |scope_id| {
                        if (self.graph.resolveBindingHygienic(scope_id, bind_name, param.pattern.bind.meta.scopes)) |bid| {
                            try self.recordBindingQualifiedType(bid, qualified, ta.getMeta().span);
                        }
                    }
                } else {
                    // Compound parameter pattern (cons `[h | t]`, list,
                    // tuple, struct, map): destructure the annotated
                    // type into its inner bindings. Without this, `h`
                    // in `pub fn f([h | t] :: [String])` keeps an
                    // UNKNOWN type, which breaks downstream
                    // first-arg-driven protocol dispatch (e.g.
                    // `h <> rest` -> `Concatenable.concat`).
                    // `recordParamBindingTypes` no-ops on
                    // type-variable-bearing annotations (e.g.
                    // impl-method params with `[element]`) so generic
                    // monomorphisation isn't pinned to a concrete
                    // specialisation here.
                    try self.recordParamBindingTypes(param.pattern, param_type, ta.getMeta().span);
                }
            } else if (inferred_sig) |sig| {
                if (param_idx < sig.param_types.len and sig.param_types[param_idx] != TypeStore.UNKNOWN) {
                    const param_type = sig.param_types[param_idx];
                    const qualified = QualifiedType.init(param_type, self.resolveParamOwnership(param, param_type));
                    if (param.pattern.* == .bind) {
                        const bind_name = param.pattern.bind.name;
                        if (self.current_scope) |scope_id| {
                            if (self.graph.resolveBindingHygienic(scope_id, bind_name, param.pattern.bind.meta.scopes)) |bid| {
                                try self.recordBindingQualifiedType(bid, qualified, param.pattern.getMeta().span);
                            }
                        }
                    } else {
                        try self.recordParamBindingTypes(param.pattern, param_type, param.pattern.getMeta().span);
                    }
                }
            } else if (param.pattern.* == .literal) {
                // Infer type from literal pattern — no annotation needed
                const param_type = switch (param.pattern.literal) {
                    .string => self.store.addType(.string_type) catch TypeStore.UNKNOWN,
                    .int => self.store.addType(.{ .int = .{ .signedness = .signed, .bits = 64 } }) catch TypeStore.UNKNOWN,
                    .float => self.store.addType(.{ .float = .{ .bits = 64 } }) catch TypeStore.UNKNOWN,
                    .atom => self.store.addType(.atom_type) catch TypeStore.UNKNOWN,
                    .bool_lit => self.store.addType(.bool_type) catch TypeStore.UNKNOWN,
                    .nil => self.store.addType(.nil_type) catch TypeStore.UNKNOWN,
                };
                _ = QualifiedType.init(param_type, self.resolveParamOwnership(param, param_type));
            } else {
                // Generated functions (span 0:0) may lack type annotations.
                // Only error for user-written functions with real source locations.
                const span = param.pattern.getMeta().span;
                if (span.start != 0 or span.end != 0) {
                    try self.addHardError(
                        if (is_anon)
                            try std.fmt.allocPrint(self.allocator, "anonymous function parameter requires a type annotation", .{})
                        else
                            try std.fmt.allocPrint(self.allocator, "parameter requires a type annotation (e.g., `param :: Type`)", .{}),
                        span,
                        "missing type annotation",
                        if (is_anon)
                            "write the parameter like `fn(x :: Type) -> ReturnType { ... }`"
                        else
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
                    if (is_anon)
                        "anonymous function is missing a return type annotation"
                    else
                        "missing return type annotation",
                    span,
                    if (is_anon)
                        "this anonymous function has no return type"
                    else
                        "this function has no return type",
                    if (is_anon)
                        "add a return type: `fn(params) -> ReturnType { ... }`"
                    else
                        "add a return type: `def name(params) -> ReturnType do`",
                );
            }
            break :blk TypeStore.UNKNOWN;
        };

        try self.validateMainEntrypointReturnType(func, clause, declared_return);

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

        // Check body (skip for bodyless declarations: protocol sigs, forward decls)
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
            if (self.closureDeclFromExpr(expr)) |decl| {
                if (self.functionDeclCapturesBorrowed(decl)) {
                    try self.addHardError(
                        "closure with borrowed captures cannot escape through return",
                        expr.getMeta().span,
                        "borrowed capture escapes scope",
                        "avoid returning closures that capture borrowed values",
                    );
                }
            }
        }

        // Skip return type check for bodyless declarations (protocol sigs, forward decls).
        if (clause.body == null) return;

        // Synthetic helper return-type fixpoint: when this clause has no
        // declared return type but the type checker has a call-site-inferred
        // signature whose return is still UNKNOWN, fold in the body's
        // computed type. The body has been fully processed by checkStmt
        // above, so `body_type` already reflects whatever the case
        // expression / cons expression / etc. produced. Without this, the
        // for-comp helper for non-list iterables (Map, Range, custom
        // Enumerable impls) keeps an UNKNOWN return type — IR widens it to
        // `.any` and ZIR emits a void-returning function, which then trips
        // type errors at the call site.
        if (clause.return_type == null and body_type != TypeStore.UNKNOWN and body_type != TypeStore.ERROR) {
            if (self.store.inferred_signatures.getPtr(func.name)) |sig_ptr| {
                if (sig_ptr.return_type == TypeStore.UNKNOWN) {
                    sig_ptr.return_type = body_type;
                }
            }
        }

        // Verify return type matches (suppress if either side is ERROR/UNKNOWN/type_var from cascading)
        const declared_is_checkable = declared_return != TypeStore.UNKNOWN and
            declared_return != TypeStore.ERROR and
            self.store.getType(declared_return) != .type_var;
        if (declared_is_checkable and body_type != TypeStore.UNKNOWN and body_type != TypeStore.ERROR) {
            const return_matches_declared = self.store.typeEquals(body_type, declared_return) or
                if (last_expr) |expr| self.exprTailIntegerLiteralCanSatisfyExpectedType(expr, declared_return) else false;
            if (!return_matches_declared) {
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
                try self.recordAssignmentBindingTypes(assign.pattern, value_type, assign.value.getMeta().span);
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
            .attribute => |attr| {
                if (attr.value) |value| _ = try self.inferExpr(value);
                return TypeStore.NIL;
            },
        };
    }

    // ============================================================
    // Expression type inference
    // ============================================================

    fn inferExpr(self: *TypeChecker, expr: *const ast.Expr) anyerror!TypeId {
        // Memoize by AST pointer to collapse the O(2^N) redundant
        // re-inference of nested-call AST pointers in `inferCall` (~14
        // sites at lines 4160, 4304, 4316, 4463, 4502, 4544, 4555, 4564,
        // 4586, 4630, 4666, 4688, 4695 all walk the same arg slice). For
        // an N-deep nested-call chain (e.g. a 13-`<>` chain expanded to
        // nested `Concatenable.concat` calls) this redundant recursion
        // pushed `TypeChecker.checkProgram` from sub-second to 5+ minutes
        // for the single struct holding the chain — task #15 PART 2's
        // root cause.
        //
        // The cache is scoped to a single top-level `inferExpr` call
        // tree: `infer_depth` increments on entry, decrements on exit,
        // and the cache is cleared when depth returns to zero. This
        // ensures side-effects (binding-ownership tracking, error
        // reporting) fire on the FIRST visit within a top-level call
        // tree, while external callers (e.g. tests that mutate
        // ownership state between `inferExpr` calls) always start with
        // a fresh cache.
        if (self.expr_types.get(@intFromPtr(expr))) |cached| return cached;
        self.infer_depth += 1;
        const result = self.inferExprUncached(expr) catch |err| {
            self.infer_depth -= 1;
            if (self.infer_depth == 0) self.expr_types.clearRetainingCapacity();
            return err;
        };
        self.expr_types.put(@intFromPtr(expr), result) catch {};
        self.infer_depth -= 1;
        if (self.infer_depth == 0) self.expr_types.clearRetainingCapacity();
        return result;
    }

    fn inferExprUncached(self: *TypeChecker, expr: *const ast.Expr) anyerror!TypeId {
        return switch (expr.*) {
            .int_literal => TypeStore.I64,
            .float_literal => TypeStore.F64,
            .string_literal => TypeStore.STRING,
            .atom_literal => TypeStore.ATOM,
            .bool_literal => TypeStore.BOOL,
            .nil_literal => TypeStore.NIL,
            .var_ref => |vr| {
                // Bare `_` is a discarder pattern. The parser folds
                // `_` in pattern position into `Pattern.wildcard`, so
                // a `_` reaching this branch is always a *read* of the
                // discarder, which is illegal — by definition there's
                // no value to read.
                {
                    const name = self.interner.get(vr.name);
                    if (std.mem.eql(u8, name, "_")) {
                        try self.addRichError(
                            try self.allocator.dupe(u8, "cannot read `_` — bare underscore is a discarder, not a binding"),
                            vr.meta.span,
                            "the discarder pattern `_` discards a value; it cannot be read back",
                            try self.allocator.dupe(u8, "introduce a named binding (e.g. `value = expr`) if you need the value"),
                        );
                        return TypeStore.UNKNOWN;
                    }
                }
                // Resolve type from scope binding
                if (self.current_scope) |scope_id| {
                    if (self.graph.resolveBindingHygienic(scope_id, vr.name, vr.meta.scopes)) |bid| {
                        // Reading a single-`_`-prefixed binding is a
                        // contradiction: the prefix tells the compiler
                        // the binding is intentionally unused, so a
                        // subsequent read either means the prefix is a
                        // mistake (drop it) or the read is a typo.
                        // Double-underscore (`__foo`) names are reserved
                        // for the language-hook namespace and stay
                        // readable. Bare `_` parses as a discarder
                        // pattern and never reaches this branch.
                        try self.rejectUnderscoreVarRead(vr.name, vr.meta.span);
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
                const var_name = self.interner.get(vr.name);
                if (self.store.resolveTypeName(var_name)) |type_id| {
                    if (type_id != TypeStore.UNKNOWN) {
                        return self.resolveFirstClassTypeStructType() orelse TypeStore.UNKNOWN;
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
                // Unify all element types so heterogeneous lists fall back
                // to `Term` and tuple-shaped element disagreements unify
                // component-wise. Mirrors `HirBuilder.unifyForCollection`.
                var elem_type = try self.inferExpr(l.elements[0]);
                for (l.elements[1..]) |e| {
                    const t = try self.inferExpr(e);
                    elem_type = self.unifyForCollection(elem_type, t);
                }
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

                    const clause_type = try self.checkCaseClause(clause, scrutinee_type);
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
                                // Check for struct_ref pattern matching enum variant
                                // e.g. Color.Red → literal atom pattern or struct_ref pattern
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
                const prev_scope = self.current_scope;
                const resolved_block_scope: ?scope_mod.ScopeId = if (blk.meta.scope_id != 0)
                    blk.meta.scope_id
                else
                    self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(blk.meta.span));
                if (resolved_block_scope) |block_scope| {
                    self.current_scope = block_scope;
                }
                defer self.current_scope = prev_scope;

                var result_type: TypeId = TypeStore.NIL;
                for (blk.stmts) |stmt| {
                    result_type = try self.checkStmt(stmt);
                }
                return result_type;
            },

            .anonymous_function => |anon| {
                try self.checkFunctionDecl(anon.decl);
                if (self.current_scope) |scope_id| {
                    if (try self.resolveFunctionValueSignature(scope_id, anon.decl.name)) |signature| {
                        return try self.store.addFunctionType(
                            signature.params,
                            signature.return_type,
                            signature.param_ownerships,
                            signature.return_ownership,
                        );
                    }
                }
                const clause = anon.decl.clauses[0];
                const params = try self.allocator.alloc(TypeId, clause.params.len);
                for (clause.params, 0..) |param, idx| {
                    params[idx] = if (param.type_annotation) |ann|
                        try self.resolveTypeExpr(ann)
                    else
                        TypeStore.UNKNOWN;
                }
                const return_type = if (clause.return_type) |rt|
                    try self.resolveTypeExpr(rt)
                else
                    TypeStore.UNKNOWN;
                return try self.buildFunctionType(params, return_type);
            },

            .function_ref => |fr| {
                _ = try self.resolveFunctionRefSignature(fr);
                return self.resolveFirstClassFunctionStructType() orelse TypeStore.UNKNOWN;
            },
            .field_access => |fa| {
                if (fa.object.* == .struct_ref) {
                    if (try self.resolveTaggedUnionVariant(fa.object.struct_ref.name, fa.field, fa.meta.span)) |type_id| {
                        return type_id;
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
                    if (t == .tuple) {
                        const field_name = self.interner.get(fa.field);
                        const tuple_index = std.fmt.parseUnsigned(u32, field_name, 10) catch return TypeStore.UNKNOWN;
                        if (tuple_index < t.tuple.elements.len) {
                            return t.tuple.elements[tuple_index];
                        }
                        try self.addHardError(
                            try std.fmt.allocPrint(self.allocator, "tuple index {d} is out of bounds for arity {d}", .{
                                tuple_index,
                                t.tuple.elements.len,
                            }),
                            fa.meta.span,
                            "tuple index out of bounds",
                            null,
                        );
                        return TypeStore.UNKNOWN;
                    }
                }
                return TypeStore.UNKNOWN;
            },
            .map => |m| {
                // Infer key/value types from all entries. Disagreement on
                // either axis collapses to `Term` so heterogeneous map
                // literals get a uniform runtime type. Returning a real
                // `Map(K, V)` type (instead of UNKNOWN) lets call-site type
                // inference for synthetic helpers — like for-comp `__for_N`
                // — propagate the iterable's type into the helper's param.
                if (m.fields.len > 0) {
                    for (m.fields) |field| {
                        try self.ensureClosureValueCanEscape(field.key, "map key storage");
                        try self.ensureClosureValueCanEscape(field.value, "map value storage");
                    }
                    var key_t = try self.inferExpr(m.fields[0].key);
                    var value_t = try self.inferExpr(m.fields[0].value);
                    for (m.fields[1..]) |field| {
                        const k = try self.inferExpr(field.key);
                        const v = try self.inferExpr(field.value);
                        key_t = self.unifyForCollection(key_t, k);
                        value_t = self.unifyForCollection(value_t, v);
                    }
                    return try self.store.addType(.{ .map = .{ .key = key_t, .value = value_t } });
                }
                // Empty map literal `%{}`: still a Map, just with type
                // variables for key/value. Returning UNKNOWN here would
                // suppress protocol dispatch on the iterable, leaving
                // `Enumerable.next` as a dangling literal call at codegen.
                const key_var = try self.store.freshVar();
                const value_var = try self.store.freshVar();
                return try self.store.addType(.{ .map = .{ .key = key_var, .value = value_var } });
            },
            .struct_expr => |se| {
                // Resolve struct type from struct name annotation
                if (se.struct_name.parts.len > 0) {
                    const full_type_name_id = try self.internDottedStructName(se.struct_name);
                    const simple_type_name_id = se.struct_name.parts[se.struct_name.parts.len - 1];
                    const type_name_id = if (self.store.name_to_type.get(full_type_name_id) != null)
                        full_type_name_id
                    else
                        simple_type_name_id;
                    if (self.store.name_to_type.get(type_name_id)) |tid| {
                        const typ = self.store.getType(tid);
                        if (typ == .struct_type) {
                            // Validate required fields are provided
                            const st = typ.struct_type;

                            // Parametric instantiation: build the
                            // substitution map mapping formal type
                            // parameters to the concrete type
                            // arguments supplied at the literal. The
                            // map stays empty (and substitution is a
                            // no-op) for concrete structs.
                            var instantiation = try self.buildStructLiteralInstantiation(se, st, type_name_id);
                            defer instantiation.deinit();

                            for (st.fields) |req_field| {
                                var found = false;
                                for (se.fields) |provided| {
                                    if (provided.name == req_field.name) {
                                        try self.ensureClosureValueCanEscape(provided.value, "struct field storage");
                                        found = true;
                                        // Apply the per-instantiation
                                        // substitution before comparing
                                        // against the supplied value's
                                        // type. For non-parametric
                                        // structs the map is empty and
                                        // `applyToType` is a pass-through.
                                        const expected_type = instantiation.substitution.applyToType(self.store, req_field.type_id);
                                        const val_type = try self.inferExpr(provided.value);
                                        if (val_type != TypeStore.UNKNOWN and expected_type != TypeStore.UNKNOWN and
                                            !self.store.typeEquals(val_type, expected_type) and
                                            !self.acceptsIntegerLiteralForExpectedType(provided.value, expected_type))
                                        {
                                            try self.addRichError(
                                                try std.fmt.allocPrint(self.allocator, "field `{s}` expects `{s}`, got `{s}`", .{
                                                    self.interner.get(req_field.name),
                                                    self.typeToString(expected_type),
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
                                            if (te.name == type_name_id) {
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
                                                                if (psd.name.parts.len > 0) {
                                                                    const pn = psd.name.parts[0];
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
                            if (self.resolveFirstClassFunctionStructType()) |function_type_id| {
                                try self.validateStaticFunctionStructExpr(se, function_type_id);
                            }
                            // For a parametric instantiation
                            // `%Box(i64){...}` the literal's *type*
                            // is the applied form `Box(i64)`, not the
                            // bare declaration TypeId. Concrete
                            // structs keep returning the declaration
                            // TypeId so existing call-sites are
                            // unchanged.
                            return instantiation.literal_type_id;
                        }
                    }
                }
                // Infer field values even if type unknown
                for (se.fields) |field| {
                    _ = try self.inferExpr(field.value);
                }
                return TypeStore.UNKNOWN;
            },
            .range => |re| {
                _ = try self.inferExpr(re.start);
                _ = try self.inferExpr(re.end);
                if (re.step) |s| {
                    _ = try self.inferExpr(s);
                    // Validate step is positive at compile time
                    if (s.* == .int_literal) {
                        if (s.int_literal.value <= 0) {
                            try self.addHardError(
                                "range step must be a positive integer",
                                s.getMeta().span,
                                "step must be > 0",
                                "ranges use a positive step magnitude; the direction is determined by start vs end",
                            );
                        }
                    }
                }
                // Resolve to the `Range` struct type if it has been registered
                // by the collector. Like the `.map` branch above, returning
                // a real type (instead of UNKNOWN) lets call-site inference
                // propagate `Range` into helper params, which HIR's protocol
                // dispatch consults to route `Enumerable.next(state)` to
                // `Range.next(state)`.
                if (self.interner.lookupExisting("Range")) |range_name| {
                    if (self.store.name_to_type.get(range_name)) |tid| return tid;
                }
                return TypeStore.UNKNOWN;
            },
            .panic_expr => |pe| {
                _ = try self.inferExpr(pe.message);
                return TypeStore.NEVER;
            },
            .unwrap => TypeStore.UNKNOWN,
            .pipe => |pipe| {
                // Most pipes are rewritten to plain calls during macro
                // expansion, but pipes nested inside an `error_pipe` chain
                // are intentionally preserved up to HIR build time so
                // `flattenAstPipeChain` can identify each step. The type
                // checker still has to reason about them: `lhs |> rhs` is
                // semantically `f(lhs, args...)` when `rhs` is `f(args...)`.
                //
                // Treating the pipe as a synthetic call with the lhs
                // prepended routes resolution through `inferCall`, which
                // resolves the family at the correct arity (rhs.args.len + 1)
                // instead of mis-reporting the rhs as a zero-arg call.
                // For non-call rhs forms we fall back to walking children
                // so var_refs are still marked as referenced.
                if (pipe.rhs.* == .call) {
                    const inner = pipe.rhs.call;
                    var new_args = try self.allocator.alloc(*const ast.Expr, inner.args.len + 1);
                    new_args[0] = pipe.lhs;
                    for (inner.args, 0..) |arg, idx| new_args[idx + 1] = arg;
                    const synthetic = ast.CallExpr{
                        .meta = pipe.meta,
                        .callee = inner.callee,
                        .args = new_args,
                    };
                    return try self.inferCall(&synthetic);
                }
                if (pipe.rhs.* == .var_ref) {
                    // Bare `lhs |> f` — equivalent to `f(lhs)`.
                    const args = try self.allocator.alloc(*const ast.Expr, 1);
                    args[0] = pipe.lhs;
                    const synthetic = ast.CallExpr{
                        .meta = pipe.meta,
                        .callee = pipe.rhs,
                        .args = args,
                    };
                    return try self.inferCall(&synthetic);
                }
                _ = try self.inferExpr(pipe.lhs);
                _ = try self.inferExpr(pipe.rhs);
                return TypeStore.UNKNOWN;
            },
            .struct_ref => |mr| {
                if (try self.resolveTaggedUnionVariantReference(mr.name, mr.meta.span)) |type_id| {
                    return type_id;
                }
                if (try self.resolveTypeReferenceTarget(mr.name)) |_| {
                    return self.resolveFirstClassTypeStructType() orelse TypeStore.UNKNOWN;
                }
                try self.reportUnknownTypeReference(mr.name, mr.meta.span);
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
                if (self.arithmeticResultForTypeVarOperand(lhs, rhs)) |resolved| return resolved;
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
            // Membership test: returns Bool
            .in_op => TypeStore.BOOL,
        };
    }

    fn inferUnaryOp(self: *TypeChecker, uo: *const ast.UnaryOp) !TypeId {
        const operand_type = try self.inferExpr(uo.operand);
        return switch (uo.op) {
            .negate => operand_type,
            .not_op => TypeStore.BOOL,
        };
    }

    fn reportArgumentTypeMismatch(self: *TypeChecker, arg: *const ast.Expr, arg_index: usize, expected: TypeId, got: TypeId) !void {
        const expected_type = self.store.getType(expected);
        const got_type = self.store.getType(got);

        if (expected_type == .function) {
            const message = if (got_type == .function)
                try std.fmt.allocPrint(self.allocator, "argument {d} expects callable `{s}`, got callable `{s}`", .{ arg_index + 1, self.typeToString(expected), self.typeToString(got) })
            else
                try std.fmt.allocPrint(self.allocator, "argument {d} expects callable `{s}`, got `{s}`", .{ arg_index + 1, self.typeToString(expected), self.typeToString(got) });

            const help = if (arg.* == .anonymous_function)
                "change the anonymous function signature to match the expected callable type"
            else if (arg.* == .function_ref)
                "pass a function reference whose signature matches the expected callable type"
            else
                "pass a callable value whose signature matches the expected function type";

            try self.addRichError(
                message,
                arg.getMeta().span,
                "callable signature mismatch",
                help,
            );
            return;
        }

        try self.addRichError(
            try std.fmt.allocPrint(self.allocator, "argument {d} expects `{s}`, got `{s}`", .{ arg_index + 1, self.typeToString(expected), self.typeToString(got) }),
            arg.getMeta().span,
            "argument type mismatch",
            null,
        );
    }

    /// Check if a field_access chain roots at an atom_literal (`:zig` bridge call).
    /// Handles nested chains like :zig.Struct.func by traversing to the root.
    fn isZigBridgeCall(fa: ast.FieldAccess) bool {
        var obj = fa.object;
        while (true) {
            switch (obj.*) {
                .atom_literal => return true,
                .field_access => |inner_fa| obj = inner_fa.object,
                else => return false,
            }
        }
    }

    fn inferStaticFunctionCall(
        self: *TypeChecker,
        call: *const ast.CallExpr,
        struct_name: ?ast.StructName,
        function_name: ast.StringId,
        raw_arity: u32,
    ) !TypeId {
        const target = (try self.resolveFunctionReferenceTarget(
            struct_name,
            function_name,
            raw_arity,
            call.meta.span,
            true,
        )) orelse {
            for (call.args) |arg| _ = try self.inferExpr(arg);
            return TypeStore.UNKNOWN;
        };

        const family = self.graph.getFamily(target.family_id);
        if (family.clauses.items.len == 0) {
            for (call.args) |arg| _ = try self.inferExpr(arg);
            return TypeStore.UNKNOWN;
        }

        const signature = (try self.resolveClauseSignature(function_name, @intCast(call.args.len), target.declared_arity, family.clauses.items[0])) orelse {
            for (call.args) |arg| _ = try self.inferExpr(arg);
            return TypeStore.UNKNOWN;
        };

        for (call.args, 0..) |arg, idx| {
            const arg_type = try self.inferExpr(arg);
            if (idx < signature.params.len) {
                const expected = signature.params[idx];
                if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR and self.callMatchCost(arg_type, expected) == null) {
                    try self.reportArgumentTypeMismatch(arg, idx, expected, arg_type);
                }
            }
        }

        const borrowed = try self.applyCallOwnership(call.args, signature.toFunctionType());
        defer self.endBorrowedBindings(borrowed) catch {};
        return signature.return_type;
    }

    fn inferCall(self: *TypeChecker, call: *const ast.CallExpr) !TypeId {
        const arity: u32 = @intCast(call.args.len);

        if (call.callee.* == .function_ref) {
            const function_ref = call.callee.function_ref;
            return try self.inferStaticFunctionCall(call, function_ref.struct_name, function_ref.function, function_ref.arity);
        }

        if (call.callee.* == .struct_expr) {
            if (try self.staticFunctionStructValue(call.callee.struct_expr)) |function_value| {
                return try self.inferStaticFunctionCall(call, function_value.struct_name, function_value.function_name, function_value.arity);
            }
        }

        // Special handling for direct function calls (callee is var_ref)
        if (call.callee.* == .var_ref) {
            const vr = call.callee.var_ref;
            const func_name = self.interner.get(vr.name);

            if (self.isDisallowedUnderscoreFunctionCall(vr.name, vr.meta)) {
                try self.rejectUnderscoreCall(func_name, arity, call.meta.span);
                for (call.args) |arg| _ = try self.inferExpr(arg);
                return TypeStore.UNKNOWN;
            }

            if (self.current_scope) |scope_id| {
                // First check if it's a variable holding a function
                if (self.graph.resolveBindingHygienic(scope_id, vr.name, vr.meta.scopes)) |bid| {
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
                        if (self.isFirstClassFunctionStructType(prov.type_id)) {
                            try self.addHardError(
                                "dynamic Function dispatch is not supported",
                                call.meta.span,
                                "Function value stored in a variable",
                                "call a static function reference directly, for example `&Struct.name/arity(args...)`",
                            );
                            for (call.args) |arg| _ = try self.inferExpr(arg);
                            return TypeStore.UNKNOWN;
                        }
                    }
                }

                // Check function families. Candidate selection is type-aware:
                // exact typed clauses win first, then same-family numeric
                // widening is considered as a fallback.
                const arg_types = try self.inferCallArgTypes(call.args);
                if (try self.resolveFamilyCallSignature(scope_id, vr.name, arity, arg_types)) |resolved_call| {
                    const signature = resolved_call.signature;
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

                    // Infer types for generated helpers from call-site argument types.
                    // When a generated function has UNKNOWN param types, propagate the
                    // concrete argument types into an InferredSignature so the HIR builder
                    // can read them instead of falling back to UNKNOWN/NEVER.
                    var has_unknown_params = false;
                    for (signature.params) |p| {
                        if (p == TypeStore.UNKNOWN) {
                            has_unknown_params = true;
                            break;
                        }
                    }

                    if (has_unknown_params or signature.return_type == TypeStore.UNKNOWN) {
                        var inferred_params = try self.allocator.alloc(TypeId, signature.params.len);
                        for (call.args, 0..) |arg, idx| {
                            const arg_type = try self.inferExpr(arg);
                            if (idx < signature.params.len) {
                                inferred_params[idx] = if (signature.params[idx] == TypeStore.UNKNOWN)
                                    arg_type
                                else
                                    signature.params[idx];
                            }
                        }
                        // Infer return type from the param types: for list-processing
                        // helpers, the return type matches the parameter's list type.
                        const inferred_return = if (signature.return_type == TypeStore.UNKNOWN) blk: {
                            // If the first param is a list type, the return is likely a list too.
                            if (inferred_params.len > 0 and inferred_params[0] != TypeStore.UNKNOWN) {
                                const param_type = self.store.getType(inferred_params[0]);
                                if (param_type == .list) break :blk inferred_params[0];
                            }
                            break :blk signature.return_type;
                        } else signature.return_type;

                        // Only store the inferred signature if it has concrete (non-UNKNOWN)
                        // param types. Recursive calls within the helper body produce UNKNOWN
                        // args; the actual external call site produces concrete types.
                        var has_concrete = false;
                        for (inferred_params) |ip| {
                            if (ip != TypeStore.UNKNOWN and ip != TypeStore.ERROR) {
                                has_concrete = true;
                                break;
                            }
                        }
                        if (has_concrete) {
                            try self.store.inferred_signatures.put(vr.name, .{
                                .param_types = inferred_params,
                                .return_type = inferred_return,
                            });
                        }

                        // Eager helper resolution: when the call's return type
                        // is still UNKNOWN we cannot just trust that a later
                        // pass will fix `chars`'s recorded type — the binding
                        // is recorded against whatever type we return *now*.
                        // For synthetic helpers (e.g. for-comp `__for_N`) the
                        // body is fully self-contained and its parameter
                        // types have just been pinned via
                        // `inferred_signatures`. Type-check the helper's
                        // declaration immediately so the body fixpoint
                        // (see `checkFunctionClause`) runs and updates
                        // `inferred_signatures.return_type` to the body's
                        // type. We then read the refreshed signature back
                        // out and propagate that to the caller.
                        var resolved_return = inferred_return;
                        if (has_concrete and inferred_return == TypeStore.UNKNOWN and self.isSyntheticHelperName(vr.name)) {
                            if (!self.eager_helper_in_flight.contains(vr.name)) {
                                if (self.lookupFunctionDecl(scope_id, vr.name, arity)) |helper_decl| {
                                    try self.eager_helper_in_flight.put(vr.name, {});
                                    defer _ = self.eager_helper_in_flight.remove(vr.name);
                                    self.checkFunctionDecl(helper_decl) catch {};
                                    if (self.store.inferred_signatures.get(vr.name)) |refreshed| {
                                        resolved_return = refreshed.return_type;
                                    }
                                }
                            }
                        }

                        const borrowed = try self.applyCallOwnershipWithSafeParams(call.args, signature.toFunctionType(), safe_params);
                        defer self.endBorrowedBindings(borrowed) catch {};
                        return resolved_return;
                    }

                    // Check if the signature is generic (contains type variables)
                    var signature_is_generic = false;
                    for (signature.params) |param_type| {
                        if (self.store.containsTypeVars(param_type)) {
                            signature_is_generic = true;
                            break;
                        }
                    }
                    if (!signature_is_generic and self.store.containsTypeVars(signature.return_type)) {
                        signature_is_generic = true;
                    }

                    if (signature_is_generic) {
                        // Generic call: use unification to bind type variables
                        var subs = SubstitutionMap.init(self.allocator);
                        var unification_failed = false;

                        for (call.args, 0..) |arg, idx| {
                            const arg_type = try self.inferExpr(arg);
                            if (idx < signature.params.len) {
                                const expected = signature.params[idx];
                                if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR) {
                                    if (self.callMatchCost(arg_type, expected) == null) {
                                        try self.reportArgumentTypeMismatch(arg, idx, expected, arg_type);
                                        unification_failed = true;
                                        continue;
                                    }
                                    const unified = self.store.unify(expected, arg_type, &subs) catch false;
                                    if (!unified) {
                                        try self.reportArgumentTypeMismatch(arg, idx, expected, arg_type);
                                        unification_failed = true;
                                    }
                                }
                            }
                        }

                        // Apply substitutions to resolve the return type.
                        // Use the position-aware variant so type variables
                        // that were Term-constrained at container positions
                        // surface as `Term` in the return type even when
                        // they also picked up a concrete binding from a
                        // scalar argument (see `applyToReturnType` doc).
                        const resolved_return = if (!unification_failed)
                            subs.applyToReturnType(self.store, signature.return_type)
                        else
                            signature.return_type;

                        // Record the instantiation in the monomorphization registry
                        if (!unification_failed) {}

                        const borrowed = try self.applyCallOwnershipWithSafeParams(call.args, signature.toFunctionType(), safe_params);
                        defer self.endBorrowedBindings(borrowed) catch {};
                        return resolved_return;
                    }

                    // Monomorphic call: use existing typeEquals comparison
                    for (call.args, 0..) |arg, idx| {
                        const arg_type = try self.inferExpr(arg);
                        if (idx < signature.params.len) {
                            const expected = signature.params[idx];
                            if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR and self.callMatchCost(arg_type, expected) == null) {
                                try self.reportArgumentTypeMismatch(arg, idx, expected, arg_type);
                            }
                        }
                    }
                    const borrowed = try self.applyCallOwnershipWithSafeParams(call.args, signature.toFunctionType(), safe_params);
                    defer self.endBorrowedBindings(borrowed) catch {};
                    return signature.return_type;
                }

                // Function not found — suggest alternatives
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

        // Struct-qualified call: IO.puts(...) is a call with field_access callee
        if (call.callee.* == .field_access) {
            const fa = call.callee.field_access;
            const field_name = self.interner.get(fa.field);
            if (self.isDisallowedUnderscoreFunctionCall(fa.field, fa.meta)) {
                try self.rejectUnderscoreCall(field_name, arity, call.meta.span);
                for (call.args) |arg| _ = try self.inferExpr(arg);
                return TypeStore.UNKNOWN;
            }

            // :zig.func(args) or :zig.Struct.func(args) — bridge call;
            // infer args to mark bindings as used. Traverse field access chain
            // to find the root object (handles :zig.A.B.func nested chains).
            if (isZigBridgeCall(fa)) {
                for (call.args) |arg| {
                    _ = try self.inferExpr(arg);
                    // Mark any var_ref args as referenced directly
                    if (arg.* == .var_ref) {
                        if (self.current_scope) |scope_id| {
                            if (self.graph.resolveBindingHygienic(scope_id, arg.var_ref.name, arg.var_ref.meta.scopes)) |bid| {
                                self.referenced_bindings.put(bid, {}) catch {};
                            }
                        }
                    }
                }
                return TypeStore.UNKNOWN;
            }
            if (fa.object.* == .struct_ref) {
                const written_mod_name = fa.object.struct_ref.name;
                var mod_name = written_mod_name;
                if (call.args.len > 0) {
                    switch (try self.resolveProtocolDispatch(written_mod_name, call.args[0])) {
                        .not_protocol => {},
                        .concrete => |target| mod_name = target,
                        .constrained => {},
                        .invalid => {
                            try self.reportInvalidProtocolDispatch(written_mod_name, call.args[0]);
                            for (call.args) |arg| _ = try self.inferExpr(arg);
                            return TypeStore.UNKNOWN;
                        },
                    }
                } else if (self.graph.findProtocol(written_mod_name) != null) {
                    try self.addHardError(
                        "protocol dispatch requires at least one argument",
                        call.meta.span,
                        "missing protocol receiver argument",
                        null,
                    );
                    return TypeStore.UNKNOWN;
                }
                for (self.graph.structs.items) |mod_entry| {
                    if (mod_entry.name.parts.len == mod_name.parts.len) {
                        var match = true;
                        for (mod_entry.name.parts, mod_name.parts) |a, b| {
                            if (a != b and !std.mem.eql(u8, self.interner.get(a), self.interner.get(b))) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            const arg_types = try self.inferCallArgTypes(call.args);
                            if (try self.resolveFamilyCallSignature(mod_entry.scope_id, fa.field, arity, arg_types)) |resolved_call| {
                                const signature = resolved_call.signature;
                                // Check if the signature is generic (contains type variables)
                                var mod_sig_is_generic = false;
                                for (signature.params) |param_type| {
                                    if (self.store.containsTypeVars(param_type)) {
                                        mod_sig_is_generic = true;
                                        break;
                                    }
                                }
                                if (!mod_sig_is_generic and self.store.containsTypeVars(signature.return_type)) {
                                    mod_sig_is_generic = true;
                                }

                                if (mod_sig_is_generic) {
                                    // Generic call: use unification to bind type variables
                                    var mod_subs = SubstitutionMap.init(self.allocator);
                                    var mod_unification_failed = false;

                                    for (call.args, 0..) |arg, idx| {
                                        const arg_type = self.inferExpr(arg) catch TypeStore.UNKNOWN;
                                        if (idx < signature.params.len) {
                                            const expected = signature.params[idx];
                                            if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR) {
                                                if (self.callMatchCost(arg_type, expected) == null) {
                                                    self.reportArgumentTypeMismatch(arg, idx, expected, arg_type) catch {};
                                                    mod_unification_failed = true;
                                                    continue;
                                                }
                                                const unified = self.store.unify(expected, arg_type, &mod_subs) catch false;
                                                if (!unified) {
                                                    self.reportArgumentTypeMismatch(arg, idx, expected, arg_type) catch {};
                                                    mod_unification_failed = true;
                                                }
                                            }
                                        }
                                    }

                                    // Apply substitutions to resolve the return type.
                                    // See `applyToReturnType` for why we use
                                    // the position-aware variant rather than
                                    // plain `applyToType`.
                                    const mod_resolved_return = if (!mod_unification_failed)
                                        mod_subs.applyToReturnType(self.store, signature.return_type)
                                    else
                                        signature.return_type;

                                    return mod_resolved_return;
                                }

                                // Monomorphic call: check arguments but always return the
                                // declared return type. Per-argument inference errors must
                                // not prevent return type resolution — the return type is
                                // known from the function signature independently of whether
                                // all argument types can be fully inferred.
                                for (call.args, 0..) |arg, idx| {
                                    const arg_type = self.inferExpr(arg) catch TypeStore.UNKNOWN;
                                    if (idx < signature.params.len) {
                                        const expected = signature.params[idx];
                                        if (expected != TypeStore.UNKNOWN and arg_type != TypeStore.UNKNOWN and arg_type != TypeStore.ERROR and self.callMatchCost(arg_type, expected) == null) {
                                            self.reportArgumentTypeMismatch(arg, idx, expected, arg_type) catch {};
                                        }
                                    }
                                }
                                return signature.return_type;
                            }
                            break;
                        }
                    }
                }
                if (self.graph.findProtocol(mod_name) != null) {
                    for (call.args) |arg| _ = try self.inferExpr(arg);
                    return TypeStore.UNKNOWN;
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
            if (self.isFirstClassFunctionStructType(callee_type)) {
                try self.addHardError(
                    "dynamic Function dispatch is not supported",
                    call.meta.span,
                    "Function value is not statically callable here",
                    "call a direct function reference or a compile-time Function struct literal",
                );
                for (call.args) |arg| _ = try self.inferExpr(arg);
                return TypeStore.UNKNOWN;
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

                // Names already bound as type variables in this clause's
                // scope take precedence — covers both natural lowercase
                // type variables (`a`, `member`) AST-classified as
                // .variable and impl-declared parameters (e.g. `K`, `V`)
                // that the parser routed through .name. Pre-population
                // happens in checkFunctionClause when entering an impl.
                if (tn.args.len == 0) {
                    if (self.type_var_scope.get(name)) |existing| return existing;
                }

                // Built-in generic containers map onto the dedicated type
                // variants the rest of the pipeline already understands.
                // Mirrors the existing `[T]` and `%{K=>V}` sigils. Native
                // type identity comes from `@native_type` on the stdlib
                // struct (see `ScopeGraph.NativeTypeKind`); a user who
                // shadows `Map`/`List` with their own struct doesn't get
                // those sugar mappings.
                if (tn.args.len > 0) {
                    if (self.isNativeTypeName(.map, tn.name) and tn.args.len == 2) {
                        const key_t = try self.resolveTypeExpr(tn.args[0]);
                        const value_t = try self.resolveTypeExpr(tn.args[1]);
                        return try self.store.addType(.{ .map = .{ .key = key_t, .value = value_t } });
                    }
                    if (self.isNativeTypeName(.list, tn.name) and tn.args.len == 1) {
                        const elem_t = try self.resolveTypeExpr(tn.args[0]);
                        return try self.store.addType(.{ .list = .{ .element = elem_t } });
                    }
                }

                const resolved_builtin_or_meta = self.store.resolveTypeName(name);
                if (resolved_builtin_or_meta) |tid| {
                    if (tid != TypeStore.UNKNOWN) {
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
                }
                // Check user-defined types registered in TypeStore.
                // A parametric struct/union (e.g. `Box(T)`) accepts
                // generic application here: `Box(i64)` resolves to
                // `.applied { base = BoxStruct, args = [I64] }`.
                // Bare references like `Box` (no args) keep the
                // existing behavior — the type stays in declaration
                // form so monomorphisation can pick the specialisation
                // later.
                if (self.store.name_to_type.get(tn.name)) |tid| {
                    if (tn.args.len > 0) {
                        const formal_arity = self.parametricTypeArity(tid);
                        if (formal_arity == 0) {
                            try self.reportNonParametricInstantiation(name, tn.args.len, type_expr.getMeta().span);
                            return tid;
                        }
                        if (formal_arity != tn.args.len) {
                            try self.reportParametricArityMismatch(name, formal_arity, tn.args.len, type_expr.getMeta().span);
                            // Fall through and still build an applied
                            // type with whatever args the user wrote
                            // so downstream inference has something
                            // concrete to consume — the diagnostic
                            // already pins the mistake to the source.
                        }
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
                if (resolved_builtin_or_meta) |tid| {
                    return tid;
                }
                // Check user-defined types in scope graph (forward reference fallback)
                for (self.graph.types.items) |type_entry| {
                    const type_name = self.interner.get(type_entry.name);
                    if (std.mem.eql(u8, name, type_name)) {
                        return TypeStore.UNKNOWN; // Known user type, just can't resolve yet
                    }
                }

                // Check if this is a struct name — structs can be used as
                // types in impl declarations and type annotations. Any
                // struct name is accepted as a valid type reference. The
                // monomorphizer resolves the concrete type at specialization.
                for (self.graph.structs.items) |mod| {
                    if (mod.name.parts.len > 0) {
                        const mod_name = self.interner.get(mod.name.parts[mod.name.parts.len - 1]);
                        if (std.mem.eql(u8, name, mod_name)) {
                            return TypeStore.UNKNOWN;
                        }
                    }
                }

                // Check if this is a protocol name
                for (self.graph.protocols.items) |proto| {
                    if (proto.name.parts.len > 0 and self.structNameMatchesTypeName(proto.name, name)) {
                        // Protocol constraint — resolve type params and create constraint type
                        var type_params: std.ArrayList(TypeId) = .empty;
                        for (tn.args) |arg| {
                            type_params.append(self.allocator, try self.resolveTypeExpr(arg)) catch {};
                        }
                        return try self.store.addType(.{
                            .protocol_constraint = .{
                                .protocol_name = tn.name,
                                .type_params = type_params.toOwnedSlice(self.allocator) catch &.{},
                            },
                        });
                    }
                }

                // Unknown type — report error with suggestions
                var candidates: std.ArrayList([]const u8) = .empty;
                // Collect builtin type names
                const builtins = [_][]const u8{
                    "Bool",  "String", "Atom", "Nil", "Never",
                    "i128",  "i64",    "i32",  "i16", "i8",
                    "u128",  "u64",    "u32",  "u16", "u8",
                    "f128",  "f80",    "f64",  "f32", "f16",
                    "usize", "isize",
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
                if (self.store.resolveTypeName(var_name)) |tid| {
                    return tid;
                }

                const builtins = [_][]const u8{
                    "Bool",  "String", "Atom", "Nil", "Never",
                    "i128",  "i64",    "i32",  "i16", "i8",
                    "u128",  "u64",    "u32",  "u16", "u8",
                    "f128",  "f80",    "f64",  "f32", "f16",
                    "usize", "isize",
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

                // Check if this type variable was already introduced in the current function scope.
                // This ensures that `a` used in two places within the same function signature
                // (e.g., `fn identity(x :: a) -> a`) refers to the same type variable.
                if (self.type_var_scope.get(var_name)) |existing_type_id| {
                    return existing_type_id;
                }

                // First occurrence in this function clause — create a fresh type variable
                // and record it so subsequent uses of the same name resolve to the same type.
                const fresh_type_id = try self.store.freshVar();
                try self.type_var_scope.put(var_name, fresh_type_id);
                return fresh_type_id;
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
            .map => |mt| {
                // `%{K -> V, ...}` map type literal. We use the first
                // field's key/value to determine the homogeneous K and V
                // (the canonical convention — the parser allows multiple
                // K -> V entries syntactically, but downstream code
                // assumes a single Map(K, V) type). Without this
                // resolution, parameter destructuring patterns like
                // `pub fn f(%{name: n} :: %{Atom -> String})` lose `n`'s
                // String type, breaking first-arg-driven protocol
                // dispatch (`Concatenable.concat`, `Arithmetic.+`, …).
                if (mt.fields.len == 0) {
                    const key_var = try self.store.freshVar();
                    const value_var = try self.store.freshVar();
                    return try self.store.addType(.{ .map = .{ .key = key_var, .value = value_var } });
                }
                const key_t = try self.resolveTypeExpr(mt.fields[0].key);
                const value_t = try self.resolveTypeExpr(mt.fields[0].value);
                return try self.store.addType(.{ .map = .{ .key = key_t, .value = value_t } });
            },
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
    try std.testing.expect(store.getType(TypeStore.I128) == .int);
    try std.testing.expect(store.getType(TypeStore.U128) == .int);
    try std.testing.expect(store.getType(TypeStore.F64) == .float);
    try std.testing.expect(store.getType(TypeStore.F80) == .float);
    try std.testing.expect(store.getType(TypeStore.F128) == .float);
    try std.testing.expect(store.getType(TypeStore.NEVER) == .never);
}

test "type store builtin types stop before removed nominal aliases" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expectEqual(TypeStore.F128 + 1, store.types.items.len);
}

test "type store resolve builtin names" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expectEqual(TypeStore.I64, store.resolveTypeName("i64").?);
    try std.testing.expectEqual(TypeStore.I128, store.resolveTypeName("i128").?);
    try std.testing.expectEqual(TypeStore.U128, store.resolveTypeName("u128").?);
    try std.testing.expectEqual(TypeStore.F80, store.resolveTypeName("f80").?);
    try std.testing.expectEqual(TypeStore.F128, store.resolveTypeName("f128").?);
    try std.testing.expectEqual(TypeStore.BOOL, store.resolveTypeName("Bool").?);
    try std.testing.expectEqual(TypeStore.STRING, store.resolveTypeName("String").?);
    try std.testing.expect(store.resolveTypeName("Nonexistent") == null);
}

test "type store represents numeric lists structurally" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const i64_list = try store.addType(.{ .list = .{ .element = TypeStore.I64 } });
    const f64_list = try store.addType(.{ .list = .{ .element = TypeStore.F64 } });

    try std.testing.expect(store.getType(i64_list) == .list);
    try std.testing.expectEqual(TypeStore.I64, store.getType(i64_list).list.element);
    try std.testing.expect(store.getType(f64_list) == .list);
    try std.testing.expectEqual(TypeStore.F64, store.getType(f64_list).list.element);
}

test "typeToString renders tuple element types" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    var graph = scope_mod.ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    var checker = TypeChecker.initWithSharedStore(std.testing.allocator, &store, &interner, &graph);
    defer checker.deinit();

    const elements = try std.testing.allocator.dupe(TypeId, &.{ TypeStore.I64, TypeStore.STRING, TypeStore.BOOL });
    defer std.testing.allocator.free(elements);
    const tuple_type = try store.addType(.{ .tuple = .{ .elements = elements } });

    const rendered = checker.typeToString(tuple_type);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("{i64, String, Bool}", rendered);
}

fn rerunWithEscapeAnalysis(
    alloc: std.mem.Allocator,
    interner: *ast.StringInterner,
    graph: *scope_mod.ScopeGraph,
    checker: *TypeChecker,
    program: *const ast.Program,
) !void {
    var hir_builder = @import("hir.zig").HirBuilder.init(alloc, interner, graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(program);

    var ir_builder = @import("ir.zig").IrBuilder.init(alloc, interner);
    ir_builder.type_store = checker.store;
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
        \\pub struct Test {
        \\  opaque Handle = String
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
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
const MacroEngine = @import("macro.zig").MacroEngine;

test "macro-generated block scopes are attached to block metadata" {
    const source =
        \\pub struct TestDsl {
        \\  pub macro make_test(name :: Expr, body :: Expr) -> Expr {
        \\    function_name = intern_atom("generated_" <> name)
        \\    quote {
        \\      pub fn unquote(function_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub macro capture(expr :: Expr) -> Expr {
        \\    quote {
        \\      value = unquote(expr)
        \\      value
        \\    }
        \\  }
        \\}
        \\
        \\pub struct First {
        \\  import TestDsl
        \\
        \\  make_test("one") {
        \\    capture(helper())
        \\  }
        \\
        \\  fn helper() -> i64 {
        \\    1
        \\  }
        \\}
        \\
        \\pub struct Second {
        \\  import TestDsl
        \\
        \\  make_test("two") {
        \\    capture(2)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var macro_engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer macro_engine.deinit();
    const expanded = try macro_engine.expandProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), macro_engine.errors.items.len);

    var expanded_collector = Collector.init(alloc, parser.interner, null);
    defer expanded_collector.deinit();
    try expanded_collector.collectProgram(&expanded);

    var checker = TypeChecker.init(alloc, parser.interner, &expanded_collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&expanded);

    for (checker.errors.items) |err| {
        std.debug.print("Unexpected type error: {s}\n", .{err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check simple function" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    var hir_builder = @import("hir.zig").HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);
    var ir_builder = @import("ir.zig").IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);
    var pipeline_result = try @import("analysis_pipeline.zig").runAnalysisPipeline(alloc, &ir_program);
    defer pipeline_result.deinit();
    checker.setAnalysisContext(&pipeline_result.context, &ir_program);
    checker.errors.clearRetainingCapacity();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "uninhabited recursive type emits friendly diagnostic" {
    // Self-recursion with no nil-escape: every Tree requires two
    // more Trees, infinite recursion at construction. The checker
    // must surface a clear "no finite base case" error before any
    // downstream pass reaches Zig's late "infinite size" message.
    const source =
        \\pub struct Bad {
        \\  pub struct Tree {
        \\    value :: i64
        \\    left :: Tree
        \\    right :: Tree
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var saw_uninhabited = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "no finite base case") != null) {
            saw_uninhabited = true;
            break;
        }
    }
    try std.testing.expect(saw_uninhabited);
}

test "habitable recursive type compiles cleanly" {
    // Same shape as the diagnostic test but with a `Tree | nil`
    // escape on each cycle field. The checker must NOT flag this:
    // `nil` is a finite base case.
    const source =
        \\pub struct Good {
        \\  pub struct Tree {
        \\    value :: i64
        \\    left :: Tree | nil
        \\    right :: Tree | nil
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "no finite base case") == null);
    }
}

test "mutual recursion with no escape diagnoses both structs" {
    // A → B → A with both edges required. Every CycleA needs a
    // CycleB and every CycleB needs a CycleA, so neither type has
    // a finite constructor. Both should be flagged.
    const source =
        \\pub struct Bad {
        \\  pub struct CycleA {
        \\    tag :: i64
        \\    partner :: CycleB
        \\  }
        \\
        \\  pub struct CycleB {
        \\    weight :: i64
        \\    back :: CycleA
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var saw_a = false;
    var saw_b = false;
    for (checker.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "no finite base case") == null) continue;
        if (std.mem.indexOf(u8, err.message, "CycleA") != null) saw_a = true;
        if (std.mem.indexOf(u8, err.message, "CycleB") != null) saw_b = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "type check literals" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check case expression" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
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
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    // Should report arithmetic type mismatch
    const err_msg = checker.errors.items[0].message;
    try std.testing.expect(std.mem.find(u8, err_msg, "arithmetic") != null or std.mem.find(u8, err_msg, "cannot perform") != null);
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
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
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
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err_msg = checker.errors.items[0].message;
    // New contextual message mentions the actual type and if requirement
    try std.testing.expect(std.mem.find(u8, err_msg, "but `if` requires a `Bool`") != null);
}

test "type check generic impl resolves Map(K, V) to map type" {
    // Verify that an `impl Enumerable for Map(K, V)` block type-checks
    // without "unknown type K/V" errors — Phase 2 plumbing only. Body
    // references `:zig.Map.next` which is a builtin call (no type-check
    // pass on its body); we're confirming the *signature* resolves.
    const source =
        \\pub protocol Enumerable {
        \\  fn next(state) -> {Atom, any, any}
        \\}
        \\
        \\pub impl Enumerable for Map(K, V) {
        \\  pub fn next(map :: Map(K, V)) -> Map(K, V) {
        \\    map
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // No "I cannot find a type named `K`" or `V` errors should fire.
    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "I cannot find a type named `K`") == null);
        try std.testing.expect(std.mem.find(u8, err.message, "I cannot find a type named `V`") == null);
    }
}

test "protocol dispatch rejects unconstrained type variable receiver" {
    const source =
        \\pub protocol Enumerable {
        \\  fn next(state) -> {Atom, any, any}
        \\}
        \\
        \\pub struct Test {
        \\  pub fn bad(collection :: enumerable) -> i64 {
        \\    case Enumerable.next(collection) {
        \\      {:done, _, _} -> 0
        \\      {:cont, value, _} -> value
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "first argument to protocol `Enumerable` does not satisfy `Enumerable`") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "protocol dispatch accepts exact protocol constraint receiver" {
    const source =
        \\pub protocol Enumerable {
        \\  fn next(state) -> {Atom, any, any}
        \\}
        \\
        \\pub struct Test {
        \\  pub fn first(collection :: Enumerable) -> i64 {
        \\    case Enumerable.next(collection) {
        \\      {:done, _, _} -> 0
        \\      {:cont, value, _} -> value
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "protocol parameter rejects unconstrained type variable argument" {
    const source =
        \\pub protocol Enumerable {
        \\  fn next(state) -> {Atom, any, any}
        \\}
        \\
        \\pub struct Enum {
        \\  pub fn to_list(collection :: Enumerable) -> [i64] {
        \\    []
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub fn bad(collection :: enumerable) -> [i64] {
        \\    Enum.to_list(collection)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "argument 1 expects `Enumerable`") != null) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "type check return type mismatch" {
    // Function declares i64 return but body returns a string
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err_msg = checker.errors.items[0].message;
    try std.testing.expect(std.mem.find(u8, err_msg, "returns the wrong type") != null);
    // Rich label should contain the expected/got info
    const err_label = checker.errors.items[0].label orelse "";
    try std.testing.expect(std.mem.find(u8, err_label, "i64") != null);
    try std.testing.expect(std.mem.find(u8, err_label, "String") != null);
}

test "type check top-level main rejects non-exit-code return type" {
    const source =
        \\fn main(_args :: [String]) -> String {
        \\  "not an exit code"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.initScript(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "main/1") != null and
            std.mem.find(u8, err.message, "u8") != null and
            std.mem.find(u8, err.message, "String") != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "type check top-level main rejects non-u8 integer return type" {
    const source =
        \\fn main(_args :: [String]) -> i64 {
        \\  1
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.initScript(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "main/1") != null and
            std.mem.find(u8, err.message, "u8") != null and
            std.mem.find(u8, err.message, "i64") != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "type check top-level main rejects Nil return type" {
    const source =
        \\fn main(_args :: [String]) -> Nil {
        \\  nil
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.initScript(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "main/1") != null and
            std.mem.find(u8, err.message, "u8") != null and
            std.mem.find(u8, err.message, "Nil") != null)
        {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "type check top-level main accepts unannotated integer literal return for u8" {
    const source =
        \\fn main(_args :: [String]) -> u8 {
        \\  13
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.initScript(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "main/1") == null);
        try std.testing.expect(std.mem.find(u8, err.message, "wrong type") == null);
    }
}

test "type check top-level main accepts if branches with unannotated u8 literals" {
    const source =
        \\fn main(_args :: [String]) -> u8 {
        \\  if true {
        \\    0
        \\  } else {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.initScript(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "wrong type") == null);
    }
}

test "type provenance tracks source span on typed parameter" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
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
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
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

test "function ref inference returns first-class Function value" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Function {
        \\    &Test.main/1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const main_func = program.structs[2].items[0].function;
    const fn_ref_expr = main_func.clauses[0].body.?[0].expr;
    const inferred = try checker.inferExpr(fn_ref_expr);
    const function_name = parser.interner.lookupExisting("Function") orelse return error.TestUnexpectedResult;
    const function_type = checker.store.name_to_type.get(function_name) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(function_type, inferred);
}

test "direct local function ref call resolves function scope before struct scope" {
    const source =
        \\pub struct Test {
        \\  pub fn outer(base :: i64) -> i64 {
        \\    pub fn add_base(x :: i64) -> i64 {
        \\      base + x
        \\    }
        \\
        \\    &add_base/1(10)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "bare struct reference infers first-class Type value" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Arena {
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Type {
        \\    Arena
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const main_func = program.structs[2].items[0].function;
    const type_ref_expr = main_func.clauses[0].body.?[0].expr;
    const inferred = try checker.inferExpr(type_ref_expr);
    const type_name = parser.interner.lookupExisting("Type") orelse return error.TestUnexpectedResult;
    const type_type = checker.store.name_to_type.get(type_name) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(type_type, inferred);
}

test "dotted bare struct reference infers first-class Type value" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Arena.Other {
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Type {
        \\    Arena.Other
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const main_func = program.structs[2].items[0].function;
    const type_ref_expr = main_func.clauses[0].body.?[0].expr;
    const inferred = try checker.inferExpr(type_ref_expr);
    const type_name = parser.interner.lookupExisting("Type") orelse return error.TestUnexpectedResult;
    const type_type = checker.store.name_to_type.get(type_name) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(type_type, inferred);
}

test "dotted tagged union variant infers union value before type reference fallback" {
    const source =
        \\pub union IO.Mode {
        \\  Raw,
        \\  Normal
        \\}
        \\
        \\pub struct Test {
        \\  pub fn direct() -> IO.Mode {
        \\    IO.Mode.Normal
        \\  }
        \\
        \\  pub fn bridge() -> IO.Mode {
        \\    :zig.IO.set_terminal_mode(IO.Mode.Normal)
        \\    IO.Mode.Raw
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "dotted tagged union variant validates final segment as variant" {
    const source =
        \\pub union IO.Mode {
        \\  Raw
        \\}
        \\
        \\pub struct Test {
        \\  pub fn direct() -> IO.Mode {
        \\    IO.Mode.Normal
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "`Normal` is not a variant of enum `IO.Mode`") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "unknown bare struct reference is a type error" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Type {
        \\    Missing
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "I cannot find a type named `Missing`") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "cross-struct function references require public target" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Other {
        \\  fn hidden(args :: Nil) -> Nil {
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Function {
        \\    &Other.hidden/1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "`Other.hidden/1` is private") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "function reference arity narrows to u8 before validation" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Other {
        \\  pub fn target(a :: Nil) -> Nil {
        \\    nil
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Function {
        \\    &Other.target/300
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "Other.target/44") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "static manual Function struct validates target and accepts narrowed arity field" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main(args :: Nil) -> Function {
        \\    %Function{struct: Test, name: :main, arity: 257}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "calling Function stored in a variable is rejected as dynamic dispatch" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn target(args :: Nil) -> Nil {
        \\    nil
        \\  }
        \\
        \\  pub fn main(args :: Nil) -> Nil {
        \\    function = &Test.target/1
        \\    function(nil)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "dynamic Function dispatch is not supported") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "anonymous closure with borrowed capture cannot escape via assignment" {
    const source =
        \\pub struct Test {
        \\  pub fn run(x :: borrowed String) -> Nil {
        \\    f = fn() -> String {
        \\      x
        \\    }
        \\    nil
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const decl = program.structs[0].items[0].function.clauses[0].body.?[0].assignment.value.anonymous_function.decl;
    try std.testing.expect(checker.functionDeclCapturesBorrowed(decl));

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "closure with borrowed captures cannot escape via assignment") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "anonymous closure with borrowed capture cannot escape through return" {
    const source =
        \\pub struct Test {
        \\  pub fn run(x :: borrowed String) -> (String -> String) {
        \\    fn(y :: String) -> String {
        \\      x <> y
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const expr = program.structs[0].items[0].function.clauses[0].body.?[0].expr;
    try std.testing.expect(checker.functionDeclCapturesBorrowed(expr.anonymous_function.decl));

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "closure with borrowed captures cannot escape through return") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "anonymous closure missing parameter annotation has closure-specific diagnostic" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> (i64 -> i64) {
        \\    fn(x) -> i64 {
        \\      x + 1
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "anonymous function parameter requires a type annotation") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "anonymous closure missing return annotation has closure-specific diagnostic" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> (i64 -> i64) {
        \\    fn(x :: i64) {
        \\      x + 1
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "anonymous function is missing a return type annotation") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "higher-order call reports callable signature mismatch for anonymous closure" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (i64 -> i64)) -> i64 {
        \\    f(41)
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    apply(fn(x :: String) -> String {
        \\      x
        \\    })
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "expects callable") != null and err.label != null and std.mem.find(u8, err.label.?, "callable signature mismatch") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "higher-order call reports callable signature mismatch for function ref" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn pair_sum(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\
        \\  pub fn apply(f :: (i64 -> i64)) -> i64 {
        \\    f(41)
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    apply(&pair_sum/2)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "expects callable") != null and err.label != null and std.mem.find(u8, err.label.?, "callable signature mismatch") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "moved binding use reports ownership error" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.structs[0].items[0].function.clauses[0];
    const expr = clause.body.?[0].expr;
    const scope_id = checker.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
    checker.current_scope = scope_id;

    const x_binding = checker.graph.resolveBinding(scope_id, clause.params[0].pattern.bind.name).?;
    try checker.recordBindingOwnership(x_binding, TypeStore.STRING, .unique);
    try checker.markBindingMoved(x_binding);

    _ = try checker.inferExpr(expr);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "already moved") != null) {
            found = true;
            try std.testing.expect(err.help != null);
        }
    }
    try std.testing.expect(found);
}

test "unique function parameter ownership moves var_ref argument" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.structs[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
        if (std.mem.find(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "shared binding cannot satisfy unique parameter ownership" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.structs[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
        if (std.mem.find(u8, err.message, "cannot pass shared value") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "named call with unique parameter moves opaque binding" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "borrowed param annotation keeps binding usable after call" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "borrowed value cannot escape through return" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot escape through return") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be returned" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "borrowed captures") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "unique capture moves outer binding" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "already moved") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be passed as argument" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot be passed as an argument") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be assigned" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "assignment") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture cannot be stored in tuple" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try rerunWithEscapeAnalysis(alloc, parser.interner, &collector.graph, &checker, &program);

    var found = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "tuple storage") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "closure with borrowed capture may be locally invoked" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "closure with borrowed capture may be passed to known-safe callee" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "borrowed parameter does not move binding" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const clause = program.structs[0].items[0].function.clauses[0];
    const scope_id = checker.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expect(checker.errors.items.len > 0);
    const err = checker.errors.items[0];
    try std.testing.expect(err.secondary_spans.len > 0);
    const ss_label = err.secondary_spans[0].label;
    try std.testing.expect(std.mem.find(u8, ss_label, "return type") != null);
    try std.testing.expect(std.mem.find(u8, ss_label, "i64") != null);
}

test "undefined function suggests similar name" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have exactly one error about "fob/2" not found
    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "fob/2") != null) {
            found_err = true;
            // Should suggest foo/2
            if (err.help) |help| {
                try std.testing.expect(std.mem.find(u8, help, "foo/2") != null);
            }
        }
    }
    try std.testing.expect(found_err);
}

test "undefined function no suggestion for unrelated name" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have error but no suggestion
    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "zzzzz/1") != null) {
            found_err = true;
            try std.testing.expect(err.help == null);
        }
    }
    try std.testing.expect(found_err);
}

test "valid function call produces no error" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // No "cannot find function" errors
    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "cannot find a function") == null);
    }
}

test "unused variable produces warning" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    var found_unused = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "variable `x` is unused") != null) {
            found_unused = true;
            try std.testing.expect(err.help != null);
            try std.testing.expect(std.mem.find(u8, err.help.?, "_x") != null);
        }
    }
    try std.testing.expect(found_unused);
}

test "underscore-prefixed variable no unused warning" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "_x") == null);
    }
}

test "direct call to underscore-prefixed bare function is rejected" {
    const source =
        \\pub struct Test {
        \\  pub fn caller() -> i64 {
        \\    _helper()
        \\  }
        \\
        \\  fn _helper() -> i64 {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_error = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_helper/0`") != null) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "direct source call to compiler helper-shaped underscore function is rejected" {
    const source =
        \\pub struct Test {
        \\  pub fn caller() -> i64 {
        \\    __for_0()
        \\  }
        \\
        \\  fn __for_0() -> i64 {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_error = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `__for_0/0`") != null) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "direct call to underscore-prefixed qualified function is rejected" {
    const source =
        \\pub struct Helper {
        \\  pub fn _hidden() -> i64 {
        \\    42
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub fn caller() -> i64 {
        \\    Helper._hidden()
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_error = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_hidden/0`") != null) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "direct call to underscore-prefixed function inside macro body is rejected" {
    const source =
        \\pub struct Test {
        \\  pub macro emit() -> Expr {
        \\    _helper()
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_error = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_helper/0`") != null) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "direct call to underscore-prefixed qualified function inside macro body is rejected" {
    const source =
        \\pub struct Test {
        \\  pub macro emit() -> Expr {
        \\    Helper._hidden()
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_error = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_hidden/0`") != null) {
            found_error = true;
        }
    }
    try std.testing.expect(found_error);
}

test "used variable no unused warning" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "variable `x` is unused") == null);
    }
}

test "variable used in zig intrinsic call is not unused" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var desugarer = @import("desugar.zig").Desugarer.init(alloc, parser.interner, null);
    const desugared = try desugarer.desugarProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&desugared);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "variable `name` is unused") == null);
    }
}

test "unknown type name produces error" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_err = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot find a type named `Other`") != null) {
            found_err = true;
        }
    }
    try std.testing.expect(found_err);
}

test "unused function parameter produces warning" {
    const source =
        \\pub struct Test {
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    var found_unused = false;
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "variable `x` is unused") != null) {
            found_unused = true;
        }
    }
    try std.testing.expect(found_unused);
}

test "zig bridge call parameters not flagged as unused" {
    // Regression: :zig.Struct.func(param) calls should mark parameters as used.
    // Previously, the scope collector created duplicate binding IDs for function
    // parameters, and the :zig bridge call resolved to the duplicate — leaving
    // the original parameter binding appearing unused.
    const source =
        \\pub struct Test {
        \\  pub fn get(map :: i64, key :: i64) -> i64 {
        \\    :zig.Integer.add(map, key)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    // No unused variable warnings should be emitted for map or key
    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "is unused") != null) {
            std.debug.print("Unexpected unused warning: {s}\n", .{err.message});
            return error.TestUnexpectedResult;
        }
    }
}

test "nested zig bridge call parameters not flagged as unused" {
    // Regression: :zig.A.B.func(param) nested bridge calls should also work.
    const source =
        \\pub struct Test {
        \\  pub fn read(path :: i64) -> i64 {
        \\    :zig.Map.get(path)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "is unused") != null) {
            std.debug.print("Unexpected unused warning: {s}\n", .{err.message});
            return error.TestUnexpectedResult;
        }
    }
}

test "macro body let-binding referenced via unquote is not unused" {
    // Regression: a let-binding inside a macro body that is referenced
    // only via `unquote(name)` inside a `quote { ... }` template was
    // flagged as "variable `name` is unused". The unused-binding check
    // never recurses into quote bodies (they're compile-time templates,
    // not type-checked) and so cannot observe references through
    // unquote. Macro-body bindings must be treated as referenced
    // unconditionally because the macro engine evaluates them at
    // compile time.
    const source =
        \\pub struct Test {
        \\  pub macro define_test(name :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 { 42 }
        \\      unquote(fn_name)()
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "variable `fn_name` is unused") != null) {
            std.debug.print("Unexpected unused warning: {s}\n", .{err.message});
            return error.TestUnexpectedResult;
        }
    }
}

test "macro body nested-block let-binding referenced via unquote is not unused" {
    // The same rule applies to bindings introduced in nested
    // constructs inside the macro body — `if`, `case`, `for`, and
    // explicit blocks each create their own child scopes whose
    // bindings are still part of the macro's compile-time evaluation.
    const source =
        \\pub struct Test {
        \\  pub macro define_named(name :: Expr) -> Expr {
        \\    if true {
        \\      fn_name = intern_atom("inner_" <> slugify(name))
        \\      quote {
        \\        pub fn unquote(fn_name)() -> i64 { 7 }
        \\        unquote(fn_name)()
        \\      }
        \\    } else {
        \\      quote { 0 }
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        if (std.mem.find(u8, err.message, "variable `fn_name` is unused") != null) {
            std.debug.print("Unexpected unused warning: {s}\n", .{err.message});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================
// Type unification tests
// ============================================================

test "unify identical primitives succeeds with empty subs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // i64 unifies with i64
    const result = try store.unify(TypeStore.I64, TypeStore.I64, &subs);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(u32, 0), subs.bindings.count());
}

test "unify type_var with i64 succeeds and binds var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create type_var(0)
    const var_type = try store.freshVar();
    _ = var_type;

    const result = try store.unify(try store.addType(.{ .type_var = 0 }), TypeStore.I64, &subs);
    try std.testing.expect(result);
    // Var 0 should be bound to i64
    try std.testing.expectEqual(TypeStore.I64, subs.resolve(0).?);
}

test "unify list of type_var with list of i64 binds var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create [type_var(0)]
    const var_type = try store.freshVar();
    const list_of_var = try store.addType(.{ .list = .{ .element = var_type } });

    // Create [i64]
    const list_of_i64 = try store.addType(.{ .list = .{ .element = TypeStore.I64 } });

    const result = try store.unify(list_of_var, list_of_i64, &subs);
    try std.testing.expect(result);
    // Var 0 should be bound to i64
    try std.testing.expectEqual(TypeStore.I64, subs.resolve(0).?);
}

test "unify function type_vars with concrete types binds both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create (type_var(0) -> type_var(1))
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();
    const param_types = try alloc.alloc(TypeId, 1);
    param_types[0] = var0;
    const generic_fn = try store.addType(.{ .function = .{
        .params = param_types,
        .return_type = var1,
    } });

    // Create (i64 -> String)
    const concrete_params = try alloc.alloc(TypeId, 1);
    concrete_params[0] = TypeStore.I64;
    const concrete_fn = try store.addType(.{ .function = .{
        .params = concrete_params,
        .return_type = TypeStore.STRING,
    } });

    const result = try store.unify(generic_fn, concrete_fn, &subs);
    try std.testing.expect(result);
    // Var 0 should be bound to i64
    try std.testing.expectEqual(TypeStore.I64, subs.resolve(0).?);
    // Var 1 should be bound to String
    try std.testing.expectEqual(TypeStore.STRING, subs.resolve(1).?);
}

test "unify incompatible primitives fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // i64 does not unify with String
    const result = try store.unify(TypeStore.I64, TypeStore.STRING, &subs);
    try std.testing.expect(!result);
}

test "unify list of i64 with list of String fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    const list_of_i64 = try store.addType(.{ .list = .{ .element = TypeStore.I64 } });
    const list_of_string = try store.addType(.{ .list = .{ .element = TypeStore.STRING } });

    const result = try store.unify(list_of_i64, list_of_string, &subs);
    try std.testing.expect(!result);
}

test "applyToType substitutes type_var in list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create [type_var(0)]
    const var_type = try store.freshVar();
    const list_of_var = try store.addType(.{ .list = .{ .element = var_type } });

    // Bind var 0 -> i64
    subs.bind(0, TypeStore.I64);

    // Apply substitution: [type_var(0)] should become [i64]
    const result_type_id = subs.applyToType(&store, list_of_var);
    const result_type = store.getType(result_type_id);
    try std.testing.expect(result_type == .list);
    try std.testing.expectEqual(TypeStore.I64, result_type.list.element);
}

test "applyToType substitutes type_vars in tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create {type_var(0), type_var(1)}
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();
    const elements = try alloc.alloc(TypeId, 2);
    elements[0] = var0;
    elements[1] = var1;
    const tuple_type = try store.addType(.{ .tuple = .{ .elements = elements } });

    // Bind var 0 -> i64, var 1 -> String
    subs.bind(0, TypeStore.I64);
    subs.bind(1, TypeStore.STRING);

    // Apply substitution
    const result_type_id = subs.applyToType(&store, tuple_type);
    const result_type = store.getType(result_type_id);
    try std.testing.expect(result_type == .tuple);
    try std.testing.expectEqual(@as(usize, 2), result_type.tuple.elements.len);
    try std.testing.expectEqual(TypeStore.I64, result_type.tuple.elements[0]);
    try std.testing.expectEqual(TypeStore.STRING, result_type.tuple.elements[1]);
}

test "applyToType substitutes type_vars in function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create (type_var(0) -> type_var(1))
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();
    const param_types = try alloc.alloc(TypeId, 1);
    param_types[0] = var0;
    const fn_type = try store.addType(.{ .function = .{
        .params = param_types,
        .return_type = var1,
    } });

    // Bind var 0 -> i64, var 1 -> Bool
    subs.bind(0, TypeStore.I64);
    subs.bind(1, TypeStore.BOOL);

    // Apply substitution
    const result_type_id = subs.applyToType(&store, fn_type);
    const result_type = store.getType(result_type_id);
    try std.testing.expect(result_type == .function);
    try std.testing.expectEqual(@as(usize, 1), result_type.function.params.len);
    try std.testing.expectEqual(TypeStore.I64, result_type.function.params[0]);
    try std.testing.expectEqual(TypeStore.BOOL, result_type.function.return_type);
}

test "applyToType substitutes type_vars in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create Map(type_var(0), type_var(1))
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();
    const map_type = try store.addType(.{ .map = .{ .key = var0, .value = var1 } });

    // Bind var 0 -> String, var 1 -> i64
    subs.bind(0, TypeStore.STRING);
    subs.bind(1, TypeStore.I64);

    // Apply substitution
    const result_type_id = subs.applyToType(&store, map_type);
    const result_type = store.getType(result_type_id);
    try std.testing.expect(result_type == .map);
    try std.testing.expectEqual(TypeStore.STRING, result_type.map.key);
    try std.testing.expectEqual(TypeStore.I64, result_type.map.value);
}

test "occurs check prevents infinite types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create type_var(0) and [type_var(0)]
    const var_type = try store.freshVar();
    const list_of_var = try store.addType(.{ .list = .{ .element = var_type } });

    // Trying to unify type_var(0) with [type_var(0)] should fail (occurs check)
    const result = try store.unify(var_type, list_of_var, &subs);
    try std.testing.expect(!result);
}

test "unify with UNKNOWN always succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // UNKNOWN unifies with i64
    try std.testing.expect(try store.unify(TypeStore.UNKNOWN, TypeStore.I64, &subs));
    // i64 unifies with UNKNOWN
    try std.testing.expect(try store.unify(TypeStore.I64, TypeStore.UNKNOWN, &subs));
}

test "unify tuples of different lengths fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    const elems2 = try alloc.alloc(TypeId, 2);
    elems2[0] = TypeStore.I64;
    elems2[1] = TypeStore.STRING;
    const tuple2 = try store.addType(.{ .tuple = .{ .elements = elems2 } });

    const elems3 = try alloc.alloc(TypeId, 3);
    elems3[0] = TypeStore.I64;
    elems3[1] = TypeStore.STRING;
    elems3[2] = TypeStore.BOOL;
    const tuple3 = try store.addType(.{ .tuple = .{ .elements = elems3 } });

    const result = try store.unify(tuple2, tuple3, &subs);
    try std.testing.expect(!result);
}

test "unify functions of different arity fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    const params1 = try alloc.alloc(TypeId, 1);
    params1[0] = TypeStore.I64;
    const fn1 = try store.addType(.{ .function = .{
        .params = params1,
        .return_type = TypeStore.BOOL,
    } });

    const params2 = try alloc.alloc(TypeId, 2);
    params2[0] = TypeStore.I64;
    params2[1] = TypeStore.STRING;
    const fn2 = try store.addType(.{ .function = .{
        .params = params2,
        .return_type = TypeStore.BOOL,
    } });

    const result = try store.unify(fn1, fn2, &subs);
    try std.testing.expect(!result);
}

test "unify map type_vars with concrete types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create Map(type_var(0), type_var(1))
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();
    const generic_map = try store.addType(.{ .map = .{ .key = var0, .value = var1 } });

    // Create Map(String, i64)
    const concrete_map = try store.addType(.{ .map = .{ .key = TypeStore.STRING, .value = TypeStore.I64 } });

    const result = try store.unify(generic_map, concrete_map, &subs);
    try std.testing.expect(result);
    try std.testing.expectEqual(TypeStore.STRING, subs.resolve(0).?);
    try std.testing.expectEqual(TypeStore.I64, subs.resolve(1).?);
}

test "transitive type variable resolution through substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create type_var(0) and type_var(1)
    const var0 = try store.freshVar();
    const var1 = try store.freshVar();

    // Unify var0 with var1 (binds var0 -> var1)
    try std.testing.expect(try store.unify(var0, var1, &subs));
    // Then unify var1 with i64 (binds var1 -> i64)
    try std.testing.expect(try store.unify(var1, TypeStore.I64, &subs));

    // applyToType on var0 should resolve through var1 to i64
    const result = subs.applyToType(&store, var0);
    try std.testing.expectEqual(TypeStore.I64, result);
}

test "applyToType leaves unbound type_var unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Create type_var(0) with no binding
    const var_type = try store.freshVar();

    // applyToType should return the original type_var
    const result = subs.applyToType(&store, var_type);
    try std.testing.expectEqual(var_type, result);
}

test "applyToType leaves primitives unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Applying to a primitive should return the same TypeId
    try std.testing.expectEqual(TypeStore.I64, subs.applyToType(&store, TypeStore.I64));
    try std.testing.expectEqual(TypeStore.STRING, subs.applyToType(&store, TypeStore.STRING));
    try std.testing.expectEqual(TypeStore.BOOL, subs.applyToType(&store, TypeStore.BOOL));
    try std.testing.expectEqual(TypeStore.NIL, subs.applyToType(&store, TypeStore.NIL));
}

test "unify records Term constraint when typevar meets Term without binding" {
    // Locks in the fix for the heterogeneous-map update-syntax false
    // positive: when a typevar is unified against `Term` the binding
    // is skipped (Term tolerates any concrete type at runtime), but
    // the substitution map MUST remember the constraint so the
    // return-type resolver can promote container occurrences of the
    // typevar back to `Term`. Without this record, a later scalar
    // argument supplying `String` would silently shadow the `Term`
    // constraint and the call's return type would collapse to a
    // concrete scalar instead of preserving the heterogeneous shape.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    const value_var = try store.freshVar();
    const value_var_id = store.getType(value_var).type_var;

    // First: unify(V, Term) — typevar is left unbound, but the constraint is recorded.
    try std.testing.expect(try store.unify(value_var, TypeStore.TERM, &subs));
    try std.testing.expect(subs.resolve(value_var_id) == null);
    try std.testing.expect(subs.isTermConstrained(value_var_id));

    // Then: unify(V, String) — typevar binds to String for scalar uses.
    try std.testing.expect(try store.unify(value_var, TypeStore.STRING, &subs));
    try std.testing.expectEqual(TypeStore.STRING, subs.resolve(value_var_id).?);
    try std.testing.expect(subs.isTermConstrained(value_var_id));
}

test "applyToReturnType promotes Term-constrained var at container position to Term" {
    // Mirrors the post-unification step the type checker runs for
    // `Map.update(map :: %{K=>V}, key :: K, value :: V) -> %{K=>V}`
    // when the map argument is heterogeneous (`%{Atom=>Term}`) and
    // the value argument is a concrete type like `String`. Container
    // positions in the return must surface as `Term`, even though
    // the substitution map records the scalar binding picked up
    // along the way.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    const key_var = try store.freshVar();
    const value_var = try store.freshVar();
    const generic_map = try store.addType(.{ .map = .{ .key = key_var, .value = value_var } });
    const heterogeneous_map = try store.addType(.{ .map = .{ .key = TypeStore.ATOM, .value = TypeStore.TERM } });

    try std.testing.expect(try store.unify(generic_map, heterogeneous_map, &subs));
    // Subsequent argument unifies the typevar against a concrete scalar.
    try std.testing.expect(try store.unify(value_var, TypeStore.STRING, &subs));

    // Plain applyToType resolves V to its scalar binding (String) — used for scalar return positions.
    const scalar_apply = subs.applyToType(&store, value_var);
    try std.testing.expectEqual(TypeStore.STRING, scalar_apply);

    // applyToReturnType against `%{K=>V}` keeps V at container position → Term.
    const return_resolved = subs.applyToReturnType(&store, generic_map);
    const return_typ = store.getType(return_resolved);
    try std.testing.expect(return_typ == .map);
    try std.testing.expectEqual(TypeStore.ATOM, return_typ.map.key);
    try std.testing.expectEqual(TypeStore.TERM, return_typ.map.value);

    // applyToReturnType for a bare `V` (scalar position) keeps the concrete binding.
    try std.testing.expectEqual(TypeStore.STRING, subs.applyToReturnType(&store, value_var));
}

test "typeEquals accepts Term against any concrete type" {
    // Regression test for the keyword-list false positive: when a
    // heterogeneous tuple/list literal collapses an element type to
    // `Term`, the monomorphic-call check (which uses `typeEquals`,
    // not `unify`) must still treat the literal as compatible with a
    // concrete declared parameter. Without this, a call like
    // `get_age([name: \"Brian\", age: 42])` against a parameter of
    // type `[{Atom, i64}]` is rejected even though the runtime can
    // wrap/unwrap each element through the Term boundary.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    // Term unifies with concrete primitive types in either order.
    try std.testing.expect(store.typeEquals(TypeStore.TERM, TypeStore.I64));
    try std.testing.expect(store.typeEquals(TypeStore.STRING, TypeStore.TERM));

    // Term inside a tuple satisfies a concrete tuple shape.
    const expected_tuple = try store.addType(.{ .tuple = .{
        .elements = try alloc.dupe(TypeId, &[_]TypeId{ TypeStore.ATOM, TypeStore.I64 }),
    } });
    const term_tuple = try store.addType(.{ .tuple = .{
        .elements = try alloc.dupe(TypeId, &[_]TypeId{ TypeStore.ATOM, TypeStore.TERM }),
    } });
    try std.testing.expect(store.typeEquals(expected_tuple, term_tuple));

    // And inside a list of tuples — the literal shape produced by
    // a heterogeneous keyword list desugar.
    const expected_list = try store.addType(.{ .list = .{ .element = expected_tuple } });
    const term_list = try store.addType(.{ .list = .{ .element = term_tuple } });
    try std.testing.expect(store.typeEquals(expected_list, term_list));
}

test "resolveFamilyAllowingDefaults accepts shorter call when tail params have defaults" {
    // Regression test for the default-parameter false positive: when
    // a function is declared with trailing defaults (e.g.
    // `pub fn add(a :: i64, b :: i64 = 10)`) a bare call supplying
    // fewer arguments must still resolve to that family. The
    // codegen backend inlines the constants — the type checker only
    // needs to confirm the supplied arguments are well-typed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var graph = scope_mod.ScopeGraph.init(alloc);
    defer graph.deinit();

    const root_scope = graph.prelude_scope;
    const fn_name = try interner.intern("add");

    // Build a synthetic `pub fn add(a :: i64, b :: i64 = 10)` clause
    // whose second parameter has a default. We only need the
    // structural shape — the type checker doesn't read into the
    // bodies during family resolution.
    const param_meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };
    const a_pat = try alloc.create(ast.Pattern);
    a_pat.* = .{ .bind = .{ .meta = param_meta, .name = try interner.intern("a") } };
    const b_pat = try alloc.create(ast.Pattern);
    b_pat.* = .{ .bind = .{ .meta = param_meta, .name = try interner.intern("b") } };

    const default_expr = try alloc.create(ast.Expr);
    default_expr.* = .{ .int_literal = .{ .meta = param_meta, .value = 10 } };

    const params = try alloc.alloc(ast.Param, 2);
    params[0] = .{ .meta = param_meta, .pattern = a_pat, .type_annotation = null };
    params[1] = .{ .meta = param_meta, .pattern = b_pat, .type_annotation = null, .default = default_expr };

    const clauses = try alloc.alloc(ast.FunctionClause, 1);
    clauses[0] = .{
        .meta = param_meta,
        .params = params,
        .return_type = null,
        .refinement = null,
        .body = null,
    };

    const decl = try alloc.create(ast.FunctionDecl);
    decl.* = .{
        .meta = param_meta,
        .name = fn_name,
        .name_expr = null,
        .clauses = clauses,
        .visibility = .public,
    };

    // Register the family at full declared arity (2). The fix path
    // must recognise this as the correct target for a 1-arg call.
    const family_id = try graph.createFamily(root_scope, fn_name, 2, .public);
    try graph.getFamilyMut(family_id).clauses.append(alloc, .{ .decl = decl, .clause_index = 0 });
    try graph.getScopeMut(root_scope).function_families.put(.{ .name = fn_name, .arity = 2 }, family_id);

    // Exact-arity lookup at arity 2 still works.
    const exact = graph.resolveFamilyAllowingDefaults(root_scope, fn_name, 2);
    try std.testing.expect(exact != null);
    try std.testing.expectEqual(@as(u32, 2), exact.?.declared_arity);
    try std.testing.expectEqual(family_id, exact.?.family_id);

    // Default-bridged lookup at arity 1 surfaces the same family with declared_arity=2.
    const bridged = graph.resolveFamilyAllowingDefaults(root_scope, fn_name, 1);
    try std.testing.expect(bridged != null);
    try std.testing.expectEqual(@as(u32, 2), bridged.?.declared_arity);
    try std.testing.expectEqual(family_id, bridged.?.family_id);

    // Arity 0 does NOT resolve — the first param has no default.
    try std.testing.expect(graph.resolveFamilyAllowingDefaults(root_scope, fn_name, 0) == null);
}

test "pipe inside error_pipe resolves rhs at the piped arity" {
    // Regression test for the type-checker treating `lhs |> rhs` as a
    // bare zero-argument call to `rhs`. Pipes are normally rewritten to
    // calls during macro expansion, but pipes inside an `error_pipe`
    // chain are intentionally preserved up to HIR build time so
    // `flattenAstPipeChain` can identify each step. The type checker
    // must therefore recognise that `lhs |> f()` has arity 1 (one piped
    // argument) and resolve `f/1`, not `f/0`.
    //
    // This test skips macro expansion so the inner pipe stays raw —
    // exactly the shape the type-checker sees inside an error_pipe
    // chain — and asserts no `cannot find a function named parse/0`
    // diagnostic fires.
    const source =
        \\pub struct Test {
        \\  pub fn parse(s :: String) -> String {
        \\    s
        \\  }
        \\
        \\  pub fn run() -> String {
        \\    "x"
        \\    |> parse()
        \\    ~> {
        \\      val -> val
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

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Deliberately skip macro expansion: the parser produces an
    // `error_pipe { chain = pipe { ... }, handler = ... }` shape and
    // the macro engine treats `error_pipe` as a leaf, leaving the
    // inner pipe intact even when expansion runs. Skipping macros
    // keeps the test self-contained while reproducing the same AST
    // the type checker sees in production.
    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        // No diagnostic should mention `parse/0` — the pipe must be
        // resolved as `parse/1`.
        try std.testing.expect(std.mem.indexOf(u8, type_err.message, "parse/0") == null);
        try std.testing.expect(std.mem.indexOf(u8, type_err.message, "parse`/`0") == null);
    }
}

test "bare pipe lhs |> f() resolves rhs at arity 1" {
    // Companion to the error_pipe regression: when a raw pipe reaches
    // the type checker (e.g. inside a context where the macro engine
    // hasn't rewritten it), `lhs |> f()` must still be resolved as
    // `f/1`, not `f/0`. We inject a raw pipe AST node directly into a
    // function body so we exercise `inferExpr`'s `.pipe` branch
    // without depending on the macro expansion order for any specific
    // surface form.
    const source =
        \\pub struct Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x + x
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    double(1)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    var program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Replace `run`'s body with a raw pipe AST: `1 |> double()`.
    // This is the post-parse, pre-macro shape — exactly what the
    // type checker would see if the macro engine hadn't rewritten
    // the pipe (which is what happens inside an error_pipe chain).
    const test_struct = &program.structs[0];
    const run_func = test_struct.items[1].function;
    const meta = ast.NodeMeta{ .span = .{ .start = 0, .end = 0 } };

    const lhs = try alloc.create(ast.Expr);
    lhs.* = .{ .int_literal = .{ .meta = meta, .value = 1 } };

    const callee = try alloc.create(ast.Expr);
    callee.* = .{ .var_ref = .{ .meta = meta, .name = run_func.clauses[0].body.?[0].expr.call.callee.var_ref.name } };
    // Reuse the `double` name from the existing call in the body.

    const rhs = try alloc.create(ast.Expr);
    rhs.* = .{ .call = .{ .meta = meta, .callee = callee, .args = &.{} } };

    const pipe_expr = try alloc.create(ast.Expr);
    pipe_expr.* = .{ .pipe = .{ .meta = meta, .lhs = lhs, .rhs = rhs } };

    const new_body = try alloc.alloc(ast.Stmt, 1);
    new_body[0] = .{ .expr = pipe_expr };

    const new_clause = ast.FunctionClause{
        .meta = run_func.clauses[0].meta,
        .params = run_func.clauses[0].params,
        .return_type = run_func.clauses[0].return_type,
        .refinement = run_func.clauses[0].refinement,
        .body = new_body,
    };
    const new_clauses = try alloc.alloc(ast.FunctionClause, 1);
    new_clauses[0] = new_clause;

    const new_func = try alloc.create(ast.FunctionDecl);
    new_func.* = .{
        .meta = run_func.meta,
        .name = run_func.name,
        .clauses = new_clauses,
        .visibility = run_func.visibility,
    };

    const new_items = try alloc.alloc(ast.StructItem, test_struct.items.len);
    @memcpy(new_items, test_struct.items);
    new_items[1] = .{ .function = new_func };

    const new_struct = ast.StructDecl{
        .meta = test_struct.meta,
        .name = test_struct.name,
        .parent = test_struct.parent,
        .items = new_items,
        .fields = test_struct.fields,
        .is_private = test_struct.is_private,
    };
    const new_structs = try alloc.alloc(ast.StructDecl, 1);
    new_structs[0] = new_struct;

    const new_program = ast.Program{
        .structs = new_structs,
        .top_items = program.top_items,
    };

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&new_program);

    for (checker.errors.items) |type_err| {
        try std.testing.expect(std.mem.indexOf(u8, type_err.message, "double/0") == null);
    }
}

test "numeric call matching prefers exact type over widening" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expectEqual(@as(?u32, 0), store.callMatchCost(TypeStore.I32, TypeStore.I32));
    try std.testing.expectEqual(@as(?u32, 33), store.callMatchCost(TypeStore.I32, TypeStore.I64));
    try std.testing.expectEqual(@as(?u32, 33), store.callMatchCost(TypeStore.U32, TypeStore.U64));
    try std.testing.expectEqual(@as(?u32, 33), store.callMatchCost(TypeStore.F32, TypeStore.F64));
    try std.testing.expectEqual(@as(?u32, 65), store.callMatchCost(TypeStore.I64, TypeStore.I128));
    try std.testing.expectEqual(@as(?u32, 65), store.callMatchCost(TypeStore.U64, TypeStore.U128));
    try std.testing.expectEqual(@as(?u32, 17), store.callMatchCost(TypeStore.F64, TypeStore.F80));
    try std.testing.expectEqual(@as(?u32, 49), store.callMatchCost(TypeStore.F80, TypeStore.F128));
}

test "numeric widening stays within signed unsigned and float families" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expect(store.canWidenTo(TypeStore.I8, TypeStore.I64));
    try std.testing.expect(store.canWidenTo(TypeStore.I64, TypeStore.I128));
    try std.testing.expect(store.canWidenTo(TypeStore.U8, TypeStore.U64));
    try std.testing.expect(store.canWidenTo(TypeStore.U64, TypeStore.U128));
    try std.testing.expect(store.canWidenTo(TypeStore.F16, TypeStore.F64));
    try std.testing.expect(store.canWidenTo(TypeStore.F64, TypeStore.F80));
    try std.testing.expect(store.canWidenTo(TypeStore.F80, TypeStore.F128));

    try std.testing.expect(!store.canWidenTo(TypeStore.U32, TypeStore.I64));
    try std.testing.expect(!store.canWidenTo(TypeStore.U64, TypeStore.I128));
    try std.testing.expect(!store.canWidenTo(TypeStore.I32, TypeStore.U64));
    try std.testing.expect(!store.canWidenTo(TypeStore.I64, TypeStore.U128));
    try std.testing.expect(!store.canWidenTo(TypeStore.I32, TypeStore.F64));
    try std.testing.expect(!store.canWidenTo(TypeStore.F32, TypeStore.I64));
}

// ============================================================
// Field-default type checking (Phase 1.1)
//
// `pub struct Foo { field :: Type = expr }` is a general struct
// feature introduced alongside `pub error` (docs/error-system-
// research-brief.md, Part V). The default expression must
// type-check against the field's declared type at struct-
// declaration time so the user gets a clean Zap diagnostic at
// the default expression, not a Zig-backend error far from the
// mistake. The tests below pin that behavior.
// ============================================================

test "field default with matching integer literal accepted" {
    const source =
        \\pub struct Counter {
        \\  value :: i64 = 0
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "field default with matching string literal accepted" {
    const source =
        \\pub struct Config {
        \\  host :: String = "localhost"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "field default with empty list literal accepted on list field" {
    // The empty list literal `[]` has UNKNOWN element type until a
    // typed context constrains it. A defaulted list field is exactly
    // such a context — the field's declared element type pushes down
    // into the default expression. The typechecker treats this as a
    // valid match rather than an UNKNOWN-vs-list mismatch.
    const source =
        \\pub struct Tags {
        \\  values :: [String] = []
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "field default with mismatched type produces a clear Zap diagnostic" {
    // Phase 1.1 Test D: `x :: i64 = "wrong"` must produce a Zap-level
    // type error at the default expression — not propagate to the
    // Zig backend as an opaque "expected type" failure.
    const source =
        \\pub struct Bad {
        \\  x :: i64 = "wrong"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var saw_default_error = false;
    for (checker.errors.items) |type_err| {
        if (std.mem.indexOf(u8, type_err.message, "default value") != null and
            std.mem.indexOf(u8, type_err.message, "i64") != null and
            std.mem.indexOf(u8, type_err.message, "String") != null)
        {
            saw_default_error = true;
        }
    }
    try std.testing.expect(saw_default_error);
}

test "field default error points at the default expression span" {
    // The diagnostic must caret the default expression itself
    // (not the field declaration or the whole struct), so the user
    // sees `^^^^^^^` under the offending value.
    const source =
        \\pub struct Bad {
        \\  x :: i64 = "wrong"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const bad_default_expr = program.structs[0].fields[0].default orelse
        return error.TestExpectedDefaultExpression;
    const expected_span = bad_default_expr.getMeta().span;

    var matched_span = false;
    for (checker.errors.items) |type_err| {
        if (std.mem.indexOf(u8, type_err.message, "default value") == null) continue;
        if (type_err.span.start == expected_span.start and
            type_err.span.end == expected_span.end)
        {
            matched_span = true;
        }
    }
    try std.testing.expect(matched_span);
}

test "field default integer literal narrowing to u16 accepted" {
    // Numeric literals are contextually typed (see
    // acceptsIntegerLiteralForExpectedType). `port :: u16 = 8080`
    // must not error — 8080 fits inside a u16 and the field's
    // declared type drives the literal's representation downstream.
    const source =
        \\pub struct Server {
        \\  port :: u16 = 8080
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "field default with nested struct expression accepted" {
    // Phase 1.1 Test E: a struct-typed field can default to a
    // struct literal. The default expression type-checks like any
    // other expression in the source — the inner struct's own
    // defaults fill in the inner fields.
    const source =
        \\pub struct Inner {
        \\  v :: i64 = 7
        \\}
        \\pub struct Outer {
        \\  inner :: Inner = %Inner{}
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

// ============================================================
// Phase 1.1.5 — Parametric struct / union types
//
// `StructType.type_params` and `TaggedUnionType.type_params` hold
// one fresh `type_var` TypeId per declared parameter name. The
// substitution helper rewrites those type_vars to concrete
// arguments at instantiation sites. `Type.AppliedType` carries the
// `(base, args)` pair, structurally deduped by `addType`.
// ============================================================

test "parametric struct registration records type_params as fresh type_vars" {
    // `pub struct Box(T) { value :: T }` registers a StructType whose
    // `type_params` array contains exactly one TypeId; that TypeId
    // resolves to a `.type_var` and is also the TypeId stored on the
    // `value` field.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const box_name = parser.interner.lookupExisting("Box") orelse return error.TestExpectedBoxName;
    const box_type_id = checker.store.name_to_type.get(box_name) orelse return error.TestExpectedBoxTypeId;
    const box_type = checker.store.getType(box_type_id);
    try std.testing.expect(box_type == .struct_type);
    try std.testing.expectEqual(@as(usize, 1), box_type.struct_type.type_params.len);

    const param_type_id = box_type.struct_type.type_params[0];
    const param_type = checker.store.getType(param_type_id);
    try std.testing.expect(param_type == .type_var);

    try std.testing.expectEqual(@as(usize, 1), box_type.struct_type.fields.len);
    try std.testing.expectEqual(param_type_id, box_type.struct_type.fields[0].type_id);
}

test "parametric union registration records type_params as fresh type_vars" {
    // `pub union Option(T) { Some :: T, None }` should expose a single
    // type-parameter TypeId; the `Some` variant's payload references
    // that same TypeId.
    const source =
        \\pub union Option(T) {
        \\  Some :: T
        \\  None
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const option_name = parser.interner.lookupExisting("Option") orelse return error.TestExpectedOptionName;
    const option_type_id = checker.store.name_to_type.get(option_name) orelse return error.TestExpectedOptionTypeId;
    const option_type = checker.store.getType(option_type_id);
    try std.testing.expect(option_type == .tagged_union);
    try std.testing.expectEqual(@as(usize, 1), option_type.tagged_union.type_params.len);

    const param_type_id = option_type.tagged_union.type_params[0];
    const param_type = checker.store.getType(param_type_id);
    try std.testing.expect(param_type == .type_var);

    try std.testing.expectEqual(@as(usize, 2), option_type.tagged_union.variants.len);
    const some_variant = option_type.tagged_union.variants[0];
    const none_variant = option_type.tagged_union.variants[1];
    try std.testing.expect(some_variant.type_id != null);
    try std.testing.expectEqual(param_type_id, some_variant.type_id.?);
    try std.testing.expectEqual(@as(?TypeId, null), none_variant.type_id);
}

test "concrete struct registers with empty type_params" {
    // Backwards-compatibility: a struct with no header parens must
    // produce a StructType whose `type_params` slice is empty.
    const source =
        \\pub struct Plain {
        \\  value :: i64
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const plain_name = parser.interner.lookupExisting("Plain") orelse return error.TestExpectedPlainName;
    const plain_type_id = checker.store.name_to_type.get(plain_name) orelse return error.TestExpectedPlainTypeId;
    const plain_type = checker.store.getType(plain_type_id);
    try std.testing.expect(plain_type == .struct_type);
    try std.testing.expectEqual(@as(usize, 0), plain_type.struct_type.type_params.len);
}

test "applyToType substitutes through nested applied type args" {
    // A substitution map that binds the formal `T` TypeVar must
    // rewrite both `Box(T)` and the nested arg of `Box(Option(T))`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    var subs = SubstitutionMap.init(alloc);
    defer subs.deinit();

    // Stand-in nominal bases — we only need the TypeIds, not full
    // declarations, for the substitution-helper test.
    const box_name = try interner.intern("Box");
    const option_name = try interner.intern("Option");
    const box_base = try store.addType(.{ .struct_type = .{
        .name = box_name,
        .fields = &.{},
        .type_params = &.{},
    } });
    const option_base = try store.addType(.{ .tagged_union = .{
        .name = option_name,
        .variants = &.{},
        .type_params = &.{},
    } });

    const t_var = try store.freshVar();
    const t_var_id = store.getType(t_var).type_var;

    const inner_args = try alloc.alloc(TypeId, 1);
    inner_args[0] = t_var;
    const option_of_t = try store.addType(.{ .applied = .{ .base = option_base, .args = inner_args } });

    const outer_args = try alloc.alloc(TypeId, 1);
    outer_args[0] = option_of_t;
    const box_of_option_t = try store.addType(.{ .applied = .{ .base = box_base, .args = outer_args } });

    subs.bind(t_var_id, TypeStore.I64);

    const substituted = subs.applyToType(&store, box_of_option_t);
    const outer = store.getType(substituted);
    try std.testing.expect(outer == .applied);
    try std.testing.expectEqual(box_base, outer.applied.base);
    try std.testing.expectEqual(@as(usize, 1), outer.applied.args.len);

    const inner = store.getType(outer.applied.args[0]);
    try std.testing.expect(inner == .applied);
    try std.testing.expectEqual(option_base, inner.applied.base);
    try std.testing.expectEqual(@as(usize, 1), inner.applied.args.len);
    try std.testing.expectEqual(TypeStore.I64, inner.applied.args[0]);
}

test "parametric struct literal type-checks field expr against substituted type" {
    // `%Box(i64){value: 42}` should accept — the literal `42` types
    // as i64 which matches the substituted field type. The literal
    // also receives the canonical `Box(i64)` (`.applied`) TypeId.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn build() -> Box {
        \\    %Box(i64){value: 42}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    for (checker.errors.items) |type_err| {
        std.debug.print("Unexpected type error: {s}\n", .{type_err.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "parametric struct literal rejects field expr of the wrong substituted type" {
    // `%Box(i64){value: \"hi\"}` must surface a clear type-mismatch
    // diagnostic — the substitution rewrites `T` to `i64`, but the
    // value is a String.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn build() -> Box {
        \\    %Box(i64){value: "hi"}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_substituted_diag = false;
    for (checker.errors.items) |type_err| {
        if (std.mem.indexOf(u8, type_err.message, "expects `i64`") != null and
            std.mem.indexOf(u8, type_err.message, "got `String`") != null)
        {
            found_substituted_diag = true;
        }
    }
    try std.testing.expect(found_substituted_diag);
}

test "parametric type expression with wrong arity emits diagnostic" {
    // `Box(i64, String)` for a `Box(T)` declaration: one type
    // parameter expected, two supplied.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn take(box :: Box(i64, String)) -> i64 { 0 }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_arity_diag = false;
    for (checker.errors.items) |type_err| {
        if (std.mem.indexOf(u8, type_err.message, "expects 1 type parameter") != null and
            std.mem.indexOf(u8, type_err.message, "got 2") != null)
        {
            found_arity_diag = true;
        }
    }
    try std.testing.expect(found_arity_diag);
}

test "applying type arguments to a non-parametric struct emits diagnostic" {
    // `Plain` has no type parameters; `Plain(i64)` is a use-site
    // error.
    const source =
        \\pub struct Plain { value :: i64 }
        \\pub struct Demo {
        \\  pub fn take(p :: Plain(i64)) -> i64 { 0 }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var found_non_parametric_diag = false;
    for (checker.errors.items) |type_err| {
        if (std.mem.indexOf(u8, type_err.message, "does not take type parameters") != null) {
            found_non_parametric_diag = true;
        }
    }
    try std.testing.expect(found_non_parametric_diag);
}

test "applied type instantiations dedupe by base and args" {
    // The structural-dedupe rule for `.applied` (typeStructEq) must
    // collapse `Box(i64)` to one TypeId regardless of how many times
    // it is constructed; `Box(String)` must remain distinct.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    var store = TypeStore.init(alloc, &interner);
    defer store.deinit();

    const box_name = try interner.intern("Box");
    const box_base = try store.addType(.{ .struct_type = .{
        .name = box_name,
        .fields = &.{},
        .type_params = &.{},
    } });

    const first_args = try alloc.alloc(TypeId, 1);
    first_args[0] = TypeStore.I64;
    const first = try store.addType(.{ .applied = .{ .base = box_base, .args = first_args } });

    const second_args = try alloc.alloc(TypeId, 1);
    second_args[0] = TypeStore.I64;
    const second = try store.addType(.{ .applied = .{ .base = box_base, .args = second_args } });
    try std.testing.expectEqual(first, second);

    const string_args = try alloc.alloc(TypeId, 1);
    string_args[0] = TypeStore.STRING;
    const box_of_string = try store.addType(.{ .applied = .{ .base = box_base, .args = string_args } });
    try std.testing.expect(box_of_string != first);
}
