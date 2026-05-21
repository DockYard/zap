const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Zig-shaped IR (spec §19)
//
// A low-level IR that sits between typed HIR and Zig emission.
// Represents explicit control flow, locals, calls, closures,
// and ARC operations.
// ============================================================

pub const FunctionId = u32;
pub const BlockId = u32;
pub const LocalId = u32;
pub const LabelId = u32;
pub const ValueMode = hir_mod.ValueMode;

// ============================================================
// IR Program
// ============================================================

pub const TypeDef = struct {
    name: []const u8,
    kind: TypeDefKind,
};

pub const TypeDefKind = union(enum) {
    struct_def: StructDef,
    enum_def: EnumDef,
    union_def: UnionDef,
    /// Per-protocol vtable struct type (Phase 1.2.5.a). For every
    /// `pub protocol Foo { fn m(x) -> R; ... }` reachable from the
    /// program, IR emits one `protocol_vtable_def` with the canonical
    /// name `FooVTable` containing one slot per protocol method.
    /// The ZIR backend's step 3.7 lowers this into a synthetic Zig
    /// source file:
    ///
    ///     pub const FooVTable = extern struct {
    ///         m: *const fn(data_ptr: ?*anyopaque) callconv(.c) R_zig,
    ///         ...
    ///     };
    ///
    /// The receiver `x` is type-erased to `?*anyopaque` because at
    /// every dispatch through a `ProtocolBox`, the concrete receiver
    /// type is invisible — the construction site lowering (Phase
    /// 1.2.5.c) heap-allocates the inner and stores it in the box's
    /// `data_ptr`; the consumption site (Phase 1.2.5.d) passes that
    /// pointer back into the impl method.
    protocol_vtable_def: ProtocolVTableDef,
    /// Per-impl vtable instance constant (Phase 1.2.5.a). For every
    /// `pub impl Foo for Bar { pub fn m(self) -> R { ... } }`
    /// reachable from the program, IR emits one
    /// `protocol_vtable_instance_def` with name
    /// `FooVTable_for_Bar`. The ZIR backend's step 3.7 lowers it
    /// into a synthetic Zig source file:
    ///
    ///     const FooVTable = @import("FooVTable").FooVTable;
    ///     const Bar_m: *const fn(data_ptr: ?*anyopaque) callconv(.c) R_zig =
    ///         @ptrCast(&Bar__m__1);
    ///     pub const FooVTable_for_Bar: FooVTable = .{ .m = Bar_m, ... };
    ///
    /// Each method-pointer entry references the impl's monomorphized
    /// implementation name — the same `<TargetStruct>__<method>__<arity>`
    /// (or its monomorphized parametric variant) that other call sites
    /// reach via `call_named`. Construction-site lowering (Phase
    /// 1.2.5.c) reads `vtable_constant_name` to populate the box's
    /// `vtable` field.
    protocol_vtable_instance_def: ProtocolVTableInstanceDef,
};

pub const StructDef = struct {
    fields: []const StructFieldDef,
};

/// How a struct field is laid out at the runtime/Zig level. Only
/// matters for nominal struct fields whose type creates a layout
/// cycle: a self-referential `Tree { left :: ?Tree }` has infinite
/// size if every `Tree` value contains another `Tree` value, so
/// the compiler must internally indirect the recursive edge with
/// a pointer. Source nullability stays source-driven — `?Tree`
/// stays optional at the source level, but its storage is
/// `?*Tree` (optional pointer); `Tree` (non-optional) is rejected
/// as uninhabited if no terminating constructor is reachable.
pub const FieldStorage = enum {
    /// Field is laid out by value at its declared type. The default
    /// for every primitive, every nominal struct type that doesn't
    /// participate in a recursion cycle, and every container of
    /// either of those.
    direct,
    /// Field is laid out via a hidden pointer indirection that
    /// breaks an otherwise-infinite layout cycle. Source-level
    /// access still returns the deref'd value; construction
    /// auto-promotes the value to the heap. Triggered only for
    /// fields whose type transitively references the struct that
    /// owns them (self-recursion today; mutual recursion through
    /// SCC analysis is the next step).
    indirect,
};

pub const StructFieldDef = struct {
    name: []const u8,
    /// Field type as a structured `ZigType`. The previous string
    /// representation collapsed every non-primitive type to a printable
    /// name and forced the ZIR builder to round-trip through string
    /// matching that only handled scalars — every other shape silently
    /// fell through to `Zir.Inst.Ref` discriminant 0 (`u0_type`,
    /// not `void_type`), producing `expected type 'u0', found 'X'`
    /// at every literal site.
    type_expr: ZigType,
    default_value: ?DefaultValue = null,
    /// Storage strategy for this field. `.direct` is the default and
    /// applies to everything except recursive edges; `.indirect`
    /// inserts a hidden pointer to break a layout cycle (see
    /// `FieldStorage`). Computed by `analyzeStructFieldStorage`
    /// during IR construction.
    storage: FieldStorage = .direct,
};

pub const EnumDef = struct {
    variants: []const []const u8,
};

pub const UnionDef = struct {
    variants: []const UnionVariant,
};

pub const UnionVariant = struct {
    name: []const u8,
    type_name: ?[]const u8 = null, // null = unit variant (void)
};

/// Shape of a single method slot in a per-protocol vtable type.
/// Each protocol method maps to one `ProtocolVTableMethod`; the
/// vtable struct field at this slot is a function pointer with
/// the receiver type-erased to `?*anyopaque` and the remaining
/// params plus return type lowered to their declared `ZigType`s.
pub const ProtocolVTableMethod = struct {
    /// The protocol method's source-level name (e.g. `message`,
    /// `kind`). Used as the field name on the generated
    /// `<Protocol>VTable` struct so dispatch sites can read the
    /// slot via `vtable.message`, matching the method name in
    /// the Zap source.
    name: []const u8,
    /// Number of source-level arguments declared on the
    /// protocol's method signature, *including* the receiver.
    /// Phase 1.2.5.a constraint: arity must be at least 1 (a
    /// protocol method always takes the receiver as its first
    /// argument). The codegen rejects arity-0 protocol methods
    /// at the IR-population step because they cannot be dispatched
    /// against a `ProtocolBox`.
    arity: u32,
    /// Non-receiver parameter types in source declaration order.
    /// `arity - 1` entries — the receiver is implicit and always
    /// `?*anyopaque` in the lowered function pointer. An empty
    /// slice means the method takes only the receiver.
    extra_param_types: []const ZigType,
    /// The method's return type. `void` represents a sentinel-
    /// only signature (no value flows back); every other return
    /// shape lowers to its declared `ZigType` form.
    return_type: ZigType,
};

/// Per-protocol vtable struct type. One IR `TypeDef` carries
/// this kind for every `pub protocol` reachable in the program.
/// The ZIR backend emits a `pub const <Protocol>VTable = extern
/// struct { ... };` synthetic source file from this entry; the
/// fields are the method slots in declaration order.
pub const ProtocolVTableDef = struct {
    /// The source-level protocol name (e.g. `Error`,
    /// `Enumerable`). Used in diagnostics and as a prefix when
    /// the ZIR backend materializes the synthetic source file —
    /// the `name` field on the owning `TypeDef` already carries
    /// the `<Protocol>VTable` form, but the bare protocol name
    /// is retained here so per-impl `protocol_vtable_instance_def`
    /// emission can correlate the vtable shape with its source
    /// protocol without re-parsing the suffix.
    protocol_name: []const u8,
    /// Methods in source declaration order. The ordering is
    /// load-bearing: per-impl vtable instance constants populate
    /// their `.method = &impl_method` slots in the same order, so
    /// the consumption-site lowering can dispatch through the
    /// vtable by field name (`vtable.method`) and read the matching
    /// method pointer regardless of how the protocol struct was
    /// laid out at the machine level.
    methods: []const ProtocolVTableMethod,
};

/// Shape of a single method-pointer entry in a per-impl vtable
/// instance constant. The ZIR backend uses this to populate one
/// `.method = &impl_function_name` field on the constant.
pub const ProtocolVTableInstanceMethod = struct {
    /// Protocol method name (matches a slot in the corresponding
    /// `ProtocolVTableDef.methods`). Lets the ZIR backend emit
    /// `.message = ...` rather than positional initializers,
    /// which is more robust against ordering drift between the
    /// vtable type and the instance constant.
    method_name: []const u8,
    /// The fully-qualified function name to point the slot at.
    /// For a concrete impl `pub impl Foo for Bar { pub fn m(self)
    /// -> R }` this is `Bar__m__1` (the same mangled name every
    /// other call site reaches via `call_named`). The
    /// monomorphized-impl asymmetry (calling-module prefix for
    /// parametric impl specializations) is resolved at population
    /// time so by the IR layer the name is stable.
    impl_function_name: []const u8,
    /// The number of source-level arguments on the impl method,
    /// including the receiver. Mirrors the protocol's arity for
    /// the matching slot. Used by the ZIR backend to emit the
    /// correct callconv on the cast.
    arity: u32,
    /// Non-receiver parameter types on the impl method, in
    /// source declaration order. Must match the protocol's
    /// `extra_param_types` at the same slot (the type checker
    /// enforces this at impl registration time); recorded here
    /// so the ZIR backend can emit the `@ptrCast` signature
    /// without a second lookup.
    extra_param_types: []const ZigType,
    /// The impl method's return type. Must match the protocol's
    /// return type at the same slot.
    return_type: ZigType,
};

/// Per-impl vtable instance constant. One IR `TypeDef` carries
/// this kind for every `pub impl <Protocol> for <TargetType>`
/// reachable from the program. The ZIR backend emits a
/// `pub const <Protocol>VTable_for_<TargetType>: <Protocol>VTable
/// = ...;` synthetic source file from this entry. The
/// construction-site lowering (Phase 1.2.5.c) writes the address
/// of this constant into the `ProtocolBox.vtable` field at every
/// site where a concrete `<TargetType>` is auto-boxed as the
/// protocol.
pub const ProtocolVTableInstanceDef = struct {
    /// Source-level protocol name (matches the
    /// `ProtocolVTableDef.protocol_name` of the corresponding
    /// vtable type). Lets the ZIR backend generate the
    /// `@import("<Protocol>VTable")` import that gives the
    /// constant its declared type.
    protocol_name: []const u8,
    /// Source-level target struct name (the type the impl is
    /// for). Used in diagnostics and as the suffix on the
    /// vtable-constant name. The `name` field on the owning
    /// `TypeDef` already carries the
    /// `<Protocol>VTable_for_<Target>` form; the bare target
    /// name is retained here so the construction-site lowering
    /// can correlate boxing arguments with their concrete impl.
    target_type_name: []const u8,
    /// Method-pointer entries in protocol declaration order.
    methods: []const ProtocolVTableInstanceMethod,
};

pub const Program = struct {
    functions: []const Function,
    type_defs: []const TypeDef,
    entry: ?FunctionId,
};

const CloneError = std.mem.Allocator.Error;

pub fn cloneProgram(allocator: std.mem.Allocator, program: Program) CloneError!Program {
    const functions = try allocator.alloc(Function, program.functions.len);
    errdefer allocator.free(functions);
    for (program.functions, 0..) |function, index| {
        functions[index] = try cloneFunction(allocator, function);
    }

    const type_defs = try allocator.alloc(TypeDef, program.type_defs.len);
    errdefer allocator.free(type_defs);
    for (program.type_defs, 0..) |type_def, index| {
        type_defs[index] = try cloneTypeDef(allocator, type_def);
    }

    return .{
        .functions = functions,
        .type_defs = type_defs,
        .entry = program.entry,
    };
}

fn cloneBytes(allocator: std.mem.Allocator, bytes: []const u8) CloneError![]const u8 {
    if (bytes.len == 0) return "";
    return try allocator.dupe(u8, bytes);
}

fn cloneOptionalBytes(allocator: std.mem.Allocator, bytes: ?[]const u8) CloneError!?[]const u8 {
    return if (bytes) |value| try cloneBytes(allocator, value) else null;
}

fn clonePlainSlice(comptime T: type, allocator: std.mem.Allocator, values: []const T) CloneError![]const T {
    if (values.len == 0) return &.{};
    return try allocator.dupe(T, values);
}

fn cloneMutableSlice(comptime T: type, allocator: std.mem.Allocator, values: []const T) CloneError![]T {
    if (values.len == 0) return &.{};
    return try allocator.dupe(T, values);
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) CloneError![]const []const u8 {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        cloned[index] = try cloneBytes(allocator, value);
    }
    return cloned;
}

fn cloneZigTypePtr(allocator: std.mem.Allocator, value: *const ZigType) CloneError!*const ZigType {
    const cloned = try allocator.create(ZigType);
    cloned.* = try cloneZigType(allocator, value.*);
    return cloned;
}

fn cloneZigTypeSlice(allocator: std.mem.Allocator, values: []const ZigType) CloneError![]const ZigType {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc(ZigType, values.len);
    for (values, 0..) |value, index| {
        cloned[index] = try cloneZigType(allocator, value);
    }
    return cloned;
}

/// Map a primitive type's source name to the matching IR
/// `ZigType` shape. Mirrors `TypeStore.resolveTypeName` so the
/// protocol-vtable populator (which resolves AST `TypeNameExpr`
/// nodes directly) and the rest of the type checker agree on
/// which names are primitives.
///
/// Used by the Phase 1.2.5.a protocol-vtable populator —
/// `astTypeExprToZigTypeForProtocol` — to lower `fn message(e) ->
/// String` to a function pointer whose return type is `.string`.
/// Returns `null` for non-primitives (the caller falls back to a
/// `.struct_ref` lookup for nominal types).
fn primitiveNameToZigType(name: []const u8) ?ZigType {
    if (std.mem.eql(u8, name, "Bool")) return .bool_type;
    if (std.mem.eql(u8, name, "String")) return .string;
    if (std.mem.eql(u8, name, "Atom")) return .atom;
    if (std.mem.eql(u8, name, "Nil")) return .nil;
    if (std.mem.eql(u8, name, "Void")) return .void;
    if (std.mem.eql(u8, name, "Never")) return .never;
    if (std.mem.eql(u8, name, "Term")) return .term;
    if (std.mem.eql(u8, name, "i128")) return .i128;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "u128")) return .u128;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "f128")) return .f128;
    if (std.mem.eql(u8, name, "f80")) return .f80;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f16")) return .f16;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    return null;
}

/// Borrow-shape mangled name for a `ZigType` used as a parametric
/// type argument. Mirrors `types_mod.typeIdMangledNameBorrowed`'s
/// component-name encoding so per-instantiation synthetic source
/// file names line up between protocol-vtable emission (this file)
/// and the type-store mangler (used by `populateAppliedSpecializations`).
///
/// Returns null when the argument's shape is one we cannot
/// participate in a name without a TypeStore handle (e.g. nested
/// `.applied` forms whose mangling needs recursive type-store
/// inspection). The caller falls back to the bare base name in
/// that case.
fn mangledNameForArgZigType(zig_type: ZigType) ?[]const u8 {
    return switch (zig_type) {
        .bool_type => "Bool",
        .string => "String",
        .atom => "Atom",
        .nil => "Nil",
        .void => "Void",
        .never => "Never",
        .term => "Term",
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .i128 => "i128",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .u128 => "u128",
        .f16 => "f16",
        .f32 => "f32",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
        .usize => "usize",
        .isize => "isize",
        .struct_ref => |name| name,
        .tagged_union => |name| name,
        // `protocol_constraint(P)` mangles to the bare protocol name
        // — matches `types.typeIdMangledNameBorrowed`'s mangling so
        // `Option(Error)` -> `Option_Error` lines up across the IR
        // pipeline (the per-instantiation `Option_Error` `union_def`
        // is produced by `populateAppliedSpecializations` under that
        // same key).
        .protocol_box => |name| name,
        else => null,
    };
}

fn cloneZigType(allocator: std.mem.Allocator, value: ZigType) CloneError!ZigType {
    return switch (value) {
        .tuple => |items| .{ .tuple = try cloneZigTypeSlice(allocator, items) },
        .list => |item| .{ .list = try cloneZigTypePtr(allocator, item) },
        .map => |map_type| .{ .map = .{
            .key = try cloneZigTypePtr(allocator, map_type.key),
            .value = try cloneZigTypePtr(allocator, map_type.value),
        } },
        .struct_ref => |name| .{ .struct_ref = try cloneBytes(allocator, name) },
        .function => |fn_type| .{ .function = .{
            .params = try cloneZigTypeSlice(allocator, fn_type.params),
            .return_type = try cloneZigTypePtr(allocator, fn_type.return_type),
        } },
        .tagged_union => |name| .{ .tagged_union = try cloneBytes(allocator, name) },
        .optional => |item| .{ .optional = try cloneZigTypePtr(allocator, item) },
        .ptr => |item| .{ .ptr = try cloneZigTypePtr(allocator, item) },
        .protocol_box => |name| .{ .protocol_box = try cloneBytes(allocator, name) },
        else => value,
    };
}

fn cloneDefaultValue(allocator: std.mem.Allocator, value: DefaultValue) CloneError!DefaultValue {
    return switch (value) {
        .string => |string| .{ .string = try cloneBytes(allocator, string) },
        else => value,
    };
}

fn cloneOptionalDefaultValue(allocator: std.mem.Allocator, value: ?DefaultValue) CloneError!?DefaultValue {
    return if (value) |default_value| try cloneDefaultValue(allocator, default_value) else null;
}

fn cloneTypeDef(allocator: std.mem.Allocator, type_def: TypeDef) CloneError!TypeDef {
    return .{
        .name = try cloneBytes(allocator, type_def.name),
        .kind = switch (type_def.kind) {
            .struct_def => |struct_def| .{ .struct_def = .{
                .fields = try cloneStructFieldDefs(allocator, struct_def.fields),
            } },
            .enum_def => |enum_def| .{ .enum_def = .{
                .variants = try cloneStringSlice(allocator, enum_def.variants),
            } },
            .union_def => |union_def| .{ .union_def = .{
                .variants = try cloneUnionVariants(allocator, union_def.variants),
            } },
            .protocol_vtable_def => |vt_def| .{ .protocol_vtable_def = .{
                .protocol_name = try cloneBytes(allocator, vt_def.protocol_name),
                .methods = try cloneProtocolVTableMethods(allocator, vt_def.methods),
            } },
            .protocol_vtable_instance_def => |vt_inst| .{ .protocol_vtable_instance_def = .{
                .protocol_name = try cloneBytes(allocator, vt_inst.protocol_name),
                .target_type_name = try cloneBytes(allocator, vt_inst.target_type_name),
                .methods = try cloneProtocolVTableInstanceMethods(allocator, vt_inst.methods),
            } },
        },
    };
}

fn cloneProtocolVTableMethods(
    allocator: std.mem.Allocator,
    methods: []const ProtocolVTableMethod,
) CloneError![]const ProtocolVTableMethod {
    if (methods.len == 0) return &.{};
    const cloned = try allocator.alloc(ProtocolVTableMethod, methods.len);
    for (methods, 0..) |method, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, method.name),
            .arity = method.arity,
            .extra_param_types = try cloneZigTypeSlice(allocator, method.extra_param_types),
            .return_type = try cloneZigType(allocator, method.return_type),
        };
    }
    return cloned;
}

fn cloneProtocolVTableInstanceMethods(
    allocator: std.mem.Allocator,
    methods: []const ProtocolVTableInstanceMethod,
) CloneError![]const ProtocolVTableInstanceMethod {
    if (methods.len == 0) return &.{};
    const cloned = try allocator.alloc(ProtocolVTableInstanceMethod, methods.len);
    for (methods, 0..) |method, index| {
        cloned[index] = .{
            .method_name = try cloneBytes(allocator, method.method_name),
            .impl_function_name = try cloneBytes(allocator, method.impl_function_name),
            .arity = method.arity,
            .extra_param_types = try cloneZigTypeSlice(allocator, method.extra_param_types),
            .return_type = try cloneZigType(allocator, method.return_type),
        };
    }
    return cloned;
}

fn cloneStructFieldDefs(allocator: std.mem.Allocator, fields: []const StructFieldDef) CloneError![]const StructFieldDef {
    if (fields.len == 0) return &.{};
    const cloned = try allocator.alloc(StructFieldDef, fields.len);
    for (fields, 0..) |field, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, field.name),
            .type_expr = try cloneZigType(allocator, field.type_expr),
            .default_value = try cloneOptionalDefaultValue(allocator, field.default_value),
            .storage = field.storage,
        };
    }
    return cloned;
}

fn cloneUnionVariants(allocator: std.mem.Allocator, variants: []const UnionVariant) CloneError![]const UnionVariant {
    if (variants.len == 0) return &.{};
    const cloned = try allocator.alloc(UnionVariant, variants.len);
    for (variants, 0..) |variant, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, variant.name),
            .type_name = try cloneOptionalBytes(allocator, variant.type_name),
        };
    }
    return cloned;
}

/// Per-value ownership classification at IR sites that produce or
/// reference ARC-managed cells (parameters, locals, call results,
/// aggregate arm results, captures, and return values).
///
/// Phase A of the Phase 6 redux plan introduces this enum as pure
/// metadata. Phases C and E will use it to drive borrow/copy
/// classification (`borrow_value` vs `copy_value`) and verifier
/// invariants. The classification is the property the ownership
/// verifier checks: every ARC value site has exactly one class, and
/// drop insertion only emits `release` for `owned` values.
///
/// - `trivial`: Non-ARC values (i64, Bool, Atom, ...). No ARC
///   operations. Stored in `Function.local_ownership` for every
///   non-ARC local so the table is dense across `LocalId`.
/// - `owned`: Owns one refcount unit. Must be destroyed exactly once
///   on every CFG path that reaches a function exit. Owners are
///   produced by: function entry of owned-convention parameters,
///   `copy_value` of any ARC value, return values of calls whose
///   convention transfers ownership, aggregate initializers
///   (`map_init`, `list_init`, `struct_init`), and freshly-allocated
///   values. Must NOT be destroyed twice.
/// - `borrowed`: Borrowed reference scoped to a borrow region. Must
///   NOT be destroyed within the region. Cannot escape into owned
///   storage without an explicit `copy_value` to promote.
///   Produced by: function entry of borrowed-convention parameters
///   (the default for ARC-managed parameter types), `borrow_value`
///   of any owner, and capture access in closures.
pub const OwnershipClass = enum {
    trivial,
    owned,
    borrowed,
};

/// Per-parameter calling convention recorded on every
/// `Function.params` slot.
///
/// Three variants cover every parameter shape, which is cleaner than
/// pairing a binary `borrowed|owned` enum with a separate
/// `is_arc_managed` predicate: the dense form lets a single look-up
/// answer "what should drop insertion do at scope exit for this
/// parameter?" without consulting the type table again.
///
/// - `trivial`: The parameter's type is not ARC-managed. No retain
///   is performed by the caller, and drop insertion never targets
///   the parameter local at scope exit. This is the catch-all for
///   primitive scalar types, atoms, and structurally trivial types.
/// - `borrowed`: The default for ARC-managed parameter types. The
///   caller has already balanced retain (`share_value`) and release
///   (post-call `release`) around the call site, so the callee
///   merely *borrows* the value within its body. Drop insertion
///   must NOT emit a destroy on the parameter local at scope exit.
/// - `owned`: The callee takes ownership of the value. The caller
///   does NOT release after the call, and the callee is responsible
///   for emitting a `destroy_value` on every CFG path. Reserved for
///   explicitly-annotated consuming functions; today's stdlib
///   surface uses no `owned` parameters, so this variant exists for
///   forward compatibility with Phase H's consume-mode work.
pub const ParamConvention = enum {
    trivial,
    borrowed,
    owned,
};

/// Calling convention for the function's result value.
///
/// - `trivial`: The return type is not ARC-managed. Default for
///   primitive scalar types. The caller binds the result in a
///   trivial local with no retain/release tracking.
/// - `owned`: The callee returns an owner. The caller binds the
///   result in an owned local and is responsible for destroying it
///   on every CFG path. Default for ARC-managed return types.
/// - `borrowed`: The callee returns a borrow scoped to one of its
///   parameters (lifetime polymorphism). Currently unused; reserved
///   for a future extension that lets a function return a borrowed
///   alias to one of its inputs without bumping the refcount.
pub const ResultConvention = enum {
    trivial,
    owned,
    borrowed,
};

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    /// When this is a compiler-generated typed-clause entrypoint, these
    /// identify the source function group and source clause it lowers.
    source_group_id: ?FunctionId = null,
    source_clause_index: ?u32 = null,
    /// Source-language debug file for DWARF. Null keeps the generated
    /// synthetic Zig file path.
    debug_source_path: ?[]const u8 = null,
    /// Zero-based source-language line/column for the first executable
    /// statement in this function. ZIR/AIR add one when emitting DWARF.
    debug_line: u32 = 0,
    debug_column: u32 = 0,
    /// Struct this function belongs to (e.g., "IO", "Zest_Runtime"). Null for top-level.
    struct_name: ?[]const u8 = null,
    /// Function name within its struct, with arity suffix (e.g., "puts__1"). Used for per-struct ZIR emission.
    local_name: []const u8 = "",
    scope_id: scope_mod.ScopeId,
    arity: u32,
    params: []const Param,
    return_type: ZigType,
    /// Original TypeStore TypeId for the return type, preserved for list type detection.
    return_type_id: ?types_mod.TypeId = null,
    body: []const Block,
    is_closure: bool,
    captures: []const Capture,
    local_count: u32 = 0,
    /// Default parameter values. defaults[i] is the default for params[full_arity - defaults.len + i].
    /// Empty when no defaults exist.
    defaults: []const DefaultValue = &.{},
    /// True when at least one self-tail-call survives in this function
    /// AND the by-value parameter ABI would reject `musttail`. Set by
    /// `rewriteTailCalls` after observing both. The ZIR backend reads
    /// this flag and lowers tail-position self-calls as a `loop` +
    /// stack-slot recurrence (loopification) instead of `musttail`.
    /// Loopification has zero hot-path allocation and bypasses LLVM's
    /// tail-call legality entirely, so byref-shaped state recurses
    /// in bounded stack.
    loopify: bool = false,
    /// Per-parameter calling convention, one entry per `params` slot.
    /// Phase A of the Phase 6 redux plan populates this with the
    /// default classification: ARC-managed parameter types get
    /// `.borrowed`, every other parameter type gets `.trivial`.
    /// Phase H may flip individual entries to `.owned` for explicit
    /// consume-mode callees. The slice must always have the same
    /// length as `params` so call sites can index by parameter
    /// position.
    param_conventions: []const ParamConvention = &.{},
    /// Per-local ownership class indexed by `LocalId`. Phase A
    /// populates this with the trivial baseline classification:
    /// every non-ARC local is `.trivial`, every ARC-managed local
    /// (the value held in the local is ARC-cell-typed) defaults to
    /// `.owned` at this stage. Phase C's `arc_ownership` pass
    /// refines ARC entries into `.borrowed` vs `.owned` based on
    /// the local's definition site (parameter binding, alias of an
    /// existing value, fresh allocation, etc.) and the verifier in
    /// Phase E checks invariants against the refined classification.
    /// The slice has length `local_count` so look-ups by `LocalId`
    /// never need a bounds-tolerant fallback.
    local_ownership: []OwnershipClass = &.{},
    /// Calling convention for the result. Defaults to `.owned` for
    /// ARC-managed return types and `.trivial` for everything else.
    /// Phase E's verifier checks every `ret` instruction's source
    /// against this convention.
    result_convention: ResultConvention = .trivial,
    /// Phase 1.2.5.d sidecar — for every local in this function whose
    /// tracked Zig type is `.protocol_box(P)`, maps `LocalId` ->
    /// bare protocol name `P`. Populated by the IR builder whenever
    /// a `box_as_protocol` produces a dest, a `param_get` reads a
    /// protocol-existential param, a `field_get` extracts a
    /// protocol-existential field, a `local_get` aliases one, or
    /// any other propagation that mutates `known_local_types`. The
    /// post-drop-insertion rewrite pass consults this map to flip
    /// `.release{value=L, kind=.release}` instructions targeting a
    /// known box-local to `.release{value=L, kind=.protocol_box_drop,
    /// protocol_name=P}`, so the ZIR backend lowers them through
    /// the synthetic `<Protocol>VTable.drop(box)` helper rather than
    /// the standard `releaseAny(box)` dispatcher (which would
    /// mis-interpret the 16-byte fat pointer as a slab-managed
    /// cell).
    ///
    /// Empty when the function doesn't traffic in any protocol
    /// existentials — the most common case. Carried by-value (no
    /// pointer) so the post-drop rewrite is a single map lookup
    /// per release with no extra indirection.
    protocol_box_locals: std.AutoHashMapUnmanaged(LocalId, []const u8) = .empty,
};

fn cloneFunction(allocator: std.mem.Allocator, function: Function) CloneError!Function {
    return .{
        .id = function.id,
        .name = try cloneBytes(allocator, function.name),
        .source_group_id = function.source_group_id,
        .source_clause_index = function.source_clause_index,
        .debug_source_path = try cloneOptionalBytes(allocator, function.debug_source_path),
        .debug_line = function.debug_line,
        .debug_column = function.debug_column,
        .struct_name = try cloneOptionalBytes(allocator, function.struct_name),
        .local_name = try cloneBytes(allocator, function.local_name),
        .scope_id = function.scope_id,
        .arity = function.arity,
        .params = try cloneParams(allocator, function.params),
        .return_type = try cloneZigType(allocator, function.return_type),
        .return_type_id = function.return_type_id,
        .body = try cloneBlocks(allocator, function.body),
        .is_closure = function.is_closure,
        .captures = try cloneCaptures(allocator, function.captures),
        .local_count = function.local_count,
        .defaults = try cloneDefaultValues(allocator, function.defaults),
        .loopify = function.loopify,
        .param_conventions = try clonePlainSlice(ParamConvention, allocator, function.param_conventions),
        .local_ownership = try cloneMutableSlice(OwnershipClass, allocator, function.local_ownership),
        .result_convention = function.result_convention,
        .protocol_box_locals = try cloneProtocolBoxLocals(allocator, function.protocol_box_locals),
    };
}

fn cloneProtocolBoxLocals(
    allocator: std.mem.Allocator,
    src: std.AutoHashMapUnmanaged(LocalId, []const u8),
) CloneError!std.AutoHashMapUnmanaged(LocalId, []const u8) {
    var out: std.AutoHashMapUnmanaged(LocalId, []const u8) = .empty;
    var iter = src.iterator();
    while (iter.next()) |entry| {
        const name_copy = try cloneBytes(allocator, entry.value_ptr.*);
        try out.put(allocator, entry.key_ptr.*, name_copy);
    }
    return out;
}

fn cloneDefaultValues(allocator: std.mem.Allocator, values: []const DefaultValue) CloneError![]const DefaultValue {
    if (values.len == 0) return &.{};
    const cloned = try allocator.alloc(DefaultValue, values.len);
    for (values, 0..) |value, index| {
        cloned[index] = try cloneDefaultValue(allocator, value);
    }
    return cloned;
}

pub const DefaultValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    nil,
};

pub const Param = struct {
    name: []const u8,
    type_expr: ZigType,
    /// Original TypeStore TypeId, preserved for list type detection.
    type_id: ?types_mod.TypeId = null,
};

fn cloneParams(allocator: std.mem.Allocator, params: []const Param) CloneError![]const Param {
    if (params.len == 0) return &.{};
    const cloned = try allocator.alloc(Param, params.len);
    for (params, 0..) |param, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, param.name),
            .type_expr = try cloneZigType(allocator, param.type_expr),
            .type_id = param.type_id,
        };
    }
    return cloned;
}

const OptionalDispatchCandidate = struct {
    struct_name: []const u8,
    struct_type_id: types_mod.TypeId,
    optional_type_id: ?types_mod.TypeId,
};

pub const Capture = struct {
    name: []const u8,
    type_expr: ZigType,
    ownership: hir_mod.Ownership,
};

fn cloneCaptures(allocator: std.mem.Allocator, captures: []const Capture) CloneError![]const Capture {
    if (captures.len == 0) return &.{};
    const cloned = try allocator.alloc(Capture, captures.len);
    for (captures, 0..) |capture, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, capture.name),
            .type_expr = try cloneZigType(allocator, capture.type_expr),
            .ownership = capture.ownership,
        };
    }
    return cloned;
}

pub const Block = struct {
    label: LabelId,
    instructions: []const Instruction,
};

fn cloneBlocks(allocator: std.mem.Allocator, blocks: []const Block) CloneError![]const Block {
    if (blocks.len == 0) return &.{};
    const cloned = try allocator.alloc(Block, blocks.len);
    for (blocks, 0..) |block, index| {
        cloned[index] = .{
            .label = block.label,
            .instructions = try cloneInstructions(allocator, block.instructions),
        };
    }
    return cloned;
}

// ============================================================
// Instructions (spec §19.2)
// ============================================================

pub const Instruction = union(enum) {
    // Constants
    const_int: ConstInt,
    const_float: ConstFloat,
    const_string: ConstString,
    const_bool: ConstBool,
    const_atom: ConstAtom,
    const_nil: LocalId,

    // Locals
    local_get: LocalGet,
    local_set: LocalSet,
    move_value: MoveValue,
    share_value: ShareValue,
    param_get: ParamGet,
    /// Phase C of the Phase 6 redux plan: produce a borrow alias of an
    /// ARC-managed source. Result is `.borrowed`. No retain on `dest`,
    /// no scope-exit destroy on `dest`. The arc_ownership pass produces
    /// this opcode by classifying a `.local_get` whose dest's only use
    /// is a borrowing-convention call argument or a borrow-only alias.
    /// Phase D's verifier ensures `dest` is not destroyed within its
    /// borrow scope and does not escape into owned storage.
    borrow_value: BorrowValue,
    /// Phase C of the Phase 6 redux plan: produce an independent owner
    /// from an ARC-managed source. Lowering emits a runtime retain on
    /// the source's cell. Result is `.owned`. Pairs with a scope-exit
    /// destroy (modeled as `.release` until Phase E renames). Produced
    /// by the arc_ownership pass when a `.local_get` flows into owned
    /// storage (struct/list/map/tuple init), is captured by a closure,
    /// or returns a borrowed parameter (return-source borrow promotion).
    copy_value: CopyValue,

    // Aggregates
    tuple_init: AggregateInit,
    list_init: ListInit,
    list_cons: ListCons,
    map_init: MapInit,
    struct_init: StructInit,
    union_init: UnionInit,
    /// Construction-site auto-boxing for protocol existentials
    /// (Phase 1.2.5.c). Wraps a concrete value as a
    /// `runtime.ProtocolBox` for the named protocol. See
    /// `BoxAsProtocol` for the contract and lowering shape.
    box_as_protocol: BoxAsProtocol,
    /// Consumption-site virtual dispatch for protocol existentials
    /// (Phase 1.2.5.d). Calls a protocol method on a `ProtocolBox`
    /// receiver by indirecting through the box's vtable slot. See
    /// `ProtocolDispatch` for the contract and lowering shape.
    protocol_dispatch: ProtocolDispatch,
    /// Consumption-site downcast for protocol existentials
    /// (Phase 1.2.5.d). Tests whether a `ProtocolBox` carries the
    /// named target concrete type, and on match recovers the inner
    /// value typed as that concrete struct. See `ProtocolBoxUnbox`
    /// for the contract and lowering shape.
    protocol_box_unbox: ProtocolBoxUnbox,
    enum_literal: EnumLiteral,
    field_get: FieldGet,
    field_set: FieldSet,
    index_get: IndexGet,
    list_len_check: ListLenCheck,
    list_get: ListGet,
    list_is_not_empty: ListIsNotEmpty,
    list_head: ListHeadTail,
    list_tail: ListHeadTail,
    map_has_key: MapHasKey,
    map_get: MapGet,

    // Arithmetic / logic
    binary_op: BinaryOp,
    unary_op: UnaryOp,

    // Calls
    call_direct: CallDirect,
    call_named: CallNamed,
    call_closure: CallClosure,
    call_dispatch: CallDispatch,
    call_builtin: CallBuiltin,
    tail_call: TailCall,
    /// Call a __try function variant (returns error union).
    /// Used in ~> catch basin pipe chains.
    try_call_named: TryCallNamed,
    /// Unwrap an error union result from try_call_named.
    /// On success: dest = unwrapped value.
    /// On error: dest = catch_value (handler result applied to the input that failed).
    error_catch: ErrorCatch,

    // Safety control
    set_safety: bool, // true = enable, false = disable

    // Control flow
    if_expr: IfExpr,
    guard_block: GuardBlock,
    case_block: CaseBlock,
    branch: Branch,
    cond_branch: CondBranch,
    switch_tag: SwitchTag,
    switch_literal: SwitchLiteral,
    switch_return: SwitchReturn,
    union_switch_return: UnionSwitchReturn,
    union_switch: UnionSwitch,
    optional_dispatch: OptionalDispatch,
    match_atom: MatchAtom,
    match_variant_tag: MatchVariantTag,
    variant_payload_get: VariantPayloadGet,
    match_int: MatchInt,
    match_float: MatchFloat,
    match_string: MatchString,
    match_type: MatchType,
    match_fail: MatchFail,
    match_error_return: MatchErrorReturn,
    ret: Return,
    cond_return: CondReturn,
    case_break: CaseBreak,
    jump: Jump,

    // Closures
    make_closure: MakeClosure,
    capture_get: CaptureGet,

    // Optional unwrap
    optional_unwrap: OptionalUnwrap,

    // Binary pattern matching
    bin_len_check: BinLenCheck,
    bin_read_int: BinReadInt,
    bin_read_float: BinReadFloat,
    bin_slice: BinSlice,
    bin_read_utf8: BinReadUtf8,
    bin_match_prefix: BinMatchPrefix,

    // Memory / ARC
    retain: Retain,
    release: Release,

    // Perceus reuse (Koka-inspired)
    reset: Reset,
    reuse_alloc: ReuseAlloc,

    // Numeric widening
    int_widen: NumericWiden,
    float_widen: NumericWiden,

    // Phi
    phi: Phi,

    // Debug info (Phase 0 — DWARF foundation)
    /// Marker for the start of a Zap source-level statement. Carries the
    /// Zap source `line` and `column` so the ZIR backend can emit a
    /// `dbg_stmt` ZIR instruction; the Zig fork's DWARF emitter projects
    /// those into the resulting binary's debug-line section, which is
    /// what lldb/gdb/addr2line/perf/samply consume to map machine
    /// addresses back to Zap source.
    dbg_stmt: DbgStmt,
    /// Marker for a named local-variable binding. Carries the Zap source
    /// identifier `name` and the `value` local that holds the binding,
    /// plus an `is_ptr` flag distinguishing pointer-bound locals (Zig
    /// `dbg_var_ptr`) from value-bound locals (`dbg_var_val`). The ZIR
    /// backend emits `dbg_var_val`/`dbg_var_ptr`, which preserves the
    /// Zap identifier in DWARF's `.debug_info` so debuggers display
    /// Zap-named locals instead of synthetic IR slot names.
    dbg_var: DbgVar,
};

fn cloneInstructions(allocator: std.mem.Allocator, instructions: []const Instruction) CloneError![]const Instruction {
    if (instructions.len == 0) return &.{};
    const cloned = try allocator.alloc(Instruction, instructions.len);
    for (instructions, 0..) |instruction, index| {
        cloned[index] = try cloneInstruction(allocator, instruction);
    }
    return cloned;
}

fn cloneInstruction(allocator: std.mem.Allocator, instruction: Instruction) CloneError!Instruction {
    return switch (instruction) {
        .const_int => |value| .{ .const_int = .{
            .dest = value.dest,
            .value = value.value,
            .type_hint = if (value.type_hint) |hint| try cloneZigType(allocator, hint) else null,
        } },
        .const_float => |value| .{ .const_float = .{
            .dest = value.dest,
            .value = value.value,
            .type_hint = if (value.type_hint) |hint| try cloneZigType(allocator, hint) else null,
        } },
        .const_string => |value| .{ .const_string = .{
            .dest = value.dest,
            .value = try cloneBytes(allocator, value.value),
        } },
        .const_bool,
        .const_nil,
        .local_get,
        .local_set,
        .move_value,
        .share_value,
        .param_get,
        .borrow_value,
        .copy_value,
        .field_set,
        .index_get,
        .binary_op,
        .unary_op,
        .error_catch,
        .set_safety,
        .branch,
        .cond_branch,
        .match_int,
        .match_float,
        .match_error_return,
        .ret,
        .cond_return,
        .case_break,
        .jump,
        .capture_get,
        .optional_unwrap,
        .bin_len_check,
        .bin_read_int,
        .bin_read_float,
        .bin_slice,
        .bin_read_utf8,
        .retain,
        .reset,
        .dbg_stmt,
        => instruction,
        .release => |value| .{ .release = .{
            .value = value.value,
            .kind = value.kind,
            .protocol_name = try cloneOptionalBytes(allocator, value.protocol_name),
        } },
        .dbg_var => |value| .{ .dbg_var = .{
            .name = try cloneBytes(allocator, value.name),
            .value = value.value,
            .is_ptr = value.is_ptr,
        } },
        .const_atom => |value| .{ .const_atom = .{
            .dest = value.dest,
            .value = try cloneBytes(allocator, value.value),
        } },
        .tuple_init => |value| .{ .tuple_init = .{
            .dest = value.dest,
            .elements = try clonePlainSlice(LocalId, allocator, value.elements),
            .component_types = if (value.component_types) |types| try cloneZigTypeSlice(allocator, types) else null,
            .reuse_token = value.reuse_token,
        } },
        .list_init => |value| .{ .list_init = .{
            .dest = value.dest,
            .elements = try clonePlainSlice(LocalId, allocator, value.elements),
            .element_type = try cloneZigType(allocator, value.element_type),
        } },
        .list_cons => |value| .{ .list_cons = .{
            .dest = value.dest,
            .head = value.head,
            .tail = value.tail,
            .element_type = try cloneZigType(allocator, value.element_type),
        } },
        .map_init => |value| .{ .map_init = .{
            .dest = value.dest,
            .entries = try clonePlainSlice(MapEntry, allocator, value.entries),
            .key_type = try cloneZigType(allocator, value.key_type),
            .value_type = try cloneZigType(allocator, value.value_type),
        } },
        .struct_init => |value| .{ .struct_init = .{
            .dest = value.dest,
            .type_name = try cloneBytes(allocator, value.type_name),
            .fields = try cloneStructFieldInits(allocator, value.fields),
            .reuse_token = value.reuse_token,
        } },
        .union_init => |value| .{ .union_init = .{
            .dest = value.dest,
            .union_type = try cloneBytes(allocator, value.union_type),
            .variant_name = try cloneBytes(allocator, value.variant_name),
            .value = value.value,
            .reuse_token = value.reuse_token,
        } },
        .box_as_protocol => |value| .{ .box_as_protocol = .{
            .dest = value.dest,
            .value = value.value,
            .protocol_name = try cloneBytes(allocator, value.protocol_name),
            .target_type_name = try cloneBytes(allocator, value.target_type_name),
            .value_zig_type = try cloneZigType(allocator, value.value_zig_type),
        } },
        .protocol_dispatch => |value| .{ .protocol_dispatch = .{
            .dest = value.dest,
            .receiver = value.receiver,
            .protocol_name = try cloneBytes(allocator, value.protocol_name),
            .method_name = try cloneBytes(allocator, value.method_name),
            .method_index = value.method_index,
            .arity = value.arity,
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
            .return_type = try cloneZigType(allocator, value.return_type),
        } },
        .protocol_box_unbox => |value| .{ .protocol_box_unbox = .{
            .dest = value.dest,
            .box = value.box,
            .protocol_name = try cloneBytes(allocator, value.protocol_name),
            .target_type_name = try cloneBytes(allocator, value.target_type_name),
            .target_zig_type = try cloneZigType(allocator, value.target_zig_type),
        } },
        .enum_literal => |value| .{ .enum_literal = .{
            .dest = value.dest,
            .type_name = try cloneBytes(allocator, value.type_name),
            .variant = try cloneBytes(allocator, value.variant),
        } },
        .field_get => |value| .{ .field_get = .{
            .dest = value.dest,
            .object = value.object,
            .field = try cloneBytes(allocator, value.field),
            .struct_type = try cloneOptionalBytes(allocator, value.struct_type),
        } },
        .list_len_check => |value| .{ .list_len_check = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .expected_len = value.expected_len,
            .minimum = value.minimum,
            .element_type = try cloneZigType(allocator, value.element_type),
            .via_helper = value.via_helper,
        } },
        .list_get => |value| .{ .list_get = .{
            .dest = value.dest,
            .list = value.list,
            .index = value.index,
            .element_type = try cloneZigType(allocator, value.element_type),
            .via_helper = value.via_helper,
        } },
        .list_is_not_empty => |value| .{ .list_is_not_empty = .{
            .dest = value.dest,
            .list = value.list,
            .element_type = try cloneZigType(allocator, value.element_type),
            .via_helper = value.via_helper,
        } },
        .list_head => |value| .{ .list_head = try cloneListHeadTail(allocator, value) },
        .list_tail => |value| .{ .list_tail = try cloneListHeadTail(allocator, value) },
        .map_has_key => |value| .{ .map_has_key = .{
            .dest = value.dest,
            .map = value.map,
            .key = value.key,
            .key_type = try cloneZigType(allocator, value.key_type),
            .value_type = try cloneZigType(allocator, value.value_type),
        } },
        .map_get => |value| .{ .map_get = .{
            .dest = value.dest,
            .map = value.map,
            .key = value.key,
            .default = value.default,
            .key_type = try cloneZigType(allocator, value.key_type),
            .value_type = try cloneZigType(allocator, value.value_type),
        } },
        .call_direct => |value| .{ .call_direct = .{
            .dest = value.dest,
            .function = value.function,
            .clause_index = value.clause_index,
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
        } },
        .call_named => |value| .{ .call_named = .{
            .dest = value.dest,
            .name = try cloneBytes(allocator, value.name),
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
        } },
        .call_closure => |value| .{ .call_closure = .{
            .dest = value.dest,
            .callee = value.callee,
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
            .return_type = try cloneZigType(allocator, value.return_type),
        } },
        .call_dispatch => |value| .{ .call_dispatch = .{
            .dest = value.dest,
            .group_id = value.group_id,
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
        } },
        .call_builtin => |value| .{ .call_builtin = .{
            .dest = value.dest,
            .name = try cloneBytes(allocator, value.name),
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
            .result_type = try cloneZigType(allocator, value.result_type),
        } },
        .tail_call => |value| .{ .tail_call = .{
            .name = try cloneBytes(allocator, value.name),
            .args = try clonePlainSlice(LocalId, allocator, value.args),
        } },
        .try_call_named => |value| .{ .try_call_named = .{
            .dest = value.dest,
            .name = try cloneBytes(allocator, value.name),
            .args = try clonePlainSlice(LocalId, allocator, value.args),
            .arg_modes = try clonePlainSlice(ValueMode, allocator, value.arg_modes),
            .input_local = value.input_local,
            .handler_instrs = try cloneInstructions(allocator, value.handler_instrs),
            .handler_result = value.handler_result,
            .success_instrs = try cloneInstructions(allocator, value.success_instrs),
            .success_result = value.success_result,
            .payload_local = value.payload_local,
        } },
        .if_expr => |value| .{ .if_expr = .{
            .dest = value.dest,
            .condition = value.condition,
            .then_instrs = try cloneInstructions(allocator, value.then_instrs),
            .then_result = value.then_result,
            .else_instrs = try cloneInstructions(allocator, value.else_instrs),
            .else_result = value.else_result,
        } },
        .guard_block => |value| .{ .guard_block = .{
            .condition = value.condition,
            .body = try cloneInstructions(allocator, value.body),
        } },
        .case_block => |value| .{ .case_block = .{
            .dest = value.dest,
            .pre_instrs = try cloneInstructions(allocator, value.pre_instrs),
            .arms = try cloneIrCaseArms(allocator, value.arms),
            .default_instrs = try cloneInstructions(allocator, value.default_instrs),
            .default_result = value.default_result,
        } },
        .switch_tag => |value| .{ .switch_tag = .{
            .scrutinee = value.scrutinee,
            .cases = try cloneTagCases(allocator, value.cases),
            .default = value.default,
        } },
        .switch_literal => |value| .{ .switch_literal = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .cases = try cloneLitCases(allocator, value.cases),
            .default_instrs = try cloneInstructions(allocator, value.default_instrs),
            .default_result = value.default_result,
        } },
        .switch_return => |value| .{ .switch_return = .{
            .scrutinee_param = value.scrutinee_param,
            .cases = try cloneReturnCases(allocator, value.cases),
            .default_instrs = try cloneInstructions(allocator, value.default_instrs),
            .default_result = value.default_result,
        } },
        .union_switch_return => |value| .{ .union_switch_return = .{
            .scrutinee_param = value.scrutinee_param,
            .cases = try cloneUnionCases(allocator, value.cases),
        } },
        .union_switch => |value| .{ .union_switch = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .cases = try cloneUnionCases(allocator, value.cases),
            .else_instrs = try cloneInstructions(allocator, value.else_instrs),
            .else_result = value.else_result,
            .has_else = value.has_else,
        } },
        .optional_dispatch => |value| .{ .optional_dispatch = .{
            .scrutinee_param = value.scrutinee_param,
            .payload_local = value.payload_local,
            .nil_instrs = try cloneInstructions(allocator, value.nil_instrs),
            .nil_result = value.nil_result,
            .struct_instrs = try cloneInstructions(allocator, value.struct_instrs),
            .struct_result = value.struct_result,
        } },
        .match_atom => |value| .{ .match_atom = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .atom_name = try cloneBytes(allocator, value.atom_name),
            .skip_type_check = value.skip_type_check,
        } },
        .match_variant_tag => |value| .{ .match_variant_tag = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .variant_name = try cloneBytes(allocator, value.variant_name),
        } },
        .variant_payload_get => |value| .{ .variant_payload_get = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .variant_name = try cloneBytes(allocator, value.variant_name),
        } },
        .match_string => |value| .{ .match_string = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .expected = try cloneBytes(allocator, value.expected),
            .skip_type_check = value.skip_type_check,
        } },
        .match_type => |value| .{ .match_type = .{
            .dest = value.dest,
            .scrutinee = value.scrutinee,
            .expected_type = try cloneZigType(allocator, value.expected_type),
            .skip_type_check = value.skip_type_check,
            .expected_arity = value.expected_arity,
        } },
        .match_fail => |value| .{ .match_fail = .{
            .message = try cloneBytes(allocator, value.message),
            .message_local = value.message_local,
        } },
        .make_closure => |value| .{ .make_closure = .{
            .dest = value.dest,
            .function = value.function,
            .captures = try clonePlainSlice(LocalId, allocator, value.captures),
        } },
        .bin_match_prefix => |value| .{ .bin_match_prefix = .{
            .dest = value.dest,
            .source = value.source,
            .expected = try cloneBytes(allocator, value.expected),
        } },
        .reuse_alloc => |value| .{ .reuse_alloc = .{
            .dest = value.dest,
            .token = value.token,
            .constructor_tag = value.constructor_tag,
            .dest_type = try cloneZigType(allocator, value.dest_type),
        } },
        .int_widen => |value| .{ .int_widen = .{
            .dest = value.dest,
            .source = value.source,
            .dest_type = try cloneZigType(allocator, value.dest_type),
        } },
        .float_widen => |value| .{ .float_widen = .{
            .dest = value.dest,
            .source = value.source,
            .dest_type = try cloneZigType(allocator, value.dest_type),
        } },
        .phi => |value| .{ .phi = .{
            .dest = value.dest,
            .sources = try clonePlainSlice(PhiSource, allocator, value.sources),
        } },
    };
}

pub const ConstInt = struct {
    dest: LocalId,
    value: i64,
    type_hint: ?ZigType = null,
};

/// Payload for the `.dbg_stmt` instruction. The `line` and `column`
/// are the **zero-based** Zap source coordinates of the statement that
/// is about to execute. The ZIR builder converts them to the
/// fork's one-based DWARF representation when emitting.
///
/// Statement boundaries are determined during HIR -> IR lowering by
/// the IR builder's `lowerBlock`. Every `hir.Stmt` (expression
/// statement, local-set, or nested function declaration) emits one
/// `.dbg_stmt` immediately before its own instructions, so any
/// runtime trap inside that statement (panic, arithmetic overflow,
/// nil-deref, etc.) maps back to the statement's source line — not
/// to the previous statement's line or the enclosing function's
/// header line.
pub const DbgStmt = struct {
    line: u32,
    column: u32,
};

/// Payload for the `.dbg_var` instruction. The `name` is the Zap
/// source identifier of a named local binding (e.g., the LHS of
/// `x = expr`). The `value` is the IR local that holds the binding
/// after lowering. `is_ptr` is `true` when the local stores a pointer
/// (lowered as Zig `dbg_var_ptr`), `false` when the local stores a
/// value (lowered as Zig `dbg_var_val`); Zap bindings are values, so
/// the default is `false`. The ZIR backend interns `name` into the
/// fork's string table and emits the corresponding `dbg_var_*` ZIR
/// instruction, which Sema/AIR propagate into DWARF `.debug_info` so
/// debuggers display Zap-named locals instead of synthetic slot ids.
pub const DbgVar = struct {
    name: []const u8,
    value: LocalId,
    is_ptr: bool = false,
};

pub const ConstFloat = struct {
    dest: LocalId,
    value: f64,
    type_hint: ?ZigType = null,
};

pub const ConstString = struct {
    dest: LocalId,
    value: []const u8,
};

pub const ConstBool = struct {
    dest: LocalId,
    value: bool,
};

pub const ConstAtom = struct {
    dest: LocalId,
    value: []const u8,
};

pub const LocalGet = struct {
    dest: LocalId,
    source: LocalId,
};

/// Payload for the `.borrow_value` instruction. Produced by the
/// arc_ownership pass when classifying a `.local_get` whose
/// destination is used only as a borrow alias (e.g., a borrowing
/// call argument). Lowers to a plain assignment in ZIR with no
/// retain on `dest`. The borrow is valid until the enclosing
/// borrow scope ends; Phase D's verifier checks no destroy fires
/// on `dest` within the scope.
pub const BorrowValue = struct {
    dest: LocalId,
    source: LocalId,
};

/// Payload for the `.copy_value` instruction. Produced by the
/// arc_ownership pass when classifying a `.local_get` whose
/// destination flows into owned storage, escapes via a closure
/// capture, or promotes a borrowed parameter to ownership at a
/// `ret` site. Lowers to assignment + `retainAny` in ZIR. The
/// caller is responsible for matching this with a scope-exit
/// destroy on `dest` (drop insertion handles this today).
pub const CopyValue = struct {
    dest: LocalId,
    source: LocalId,
};

pub const LocalSet = struct {
    dest: LocalId,
    value: LocalId,
};

pub const MoveValue = struct {
    dest: LocalId,
    source: LocalId,
};

/// Ownership semantics of a `share_value` instruction. Distinguishes
/// retain-style sharing (two live references after the share) from
/// consume-style transfer (caller relinquishes ownership). The default
/// is `.retain` so existing IR sites stay byte-identical until the ARC
/// liveness pass (phase 4) explicitly upgrades selected sites.
pub const ShareMode = enum {
    /// Default. Emits assign + retain. Caller's local stays live;
    /// callee's slot gets an independent ownership reference.
    /// Pairs with a release at scope exit (unless suppressed by
    /// `arc_share_skipped` from the escape lattice).
    retain,
    /// Caller relinquishes the retain bump at the share site because
    /// the source local is at its last use. Emits assign only — no
    /// retain. The post-call `.release{value=dest}` IR instruction
    /// still fires: callees BORROW their arguments, they do not
    /// internally decrement the cell. The scope-exit release on the
    /// source local (emitted by the drop-insertion pass) is also still
    /// emitted; it balances the original allocation rather than the
    /// share. Net effect of consume vs retain: -1 retain on the call
    /// path. Ownership transfers naturally because the source's last
    /// use means no further reads accumulate retains the post-call
    /// release would otherwise need to pair with.
    consume,
};

pub const ShareValue = struct {
    dest: LocalId,
    source: LocalId,
    mode: ShareMode = .retain,
};

pub const ParamGet = struct {
    dest: LocalId,
    index: u32,
};

pub const AggregateInit = struct {
    dest: LocalId,
    elements: []const LocalId,
    /// Static component types (one per element) when the tuple's type is
    /// known at IR build time. Used by the ZIR backend so that components
    /// promoted to `Term` (e.g. heterogeneous keyword-list pair values
    /// like `{Atom, Term}`) wrap concrete element values via `Term.from`.
    /// `null` for tuples where component types are not statically known.
    component_types: ?[]const ZigType = null,
    /// Perceus reuse: when set, this tuple is constructed by reusing the
    /// allocation referenced by the token's LocalId rather than allocating
    /// fresh. The token is produced by a preceding `.reset` IR instruction
    /// whose `dest` matches this value. `arc_materialize.materializeReusePairs`
    /// sets this field when the Perceus analyzer paired this construction
    /// site with an upstream deconstruction site.
    reuse_token: ?LocalId = null,
};

pub const MapInit = struct {
    dest: LocalId,
    entries: []const MapEntry,
    key_type: ZigType = .atom,
    value_type: ZigType = .i64,
};

pub const MapEntry = struct {
    key: LocalId,
    value: LocalId,
};

pub const StructInit = struct {
    dest: LocalId,
    type_name: []const u8,
    fields: []const StructFieldInit,
    /// Perceus reuse: see `AggregateInit.reuse_token` for the contract.
    reuse_token: ?LocalId = null,
};

/// Payload for the `.box_as_protocol` instruction (Phase 1.2.5.c).
/// Construction-site auto-boxing: wrap a concrete `target_type_name`
/// value in a `runtime.ProtocolBox` carrying the `protocol_name`'s
/// vtable. Emitted whenever a concrete value flows into a slot
/// typed as the corresponding `protocol_box(protocol_name)` —
/// struct fields, union variant payloads, function-call arguments,
/// return values, and explicitly-typed variable assignments.
///
/// Lowering contract (Phase 1.2.5.c ZIR):
///
///   1. Heap-allocate the inner value via
///      `zap_runtime.ArcRuntime.allocAny(InnerT, allocator, value)`.
///      The resulting `*InnerT` is the box's `data_ptr` (after
///      `@ptrCast` to `?*anyopaque`).
///   2. Look up `<Protocol>VTable_for_<TargetMangled>` (resolved
///      from the IR's `protocol_vtable_instance_def` TypeDefs via
///      `findProtocolImplVTable`); its address (`@ptrCast` to
///      `?*const anyopaque`) becomes the box's `vtable`.
///   3. Emit a `runtime.ProtocolBox{ .data_ptr = ..., .vtable = ... }`
///      struct literal as the instruction's result.
///
/// ARC: the inner allocation is the box's owning reference. Box
/// release runs the vtable's synthetic `__drop__` slot, which calls
/// `ArcRuntime.releaseAny(InnerT, allocator, inner_ptr)` to free
/// the inner before the box itself is reclaimed.
pub const BoxAsProtocol = struct {
    /// Destination local that receives the `runtime.ProtocolBox`
    /// value. Typed `.protocol_box(protocol_name)` in the ZIR-side
    /// inference tables.
    dest: LocalId,
    /// Source local carrying the concrete value being boxed. The
    /// IR construction-site detector verifies that this local's
    /// HIR/Zig type matches `target_type_name` before emitting the
    /// box; the ZIR backend reads it back out via the local-type
    /// tables to drive the `allocAny` type parameter.
    value: LocalId,
    /// Bare protocol name (e.g. `"Error"`). Used to find the
    /// matching `<Protocol>VTable_for_<Target>` instance constant
    /// at lowering time and to type `dest` as
    /// `.protocol_box(protocol_name)`.
    protocol_name: []const u8,
    /// Mangled target type name as it appears on the vtable
    /// instance constant's suffix (`MyError` for a concrete impl,
    /// `Box_i64` for a parametric impl specialization). The
    /// canonical source is the inner's `ZigType.struct_ref` payload
    /// (which `typeIdMangledName`-style mangling produces upstream)
    /// — the IR layer doesn't re-derive it because the same name
    /// drives the vtable-instance lookup and the inner's `@import`
    /// path at the ZIR layer.
    target_type_name: []const u8,
    /// The concrete Zig type of the inner value, used by the ZIR
    /// backend as the `T` in `ArcRuntime.allocAny(T, allocator,
    /// value)` and `releaseAny(T, allocator, ptr)`. Captured at
    /// box-emission time so the ZIR lowering never has to re-walk
    /// the type tables.
    value_zig_type: ZigType,
};

/// Payload for the `.protocol_dispatch` instruction (Phase 1.2.5.d).
/// Consumption-site virtual dispatch: call a protocol method on a
/// `runtime.ProtocolBox` by reading the matching vtable slot and
/// invoking the slot's function pointer with the box's `data_ptr`
/// as the implicit receiver. Emitted whenever HIR sees
/// `Protocol.method(receiver, ...)` where `receiver` is statically
/// typed `.protocol_box(<Protocol>)`.
///
/// Lowering contract (Phase 1.2.5.d ZIR):
///
///   1. Emit a call to the synthetic per-protocol dispatcher
///      function `@import("<Protocol>VTable").dispatch_<method>(box,
///      arg0, arg1, ...)`. The dispatcher (emitted alongside the
///      vtable struct in `<Protocol>VTable`'s source file) does the
///      `@ptrCast(@alignCast(box.vtable.?))` recovery and invokes
///      the `vt.<method>(box.data_ptr, args...)` indirect call.
///   2. The per-protocol dispatcher's return type is the method's
///      declared return type — recorded in the IR op so the ZIR
///      backend knows how to type the result local.
///
/// ARC: the dispatched method runs against the inner value through
/// the box; ownership of the box itself is unchanged. Argument
/// retain/release pairing is governed by the receiver's existing
/// ARC discipline (the box is `.borrowed` at the dispatch site by
/// default; the trailing scope-exit drop or explicit move sites
/// own the box's release).
pub const ProtocolDispatch = struct {
    /// Destination local that receives the method's return value.
    /// When the method returns `void`, the dest still receives an
    /// IR placeholder local so downstream passes can track the
    /// call site uniformly — the ZIR backend ignores the local
    /// for void-returning calls (same shape every other IR call
    /// op uses).
    dest: LocalId,
    /// The `runtime.ProtocolBox`-typed receiver local. Typed
    /// `.protocol_box(protocol_name)` in the IR's local-type table.
    receiver: LocalId,
    /// Bare protocol name (e.g. `"Error"`). Drives the
    /// `@import("<Protocol>VTable")` cast and the dispatcher-helper
    /// name.
    protocol_name: []const u8,
    /// Protocol method name (matches a slot on the
    /// `<Protocol>VTable` struct emitted by 1.2.5.a). Used as
    /// `dispatch_<method>` in the per-protocol dispatcher helper.
    method_name: []const u8,
    /// Zero-based index of the slot in the protocol's declaration
    /// order. The vtable struct lays out fields in this order;
    /// recording the index here lets verifier passes and downstream
    /// analysis cross-check the (protocol, method) pair against the
    /// `ProtocolVTableDef` without re-scanning the method list.
    method_index: u32,
    /// Total method arity including the implicit receiver. Mirrors
    /// `ProtocolVTableMethod.arity`. Recorded for symmetry with
    /// other IR call ops and for verifier checks.
    arity: u32,
    /// Non-receiver argument locals in source order. Length always
    /// equals `arity - 1`. The ZIR backend prepends the box itself
    /// as the dispatcher helper's first argument; the args slice
    /// supplies the remaining positional parameters.
    args: []const LocalId,
    /// Per-arg ownership mode. Mirrors `CallNamed.arg_modes`: the
    /// ARC pass uses this to decide retain/release semantics for
    /// arguments crossing the dispatch boundary.
    arg_modes: []const ValueMode,
    /// The protocol method's return type — captured at IR emit
    /// time from the protocol declaration. Used by the ZIR backend
    /// to type the destination local and by downstream IR analyses
    /// to track the call's value flow.
    return_type: ZigType,
};

/// Payload for the `.protocol_box_unbox` instruction (Phase 1.2.5.d).
/// Consumption-site downcast: extract the concrete inner value from
/// a `runtime.ProtocolBox` when its vtable matches the named
/// per-impl instance constant. Emitted by HIR's pattern-match
/// compilation when a downcast pattern `inner :: Target` is matched
/// against a scrutinee whose static type is
/// `.protocol_box(<Protocol>)`.
///
/// Lowering contract (Phase 1.2.5.d ZIR):
///
///   1. The pattern-match compiler emits a `guard_block` whose
///      condition is
///      `@import("<Protocol>VTable_for_<Target>").vtable_eq(box)` —
///      a synthetic per-impl helper that pointer-compares
///      `box.vtable` against the address of the impl's vtable
///      instance constant. Returns `bool`.
///   2. When the guard fires (vtable matches), the arm body's
///      `protocol_box_unbox` lowering calls
///      `@import("<Protocol>VTable_for_<Target>").unbox(box)` —
///      a synthetic per-impl helper that does
///      `@ptrCast(@alignCast(box.data_ptr.?)).*` and returns the
///      typed concrete value (by-value). The box still owns the
///      heap cell, so its scope-exit drop can free the slot
///      independently of the unbox.
///   3. When the guard is false the arm's body is skipped — the
///      match-arm machinery routes control flow to the next case
///      arm before consulting the unbox dest. Both synthetic
///      helpers (`vtable_eq`, `unbox`) are emitted alongside the
///      per-impl vtable instance constant in
///      `emitProtocolVTableInstanceSourceFile`.
///
/// **Exhaustiveness rule.** Pattern matching against a
/// `protocol_box(P)` scrutinee is fundamentally OPEN: any impl
/// registered for `P` (now or in a future module load) is a
/// possible concrete inner type. Static exhaustiveness over an
/// open existential is undecidable, so a match expression whose
/// scrutinee is `protocol_box(P)` requires a `_` catch-all arm to
/// be considered exhaustive — mirroring Rust's rule for matches
/// over `Box<dyn Trait>`. The HIR pattern-match elaborator emits
/// a non-exhaustiveness warning when this catch-all is missing
/// (warning rather than error so the user can opt out via
/// `@unsafe_open_match`-style suppression if needed; mechanism
/// added with the typed-bind parser surface).
///
/// **Status — IR/ZIR ready; AST/HIR/parser surface deferred.** The
/// IR op, ZIR lowering, and the synthetic `vtable_eq` / `unbox`
/// per-impl helpers are in place and exercised through the round-
/// trip clone test (`protocol_box_unbox instruction round-trips
/// through cloneInstruction`). The frontend surface — extending
/// `BindPattern` with an optional `type_annotation` and the
/// pattern-elaborator to recognise the downcast shape against
/// `.protocol_box(<P>)` scrutinees — is the natural follow-up for
/// 1.2.5.e (alongside the `cause :: Option(Error)` field that
/// motivates the downcast semantics in the first place). The IR
/// op is ready to be consumed the moment the frontend emits it.
pub const ProtocolBoxUnbox = struct {
    /// Destination local that receives the concrete inner value
    /// when the guard fires. Typed `.struct_ref(target_type_name)`
    /// in the IR's local-type table.
    dest: LocalId,
    /// Local holding the `runtime.ProtocolBox` scrutinee. Typed
    /// `.protocol_box(protocol_name)`.
    box: LocalId,
    /// Bare protocol name (e.g. `"Error"`). Drives the
    /// `@import("<Protocol>VTable")` lookup for the
    /// `vtable_eq_<Target>` and `unbox_<Target>` helpers.
    protocol_name: []const u8,
    /// Mangled target concrete type name as it appears on the
    /// vtable instance constant's suffix (`MyError` for a concrete
    /// impl, `Box_i64` for a parametric impl specialization). Same
    /// shape `BoxAsProtocol.target_type_name` uses.
    target_type_name: []const u8,
    /// The concrete Zig type the unboxed value is typed as.
    /// Captured here so downstream analyses don't need to re-walk
    /// type tables to recover it. Always `.struct_ref(target_type_name)`
    /// in practice but recorded structurally to keep the
    /// invariant local.
    target_zig_type: ZigType,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: LocalId,
};

fn cloneStructFieldInits(allocator: std.mem.Allocator, fields: []const StructFieldInit) CloneError![]const StructFieldInit {
    if (fields.len == 0) return &.{};
    const cloned = try allocator.alloc(StructFieldInit, fields.len);
    for (fields, 0..) |field, index| {
        cloned[index] = .{
            .name = try cloneBytes(allocator, field.name),
            .value = field.value,
        };
    }
    return cloned;
}

pub const UnionInit = struct {
    dest: LocalId,
    union_type: []const u8,
    variant_name: []const u8,
    value: LocalId,
    /// Perceus reuse: see `AggregateInit.reuse_token` for the contract.
    reuse_token: ?LocalId = null,
};

pub const EnumLiteral = struct {
    dest: LocalId,
    type_name: []const u8,
    variant: []const u8,
};

pub const FieldGet = struct {
    dest: LocalId,
    object: LocalId,
    field: []const u8,
    /// Struct type name owning the field, when known. Used by
    /// the ZIR emitter to look up `FieldStorage` for indirect-
    /// storage auto-deref. `null` when the receiver's struct
    /// type isn't statically known (e.g. `term`/`any` or open
    /// generics).
    struct_type: ?[]const u8 = null,
};

pub const FieldSet = struct {
    object: LocalId,
    field: []const u8,
    value: LocalId,
};

pub const IndexGet = struct {
    dest: LocalId,
    object: LocalId,
    index: u32,
    /// When set, the extracted slot's runtime type is `zap_runtime.Term`
    /// but the IR's static expected type is concrete (the declared slot
    /// type from the parent's static tuple shape). The ZIR backend
    /// inserts a `Term.toCoerced(value, default)` to recover the concrete
    /// type. Used when patterns over heterogeneous keyword lists extract
    /// values from `tuple{Atom, Term}` slots where the user expected a
    /// concrete type per the declared param signature.
    coerce_term_to: ZigType = .any,
};

pub const ListInit = struct {
    dest: LocalId,
    elements: []const LocalId,
    element_type: ZigType = .i64,
};

pub const ListCons = struct {
    dest: LocalId,
    head: LocalId,
    tail: LocalId,
    element_type: ZigType = .i64,
};

pub const ListLenCheck = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_len: u32,
    minimum: bool = false,
    element_type: ZigType = .i64,
    /// Route through `listLength(anytype)` helper instead of
    /// `List(element_type).length(...)`. Set when `scrutinee` is
    /// param-backed (see ListGet.via_helper for rationale).
    via_helper: bool = false,
};

pub const ListGet = struct {
    dest: LocalId,
    list: LocalId,
    index: u32,
    element_type: ZigType = .i64,
    /// When true, the ZIR backend routes through the type-derived
    /// `listGet(anytype, index)` helper instead of
    /// `List(element_type).get(list, index)`. Set when `list` is
    /// param-backed: the runtime element type may diverge from the
    /// declared type (e.g. a function declared `[{Atom, i64}]` is
    /// passed a heterogeneous keyword list whose runtime element
    /// type is `[{Atom, Term}]`). The helper's `anytype` signature
    /// reads the actual element type from `@TypeOf(list)`.
    via_helper: bool = false,
};

pub const ListIsNotEmpty = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
    /// Route through `listIsEmpty(anytype)` helper instead of
    /// `List(element_type).isEmpty(...)`. Set when `list` is
    /// param-backed (see ListGet.via_helper for rationale).
    via_helper: bool = false,
};

pub const ListHeadTail = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
    /// For `.list_tail`, the zero-based start offset for the returned
    /// suffix. Defaults to one for ordinary tail access; multi-head
    /// list patterns set this to the number of heads so the rest is
    /// materialized by one slice instead of chained tail clones.
    start_index: u32 = 1,
    /// Route through `listGetHead(anytype)` / `listGetTail(anytype)`
    /// helper instead of the typed `List(element_type)` method.
    /// Set when `list` is param-backed (see ListGet.via_helper).
    via_helper: bool = false,
    /// For `.list_tail`, consume a proven-unique source list by
    /// lowering to `slice_owned_unchecked` instead of cloning the
    /// suffix. Set only by the ARC/uniqueness rewrite after last-use
    /// and uniqueness checks pass.
    consume_source: bool = false,
};

fn cloneListHeadTail(allocator: std.mem.Allocator, value: ListHeadTail) CloneError!ListHeadTail {
    return .{
        .dest = value.dest,
        .list = value.list,
        .element_type = try cloneZigType(allocator, value.element_type),
        .start_index = value.start_index,
        .via_helper = value.via_helper,
        .consume_source = value.consume_source,
    };
}

pub const MapHasKey = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
    /// Type of map keys (used by ZIR to look up the right `Map(K, V)` cell).
    key_type: ZigType = .atom,
    /// Type of map values (carried for symmetry; not strictly required by `hasKey`).
    value_type: ZigType = .i64,
};

pub const MapGet = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
    default: LocalId,
    /// Type of map keys (used by ZIR to look up the right `Map(K, V)` cell).
    key_type: ZigType = .atom,
    /// Type of map values (used by ZIR to look up the right `Map(K, V)` cell).
    value_type: ZigType = .i64,
};

pub const GuardBlock = struct {
    condition: LocalId,
    body: []const Instruction,
};

pub const CaseBreak = struct {
    value: ?LocalId,
};

pub const CaseBlock = struct {
    dest: LocalId,
    pre_instrs: []const Instruction, // tuple arm guards (emit before regular arms)
    arms: []const IrCaseArm,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const IrCaseArm = struct {
    cond_instrs: []const Instruction,
    condition: LocalId,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

fn cloneIrCaseArms(allocator: std.mem.Allocator, arms: []const IrCaseArm) CloneError![]const IrCaseArm {
    if (arms.len == 0) return &.{};
    const cloned = try allocator.alloc(IrCaseArm, arms.len);
    for (arms, 0..) |arm, index| {
        cloned[index] = .{
            .cond_instrs = try cloneInstructions(allocator, arm.cond_instrs),
            .condition = arm.condition,
            .body_instrs = try cloneInstructions(allocator, arm.body_instrs),
            .result = arm.result,
        };
    }
    return cloned;
}

pub const IfExpr = struct {
    dest: LocalId,
    condition: LocalId,
    then_instrs: []const Instruction,
    then_result: ?LocalId,
    else_instrs: []const Instruction,
    else_result: ?LocalId,
};

pub const BinaryOp = struct {
    dest: LocalId,
    op: Op,
    lhs: LocalId,
    rhs: LocalId,
    result_type: ZigType = .any,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        rem_op,
        eq,
        neq,
        string_eq,
        string_neq,
        lt,
        gt,
        lte,
        gte,
        bool_and,
        bool_or,
        concat,
        in_list,
        in_range,
    };
};

pub const UnaryOp = struct {
    dest: LocalId,
    op: Op,
    operand: LocalId,

    pub const Op = enum {
        negate,
        bool_not,
    };
};

pub const CallDirect = struct {
    dest: LocalId,
    function: FunctionId,
    clause_index: ?u32 = null,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const CallNamed = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const TailCall = struct {
    name: []const u8,
    args: []const LocalId,
};

pub const CallClosure = struct {
    dest: LocalId,
    callee: LocalId,
    args: []const LocalId,
    arg_modes: []const ValueMode,
    return_type: ZigType,
};

pub const CallDispatch = struct {
    dest: LocalId,
    group_id: u32,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const CallBuiltin = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
    arg_modes: []const ValueMode,
    result_type: ZigType = .any,
};

/// Call a __try function variant. The result is an error union:
/// error{NoMatchingClause}!ReturnType.
///
/// Lowering invariant: the catch-basin pipeline is short-circuited at the
/// FIRST failing dispatched step. To express that without forcing a
/// `ret` (which would hijack the enclosing function's return), each
/// `try_call_named` carries the REST of the pipe in `success_instrs` /
/// `success_result`. The ZIR backend lowers the instruction as a single
/// if-else block whose value is the catch-basin expression value:
///   * then-branch: unwrap payload, run `success_instrs`, yield
///     `success_result` (which itself may be the dest of a nested
///     try_call_named for deeper pipelines).
///   * else-branch: run `handler_instrs`, yield `handler_result`.
/// When `success_instrs` is empty, the success value is simply the
/// unwrapped payload — the simple terminal-step case.
pub const TryCallNamed = struct {
    dest: LocalId, // holds the optional result (?ReturnType)
    name: []const u8, // the __try function name (already suffixed)
    args: []const LocalId,
    arg_modes: []const ValueMode,
    input_local: LocalId, // the pipe input — passed to handler on null
    handler_instrs: []const Instruction, // handler body instructions
    handler_result: ?LocalId, // handler result local
    /// Instructions to run in the success branch AFTER unwrapping the
    /// optional payload. When empty the success value is the payload itself.
    success_instrs: []const Instruction = &.{},
    /// Local that holds the value of the success branch after
    /// `success_instrs` runs. When `null`, the unwrapped payload is used
    /// directly (terminal step in the pipe).
    success_result: ?LocalId = null,
    /// Local that the unwrapped payload is bound to so that
    /// `success_instrs` can reference it. When `null`, the success
    /// branch does not need access to the payload.
    payload_local: ?LocalId = null,
};

/// Unwrap an error union from try_call_named.
/// dest = if source is success: unwrapped value, else: catch_value.
pub const ErrorCatch = struct {
    dest: LocalId, // the final unwrapped result
    source: LocalId, // the error union (from try_call_named)
    catch_value: LocalId, // value to use on error (handler result for the failed input)
};

pub const Branch = struct {
    target: LabelId,
};

pub const CondBranch = struct {
    condition: LocalId,
    then_target: LabelId,
    else_target: LabelId,
};

pub const SwitchTag = struct {
    scrutinee: LocalId,
    cases: []const TagCase,
    default: LabelId,
};

pub const TagCase = struct {
    tag: []const u8,
    target: LabelId,
};

fn cloneTagCases(allocator: std.mem.Allocator, cases: []const TagCase) CloneError![]const TagCase {
    if (cases.len == 0) return &.{};
    const cloned = try allocator.alloc(TagCase, cases.len);
    for (cases, 0..) |case, index| {
        cloned[index] = .{
            .tag = try cloneBytes(allocator, case.tag),
            .target = case.target,
        };
    }
    return cloned;
}

pub const SwitchLiteral = struct {
    dest: LocalId,
    scrutinee: LocalId,
    cases: []const LitCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const LitCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

fn cloneLiteralValue(allocator: std.mem.Allocator, value: LiteralValue) CloneError!LiteralValue {
    return switch (value) {
        .string => |string| .{ .string = try cloneBytes(allocator, string) },
        else => value,
    };
}

fn cloneLitCases(allocator: std.mem.Allocator, cases: []const LitCase) CloneError![]const LitCase {
    if (cases.len == 0) return &.{};
    const cloned = try allocator.alloc(LitCase, cases.len);
    for (cases, 0..) |case, index| {
        cloned[index] = .{
            .value = try cloneLiteralValue(allocator, case.value),
            .body_instrs = try cloneInstructions(allocator, case.body_instrs),
            .result = case.result,
        };
    }
    return cloned;
}

pub const SwitchReturn = struct {
    scrutinee_param: u32,
    cases: []const ReturnCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const ReturnCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    return_value: ?LocalId,
};

fn cloneReturnCases(allocator: std.mem.Allocator, cases: []const ReturnCase) CloneError![]const ReturnCase {
    if (cases.len == 0) return &.{};
    const cloned = try allocator.alloc(ReturnCase, cases.len);
    for (cases, 0..) |case, index| {
        cloned[index] = .{
            .value = try cloneLiteralValue(allocator, case.value),
            .body_instrs = try cloneInstructions(allocator, case.body_instrs),
            .return_value = case.return_value,
        };
    }
    return cloned;
}

pub const UnionSwitchReturn = struct {
    scrutinee_param: u32,
    cases: []const UnionCase,
};

/// Comptime-safe tagged-union case matching. Lowered by the ZIR backend
/// (`emitUnionSwitch`) to a single `switch_block` instruction (one prong
/// per variant, plus an optional `else` prong). Because Sema only analyzes
/// the active prong of a `switch_block` over a comptime-known scrutinee,
/// this avoids the "access of union field X while Y is active" UB that the
/// older `match_variant_tag` + `guard_block` + `variant_payload_get` chain
/// hit when both arms bound payloads.
///
/// This is the SINGLE lowering path for every `case` over a tagged-union
/// scrutinee — 1, 2, or N arms; nullary, single-payload, or multi-payload
/// variants; with or without a `_` catch-all. The decision-tree lowering
/// (`lowerDecisionTreeForCase` / `lowerDecisionTreeForDispatch`
/// `.switch_variant`) builds it directly.
///
/// Each prong is a `UnionCase`: `body_instrs` + `return_value` carry the
/// prong body and its value; `field_bindings` carries the payload binding.
/// For a payload-bearing variant, the prong has exactly one `FieldBinding`
/// whose `field_name` is the empty string (a whole-payload bind) and whose
/// `local_index` is the local the prong body reads the captured payload
/// through. Nullary variants have no field bindings. Reusing `UnionCase`
/// (rather than a bespoke case type) lets every ARC analysis pass that
/// already walks `union_switch.cases[].body_instrs` / `.return_value` /
/// `.field_bindings` keep working without change.
pub const UnionSwitch = struct {
    dest: LocalId,
    scrutinee: LocalId,
    cases: []const UnionCase,
    /// Catch-all (`_` / decision-tree default) prong, lowered to the
    /// switch's `else` prong. Empty + `has_else == false` when the
    /// variants are exhaustive (no catch-all arm).
    else_instrs: []const Instruction = &.{},
    else_result: ?LocalId = null,
    has_else: bool = false,
};

/// Multi-clause `f(nil) / f(t :: T)` dispatch on an optional parameter.
/// Generated when `canOptionalDispatch` succeeds at function-group
/// lowering. The ZIR emitter expands this into:
///
///   if (param == null) { nil_instrs; ret nil_result }
///   else { payload_local = param.?; struct_instrs; ret struct_result }
///
/// `payload_local` is a fresh `LocalId` allocated by the IR builder.
/// References to the optional param inside the struct clause body still
/// emit `param_get(scrutinee_param)`; the ZIR emitter redirects those
/// reads to `payload_local` for the duration of the struct branch so
/// the user-visible `n :: T` binding sees the unwrapped value, not the
/// optional storage shape.
pub const OptionalDispatch = struct {
    scrutinee_param: u32,
    payload_local: LocalId,
    nil_instrs: []const Instruction,
    nil_result: ?LocalId,
    struct_instrs: []const Instruction,
    struct_result: ?LocalId,
};

pub const UnionCase = struct {
    variant_name: []const u8,
    field_bindings: []const FieldBinding,
    body_instrs: []const Instruction,
    return_value: ?LocalId,
};

pub const FieldBinding = struct {
    field_name: []const u8,
    local_name: []const u8,
    local_index: LocalId,
};

fn cloneFieldBindings(allocator: std.mem.Allocator, bindings: []const FieldBinding) CloneError![]const FieldBinding {
    if (bindings.len == 0) return &.{};
    const cloned = try allocator.alloc(FieldBinding, bindings.len);
    for (bindings, 0..) |binding, index| {
        cloned[index] = .{
            .field_name = try cloneBytes(allocator, binding.field_name),
            .local_name = try cloneBytes(allocator, binding.local_name),
            .local_index = binding.local_index,
        };
    }
    return cloned;
}

fn cloneUnionCases(allocator: std.mem.Allocator, cases: []const UnionCase) CloneError![]const UnionCase {
    if (cases.len == 0) return &.{};
    const cloned = try allocator.alloc(UnionCase, cases.len);
    for (cases, 0..) |case, index| {
        cloned[index] = .{
            .variant_name = try cloneBytes(allocator, case.variant_name),
            .field_bindings = try cloneFieldBindings(allocator, case.field_bindings),
            .body_instrs = try cloneInstructions(allocator, case.body_instrs),
            .return_value = case.return_value,
        };
    }
    return cloned;
}

pub const NumericWiden = struct {
    dest: LocalId,
    source: LocalId,
    dest_type: ZigType,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
};

pub const MatchAtom = struct {
    dest: LocalId,
    scrutinee: LocalId,
    atom_name: []const u8,
    skip_type_check: bool = false,
};

/// Compare a tagged-union scrutinee's active tag against an
/// expected variant name. Lowers to
/// `std.meta.activeTag(scrutinee) == .VariantName` via the ZIR
/// backend's existing enum-literal comparison machinery (also used
/// by `union_switch_return`). The result local holds a bool that
/// `guard_block` consumes.
pub const MatchVariantTag = struct {
    dest: LocalId,
    scrutinee: LocalId,
    variant_name: []const u8,
};

/// Extract a tagged-union scrutinee's payload for the named variant
/// — `scrutinee.VariantName` in Zig terms. Mirrors the
/// payload-extraction step inside `union_switch_return`'s
/// case-body lowering. Emitted only inside a guard_block whose
/// condition is a matching `match_variant_tag`, so it is sound to
/// reach the variant's payload field directly.
pub const VariantPayloadGet = struct {
    dest: LocalId,
    scrutinee: LocalId,
    variant_name: []const u8,
};

pub const MatchInt = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: i64,
    skip_type_check: bool = false,
};

pub const MatchFloat = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: f64,
    skip_type_check: bool = false,
};

pub const MatchString = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected: []const u8,
    skip_type_check: bool = false,
};

pub const MatchType = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_type: ZigType,
    skip_type_check: bool = false,
    expected_arity: ?u32 = null,
};

pub const MatchFail = struct {
    message: []const u8,
    /// For panic expressions, the local holding the runtime message string.
    message_local: ?LocalId = null,
};

/// Like match_fail but returns error.NoMatchingClause instead of panicking.
/// Used in __try function variants for the ~> catch basin operator.
pub const MatchErrorReturn = struct {
    scrutinee: LocalId, // the unmatched value
};

pub const Return = struct {
    value: ?LocalId,
};

pub const CondReturn = struct {
    condition: LocalId,
    value: ?LocalId,
};

pub const Jump = struct {
    target: LabelId,
    value: ?LocalId = null,
    bind_dest: ?LocalId = null,
};

pub const MakeClosure = struct {
    dest: LocalId,
    function: FunctionId,
    captures: []const LocalId,
};

pub const CaptureGet = struct {
    dest: LocalId,
    index: u32,
};

pub const OptionalUnwrap = struct {
    dest: LocalId,
    source: LocalId,
};

pub const BinLenCheck = struct {
    dest: LocalId,
    scrutinee: LocalId,
    min_len: u32,
};

pub const BinReadInt = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    bits: u16,
    signed: bool,
    endianness: ast.Endianness,
    bit_offset: u8 = 0, // bit offset within byte for sub-byte extractions
};

pub const BinReadFloat = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    bits: u16,
    endianness: ast.Endianness,
};

pub const BinSlice = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    length: ?BinOffset, // null = rest of data
};

pub const BinReadUtf8 = struct {
    dest_codepoint: LocalId,
    dest_len: LocalId,
    source: LocalId,
    offset: BinOffset,
};

pub const BinMatchPrefix = struct {
    dest: LocalId,
    source: LocalId,
    expected: []const u8,
};

pub const BinOffset = union(enum) {
    static: u32,
    dynamic: LocalId,
};

/// Flavor of retain. Each kind selects a different runtime helper at
/// ZIR-lowering time. The kind is set at the IR-build site to encode
/// the retain's *purpose*, not the value's type — the same value may
/// be retained `.normal` at a call site (transient borrow) and
/// `.persistent` at a struct-field-store site (long-lived owner).
///
/// Phase 1 Class A: introduced to migrate the implicit retains on
/// `.copy_value` (persistent) and `.share_value` mode=retain (normal)
/// from direct ZIR runtime-call emission into explicit `.retain` IR
/// instructions, so the IR-level analysis pipeline can see every
/// retain operation. See
/// `docs/arc-emission-architecture-research-brief.md` §10.1.
pub const RetainKind = enum {
    /// Standard transient retain. Lowers to `ArcRuntime.retainAny`.
    /// This is the canonical retain for call-argument passing,
    /// indirect-storage field extraction, aggregate construction,
    /// etc.
    normal,
    /// Persistent retain — value is being stashed in long-lived
    /// container storage (struct field, list element slot, closure
    /// capture). Lowers to `ArcRuntime.retainAnyPersistent`, which
    /// routes through the type's own `retain` method when one
    /// exists so the Map-workload share-event tracking fires.
    persistent,
};

pub const Retain = struct {
    value: LocalId,
    /// Flavor of retain. Defaults to `.normal` so existing
    /// `Instruction{ .retain = .{ .value = x } }` constructions
    /// continue to compile after the kind field was added. The IR
    /// builder's `emitArcRetainOnAggregateExtract` and the call-arg
    /// share emit `.normal`; `arc_ownership.zig`'s `.copy_value`
    /// rewrite path emits `.persistent`.
    kind: RetainKind = .normal,
};

/// Flavor of release. Each kind selects a different runtime helper
/// at ZIR-lowering time. Phase 2 Class B introduces this flavoring
/// so the analysis-driven `releaseAny` / `freeAny` emissions
/// (`emitDropSpecializationsForCurrentInstr` at zir_builder.zig:3934)
/// can become first-class IR instructions consumed by the canonical
/// `.release` handler. Same architectural rationale as `RetainKind`
/// (Phase 1 Class A): the IR is the single source of truth for
/// every retain/release the program executes.
pub const ReleaseKind = enum {
    /// Standard ARC release: decrement refcount; if zero, run the
    /// type's destructor (which deep-releases ARC-managed
    /// children) and free the allocation. Lowers to
    /// `ArcRuntime.releaseAny`.
    release,
    /// Shallow free: refcount must be statically known to be 1 at
    /// this point; destroys the parent allocation without walking
    /// children. Used by destructive-optional-dispatch where
    /// children were already extracted and consumed by inner
    /// calls. Lowers to `ArcRuntime.freeAny`.
    free,
    /// Phase 1.2.5.d protocol-existential drop. Routes the release
    /// through the per-protocol synthetic `<Protocol>VTable.drop(box)`
    /// helper rather than the standard `releaseAny` dispatcher. The
    /// box is a 16-byte fat-pointer value-typed local — it has no
    /// inline `ArcHeader`, so `releaseAny` would mis-interpret it.
    /// `drop(box)` casts the vtable slot to `*const <Protocol>VTable`
    /// and invokes the synthetic `__drop__` slot, which routes the
    /// inner's typed pointer through `releaseProtocolBoxInner` to
    /// run the full ARC deep-walk and slab return.
    protocol_box_drop,
};

pub const Release = struct {
    value: LocalId,
    /// Flavor of release. Defaults to `.release` for backward compat
    /// with existing `.{ .release = .{ .value = x } }` constructions.
    /// `arc_drop_insertion` and the Phase 2 materialization pass
    /// emit `.release` (deep) by default; the optimizer / drop-
    /// specialization pass refines selected releases to `.free`
    /// when liveness proves the value is statically unique.
    kind: ReleaseKind = .release,
    /// Phase 1.2.5.d — when `kind == .protocol_box_drop`, the bare
    /// protocol name used to find the synthetic
    /// `<Protocol>VTable.drop` helper. `null` for every other kind.
    /// The IR builder fills this whenever it rewrites a release of a
    /// `.protocol_box(P)` local; the ZIR lowering reads it back out
    /// at emit time.
    protocol_name: ?[]const u8 = null,
};

/// Perceus: if RC=1, make memory available for reuse and return a reuse token.
/// If RC>1, decrement RC and return null token.
pub const Reset = struct {
    dest: LocalId, // reuse token
    source: LocalId, // value being deconstructed
};

/// Perceus: if reuse token is non-null, reuse memory for new allocation.
/// If token is null, allocate fresh.
pub const ReuseAlloc = struct {
    dest: LocalId, // newly allocated value
    token: ?LocalId, // reuse token from Reset (null = fresh alloc)
    constructor_tag: u32, // constructor tag for tagged unions
    dest_type: ZigType = .any,
};

pub const Phi = struct {
    dest: LocalId,
    sources: []const PhiSource,
};

pub const PhiSource = struct {
    from_block: LabelId,
    value: LocalId,
};

// ============================================================
// Zig types (for codegen)
// ============================================================

pub const ZigType = union(enum) {
    void,
    bool_type,
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
    f16,
    f32,
    f64,
    f80,
    f128,
    usize,
    isize,
    string, // []const u8
    atom, // enum literal or interned string
    nil, // void or optional
    /// `runtime.Term` — heterogeneous value wrapper. Used as the
    /// element type of collections whose components have disagreeing
    /// static types (e.g. `%{name: "Alice", age: 30}`). Construction
    /// sites wrap via `Term.from(value)` and consumption sites unwrap
    /// via `Term.to(T, term, default)`.
    term,
    tuple: []const ZigType,
    list: *const ZigType,
    map: MapType,
    struct_ref: []const u8,
    function: FnType,
    tagged_union: []const u8,
    optional: *const ZigType,
    ptr: *const ZigType,
    /// Protocol existential — a `runtime.ProtocolBox` fat pointer
    /// carrying an opaque inner-value pointer plus a per-impl vtable
    /// pointer. Payload is the protocol's bare name (e.g. `"Error"`
    /// for the Phase 1.2 `Error` protocol), which the ZIR backend
    /// uses to look up the corresponding `<Protocol>VTable` type when
    /// emitting consumption-site dispatch. The Zig source rendering
    /// for this variant is always `zap_runtime.ProtocolBox` (the
    /// runtime carrier type defined in `src/runtime.zig`).
    ///
    /// Phase 1.2.5.b plumbs this variant through every layer that
    /// touches `protocol_constraint` TypeIds; Phases 1.2.5.c and
    /// 1.2.5.d add construction-site auto-boxing and consumption-
    /// site dispatch that actually populate / read the box.
    protocol_box: []const u8,
    never, // noreturn — function that never returns (e.g., raise)
    any, // for generics

    pub const MapType = struct {
        key: *const ZigType,
        value: *const ZigType,
    };

    pub const FnType = struct {
        params: []const ZigType,
        return_type: *const ZigType,
    };
};

// ============================================================
// Public IR helpers — used by analysis passes (e.g. arc_liveness).
// ============================================================

/// Recognises the "default" ARC-managed-type set, mirroring
/// `IrBuilder.isArcManagedType`. Phase 6 of the k-nucleotide RSS gap
/// plan extends this to include `.map`. Exposed here so analysis
/// passes can share a single source of truth without instantiating
/// an IrBuilder.
pub fn isArcManagedTypeId(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= type_store.types.items.len) return false;
    // Phase F (the k-nucleotide RSS gap milestone) flipped `.map` to
    // join `.opaque_type` as ARC-managed. Phases A–E.9 built the
    // substrate (param-convention inference, consume-site rewrites,
    // ownership-transfer-aware liveness, V1–V7 verifiers) so that
    // every `.map` value flows through the same retain/release ABI as
    // opaque types.
    //
    // Phase H.1 laid the runtime substrate (`List(T)` Arc-headered +
    // pool-allocated + deep retain/release). Phase H.2 closed the
    // Air/Liveness gap by scoping `guard_block` body ownership to
    // its own execution path so out-of-scope locals no longer leak
    // into the parent's `owns` set. Phase H.3 closed the runtime
    // ARC ABI gap in `List.next`, `List.getHead`, and `List.getTail`
    // (those ops returned `cell.head`/`cell.tail` without bumping
    // refcounts, which the IR's `.owned` result convention required;
    // the cell's owner-side deep-release on its zero-transition
    // raced with the caller's release of the same children and
    // produced double-frees). Phase H.4 added `.list` to the
    // ARC-managed-type set so List(T) values flow through the same
    // retain/release ABI as `.map` and `.opaque_type`.
    //
    return switch (type_store.getType(type_id)) {
        .opaque_type, .map, .list => true,
        // Phase 1.2.5.d: protocol existentials are owning — every box
        // value carries a heap-allocated typed inner whose release is
        // dispatched through the synthetic `<Protocol>VTable.drop(box)`
        // helper. Treating non-parametric `.protocol_constraint` as
        // ARC-managed here is what flips `isArcManagedLocal(box_local)`
        // to true, which in turn drives `arc_managed_locals` membership
        // in the liveness pass and
        // `local_ownership[box_local] = .owned` in
        // `computeLocalOwnership`. Together those make
        // `arc_drop_insertion` schedule a scope-exit release for the
        // box — the release the IR builder rewrites to
        // `.kind = .protocol_box_drop` so the ZIR backend lowers it
        // through `drop(box)` instead of `releaseAny(box)`.
        //
        // Parametric protocol constraints (`Enumerable(t)`,
        // `Iterator(K, V)`) are deliberately EXCLUDED: their
        // per-protocol vtable + per-impl adapter codegen is still
        // gated off in `populateProtocolVTables`
        // (`if (proto_entry.decl.type_params.len != 0) continue;`),
        // so no `<Protocol>VTable.drop` helper exists for them. The
        // existing HIR `protocolDispatchStruct` rewrite folds parametric
        // protocol calls to concrete-impl calls before IR sees them, so
        // their receivers never actually flow through a `ProtocolBox`
        // value — classifying them as ARC-managed would be a
        // diagnostic-only no-op at best and trip the V11 verifier on
        // share_value of trivial-classified arguments at worst.
        .protocol_constraint => |pc| pc.type_params.len == 0,
        .struct_type => structTypeUsesRecursiveBoxing(type_store, type_id),
        .union_type => |union_type| blk: {
            for (union_type.members) |member_type_id| {
                if (isArcManagedTypeId(type_store, member_type_id)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn structTypeUsesRecursiveBoxing(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= type_store.types.items.len) return false;
    if (type_store.getType(type_id) != .struct_type) return false;
    const struct_type = type_store.getType(type_id).struct_type;
    for (struct_type.fields) |field| {
        if (typeReferencesTargetStruct(type_store, field.type_id, type_id, 0)) return true;
    }
    return false;
}

fn typeReferencesTargetStruct(
    type_store: *const types_mod.TypeStore,
    current_type_id: types_mod.TypeId,
    target_type_id: types_mod.TypeId,
    depth: usize,
) bool {
    if (current_type_id >= type_store.types.items.len) return false;
    if (depth > type_store.types.items.len) return false;

    return switch (type_store.getType(current_type_id)) {
        .struct_type => |struct_type| blk: {
            if (current_type_id == target_type_id) break :blk true;
            for (struct_type.fields) |field| {
                if (typeReferencesTargetStruct(type_store, field.type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .union_type => |union_type| blk: {
            for (union_type.members) |member_type_id| {
                if (typeReferencesTargetStruct(type_store, member_type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .tagged_union => |tagged_union| blk: {
            for (tagged_union.variants) |variant| {
                const payload_type_id = variant.type_id orelse continue;
                if (typeReferencesTargetStruct(type_store, payload_type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .tuple => |tuple_type| blk: {
            for (tuple_type.elements) |element_type_id| {
                if (typeReferencesTargetStruct(type_store, element_type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        .list => |list_type| typeReferencesTargetStruct(type_store, list_type.element, target_type_id, depth + 1),
        .map => |map_type| typeReferencesTargetStruct(type_store, map_type.key, target_type_id, depth + 1) or
            typeReferencesTargetStruct(type_store, map_type.value, target_type_id, depth + 1),
        .function => |function_type| blk: {
            for (function_type.params) |param_type_id| {
                if (typeReferencesTargetStruct(type_store, param_type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk typeReferencesTargetStruct(type_store, function_type.return_type, target_type_id, depth + 1);
        },
        .applied => |applied_type| blk: {
            if (typeReferencesTargetStruct(type_store, applied_type.base, target_type_id, depth + 1)) break :blk true;
            for (applied_type.args) |arg_type_id| {
                if (typeReferencesTargetStruct(type_store, arg_type_id, target_type_id, depth + 1)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn findOptionalUnionTypeId(type_store: *const types_mod.TypeStore, payload_type_id: types_mod.TypeId) ?types_mod.TypeId {
    for (type_store.types.items, 0..) |candidate_type, candidate_index| {
        if (candidate_type != .union_type) continue;
        const union_type = candidate_type.union_type;
        if (union_type.members.len != 2) continue;

        var saw_payload = false;
        var saw_nil = false;
        for (union_type.members) |member_type_id| {
            if (member_type_id == types_mod.TypeStore.NIL) {
                saw_nil = true;
            } else if (type_store.typeEquals(member_type_id, payload_type_id)) {
                saw_payload = true;
            }
        }
        if (saw_payload and saw_nil) return @intCast(candidate_index);
    }
    return null;
}

/// Default `ParamConvention` for a parameter of HIR type `type_id`.
/// Phase A of the Phase 6 redux plan classifies every ARC-managed
/// parameter as `.borrowed` (matching the existing caller-side
/// `share_value` + post-call `release` ABI) and every non-ARC
/// parameter as `.trivial`. When `type_store` is null (only the
/// in-process IrBuilder unit tests do this) every parameter falls
/// back to `.trivial` because we cannot determine ARC status without
/// the type table.
pub fn defaultParamConvention(
    type_store: ?*const types_mod.TypeStore,
    type_id: ?types_mod.TypeId,
) ParamConvention {
    const store = type_store orelse return .trivial;
    const tid = type_id orelse return .trivial;
    if (isArcManagedTypeId(store, tid)) return .borrowed;
    return .trivial;
}

/// Default `ResultConvention` for a return type of HIR type
/// `type_id`. ARC-managed return types receive `.owned` (the callee
/// returns an owner; the caller is responsible for destroying it on
/// every CFG path). Every other return type is `.trivial`.
pub fn defaultResultConvention(
    type_store: ?*const types_mod.TypeStore,
    type_id: ?types_mod.TypeId,
) ResultConvention {
    const store = type_store orelse return .trivial;
    const tid = type_id orelse return .trivial;
    if (isArcManagedTypeId(store, tid)) return .owned;
    return .trivial;
}

/// Walks every instruction in `function` (top-level and nested
/// inside structural sub-streams) in depth-first order, invoking
/// `visitor.visit(instruction_pointer)` for each. Used by analysis
/// passes that need to enumerate every instruction without
/// re-implementing the structural recursion.
pub fn forEachInstruction(
    function: *const Function,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    for (function.body) |block| {
        forEachInstructionInStream(block.instructions, context, visitFn);
    }
}

fn forEachInstructionInStream(
    stream: []const Instruction,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    for (stream) |*instr| {
        visitFn(context, instr);
        forEachInstructionChildren(instr, context, visitFn);
    }
}

fn forEachInstructionChildren(
    instr: *const Instruction,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    switch (instr.*) {
        .if_expr => |ie| {
            forEachInstructionInStream(ie.then_instrs, context, visitFn);
            forEachInstructionInStream(ie.else_instrs, context, visitFn);
        },
        .case_block => |cb| {
            forEachInstructionInStream(cb.pre_instrs, context, visitFn);
            for (cb.arms) |arm| {
                forEachInstructionInStream(arm.cond_instrs, context, visitFn);
                forEachInstructionInStream(arm.body_instrs, context, visitFn);
            }
            forEachInstructionInStream(cb.default_instrs, context, visitFn);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
            forEachInstructionInStream(sl.default_instrs, context, visitFn);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
            forEachInstructionInStream(sr.default_instrs, context, visitFn);
        },
        .union_switch => |us| {
            for (us.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
        },
        .try_call_named => |tc| {
            forEachInstructionInStream(tc.handler_instrs, context, visitFn);
            forEachInstructionInStream(tc.success_instrs, context, visitFn);
        },
        .guard_block => |gb| {
            forEachInstructionInStream(gb.body, context, visitFn);
        },
        .optional_dispatch => |od| {
            // Phase D (Phase 6 redux plan §3.D): recurse into both
            // arm bodies so any visitor — use-summary walker, drop
            // counter, verifier, IR dumper — sees every instruction
            // regardless of nesting. The arc-liveness analyzer and
            // arc-drop-insertion rebuilder use a separate region-tree
            // walk with their own InstructionId assignment, so this
            // helper's traversal order is orthogonal to theirs; it
            // is only required to be consistent (which it is — nil
            // first, then struct, mirroring the structural shape).
            forEachInstructionInStream(od.nil_instrs, context, visitFn);
            forEachInstructionInStream(od.struct_instrs, context, visitFn);
        },
        else => {},
    }
}

// ============================================================
// IR Builder — lowers HIR to IR
// ============================================================

pub const IrBuilder = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(Function),
    /// Separate ID counter for __try variants. Initialized in `buildProgram`
    /// to `max(group.id) + 1` over the input HIR groups so the variant IDs
    /// never collide with HIR-allocated group IDs regardless of program size.
    next_try_id: FunctionId = 0,
    next_local: LocalId,
    current_blocks: std.ArrayList(Block),
    current_instrs: std.ArrayList(Instruction),
    interner: *const ast.StringInterner,
    type_store: ?*const types_mod.TypeStore,
    /// Optional scope graph reference. Used to consult the native-type
    /// registry (`isNativeTypeName`, `nativeTypeStructName`) at IR-emit
    /// time — e.g. deciding whether `in` should lower to `in_range` or
    /// `in_list` based on whether the rhs is the registered Range type.
    /// The IR builder unit tests construct an IrBuilder without a
    /// scope graph, so call sites must guard for null.
    scope_graph: ?*const scope_mod.ScopeGraph = null,
    known_local_types: std.AutoHashMap(LocalId, ZigType),
    /// Maps `LocalId` -> the HIR `TypeId` of the value held in that
    /// local. Distinct from `known_local_types`, which carries the
    /// post-monomorphization Zig-level type. The HIR-level type is
    /// what `isArcManagedType` consults, so any analysis that needs
    /// to ask "is this local's value ARC-managed?" — including the
    /// `emitLocalGet` helper that decides whether a `.local_get`
    /// requires a follow-up `.retain` for independent ownership —
    /// must use this table. Populated at every site that produces a
    /// new local: param entries, `local_set`, every dest computed by
    /// `lowerExpr`, `local_get` aliases, and the four pattern-binding
    /// `local_get` sites in case / decision-tree lowering. Saved and
    /// restored across nested `function_group` blocks alongside
    /// `known_local_types`.
    local_hir_types: std.AutoHashMap(LocalId, hir_mod.TypeId),
    /// Locals whose value originated from a `param_get` instruction.
    /// Used by the call-builtin encoder to detect bridge calls inside
    /// generic Zap functions — those have `param: anytype` in the
    /// emitted Zig, so any post-monomorph nominal type (e.g.
    /// `Map(atom, string)`) cannot be safely burned into the call name
    /// because the runtime value may carry a different generic
    /// instantiation (e.g. `Map(atom, term)`). Locals in this set
    /// route through the runtime's type-derived helpers instead.
    param_backed_locals: std.AutoHashMap(LocalId, void),
    /// Tuple-typed locals whose components may have been Term-promoted
    /// because they were extracted via a `via_helper` list operation
    /// (heterogeneous keyword list flowing through `anytype`). When a
    /// later `index_get` reads from one of these locals, the IR emits
    /// `Term.toCoerced` to recover the declared concrete component type.
    term_tuple_locals: std.AutoHashMap(LocalId, ZigType),
    current_struct_prefix: ?[]const u8,
    known_function_names: std.StringHashMap(void),
    synthesized_type_defs: std.ArrayList(TypeDef),
    /// Maps function name → union dispatch info for call-site wrapping
    union_dispatch_map: std.StringHashMap(UnionDispatchInfo),
    /// When true, decision tree failure nodes emit match_error_return instead of match_fail.
    /// Used when generating __try function variants for the ~> catch basin operator.
    try_mode: bool = false,
    /// The original function's arity (number of params excluding the handler).
    /// The handler param is at index current_try_arity in the __try variant.
    current_try_arity: u32 = 0,
    /// Set of function names that need __try variants (populated by error pipe analysis).
    /// Only functions in this set will get __try variants generated.
    try_variant_names: std.StringHashMap(void),
    /// Optional whole-program HIR view used only for registering callable
    /// names during per-struct IR lowering. Emission still uses the
    /// `hir_program` passed to `buildProgram`.
    known_name_program: ?*const hir_mod.Program = null,
    /// HIR program currently being lowered. Used to recover concrete
    /// parameter types after monomorphization rewrites call targets to
    /// specialized function groups.
    current_hir_program: ?*const hir_mod.Program = null,
    /// Current function's declared param types (for param_get fallback when expr type is UNKNOWN).
    current_param_types: std.ArrayListUnmanaged(ZigType) = .empty,
    /// Current function's declared parameter HIR types, indexed by
    /// parameter position. Populated alongside `current_param_types`
    /// at clause prelude. Phase E.5 Gap 2: the body's `param_get`
    /// HIR-expression lowering consults this list to populate
    /// `local_hir_types[dest]` with the canonical param HIR type
    /// even when the source HIR expression's `type_id` was set to
    /// `UNKNOWN` (which happens for some monomorphized / type-erased
    /// signatures). Without this fallback `local_ownership` for the
    /// param-bound dest local is `.trivial` and the verifier never
    /// classifies the param read as ARC-managed.
    current_param_hir_types: std.ArrayListUnmanaged(hir_mod.TypeId) = .empty,
    /// Contextual type supplied by a call argument slot while lowering the
    /// argument expression. Used for empty container literals whose own HIR
    /// type is intentionally underconstrained.
    current_expected_type: ?types_mod.TypeId = null,
    /// Per-instantiation specialization table for every concrete
    /// `.applied { base, args }` TypeId that appears in the TypeStore
    /// at the start of `buildProgram`. Each entry records the
    /// canonical mangled name (`Box_i64`), the base nominal TypeId,
    /// and the substituted field/variant types ready for emission.
    /// Populated once via `populateAppliedSpecializations` so the
    /// IR's `field_get` / `struct_init` lowering, the type_defs
    /// emitter, and the per-instantiation lookup helpers all consult
    /// the same data — no on-the-fly substitution at lookup time.
    applied_specializations: std.ArrayListUnmanaged(AppliedSpecialization) = .empty,
    /// Maps an `.applied` TypeId to its index in
    /// `applied_specializations`. Used by `resolveTypeName` and
    /// `typeIdToZigTypeWithStore` to route a parametric instantiation
    /// to its mangled per-instantiation name.
    applied_id_to_spec: std.AutoHashMap(types_mod.TypeId, usize) = undefined,
    /// Maps a per-instantiation mangled name (`Box_i64`) to its index
    /// in `applied_specializations`. Used by `lookupStructFieldHirTypeByName`
    /// and `fieldZigTypeAndStorage` to recover the substituted field
    /// type list when the IR's field-receiver tracker hands them the
    /// post-monomorphization nominal name rather than the parametric
    /// base name.
    applied_name_to_spec: std.StringHashMapUnmanaged(usize) = .empty,

    /// One precomputed entry per concrete `.applied { base, args }`
    /// TypeId observed in the TypeStore. See `applied_specializations`
    /// for why this data is precomputed.
    pub const AppliedSpecialization = struct {
        /// Canonical applied TypeId — acts as the structural cache key
        /// (`TypeStore.addType` already structurally dedupes
        /// `(base, args)` so two callers asking for `Box(i64)` get the
        /// same TypeId).
        applied_type_id: types_mod.TypeId,
        /// Base nominal TypeId — the `struct_type` or `tagged_union`
        /// the `.applied` was built against.
        base_type_id: types_mod.TypeId,
        /// Owning mangled per-instantiation name (`Box_i64`). Owned by
        /// the IR builder's allocator.
        mangled_name: []const u8,
        /// One entry per field (struct) or variant (tagged_union) of
        /// the base nominal type, in declaration order. Each entry is
        /// the substituted ZigType ready to embed in `StructFieldDef`
        /// / `UnionVariant`. For unit variants the entry is `.nil`
        /// (callers consult the `null` payload TypeId via `variant_payload_type_ids`
        /// instead).
        substituted_field_zig_types: []const ZigType,
        /// Substituted HIR TypeId for each field/variant. For unit
        /// variants the slot is `TypeStore.UNKNOWN`. Used by the
        /// IR's HIR-type-driven helpers (e.g. `isArcManagedTypeId`).
        substituted_field_hir_types: []const types_mod.TypeId,
        /// Optional payload TypeId per variant (tagged_union case);
        /// empty for struct case. `null` entries denote unit variants
        /// (no payload).
        variant_payload_type_ids: []const ?types_mod.TypeId,
    };

    pub const UnionDispatchInfo = struct {
        param_idx: u32,
        union_type_name: []const u8,
        /// Maps variant type name → variant name in the union
        variants: std.StringHashMap(void),
    };

    const TypedClauseResolution = struct {
        declared_arity: u32,
        clause_index: u32,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) IrBuilder {
        return .{
            .allocator = allocator,
            .functions = .empty,
            .next_local = 0,
            .current_blocks = .empty,
            .current_instrs = .empty,
            .interner = interner,
            .type_store = null,
            .known_local_types = std.AutoHashMap(LocalId, ZigType).init(allocator),
            .local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(allocator),
            .param_backed_locals = std.AutoHashMap(LocalId, void).init(allocator),
            .term_tuple_locals = std.AutoHashMap(LocalId, ZigType).init(allocator),
            .current_struct_prefix = null,
            .known_function_names = std.StringHashMap(void).init(allocator),
            .synthesized_type_defs = .empty,
            .union_dispatch_map = std.StringHashMap(UnionDispatchInfo).init(allocator),
            .try_variant_names = std.StringHashMap(void).init(allocator),
            .applied_specializations = .empty,
            .applied_id_to_spec = std.AutoHashMap(types_mod.TypeId, usize).init(allocator),
            .applied_name_to_spec = .empty,
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        self.functions.deinit(self.allocator);
        self.current_blocks.deinit(self.allocator);
        self.current_instrs.deinit(self.allocator);
        self.known_local_types.deinit();
        self.local_hir_types.deinit();
        self.param_backed_locals.deinit();
        self.term_tuple_locals.deinit();
        self.synthesized_type_defs.deinit(self.allocator);
        self.union_dispatch_map.deinit();
        self.known_function_names.deinit();
        self.applied_specializations.deinit(self.allocator);
        self.applied_id_to_spec.deinit();
        self.applied_name_to_spec.deinit(self.allocator);
    }

    fn localBackedByParam(self: *const IrBuilder, local: LocalId) bool {
        return self.param_backed_locals.contains(local);
    }

    fn hirFunctionGroupById(self: *const IrBuilder, group_id: FunctionId) ?*const hir_mod.FunctionGroup {
        const program = self.current_hir_program orelse return null;
        for (program.structs) |*struct_info| {
            for (struct_info.functions) |*function_group| {
                if (function_group.id == group_id) return function_group;
            }
        }
        for (program.top_functions) |*function_group| {
            if (function_group.id == group_id) return function_group;
        }
        return null;
    }

    fn debugPathForSpan(self: *const IrBuilder, span: ast.SourceSpan) ?[]const u8 {
        const source_id = span.source_id orelse return null;
        const graph = self.scope_graph orelse return null;
        return graph.sourcePathById(source_id);
    }

    fn zeroBasedSourceCoordinate(value: u32) u32 {
        return if (value > 0) value - 1 else 0;
    }

    fn resolveNamedHirGroup(self: *const IrBuilder, named: hir_mod.NamedCall, arity: u32) ?*const hir_mod.FunctionGroup {
        const target_struct = named.struct_name orelse return null;
        const program = self.current_hir_program orelse return null;
        for (program.structs) |*struct_info| {
            if (struct_info.name.parts.len == 0) continue;
            const last_part = self.interner.get(struct_info.name.parts[struct_info.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, target_struct)) continue;
            for (struct_info.functions) |*function_group| {
                if (function_group.arity == arity and
                    std.mem.eql(u8, self.interner.get(function_group.name), named.name))
                {
                    return function_group;
                }
            }
        }
        return null;
    }

    fn callTargetExpectedType(
        self: *const IrBuilder,
        target: hir_mod.CallTarget,
        arg_count: usize,
        arg_index: usize,
    ) ?types_mod.TypeId {
        const group_id = switch (target) {
            .direct => |direct| direct.function_group_id,
            .dispatch => |dispatch| dispatch.function_group_id,
            .named => |named| blk: {
                const resolved = self.resolveNamedHirGroup(named, @intCast(arg_count)) orelse return null;
                break :blk resolved.id;
            },
            else => return null,
        };
        const group = self.hirFunctionGroupById(group_id) orelse return null;
        if (group.clauses.len == 0) return null;
        if (arg_index >= group.clauses[0].params.len) return null;
        return group.clauses[0].params[arg_index].type_id;
    }

    fn callTargetReturnType(self: *const IrBuilder, target: hir_mod.CallTarget, arg_count: usize) ?types_mod.TypeId {
        const group = switch (target) {
            .direct => |direct| self.hirFunctionGroupById(direct.function_group_id) orelse return null,
            .dispatch => |dispatch| self.hirFunctionGroupById(dispatch.function_group_id) orelse return null,
            .named => |named| self.resolveNamedHirGroup(named, @intCast(arg_count)) orelse return null,
            else => return null,
        };
        if (group.clauses.len == 0) return null;
        return group.clauses[0].return_type;
    }

    fn callTargetClause(
        self: *IrBuilder,
        target: hir_mod.CallTarget,
        arg_count: usize,
        args: []const hir_mod.CallArg,
    ) ?*const hir_mod.Clause {
        const group = switch (target) {
            .direct => |direct| blk: {
                const group = self.hirFunctionGroupById(direct.function_group_id) orelse return null;
                if (direct.clause_index) |clause_index| {
                    const index: usize = @intCast(clause_index);
                    if (index < group.clauses.len) return &group.clauses[index];
                }
                break :blk group;
            },
            .dispatch => |dispatch| self.hirFunctionGroupById(dispatch.function_group_id) orelse return null,
            .named => |named| blk: {
                const group = self.resolveNamedHirGroup(named, @intCast(arg_count)) orelse return null;
                if (named.struct_name) |struct_name| {
                    if (self.selectTypeOnlyNamedClause(struct_name, named.name, arg_count, args, named.clause_index)) |selected| {
                        const index: usize = @intCast(selected.clause_index);
                        if (index < group.clauses.len) return &group.clauses[index];
                    }
                }
                if (named.clause_index) |clause_index| {
                    const index: usize = @intCast(clause_index);
                    if (index < group.clauses.len) return &group.clauses[index];
                }
                break :blk group;
            },
            else => return null,
        };

        if (group.clauses.len == 0) return null;
        return &group.clauses[0];
    }

    fn resolvedCallReturnType(
        self: *IrBuilder,
        target: hir_mod.CallTarget,
        args: []const hir_mod.CallArg,
    ) ?types_mod.TypeId {
        const store_const = self.type_store orelse return self.callTargetReturnType(target, args.len);
        const clause = self.callTargetClause(target, args.len, args) orelse return null;
        const return_type = clause.return_type;
        if (!containsUnresolvedTypeVarForSpecialization(store_const, return_type)) return return_type;

        var substitutions = types_mod.SubstitutionMap.init(self.allocator);
        defer substitutions.deinit();

        const param_count = @min(clause.params.len, args.len);
        for (clause.params[0..param_count], args[0..param_count]) |param, arg| {
            const actual_type = self.typeOnlyArgType(arg);
            if (actual_type == types_mod.TypeStore.UNKNOWN or actual_type == types_mod.TypeStore.ERROR) continue;
            const matched = store_const.unify(param.type_id, actual_type, &substitutions) catch false;
            if (!matched) return return_type;
        }

        // `applyToReturnType` may intern a compound instantiated type
        // such as `List(f64)`. IR owns the same TypeStore used by
        // type-checking and monomorphization, so extending it here
        // keeps later ownership/ZIR decisions on concrete TypeIds
        // instead of stale bare type variables.
        return substitutions.applyToReturnType(@constCast(store_const), return_type);
    }

    fn trackCallResultType(self: *IrBuilder, dest: LocalId, return_type: ?types_mod.TypeId) !void {
        const type_id = return_type orelse return;
        _ = self.usableContextType(type_id) orelse return;
        try self.local_hir_types.put(dest, type_id);
        const zig_type = typeIdToZigTypeWithStore(type_id, self.type_store);
        if (zig_type != .any and zig_type != .void) {
            try self.known_local_types.put(dest, zig_type);
        }
    }

    fn binaryResultZigType(
        self: *const IrBuilder,
        result_type_id: types_mod.TypeId,
        lhs: LocalId,
        rhs: LocalId,
    ) ZigType {
        const result_type = typeIdToZigTypeWithStore(result_type_id, self.type_store);
        if (result_type != .any) return result_type;
        if (self.known_local_types.get(lhs)) |lhs_type| {
            if (lhs_type != .any) return lhs_type;
        }
        if (self.known_local_types.get(rhs)) |rhs_type| {
            if (rhs_type != .any) return rhs_type;
        }
        return .any;
    }

    fn binaryResultHirType(
        self: *const IrBuilder,
        result_type_id: types_mod.TypeId,
        lhs: LocalId,
        rhs: LocalId,
    ) types_mod.TypeId {
        if (self.usableContextType(result_type_id)) |type_id| return type_id;
        if (self.local_hir_types.get(lhs)) |lhs_type| {
            if (self.usableContextType(lhs_type)) |type_id| return type_id;
        }
        if (self.local_hir_types.get(rhs)) |rhs_type| {
            if (self.usableContextType(rhs_type)) |type_id| return type_id;
        }
        return result_type_id;
    }

    fn listElementTypeFromHirMaybe(self: *const IrBuilder, type_id: types_mod.TypeId) ?ZigType {
        const ts = self.type_store orelse return null;
        if (type_id >= ts.types.items.len) return null;
        const typ = ts.types.items[type_id];
        return switch (typ) {
            .list => |lt| typeIdToZigTypeWithStore(lt.element, self.type_store),
            else => null,
        };
    }

    fn listTypeFromElement(self: *const IrBuilder, element_type: ZigType) !ZigType {
        const element_ptr = try self.allocator.create(ZigType);
        element_ptr.* = element_type;
        return .{ .list = element_ptr };
    }

    fn listTypeFromHirOrElement(self: *const IrBuilder, type_id: types_mod.TypeId, element_type: ZigType) !ZigType {
        if (self.listElementTypeFromHirMaybe(type_id)) |hir_element_type| {
            if (hir_element_type != .any or element_type == .any) {
                return typeIdToZigTypeWithStore(type_id, self.type_store);
            }
        }
        if (self.current_expected_type) |expected_type| {
            if (self.listElementTypeFromHirMaybe(expected_type)) |expected_element_type| {
                if (expected_element_type != .any or element_type == .any) {
                    return typeIdToZigTypeWithStore(expected_type, self.type_store);
                }
            }
        }
        return try self.listTypeFromElement(element_type);
    }

    fn chooseListElementType(self: *const IrBuilder, hir_type_id: types_mod.TypeId, fallback_type: ZigType) ZigType {
        if (self.listElementTypeFromHirMaybe(hir_type_id)) |hir_element_type| {
            if (hir_element_type != .any or fallback_type == .any) {
                return hir_element_type;
            }
        }
        if (self.current_expected_type) |expected_type| {
            if (self.listElementTypeFromHirMaybe(expected_type)) |expected_element_type| {
                if (expected_element_type != .any or fallback_type == .any) {
                    return expected_element_type;
                }
            }
        }
        return fallback_type;
    }

    fn listElementTypeFromLocal(self: *const IrBuilder, local: LocalId) ?ZigType {
        if (self.known_local_types.get(local)) |local_type| {
            return local_type;
        }
        return null;
    }

    fn usableContextType(self: *const IrBuilder, type_id: types_mod.TypeId) ?types_mod.TypeId {
        if (type_id == types_mod.TypeStore.UNKNOWN or type_id == types_mod.TypeStore.ERROR) return null;
        if (self.type_store) |store| {
            if (containsUnresolvedTypeVarForSpecialization(store, type_id)) return null;
        }
        const resolved = typeIdToZigTypeWithStore(type_id, self.type_store);
        if (resolved == .any) return null;
        return type_id;
    }

    fn shouldPreferContextType(self: *const IrBuilder, fallback: types_mod.TypeId, context: types_mod.TypeId) bool {
        _ = self.usableContextType(context) orelse return false;
        if (fallback == types_mod.TypeStore.UNKNOWN or fallback == types_mod.TypeStore.ERROR) return true;
        const fallback_resolved = typeIdToZigTypeWithStore(fallback, self.type_store);
        if (fallback_resolved == .any) return true;
        if (self.type_store) |store| {
            if (containsUnresolvedTypeVarForSpecialization(store, fallback)) return true;
        }
        return false;
    }

    fn effectiveTrackedHirType(self: *IrBuilder, expr: *const hir_mod.Expr) types_mod.TypeId {
        var fallback = expr.type_id;
        if (expr.kind == .call) {
            const call = expr.kind.call;
            if (self.resolvedCallReturnType(call.target, call.args)) |return_type| {
                if (self.usableContextType(return_type) != null) fallback = return_type;
            }
        }
        if (self.current_expected_type) |context| {
            if (self.shouldPreferContextType(fallback, context)) return context;
        }
        return fallback;
    }

    fn listElementTypeFromTailLocal(self: *const IrBuilder, tail: LocalId) ?ZigType {
        if (self.known_local_types.get(tail)) |tail_type| {
            if (tail_type == .list) {
                return tail_type.list.*;
            }
        }
        return null;
    }

    fn closureReturnType(self: *const IrBuilder, expr_type: types_mod.TypeId, callee: LocalId) ZigType {
        const expr_zig_type = typeIdToZigTypeWithStore(expr_type, self.type_store);
        if (expr_zig_type != .any) return expr_zig_type;
        if (self.known_local_types.get(callee)) |callee_type| {
            if (callee_type == .function) {
                return callee_type.function.return_type.*;
            }
        }
        return expr_zig_type;
    }

    /// Extract the list element ZigType from a local's known type.
    /// Returns null when the local's type is unknown or not a list; callers
    /// must choose an explicit default only at syntactic empty-list sites.
    fn listElementTypeForLocal(self: *const IrBuilder, local: LocalId) ?ZigType {
        const known = self.known_local_types.get(local) orelse return null;
        return switch (std.meta.activeTag(known)) {
            .list => known.list.*,
            else => null,
        };
    }

    /// Resolve the nominal struct type name owning a `field_get`'s
    /// receiver, when the local's static type is a struct (or an
    /// optional/pointer to one). Returns the struct name string the
    /// ZIR emitter can hand to `findStructDef`. `null` means the
    /// receiver's struct identity isn't statically known — fall back
    /// to the un-derefed `field_val` path.
    fn structTypeForFieldReceiver(self: *const IrBuilder, local: LocalId) ?[]const u8 {
        const known = self.known_local_types.get(local) orelse return null;
        return zigTypeStructName(known);
    }

    /// Look up the source-level field type and storage strategy for a
    /// field on a struct whose def already lives in the TypeStore.
    /// Returns null when the struct or field can't be resolved (e.g.
    /// generic shapes, missing TypeStore). The ZIR emitter uses the
    /// returned `ZigType` to drive the source-level type the indirect
    /// auto-deref must produce.
    fn fieldZigTypeAndStorage(self: *const IrBuilder, struct_name: []const u8, field_name: []const u8) ?struct {
        type_expr: ZigType,
        storage: FieldStorage,
    } {
        const ts = self.type_store orelse return null;
        // Per-instantiation form (`Box_i64`): the precomputed
        // substituted ZigType list is the authoritative source —
        // walking `ts.types.items` for `Box_i64` would find nothing
        // because the TypeStore only carries the parametric base
        // `Box` plus the `.applied` cache entry; neither has the
        // post-substitution field shape recorded.
        if (self.appliedSpecializationByMangledName(struct_name)) |spec| {
            const base = ts.getType(spec.base_type_id);
            if (base != .struct_type) return null;
            for (base.struct_type.fields, 0..) |f, i| {
                const fname = self.interner.get(f.name);
                if (!std.mem.eql(u8, fname, field_name)) continue;
                const field_zig_type = spec.substituted_field_zig_types[i];
                // The cycle-detection owner is the per-instantiation
                // name (`Box_i64`) — that's what a recursive
                // `value :: Box(i64)` field would carry as its
                // post-substitution struct_ref, so a self-referential
                // parametric struct still correctly lowers to
                // indirect storage at the per-instantiation TypeDef.
                const reaches_cycle = zigTypeReachesStructInCycle(self.allocator, field_zig_type, struct_name, ts, self.interner) catch
                    zigTypeReachesStruct(field_zig_type, struct_name);
                const storage: FieldStorage = if (reaches_cycle) .indirect else .direct;
                return .{ .type_expr = field_zig_type, .storage = storage };
            }
            return null;
        }
        for (ts.types.items) |typ| {
            if (typ != .struct_type) continue;
            const st = typ.struct_type;
            const owner = self.interner.get(st.name);
            if (!std.mem.eql(u8, owner, struct_name)) continue;
            for (st.fields) |f| {
                const fname = self.interner.get(f.name);
                if (!std.mem.eql(u8, fname, field_name)) continue;
                const field_zig_type = typeIdToZigTypeWithStore(f.type_id, self.type_store);
                // Use the SCC-aware walker so mutual recursion (`A
                // → B → A`) gets the same `.indirect` storage that
                // self-recursion already does.
                const reaches_cycle = zigTypeReachesStructInCycle(self.allocator, field_zig_type, owner, ts, self.interner) catch
                    zigTypeReachesStruct(field_zig_type, owner);
                const storage: FieldStorage = if (reaches_cycle) .indirect else .direct;
                return .{ .type_expr = field_zig_type, .storage = storage };
            }
        }
        return null;
    }

    /// True iff `name_id` (a struct's StringId) refers to the stdlib
    /// struct that opted in to `@native_type = "range"`. Used by `in_op`
    /// lowering to choose between `in_range` and `in_list`. Returns
    /// false when no scope graph is attached (IR unit-test path) — in
    /// that case the caller falls back to `in_list`, which is the safe
    /// default for non-Range right-hand sides.
    fn isNativeRangeStruct(self: *const IrBuilder, name_id: ast.StringId) bool {
        const graph = self.scope_graph orelse return false;
        const registered = graph.nativeTypeStructName(.range) orelse return false;
        return registered == name_id or std.mem.eql(u8, self.interner.get(registered), self.interner.get(name_id));
    }

    /// Append one concrete (non-parametric) struct's TypeDef to the
    /// builder's running list. Walks each field, lowers its TypeId to
    /// a ZigType, runs the SCC-aware cycle check for recursive
    /// storage, and collects defaults. Shared by the concrete struct
    /// path (category 1) and the per-instantiation path (category 2)
    /// — they differ only in how the field type list is produced,
    /// not in how the layout is computed.
    fn appendStructTypeDefShape(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
        type_store: *const types_mod.TypeStore,
        owner_name: []const u8,
        field_names: []const ast.StringId,
        field_zig_types: []const ZigType,
        field_defaults: []const ?DefaultValue,
    ) !void {
        var fields: std.ArrayList(StructFieldDef) = .empty;
        for (field_names, field_zig_types, field_defaults) |name_id, zig_type, default_val| {
            const reaches_cycle = zigTypeReachesStructInCycle(self.allocator, zig_type, owner_name, type_store, self.interner) catch
                zigTypeReachesStruct(zig_type, owner_name);
            const storage: FieldStorage = if (reaches_cycle) .indirect else .direct;
            try fields.append(self.allocator, .{
                .name = self.interner.get(name_id),
                .type_expr = zig_type,
                .default_value = default_val,
                .storage = storage,
            });
        }
        try type_defs.append(self.allocator, .{
            .name = owner_name,
            .kind = .{ .struct_def = .{
                .fields = try fields.toOwnedSlice(self.allocator),
            } },
        });
    }

    /// Conventional (non-parametric) struct TypeDef emission. The
    /// field type list is the struct's declared type list lowered
    /// through `typeIdToZigTypeWithStore`.
    fn appendStructTypeDef(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
        type_store: *const types_mod.TypeStore,
        owner_name: []const u8,
        fields: []const types_mod.Type.StructField,
    ) !void {
        const names = try self.allocator.alloc(ast.StringId, fields.len);
        defer self.allocator.free(names);
        const zig_types = try self.allocator.alloc(ZigType, fields.len);
        defer self.allocator.free(zig_types);
        const defaults = try self.allocator.alloc(?DefaultValue, fields.len);
        defer self.allocator.free(defaults);
        for (fields, 0..) |field, i| {
            names[i] = field.name;
            zig_types[i] = typeIdToZigTypeWithStore(field.type_id, type_store);
            defaults[i] = if (field.default_expr) |expr| self.extractDefaultValue(expr) else null;
        }
        try self.appendStructTypeDefShape(type_defs, type_store, owner_name, names, zig_types, defaults);
    }

    /// Per-instantiation struct/tagged-union TypeDef emission for an
    /// `.applied` form. Reuses the precomputed substituted ZigType
    /// list from the specialization table — no per-call substitution.
    fn appendAppliedSpecializationTypeDef(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
        type_store: *const types_mod.TypeStore,
        spec: *const AppliedSpecialization,
    ) !void {
        const base = type_store.getType(spec.base_type_id);
        switch (base) {
            .struct_type => |st| {
                // Use the SAME field-name list as the base — the
                // declared field names do not change between
                // instantiations, only their types.
                const names = try self.allocator.alloc(ast.StringId, st.fields.len);
                defer self.allocator.free(names);
                const defaults = try self.allocator.alloc(?DefaultValue, st.fields.len);
                defer self.allocator.free(defaults);
                for (st.fields, 0..) |field, i| {
                    names[i] = field.name;
                    // Field-default re-validation under substitution
                    // is the 1.1.5.e consumer of the
                    // `validated_default_struct_ids` hook; until then,
                    // carry the declared default verbatim. Defaults
                    // with type-var-bearing expressions are gated
                    // upstream by `validateStructFieldDefaults`, so
                    // re-emitting them here is safe — the worst case
                    // is a duplicate diagnostic if the user wrote
                    // `value :: T = 0` and instantiated with String.
                    defaults[i] = if (field.default_expr) |expr| self.extractDefaultValue(expr) else null;
                }
                try self.appendStructTypeDefShape(
                    type_defs,
                    type_store,
                    spec.mangled_name,
                    names,
                    spec.substituted_field_zig_types,
                    defaults,
                );
            },
            .tagged_union => |tu| {
                // Emit as union_def when any variant carries a
                // payload, enum_def when all variants are units —
                // matches the concrete-tagged-union path's behavior.
                var has_data = false;
                for (spec.variant_payload_type_ids) |payload| {
                    if (payload != null) {
                        has_data = true;
                        break;
                    }
                }
                if (has_data) {
                    var variants: std.ArrayList(UnionVariant) = .empty;
                    for (tu.variants, 0..) |variant, i| {
                        const type_str = if (spec.variant_payload_type_ids[i]) |tid| blk: {
                            if (tid == types_mod.TypeStore.ATOM) break :blk @as([]const u8, "u32");
                            break :blk typeIdToZigTypeStrWithStore(tid, type_store);
                        } else "void";
                        try variants.append(self.allocator, .{
                            .name = self.interner.get(variant.name),
                            .type_name = type_str,
                        });
                    }
                    try type_defs.append(self.allocator, .{
                        .name = spec.mangled_name,
                        .kind = .{ .union_def = .{
                            .variants = try variants.toOwnedSlice(self.allocator),
                        } },
                    });
                } else {
                    var variants: std.ArrayList([]const u8) = .empty;
                    for (tu.variants) |variant| {
                        try variants.append(self.allocator, self.interner.get(variant.name));
                    }
                    try type_defs.append(self.allocator, .{
                        .name = spec.mangled_name,
                        .kind = .{ .enum_def = .{
                            .variants = try variants.toOwnedSlice(self.allocator),
                        } },
                    });
                }
            },
            else => unreachable, // guarded by populateAppliedSpecializations
        }
    }

    /// Conventional (non-parametric) tagged-union TypeDef emission —
    /// preserves the legacy union(enum) / plain-enum split based on
    /// whether any variant carries a payload.
    fn appendTaggedUnionTypeDef(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
        owner_name: []const u8,
        variants_in: []const types_mod.Type.TaggedUnionVariant,
    ) !void {
        var has_data = false;
        for (variants_in) |v| {
            if (v.type_id != null) {
                has_data = true;
                break;
            }
        }
        if (has_data) {
            var union_variants: std.ArrayList(UnionVariant) = .empty;
            for (variants_in) |v| {
                const type_str = if (v.type_id) |tid| blk: {
                    if (tid == types_mod.TypeStore.ATOM) break :blk @as([]const u8, "u32");
                    break :blk typeIdToZigTypeStrWithStore(tid, self.type_store);
                } else "void";
                try union_variants.append(self.allocator, .{
                    .name = self.interner.get(v.name),
                    .type_name = type_str,
                });
            }
            try type_defs.append(self.allocator, .{
                .name = owner_name,
                .kind = .{ .union_def = .{
                    .variants = try union_variants.toOwnedSlice(self.allocator),
                } },
            });
        } else {
            var variants: std.ArrayList([]const u8) = .empty;
            for (variants_in) |v| {
                try variants.append(self.allocator, self.interner.get(v.name));
            }
            try type_defs.append(self.allocator, .{
                .name = owner_name,
                .kind = .{ .enum_def = .{
                    .variants = try variants.toOwnedSlice(self.allocator),
                } },
            });
        }
    }

    pub fn buildProgram(self: *IrBuilder, hir_program: *const hir_mod.Program) !Program {
        const saved_hir_program = self.current_hir_program;
        self.current_hir_program = hir_program;
        defer self.current_hir_program = saved_hir_program;

        // Precompute the per-instantiation specialization table for
        // every concrete `.applied { base, args }` TypeId in the
        // TypeStore. Every downstream lowering path that needs to
        // resolve a parametric instantiation's nominal name or field
        // layout reads from this table — see
        // `populateAppliedSpecializations` for the contract.
        try self.populateAppliedSpecializations();

        // First pass: register all qualified function names for bare call resolution.
        // Mangle the raw symbol so operator-named functions (`+`, `<>`, etc.) become
        // valid Zig identifiers; downstream lookups always go through the same mangler
        // so call sites and declarations see the same string. Also compute the upper
        // bound on HIR group IDs so `__try` variant IDs can be assigned past the
        // largest existing group without collision (regardless of program size).
        var max_group_id: FunctionId = 0;
        const name_program = self.known_name_program orelse hir_program;
        for (name_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                if (func_group.id > max_group_id) max_group_id = func_group.id;
                const func_name = self.interner.get(func_group.name);
                const mangled_func_name = try mangleSymbolForZig(self.allocator, func_name);
                if (self.type_store != null and self.isTypeOnlyOverloadGroup(&func_group)) {
                    for (func_group.clauses, 0..) |_, clause_index| {
                        const qualified = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}__{s}__{d}__clause_{d}",
                            .{ struct_prefix, mangled_func_name, func_group.arity, clause_index },
                        );
                        try self.known_function_names.put(qualified, {});
                    }
                } else {
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ struct_prefix, mangled_func_name, func_group.arity });
                    try self.known_function_names.put(qualified, {});
                }
            }
        }
        for (name_program.top_functions) |func_group| {
            if (func_group.id > max_group_id) max_group_id = func_group.id;
            const func_name = self.interner.get(func_group.name);
            const mangled_func_name = try mangleSymbolForZig(self.allocator, func_name);
            if (self.type_store != null and self.isTypeOnlyOverloadGroup(&func_group)) {
                for (func_group.clauses, 0..) |_, clause_index| {
                    const qualified = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}__{d}__clause_{d}",
                        .{ mangled_func_name, func_group.arity, clause_index },
                    );
                    try self.known_function_names.put(qualified, {});
                }
            } else {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_func_name, func_group.arity });
                try self.known_function_names.put(qualified, {});
            }
        }
        // The per-struct IR build path computes `max_group_id` from
        // *this struct's* HIR only. To prevent `__try` IDs from
        // colliding with regular HIR IDs in *other* structs (the IR
        // eventually merges all structs' functions into one program),
        // the caller may pre-seed `next_try_id` with a globally-safe
        // offset. Only fall back to `max_group_id + 1` when the
        // caller hasn't seeded a value.
        if (self.next_try_id <= max_group_id) {
            self.next_try_id = max_group_id + 1;
        }

        // Second pass: pre-scan for ~> error pipe chains to identify functions
        // that need __try variants. This must happen before building function bodies
        // so that __try variants are generated during buildFunctionGroup.
        for (hir_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                for (func_group.clauses) |clause| {
                    try self.scanForTryVariantNames(clause.body, struct_prefix);
                }
            }
        }
        for (hir_program.top_functions) |func_group| {
            for (func_group.clauses) |clause| {
                try self.scanForTryVariantNames(clause.body, null);
            }
        }

        // Fourth pass: build function bodies
        for (hir_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            self.current_struct_prefix = struct_prefix;
            for (mod.functions) |func_group| {
                try self.buildFunctionGroup(&func_group);
            }
        }
        self.current_struct_prefix = null;
        for (hir_program.top_functions) |func_group| {
            try self.buildFunctionGroup(&func_group);
        }

        // Build type definitions from TypeStore.
        //
        // Three categories of entry produce TypeDefs:
        //   1. Concrete `struct_type` / `tagged_union` (no type params) —
        //      the conventional path. Field types lower via
        //      `typeIdToZigTypeWithStore`, and the owner_name comes
        //      from the type's StringId.
        //   2. `.applied { base, args }` — per-instantiation forms
        //      produced by parametric struct/union literals. Each
        //      gets its own TypeDef under the canonical mangled name
        //      (`Box_i64`, `Pair_i64_String`), with field/variant
        //      types substituted through the precomputed specialization
        //      table.
        //   3. Parametric *templates* (`struct_type` / `tagged_union`
        //      with `type_params.len > 0`) — explicitly SKIPPED. They
        //      have no runtime layout (their field types still contain
        //      type variables) and emitting them would either crash
        //      the ZIR layer or shadow the concrete `Box_i64` form.
        var type_defs: std.ArrayList(TypeDef) = .empty;
        if (self.type_store) |ts| {
            for (ts.types.items, 0..) |typ, type_index| {
                switch (typ) {
                    .struct_type => |st| {
                        if (st.type_params.len > 0) continue; // category 3: skip template
                        try self.appendStructTypeDef(&type_defs, ts, self.interner.get(st.name), st.fields);
                    },
                    .tagged_union => |tu| {
                        if (tu.type_params.len > 0) continue; // category 3: skip template
                        try self.appendTaggedUnionTypeDef(&type_defs, self.interner.get(tu.name), tu.variants);
                    },
                    .applied => {
                        // Category 2: emit per-instantiation. We
                        // gate on `applied_id_to_spec.get` so partial
                        // / mid-monomorphization applied forms
                        // (filtered out by
                        // `populateAppliedSpecializations`) don't
                        // produce ghost TypeDefs.
                        const spec_idx = self.applied_id_to_spec.get(@intCast(type_index)) orelse continue;
                        const spec = &self.applied_specializations.items[spec_idx];
                        try self.appendAppliedSpecializationTypeDef(&type_defs, ts, spec);
                    },
                    else => {},
                }
            }
        }

        // Append synthesized union type definitions
        for (self.synthesized_type_defs.items) |synth_td| {
            try type_defs.append(self.allocator, synth_td);
        }

        // Phase 1.2.5.a step 3.7: per-protocol vtable types and per-impl
        // vtable instance constants. The construction-site lowering
        // (Phase 1.2.5.c) and consumption-site lowering (Phase 1.2.5.d)
        // both depend on these entries existing — Phase 1.2.5.a
        // surfaces them in the IR so the ZIR backend can lower them to
        // synthetic Zig source files. Skipped silently when the IR
        // builder has no scope_graph wired (unit tests for unrelated
        // IR shapes don't always set it; protocol existentials are
        // exercised by the dedicated tests at end-of-file).
        try self.populateProtocolVTables(&type_defs);

        return .{
            .functions = try self.functions.toOwnedSlice(self.allocator),
            .type_defs = try type_defs.toOwnedSlice(self.allocator),
            .entry = null,
        };
    }

    /// Extract a compile-time constant from an AST default expression.
    fn extractDefaultValue(self: *IrBuilder, expr: *const @import("ast.zig").Expr) ?DefaultValue {
        return switch (expr.*) {
            .int_literal => |il| .{ .int = il.value },
            .float_literal => |fl| .{ .float = fl.value },
            .bool_literal => |bl| .{ .bool_val = bl.value },
            .string_literal => |sl| .{ .string = self.interner.get(sl.value) },
            .nil_literal => .nil,
            else => null,
        };
    }

    fn isTypeOnlyOverloadGroup(self: *const IrBuilder, group: *const hir_mod.FunctionGroup) bool {
        if (group.clauses.len < 2) return false;
        for (group.clauses) |clause| {
            if (clause.refinement != null) return false;
            for (clause.params) |param| {
                if (param.pattern) |pattern| {
                    switch (pattern.*) {
                        .bind, .wildcard => {},
                        else => return false,
                    }
                }
            }
        }
        for (0..group.arity) |param_index| {
            const first_type = group.clauses[0].params[param_index].type_id;
            for (group.clauses[1..]) |clause| {
                if (param_index >= clause.params.len) continue;
                if (!self.type_store.?.typeEquals(first_type, clause.params[param_index].type_id)) return true;
            }
        }
        return false;
    }

    fn typeOnlyArgType(self: *const IrBuilder, arg: hir_mod.CallArg) hir_mod.TypeId {
        switch (arg.expr.kind) {
            .local_get => |local| {
                if (self.local_hir_types.get(local)) |tracked_type| return tracked_type;
            },
            .param_get => |param_index| {
                if (param_index < self.current_param_hir_types.items.len) {
                    return self.current_param_hir_types.items[param_index];
                }
            },
            else => {},
        }

        return arg.expr.type_id;
    }

    fn typeOnlyClauseMatchCost(self: *const IrBuilder, clause: *const hir_mod.Clause, call_arity: usize, args: []const hir_mod.CallArg) ?u32 {
        const ts = self.type_store orelse return null;
        if (args.len < call_arity) return null;
        if (clause.params.len < call_arity) return null;

        var total: u32 = 0;
        for (args[0..call_arity], clause.params[0..call_arity]) |arg, param| {
            const cost = ts.callMatchCost(self.typeOnlyArgType(arg), param.type_id) orelse return null;
            total +|= cost;
        }
        return total;
    }

    fn typeOnlyClauseCanonicalRank(self: *const IrBuilder, clause: *const hir_mod.Clause, call_arity: usize, args: []const hir_mod.CallArg) u32 {
        if (args.len < call_arity or clause.params.len < call_arity) return std.math.maxInt(u32);

        var total: u32 = 0;
        for (args[0..call_arity], clause.params[0..call_arity]) |arg, param| {
            if (self.typeOnlyArgType(arg) != types_mod.TypeStore.UNKNOWN) continue;
            total +|= self.canonicalTypeRank(param.type_id);
        }
        return total;
    }

    fn canonicalTypeRank(self: *const IrBuilder, type_id: types_mod.TypeId) u32 {
        const ts = self.type_store orelse return 1024;
        const typ = ts.getType(type_id);
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

    fn selectTypeOnlyNamedClause(
        self: *IrBuilder,
        struct_prefix: []const u8,
        function_name: []const u8,
        call_arity: usize,
        args: []const hir_mod.CallArg,
        requested_clause_index: ?u32,
    ) ?TypedClauseResolution {
        _ = self.type_store orelse return null;
        const program = self.known_name_program orelse return null;

        var best: ?TypedClauseResolution = null;
        var best_cost: u32 = std.math.maxInt(u32);
        var best_rank: u32 = std.math.maxInt(u32);

        for (program.structs) |candidate_struct| {
            const candidate_prefix = self.structNameToPrefix(candidate_struct.name);
            if (!std.mem.eql(u8, candidate_prefix, struct_prefix)) continue;

            for (candidate_struct.functions) |function_group| {
                if (!std.mem.eql(u8, self.interner.get(function_group.name), function_name)) continue;
                const declared_arity: usize = @intCast(function_group.arity);
                if (declared_arity < call_arity) continue;
                if (declared_arity > call_arity + 4) continue;
                if (!self.isTypeOnlyOverloadGroup(&function_group)) continue;

                _ = requested_clause_index;

                for (function_group.clauses, 0..) |*clause, clause_index| {
                    const cost = self.typeOnlyClauseMatchCost(clause, call_arity, args) orelse continue;
                    if (best == null or cost < best_cost) {
                        best = .{
                            .declared_arity = function_group.arity,
                            .clause_index = @intCast(clause_index),
                        };
                        best_cost = cost;
                        best_rank = self.typeOnlyClauseCanonicalRank(clause, call_arity, args);
                    } else if (cost == best_cost) {
                        const rank = self.typeOnlyClauseCanonicalRank(clause, call_arity, args);
                        if (rank < best_rank) {
                            best = .{
                                .declared_arity = function_group.arity,
                                .clause_index = @intCast(clause_index),
                            };
                            best_rank = rank;
                        }
                    }
                }
            }
        }

        return best;
    }

    fn buildTypedClauseEntrypoint(self: *IrBuilder, group: *const hir_mod.FunctionGroup, clause: *const hir_mod.Clause, clause_index: u32) !void {
        const func_id = self.next_try_id;
        self.next_try_id += 1;

        self.next_local = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();
        self.local_hir_types.clearRetainingCapacity();
        self.param_backed_locals.clearRetainingCapacity();
        self.term_tuple_locals.clearRetainingCapacity();
        self.current_param_types = .empty;
        self.current_param_hir_types = .empty;

        var captures: std.ArrayList(Capture) = .empty;
        for (group.captures, 0..) |capture, idx| {
            const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
            try captures.append(self.allocator, .{
                .name = cap_name,
                .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                .ownership = capture.ownership,
            });
        }

        var params: std.ArrayList(Param) = .empty;
        for (clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            const resolved_type = typeIdToZigTypeWithStore(param.type_id, self.type_store);
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = resolved_type,
                .type_id = param.type_id,
            });
            try self.current_param_types.append(self.allocator, resolved_type);
            try self.current_param_hir_types.append(self.allocator, param.type_id);
        }

        const single_clause = [_]hir_mod.Clause{clause.*};
        self.next_local = computeMaxBindingLocalForClauses(single_clause[0..]);
        try self.emitTupleBindings(clause);
        try self.emitStructBindings(clause);
        try self.emitBinaryBindings(clause);
        try self.emitMapBindings(clause);
        const result_local = try self.lowerBlockExpecting(clause.body, clause.return_type);
        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
        const entry_instrs = try self.current_instrs.toOwnedSlice(self.allocator);

        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const mangled_raw_name = try mangleSymbolForZig(self.allocator, raw_name);
        const local_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}__clause_{d}", .{ mangled_raw_name, group.arity, clause_index });
        const name_str = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, local_name })
        else
            local_name;

        try self.known_function_names.put(name_str, {});
        const final_params_typed = try params.toOwnedSlice(self.allocator);
        const param_conventions = try self.computeParamConventions(final_params_typed);
        const local_ownership = try self.computeLocalOwnership(self.next_local);
        const result_convention = self.computeResultConvention(clause.return_type);
        const debug_span = clause.debug_span;
        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .source_group_id = group.id,
            .source_clause_index = clause_index,
            .debug_source_path = self.debugPathForSpan(debug_span),
            .debug_line = zeroBasedSourceCoordinate(debug_span.line),
            .debug_column = zeroBasedSourceCoordinate(debug_span.col),
            .struct_name = self.current_struct_prefix,
            .local_name = local_name,
            .scope_id = group.scope_id,
            .arity = group.arity,
            .params = final_params_typed,
            .return_type = typeIdToZigTypeWithStore(clause.return_type, self.type_store),
            .return_type_id = clause.return_type,
            .body = try self.allocSlice(Block, &.{.{
                .label = 0,
                .instructions = entry_instrs,
            }}),
            .is_closure = group.captures.len > 0,
            .captures = try captures.toOwnedSlice(self.allocator),
            .local_count = self.next_local,
            .param_conventions = param_conventions,
            .local_ownership = local_ownership,
            .result_convention = result_convention,
            .protocol_box_locals = try self.snapshotProtocolBoxLocals(),
        });
    }

    fn buildFunctionGroup(self: *IrBuilder, group: *const hir_mod.FunctionGroup) !void {
        if (group.clauses.len == 0) return;

        // Skip generic (unmonomorphized) functions — they contain type variables
        // that can't be lowered to concrete IR types. Only the monomorphized copies
        // (produced by the monomorphization pass) should be compiled.
        if (self.type_store) |ts| {
            if (isGenericHirGroup(ts, group)) return;
        }

        if (self.type_store != null and self.isTypeOnlyOverloadGroup(group)) {
            for (group.clauses, 0..) |*clause, clause_index| {
                try self.buildTypedClauseEntrypoint(group, clause, @intCast(clause_index));
            }
            return;
        }

        const func_id: FunctionId = group.id;
        self.next_local = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();
        self.local_hir_types.clearRetainingCapacity();
        self.param_backed_locals.clearRetainingCapacity();
        self.term_tuple_locals.clearRetainingCapacity();
        self.current_param_types = .empty;
        self.current_param_hir_types = .empty;

        // Use first clause for arity and return type
        const first_clause = &group.clauses[0];

        // Build params with generic names (__arg_N).
        // If all clauses agree on a param's type, use that type.
        // If clauses have different struct types, synthesize a union.
        // Otherwise fall back to anytype.
        var params: std.ArrayList(Param) = .empty;
        var union_param_idx: ?u32 = null;
        var optional_param_idx: ?u32 = null;
        var optional_struct_name: ?[]const u8 = null;
        var captures: std.ArrayList(Capture) = .empty;
        for (group.captures, 0..) |capture, idx| {
            const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
            try captures.append(self.allocator, .{
                .name = cap_name,
                .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                .ownership = capture.ownership,
            });
        }
        for (first_clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            var resolved_type = typeIdToZigTypeWithStore(param.type_id, self.type_store);
            var resolved_type_id: ?types_mod.TypeId = param.type_id;
            if (group.clauses.len > 1) {
                for (group.clauses[1..]) |clause| {
                    if (i < clause.params.len) {
                        const other_type = typeIdToZigTypeWithStore(clause.params[i].type_id, self.type_store);
                        const tags_differ = std.meta.activeTag(other_type) != std.meta.activeTag(resolved_type);
                        // Also check if both are struct_ref but with different names
                        const struct_names_differ = if (resolved_type == .struct_ref and other_type == .struct_ref)
                            !std.mem.eql(u8, resolved_type.struct_ref, other_type.struct_ref)
                        else
                            false;
                        if (tags_differ or struct_names_differ) {
                            // Check if this is a union synthesis candidate
                            if (try self.canUnionDispatch(group, @intCast(i))) |union_type_name| {
                                resolved_type = .{ .struct_ref = union_type_name };
                                resolved_type_id = null;
                                union_param_idx = @intCast(i);
                            } else if (self.canOptionalDispatch(group, @intCast(i))) |optional_candidate| {
                                // f(nil) / f(t :: T) shape — unify the
                                // param to `?T` and route via
                                // optional_dispatch IR.
                                const inner_ptr = try self.allocator.create(ZigType);
                                inner_ptr.* = .{ .struct_ref = optional_candidate.struct_name };
                                resolved_type = .{ .optional = inner_ptr };
                                resolved_type_id = optional_candidate.optional_type_id;
                                optional_param_idx = @intCast(i);
                                optional_struct_name = optional_candidate.struct_name;
                            } else {
                                resolved_type = .any;
                                resolved_type_id = null;
                            }
                            break;
                        }
                    }
                }
            }
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = resolved_type,
                .type_id = resolved_type_id,
            });
            try self.current_param_types.append(self.allocator, resolved_type);
            try self.current_param_hir_types.append(self.allocator, resolved_type_id orelse param.type_id);
        }

        // Reserve local indices used by destructure bindings across all clauses.
        // These locals are defined inside guard_blocks (separate Zig scopes),
        // so top-level code must start allocating ABOVE this range.
        self.next_local = computeMaxBindingLocalForClauses(group.clauses);

        var uses_decision_tree = false;

        if (group.clauses.len == 1) {
            // Single clause — no dispatch needed
            // Emit tuple/struct/binary/map bindings if present
            try self.emitTupleBindings(first_clause);
            try self.emitStructBindings(first_clause);
            try self.emitBinaryBindings(first_clause);
            try self.emitMapBindings(first_clause);
            const result_local = try self.lowerBlockExpecting(first_clause.body, first_clause.return_type);
            try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
        } else if (self.canSwitchDispatch(group)) |switch_param| {
            // Emit switch_return for integer literal dispatch
            var return_cases: std.ArrayList(ReturnCase) = .empty;
            var default_instrs_result: []const Instruction = &.{};
            var default_result: ?LocalId = null;

            for (group.clauses, 0..) |clause, clause_idx| {
                const is_last = clause_idx == group.clauses.len - 1;

                if (is_last) {
                    // Default clause — lower body into default_instrs
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.emitTupleBindings(&clause);
                    try self.emitStructBindings(&clause);
                    const result_local = try self.lowerBlockExpecting(clause.body, clause.return_type);
                    default_instrs_result = try self.current_instrs.toOwnedSlice(self.allocator);
                    default_result = result_local;
                    self.current_instrs = saved;
                } else {
                    // Literal case
                    const pat = clause.params[switch_param].pattern.?;
                    const lit_value: LiteralValue = switch (pat.literal) {
                        .int => |v| .{ .int = v },
                        else => unreachable,
                    };

                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    const body_result = try self.lowerBlockExpecting(clause.body, clause.return_type);
                    const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try return_cases.append(self.allocator, .{
                        .value = lit_value,
                        .body_instrs = body_instrs,
                        .return_value = body_result,
                    });
                }
            }

            try self.current_instrs.append(self.allocator, .{
                .switch_return = .{
                    .scrutinee_param = switch_param,
                    .cases = try return_cases.toOwnedSlice(self.allocator),
                    .default_instrs = default_instrs_result,
                    .default_result = default_result,
                },
            });
        } else if (union_param_idx) |u_param_idx| {
            // Union switch dispatch for struct type patterns
            var union_cases: std.ArrayList(UnionCase) = .empty;

            for (group.clauses) |clause| {
                const param = clause.params[u_param_idx];
                const variant_name = blk: {
                    if (param.pattern) |pat| {
                        if (pat.* == .struct_match) {
                            break :blk self.interner.get(pat.struct_match.type_name);
                        }
                    }
                    break :blk self.resolveTypeName(param.type_id);
                };

                // Build field bindings from struct_bindings on the clause
                var field_bindings: std.ArrayList(FieldBinding) = .empty;
                for (clause.struct_bindings) |sb| {
                    if (sb.param_index == u_param_idx) {
                        try field_bindings.append(self.allocator, .{
                            .field_name = self.interner.get(sb.field_name),
                            .local_name = try std.fmt.allocPrint(self.allocator, "__local_{d}", .{sb.local_index}),
                            .local_index = sb.local_index,
                        });
                    }
                }

                // Lower body
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                const body_result = try self.lowerBlockExpecting(clause.body, clause.return_type);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try union_cases.append(self.allocator, .{
                    .variant_name = variant_name,
                    .field_bindings = try field_bindings.toOwnedSlice(self.allocator),
                    .body_instrs = body_instrs,
                    .return_value = body_result,
                });
            }

            try self.current_instrs.append(self.allocator, .{
                .union_switch_return = .{
                    .scrutinee_param = u_param_idx,
                    .cases = try union_cases.toOwnedSlice(self.allocator),
                },
            });
        } else if (optional_param_idx) |o_param_idx| {
            // f(nil) / f(t :: T) optional dispatch. Lower each clause's
            // body separately. The struct clause's body must observe the
            // param as `T`, not `?T` — track `payload_local` so the ZIR
            // emitter can redirect `param_get(o_param_idx)` reads to it
            // while emitting the struct branch.
            //
            // `payload_local` is allocated AFTER the bodies are lowered.
            // HIR resets its own `next_local` to 0 per clause, so any
            // body bindings (`one = 1 :: i64`, etc.) get IDs starting at
            // 0 and march upward. Allocating payload_local up front
            // would collide with that range — `setLocal(payload_local,
            // payload_ref)` and the body's `local_set dest=0 value=...`
            // would write the same slot, and the ZIR drop emitted for
            // the payload would read whichever value happened to land
            // there last (a `comptime_int` from the body's literal,
            // tripping `arcPtrChild`'s pointer assertion). Lowering
            // first lets `next_local` advance past every body binding,
            // so payload_local lands in a unique slot.
            var nil_instrs_result: []const Instruction = &.{};
            var nil_result: ?LocalId = null;
            var struct_instrs_result: []const Instruction = &.{};
            var struct_result: ?LocalId = null;

            for (group.clauses) |clause| {
                const param = clause.params[o_param_idx];
                const is_nil_clause = blk: {
                    if (param.pattern) |pat| {
                        if (pat.* == .literal and pat.literal == .nil) break :blk true;
                    }
                    break :blk param.type_id == types_mod.TypeStore.NIL;
                };

                const saved = self.current_instrs;
                self.current_instrs = .empty;
                if (!is_nil_clause) {
                    // The struct clause might destructure other params via
                    // tuple/struct/binary/map patterns. Only emit those
                    // bindings; the optional-param itself is handled by
                    // the ZIR redirect rather than an explicit binding.
                    try self.emitTupleBindings(&clause);
                    try self.emitStructBindings(&clause);
                    try self.emitBinaryBindings(&clause);
                    try self.emitMapBindings(&clause);
                }
                const body_result = try self.lowerBlockExpecting(clause.body, clause.return_type);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                if (is_nil_clause) {
                    nil_instrs_result = body_instrs;
                    nil_result = body_result;
                } else {
                    struct_instrs_result = body_instrs;
                    struct_result = body_result;
                }
            }

            const payload_local = self.next_local;
            self.next_local += 1;
            if (optional_struct_name) |sname| {
                try self.known_local_types.put(payload_local, .{ .struct_ref = sname });
                // Populate the HIR type so `local_ownership` is computed
                // correctly for the payload local. Without this, the
                // ownership table tags `payload_local` as `.trivial` and
                // every downstream pass that consults `local_ownership`
                // (drop insertion, in particular) treats the local as if
                // it weren't ARC-managed — even when the underlying
                // struct is. This blocks the binarytrees-style fix where
                // drop insertion appends a `.release { payload_local }`
                // at the struct branch's end to balance the caller's
                // `.owned` convention retain.
                if (self.resolveNominalTypeId(sname)) |type_id| {
                    try self.local_hir_types.put(payload_local, type_id);
                }
            }

            try self.current_instrs.append(self.allocator, .{
                .optional_dispatch = .{
                    .scrutinee_param = o_param_idx,
                    .payload_local = payload_local,
                    .nil_instrs = nil_instrs_result,
                    .nil_result = nil_result,
                    .struct_instrs = struct_instrs_result,
                    .struct_result = struct_result,
                },
            });
        } else {
            uses_decision_tree = true;
            // General multi-clause dispatch via decision tree
            // Build PatternMatrix from clause params
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (group.clauses, 0..) |clause, clause_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                for (clause.params) |param| {
                    try pats.append(self.allocator, param.pattern);
                }
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(clause_idx),
                    .guard = clause.refinement,
                });
            }

            // Set up scrutinee_map: param indices as scrutinee IDs
            var scrutinee_ids: std.ArrayList(u32) = .empty;
            for (0..group.arity) |i| {
                try scrutinee_ids.append(self.allocator, @intCast(i));
            }

            var next_scrutinee_id: u32 = group.arity;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = group.arity,
                },
                try scrutinee_ids.toOwnedSlice(self.allocator),
                &next_scrutinee_id,
            );

            // Set up scrutinee_map: map scrutinee IDs to param_get locals
            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            for (0..group.arity) |i| {
                const param_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = param_local, .index = @intCast(i) },
                });
                // Track known types for Phase 3
                const param_type = typeIdToZigTypeWithStore(first_clause.params[i].type_id, self.type_store);
                if (param_type != .any) {
                    try self.known_local_types.put(param_local, param_type);
                }
                // Track HIR type so `emitLocalGet` can decide whether a
                // pattern-binding `.local_get` from this param requires a
                // follow-up `.retain`.
                try self.local_hir_types.put(param_local, first_clause.params[i].type_id);
                try self.param_backed_locals.put(param_local, {});
                try scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(decision, group.clauses, &scrutinee_map);
        }

        var entry_instrs: []const Instruction = try self.current_instrs.toOwnedSlice(self.allocator);

        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const mangled_raw_name = try mangleSymbolForZig(self.allocator, raw_name);
        const local_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_raw_name, group.arity });
        const name_str = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, local_name })
        else
            local_name;

        const return_type = typeIdToZigTypeWithStore(first_clause.return_type, self.type_store);

        // Register union dispatch info for call-site wrapping
        if (union_param_idx) |u_idx| {
            for (params.items) |p| {
                if (p.type_expr == .struct_ref) {
                    var variants = std.StringHashMap(void).init(self.allocator);
                    for (group.clauses) |clause| {
                        const clause_type = typeIdToZigTypeWithStore(clause.params[u_idx].type_id, self.type_store);
                        if (clause_type == .struct_ref) {
                            try variants.put(clause_type.struct_ref, {});
                        }
                    }
                    try self.union_dispatch_map.put(name_str, .{
                        .param_idx = u_idx,
                        .union_type_name = p.type_expr.struct_ref,
                        .variants = variants,
                    });
                    break;
                }
            }
        }

        // Rewrite tail-recursive self-calls into `tail_call` IR. The
        // ZIR backend's tail_call lowering picks musttail (TCO-safe
        // signatures) vs loopification (byref) — see `rewriteTailCalls`
        // doc for the dispatch rationale.
        entry_instrs = try self.rewriteTailCalls(entry_instrs, name_str, func_id, params.items, return_type);

        const has_tail_call = containsTailCall(entry_instrs);
        const tco_safe = isTcoEligible(params.items, return_type);
        const loopify = has_tail_call and !tco_safe;

        const entry_block = Block{
            .label = 0,
            .instructions = entry_instrs,
        };

        const final_params = try params.toOwnedSlice(self.allocator);

        // Collect default parameter values for call-site inlining
        var defaults_list: std.ArrayList(DefaultValue) = .empty;
        if (group.clauses.len == 1) {
            const clause = &group.clauses[0];
            var di: usize = clause.params.len;
            while (di > 0) {
                di -= 1;
                if (clause.params[di].default) |default_expr| {
                    const dv: DefaultValue = switch (default_expr.kind) {
                        .int_lit => |v| .{ .int = v },
                        .float_lit => |v| .{ .float = v },
                        .string_lit => |v| .{ .string = self.interner.get(v) },
                        .bool_lit => |v| .{ .bool_val = v },
                        .nil_lit => .nil,
                        else => break, // Non-constant default, can't inline
                    };
                    try defaults_list.insert(self.allocator, 0, dv); // prepend to maintain order
                } else break;
            }
        }

        const param_conventions = try self.computeParamConventions(final_params);
        const local_ownership = try self.computeLocalOwnership(self.next_local);
        const result_convention = self.computeResultConvention(first_clause.return_type);
        const debug_span = group.debug_span;
        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .debug_source_path = self.debugPathForSpan(debug_span),
            .debug_line = zeroBasedSourceCoordinate(debug_span.line),
            .debug_column = zeroBasedSourceCoordinate(debug_span.col),
            .struct_name = self.current_struct_prefix,
            .local_name = local_name,
            .scope_id = group.scope_id,
            .arity = group.arity,
            .params = final_params,
            .return_type = return_type,
            .return_type_id = first_clause.return_type,
            .body = try self.allocSlice(Block, &.{entry_block}),
            .is_closure = group.captures.len > 0,
            .captures = try captures.toOwnedSlice(self.allocator),
            .local_count = self.next_local,
            .defaults = try defaults_list.toOwnedSlice(self.allocator),
            .loopify = loopify,
            .param_conventions = param_conventions,
            .local_ownership = local_ownership,
            .result_convention = result_convention,
            .protocol_box_locals = try self.snapshotProtocolBoxLocals(),
        });

        // Generate a `__try` variant whenever the catch-basin pipeline asked
        // for one (i.e. the original function name is in `try_variant_names`).
        //
        // For multi-clause functions we go through the decision-tree dispatch
        // path. Single-clause functions are regularly emitted without
        // dispatch — but if the single clause has a non-trivial pattern
        // (literal, struct, tuple, refinement, etc.) the call can still fail
        // to match, and `~>` callers need a `__try` variant to detect that.
        // We synthesise one here using the same decision-tree machinery used
        // for multi-clause functions.
        const single_clause_has_dispatch = blk: {
            if (group.clauses.len != 1) break :blk false;
            const c = group.clauses[0];
            if (c.refinement != null) break :blk true;
            for (c.params) |p| {
                if (p.pattern) |pat| {
                    if (!isTotalMatchPattern(pat)) break :blk true;
                }
            }
            break :blk false;
        };
        const want_try_variant =
            self.try_variant_names.contains(name_str) and
            ((uses_decision_tree and group.clauses.len > 1) or single_clause_has_dispatch);
        if (want_try_variant) {
            // Use a high ID offset for __try variants to avoid colliding with
            // normal function group IDs (which come from HIR and are sequential).
            const try_func_id = self.next_try_id;
            self.next_try_id += 1;
            self.next_local = 0;
            self.current_instrs = .empty;
            self.known_local_types.clearRetainingCapacity();
            self.local_hir_types.clearRetainingCapacity();
            self.param_backed_locals.clearRetainingCapacity();
            self.term_tuple_locals.clearRetainingCapacity();

            // Reserve binding locals (same as normal function)
            self.next_local = computeMaxBindingLocalForClauses(group.clauses);

            // Re-build the decision tree with try_mode enabled
            self.try_mode = true;
            self.current_try_arity = group.arity;
            defer self.try_mode = false;

            var try_pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (group.clauses, 0..) |clause, clause_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                for (clause.params) |param| {
                    try pats.append(self.allocator, param.pattern);
                }
                try try_pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(clause_idx),
                    .guard = clause.refinement,
                });
            }

            var try_scrutinee_ids: std.ArrayList(u32) = .empty;
            for (0..group.arity) |i| {
                try try_scrutinee_ids.append(self.allocator, @intCast(i));
            }

            var try_next_scrutinee_id: u32 = group.arity;
            const try_decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try try_pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = group.arity,
                },
                try try_scrutinee_ids.toOwnedSlice(self.allocator),
                &try_next_scrutinee_id,
            );

            var try_scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer try_scrutinee_map.deinit();
            for (0..group.arity) |i| {
                const param_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = param_local, .index = @intCast(i) },
                });
                const param_type = typeIdToZigTypeWithStore(first_clause.params[i].type_id, self.type_store);
                if (param_type != .any) {
                    try self.known_local_types.put(param_local, param_type);
                }
                // Track HIR type for ARC-managed pattern-binding decisions.
                try self.local_hir_types.put(param_local, first_clause.params[i].type_id);
                try self.param_backed_locals.put(param_local, {});
                try try_scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(try_decision, group.clauses, &try_scrutinee_map);

            const try_entry_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            const try_entry_block = Block{
                .label = 0,
                .instructions = try_entry_instrs,
            };

            // Re-build captures for the __try variant
            var try_captures: std.ArrayList(Capture) = .empty;
            for (group.captures, 0..) |capture, idx| {
                const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
                try try_captures.append(self.allocator, .{
                    .name = cap_name,
                    .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                    .ownership = capture.ownership,
                });
            }

            // __try variant has the same params as the original (no handler param)
            var try_params: std.ArrayList(Param) = .empty;
            for (final_params) |p| try try_params.append(self.allocator, p);

            const try_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{name_str});
            const try_local_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{local_name});
            const try_final_params = try try_params.toOwnedSlice(self.allocator);
            const try_param_conventions = try self.computeParamConventions(try_final_params);
            const try_local_ownership = try self.computeLocalOwnership(self.next_local);
            const try_result_convention = self.computeResultConvention(first_clause.return_type);
            try self.functions.append(self.allocator, .{
                .id = try_func_id,
                .name = try_name,
                .debug_source_path = self.debugPathForSpan(debug_span),
                .debug_line = zeroBasedSourceCoordinate(debug_span.line),
                .debug_column = zeroBasedSourceCoordinate(debug_span.col),
                .struct_name = self.current_struct_prefix,
                .local_name = try_local_name,
                .scope_id = group.scope_id,
                .arity = group.arity,
                .params = try_final_params,
                .return_type = return_type,
                .body = try self.allocSlice(Block, &.{try_entry_block}),
                .is_closure = group.captures.len > 0,
                .captures = try try_captures.toOwnedSlice(self.allocator),
                .local_count = self.next_local,
                .param_conventions = try_param_conventions,
                .local_ownership = try_local_ownership,
                .result_convention = try_result_convention,
                .protocol_box_locals = try self.snapshotProtocolBoxLocals(),
            });
        }
    }

    /// Whether a given Zig type is safe to pass through an LLVM
    /// `musttail` call site without breaking the no-caller-frame-
    /// references invariant. Only types that fastcc passes/returns
    /// purely in registers qualify. Anything that the Zig backend
    /// classifies as `byref` (the `isByRef` predicate at
    /// `codegen/llvm/FuncGen.zig:7223`) — every non-zero struct,
    /// tuple, slice, list, map, optional-of-byref, tagged union, or
    /// `runtime.Term` — would force the caller to allocate on its own
    /// frame and pass a pointer; LLVM then rejects `musttail` because
    /// the callee retains a pointer into the caller's frame past the
    /// jump. The conservative approach: emit `tail_call` only when
    /// every parameter and the return type are scalar-by-value.
    fn isTcoSafeType(t: ZigType) bool {
        return switch (t) {
            .void,
            .bool_type,
            .nil,
            .i8,
            .i16,
            .i32,
            .i64,
            .i128,
            .u8,
            .u16,
            .u32,
            .u64,
            .u128,
            .f16,
            .f32,
            .f64,
            .f80,
            .f128,
            .usize,
            .isize,
            .atom,
            .never,
            .ptr,
            => true,
            // Anything routed through Zig's by-ref ABI is unsafe for
            // `musttail`. Strings (slices), structs, tuples, lists,
            // maps, tagged unions, optionals, term, function values,
            // and `any` all fall here. `protocol_box` is also by-ref
            // — `runtime.ProtocolBox` is a 16-byte extern struct.
            .string,
            .struct_ref,
            .tuple,
            .list,
            .map,
            .function,
            .tagged_union,
            .optional,
            .term,
            .any,
            .protocol_box,
            => false,
        };
    }

    fn isTcoEligible(params: []const Param, return_type: ZigType) bool {
        if (!isTcoSafeType(return_type)) return false;
        for (params) |p| {
            if (!isTcoSafeType(p.type_expr)) return false;
        }
        return true;
    }

    /// Rewrite tail-recursive calls in a function's instruction list.
    /// Scans for patterns where the last operation before a return/break is a
    /// recursive call to the same function, and replaces them with tail_call.
    ///
    /// Bails out without rewriting whenever any parameter or the
    /// return type is by-ref (struct, slice, list, map, …). Marking
    /// such a call as LLVM `musttail` is unsupportable on AArch64
    /// fastcc — the caller-frame allocas backing those args would
    /// have to survive the tail jump and LLVM rejects the IR with
    /// `failed to perform tail call elimination on a call site
    /// marked musttail`. Falling back to ordinary `call_named + ret`
    /// here is correctness-preserving (the recursion just builds a
    /// real frame). Restoring TCO for byref-shaped state is a
    /// separate, larger ABI design effort.
    /// Walk `instrs` (and any nested bodies the IR carries — switch
    /// cases, optional-dispatch branches) and report whether a
    /// `tail_call` instruction reaches the surface anywhere. Used to
    /// decide if a function's signature needs the loopification
    /// lowering path: `loopify = !isTcoEligible AND containsTailCall`.
    fn containsTailCall(instrs: []const Instruction) bool {
        for (instrs) |instr| {
            switch (instr) {
                .tail_call => return true,
                .switch_return => |sr| {
                    for (sr.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                    if (containsTailCall(sr.default_instrs)) return true;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                },
                .union_switch => |us| {
                    for (us.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                },
                .optional_dispatch => |od| {
                    if (containsTailCall(od.nil_instrs)) return true;
                    if (containsTailCall(od.struct_instrs)) return true;
                },
                .switch_literal => |sl| {
                    for (sl.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                    if (containsTailCall(sl.default_instrs)) return true;
                },
                .case_block => |cb| {
                    if (containsTailCall(cb.pre_instrs)) return true;
                    for (cb.arms) |arm| {
                        if (containsTailCall(arm.cond_instrs)) return true;
                        if (containsTailCall(arm.body_instrs)) return true;
                    }
                    if (containsTailCall(cb.default_instrs)) return true;
                },
                .guard_block => |gb| {
                    if (containsTailCall(gb.body)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Phase E.6: classify a trailing instruction sitting between a
    /// recursive `call_named` and its `ret` as "tail-mappable" — i.e.,
    /// an instruction the tail-call rewriter can reorder around the
    /// rewrite without changing semantics.
    ///
    /// The set of tail-mappable instructions covers the no-op /
    /// refcount-only opcodes that ARC infrastructure may emit between
    /// the call and the return:
    ///   * `.release` — post-call ARC release for a shared arg local,
    ///     or a forward-dataflow scope-exit drop synthesized by
    ///     ownership analysis.
    ///   * `.retain` — refcount bump that pairs with a downstream
    ///     release; semantically a no-op when paired but must be
    ///     preserved for accounting.
    ///   * `.borrow_value` — Phase C alias instruction; lowers to a
    ///     plain assignment with no runtime effect.
    ///   * `.copy_value` — Phase C copy instruction; lowers to
    ///     assignment + retain.
    ///   * `.move_value` — ownership transfer; lowers to assignment.
    ///
    /// Any other instruction between `call_named` and `ret` blocks
    /// the rewrite — the verifier's V6 invariant rejects such IR
    /// because the runtime stack would grow unboundedly on deep
    /// recursion.
    fn isTailMappableTrailingInstr(instr: Instruction) bool {
        return switch (instr) {
            .release, .retain, .borrow_value, .copy_value, .move_value => true,
            else => false,
        };
    }

    /// Phase E.6: a trailing instruction sitting between the recursive
    /// `call_named` and its `ret` is dropped on rewrite iff it is a
    /// `.release` whose target is one of the call's argument locals.
    /// Once the call becomes a `tail_call`, the callee inherits
    /// ownership of every arg through the tail jump — there is no
    /// "after the call" for that release to fire in (control transfers
    /// out of the function), and the next iteration's matching
    /// parameter already accounts for the refcount unit. Eliminating
    /// the per-arg releases is therefore the correct ownership-
    /// transfer accounting.
    ///
    /// Every other tail-mappable instruction (non-arg releases, retains,
    /// borrow_value, copy_value, move_value) is preserved before the
    /// new `tail_call` so it observes pre-tail refcounts and fires
    /// before control leaves the function.
    fn isTailReleaseOfArg(instr: Instruction, args: []const LocalId) bool {
        switch (instr) {
            .release => |r| {
                for (args) |arg_local| {
                    if (arg_local == r.value) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Phase E.8 orphan-share fix: when the tail-call rewriter drops a
    /// trailing `.release{value=X}` of a call-arg slot, it must also
    /// drop the matching `.share_value{dest=X, source=Y}` earlier in
    /// the body and substitute the call's arg `X` with `Y`. Otherwise
    /// the share_value's retain becomes orphaned (no matching release
    /// after the rewrite, since the callee inherits ownership through
    /// the tail jump) and accumulates +1 refcount per iteration —
    /// exactly the leak signature observed in Phase F retry-3.
    ///
    /// Builds the drop-set + substitution table by scanning the
    /// trailing instructions for arg-cleanup releases. Returns:
    ///   * `dropped_share_dests` — LocalIds of `.share_value`
    ///     instructions to elide from the prelude (caller-allocated
    ///     hash set populated here; caller frees).
    ///   * `arg_substitutions` — for each call arg, the source local
    ///     to substitute (caller-allocated hash map populated here).
    ///
    /// Lookup of the matching share_value walks the prelude (the
    /// instructions BEFORE the call slot) and finds the most recent
    /// `.share_value{dest=X, source=Y}`. If no match is found, only
    /// the release is dropped (existing E.6 behaviour); the call's
    /// arg stays as-is.
    fn collectOrphanShareRewrites(
        prelude: []const Instruction,
        trailing: []const Instruction,
        call_args: []const LocalId,
        dropped_share_dests: *std.AutoHashMap(LocalId, void),
        arg_substitutions: *std.AutoHashMap(LocalId, LocalId),
    ) !void {
        for (trailing) |trailing_instr| {
            const released_local = switch (trailing_instr) {
                .release => |r| r.value,
                else => continue,
            };
            // Only match arg-cleanup releases — those whose target
            // is one of the call's argument locals.
            var is_arg_release = false;
            for (call_args) |arg_local| {
                if (arg_local == released_local) {
                    is_arg_release = true;
                    break;
                }
            }
            if (!is_arg_release) continue;

            // Walk the prelude backward to find the most recent
            // `.share_value{dest=released_local, source=Y}`. The
            // backward scan matches the one share-per-arg produced
            // by `lowerExpr`'s arg-shape lowering; multiple shares
            // for the same dest cannot occur at the IR-builder
            // level (each share allocates a fresh `next_local`).
            var idx: usize = prelude.len;
            while (idx > 0) {
                idx -= 1;
                switch (prelude[idx]) {
                    .share_value => |sv| {
                        if (sv.dest == released_local) {
                            try dropped_share_dests.put(sv.dest, {});
                            try arg_substitutions.put(sv.dest, sv.source);
                            break;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Phase E.8: apply the substitution table to the call's arg
    /// list, producing a fresh slice when any arg changes. When no
    /// substitutions apply, returns the original slice (no copy).
    fn applyArgSubstitutions(
        allocator: std.mem.Allocator,
        args: []const LocalId,
        arg_substitutions: *const std.AutoHashMap(LocalId, LocalId),
    ) ![]const LocalId {
        if (arg_substitutions.count() == 0) return args;
        var any_change = false;
        for (args) |arg_local| {
            if (arg_substitutions.contains(arg_local)) {
                any_change = true;
                break;
            }
        }
        if (!any_change) return args;
        const new_args = try allocator.alloc(LocalId, args.len);
        for (args, 0..) |arg_local, i| {
            new_args[i] = arg_substitutions.get(arg_local) orelse arg_local;
        }
        return new_args;
    }

    fn rewriteTailCalls(
        self: *IrBuilder,
        instrs: []const Instruction,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
        params: []const Param,
        return_type: ZigType,
    ) ![]const Instruction {
        // Self-tail-calls are always rewritten to `tail_call` IR. The
        // ZIR backend chooses between two strategies at lowering time:
        //
        //   * `isTcoEligible(params, return_type)` true → emit
        //     `musttail call + ret`, the existing fast path. LLVM
        //     reuses the current frame.
        //   * `isTcoEligible` false → emit a loopification body —
        //     stack-slot stores plus `repeat` to the function-level
        //     `loop` block — so by-ref state recurses without growing
        //     the stack and without triggering LLVM's `musttail`
        //     legality check (which rejects byref signatures on
        //     fastcc-bound argument shapes).
        //
        // Earlier passes used to bail out here for byref signatures;
        // that left the recursion as a regular `call_named + ret`,
        // which compiled cleanly but blew the stack at scale. The
        // ZIR-level loopification dispatch makes the byref case work
        // correctly, so the IR rewrite always runs.
        _ = params;
        _ = return_type;

        var result: std.ArrayList(Instruction) = .empty;
        for (instrs) |instr| {
            switch (instr) {
                .switch_return => |sr| {
                    // Rewrite tail calls inside switch_return cases
                    var new_cases: std.ArrayList(ReturnCase) = .empty;
                    for (sr.cases) |case| {
                        const new_body = try self.rewriteTailCallsInBody(case.body_instrs, case.return_value, func_name, enclosing_function_id);
                        if (new_body.rewritten) {
                            try new_cases.append(self.allocator, .{
                                .value = case.value,
                                .body_instrs = new_body.instrs,
                                .return_value = null, // tail_call handles the return
                            });
                        } else {
                            try new_cases.append(self.allocator, case);
                        }
                    }
                    // Also check default arm
                    const new_default = try self.rewriteTailCallsInBody(sr.default_instrs, sr.default_result, func_name, enclosing_function_id);
                    try result.append(self.allocator, .{
                        .switch_return = .{
                            .scrutinee_param = sr.scrutinee_param,
                            .cases = try new_cases.toOwnedSlice(self.allocator),
                            .default_instrs = if (new_default.rewritten) new_default.instrs else sr.default_instrs,
                            .default_result = if (new_default.rewritten) null else sr.default_result,
                        },
                    });
                },
                .ret => |r| {
                    // Walk backward in `result` past any tail-mappable
                    // trailing instructions (releases, retains, and the
                    // Phase C alias/copy/move opcodes) to find the
                    // matching `call_named`. Several distinct sources
                    // can interleave instructions between the recursive
                    // call and the `ret`:
                    //
                    //   * Phase 6.2b's IR drop-insertion pass appends
                    //     `.release` instructions before terminator
                    //     returns for owned-at-ret locals.
                    //   * The share_value call-arg lowering emits per-
                    //     call cleanup `.release` IR immediately after
                    //     the call (every entry in
                    //     `shared_release_locals` becomes a post-call
                    //     release on the per-call shared dest local).
                    //   * Phase C's `arc_ownership` pass may rewrite
                    //     trailing `local_get` reads into
                    //     `.borrow_value` or `.copy_value`.
                    //   * Move/retain instructions can also surface
                    //     between the call and the ret as forward-
                    //     dataflow ownership normalisation evolves.
                    //
                    // When any of these fire on a tail-position
                    // recursive call, the naive "is the immediately-
                    // preceding instruction a call_named?" check
                    // fails. Walking past every tail-mappable trailing
                    // instruction restores the rewrite for the k-
                    // nucleotide hot loop and any other ARC-arg tail-
                    // recursive function. The verifier's V6 invariant
                    // (in `arc_verifier.zig`) catches the converse: any
                    // non-tail-mappable instruction sitting between a
                    // self-recursive call and its `ret` is rejected at
                    // compile time so deep recursion never silently
                    // blows the stack.
                    if (result.items.len > 0 and r.value != null) {
                        var probe: usize = result.items.len;
                        while (probe > 0 and isTailMappableTrailingInstr(result.items[probe - 1])) : (probe -= 1) {}
                        if (probe > 0 and result.items[probe - 1] == .call_named) {
                            const cn = result.items[probe - 1].call_named;
                            if (std.mem.eql(u8, cn.name, func_name) and r.value.? == cn.dest) {
                                // Phase E.8 orphan-share fix: scan
                                // the trailing arg-cleanup releases
                                // and find their matching prelude
                                // `.share_value` instructions. We
                                // will drop both the trailing
                                // release AND the matching
                                // `.share_value` from the prelude,
                                // then substitute the call's arg with
                                // the share's source. Without this,
                                // the share_value's retain would
                                // accumulate +1 refcount per
                                // iteration (Phase F retry-3 leak).
                                var dropped_share_dests = std.AutoHashMap(LocalId, void).init(self.allocator);
                                defer dropped_share_dests.deinit();
                                var arg_substitutions = std.AutoHashMap(LocalId, LocalId).init(self.allocator);
                                defer arg_substitutions.deinit();
                                try collectOrphanShareRewrites(
                                    result.items[0 .. probe - 1],
                                    result.items[probe..],
                                    cn.args,
                                    &dropped_share_dests,
                                    &arg_substitutions,
                                );

                                // For each trailing tail-mappable
                                // instruction, decide:
                                //   * `.release{value=arg}` — drop on
                                //     rewrite (callee inherits
                                //     ownership through tail jump).
                                //   * everything else — preserve before
                                //     the new `tail_call` so the
                                //     refcount op observes pre-tail
                                //     state and fires before control
                                //     leaves the function.
                                var preserved: std.ArrayList(Instruction) = .empty;
                                defer preserved.deinit(self.allocator);
                                for (result.items[probe..]) |trailing| {
                                    std.debug.assert(isTailMappableTrailingInstr(trailing));
                                    if (isTailReleaseOfArg(trailing, cn.args)) continue;
                                    try preserved.append(self.allocator, trailing);
                                }

                                // Build the new prelude in a fresh
                                // ArrayList, eliding any `.share_value`
                                // whose dest is in the drop set. We
                                // can't mutate `result.items[0..probe-1]`
                                // in place because shrinking it would
                                // require a memmove; collecting into
                                // a temp slice keeps the code clear.
                                var rebuilt_prelude: std.ArrayList(Instruction) = .empty;
                                defer rebuilt_prelude.deinit(self.allocator);
                                for (result.items[0 .. probe - 1]) |prelude_instr| {
                                    switch (prelude_instr) {
                                        .share_value => |sv| {
                                            if (dropped_share_dests.contains(sv.dest)) continue;
                                        },
                                        else => {},
                                    }
                                    try rebuilt_prelude.append(self.allocator, prelude_instr);
                                }

                                // Truncate result and re-emit the
                                // rebuilt prelude, preserved
                                // trailing instructions, and the new
                                // `tail_call` (with substituted args).
                                // The original `ret` is dropped — the
                                // tail_call is itself the terminator.
                                const substituted_args = try applyArgSubstitutions(self.allocator, cn.args, &arg_substitutions);
                                result.clearRetainingCapacity();
                                for (rebuilt_prelude.items) |kept| {
                                    try result.append(self.allocator, kept);
                                }
                                for (preserved.items) |kept| {
                                    try result.append(self.allocator, kept);
                                }
                                try result.append(self.allocator, .{ .tail_call = .{
                                    .name = cn.name,
                                    .args = substituted_args,
                                } });
                                continue; // skip the ret
                            }
                        }

                        // Phase E.7: structural tail-call through `if_expr`
                        // / `switch_literal` arms.
                        //
                        // Zap's `if-else` surface lowers to `switch_literal`
                        // (literal arms on a Bool scrutinee) or `if_expr`,
                        // and the value flowing out of the construct (the
                        // arms' merged result) is what feeds the function's
                        // `ret`. When each arm's last instruction is a
                        // self-recursive `call_named` whose `dest` is the
                        // arm's `result`, the recursion is genuinely in
                        // tail position — every CFG path from the construct
                        // to the function exit is `arm body -> recursive
                        // call -> arm result -> if/switch dest -> ret`. The
                        // top-level rewriter above only handles the case
                        // where the `call_named + ret` pair is already
                        // adjacent in the same stream; the structural case
                        // requires recursing INTO each arm and rewriting
                        // its tail position.
                        //
                        // Match the construct walking past trailing tail-
                        // mappable instructions exactly like the linear
                        // case. When the construct's `dest` matches the
                        // outer `ret`'s value, rewrite each arm via the
                        // existing `rewriteTailCallsInBody` helper. Arms
                        // whose body does NOT end in a self-recursive call
                        // (e.g., a base case returning a constant) are left
                        // alone — `rewriteTailCallsInBody` returns `null`
                        // for the rewritten flag and the original arm is
                        // preserved verbatim. This is correct: only the
                        // recursive arm needs the tail-call rewrite; the
                        // base case completes its arm body, joins at the
                        // construct's `dest`, and flows into the outer
                        // `ret` normally. The outer `ret` itself stays in
                        // place — it remains the terminator for non-
                        // rewritten arms; for rewritten arms the `tail_call`
                        // inside the arm jumps out of the function before
                        // control would have rejoined the merge.
                        // Only fire the structural rewrite when the
                        // branch is IMMEDIATELY followed by the outer
                        // `ret` (no intervening tail-mappable
                        // instructions). Tail-mappable instructions in
                        // the gap would be ARC bookkeeping on the
                        // merge value (e.g., a post-merge retain
                        // before ret); after the rewrite no merge
                        // value exists, so those instructions would
                        // have nothing to operate on. Keeping the
                        // gate strict avoids that ambiguity. The k-
                        // nucleotide hot loop falls in this strict
                        // window.
                        if (probe == result.items.len and probe > 0) {
                            const branch_instr = result.items[probe - 1];
                            const rewritten_branch = try self.tryRewriteTailThroughBranch(branch_instr, r.value.?, func_name, enclosing_function_id);
                            if (rewritten_branch) |new_branch| {
                                // The rewritten branch subsumes the
                                // outer `ret`: every arm now terminates
                                // itself (either via `tail_call` or via
                                // the `ret arm_result` pushed by
                                // `tryRewriteTailThroughBranch`). Drop
                                // the outer `ret` — control never
                                // reaches a merge. The shape mirrors
                                // `switch_return`'s self-terminating
                                // arms, which the ZIR backend already
                                // handles correctly under both musttail
                                // and loopify lowering.
                                result.items.len = probe - 1;
                                try result.append(self.allocator, new_branch);
                                continue;
                            }
                        }
                    }
                    try result.append(self.allocator, instr);
                },
                else => try result.append(self.allocator, instr),
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    const TailCallRewrite = struct {
        instrs: []const Instruction,
        rewritten: bool,
    };

    fn rewriteTailCallsInBody(
        self: *IrBuilder,
        body: []const Instruction,
        return_value: ?LocalId,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
    ) !TailCallRewrite {
        if (body.len == 0 or return_value == null) return .{ .instrs = body, .rewritten = false };

        // Walk backward past trailing tail-mappable instructions
        // (releases, retains, and the Phase C alias/copy/move opcodes)
        // to find the call. Mirrors the behaviour in
        // `rewriteTailCalls`: ARC infrastructure (share_value cleanup
        // releases, drop insertion, and the Phase C ownership
        // normalisation) interleaves no-op / refcount-only
        // instructions between the recursive call and the implicit
        // return; without walking past them the naive "is the last
        // instruction a call?" check fails. See `rewriteTailCalls` for
        // the full reasoning, including why per-arg releases must be
        // dropped on rewrite (the callee inherits ownership through
        // the tail jump) and how every other tail-mappable trailing
        // instruction is preserved before the new `tail_call`.
        var call_index: usize = body.len;
        while (call_index > 0 and isTailMappableTrailingInstr(body[call_index - 1])) : (call_index -= 1) {}
        if (call_index == 0) return .{ .instrs = body, .rewritten = false };
        const call_instr = body[call_index - 1];

        const trailing = body[call_index..];

        const TailCallShape = struct {
            args: []const LocalId,
            tail_name: []const u8,
            dest_matches: bool,
        };
        const shape: ?TailCallShape = blk: {
            switch (call_instr) {
                .call_direct => |cd| break :blk .{
                    .args = cd.args,
                    .tail_name = func_name,
                    // A `call_direct` only counts as a tail-recursive
                    // self-call when its `function` field references the
                    // enclosing function. Without this guard, a sibling-
                    // function call (e.g., `add_ten(0)` in a `case` arm
                    // of `compute`) would be rewritten into
                    // `tail_call name=compute`, producing unbounded
                    // self-recursion at runtime. The dest-equality
                    // check alone is insufficient: every direct call
                    // whose result becomes the arm's value satisfies
                    // it, regardless of which function was actually
                    // invoked.
                    .dest_matches = cd.function == enclosing_function_id and cd.dest == return_value.?,
                },
                .call_named => |cn| break :blk .{
                    .args = cn.args,
                    .tail_name = cn.name,
                    .dest_matches = std.mem.eql(u8, cn.name, func_name) and cn.dest == return_value.?,
                },
                else => break :blk null,
            }
        };
        if (shape == null or !shape.?.dest_matches) {
            return .{ .instrs = body, .rewritten = false };
        }
        const sh = shape.?;

        // Phase E.8 orphan-share fix — see `rewriteTailCalls` for
        // full reasoning. Mirror the same scan-and-substitute logic
        // here so structural tail-calls through `if_expr` /
        // `switch_literal` arms also benefit from the leak fix.
        var dropped_share_dests = std.AutoHashMap(LocalId, void).init(self.allocator);
        defer dropped_share_dests.deinit();
        var arg_substitutions = std.AutoHashMap(LocalId, LocalId).init(self.allocator);
        defer arg_substitutions.deinit();
        try collectOrphanShareRewrites(
            body[0 .. call_index - 1],
            trailing,
            sh.args,
            &dropped_share_dests,
            &arg_substitutions,
        );

        var preserved: std.ArrayList(Instruction) = .empty;
        defer preserved.deinit(self.allocator);
        for (trailing) |trailing_instr| {
            std.debug.assert(isTailMappableTrailingInstr(trailing_instr));
            if (isTailReleaseOfArg(trailing_instr, sh.args)) continue;
            try preserved.append(self.allocator, trailing_instr);
        }

        var new_body: std.ArrayList(Instruction) = .empty;
        for (body[0 .. call_index - 1]) |bi| {
            switch (bi) {
                .share_value => |sv| {
                    if (dropped_share_dests.contains(sv.dest)) continue;
                },
                else => {},
            }
            try new_body.append(self.allocator, bi);
        }
        for (preserved.items) |kept| {
            try new_body.append(self.allocator, kept);
        }
        const substituted_args = try applyArgSubstitutions(self.allocator, sh.args, &arg_substitutions);
        try new_body.append(self.allocator, .{
            .tail_call = .{ .name = sh.tail_name, .args = substituted_args },
        });
        return .{ .instrs = try new_body.toOwnedSlice(self.allocator), .rewritten = true };
    }

    /// Phase E.7: rewrite an `if_expr` / `switch_literal` whose `dest`
    /// flows into a function-level tail-position `ret`, descending into
    /// each arm and rewriting per-arm `call_named + arm_result == call.dest`
    /// shapes into `tail_call`. Returns the rewritten branch instruction
    /// when at least one arm was rewritten, otherwise `null` (so the
    /// caller leaves the original branch in place).
    ///
    /// `dest_local` is the LocalId that the outer `ret` consumes; the
    /// rewrite is gated on the branch's `dest` matching it. A mismatch
    /// (the branch's value flows somewhere else before reaching `ret`)
    /// means the arms are NOT in tail position and the rewrite would
    /// be unsound.
    ///
    /// Branch lowering: a `switch_literal` / `if_expr` is a value-
    /// producing expression. The ZIR backend lowers it to nested
    /// `if_else_bodies` whose merge produces `dest`. Without further
    /// changes, a single arm being rewritten to `tail_call` would
    /// leave the OTHER arm producing a typed value into the merge —
    /// in loopify mode (the ARC-managed/byref shape) the merge would
    /// be Map vs void, which Sema rejects. To make the construct
    /// type-uniform we push the outer `ret` INTO each non-recursive
    /// arm: append `ret arm_result` to the arm body and clear the
    /// arm's `result` field. The arm becomes noreturn (matching
    /// `switch_return`'s shape). The outer `ret` is left in place by
    /// the caller — it becomes dead code that Zig's ZIR/Sema accept
    /// without complaint, and it remains the explicit terminator if
    /// any arm bodies happen not to be rewritten or pushed (e.g., an
    /// empty arm, which today is an unreachable IR shape).
    ///
    /// In musttail mode every rewritten arm ends in `tail_call` →
    /// `musttail call + ret` (noreturn at ZIR level). Pushed-ret arms
    /// also end in `ret` (noreturn). The merge is never reached.
    ///
    /// In loopify mode the rewritten arm ends in `tail_call` → stores
    /// + fall-through to the wrapping `loop`'s trailing `repeat`.
    /// Pushed-ret arms end in `ret` (noreturn → exits the function,
    /// bypassing the loop). Both shapes are valid block-body
    /// terminators inside `if_else_bodies` because Sema treats
    /// fall-through-and-repeat the same as any normal break_inline.
    fn tryRewriteTailThroughBranch(
        self: *IrBuilder,
        branch_instr: Instruction,
        dest_local: LocalId,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
    ) !?Instruction {
        switch (branch_instr) {
            .if_expr => |ie| {
                if (ie.dest != dest_local) return null;
                const new_then = try self.rewriteTailCallsInBody(ie.then_instrs, ie.then_result, func_name, enclosing_function_id);
                const new_else = try self.rewriteTailCallsInBody(ie.else_instrs, ie.else_result, func_name, enclosing_function_id);
                if (!new_then.rewritten and !new_else.rewritten) return null;

                const final_then_instrs = if (new_then.rewritten)
                    new_then.instrs
                else
                    try self.appendRetToBody(ie.then_instrs, ie.then_result);
                const final_else_instrs = if (new_else.rewritten)
                    new_else.instrs
                else
                    try self.appendRetToBody(ie.else_instrs, ie.else_result);

                return Instruction{ .if_expr = .{
                    .dest = ie.dest,
                    .condition = ie.condition,
                    .then_instrs = final_then_instrs,
                    .then_result = null,
                    .else_instrs = final_else_instrs,
                    .else_result = null,
                } };
            },
            .switch_literal => |sl| {
                if (sl.dest != dest_local) return null;
                var any_rewritten = false;
                // First pass: discover whether any arm gets rewritten.
                // The pushed-ret transformation is gated on this
                // (arms only need to push the outer ret if at least
                // one sibling arm is taking the tail-call path).
                var rewrite_results: std.ArrayList(TailCallRewrite) = .empty;
                defer rewrite_results.deinit(self.allocator);
                for (sl.cases) |case| {
                    const r = try self.rewriteTailCallsInBody(case.body_instrs, case.result, func_name, enclosing_function_id);
                    if (r.rewritten) any_rewritten = true;
                    try rewrite_results.append(self.allocator, r);
                }
                const new_default = try self.rewriteTailCallsInBody(sl.default_instrs, sl.default_result, func_name, enclosing_function_id);
                if (new_default.rewritten) any_rewritten = true;
                if (!any_rewritten) return null;

                // Second pass: emit each arm in its final shape —
                // either the rewritten body (tail_call terminated) or
                // the original body with `ret arm_result` appended.
                var new_cases: std.ArrayList(LitCase) = .empty;
                for (sl.cases, 0..) |case, idx| {
                    const r = rewrite_results.items[idx];
                    const final_body = if (r.rewritten)
                        r.instrs
                    else
                        try self.appendRetToBody(case.body_instrs, case.result);
                    try new_cases.append(self.allocator, .{
                        .value = case.value,
                        .body_instrs = final_body,
                        .result = null,
                    });
                }
                const final_default = if (new_default.rewritten)
                    new_default.instrs
                else
                    try self.appendRetToBody(sl.default_instrs, sl.default_result);
                return Instruction{ .switch_literal = .{
                    .dest = sl.dest,
                    .scrutinee = sl.scrutinee,
                    .cases = try new_cases.toOwnedSlice(self.allocator),
                    .default_instrs = final_default,
                    .default_result = null,
                } };
            },
            else => return null,
        }
    }

    /// Phase E.7 helper: append a `ret arm_result` instruction to
    /// `body`, returning a freshly-allocated slice. Used by
    /// `tryRewriteTailThroughBranch` to push the outer `ret` into
    /// arms that did NOT get the tail-call rewrite, so every arm
    /// becomes noreturn and the if/switch construct type-merges
    /// uniformly under both musttail and loopify lowering.
    ///
    /// If `result` is `null`, the body is returned unchanged — the
    /// arm is already noreturn (e.g., it ends in `match_fail`) and
    /// adding a `ret` would emit an unreachable instruction after a
    /// noreturn terminator.
    fn appendRetToBody(
        self: *IrBuilder,
        body: []const Instruction,
        result: ?LocalId,
    ) ![]const Instruction {
        const ret_value = result orelse return body;
        // Detect bodies that already end in a noreturn terminator
        // (e.g., `match_fail`, `match_error_return`, `ret`, or a
        // tail_call). Such bodies should not have an extra `ret`
        // appended — the appended instruction would be unreachable.
        if (body.len > 0) {
            switch (body[body.len - 1]) {
                .ret, .match_fail, .match_error_return, .tail_call, .switch_return, .union_switch_return => return body,
                else => {},
            }
        }
        var new_body: std.ArrayList(Instruction) = .empty;
        for (body) |bi| try new_body.append(self.allocator, bi);
        try new_body.append(self.allocator, .{ .ret = .{ .value = ret_value } });
        return try new_body.toOwnedSlice(self.allocator);
    }

    /// Check if multi-clause function can emit switch_return for integer literals.
    /// Returns the param index to switch on if eligible.
    fn canSwitchDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup) ?u32 {
        if (group.clauses.len < 2) return null;

        var switch_param_idx: ?u32 = null;

        for (group.clauses, 0..) |clause, clause_idx| {
            const is_last = clause_idx == group.clauses.len - 1;

            if (is_last) {
                // Last clause must be wildcard/bind fallback (no literal pattern)
                for (clause.params) |param| {
                    if (param.pattern) |pat| {
                        if (pat.* == .literal) return null;
                    }
                }
                break;
            }

            // Non-last clauses must have literal pattern with no refinement
            if (clause.refinement != null) return null;

            // Find the literal param
            var found_literal_param: ?u32 = null;
            for (clause.params, 0..) |param, i| {
                if (param.pattern) |pat| {
                    if (pat.* == .literal) {
                        // Only integer literals can use switch
                        switch (pat.literal) {
                            .int => {},
                            else => return null,
                        }
                        found_literal_param = @intCast(i);
                    }
                }
            }

            if (found_literal_param == null) return null;

            if (switch_param_idx) |idx| {
                if (idx != found_literal_param.?) return null; // different param positions
            } else {
                // Check that the param type is a known integer type
                const param_type = typeIdToZigType(clause.params[found_literal_param.?].type_id);
                switch (param_type) {
                    .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => {},
                    else => return null,
                }
                switch_param_idx = found_literal_param;
            }
        }

        return switch_param_idx orelse {
            _ = self; // suppress unused
            return null;
        };
    }

    /// Detect the multi-clause `f(nil) / f(t :: T)` shape where every
    /// clause for `param_idx` is either the `nil` literal pattern or a
    /// non-nil pattern (typed bind / struct match) over the same nominal
    /// struct. The unified parameter type is `?T` so the call site can
    /// pass either `nil` or a `T` value, and the dispatcher routes on
    /// is-null. Returns the single struct type on success — caller
    /// promotes the param's `ZigType` to `optional(struct_ref T)`,
    /// preserves the optional union TypeId when one already exists in
    /// the TypeStore, and emits an `optional_dispatch` IR.
    ///
    /// Reasons to return null:
    ///  - fewer than two clauses
    ///  - no `TypeStore` (unit-test path with raw IR)
    ///  - any clause has a non-nil / non-struct type for this param
    ///  - more than one distinct struct type among the non-nil clauses
    ///  - all clauses are nil (degenerate) or all struct (no optional)
    fn canOptionalDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup, param_idx: u32) ?OptionalDispatchCandidate {
        if (group.clauses.len < 2) return null;
        const ts = self.type_store orelse return null;

        var struct_name: ?[]const u8 = null;
        var struct_type_id: ?types_mod.TypeId = null;
        var saw_nil = false;
        var saw_struct = false;

        for (group.clauses) |clause| {
            if (param_idx >= clause.params.len) return null;
            const param = clause.params[param_idx];
            const tid = param.type_id;

            // Match nil either by type or by literal pattern. Source
            // code like `pub fn count(nil)` parses with a `literal nil`
            // pattern and a still-unresolved param type_id; the
            // pattern is the authoritative signal.
            const is_nil_pattern = blk: {
                if (param.pattern) |pat| {
                    if (pat.* == .literal and pat.literal == .nil) break :blk true;
                }
                break :blk false;
            };

            if (is_nil_pattern or tid == types_mod.TypeStore.NIL) {
                saw_nil = true;
                continue;
            }

            if (tid >= ts.types.items.len) return null;
            const typ = ts.types.items[tid];
            switch (typ) {
                .struct_type => |st| {
                    const sname = self.interner.get(st.name);
                    if (struct_name) |existing| {
                        if (!std.mem.eql(u8, existing, sname)) return null;
                        if (struct_type_id != tid) return null;
                    } else {
                        struct_name = sname;
                        struct_type_id = tid;
                    }
                    saw_struct = true;
                },
                else => return null,
            }
        }

        if (!saw_nil or !saw_struct) return null;
        return .{
            .struct_name = struct_name.?,
            .struct_type_id = struct_type_id.?,
            .optional_type_id = findOptionalUnionTypeId(ts, struct_type_id.?),
        };
    }

    fn canUnionDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup, param_idx: u32) !?[]const u8 {
        if (group.clauses.len < 2) return null;
        const ts = self.type_store orelse return null;

        var type_names: std.ArrayList([]const u8) = .empty;

        for (group.clauses) |clause| {
            if (param_idx >= clause.params.len) return null;
            const param = clause.params[param_idx];

            // Check if this param has a struct_match pattern (struct pattern)
            if (param.pattern) |pat| {
                if (pat.* == .struct_match) {
                    const type_name = self.interner.get(pat.struct_match.type_name);
                    // Verify it's a known struct type
                    var found = false;
                    for (type_names.items) |existing| {
                        if (std.mem.eql(u8, existing, type_name)) return null; // duplicate type
                    }
                    // Check via type_id that it's really a struct
                    if (param.type_id < ts.types.items.len) {
                        const typ = ts.types.items[param.type_id];
                        if (typ == .struct_type) {
                            found = true;
                        }
                    }
                    if (!found) return null;
                    try type_names.append(self.allocator, type_name);
                    continue;
                }
            }

            // Also check via type_id if the param resolves to a struct type
            if (param.type_id < ts.types.items.len) {
                const typ = ts.types.items[param.type_id];
                if (typ == .struct_type) {
                    const type_name = ts.interner.get(typ.struct_type.name);
                    for (type_names.items) |existing| {
                        if (std.mem.eql(u8, existing, type_name)) return null; // duplicate
                    }
                    try type_names.append(self.allocator, type_name);
                    continue;
                }
            }

            // Not a struct type — can't do union dispatch
            return null;
        }

        if (type_names.items.len < 2) return null;

        // Build the union name from the function group name
        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const func_name = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, raw_name })
        else
            raw_name;
        const union_name = try std.fmt.allocPrint(self.allocator, "{s}_Union", .{func_name});

        // Synthesize the union type definition
        var variants: std.ArrayList(UnionVariant) = .empty;
        for (type_names.items) |tn| {
            try variants.append(self.allocator, .{
                .name = tn,
                .type_name = tn,
            });
        }

        try self.synthesized_type_defs.append(self.allocator, .{
            .name = union_name,
            .kind = .{ .union_def = .{
                .variants = try variants.toOwnedSlice(self.allocator),
            } },
        });

        return union_name;
    }

    /// Emit binary extraction instructions to populate binary binding locals.
    fn emitBinaryBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        // Find params that have binary patterns
        for (clause.params, 0..) |param, param_idx_usize| {
            const param_idx: u32 = @intCast(param_idx_usize);
            const pat = param.pattern orelse continue;
            if (pat.* != .binary_match) continue;

            // Get param local
            const data_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = data_local, .index = param_idx },
            });

            // Calculate min byte size and emit length check
            // For sub-byte types, accumulate bits then convert to bytes
            var min_bits: u32 = 0;
            for (pat.binary_match.segments) |seg| {
                switch (seg.type_spec) {
                    .default => min_bits += 8,
                    .integer => |i| min_bits += i.bits,
                    .float => |f| min_bits += f.bits,
                    .string => {
                        // Flush any partial byte first
                        if (min_bits % 8 != 0) min_bits = (min_bits + 7) / 8 * 8;
                        if (seg.string_literal) |sl| {
                            min_bits += @as(u32, @intCast(self.interner.get(sl).len)) * 8;
                        } else if (seg.size) |sz| {
                            switch (sz) {
                                .literal => |n| min_bits += n * 8,
                                .variable => {},
                            }
                        }
                    },
                    .utf8 => min_bits += 8,
                    .utf16 => min_bits += 16,
                    .utf32 => min_bits += 32,
                }
            }
            const min_bytes = (min_bits + 7) / 8;
            if (min_bytes > 0) {
                const len_check = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check, .scrutinee = data_local, .min_len = min_bytes },
                });
                // Wrap remaining extractions in a guard block
                // (for single-clause we just emit inline — the check ensures safety)
            }

            // Track running byte and bit offsets
            var byte_offset: u32 = 0;
            var bit_offset: u8 = 0; // bits consumed within current byte (for sub-byte types)
            var offset_is_dynamic = false;
            var dynamic_offset_local: LocalId = 0;

            for (pat.binary_match.segments, 0..) |seg, seg_idx_usize| {
                const seg_idx: u32 = @intCast(seg_idx_usize);

                // Find the binding for this segment (if any)
                var binding_local: ?LocalId = null;
                for (clause.binary_bindings) |binding| {
                    if (binding.param_index == param_idx and binding.segment_index == seg_idx) {
                        binding_local = binding.local_index;
                        break;
                    }
                }

                // Handle string literal prefix segments
                if (seg.string_literal) |sl| {
                    const prefix_str = self.interner.get(sl);
                    const prefix_check = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .bin_match_prefix = .{
                            .dest = prefix_check,
                            .source = data_local,
                            .expected = prefix_str,
                        },
                    });
                    byte_offset += @intCast(prefix_str.len);
                    continue;
                }

                const current_offset: BinOffset = if (offset_is_dynamic)
                    .{ .dynamic = dynamic_offset_local }
                else
                    .{ .static = byte_offset };

                switch (seg.type_spec) {
                    .default => {
                        // Flush any partial bit offset to byte boundary
                        if (bit_offset > 0) {
                            byte_offset += 1;
                            bit_offset = 0;
                        }
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = 8,
                                    .signed = false,
                                    .endianness = .big,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += 1;
                    },
                    .integer => |int_spec| {
                        if (int_spec.bits < 8) {
                            // Sub-byte: track bit offset, compute shift
                            // Bits are extracted MSB-first within a byte
                            const shift: u8 = 8 - bit_offset - @as(u8, @intCast(int_spec.bits));
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_read_int = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .bits = int_spec.bits,
                                        .signed = int_spec.signed,
                                        .endianness = seg.endianness,
                                        .bit_offset = shift,
                                    },
                                });
                            }
                            bit_offset += @intCast(int_spec.bits);
                            if (bit_offset >= 8) {
                                byte_offset += bit_offset / 8;
                                bit_offset = bit_offset % 8;
                            }
                        } else {
                            // Flush any partial bit offset
                            if (bit_offset > 0) {
                                byte_offset += 1;
                                bit_offset = 0;
                            }
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_read_int = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .bits = int_spec.bits,
                                        .signed = int_spec.signed,
                                        .endianness = seg.endianness,
                                    },
                                });
                            }
                            if (!offset_is_dynamic) byte_offset += (int_spec.bits + 7) / 8;
                        }
                    },
                    .float => |float_spec| {
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_float = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = float_spec.bits,
                                    .endianness = seg.endianness,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += float_spec.bits / 8;
                    },
                    .string => {
                        if (seg.size) |size| {
                            switch (size) {
                                .literal => |n| {
                                    if (binding_local) |dest| {
                                        try self.current_instrs.append(self.allocator, .{
                                            .bin_slice = .{
                                                .dest = dest,
                                                .source = data_local,
                                                .offset = current_offset,
                                                .length = .{ .static = n },
                                            },
                                        });
                                    }
                                    if (!offset_is_dynamic) byte_offset += n;
                                },
                                .variable => |var_name| {
                                    const var_local = findBinaryVarLocal(clause, var_name);
                                    if (binding_local) |dest| {
                                        try self.current_instrs.append(self.allocator, .{
                                            .bin_slice = .{
                                                .dest = dest,
                                                .source = data_local,
                                                .offset = current_offset,
                                                .length = .{ .dynamic = var_local },
                                            },
                                        });
                                    }
                                    // After a dynamic-size segment, offset becomes dynamic
                                    if (!offset_is_dynamic) {
                                        // new_offset = byte_offset + var_local
                                        const static_base = self.next_local;
                                        self.next_local += 1;
                                        try self.current_instrs.append(self.allocator, .{
                                            .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                                        });
                                        dynamic_offset_local = self.next_local;
                                        self.next_local += 1;
                                        try self.current_instrs.append(self.allocator, .{
                                            .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = var_local },
                                        });
                                        offset_is_dynamic = true;
                                    }
                                },
                            }
                        } else {
                            // Rest of data
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_slice = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .length = null,
                                    },
                                });
                            }
                        }
                    },
                    .utf8 => {
                        if (binding_local) |dest| {
                            const len_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_utf8 = .{
                                    .dest_codepoint = dest,
                                    .dest_len = len_local,
                                    .source = data_local,
                                    .offset = current_offset,
                                },
                            });
                            // UTF-8 is variable width — offset becomes dynamic
                            if (!offset_is_dynamic) {
                                const static_base = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                                });
                                dynamic_offset_local = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = len_local },
                                });
                                offset_is_dynamic = true;
                            }
                        }
                    },
                    .utf16, .utf32 => {
                        // TODO: implement utf16/utf32
                    },
                }
            }
        }
    }

    fn findBinaryVarLocal(clause: *const hir_mod.Clause, var_name: ast.StringId) LocalId {
        for (clause.binary_bindings) |binding| {
            if (binding.name == var_name) return binding.local_index;
        }
        return 0;
    }

    /// Emit binary segment extraction instructions for case expression bindings.
    /// Iterates over the binary match segments, computes byte/bit offsets, and
    /// emits bin_read_int/bin_read_float/bin_slice instructions targeting the
    /// binding locals from the case arm's CaseBinding entries.
    fn emitBinarySegmentExtractions(
        self: *IrBuilder,
        segments: []const hir_mod.BinaryMatchSegment,
        data_local: LocalId,
        case_arms: []const hir_mod.CaseArm,
    ) !void {
        var byte_offset: u32 = 0;
        var bit_offset: u8 = 0;
        var offset_is_dynamic = false;
        var dynamic_offset_local: LocalId = 0;

        for (segments, 0..) |seg, seg_idx_usize| {
            const seg_idx: u32 = @intCast(seg_idx_usize);

            // Find the binding local for this segment (if any) from case arm bindings
            var binding_local: ?LocalId = null;
            for (case_arms) |arm| {
                for (arm.bindings) |binding| {
                    if (binding.kind == .binary_element and binding.element_index == seg_idx) {
                        binding_local = binding.local_index;
                        break;
                    }
                }
                if (binding_local != null) break;
            }

            // Handle string literal prefix segments
            if (seg.string_literal) |sl| {
                const prefix_str = self.interner.get(sl);
                byte_offset += @intCast(prefix_str.len);
                continue;
            }

            const current_offset: BinOffset = if (offset_is_dynamic)
                .{ .dynamic = dynamic_offset_local }
            else
                .{ .static = byte_offset };

            switch (seg.type_spec) {
                .default => {
                    if (bit_offset > 0) {
                        byte_offset += 1;
                        bit_offset = 0;
                    }
                    if (binding_local) |dest| {
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_int = .{
                                .dest = dest,
                                .source = data_local,
                                .offset = current_offset,
                                .bits = 8,
                                .signed = false,
                                .endianness = .big,
                            },
                        });
                    }
                    if (!offset_is_dynamic) byte_offset += 1;
                },
                .integer => |int_spec| {
                    if (int_spec.bits < 8) {
                        const shift: u8 = 8 - bit_offset - @as(u8, @intCast(int_spec.bits));
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = int_spec.bits,
                                    .signed = int_spec.signed,
                                    .endianness = seg.endianness,
                                    .bit_offset = shift,
                                },
                            });
                        }
                        bit_offset += @intCast(int_spec.bits);
                        if (bit_offset >= 8) {
                            byte_offset += bit_offset / 8;
                            bit_offset = bit_offset % 8;
                        }
                    } else {
                        if (bit_offset > 0) {
                            byte_offset += 1;
                            bit_offset = 0;
                        }
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = int_spec.bits,
                                    .signed = int_spec.signed,
                                    .endianness = seg.endianness,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += (int_spec.bits + 7) / 8;
                    }
                },
                .float => |float_spec| {
                    if (binding_local) |dest| {
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_float = .{
                                .dest = dest,
                                .source = data_local,
                                .offset = current_offset,
                                .bits = float_spec.bits,
                                .endianness = seg.endianness,
                            },
                        });
                    }
                    if (!offset_is_dynamic) byte_offset += float_spec.bits / 8;
                },
                .string => {
                    if (seg.size) |size| {
                        switch (size) {
                            .literal => |n| {
                                if (binding_local) |dest| {
                                    try self.current_instrs.append(self.allocator, .{
                                        .bin_slice = .{
                                            .dest = dest,
                                            .source = data_local,
                                            .offset = current_offset,
                                            .length = .{ .static = n },
                                        },
                                    });
                                }
                                if (!offset_is_dynamic) byte_offset += n;
                            },
                            .variable => {
                                // Dynamic-size string segments in case patterns
                                // are not yet supported for extraction.
                            },
                        }
                    } else {
                        // Rest of data (no explicit size)
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_slice = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .length = null,
                                },
                            });
                        }
                    }
                },
                .utf8 => {
                    if (binding_local) |dest| {
                        const len_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_utf8 = .{
                                .dest_codepoint = dest,
                                .dest_len = len_local,
                                .source = data_local,
                                .offset = current_offset,
                            },
                        });
                        if (!offset_is_dynamic) {
                            const static_base = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                            });
                            dynamic_offset_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = len_local },
                            });
                            offset_is_dynamic = true;
                        }
                    }
                },
                .utf16, .utf32 => {},
            }
        }
    }

    /// Emit index_get instructions to populate tuple binding locals.
    ///
    /// Each binding's `local_index` carries the runtime value of one slot of
    /// the tuple-typed parameter. Downstream IR passes (container dispatch,
    /// protocol dispatch, numeric widening, generic call-name encoding) read
    /// per-local types from `known_local_types`, so both the parent tuple
    /// local and each destructured element local must be registered with
    /// their concrete types here. Without it, an in-body `Map.get(m, ...)`
    /// where `m` came from `{m, k} :: {%{K=>V}, ...}` would default to the
    /// generic `Map(u32, ...)` variant and fail to type-check at the ZIR
    /// boundary; the parallel issue affects `<>` (Concatenable) on
    /// destructured String elements.
    fn emitTupleBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.tuple_bindings) |binding| {
            // Get the param (the tuple)
            const tuple_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = tuple_local, .index = binding.param_index },
            });
            // Resolve the parent tuple's static type so we can hand the
            // backend per-element types. The clause's declared parameter
            // types are authoritative after monomorphization (mirrors the
            // `param_get` lowering at `lowerExpr`).
            const param_type: ZigType = if (binding.param_index < clause.params.len)
                typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store)
            else
                ZigType.any;
            if (param_type != .any) {
                try self.known_local_types.put(tuple_local, param_type);
            }
            // Resolve the element's HIR type from the parent tuple's
            // HIR type so `emitArcRetainOnAggregateExtract` can detect
            // an ARC-managed extraction. The clause's declared parameter
            // type is authoritative after monomorphization.
            if (binding.param_index < clause.params.len) {
                const param_hir_type = clause.params[binding.param_index].type_id;
                if (self.type_store) |ts| {
                    const tuple_type = ts.getType(param_hir_type);
                    if (tuple_type == .tuple and binding.element_index < tuple_type.tuple.elements.len) {
                        const elem_hir_type = tuple_type.tuple.elements[binding.element_index];
                        try self.local_hir_types.put(binding.local_index, elem_hir_type);
                    }
                }
            }
            // Extract the element into the binding's local index
            try self.current_instrs.append(self.allocator, .{
                .index_get = .{
                    .dest = binding.local_index,
                    .object = tuple_local,
                    .index = binding.element_index,
                },
            });
            // Retain the extracted ARC value: a tuple is non-ARC and
            // its `index_get` lowers to `elem_val_imm`, which never
            // bumps the cell's refcount. Without this retain, multiple
            // destructures of the same tuple (or of distinct tuples
            // that share the underlying ARC pointer) would each fire
            // a scope-exit release against a single +1.
            try self.emitArcRetainOnAggregateExtract(binding.local_index);
            // Propagate the static element type so downstream lookups (e.g.
            // `Map.get`'s key/value resolution, `<>`'s Concatenable dispatch,
            // numeric widening, generic call-name encoding) see the right
            // type for the destructured local.
            if (param_type == .tuple and binding.element_index < param_type.tuple.len) {
                const elem_type = param_type.tuple[binding.element_index];
                if (elem_type != .any) {
                    try self.known_local_types.put(binding.local_index, elem_type);
                }
            }
        }
    }

    /// Emit field_get instructions to populate struct binding locals.
    fn emitStructBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.struct_bindings) |binding| {
            const struct_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = struct_local, .index = binding.param_index },
            });
            // Track the param's struct type so the field_get lookup
            // resolves the nominal type and can attach storage info.
            const struct_name = self.interner.get(binding.struct_type);
            try self.known_local_types.put(struct_local, .{ .struct_ref = struct_name });
            const field_name = self.interner.get(binding.field_name);
            const info = self.fieldZigTypeAndStorage(struct_name, field_name);
            // Plumb the field's HIR type onto the destructured local so
            // `emitArcRetainOnAggregateExtract` can detect an ARC-managed
            // extraction. Mirrors the equivalent plumbing for tuple
            // bindings.
            if (self.lookupStructFieldHirType(binding.struct_type, binding.field_name)) |field_hir_type| {
                try self.local_hir_types.put(binding.local_index, field_hir_type);
            }
            try self.current_instrs.append(self.allocator, .{
                .field_get = .{
                    .dest = binding.local_index,
                    .object = struct_local,
                    .field = field_name,
                    .struct_type = struct_name,
                },
            });
            // Retain the extracted ARC value: a plain struct's
            // `field_get` lowers to `field_val`, which never bumps the
            // cell's refcount. Without this retain, multiple struct
            // destructures of distinct parents that share the same
            // underlying ARC pointer would each fire a scope-exit
            // release against a single +1.
            try self.emitArcRetainOnAggregateExtract(binding.local_index);
            if (info) |i| {
                try self.known_local_types.put(binding.local_index, i.type_expr);
            }
        }
    }

    fn emitMapBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.map_bindings) |binding| {
            // Get the param (the map)
            const map_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = map_local, .index = binding.param_index },
            });
            // Resolve the map's key/value types from the clause's
            // declared parameter type so the ZIR emitter instantiates
            // the right `Map(K, V)` cell for the runtime call. Without
            // this the emitter would default to `.atom`/`.i64`.
            const param_type = if (binding.param_index < clause.params.len)
                typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store)
            else
                ZigType.any;
            const key_type: ZigType = if (param_type == .map) param_type.map.key.* else .atom;
            const value_type: ZigType = if (param_type == .map) param_type.map.value.* else .i64;
            // Track the binding's value type so `var_ref` lookups against
            // the destructured local emit correctly-typed downstream
            // instructions (e.g. string concat, arithmetic).
            try self.known_local_types.put(binding.local_index, value_type);
            // Track the param's map type so subsequent `map_get` locals
            // resolved through this same param_get path see the right
            // K/V (e.g. for `Map.get` calls in the body).
            if (param_type != .any) {
                try self.known_local_types.put(map_local, param_type);
            }
            // Lower the key expression to get the key local
            const key_local = try self.lowerExpr(binding.key_expr);
            // Create a default value matching the map's value type. The
            // pattern destructure semantically assumes the key exists,
            // so the default is unreachable at runtime — but the
            // compiler still type-checks it against the runtime
            // `Map(K, V).get` signature, so we must produce a value of
            // the right Zig type or the call won't typecheck.
            const default_local = try self.emitDefaultValueForType(value_type);
            // Plumb the map's value HIR type onto the destructured
            // local so `emitArcRetainOnAggregateExtract` can detect an
            // ARC-managed extraction. Without this, an extracted map
            // value of an ARC-managed type (List, Map, recursive
            // struct, etc.) reaches `arc_managed_locals` only via
            // `local_ownership` derived from `local_hir_types` — and
            // the latter would be unset, classifying the local as
            // `.trivial` and silencing every downstream retain/release
            // emission. This is the same bug shape that produced the
            // binarytrees ~12 GB leak (commit 122bf73).
            if (binding.param_index < clause.params.len) {
                const param_hir_type = clause.params[binding.param_index].type_id;
                if (self.type_store) |ts| {
                    if (ts.getType(param_hir_type) == .map) {
                        const value_hir_type = ts.getType(param_hir_type).map.value;
                        try self.local_hir_types.put(binding.local_index, value_hir_type);
                    }
                }
            }
            // Extract the value via map_get
            try self.current_instrs.append(self.allocator, .{
                .map_get = .{
                    .dest = binding.local_index,
                    .map = map_local,
                    .key = key_local,
                    .default = default_local,
                    .key_type = key_type,
                    .value_type = value_type,
                },
            });
            // Retain the extracted ARC value at the IR level. The
            // matching scope-exit `.release` is inserted by
            // `arc_drop_insertion` once the binding's local enters
            // `arc_managed_locals` (via the `local_hir_types`
            // plumbing above).
            try self.emitArcRetainOnAggregateExtract(binding.local_index);
        }
    }

    /// Emit a default value of the given Zig type for use as `Map(K, V).get`'s
    /// `default` parameter when destructuring assumes key presence. The
    /// concrete runtime never observes this value (the get hits the existing
    /// entry), but the call must still typecheck through the monomorphised
    /// `Map(K, V).get` signature.
    fn emitDefaultValueForType(self: *IrBuilder, value_type: ZigType) !LocalId {
        const default_local = self.next_local;
        self.next_local += 1;
        switch (value_type) {
            .string => {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = default_local, .value = "" },
                });
            },
            .bool_type => {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = default_local, .value = false },
                });
            },
            .f32, .f64, .f16, .f80, .f128 => {
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = default_local, .value = 0.0 },
                });
            },
            .atom => {
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = default_local, .value = 0 },
                });
            },
            .nil => {
                try self.current_instrs.append(self.allocator, .{
                    .const_nil = default_local,
                });
            },
            else => {
                // Numeric or unknown — `0` works as a placeholder for
                // any integer type the runtime cell instantiates.
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = default_local, .value = 0 },
                });
            },
        }
        return default_local;
    }

    /// AND two boolean locals together.
    fn emitAnd(self: *IrBuilder, lhs: LocalId, rhs: LocalId) !LocalId {
        const result = self.next_local;
        self.next_local += 1;
        try self.current_instrs.append(self.allocator, .{
            .binary_op = .{ .dest = result, .op = .bool_and, .lhs = lhs, .rhs = rhs },
        });
        return result;
    }

    /// AND a refinement predicate with an existing condition, if present.
    fn emitRefinement(self: *IrBuilder, clause: *const hir_mod.Clause, condition: LocalId) !LocalId {
        if (clause.refinement) |ref_expr| {
            const ref_local = try self.lowerExpr(ref_expr);
            return self.emitAnd(condition, ref_local);
        }
        return condition;
    }

    /// Emit a check for a literal sub-pattern against an already-extracted element local.
    fn emitSubPatternCheck(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue) !LocalId {
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v) },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v) },
                });
                return match_local;
            },
            else => {
                // For bool, nil sub-patterns in tuples
                const lit_local = self.next_local;
                self.next_local += 1;
                switch (lit) {
                    .bool_val => |v| try self.current_instrs.append(self.allocator, .{
                        .const_bool = .{ .dest = lit_local, .value = v },
                    }),
                    .nil => try self.current_instrs.append(self.allocator, .{ .const_nil = lit_local }),
                    else => unreachable,
                }
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = elem_local, .rhs = lit_local },
                });
                return cmp_local;
            },
        };
    }

    /// Lower a case expression: reserve binding locals, then allocate dest/scrutinee,
    /// then build the case_block. Returns the dest local ID.
    fn lowerCaseExpr(self: *IrBuilder, case_data: hir_mod.CaseData) !LocalId {
        // Reserve binding local indices FIRST so that dest and scrutinee
        // don't conflict with locals defined inside if-scoped blocks.
        {
            var max_binding_local: u32 = self.next_local;
            for (case_data.arms) |arm| {
                for (arm.bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
            }
            self.next_local = max_binding_local;
        }

        // NOW allocate dest (after reservation — no shadowing risk)
        const dest = self.next_local;
        self.next_local += 1;

        // Lower scrutinee (also after reservation)
        const saved_expected_type = self.current_expected_type;
        self.current_expected_type = null;
        const scrutinee_local = try self.lowerExpr(case_data.scrutinee);
        self.current_expected_type = saved_expected_type;

        try self.lowerCaseExprBody(dest, scrutinee_local, case_data);
        return dest;
    }

    /// Check if all non-default arms are integer or bool literals of the same type with no guards.
    const SwitchableType = enum { int, bool_val };
    fn canSwitchLiteral(arms: []const hir_mod.CaseArm) ?SwitchableType {
        if (arms.len < 2) return null;

        var switchable_type: ?SwitchableType = null;

        for (arms, 0..) |arm, arm_idx| {
            const is_last = arm_idx == arms.len - 1;
            const pat = arm.pattern orelse return null;

            // Any arm with a guard disqualifies
            if (arm.guard != null) return null;

            if (pat.* == .wildcard or pat.* == .bind) {
                // Wildcard/bind is allowed only as the last arm (default)
                if (!is_last) return null;
                // Default arm is ok
                continue;
            }

            if (pat.* != .literal) return null;

            const lit_type: SwitchableType = switch (pat.literal) {
                .int => .int,
                .bool_val => .bool_val,
                else => return null, // atoms, strings, floats can't switch
            };

            if (switchable_type) |st| {
                if (st != lit_type) return null; // mixed types
            } else {
                switchable_type = lit_type;
            }
        }

        return switchable_type;
    }

    /// Build the case_block instruction body.
    fn lowerCaseExprBody(self: *IrBuilder, dest: LocalId, scrutinee_local: LocalId, case_data: hir_mod.CaseData) !void {
        // Try to emit a switch for homogeneous integer/bool literals with no guards
        if (canSwitchLiteral(case_data.arms)) |_| {
            var lit_cases: std.ArrayList(LitCase) = .empty;

            for (case_data.arms, 0..) |arm, arm_idx| {
                const is_last = arm_idx == case_data.arms.len - 1;
                const pat = arm.pattern.?;

                if (is_last and (pat.* == .wildcard or pat.* == .bind)) {
                    // Default arm
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;

                    if (pat.* == .bind) {
                        for (arm.bindings) |binding| {
                            if (binding.kind == .scrutinee) {
                                try self.emitLocalGet(binding.local_index, scrutinee_local);
                            }
                        }
                    }

                    const body_result = try self.lowerBlock(arm.body);
                    const default_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try self.current_instrs.append(self.allocator, .{
                        .switch_literal = .{
                            .dest = dest,
                            .scrutinee = scrutinee_local,
                            .cases = try lit_cases.toOwnedSlice(self.allocator),
                            .default_instrs = default_instrs,
                            .default_result = body_result,
                        },
                    });
                    return;
                }

                // Literal case arm
                const lit_value: LiteralValue = switch (pat.literal) {
                    .int => |v| .{ .int = v },
                    .bool_val => |v| .{ .bool_val = v },
                    else => unreachable,
                };

                const saved = self.current_instrs;
                self.current_instrs = .empty;
                const body_result = try self.lowerBlock(arm.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try lit_cases.append(self.allocator, .{
                    .value = lit_value,
                    .body_instrs = body_instrs,
                    .result = body_result,
                });
            }

            // All arms are literal (no default) — add match_fail as default
            const saved = self.current_instrs;
            self.current_instrs = .empty;
            try self.current_instrs.append(self.allocator, .{
                .match_fail = .{ .message = "no matching case clause" },
            });
            const fail_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved;

            try self.current_instrs.append(self.allocator, .{
                .switch_literal = .{
                    .dest = dest,
                    .scrutinee = scrutinee_local,
                    .cases = try lit_cases.toOwnedSlice(self.allocator),
                    .default_instrs = fail_instrs,
                    .default_result = null,
                },
            });
            return;
        }

        // General path: compile pattern matrix and lower decision tree
        {
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (case_data.arms, 0..) |arm, arm_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                try pats.append(self.allocator, arm.pattern);
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(arm_idx),
                    .guard = arm.guard,
                });
            }

            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            try scrutinee_map.put(0, scrutinee_local);

            var next_scrutinee_id: u32 = 1;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = 1,
                },
                try self.allocSlice(u32, &.{0}),
                &next_scrutinee_id,
            );

            // Emit case_block wrapping the decision tree lowering
            const saved_outer = self.current_instrs;
            self.current_instrs = .empty;
            try self.lowerDecisionTreeForCase(decision, case_data.arms, &scrutinee_map, dest);
            const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved_outer;

            try self.current_instrs.append(self.allocator, .{
                .case_block = .{
                    .dest = dest,
                    .pre_instrs = case_body,
                    .arms = &.{},
                    .default_instrs = &.{},
                    .default_result = null,
                },
            });
            return;
        }
    }

    /// Lower the realized `?` propagation operator (`ExprKind.try_project`)
    /// into a comptime-safe `union_switch` over the operand's `Result(T, E)`:
    ///
    ///   * the `Ok(v)` prong binds the payload to a fresh local and
    ///     `case_break`s it to `dest` (yielding the unwrapped value), and
    ///   * the `Error(e)` prong binds the payload, re-wraps
    ///     `Result(T, E).Error(e)` via `union_init` (auto-boxing the payload
    ///     into a `runtime.ProtocolBox` when the variant's payload type is a
    ///     protocol existential — the Acceptance-E cross-struct path), then
    ///     `ret`-terminates to early-return the enclosing function.
    ///
    /// `union_switch` is the realized form of the design's `TryProject` node:
    /// the Ok prong is the projection and the Error prong is the early
    /// return. The Error prong is `noreturn`, so the switch's value flows
    /// solely from the Ok prong — exactly the semantics of `expr?`.
    ///
    /// ARC return-source contract: the Error re-wrap value is a freshly
    /// constructed `Result.Error(...)` local that the `ret` consumes, so the
    /// enclosing function's return-source set already covers it (every `ret`
    /// value is a return source). The Ok payload `v` becomes the expression
    /// result through `dest` like any other case-break value.
    fn lowerTryProject(self: *IrBuilder, tp: hir_mod.TryProjectHir, dest: LocalId) anyerror!void {
        const scrutinee_local = try self.lowerExpr(tp.operand);

        const result_type_name = self.resolveTypeName(tp.result_type_id);
        const ok_name = self.interner.get(tp.ok_variant_name);
        const error_name = self.interner.get(tp.error_variant_name);

        // --- Ok prong: bind the payload, yield it to `dest`. ---
        // The payload local is bound to the switch's payload-capture
        // placeholder by the ZIR backend, so the prong yields it directly via
        // `case_break` (no intermediate copy — an extra `local_get` of the
        // capture would emit a coercion `ty_op` against the as-yet-unresolved
        // capture Ref and trip AIR Liveness).
        const ok_payload_local = self.next_local;
        self.next_local += 1;

        const saved_ok = self.current_instrs;
        self.current_instrs = .empty;
        try self.current_instrs.append(self.allocator, .{ .case_break = .{ .value = ok_payload_local } });
        const ok_body = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = saved_ok;

        // --- Error prong: bind the payload, re-wrap Result.Error(e), ret. ---
        const err_payload_local = self.next_local;
        self.next_local += 1;
        const rewrapped_local = self.next_local;
        self.next_local += 1;

        const saved_err = self.current_instrs;
        self.current_instrs = .empty;
        // Auto-box the error payload when the `Error` variant's payload type
        // is a protocol existential (e.g. `Result(T, Error)` where `Error` is
        // a protocol). This mirrors the construction-site auto-box in the
        // `.union_init` arm so a concrete error value re-wraps into a
        // `runtime.ProtocolBox` and the early-returned `Result` matches the
        // enclosing function's declared return type.
        var error_value_local = err_payload_local;
        if (self.variantPayloadZigTypeByName(result_type_name, error_name)) |error_payload_type| {
            error_value_local = try self.maybeBoxAsProtocol(err_payload_local, error_payload_type);
        }
        try self.current_instrs.append(self.allocator, .{
            .union_init = .{
                .dest = rewrapped_local,
                .union_type = result_type_name,
                .variant_name = error_name,
                .value = error_value_local,
            },
        });
        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = rewrapped_local } });
        const err_body = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = saved_err;

        const cases = try self.allocator.alloc(UnionCase, 2);
        cases[0] = .{
            .variant_name = ok_name,
            .field_bindings = try self.allocSlice(FieldBinding, &.{.{ .field_name = "", .local_name = "", .local_index = ok_payload_local }}),
            .body_instrs = ok_body,
            .return_value = null,
        };
        cases[1] = .{
            .variant_name = error_name,
            .field_bindings = try self.allocSlice(FieldBinding, &.{.{ .field_name = "", .local_name = "", .local_index = err_payload_local }}),
            .body_instrs = err_body,
            .return_value = null,
        };

        try self.current_instrs.append(self.allocator, .{
            .union_switch = .{
                .dest = dest,
                .scrutinee = scrutinee_local,
                .cases = cases,
                .else_instrs = &.{},
                .else_result = null,
                .has_else = false,
            },
        });
    }

    /// Context for `buildUnionSwitchFromVariantNode`: case expressions
    /// lower each prong body via `lowerDecisionTreeForCase` (case_break
    /// leaves), dispatch lowers via `lowerDecisionTreeForDispatch` (ret
    /// leaves).
    const VariantSwitchContext = enum { case, dispatch };

    /// Build a comptime-safe `UnionSwitch` from a `switch_variant` decision
    /// node. Each variant case becomes a prong: the payload (if any) is
    /// bound to a fresh local recorded in `scrutinee_map` under the case's
    /// `payload_scrutinee_id`, then the case's sub-decision-tree is lowered
    /// into the prong body. The decision-tree default becomes the `else`
    /// prong unless it is an unconditional failure (non-exhaustive match
    /// with no `_` arm), in which case the switch is left exhaustive.
    ///
    /// The prong's payload binding is encoded as a single whole-payload
    /// `FieldBinding` (empty `field_name`) so the ZIR backend wires the
    /// bound local to the switch's payload capture. The result of each
    /// prong flows through the shared `dest` local via the body's terminal
    /// `case_break` / `ret`, so `return_value` is left `null`.
    fn buildUnionSwitchFromVariantNode(
        self: *IrBuilder,
        sw: hir_mod.SwitchVariantNode,
        scrutinee_local: LocalId,
        dest: LocalId,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
        context: VariantSwitchContext,
        case_arms: []const hir_mod.CaseArm,
        clauses: []const hir_mod.Clause,
    ) anyerror!UnionSwitch {
        var union_cases: std.ArrayList(UnionCase) = .empty;
        for (sw.cases) |case| {
            const variant_name = self.interner.get(case.variant_name);

            var field_bindings: std.ArrayList(FieldBinding) = .empty;
            if (case.has_payload) {
                const payload_local = self.next_local;
                self.next_local += 1;
                try scrutinee_map.put(case.payload_scrutinee_id, payload_local);
                // Whole-payload bind: empty field_name signals the ZIR
                // backend to map this local directly to the switch's
                // payload capture (no struct-field projection).
                try field_bindings.append(self.allocator, .{
                    .field_name = "",
                    .local_name = "",
                    .local_index = payload_local,
                });
            }

            const saved = self.current_instrs;
            self.current_instrs = .empty;
            switch (context) {
                .case => try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, dest),
                .dispatch => try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map),
            }
            const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved;

            try union_cases.append(self.allocator, .{
                .variant_name = variant_name,
                .field_bindings = try field_bindings.toOwnedSlice(self.allocator),
                .body_instrs = body_instrs,
                .return_value = null,
            });
        }

        // The decision-tree default becomes the switch's `else` prong only
        // when it is a real catch-all body. A bare `.failure` default (a
        // non-exhaustive match with no `_` arm) is dropped: the variants
        // are exhaustive over the tagged union, so Sema needs no else prong.
        var else_instrs: []const Instruction = &.{};
        var else_result: ?LocalId = null;
        var has_else = false;
        if (sw.default.* != .failure) {
            const saved = self.current_instrs;
            self.current_instrs = .empty;
            switch (context) {
                .case => try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, dest),
                .dispatch => try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map),
            }
            else_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved;
            else_result = null;
            has_else = true;
        }

        return .{
            .dest = dest,
            .scrutinee = scrutinee_local,
            .cases = try union_cases.toOwnedSlice(self.allocator),
            .else_instrs = else_instrs,
            .else_result = else_result,
            .has_else = has_else,
        };
    }

    /// Lower a decision tree for case expressions, emitting case_break at leaves.
    fn lowerDecisionTreeForCase(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        case_arms: []const hir_mod.CaseArm,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
        dest: LocalId,
    ) anyerror!void {
        switch (decision.*) {
            .success => |leaf| {
                const arm = case_arms[leaf.body_index];
                // Emit only scrutinee bindings (whole-value binds like `v -> v`).
                // Extracted bindings (tuple/list/struct/map elements) are handled
                // by bind nodes in the decision tree path, which resolve to the
                // correct decomposed locals.
                for (arm.bindings) |binding| {
                    if (binding.kind == .scrutinee) {
                        const scr_local = scrutinee_map.get(0) orelse 0;
                        try self.emitLocalGet(binding.local_index, scr_local);
                    }
                }
                const body_result = try self.lowerBlock(arm.body);
                try self.current_instrs.append(self.allocator, .{
                    .case_break = .{ .value = body_result },
                });
            },
            .failure => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "no matching case clause" },
                });
            },
            .guard => |guard_node| {
                try self.current_instrs.append(self.allocator, .{ .set_safety = false });
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
                try self.current_instrs.append(self.allocator, .{ .set_safety = true });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForCase(guard_node.success, case_arms, scrutinee_map, dest);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForCase(guard_node.failure, case_arms, scrutinee_map, dest);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const check_local = try self.emitSubPatternCheck(scrutinee_local, case.value);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, dest);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, dest);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, dest);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, dest);
            },
            .switch_variant => |sw| {
                // Comptime-safe tagged-union matching. Emit ONE `union_switch`
                // instruction (lowered by the ZIR backend to a single
                // `switch_block`-with-capture) instead of the old
                // `match_variant_tag` + `guard_block` + `variant_payload_get`
                // chain, which tripped Sema's "access of union field X while Y
                // is active" UB on comptime-known scrutinees whose match bound
                // payloads on more than one arm. The switch_block analyzes only
                // the active prong, so inactive payload fields are never read.
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                const union_switch = try self.buildUnionSwitchFromVariantNode(
                    sw,
                    scrutinee_local,
                    dest,
                    scrutinee_map,
                    .case,
                    case_arms,
                    &.{},
                );
                try self.current_instrs.append(self.allocator, .{ .union_switch = union_switch });
            },
            .check_tuple => |ct| {
                // For case expressions in statically typed code, the tuple type
                // check always passes. Emit element extraction and inner guards
                // at the CURRENT level (no guard_block wrapper). This ensures
                // inner guard_blocks (from atom switches) appear as flat siblings
                // in the case_block's pre_instrs, enabling proper if-else nesting
                // by emitFlatCaseBlock.
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                // When the scrutinee is a tuple extracted from a heterogeneous
                // keyword list (param-backed list_get with `via_helper`), the
                // runtime tuple's components are Term while the declared per-
                // slot types are concrete. Tell `index_get` which concrete
                // type to coerce each slot back to via `Term.toCoerced`.
                const term_tuple_decl: ?ZigType = self.term_tuple_locals.get(scrutinee_local);
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    const coerce_to: ZigType = if (term_tuple_decl) |tdecl| blk: {
                        if (tdecl == .tuple and i < tdecl.tuple.len) {
                            const slot_type = tdecl.tuple[i];
                            if (slot_type != .term) break :blk slot_type;
                        }
                        break :blk .any;
                    } else .any;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i, .coerce_term_to = coerce_to },
                    });
                    if (coerce_to != .any) {
                        try self.known_local_types.put(elem_local, coerce_to);
                    }
                    const elem_id = if (i < ct.element_scrutinee_ids.len)
                        ct.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(ct.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                // Lower success subtree at the same level — inner guards become
                // flat guard_blocks that emitFlatCaseBlock can process
                try self.lowerDecisionTreeForCase(ct.success, case_arms, scrutinee_map, dest);
            },
            .check_list => |cl| {
                const scrutinee_local = self.resolveScrutinee(cl.scrutinee, scrutinee_map);
                // When the scrutinee comes from a param, the runtime element
                // type may diverge from the declared one (e.g. heterogeneous
                // keyword list `[name: "x", age: 42]` passed to a function
                // declared `[{Atom, i64}]`). Route through the type-derived
                // `listLength`/`listGet` helpers so the actual element type
                // is read from `@TypeOf(list)` instead of the stale declared
                // element type.
                const dispatch_via_helper = self.localBackedByParam(scrutinee_local);
                const elem_type = self.listElementTypeForLocal(scrutinee_local) orelse
                    if (dispatch_via_helper) ZigType.any else return error.ListElementTypeUnavailable;
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .expected_len = cl.expected_length, .element_type = elem_type, .via_helper = dispatch_via_helper },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < cl.expected_length) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = elem_local, .list = scrutinee_local, .index = i, .element_type = elem_type, .via_helper = dispatch_via_helper },
                    });
                    try self.known_local_types.put(elem_local, elem_type);
                    // When the list is param-backed AND its declared element
                    // type is a tuple, the actual runtime element is a tuple
                    // whose components may have been Term-promoted (the param
                    // type `[{Atom, i64}]` accepts `[{Atom, Term}]` at runtime).
                    // Track this so a later `index_get` from `elem_local` can
                    // unwrap each Term slot back to the declared component
                    // type via `Term.toCoerced(value, default)`.
                    if (dispatch_via_helper and elem_type == .tuple) {
                        try self.term_tuple_locals.put(elem_local, elem_type);
                    }
                    // Use the explicit element_scrutinee_ids when available
                    // (always populated by the compiler), falling back to the
                    // legacy heuristic only for older fixtures that may have
                    // hand-constructed CheckListNodes without the field.
                    const elem_id = if (i < cl.element_scrutinee_ids.len)
                        cl.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(cl.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                try self.lowerDecisionTreeForCase(cl.success, case_arms, scrutinee_map, dest);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(cl.failure, case_arms, scrutinee_map, dest);
            },
            .check_list_cons => |clc| {
                const scrutinee_local = self.resolveScrutinee(clc.scrutinee, scrutinee_map);
                const scrutinee_list_type = self.known_local_types.get(scrutinee_local) orelse .any;
                // Same param-backed dispatch shim as check_list — route
                // through the type-derived list helpers when the scrutinee
                // came from a param so the runtime element type is honored.
                const dispatch_via_helper = self.localBackedByParam(scrutinee_local);
                const elem_type = self.listElementTypeForLocal(scrutinee_local) orelse
                    if (dispatch_via_helper) ZigType.any else return error.ListElementTypeUnavailable;
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{
                        .dest = len_check_local,
                        .scrutinee = scrutinee_local,
                        .expected_len = clc.head_count,
                        .minimum = true,
                        .element_type = elem_type,
                        .via_helper = dispatch_via_helper,
                    },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < clc.head_count) : (i += 1) {
                    const head_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = head_local, .list = scrutinee_local, .index = i, .element_type = elem_type, .via_helper = dispatch_via_helper },
                    });
                    try self.known_local_types.put(head_local, elem_type);
                    // Phase H.1: propagate the HIR element type so any
                    // downstream local_get/share_value chain that flows
                    // from this head into a function argument sees a
                    // consistent ARC-managed status. Without this, the
                    // chain falls back to `.trivial` and the verifier's
                    // V2 invariant rejects the matching post-call
                    // release once `.list` joins the ARC-managed set.
                    try self.recordListChildHirType(scrutinee_local, head_local, .element);
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                }
                const tail_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = tail_local, .list = scrutinee_local, .element_type = elem_type, .start_index = clc.head_count, .via_helper = dispatch_via_helper },
                });
                try self.known_local_types.put(tail_local, scrutinee_list_type);
                try self.recordListChildHirType(scrutinee_local, tail_local, .list);
                try scrutinee_map.put(clc.tail_scrutinee_id, tail_local);
                try self.lowerDecisionTreeForCase(clc.success, case_arms, scrutinee_map, dest);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(clc.failure, case_arms, scrutinee_map, dest);
            },
            .check_binary => |cb| {
                const scrutinee_local = self.resolveScrutinee(cb.scrutinee, scrutinee_map);
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .min_len = cb.min_byte_size },
                });

                // Emit bin_match_prefix for each string literal prefix segment
                // and AND the result with the length check condition.
                var condition_local = len_check_local;
                for (cb.segments) |seg| {
                    if (seg.string_literal) |sl| {
                        const prefix_str = self.interner.get(sl);
                        const prefix_check_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .bin_match_prefix = .{
                                .dest = prefix_check_local,
                                .source = scrutinee_local,
                                .expected = prefix_str,
                            },
                        });
                        condition_local = try self.emitAnd(condition_local, prefix_check_local);
                    }
                }

                const saved = self.current_instrs;
                self.current_instrs = .empty;

                // Emit binary segment extraction instructions for case arm bindings.
                // Each segment with a bind pattern needs a bin_read_int/bin_read_float/bin_slice
                // instruction to extract the value into the binding's local.
                try self.emitBinarySegmentExtractions(cb.segments, scrutinee_local, case_arms);

                try self.lowerDecisionTreeForCase(cb.success, case_arms, scrutinee_map, dest);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = condition_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(cb.failure, case_arms, scrutinee_map, dest);
            },
            .bind => |bind_node| {
                // Emit binding: resolve scrutinee and assign to binding local
                const scrutinee_local = self.resolveScrutinee(bind_node.source, scrutinee_map);
                // Find matching CaseBinding by name to get the local_index
                for (case_arms) |arm| {
                    for (arm.bindings) |binding| {
                        if (binding.name == bind_node.name) {
                            try self.emitLocalGet(binding.local_index, scrutinee_local);
                            break;
                        }
                    }
                }
                try self.lowerDecisionTreeForCase(bind_node.next, case_arms, scrutinee_map, dest);
            },
            .extract_struct => |es| {
                const scrutinee_local = self.resolveScrutinee(es.scrutinee, scrutinee_map);
                const struct_type = self.structTypeForFieldReceiver(scrutinee_local);
                for (es.fields) |fe| {
                    const field_local = self.next_local;
                    self.next_local += 1;
                    const field_name = self.interner.get(fe.field_name);
                    const field_info = if (struct_type) |sname|
                        self.fieldZigTypeAndStorage(sname, field_name)
                    else
                        null;
                    // Plumb the field's HIR type onto the destructured
                    // local so the matching `emitArcRetainOnAggregateExtract`
                    // call below can detect ARC-managed extractions
                    // (boxed-recursive struct types like `Tree | nil`
                    // included). Without this, the field-extracted
                    // local has no recorded HIR type,
                    // `isArcManagedLocal` returns its conservative-
                    // false default, and no `.retain` IR is emitted —
                    // leaving the runtime's `retainAnyOpt` (formerly
                    // emitted from the ZIR backend) without a matching
                    // IR-level release. This is the binarytrees-class
                    // leak: ~610M tree nodes never freed because the
                    // field-extracted child locals never reached
                    // `arc_managed_locals` and never got a scope-exit
                    // `.release`.
                    if (struct_type) |sname| {
                        if (self.lookupStructFieldHirTypeByName(sname, field_name)) |field_hir_type| {
                            try self.local_hir_types.put(field_local, field_hir_type);
                        }
                    }
                    try self.current_instrs.append(self.allocator, .{
                        .field_get = .{
                            .dest = field_local,
                            .object = scrutinee_local,
                            .field = field_name,
                            .struct_type = struct_type,
                        },
                    });
                    // Retain the extracted ARC value at the IR level.
                    // The matching `.release` is inserted by
                    // `arc_drop_insertion` once the field-extracted
                    // local enters `arc_managed_locals` (via the
                    // `local_hir_types` plumbing above).
                    try self.emitArcRetainOnAggregateExtract(field_local);
                    if (field_info) |i| {
                        try self.known_local_types.put(field_local, i.type_expr);
                    }
                    try scrutinee_map.put(fe.scrutinee_id, field_local);
                }
                try self.lowerDecisionTreeForCase(es.success, case_arms, scrutinee_map, dest);
            },
            .extract_map => |em| {
                const scrutinee_local = self.resolveScrutinee(em.scrutinee, scrutinee_map);
                // Pull the map's K/V from the scrutinee's known type
                // so the ZIR emitter looks up the right `Map(K, V)`
                // cell. Falls back to atom→i64 for legacy maps that
                // don't carry concrete types.
                const map_zig_type = self.known_local_types.get(scrutinee_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                // Resolve the map's value HIR type so the extracted
                // local participates in `arc_managed_locals` when the
                // value type is ARC-managed (List, Map, recursive
                // struct, etc.). Same fix shape as commit ce5e715
                // (`emitMapBindings`) applied to the decision-tree
                // case-extraction path.
                const value_hir_type: ?hir_mod.TypeId = blk: {
                    const ts = self.type_store orelse break :blk null;
                    const scrutinee_hir = self.local_hir_types.get(scrutinee_local) orelse break :blk null;
                    const t = ts.getType(scrutinee_hir);
                    if (t != .map) break :blk null;
                    break :blk t.map.value;
                };
                for (em.keys) |ke| {
                    const key_local = try self.lowerExpr(ke.key);
                    const default_local = try self.emitDefaultValueForType(value_type);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    if (value_hir_type) |vht| {
                        try self.local_hir_types.put(value_local, vht);
                    }
                    try self.current_instrs.append(self.allocator, .{
                        .map_get = .{
                            .dest = value_local,
                            .map = scrutinee_local,
                            .key = key_local,
                            .default = default_local,
                            .key_type = key_type,
                            .value_type = value_type,
                        },
                    });
                    try self.emitArcRetainOnAggregateExtract(value_local);
                    try self.known_local_types.put(value_local, value_type);
                    try scrutinee_map.put(ke.scrutinee_id, value_local);
                }
                try self.lowerDecisionTreeForCase(em.success, case_arms, scrutinee_map, dest);
            },
        }
    }

    /// Lower a decision tree for function dispatch, emitting ret at leaves.
    fn lowerDecisionTreeForDispatch(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        clauses: []const hir_mod.Clause,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
    ) anyerror!void {
        switch (decision.*) {
            .success => |leaf| {
                const clause = &clauses[leaf.body_index];
                for (clause.tuple_bindings) |binding| {
                    const tuple_local = scrutinee_map.get(binding.param_index) orelse blk: {
                        const pl = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = pl, .index = binding.param_index },
                        });
                        break :blk pl;
                    };
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{
                            .dest = binding.local_index,
                            .object = tuple_local,
                            .index = binding.element_index,
                        },
                    });
                }
                // Emit list element bindings
                for (clause.list_bindings) |binding| {
                    if (self.known_local_types.contains(binding.local_index)) continue;
                    const list_local = scrutinee_map.get(binding.param_index) orelse blk: {
                        const pl = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = pl, .index = binding.param_index },
                        });
                        // Track fallback param's type so listElementTypeForLocal works
                        if (binding.param_index < clause.params.len) {
                            const param_type = typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store);
                            if (param_type != .any) {
                                try self.known_local_types.put(pl, param_type);
                            }
                            // Propagate the param's HIR type so downstream
                            // chains (local_get, share_value, release) see
                            // the correct ARC-managed status. Without this,
                            // the fallback-param local's hir type stays
                            // unset and any reuse of `binding.local_index`
                            // via local_get below cannot inherit the
                            // expected list HIR type.
                            try self.local_hir_types.put(pl, clause.params[binding.param_index].type_id);
                        }
                        break :blk pl;
                    };
                    const list_elem_type = self.listElementTypeForLocal(list_local) orelse
                        return error.ListElementTypeUnavailable;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{
                            .dest = binding.local_index,
                            .list = list_local,
                            .index = binding.element_index,
                            .element_type = list_elem_type,
                        },
                    });
                    try self.known_local_types.put(binding.local_index, list_elem_type);
                    // Phase H.1: propagate the HIR element type onto the
                    // binding local. Without this, the binding's
                    // `local_hir_types` entry stays at whatever the local
                    // id had been used for previously (often non-ARC),
                    // which causes `isArcManagedLocal(binding)` to return
                    // false and breaks any downstream
                    // share_value/release chain whose source flows from
                    // this binding. Pulled from the list's recorded HIR
                    // type via the type-store's `.list.element` field.
                    try self.recordListChildHirType(list_local, binding.local_index, .element);
                }
                // Emit cons tail bindings: copy decision tree tail locals to binding locals
                for (clause.cons_tail_bindings) |binding| {
                    if (self.known_local_types.contains(binding.local_index)) continue;
                    // The tail was extracted by check_list_cons and stored in scrutinee_map.
                    // Find the tail local and copy it to the binding's local_index.
                    // The scrutinee_map maps scrutinee IDs → locals, but we need to find
                    // the tail by param_index. Look for the list param's tail local.
                    const list_local = scrutinee_map.get(binding.param_index) orelse continue;
                    // The tail is the list local itself (after head extraction, the remaining
                    // scrutinee entries represent tails). Search for a tail scrutinee.
                    // For simplicity, use list_tail on the original list to get the tail.
                    const list_elem_type = self.listElementTypeForLocal(list_local) orelse
                        return error.ListElementTypeUnavailable;
                    const scrutinee_list_type = self.known_local_types.get(list_local) orelse .any;
                    try self.current_instrs.append(self.allocator, .{
                        .list_tail = .{ .dest = binding.local_index, .list = list_local, .element_type = list_elem_type, .start_index = binding.start_index },
                    });
                    try self.known_local_types.put(binding.local_index, scrutinee_list_type);
                    // Phase H.1: propagate the HIR list type onto the
                    // tail binding local. The tail of a list has the
                    // same list HIR type as the source list — pull it
                    // from the source's recorded `local_hir_types`
                    // entry. Without this, the binding's hir type
                    // stays unset (or stale from a prior reuse of the
                    // local id), and the downstream
                    // share_value/release path fires on a local whose
                    // ownership class is computed as `.trivial`,
                    // tripping the verifier's V2 invariant once
                    // `.list` joins the ARC-managed type set.
                    try self.recordListChildHirType(list_local, binding.local_index, .list);
                }
                // Emit binary/struct bindings
                try self.emitBinaryBindings(clause);
                try self.emitStructBindings(clause);
                const result_local = try self.lowerBlockExpecting(clause.body, clause.return_type);
                try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
            },
            .failure => {
                if (self.try_mode) {
                    // Return sentinel empty string — caller checks and substitutes handler
                    try self.current_instrs.append(self.allocator, .{
                        .match_error_return = .{ .scrutinee = 0 },
                    });
                } else {
                    try self.current_instrs.append(self.allocator, .{
                        .match_fail = .{ .message = "no matching clause" },
                    });
                }
            },
            .guard => |guard_node| {
                // Disable runtime safety during guard condition evaluation.
                // If the guard expression triggers a safety check (overflow,
                // bounds, etc.), the result is undefined rather than a panic,
                // causing the guard to evaluate to false and skip to the next clause.
                try self.current_instrs.append(self.allocator, .{ .set_safety = false });
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
                try self.current_instrs.append(self.allocator, .{ .set_safety = true });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForDispatch(guard_node.success, clauses, scrutinee_map);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForDispatch(guard_node.failure, clauses, scrutinee_map);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const skip = self.shouldSkipTypeCheck(scrutinee_local, case.value);
                    const check_local = try self.emitSubPatternCheckWithSkip(scrutinee_local, case.value, skip);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .switch_variant => |sw| {
                // Function-clause dispatch on a tagged-union variant
                // pattern — same emit shape as the case-arm path's
                // `lowerDecisionTreeForCase.switch_variant`: emit a
                // tag check, then inside the guard body extract the
                // payload via variant_payload_get and bind it under
                // the case's payload_scrutinee_id before recursing.
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const variant_name = self.interner.get(case.variant_name);
                    const tag_check_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_variant_tag = .{
                            .dest = tag_check_local,
                            .scrutinee = scrutinee_local,
                            .variant_name = variant_name,
                        },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    if (case.has_payload) {
                        const payload_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .variant_payload_get = .{
                                .dest = payload_local,
                                .scrutinee = scrutinee_local,
                                .variant_name = variant_name,
                            },
                        });
                        try scrutinee_map.put(case.payload_scrutinee_id, payload_local);
                    }
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = tag_check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .check_tuple => |ct| {
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                const type_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_type = .{ .dest = type_check_local, .scrutinee = scrutinee_local, .expected_type = .{ .tuple = &.{} }, .expected_arity = ct.expected_arity },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i },
                    });
                    const elem_id = if (i < ct.element_scrutinee_ids.len)
                        ct.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(ct.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                try self.lowerDecisionTreeForDispatch(ct.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(ct.failure, clauses, scrutinee_map);
            },
            .check_list => |cl| {
                const scrutinee_local = self.resolveScrutinee(cl.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local) orelse
                    return error.ListElementTypeUnavailable;
                // Emit: __local_N = scrutinee.len == expected_length
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .expected_len = cl.expected_length, .element_type = elem_type },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                // Extract list elements into locals
                var i: u32 = 0;
                while (i < cl.expected_length) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = elem_local, .list = scrutinee_local, .index = i, .element_type = elem_type },
                    });
                    try self.known_local_types.put(elem_local, elem_type);
                    try self.recordListChildHirType(scrutinee_local, elem_local, .element);
                    try scrutinee_map.put(findParamGetIdInDecision(cl.success, i), elem_local);
                }
                try self.lowerDecisionTreeForDispatch(cl.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(cl.failure, clauses, scrutinee_map);
            },
            .check_list_cons => |clc| {
                const scrutinee_local = self.resolveScrutinee(clc.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local) orelse
                    return error.ListElementTypeUnavailable;
                const scrutinee_list_type = self.known_local_types.get(scrutinee_local) orelse .any;
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{
                        .dest = len_check_local,
                        .scrutinee = scrutinee_local,
                        .expected_len = clc.head_count,
                        .minimum = true,
                        .element_type = elem_type,
                    },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < clc.head_count) : (i += 1) {
                    const head_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = head_local, .list = scrutinee_local, .index = i, .element_type = elem_type },
                    });
                    try self.known_local_types.put(head_local, elem_type);
                    try self.recordListChildHirType(scrutinee_local, head_local, .element);
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                }
                const tail_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = tail_local, .list = scrutinee_local, .element_type = elem_type, .start_index = clc.head_count },
                });
                try self.known_local_types.put(tail_local, scrutinee_list_type);
                try self.recordListChildHirType(scrutinee_local, tail_local, .list);
                try scrutinee_map.put(clc.tail_scrutinee_id, tail_local);

                try self.lowerDecisionTreeForDispatch(clc.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(clc.failure, clauses, scrutinee_map);
            },
            .check_binary => |cb| {
                const scrutinee_local = self.resolveScrutinee(cb.scrutinee, scrutinee_map);
                // Emit length check
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .min_len = cb.min_byte_size },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;

                if (clauses.len > 1) {
                    // Multi-clause binary dispatch: emit per-clause guarded bodies.
                    // Each clause with a binary pattern gets its own extraction + guard.
                    // Clauses without binary patterns (wildcards) are handled by cb.failure.
                    for (clauses) |clause| {
                        // Skip clauses that don't have binary patterns (handled by cb.failure)
                        var has_binary = false;
                        for (clause.params) |param| {
                            if (param.pattern) |pat| {
                                if (pat.* == .binary_match) {
                                    has_binary = true;
                                    break;
                                }
                            }
                        }
                        if (!has_binary) continue;

                        const inner_saved = self.current_instrs;
                        self.current_instrs = .empty;
                        try self.emitBinaryBindings(&clause);
                        const result_local = try self.lowerBlockExpecting(clause.body, clause.return_type);
                        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
                        const all_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                        self.current_instrs = inner_saved;

                        // Find any guard condition (bin_match_prefix or bin_len_check)
                        // and split instructions: pre-guard setup vs guarded body.
                        var guard_cond: ?LocalId = null;
                        var split_idx: usize = 0;
                        for (all_instrs, 0..) |instr, idx| {
                            switch (instr) {
                                .bin_match_prefix => |bmp| {
                                    guard_cond = bmp.dest;
                                    split_idx = idx + 1;
                                    break;
                                },
                                else => {},
                            }
                        }

                        if (guard_cond) |cond| {
                            // Emit setup instructions, then wrap body in guard
                            for (all_instrs[0..split_idx]) |instr| {
                                try self.current_instrs.append(self.allocator, instr);
                            }
                            try self.current_instrs.append(self.allocator, .{
                                .guard_block = .{ .condition = cond, .body = all_instrs[split_idx..] },
                            });
                        } else {
                            // No string-literal prefix guard — wrap the whole body
                            // in a length check guard to differentiate from fallback
                            var clause_min_bits: u32 = 0;
                            for (clause.params) |param| {
                                if (param.pattern) |pat| {
                                    if (pat.* == .binary_match) {
                                        for (pat.binary_match.segments) |seg| {
                                            clause_min_bits += switch (seg.type_spec) {
                                                .default => 8,
                                                .integer => |i| i.bits,
                                                .float => |f| f.bits,
                                                .string => 0,
                                                .utf8 => 8,
                                                .utf16 => 16,
                                                .utf32 => 32,
                                            };
                                        }
                                    }
                                }
                            }
                            const clause_min_bytes = (clause_min_bits + 7) / 8;
                            if (clause_min_bytes > 0) {
                                const clause_len_check = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_len_check = .{ .dest = clause_len_check, .scrutinee = scrutinee_local, .min_len = clause_min_bytes },
                                });
                                try self.current_instrs.append(self.allocator, .{
                                    .guard_block = .{ .condition = clause_len_check, .body = all_instrs },
                                });
                            } else {
                                // Zero min bytes — just emit inline
                                for (all_instrs) |instr| {
                                    try self.current_instrs.append(self.allocator, instr);
                                }
                            }
                        }
                    }
                } else {
                    // Single-clause binary: use normal decision tree
                    try self.lowerDecisionTreeForDispatch(cb.success, clauses, scrutinee_map);
                }

                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(cb.failure, clauses, scrutinee_map);
            },
            .bind => |bind_node| {
                const scrutinee_local = self.resolveScrutinee(bind_node.source, scrutinee_map);
                for (clauses) |clause| {
                    for (clause.list_bindings) |binding| {
                        if (binding.name == bind_node.name) {
                            try self.emitLocalGet(binding.local_index, scrutinee_local);
                            break;
                        }
                    }
                    for (clause.cons_tail_bindings) |binding| {
                        if (binding.name == bind_node.name) {
                            try self.emitLocalGet(binding.local_index, scrutinee_local);
                            break;
                        }
                    }
                }
                try self.lowerDecisionTreeForDispatch(bind_node.next, clauses, scrutinee_map);
            },
            .extract_struct => |es| {
                const scrutinee_local = self.resolveScrutinee(es.scrutinee, scrutinee_map);
                const struct_type = self.structTypeForFieldReceiver(scrutinee_local);
                for (es.fields) |fe| {
                    const field_local = self.next_local;
                    self.next_local += 1;
                    const field_name = self.interner.get(fe.field_name);
                    const field_info = if (struct_type) |sname|
                        self.fieldZigTypeAndStorage(sname, field_name)
                    else
                        null;
                    // See parallel comment in lowerDecisionTreeForCase's
                    // extract_struct arm: this plumbing is what closes
                    // the binarytrees-class leak by exposing the field-
                    // extracted local's HIR type to
                    // `emitArcRetainOnAggregateExtract`, which then
                    // emits an explicit `.retain` IR that
                    // `arc_drop_insertion` balances with a matching
                    // scope-exit `.release`.
                    if (struct_type) |sname| {
                        if (self.lookupStructFieldHirTypeByName(sname, field_name)) |field_hir_type| {
                            try self.local_hir_types.put(field_local, field_hir_type);
                        }
                    }
                    try self.current_instrs.append(self.allocator, .{
                        .field_get = .{
                            .dest = field_local,
                            .object = scrutinee_local,
                            .field = field_name,
                            .struct_type = struct_type,
                        },
                    });
                    try self.emitArcRetainOnAggregateExtract(field_local);
                    if (field_info) |i| {
                        try self.known_local_types.put(field_local, i.type_expr);
                    }
                    try scrutinee_map.put(fe.scrutinee_id, field_local);
                }
                try self.lowerDecisionTreeForDispatch(es.success, clauses, scrutinee_map);
            },
            .extract_map => |em| {
                const scrutinee_local = self.resolveScrutinee(em.scrutinee, scrutinee_map);
                // Pull the map's K/V from the scrutinee's known type
                // so the ZIR emitter looks up the right `Map(K, V)`
                // cell. Falls back to atom→i64 for legacy maps that
                // don't carry concrete types.
                const map_zig_type = self.known_local_types.get(scrutinee_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                // Same plumbing as the dispatch path's extract_struct
                // and the case path's extract_map: resolve the map's
                // value HIR type and populate `local_hir_types` so the
                // value-extracted local enters `arc_managed_locals`
                // when it's ARC-managed.
                const value_hir_type: ?hir_mod.TypeId = blk: {
                    const ts = self.type_store orelse break :blk null;
                    const scrutinee_hir = self.local_hir_types.get(scrutinee_local) orelse break :blk null;
                    const t = ts.getType(scrutinee_hir);
                    if (t != .map) break :blk null;
                    break :blk t.map.value;
                };
                for (em.keys) |ke| {
                    const key_local = try self.lowerExpr(ke.key);
                    const default_local = try self.emitDefaultValueForType(value_type);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    if (value_hir_type) |vht| {
                        try self.local_hir_types.put(value_local, vht);
                    }
                    try self.current_instrs.append(self.allocator, .{
                        .map_get = .{
                            .dest = value_local,
                            .map = scrutinee_local,
                            .key = key_local,
                            .default = default_local,
                            .key_type = key_type,
                            .value_type = value_type,
                        },
                    });
                    try self.emitArcRetainOnAggregateExtract(value_local);
                    try self.known_local_types.put(value_local, value_type);
                    try scrutinee_map.put(ke.scrutinee_id, value_local);
                }
                try self.lowerDecisionTreeForDispatch(em.success, clauses, scrutinee_map);
            },
        }
    }

    /// Resolve a scrutinee expression from the decision tree to an IR local.
    fn resolveScrutinee(self: *IrBuilder, expr: *const hir_mod.Expr, scrutinee_map: *std.AutoHashMap(u32, LocalId)) LocalId {
        _ = self;
        if (expr.kind == .param_get) {
            if (scrutinee_map.get(expr.kind.param_get)) |local| {
                return local;
            }
        }
        return 0;
    }

    /// Lower a guard expression from the decision tree, resolving param_get
    /// indices through the scrutinee map. In the decision tree, param_get
    /// indices are scrutinee IDs (not raw parameter indices), so they must be
    /// resolved to the IR locals that hold the corresponding values.
    fn lowerGuardExpr(self: *IrBuilder, expr: *const hir_mod.Expr, scrutinee_map: *std.AutoHashMap(u32, LocalId)) !LocalId {
        switch (expr.kind) {
            .param_get => |idx| {
                // Resolve through scrutinee map first (scrutinee IDs from decision tree)
                if (scrutinee_map.get(idx)) |local| {
                    const dest = self.next_local;
                    self.next_local += 1;
                    try self.emitLocalGet(dest, local);
                    return dest;
                }
                // Fall back to raw param_get for actual parameter references
                const dest = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = dest, .index = idx },
                });
                return dest;
            },
            .binary => |bin| {
                const lhs = try self.lowerGuardExpr(bin.lhs, scrutinee_map);
                const rhs = try self.lowerGuardExpr(bin.rhs, scrutinee_map);
                const dest = self.next_local;
                self.next_local += 1;
                const ir_op: BinaryOp.Op = switch (bin.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .rem_op => .rem_op,
                    .equal => .eq,
                    .not_equal => .neq,
                    .less => .lt,
                    .greater => .gt,
                    .less_equal => .lte,
                    .greater_equal => .gte,
                    .and_op => .bool_and,
                    .or_op => .bool_or,
                    .concat => .concat,
                    .in_op => blk: {
                        if (bin.rhs.kind == .struct_init) {
                            if (self.type_store) |ts| {
                                if (bin.rhs.type_id < ts.types.items.len) {
                                    const rhs_type = ts.getType(bin.rhs.type_id);
                                    if (rhs_type == .struct_type) {
                                        if (self.isNativeRangeStruct(rhs_type.struct_type.name)) break :blk .in_range;
                                    }
                                }
                            }
                        }
                        break :blk .in_list;
                    },
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{
                        .dest = dest,
                        .op = ir_op,
                        .lhs = lhs,
                        .rhs = rhs,
                        .result_type = self.binaryResultZigType(expr.type_id, lhs, rhs),
                    },
                });
                return dest;
            },
            .call => {
                // In guard context, fall through to the generic lowerExpr which
                // handles all call targets correctly. The guard-specific handling
                // only needs to be in lowerGuardExpr for param_get (scrutinee
                // resolution) and binary ops (guard-specific comparison lowering).
                return self.lowerExpr(expr);
            },
            else => {
                // For other expression kinds, fall through to generic lowerExpr
                return self.lowerExpr(expr);
            },
        }
    }

    /// Check if a scrutinee has a known type that allows skipping runtime type checks (Phase 3).
    fn shouldSkipTypeCheck(self: *IrBuilder, scrutinee: LocalId, lit: hir_mod.LiteralValue) bool {
        const known_type = self.known_local_types.get(scrutinee) orelse return false;
        return switch (lit) {
            .int => switch (known_type) {
                .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
                else => false,
            },
            .float => switch (known_type) {
                .f16, .f32, .f64, .f80, .f128 => true,
                else => false,
            },
            .atom => known_type == .atom,
            .string => known_type == .string,
            .bool_val => known_type == .bool_type,
            .nil => known_type == .nil,
        };
    }

    /// Emit a sub-pattern check with optional skip_type_check flag (Phase 3).
    fn emitSubPatternCheckWithSkip(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue, skip: bool) !LocalId {
        if (!skip) return self.emitSubPatternCheck(elem_local, lit);
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            else => self.emitSubPatternCheck(elem_local, lit),
        };
    }

    /// Emit a `.dbg_stmt` IR instruction carrying the Zap source span
    /// of `stmt`. Called by `lowerBlock` once per HIR statement so the
    /// ZIR backend produces a DWARF line entry at every Zap statement
    /// boundary — every runtime trap (panic, arithmetic overflow,
    /// nil-deref, divide-by-zero, ...) inside the statement maps
    /// back to the statement's source line.
    ///
    /// The emitted span is the *driving* HIR `Expr`'s span:
    ///   - `expr` statements: the expression's own span.
    ///   - `local_set` statements: the RHS expression's span (the
    ///     assignment's start), which matches user intuition of
    ///     "the statement is the assignment line".
    ///   - `function_group` statements: skipped — nested function
    ///     declarations don't produce executable instructions in the
    ///     enclosing block; their bodies carry their own dbg_stmts.
    ///
    /// A zero `line` (synthetic statement with no source origin) is
    /// emitted unchanged; the ZIR builder treats `{line: 0, column: 0}`
    /// as a sentinel and skips ZIR emission. Doing the sentinel check
    /// once at the ZIR boundary keeps every IR-level analysis pass
    /// agnostic to the distinction.
    fn emitDbgStmtForStmt(self: *IrBuilder, stmt: hir_mod.Stmt) !void {
        const span: ast.SourceSpan = switch (stmt) {
            .expr => |expr| expr.span,
            .local_set => |ls| ls.value.span,
            .function_group => return,
        };
        // The lexer emits 1-based line/column, the existing IR
        // function-level `debug_line`/`debug_column` are stored
        // zero-based (see `zeroBasedSourceCoordinate`). Convert here
        // so the IR payload's contract is identical: zero-based,
        // sentinel `{0,0}` means "no source origin". The ZIR builder
        // adds one back when calling the fork's `addDbgStmt` (which
        // expects DWARF's one-based convention).
        try self.current_instrs.append(self.allocator, .{
            .dbg_stmt = .{
                .line = zeroBasedSourceCoordinate(span.line),
                .column = zeroBasedSourceCoordinate(span.col),
            },
        });
    }

    fn lowerBlock(self: *IrBuilder, block: *const hir_mod.Block) anyerror!?LocalId {
        var last_local: ?LocalId = null;
        for (block.stmts, 0..) |stmt, stmt_index| {
            // Phase 0 — DWARF foundation: emit a `.dbg_stmt` at every
            // Zap statement boundary so the ZIR backend can produce a
            // DWARF line entry for it. Source coordinates come from
            // the HIR Expr's span; statements with no user-visible
            // source (synthetic helper assignments produced by
            // pattern destructuring, etc.) carry a zero span, which
            // the ZIR builder treats as a sentinel and skips.
            try self.emitDbgStmtForStmt(stmt);
            switch (stmt) {
                .expr => |expr| {
                    const saved_expected_type = self.current_expected_type;
                    if (stmt_index + 1 == block.stmts.len) {
                        if (self.usableContextType(block.result_type)) |block_result_type| {
                            self.current_expected_type = block_result_type;
                        }
                    }
                    defer self.current_expected_type = saved_expected_type;
                    last_local = try self.lowerExpr(expr);
                },
                .local_set => |ls| {
                    const val = try self.lowerExpr(ls.value);
                    // Skip redundant self-assignment (e.g., struct init already in the right local)
                    if (val != ls.index) {
                        try self.current_instrs.append(self.allocator, .{
                            .local_set = .{ .dest = ls.index, .value = val },
                        });
                    }
                    // Propagate type from value to assignment target
                    if (self.known_local_types.get(val)) |src_type| {
                        try self.known_local_types.put(ls.index, src_type);
                    }
                    // Propagate HIR type as well so subsequent `.local_get`
                    // sites reading `ls.index` know whether the value is
                    // ARC-managed and need a retain on alias.
                    if (self.local_hir_types.get(val)) |src_hir_type| {
                        try self.local_hir_types.put(ls.index, src_hir_type);
                    }
                    // Phase 0 — DWARF foundation: record the Zap source
                    // identifier for this local so the ZIR backend can
                    // emit a `dbg_var_val`, preserving the name into
                    // DWARF `.debug_info`. Only emitted when the
                    // assignment was a plain `name = expr` (destructure
                    // bindings record their own per-leaf names via
                    // `lowerAssignmentDestructure` and its descendants).
                    if (ls.name) |name_id| {
                        try self.current_instrs.append(self.allocator, .{
                            .dbg_var = .{
                                .name = self.interner.get(name_id),
                                .value = ls.index,
                                .is_ptr = false,
                            },
                        });
                    }
                    last_local = ls.index;
                },
                .function_group => |group| {
                    const saved_instrs = self.current_instrs;
                    const saved_next_local = self.next_local;
                    const saved_known_local_types = self.known_local_types;
                    const saved_local_hir_types = self.local_hir_types;
                    self.current_instrs = .empty;
                    self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                    self.local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(self.allocator);
                    defer {
                        self.known_local_types.deinit();
                        self.known_local_types = saved_known_local_types;
                        self.local_hir_types.deinit();
                        self.local_hir_types = saved_local_hir_types;
                    }
                    try self.buildFunctionGroup(group);
                    self.current_instrs = saved_instrs;
                    self.next_local = saved_next_local;
                },
            }
        }
        return last_local;
    }

    fn lowerBlockExpecting(
        self: *IrBuilder,
        block: *const hir_mod.Block,
        expected_type: ?types_mod.TypeId,
    ) anyerror!?LocalId {
        const saved_expected_type = self.current_expected_type;
        if (expected_type) |type_id| {
            if (self.usableContextType(type_id)) |usable_type_id| {
                self.current_expected_type = usable_type_id;
            }
        }
        defer self.current_expected_type = saved_expected_type;
        return try self.lowerBlock(block);
    }

    /// Phase H.1: kind of HIR-type relationship between a list local
    /// and a child binding produced by pattern destructuring or
    /// decision-tree extraction. Used by `recordListChildHirType` to
    /// pick the correct extraction (`.element` -> the list's element
    /// type; `.list` -> the same list type as the source).
    const ListChildKind = enum { element, list };

    /// Look up the HIR type recorded for `list_local` and propagate
    /// the appropriate child type onto `child_local`. For `.element`,
    /// the child receives the list's element TypeId; for `.list`, the
    /// child receives the same list TypeId (e.g. tail bindings whose
    /// type matches the source list).
    ///
    /// Phase H.1: this is the load-bearing fix that lets list-child
    /// bindings (head extraction, tail extraction) participate in the
    /// same ARC-managed classification as their source. Without it,
    /// the binding's `local_hir_types` entry stays unset (or stale
    /// from a prior reuse of the local id), and any downstream
    /// `share_value`/`release` chain whose source flows from this
    /// binding fires on a local whose ownership class is `.trivial`
    /// — tripping the verifier's V2 invariant the moment `.list`
    /// joins the ARC-managed type set.
    ///
    /// Silent no-op when the source's HIR type is unknown or not a
    /// list — the conservative fallback preserves existing behavior
    /// for non-list scrutinees and makes the helper safe to call from
    /// every list-extraction site.
    fn recordListChildHirType(
        self: *IrBuilder,
        list_local: LocalId,
        child_local: LocalId,
        kind: ListChildKind,
    ) !void {
        const list_hir = self.local_hir_types.get(list_local) orelse return;
        const store = self.type_store orelse return;
        if (list_hir >= store.types.items.len) return;
        const list_type = store.getType(list_hir);
        if (list_type != .list) return;
        switch (kind) {
            .element => try self.local_hir_types.put(child_local, list_type.list.element),
            .list => try self.local_hir_types.put(child_local, list_hir),
        }
    }

    fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
        const store = self.type_store orelse return false;
        // Phase F flip: `.map` joined `.opaque_type` as ARC-managed.
        // Phase H.4 flip: `.list` joins them, completing the chain
        // started by H.1's runtime substrate (Arc-headered pool-
        // allocated cells), continued by H.2's `guard_block`
        // ownership scoping fix in `arc_liveness.zig`, and closed
        // by H.3's `next`/`getHead`/`getTail` retain symmetry in
        // `runtime.zig`. Keep
        // `isArcManagedTypeId` and this method in lockstep — both
        // must agree on every type.
        return isArcManagedTypeId(store, type_id);
    }

    /// Returns whether the value held in `local` is ARC-managed at the
    /// HIR-type level, consulting `local_hir_types`. Returns `false` if
    /// no HIR type was recorded for the local — this is a conservative
    /// default that avoids spurious retains on locals whose types we
    /// genuinely don't know.
    fn isArcManagedLocal(self: *const IrBuilder, local: LocalId) bool {
        const hir_type = self.local_hir_types.get(local) orelse return false;
        return self.isArcManagedType(hir_type);
    }

    /// Look up the TypeId of `field_name` on the struct named
    /// `struct_name_id`. Returns null when the type store is missing,
    /// the struct cannot be resolved, or the field name is not a
    /// member. Used by the destructuring helpers (`emitStructBindings`,
    /// pattern-match field bindings) to plumb the field's HIR type
    /// onto the destructured local so `isArcManagedLocal` can detect
    /// ARC-managed extractions.
    fn lookupStructFieldHirType(
        self: *const IrBuilder,
        struct_name_id: ast.StringId,
        field_name_id: ast.StringId,
    ) ?hir_mod.TypeId {
        const ts = self.type_store orelse return null;
        const struct_type_id = ts.name_to_type.get(struct_name_id) orelse return null;
        const struct_type = ts.getType(struct_type_id);
        if (struct_type != .struct_type) return null;
        for (struct_type.struct_type.fields) |f| {
            if (f.name == field_name_id) return f.type_id;
        }
        return null;
    }

    /// String-keyed analogue of `lookupStructFieldHirType`. The
    /// multi-clause dispatch decision-tree lowering paths
    /// (`lowerDecisionTreeForCase`, `lowerDecisionTreeForDispatch`)
    /// resolve the receiver's struct type via
    /// `structTypeForFieldReceiver`, which returns `?[]const u8`
    /// (a borrowed string) rather than an `ast.StringId`. Linear-
    /// scanning the type store by name lets those paths populate
    /// `local_hir_types` for the field-extracted local without
    /// having to round-trip the strings through the interner. The
    /// alternative — interning the strings just to call
    /// `lookupStructFieldHirType` — would mutate the interner
    /// during IR build, which the interner's contract forbids.
    fn lookupStructFieldHirTypeByName(
        self: *const IrBuilder,
        struct_name: []const u8,
        field_name: []const u8,
    ) ?hir_mod.TypeId {
        const ts = self.type_store orelse return null;
        // Per-instantiation form (`Box_i64`): consult the
        // precomputed specialization table so the field type comes
        // back substituted (i64) rather than the parametric base's
        // declared type variable (t).
        if (self.appliedSpecializationByMangledName(struct_name)) |spec| {
            const base = ts.getType(spec.base_type_id);
            if (base != .struct_type) return null;
            for (base.struct_type.fields, 0..) |f, i| {
                const fname = ts.interner.get(f.name);
                if (std.mem.eql(u8, fname, field_name)) {
                    return spec.substituted_field_hir_types[i];
                }
            }
            return null;
        }
        const type_id = self.resolveNominalTypeId(struct_name) orelse return null;
        const struct_type = ts.getType(type_id);
        if (struct_type != .struct_type) return null;
        for (struct_type.struct_type.fields) |f| {
            const fname = ts.interner.get(f.name);
            if (std.mem.eql(u8, fname, field_name)) return f.type_id;
        }
        return null;
    }

    /// Allocates a `param_conventions` slice sized to `params.len` and
    /// populates each entry from its parameter's HIR type. Phase A of
    /// the Phase 6 redux plan: ARC-managed parameter types default to
    /// `.borrowed`, every other type defaults to `.trivial`. The
    /// caller owns the returned slice via `self.allocator`.
    fn computeParamConventions(self: *IrBuilder, params: []const Param) ![]ParamConvention {
        const out = try self.allocator.alloc(ParamConvention, params.len);
        for (params, 0..) |param, i| {
            out[i] = self.defaultParamConventionForParam(param);
        }
        return out;
    }

    fn defaultParamConventionForParam(self: *const IrBuilder, param: Param) ParamConvention {
        const hir_convention = defaultParamConvention(self.type_store, param.type_id);
        if (hir_convention != .trivial) return hir_convention;
        return if (self.isArcManagedZigType(param.type_expr)) .borrowed else .trivial;
    }

    /// Phase 1.2.5.d helper: true iff the scope graph carries a
    /// non-parametric `ProtocolEntry` matching `protocol_name_text`.
    /// Used by `isArcManagedZigType` to gate protocol-box ARC
    /// management on whether the protocol's vtable codegen is
    /// active (it isn't yet for parametric protocols — see the
    /// `populateProtocolVTables` parametric guard). Without this
    /// gate, parametric-protocol receivers would route releases
    /// through a `<Protocol>VTable.drop` helper that the per-impl
    /// codegen never emitted, failing at Zig Sema time.
    ///
    /// Returns false (defensive) when the scope graph isn't wired,
    /// when no protocol matches the name, or when the matched
    /// protocol carries one or more type parameters.
    fn protocolHasVTable(self: *const IrBuilder, protocol_name_text: []const u8) bool {
        const graph = self.scope_graph orelse return false;
        for (graph.protocols.items) |proto_entry| {
            if (proto_entry.decl.type_params.len != 0) continue;
            const text = self.protocolNameToString(proto_entry.name);
            if (std.mem.eql(u8, text, protocol_name_text)) return true;
        }
        return false;
    }

    fn isArcManagedZigType(self: *const IrBuilder, type_expr: ZigType) bool {
        return switch (type_expr) {
            .list, .map => true,
            // Phase 1.2.5.d: non-parametric protocol existentials
            // are owning — the box's `data_ptr` is a heap-allocated
            // typed inner cell allocated through
            // `ArcRuntime.allocAny`. Treating `.protocol_box` as
            // ARC-managed here is what flips
            // `defaultParamConventionForParam` to `.borrowed` for
            // protocol-existential params and makes
            // `arc_drop_insertion` schedule a scope-exit release.
            // The IR builder rewrites the scheduled release's kind
            // to `.protocol_box_drop` and stamps the protocol name
            // (see `rewriteProtocolBoxReleases`) so the ZIR backend
            // lowers the release through the synthetic
            // `<Protocol>VTable.drop(box)` helper instead of the
            // standard `releaseAny(box)` dispatcher (the box is a
            // thin 16-byte fat-pointer value, not a slab-managed
            // cell with an inline ArcHeader, so `releaseAny` would
            // mis-interpret it).
            //
            // Parametric protocols (Enumerable(t), Iterator(K, V))
            // still lower their constrained-receiver positions to
            // `.protocol_box(<name>)` for ZIR typing, but
            // `populateProtocolVTables` doesn't yet emit a vtable
            // for them — and the existing HIR
            // `protocolDispatchStruct` rewrite folds parametric
            // protocol calls to concrete-impl calls before IR sees
            // them, so their values never actually flow through a
            // ProtocolBox at runtime. Classifying their box-typed
            // ZigType as ARC-managed would route `arc_drop_insertion`
            // toward a `drop` helper that doesn't exist; explicitly
            // exclude them here by consulting the scope graph.
            .protocol_box => |protocol_name| self.protocolHasVTable(protocol_name),
            .optional => |inner| self.isArcManagedZigType(inner.*),
            .ptr => |pointee| self.isArcManagedZigType(pointee.*),
            .struct_ref => |type_name| blk: {
                const type_id = self.resolveNominalTypeId(type_name) orelse break :blk false;
                break :blk self.isArcManagedType(type_id);
            },
            else => false,
        };
    }

    /// Walk the TypeStore once and populate `applied_specializations`
    /// plus the two indexes (`applied_id_to_spec`, `applied_name_to_spec`).
    /// Called at the start of `buildProgram` so every downstream IR
    /// pass — `lowerExpr` for `struct_init`/`field_get`,
    /// `resolveTypeName`, `lookupStructFieldHirTypeByName`,
    /// `fieldZigTypeAndStorage`, and the per-instantiation TypeDef
    /// emitter — can consult the same precomputed map. Per-instantiation
    /// substitution runs exactly once per `.applied { base, args }`
    /// TypeId rather than once per field-access site, and the
    /// canonical mangled name is owned by the IR builder's allocator
    /// so it can be safely embedded in `TypeDef.name`,
    /// `StructInit.type_name`, and `FieldGet.struct_type` strings
    /// without per-site allocation.
    ///
    /// `.applied` entries whose `base` is not a struct/tagged_union
    /// (e.g. an erroneously-constructed applied over a primitive) are
    /// silently skipped — they cannot have field/variant lists to
    /// substitute, and the type checker rejects such constructions
    /// upstream.
    ///
    /// **Mangled-name collision risk.** The mangling scheme
    /// (`typeIdMangledName`) joins base + args with `_`, matching
    /// the monomorphizer's function-specialization scheme. A user
    /// who declares a concrete struct under a name that matches a
    /// parametric instantiation's mangled form (`pub struct Box_i64`
    /// while also using `Box(i64)` elsewhere) would produce two
    /// `TypeDef` entries with the same name — a defect surface that
    /// downstream layers cannot disambiguate. Detecting and reporting
    /// the collision as a Zap-level diagnostic is tracked as a
    /// follow-up; for now the `StringHashMap.put` here would
    /// overwrite the concrete-struct index with the parametric one,
    /// which is consistent with the IR's category ordering (concrete
    /// first, applied second) but is not a deliberate semantic. The
    /// collision is exceedingly unlikely in practice — Zap struct
    /// names use PascalCase and a literal `Box_i64` is not idiomatic.
    ///
    /// `.applied` entries whose args still contain a type
    /// variable are also skipped: those are *partial* instantiations
    /// produced by the type-checker's mid-traversal stages that the
    /// monomorphizer collapses before IR runs, so emitting a TypeDef
    /// for them would be both meaningless and a name collision risk.
    fn populateAppliedSpecializations(self: *IrBuilder) !void {
        const store = self.type_store orelse return;
        for (store.types.items, 0..) |candidate_type, candidate_index| {
            if (candidate_type != .applied) continue;
            const applied = candidate_type.applied;
            // Skip applied forms that still contain unresolved type
            // variables — they're partial instantiations the
            // monomorphizer hasn't collapsed yet. Emitting a TypeDef
            // for them would either alias a concrete instantiation
            // (silent name collision) or carry type_var-shaped fields
            // (illegal at the ZIR layer).
            if (containsUnresolvedTypeVarForSpecialization(store, @intCast(candidate_index))) continue;

            // The applied base must resolve to a nominal struct /
            // tagged_union. Anything else is a malformed applied
            // (e.g. a stale entry left over by a bug elsewhere); skip
            // rather than crash so the remaining IR build can still
            // surface the real diagnostic upstream.
            const base_type = store.getType(applied.base);
            switch (base_type) {
                .struct_type, .tagged_union => {},
                else => continue,
            }

            // Build the canonical mangled name once and stash it on
            // the IR builder's allocator so the lifetime matches
            // every downstream consumer.
            const mangled = try types_mod.typeIdMangledName(
                self.allocator,
                store,
                @intCast(candidate_index),
            );
            errdefer self.allocator.free(mangled);

            const spec = try self.buildAppliedSpecialization(
                @constCast(store),
                @intCast(candidate_index),
                applied,
                mangled,
            );

            // Insert into the parallel indexes. The applied TypeId is
            // already structurally unique via `TypeStore.addType`'s
            // dedup, so the auto-hash insert is a one-shot put. The
            // mangled-name index might collide if two parametric
            // bases share a name and instantiate identically — that's
            // a Zap-level error (duplicate `pub struct Box(T)`) that
            // upstream rejection catches, so the StringHashMap put is
            // also a one-shot put.
            const idx = self.applied_specializations.items.len;
            try self.applied_specializations.append(self.allocator, spec);
            try self.applied_id_to_spec.put(@intCast(candidate_index), idx);
            try self.applied_name_to_spec.put(self.allocator, mangled, idx);
        }
    }

    /// Phase 1.2.5.a step 3.7 + Phase 1.2.5.b extensions: emit a
    /// `protocol_vtable_def` TypeDef for every `pub protocol`
    /// reachable from the program, and a
    /// `protocol_vtable_instance_def` for every `pub impl`. The ZIR
    /// backend's step 3.7 lowers each entry into a synthetic Zig
    /// source file:
    ///
    ///   - `<Protocol>VTable` — the protocol's vtable struct type,
    ///     one field per method (function pointer with receiver erased
    ///     to `?*anyopaque`).
    ///   - `<Protocol>VTable_for_<Target>` — one constant per impl,
    ///     populated with `.method = &<Target>__<method>__<arity>`
    ///     pointers. For a *parametric* impl `impl Foo for Bar(t)`,
    ///     the populator emits one instance per applied specialization
    ///     `.applied { Bar, [<args>] }` discovered through
    ///     `applied_specializations`, using the mangled per-
    ///     instantiation name (`Bar_i64`) as the target suffix. The
    ///     dispatch-side `findMonomorphizedImplFor` then resolves the
    ///     logical `<MangledTarget>__<method>__<arity>` slot name to
    ///     the monomorphized symbol.
    ///
    /// Silently no-ops when `scope_graph` is null — the IR builder is
    /// used by unrelated unit tests that don't construct the full
    /// collect pipeline; those tests must still build a coherent
    /// `Program` without protocol surfaces.
    ///
    /// Phase 1.2.5.b lifts the parametric-impl guard from 1.2.5.a's
    /// initial cut. Parametric *protocols* (`pub protocol Foo(t)
    /// { ... }`) still defer — the vtable shape itself needs a
    /// per-instantiation substitution before emission, which is a
    /// downstream upgrade beyond the runtime existential boxing this
    /// phase enables.
    fn populateProtocolVTables(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
    ) !void {
        const graph = self.scope_graph orelse return;

        // ── 3.7.a: per-protocol vtable struct types ──────────────
        // Walk every `ProtocolEntry` and emit a
        // `protocol_vtable_def` TypeDef. The vtable's field list
        // mirrors the protocol's method signatures, with each
        // receiver erased to `?*anyopaque` (the dispatch site only
        // has the box's `data_ptr`, not the concrete receiver type).
        for (graph.protocols.items) |proto_entry| {
            // Phase 1.2.5.b still defers parametric protocols — the
            // vtable shape would need to be re-instantiated per
            // protocol argument set, which is a separate upgrade.
            if (proto_entry.decl.type_params.len != 0) continue;

            const protocol_name = self.protocolNameToString(proto_entry.name);
            const vtable_type_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}VTable",
                .{protocol_name},
            );

            const methods = try self.allocator.alloc(
                ProtocolVTableMethod,
                proto_entry.decl.functions.len,
            );
            for (proto_entry.decl.functions, 0..) |fn_sig, method_index| {
                const method_name = self.interner.get(fn_sig.name);
                const arity: u32 = @intCast(fn_sig.params.len);
                // Extra params are everything past the receiver — index 0.
                const extra_count = if (fn_sig.params.len > 0) fn_sig.params.len - 1 else 0;
                const extra_param_types = try self.allocator.alloc(ZigType, extra_count);
                if (extra_count > 0) {
                    for (fn_sig.params[1..], 0..) |param, param_index| {
                        extra_param_types[param_index] = self.protocolParamTypeToZigType(param.type_annotation);
                    }
                }
                const return_zig_type = self.protocolReturnTypeToZigType(fn_sig.return_type);
                methods[method_index] = .{
                    .name = try cloneBytes(self.allocator, method_name),
                    .arity = arity,
                    .extra_param_types = extra_param_types,
                    .return_type = return_zig_type,
                };
            }

            try type_defs.append(self.allocator, .{
                .name = vtable_type_name,
                .kind = .{ .protocol_vtable_def = .{
                    .protocol_name = try cloneBytes(self.allocator, protocol_name),
                    .methods = methods,
                } },
            });
        }

        // ── 3.7.b: per-impl vtable instance constants ────────────
        // Walk every `ImplEntry` and emit a
        // `protocol_vtable_instance_def` TypeDef whose
        // method-pointer entries name the impl's monomorphized
        // function symbols.
        //
        // The target naming branches on whether the impl is
        // parametric:
        //
        //   - Concrete target (`impl Foo for Bar`): one instance per
        //     impl, named `FooVTable_for_Bar` with target_name
        //     `"Bar"` directly from the impl's `target_type`.
        //   - Parametric target (`impl Foo for Bar(t)`): one instance
        //     per applied specialization `.applied { Bar, [<args>] }`
        //     visible in `applied_specializations`. Each instance is
        //     named `FooVTable_for_<MangledTarget>` (e.g.
        //     `FooVTable_for_Bar_i64`) and the method-pointer slots
        //     carry the *logical* `<MangledTarget>__<method>__<arity>`
        //     address — `findMonomorphizedImplFor` resolves that
        //     logical address to the actual monomorphized symbol at
        //     dispatch lowering time.
        for (graph.impls.items) |impl_entry| {
            // Locate the protocol entry to read the method
            // signatures in declaration order. Construction-time
            // method-name matching uses the protocol's slot ordering,
            // not the impl's source-order, so an impl that lists
            // methods in a different order still produces a correctly
            // aligned vtable.
            const proto_entry = graph.findProtocol(impl_entry.protocol_name) orelse continue;
            // Parametric protocols are still deferred (see header).
            if (proto_entry.decl.type_params.len != 0) continue;

            const protocol_name = self.protocolNameToString(proto_entry.name);
            const declared_target_name = self.protocolNameToString(impl_entry.target_type);

            if (impl_entry.decl.type_params.len == 0) {
                // Concrete-target impl — Phase 1.2.5.a's path.
                try self.emitProtocolVTableInstance(
                    type_defs,
                    proto_entry,
                    protocol_name,
                    declared_target_name,
                );
                continue;
            }

            // Parametric impl — one vtable instance per applied
            // specialization whose base nominal name matches the
            // impl's declared target. The applied table was already
            // populated by `populateAppliedSpecializations` (which
            // 1.2.5.b's `containsUnresolvedTypeVarForSpecialization`
            // refactor unblocks for `Option(Error)`-shaped forms;
            // ordinary parametric instantiations like `Tag(i64)` were
            // never blocked).
            for (self.applied_specializations.items) |spec| {
                const base_name = self.baseStructNameForSpec(spec) orelse continue;
                if (!std.mem.eql(u8, base_name, declared_target_name)) continue;
                try self.emitProtocolVTableInstance(
                    type_defs,
                    proto_entry,
                    protocol_name,
                    spec.mangled_name,
                );
            }
        }
    }

    /// Resolve the base nominal struct/tagged-union name for an
    /// `AppliedSpecialization`. Returns null when the base is not a
    /// nominal type (a pathology that `populateAppliedSpecializations`
    /// has already filtered out, but the explicit null arm keeps the
    /// caller defensive).
    fn baseStructNameForSpec(
        self: *const IrBuilder,
        spec: AppliedSpecialization,
    ) ?[]const u8 {
        const store = self.type_store orelse return null;
        if (spec.base_type_id >= store.types.items.len) return null;
        const base_type = store.types.items[spec.base_type_id];
        return switch (base_type) {
            .struct_type => |st| self.interner.get(st.name),
            .tagged_union => |tu| self.interner.get(tu.name),
            else => null,
        };
    }

    /// Emit one `protocol_vtable_instance_def` TypeDef for the
    /// (protocol, target) pair. Used by both the concrete-target and
    /// parametric-target arms in `populateProtocolVTables` so the
    /// instance shape (name layout, method-slot ordering, signature
    /// lowering) stays in lockstep across the two paths.
    fn emitProtocolVTableInstance(
        self: *IrBuilder,
        type_defs: *std.ArrayList(TypeDef),
        proto_entry: *const scope_mod.ProtocolEntry,
        protocol_name: []const u8,
        target_name: []const u8,
    ) !void {
        const instance_type_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}VTable_for_{s}",
            .{ protocol_name, target_name },
        );

        const methods = try self.allocator.alloc(
            ProtocolVTableInstanceMethod,
            proto_entry.decl.functions.len,
        );
        for (proto_entry.decl.functions, 0..) |proto_fn_sig, method_index| {
            const method_name = self.interner.get(proto_fn_sig.name);
            const arity: u32 = @intCast(proto_fn_sig.params.len);
            const impl_function_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}__{s}__{d}",
                .{ target_name, method_name, arity },
            );
            const extra_count = if (proto_fn_sig.params.len > 0) proto_fn_sig.params.len - 1 else 0;
            const extra_param_types = try self.allocator.alloc(ZigType, extra_count);
            if (extra_count > 0) {
                for (proto_fn_sig.params[1..], 0..) |param, param_index| {
                    extra_param_types[param_index] = self.protocolParamTypeToZigType(param.type_annotation);
                }
            }
            const return_zig_type = self.protocolReturnTypeToZigType(proto_fn_sig.return_type);
            methods[method_index] = .{
                .method_name = try cloneBytes(self.allocator, method_name),
                .impl_function_name = impl_function_name,
                .arity = arity,
                .extra_param_types = extra_param_types,
                .return_type = return_zig_type,
            };
        }

        try type_defs.append(self.allocator, .{
            .name = instance_type_name,
            .kind = .{ .protocol_vtable_instance_def = .{
                .protocol_name = try cloneBytes(self.allocator, protocol_name),
                .target_type_name = try cloneBytes(self.allocator, target_name),
                .methods = methods,
            } },
        });
    }

    /// Convert a `StructName` from the scope graph into a flat
    /// string suitable for use as a vtable name prefix or target
    /// suffix. Single-segment names (the common case for protocols
    /// and impl targets) return the leaf; multi-segment names join
    /// with `_` to keep the result a valid Zig identifier without
    /// re-running the per-segment mangler.
    fn protocolNameToString(self: *const IrBuilder, name: ast.StructName) []const u8 {
        if (name.parts.len == 1) return self.interner.get(name.parts[0]);
        return name.joinedWith(self.allocator, self.interner, "_") catch
            self.interner.get(name.parts[name.parts.len - 1]);
    }

    /// Phase 1.2.5.d consumption-site dispatch helper. Look up the
    /// `(method_index, arity, return_type)` for a named method on a
    /// named protocol by walking the scope graph's `ProtocolEntry`
    /// list. Mirrors the slot layout `populateProtocolVTables`
    /// produces for the corresponding `ProtocolVTableDef`, but is
    /// callable during function-body lowering — before
    /// `populateProtocolVTables` has written its TypeDefs — because
    /// the data source (declaration order on the source `ProtocolDecl`)
    /// is the same.
    ///
    /// Returns `null` when the scope graph isn't wired (unit tests
    /// for unrelated shapes), the protocol isn't registered, or the
    /// method name doesn't match a declared method.
    fn findProtocolMethodSlotByScope(
        self: *IrBuilder,
        protocol_name_text: []const u8,
        method_name_text: []const u8,
    ) ?ProtocolMethodSlot {
        const graph = self.scope_graph orelse return null;
        for (graph.protocols.items) |proto_entry| {
            // Phase 1.2.5.b still defers parametric protocols — the
            // vtable shape would need to be re-instantiated per
            // protocol argument set, which is a separate upgrade.
            // The matching `populateProtocolVTables` guard skips
            // these too, so reaching the dispatch site for a
            // parametric protocol is a no-op here.
            if (proto_entry.decl.type_params.len != 0) continue;

            const proto_text = self.protocolNameToString(proto_entry.name);
            if (!std.mem.eql(u8, proto_text, protocol_name_text)) continue;

            for (proto_entry.decl.functions, 0..) |fn_sig, idx| {
                const fn_name = self.interner.get(fn_sig.name);
                if (!std.mem.eql(u8, fn_name, method_name_text)) continue;
                const return_zig_type = self.protocolReturnTypeToZigType(fn_sig.return_type);
                return .{
                    .method_index = @intCast(idx),
                    .arity = @intCast(fn_sig.params.len),
                    .return_type = return_zig_type,
                };
            }
            return null;
        }
        return null;
    }

    /// Convert a protocol method's parameter or return type
    /// annotation to a `ZigType` suitable for use in the vtable's
    /// function-pointer field type. Phase 1.2.5.a handles primitive
    /// names (`i64`, `String`, `Atom`, `Bool`, etc.); structured
    /// types (`Option(T)`, optional, list, etc.) fall back to a
    /// `.struct_ref` of the spelled-out name so the ZIR backend
    /// emits an `@import("<Name>").<Name>` lookup. Phase 1.2.5.b
    /// extends this to the full type-store path (including
    /// `protocol_constraint`) once the type-store plumbing lands.
    ///
    /// Unannotated parameters (rare — only `(self)` style sugars)
    /// fall back to `.any`, which becomes Zig's `anytype` at the
    /// emission layer; the dispatch site is still well-typed
    /// because the box transports a concrete pointer regardless.
    fn protocolParamTypeToZigType(
        self: *IrBuilder,
        type_annotation: ?*const ast.TypeExpr,
    ) ZigType {
        const ann = type_annotation orelse return .any;
        return self.astTypeExprToZigTypeForProtocol(ann);
    }

    fn protocolReturnTypeToZigType(
        self: *IrBuilder,
        return_type: ?*const ast.TypeExpr,
    ) ZigType {
        const ret = return_type orelse return .void;
        return self.astTypeExprToZigTypeForProtocol(ret);
    }

    /// Minimal AST `TypeExpr` → IR `ZigType` resolver for protocol
    /// vtable emission. Handles the cases that actually appear in
    /// protocol signatures (primitive names, parametric
    /// applications, optional/list containers); anything outside
    /// the supported set falls back to `.any`. Phase 1.2.5.b
    /// replaces this with a full resolution against the type
    /// store, once `protocol_constraint` materializes as a
    /// concrete TypeId backed by `ProtocolBox`.
    fn astTypeExprToZigTypeForProtocol(
        self: *IrBuilder,
        type_expr: *const ast.TypeExpr,
    ) ZigType {
        return switch (type_expr.*) {
            .name => |name_expr| blk: {
                const text = self.interner.get(name_expr.name);
                // Primitive name? Map directly. Mirrors
                // `TypeStore.resolveTypeName` so we don't drift
                // from the type checker's recognized name set.
                if (primitiveNameToZigType(text)) |prim| break :blk prim;
                // A bare protocol name (e.g. `Error` from the Phase
                // 1.2 stdlib protocol) lowers to the protocol-box
                // existential carrier — `protocol_box(name)`. The
                // ZIR backend emits the receiver as
                // `zap_runtime.ProtocolBox` so the dispatch site can
                // run through the vtable without committing to a
                // concrete impl target. Phase 1.2.5.b is what makes
                // this resolve consistently across struct fields,
                // function params, and return types.
                if (self.scope_graph) |graph| {
                    for (graph.protocols.items) |proto_entry| {
                        if (proto_entry.name.parts.len > 0 and
                            std.mem.eql(u8, self.interner.get(proto_entry.name.parts[proto_entry.name.parts.len - 1]), text))
                        {
                            break :blk .{ .protocol_box = self.allocator.dupe(u8, text) catch text };
                        }
                    }
                }
                // Parametric application: lower to a per-
                // instantiation mangled name (`Option(Error)` ->
                // `Option_Error`, `Option(i64)` -> `Option_i64`).
                // Per the file-IS-the-struct emission model the
                // resulting synthetic source file is the canonical
                // ZIR identity for the instantiation, so the
                // `@import("<Mangled>").<Mangled>` reference in
                // protocol vtable type signatures and adapter
                // function returns resolves to the right type.
                //
                // We pick `.tagged_union` for the result kind because
                // every parametric type currently exposed at the Zap
                // surface that flows through a protocol signature is
                // a tagged union (`Option(T)`, `Result(T, E)` in
                // Phase 1.3). `appendZigTypeForVTable` renders
                // `.tagged_union` as `@import("X").X` — the type
                // expression Sema actually accepts in signatures —
                // whereas `.struct_ref` renders as `@import("X")`,
                // a namespace value Sema rejects with "expected
                // pointer, found 'type'".
                if (name_expr.args.len > 0) {
                    if (self.composeMangledAppliedName(name_expr)) |mangled| {
                        // Determine whether the base is a tagged
                        // union or struct. Parametric protocol-
                        // signature args reachable today (Option,
                        // future Result) are tagged unions, so
                        // default to that. The scope graph lets us
                        // double-check when the base resolves.
                        break :blk .{ .tagged_union = mangled };
                    }
                    // Fall back to the bare base name — keeps the
                    // diagnostic surfaced ("unknown declaration X")
                    // honest instead of silently dropping the args.
                    break :blk .{ .struct_ref = self.allocator.dupe(u8, text) catch text };
                }
                // Bare nominal — treat as struct ref.
                break :blk .{ .struct_ref = self.allocator.dupe(u8, text) catch text };
            },
            .variable => .any,
            else => .any,
        };
    }

    /// Compose the per-instantiation mangled name for a parametric
    /// AST type-name like `Option(Error)` -> `Option_Error`. Returns
    /// null when an argument fails to render (an unresolved
    /// identifier, a higher-kinded form we don't yet support in
    /// protocol signatures, etc.) so the caller can fall back to the
    /// bare base name.
    ///
    /// The mangling mirrors `types_mod.typeIdMangledName`: each arg
    /// is recursively mangled, joined with `_` separators. Protocol
    /// constraints render as their bare name (the protocol's own
    /// name), matching how `types.typeIdMangledNameBorrowed` mangles
    /// `protocol_constraint(Error)` -> `Error` so per-instantiation
    /// synthetic source file names line up across the IR pipeline.
    fn composeMangledAppliedName(
        self: *IrBuilder,
        name_expr: ast.TypeNameExpr,
    ) ?[]const u8 {
        const base_text = self.interner.get(name_expr.name);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, base_text) catch return null;
        for (name_expr.args) |arg| {
            buf.append(self.allocator, '_') catch return null;
            const arg_zig_type = self.astTypeExprToZigTypeForProtocol(arg);
            const arg_name = mangledNameForArgZigType(arg_zig_type) orelse return null;
            buf.appendSlice(self.allocator, arg_name) catch return null;
        }
        return buf.toOwnedSlice(self.allocator) catch null;
    }

    /// Build the per-instantiation specialization data for one
    /// `.applied { base, args }` TypeId. Walks the base nominal type's
    /// field (struct) or variant (tagged_union) list, applying the
    /// `(type_params[i] -> args[i])` substitution map to each
    /// declared type, and converts the result to both the HIR-level
    /// TypeId (for `isArcManagedTypeId` checks) and the Zig-level
    /// `ZigType` (for `TypeDef`/`StructInit`/`FieldGet` emission).
    fn buildAppliedSpecialization(
        self: *IrBuilder,
        store: *types_mod.TypeStore,
        applied_type_id: types_mod.TypeId,
        applied: types_mod.Type.AppliedType,
        mangled: []const u8,
    ) !AppliedSpecialization {
        const base_type = store.getType(applied.base);

        var subs = types_mod.SubstitutionMap.init(self.allocator);
        defer subs.deinit();

        switch (base_type) {
            .struct_type => |st| {
                const pair_count = @min(st.type_params.len, applied.args.len);
                for (st.type_params[0..pair_count], applied.args[0..pair_count]) |tp_id, arg_id| {
                    const tp_type = store.getType(tp_id);
                    if (tp_type != .type_var) continue;
                    subs.bind(tp_type.type_var, arg_id);
                }

                const zig_types = try self.allocator.alloc(ZigType, st.fields.len);
                errdefer self.allocator.free(zig_types);
                const hir_types = try self.allocator.alloc(types_mod.TypeId, st.fields.len);
                errdefer self.allocator.free(hir_types);
                for (st.fields, 0..) |field, i| {
                    const substituted = subs.applyToType(store, field.type_id);
                    hir_types[i] = substituted;
                    zig_types[i] = typeIdToZigTypeWithStore(substituted, store);
                }

                return .{
                    .applied_type_id = applied_type_id,
                    .base_type_id = applied.base,
                    .mangled_name = mangled,
                    .substituted_field_zig_types = zig_types,
                    .substituted_field_hir_types = hir_types,
                    .variant_payload_type_ids = &.{},
                };
            },
            .tagged_union => |tu| {
                const pair_count = @min(tu.type_params.len, applied.args.len);
                for (tu.type_params[0..pair_count], applied.args[0..pair_count]) |tp_id, arg_id| {
                    const tp_type = store.getType(tp_id);
                    if (tp_type != .type_var) continue;
                    subs.bind(tp_type.type_var, arg_id);
                }

                const zig_types = try self.allocator.alloc(ZigType, tu.variants.len);
                errdefer self.allocator.free(zig_types);
                const hir_types = try self.allocator.alloc(types_mod.TypeId, tu.variants.len);
                errdefer self.allocator.free(hir_types);
                const payloads = try self.allocator.alloc(?types_mod.TypeId, tu.variants.len);
                errdefer self.allocator.free(payloads);
                for (tu.variants, 0..) |variant, i| {
                    if (variant.type_id) |payload| {
                        const substituted = subs.applyToType(store, payload);
                        payloads[i] = substituted;
                        hir_types[i] = substituted;
                        zig_types[i] = typeIdToZigTypeWithStore(substituted, store);
                    } else {
                        payloads[i] = null;
                        hir_types[i] = types_mod.TypeStore.UNKNOWN;
                        zig_types[i] = .nil;
                    }
                }

                return .{
                    .applied_type_id = applied_type_id,
                    .base_type_id = applied.base,
                    .mangled_name = mangled,
                    .substituted_field_zig_types = zig_types,
                    .substituted_field_hir_types = hir_types,
                    .variant_payload_type_ids = payloads,
                };
            },
            else => unreachable, // guarded by the caller
        }
    }

    /// Look up the per-instantiation specialization for a mangled
    /// per-instantiation name (`Box_i64`). Returns `null` when the
    /// name does not correspond to a known `.applied` form — callers
    /// fall back to the original parametric-or-concrete struct lookup
    /// path in that case (every name that is not a per-instantiation
    /// goes through this null arm, including every concrete struct
    /// like `IO`, `String`, `Tree`).
    fn appliedSpecializationByMangledName(
        self: *const IrBuilder,
        name: []const u8,
    ) ?*const AppliedSpecialization {
        const idx = self.applied_name_to_spec.get(name) orelse return null;
        return &self.applied_specializations.items[idx];
    }

    /// Look up the per-instantiation specialization for a canonical
    /// `.applied` TypeId. Returns `null` when the TypeId is not
    /// `.applied` (or, more precisely, was filtered out by
    /// `populateAppliedSpecializations` because it still carries
    /// type variables).
    fn appliedSpecializationByTypeId(
        self: *const IrBuilder,
        type_id: types_mod.TypeId,
    ) ?*const AppliedSpecialization {
        const idx = self.applied_id_to_spec.get(type_id) orelse return null;
        return &self.applied_specializations.items[idx];
    }

    fn resolveNominalTypeId(self: *const IrBuilder, type_name: []const u8) ?types_mod.TypeId {
        const store = self.type_store orelse return null;
        // A mangled per-instantiation name (`Box_i64`) resolves to its
        // canonical `.applied` TypeId — that's the runtime-bearing
        // identity. Without this arm an `Outer` struct that holds a
        // `Box_i64`-typed field would fail to look up the field
        // through `resolveNominalTypeId` and the auto-deref / ARC
        // routing would default to the safe-but-pessimistic path.
        if (self.applied_name_to_spec.get(type_name)) |idx| {
            return self.applied_specializations.items[idx].applied_type_id;
        }
        for (store.types.items, 0..) |candidate_type, candidate_index| {
            const candidate_name = switch (candidate_type) {
                .struct_type => |struct_type| store.interner.get(struct_type.name),
                .tagged_union => |tagged_union| store.interner.get(tagged_union.name),
                .opaque_type => |opaque_type| store.interner.get(opaque_type.name),
                else => continue,
            };
            if (std.mem.eql(u8, candidate_name, type_name)) return @intCast(candidate_index);
        }
        return null;
    }

    /// Allocates a `local_ownership` slice sized to `local_count` and
    /// populates each entry by consulting `local_hir_types`. Phase A
    /// classifies every non-ARC local as `.trivial` and every ARC-
    /// managed local as `.owned` (a stub that Phase C's classifier
    /// refines into `.borrowed` vs `.owned` based on definition
    /// site). Locals with no recorded HIR type fall back to
    /// `.trivial` — this matches the conservative `isArcManagedLocal`
    /// default and avoids labelling unknown locals as owners.
    fn computeLocalOwnership(self: *IrBuilder, local_count: u32) ![]OwnershipClass {
        const out = try self.allocator.alloc(OwnershipClass, local_count);
        var index: u32 = 0;
        while (index < local_count) : (index += 1) {
            out[index] = if (self.isArcManagedLocal(index)) .owned else .trivial;
        }
        return out;
    }

    /// Phase 1.2.5.d sidecar. Snapshot `known_local_types` for every
    /// local whose tracked Zig type is `.protocol_box(P)` and return
    /// a fresh `AutoHashMapUnmanaged` mapping LocalId -> bare
    /// protocol name. The map is owned by the function's allocator
    /// and lives as long as the IR program does — the post-drop
    /// rewrite pass consults it to flip the kind on box-local
    /// releases without needing to re-walk the type tables.
    ///
    /// Returns an empty map when no boxed locals exist (the common
    /// case for functions that don't traffic in protocol
    /// existentials).
    fn snapshotProtocolBoxLocals(
        self: *IrBuilder,
    ) !std.AutoHashMapUnmanaged(LocalId, []const u8) {
        var out: std.AutoHashMapUnmanaged(LocalId, []const u8) = .empty;
        var iter = self.known_local_types.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .protocol_box) continue;
            const protocol_name = entry.value_ptr.protocol_box;
            // Skip parametric protocols — their vtable codegen is
            // still gated off (see `populateProtocolVTables`), so no
            // `<Protocol>VTable.drop` helper exists to route their
            // releases through. The same parametric-protocol guard
            // also protects `isArcManagedZigType` from classifying
            // their box-typed locals as ARC-managed, so reaching
            // the sidecar with a parametric entry would be dead —
            // but the explicit check keeps the snapshot consistent
            // with the release-rewrite contract.
            if (!self.protocolHasVTable(protocol_name)) continue;
            const protocol_name_copy = try cloneBytes(self.allocator, protocol_name);
            try out.put(self.allocator, entry.key_ptr.*, protocol_name_copy);
        }
        return out;
    }

    /// Returns the default `ResultConvention` for a function whose
    /// HIR-level return type is `return_type_id`. Mirrors
    /// `defaultResultConvention`; placed on the builder so call sites
    /// can use the same `self.type_store` context.
    fn computeResultConvention(self: *const IrBuilder, return_type_id: ?hir_mod.TypeId) ResultConvention {
        return defaultResultConvention(self.type_store, return_type_id);
    }

    /// Emits a `.local_get{dest, source}` instruction and the
    /// follow-up `.retain{value=dest}` when the source's HIR type is
    /// ARC-managed. Also propagates `known_local_types`,
    /// `local_hir_types`, and `param_backed_locals` membership from
    /// `source` to `dest` so downstream passes see the new alias as
    /// equivalent to the original local.
    ///
    /// This helper is the single source of truth for `.local_get`
    /// emission — the named-binding path in `lowerExpr.local_get` and
    /// the four pattern-binding extraction sites in case / decision-
    /// tree lowering all funnel through it. Centralising the retain
    /// emission here avoids the silent mismatch that bit Phase 6:
    /// pattern bindings used to alias an ARC cell into a fresh local
    /// without bumping the cell's refcount, so the dest's own scope-
    /// exit release decremented past the source's true ownership.
    ///
    /// Without this retain, a single ARC-managed scrutinee shared into
    /// multiple binding locals would lower to multiple `.local_get`
    /// sites all aliasing the same cell, with the per-binding scope-
    /// exit releases over-decrementing. The Phase 6.2b drop-insertion
    /// pass treats each binding as owning an independent +1, so the
    /// retain restores that invariant.
    ///
    /// Phase C of the Phase 6 redux plan: this helper is now a
    /// transitional shim. The IR builder still produces `.local_get +
    /// .retain` here so that existing IR-level tests and pre-
    /// arc_ownership consumers (CTFE attribute eval is post-
    /// arc_ownership; HIR / monomorphize / arc_liveness are pre-
    /// arc_ownership and consume `.local_get`) keep their current
    /// shape. The new `arc_ownership.classifyAndNormalize` pass walks
    /// each function's body after `arc_liveness` and replaces every
    /// `.local_get` with an explicit `.borrow_value` (no retain) or
    /// `.copy_value` (lowering emits the retain at ZIR time). When
    /// the conversion is total — i.e., no consumer below
    /// `arc_ownership` reads `.local_get` anymore — this helper can
    /// be retired and the explicit forms emitted directly.
    fn emitLocalGet(self: *IrBuilder, dest: LocalId, source: LocalId) !void {
        try self.current_instrs.append(self.allocator, .{
            .local_get = .{ .dest = dest, .source = source },
        });
        if (self.isArcManagedLocal(source)) {
            try self.current_instrs.append(self.allocator, .{
                .retain = .{ .value = dest },
            });
        }
        if (self.known_local_types.get(source)) |src_type| {
            try self.known_local_types.put(dest, src_type);
        }
        if (self.local_hir_types.get(source)) |src_hir_type| {
            try self.local_hir_types.put(dest, src_hir_type);
        }
        if (self.param_backed_locals.contains(source)) {
            try self.param_backed_locals.put(dest, {});
        }
    }

    /// Emit `.retain {value=dest}` when `dest` holds an ARC-managed
    /// value extracted from a non-ARC aggregate (tuple, plain struct).
    /// The aggregate's storage holds a raw pointer to the ARC cell —
    /// no retain is performed at extraction time by the underlying
    /// runtime read (`elem_val_imm` / `field_val`). Without an explicit
    /// retain on `dest`, every owner alias produced by destructuring
    /// the aggregate would share a single +1 — the producer's original
    /// ownership transferred into the aggregate by the Phase E.10
    /// "aggregate-store consumes" rule. Multiple destructures of the
    /// same aggregate (or of distinct aggregates that share the same
    /// underlying ARC pointer) would then emit multiple scope-exit
    /// `release`s against one underlying refcount, double-freeing the
    /// cell.
    ///
    /// `dest`'s HIR type must be recorded in `local_hir_types` before
    /// this helper is called — `isArcManagedLocal` consults that map.
    /// Mirrors the retain-on-alias contract codified in `emitLocalGet`
    /// for `local_get`. ARC-managed aggregates (`Map`, `List`) handle
    /// their own deep-retain on the runtime side (`Map.get`,
    /// `List.getHead`, …) and never reach this helper because their
    /// extractions lower to dedicated IR opcodes (`map_get`,
    /// `list_head`, …) instead of `index_get` / `field_get`.
    fn emitArcRetainOnAggregateExtract(self: *IrBuilder, dest: LocalId) !void {
        if (!self.isArcManagedLocal(dest)) return;
        try self.current_instrs.append(self.allocator, .{
            .retain = .{ .value = dest },
        });
    }

    /// Pre-scan HIR block to find error_pipe expressions with
    /// is_dispatched steps, registering their function names in try_variant_names.
    /// This runs before function bodies are built so __try variants are generated.
    fn scanForTryVariantNames(self: *IrBuilder, block: *const hir_mod.Block, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, struct_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, struct_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, struct_prefix);
                    }
                },
            }
        }
    }

    fn scanExprForTryVariants(self: *IrBuilder, expr: *const hir_mod.Expr, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        switch (expr.kind) {
            .error_pipe => |ep| {
                for (ep.steps) |step| {
                    if (step.is_dispatched and step.expr.kind == .call) {
                        const call = step.expr.kind.call;
                        // +1 for the piped value which becomes the first argument
                        const call_arity = call.args.len + 1;
                        const call_name_str = switch (call.target) {
                            .named => |n| blk: {
                                if (n.struct_name) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, call_arity });
                                if (struct_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, call_arity });
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, call_arity });
                            },
                            else => continue,
                        };
                        try self.try_variant_names.put(call_name_str, {});
                    }
                    // Recurse into step expressions
                    try self.scanExprForTryVariants(step.expr, struct_prefix);
                }
                // Recurse into handler
                try self.scanExprForTryVariants(ep.handler, struct_prefix);
            },
            .call => |c| {
                for (c.args) |arg| {
                    try self.scanExprForTryVariants(arg.expr, struct_prefix);
                }
            },
            .branch => |br| {
                try self.scanExprForTryVariants(br.condition, struct_prefix);
                try self.scanBlockForTryVariants(br.then_block, struct_prefix);
                if (br.else_block) |eb| try self.scanBlockForTryVariants(eb, struct_prefix);
            },
            .case => |ce| {
                try self.scanExprForTryVariants(ce.scrutinee, struct_prefix);
                for (ce.arms) |arm| {
                    try self.scanBlockForTryVariants(arm.body, struct_prefix);
                }
            },
            .binary => |b| {
                try self.scanExprForTryVariants(b.lhs, struct_prefix);
                try self.scanExprForTryVariants(b.rhs, struct_prefix);
            },
            .unary => |u| {
                try self.scanExprForTryVariants(u.operand, struct_prefix);
            },
            .union_init => |ui| {
                try self.scanExprForTryVariants(ui.value, struct_prefix);
            },
            .block => |blk| {
                try self.scanBlockForTryVariants(&blk, struct_prefix);
            },
            else => {},
        }
    }

    fn scanBlockForTryVariants(self: *IrBuilder, block: *const hir_mod.Block, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, struct_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, struct_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, struct_prefix);
                    }
                },
            }
        }
    }

    /// Build the mangled name used by error-pipe call lowering:
    /// `Mod__name__N` when there is a struct prefix, `name__N` otherwise.
    /// Mirrors what the rest of the IR uses so that the `__try` variant
    /// resolved at the call site matches the concrete function we emit.
    fn formatErrorPipeCallName(self: *IrBuilder, call: hir_mod.CallExpr, arity: usize) anyerror![]const u8 {
        return switch (call.target) {
            .named => |n| blk: {
                if (n.struct_name) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, arity });
                if (self.current_struct_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, arity });
                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, arity });
            },
            else => "unknown",
        };
    }

    /// Lower a non-dispatched call step inside an error pipe (a
    /// single-clause total function). The call is emitted inline at the
    /// current `current_instrs` position. Returns the local that holds the
    /// call's result so it can be threaded into the next pipe step.
    fn lowerSingleErrorPipeCall(self: *IrBuilder, step: hir_mod.ErrorPipeStep, pipe_val: LocalId) anyerror!LocalId {
        const call = step.expr.kind.call;
        var arg_locals: std.ArrayList(LocalId) = .empty;
        try arg_locals.append(self.allocator, pipe_val);
        for (call.args) |arg| {
            try arg_locals.append(self.allocator, try self.lowerExpr(arg.expr));
        }
        const call_dest = self.next_local;
        self.next_local += 1;
        const final_args = try arg_locals.toOwnedSlice(self.allocator);
        const modes = try self.allocator.alloc(ValueMode, final_args.len);
        @memset(modes, .share);
        const ep_call_arity = final_args.len;
        const call_name_str = try self.formatErrorPipeCallName(call, ep_call_arity);
        try self.current_instrs.append(self.allocator, .{
            .call_named = .{ .dest = call_dest, .name = call_name_str, .args = final_args, .arg_modes = modes },
        });
        return call_dest;
    }

    /// Lower a single dispatched error-pipe step that may fail. The rest
    /// of the pipe (`remaining`) is lowered into the step's success
    /// branch so that a dispatch failure jumps directly to the handler
    /// without running the trailing steps. Returns the local that the ZIR
    /// backend will populate with the catch-basin expression value.
    fn lowerErrorPipeTryStep(
        self: *IrBuilder,
        step: hir_mod.ErrorPipeStep,
        pipe_val: LocalId,
        remaining: []const hir_mod.ErrorPipeStep,
        err_local: ?u32,
        handler_hir: *const hir_mod.Expr,
    ) anyerror!LocalId {
        const call = step.expr.kind.call;
        var arg_locals: std.ArrayList(LocalId) = .empty;
        try arg_locals.append(self.allocator, pipe_val);
        for (call.args) |arg| {
            try arg_locals.append(self.allocator, try self.lowerExpr(arg.expr));
        }
        const call_dest = self.next_local;
        self.next_local += 1;
        const final_args = try arg_locals.toOwnedSlice(self.allocator);
        const modes = try self.allocator.alloc(ValueMode, final_args.len);
        @memset(modes, .share);
        const ep_call_arity = final_args.len;
        const call_name_str = try self.formatErrorPipeCallName(call, ep_call_arity);

        const try_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{call_name_str});
        try self.try_variant_names.put(call_name_str, {});

        // Lower the handler in a fresh instruction buffer. The handler
        // reads the failed pipe value via `__err` (block-style handlers)
        // or as a function argument (`err_local == 0`).
        const saved = self.current_instrs;
        self.current_instrs = .empty;
        if (err_local) |el| {
            if (self.next_local <= el) self.next_local = el + 1;
            try self.current_instrs.append(self.allocator, .{
                .local_set = .{ .dest = el, .value = pipe_val },
            });
        }
        const handler_result = try self.lowerExpr(handler_hir);
        const handler_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = saved;

        // Allocate a local to hold the unwrapped payload, so the success
        // branch can refer to it as the input of subsequent steps.
        const payload_local = self.next_local;
        self.next_local += 1;

        // Build the success branch: emit any remaining steps with
        // `payload_local` as the new pipe value, recursing into another
        // try_call_named for the next dispatched step.
        const success_saved = self.current_instrs;
        self.current_instrs = .empty;
        var success_pipe_val: LocalId = payload_local;
        var rem_idx: usize = 0;
        while (rem_idx < remaining.len) : (rem_idx += 1) {
            const next_step = remaining[rem_idx];
            if (next_step.expr.kind != .call) continue;
            if (!next_step.is_dispatched) {
                const lowered = try self.lowerSingleErrorPipeCall(next_step, success_pipe_val);
                success_pipe_val = lowered;
                continue;
            }
            const inner = try self.lowerErrorPipeTryStep(
                next_step,
                success_pipe_val,
                remaining[rem_idx + 1 ..],
                err_local,
                handler_hir,
            );
            success_pipe_val = inner;
            // After a nested try_call_named, the rest of the pipe has
            // already been folded into its success branch.
            break;
        }
        const success_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = success_saved;

        try self.current_instrs.append(self.allocator, .{
            .try_call_named = .{
                .dest = call_dest,
                .name = try_name,
                .args = final_args,
                .arg_modes = modes,
                .input_local = pipe_val,
                .handler_instrs = handler_instrs,
                .handler_result = handler_result,
                .success_instrs = success_instrs,
                .success_result = success_pipe_val,
                .payload_local = payload_local,
            },
        });
        return call_dest;
    }

    /// Look up the payload ZigType for a tagged-union variant by
    /// name. Returns the substituted-form ZigType when the union is
    /// per-instantiation (via `appliedSpecializationByMangledName`);
    /// returns the bare-declaration form otherwise (via the
    /// type_store walk). Unit variants return `.nil`.
    ///
    /// Used by the Phase 1.2.5.c construction-site detector to find
    /// the variant payload's expected ZigType — when that type is
    /// `.protocol_box(P)` and the supplied value is a concrete
    /// struct implementing `P`, the detector emits a
    /// `box_as_protocol` coercion before the `union_init`.
    fn variantPayloadZigTypeByName(
        self: *const IrBuilder,
        union_type_name: []const u8,
        variant_name: []const u8,
    ) ?ZigType {
        const ts = self.type_store orelse return null;
        // Per-instantiation form (`Option_Error`): substituted
        // payloads live in the applied-spec cache.
        if (self.appliedSpecializationByMangledName(union_type_name)) |spec| {
            const base = ts.getType(spec.base_type_id);
            if (base != .tagged_union) return null;
            for (base.tagged_union.variants, 0..) |variant, i| {
                const vname = self.interner.get(variant.name);
                if (!std.mem.eql(u8, vname, variant_name)) continue;
                if (i >= spec.substituted_field_zig_types.len) return null;
                return spec.substituted_field_zig_types[i];
            }
            return null;
        }
        // Bare-declaration form (`Color`): walk the type_store.
        for (ts.types.items) |typ| {
            if (typ != .tagged_union) continue;
            const tu = typ.tagged_union;
            const owner = self.interner.get(tu.name);
            if (!std.mem.eql(u8, owner, union_type_name)) continue;
            for (tu.variants) |variant| {
                const vname = self.interner.get(variant.name);
                if (!std.mem.eql(u8, vname, variant_name)) continue;
                const tid = variant.type_id orelse return ZigType.nil;
                return typeIdToZigTypeWithStore(tid, self.type_store);
            }
        }
        return null;
    }

    /// Phase 1.2.5.c construction-site auto-boxing detector. Given a
    /// freshly-lowered value local and the ZigType the consuming
    /// slot expects, emit a `box_as_protocol` coercion if the slot
    /// is a `protocol_box(P)` and the value is a concrete struct
    /// that implements `P`. Returns the LocalId to use in place of
    /// `value_local` at the slot. When no coercion is needed (the
    /// value is already the right shape, or the slot is not a
    /// protocol box) returns `value_local` unchanged.
    ///
    /// Three legal paths through this helper:
    ///
    /// 1. `expected_zig_type` is NOT `.protocol_box` — pass through.
    /// 2. `expected_zig_type` is `.protocol_box(P)` and the value's
    ///    `known_local_types` entry is itself `.protocol_box(P)` —
    ///    pass through (already a box of the same protocol).
    /// 3. `expected_zig_type` is `.protocol_box(P)` and the value's
    ///    `known_local_types` entry is a concrete `struct_ref(T)`
    ///    with a registered `impl P for T` — emit `box_as_protocol`
    ///    and return the box's dest.
    ///
    /// A registered `impl P for T` is verified via `scope_graph`'s
    /// `findImpl`, which canonicalizes against both concrete and
    /// parametric-target impls. When the value is a concrete struct
    /// that does NOT implement the expected protocol, the helper
    /// passes the value through unchanged — Sema downstream will
    /// reject the assignment with a "expected ProtocolBox, found
    /// MyError" diagnostic. (A richer source-level error belongs to
    /// HIR-level type checking; Phase 1.2.5.c surfaces the
    /// missing-impl case as a structural error, not a soft warning.)
    fn maybeBoxAsProtocol(
        self: *IrBuilder,
        value_local: LocalId,
        expected_zig_type: ZigType,
    ) anyerror!LocalId {
        // Path 1: not a protocol-box slot.
        if (expected_zig_type != .protocol_box) return value_local;
        const expected_protocol = expected_zig_type.protocol_box;

        // Discover the value local's actual ZigType. Absent
        // tracking — e.g. a primitive literal that bypassed
        // `known_local_types` — leaves the box unemitted. Sema
        // catches the mismatch (no concrete type to box).
        const value_zig_type = self.known_local_types.get(value_local) orelse return value_local;

        // Path 2: already a protocol box (possibly from an upstream
        // coercion or a parameter typed as `Foo` where Foo is a
        // protocol). No second wrap.
        if (value_zig_type == .protocol_box) {
            if (std.mem.eql(u8, value_zig_type.protocol_box, expected_protocol)) {
                return value_local;
            }
            // Mismatched protocol box (Foo-typed value flowing into
            // a Bar-typed slot). Pass through; Sema rejects at the
            // type level.
            return value_local;
        }

        // Path 3: concrete struct — check for a registered impl.
        if (value_zig_type != .struct_ref) return value_local;
        const target_name = value_zig_type.struct_ref;

        // Look up `impl <expected_protocol> for <target_name>` in
        // the scope graph. The protocol's `StructName` shape needs
        // an `[StringId]` parts slice; we look up existing interned
        // ids via `lookupExisting` (the interner is `*const` here
        // since IR-build is a read pass over the interner; both
        // names must already be interned for an impl to exist).
        const graph = self.scope_graph orelse return value_local;
        const protocol_id = self.interner.lookupExisting(expected_protocol) orelse return value_local;
        const target_id = self.interner.lookupExisting(target_name) orelse return value_local;
        const proto_struct_name: ast.StructName = .{
            .parts = &[_]ast.StringId{protocol_id},
            .span = .{ .start = 0, .end = 0 },
        };
        const target_struct_name: ast.StructName = .{
            .parts = &[_]ast.StringId{target_id},
            .span = .{ .start = 0, .end = 0 },
        };
        // `findImpl` handles concrete `impl P for T` directly. For
        // parametric impls `impl P for T(t)` the registered impl's
        // target_type carries the bare `T` (not the per-instantiation
        // form), so a concrete `T_i64` value's `struct_ref` name
        // would not match. The per-instantiation match is left for
        // later — Phase 1.2.5.c gates concrete impls only; the
        // parametric-impl-on-parametric-value box site lands as a
        // separate exercise once the vtable instance lookup is
        // wired through the applied-specialization table at the
        // construction site, not just at the vtable populator.
        if (graph.findImpl(proto_struct_name, target_struct_name) == null) return value_local;

        // Emit a fresh local for the box's dest. The IR
        // construction-site detector owns the local allocation here
        // so the caller's `value_local` retains its original
        // identity (important for ARC liveness; the box's new local
        // is a distinct ownership cursor).
        const box_dest = self.next_local;
        self.next_local += 1;
        try self.current_instrs.append(self.allocator, .{
            .box_as_protocol = .{
                .dest = box_dest,
                .value = value_local,
                .protocol_name = expected_protocol,
                .target_type_name = target_name,
                .value_zig_type = value_zig_type,
            },
        });
        // Track the box's dest as a `.protocol_box(P)` so downstream
        // type-aware passes (ARC retain/release, indirect-storage
        // field promotion) see the right shape.
        try self.known_local_types.put(box_dest, expected_zig_type);
        return box_dest;
    }

    fn lowerExpr(self: *IrBuilder, expr: *const hir_mod.Expr) anyerror!LocalId {
        const tracked_hir_type = self.effectiveTrackedHirType(expr);

        // Case expressions need binding locals reserved before dest allocation
        // to avoid shadowing conflicts in the generated Zig.
        if (expr.kind == .case) {
            const case_dest = try self.lowerCaseExpr(expr.kind.case);
            try self.local_hir_types.put(case_dest, tracked_hir_type);
            const case_result_type = typeIdToZigTypeWithStore(tracked_hir_type, self.type_store);
            if (case_result_type != .any and case_result_type != .void) {
                try self.known_local_types.put(case_dest, case_result_type);
            }
            return case_dest;
        }

        const dest = self.next_local;
        self.next_local += 1;

        // Record the HIR-level type of this expression's dest local. The
        // `emitLocalGet` helper consults `local_hir_types[source]` to
        // decide whether a follow-up `.retain` is required, so this
        // population is what lets pattern-binding extraction sites see
        // the scrutinee local's ARC-managed type even though they only
        // have the scrutinee local id, not its HIR expression node. The
        // `expr.type_id` may be `UNKNOWN` for some lowered shapes; that
        // is acceptable because `isArcManagedType(UNKNOWN)` returns
        // false and conservative non-retain is correct for unknown
        // types (they cannot be ARC-managed as far as the IR knows).
        try self.local_hir_types.put(dest, tracked_hir_type);

        switch (expr.kind) {
            .int_lit => |v| {
                const int_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const resolved = if (int_type == .any) .i64 else int_type;
                const hint: ?ZigType = if (resolved != .i64) resolved else null;
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = dest, .value = v, .type_hint = hint },
                });
                try self.known_local_types.put(dest, resolved);
            },
            .float_lit => |v| {
                const float_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const resolved = if (float_type == .any) .f64 else float_type;
                const hint: ?ZigType = if (resolved != .f64) resolved else null;
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = dest, .value = v, .type_hint = hint },
                });
                try self.known_local_types.put(dest, resolved);
            },
            .string_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .string);
            },
            .atom_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_atom = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .atom);
            },
            .bool_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = dest, .value = v },
                });
                try self.known_local_types.put(dest, .bool_type);
            },
            .nil_lit => {
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
                try self.known_local_types.put(dest, .nil);
            },
            .local_get => |idx| {
                // Funnel through the unified helper so the named-binding
                // alias gets the same retain treatment as the four
                // pattern-binding extraction sites in case / decision-
                // tree lowering. The helper consults `local_hir_types`
                // so that even when the named binding's HIR type was
                // not flagged on `expr.type_id` (e.g. a stale
                // pre-monomorphization id), the source local's tracked
                // HIR type still drives the correct retain decision.
                try self.emitLocalGet(dest, idx);
            },
            .param_get => |idx| {
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = dest, .index = idx },
                });
                // Phase 3: track known type from HIR expr type_id
                var param_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                // Always prefer the declared param type from the function signature.
                // The expression's type_id may be stale (from before monomorphization)
                // or incorrectly concretized. The function's declared param types are
                // the authoritative source of truth after monomorphization.
                if (idx < self.current_param_types.items.len) {
                    param_zig_type = self.current_param_types.items[idx];
                }
                if (param_zig_type != .any) {
                    try self.known_local_types.put(dest, param_zig_type);
                }
                // Phase E.5 Gap 2: override the universal
                // `local_hir_types[dest] = expr.type_id` (set above at
                // expression entry) with the function signature's
                // declared parameter HIR type when available. The HIR
                // expression's `type_id` may be `UNKNOWN` (or stale
                // from before monomorphization) for some param_get
                // sites; the function's declared param HIR type is the
                // authoritative source. Without this override
                // `isArcManagedLocal(dest)` returns false on the param-
                // bound local in single-clause functions, so
                // `local_ownership[dest] = .trivial` and downstream
                // arc_liveness/verifier never treat the param read as
                // ARC-managed.
                if (idx < self.current_param_hir_types.items.len) {
                    const declared_hir_type = self.current_param_hir_types.items[idx];
                    try self.local_hir_types.put(dest, declared_hir_type);
                }
                // Mark this local as param-backed so call-name encoding
                // can detect bridge calls that thread function parameters
                // straight into a `:zig.<Container>.<method>` site.
                try self.param_backed_locals.put(dest, {});
            },
            .binary => |bin| {
                const lhs = try self.lowerExpr(bin.lhs);
                const rhs = try self.lowerExpr(bin.rhs);
                try self.local_hir_types.put(dest, self.binaryResultHirType(expr.type_id, lhs, rhs));
                // Detect string comparison — Zig needs std.mem.eql, not ==
                const lhs_is_string = if (self.known_local_types.get(lhs)) |t| t == .string else (bin.lhs.type_id == types_mod.TypeStore.STRING);
                const rhs_is_string = if (self.known_local_types.get(rhs)) |t| t == .string else (bin.rhs.type_id == types_mod.TypeStore.STRING);
                const is_string_cmp = lhs_is_string or rhs_is_string;

                const ir_op: BinaryOp.Op = switch (bin.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .rem_op => .rem_op,
                    .equal => if (is_string_cmp) .string_eq else .eq,
                    .not_equal => if (is_string_cmp) .string_neq else .neq,
                    .less => .lt,
                    .greater => .gt,
                    .less_equal => .lte,
                    .greater_equal => .gte,
                    .and_op => .bool_and,
                    .or_op => .bool_or,
                    .concat => .concat,
                    .in_op => blk: {
                        // Detect if RHS is the native Range struct
                        if (bin.rhs.kind == .struct_init) {
                            if (self.type_store) |ts| {
                                if (bin.rhs.type_id < ts.types.items.len) {
                                    const rhs_type = ts.getType(bin.rhs.type_id);
                                    if (rhs_type == .struct_type) {
                                        if (self.isNativeRangeStruct(rhs_type.struct_type.name)) break :blk .in_range;
                                    }
                                }
                            }
                        }
                        break :blk .in_list;
                    },
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{
                        .dest = dest,
                        .op = ir_op,
                        .lhs = lhs,
                        .rhs = rhs,
                        .result_type = self.binaryResultZigType(expr.type_id, lhs, rhs),
                    },
                });
            },
            .unary => |un| {
                const operand = try self.lowerExpr(un.operand);
                const ir_op: UnaryOp.Op = switch (un.op) {
                    .negate => .negate,
                    .not_op => .bool_not,
                };
                try self.current_instrs.append(self.allocator, .{
                    .unary_op = .{ .dest = dest, .op = ir_op, .operand = operand },
                });
            },
            .call => |call| {
                var args: std.ArrayList(LocalId) = .empty;
                var arg_modes: std.ArrayList(ValueMode) = .empty;
                var shared_release_locals: std.ArrayList(LocalId) = .empty;
                for (call.args, 0..) |arg, arg_index| {
                    const arg_ownership_type = self.typeOnlyArgType(arg);
                    const arg_local = blk: {
                        const saved_expected_type = self.current_expected_type;
                        const target_expected_type = self.callTargetExpectedType(call.target, call.args.len, arg_index) orelse arg.expected_type;
                        self.current_expected_type = if (target_expected_type != types_mod.TypeStore.UNKNOWN and
                            target_expected_type != types_mod.TypeStore.ERROR)
                            target_expected_type
                        else
                            null;
                        defer self.current_expected_type = saved_expected_type;
                        break :blk try self.lowerExpr(arg.expr);
                    };
                    const lowered_arg = switch (arg.mode) {
                        .move => blk: {
                            const moved_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{ .move_value = .{ .dest = moved_local, .source = arg_local } });
                            if (self.known_local_types.get(arg_local)) |src_type| {
                                try self.known_local_types.put(moved_local, src_type);
                            }
                            break :blk moved_local;
                        },
                        .share => blk: {
                            const has_arg_ownership_type = arg_ownership_type != types_mod.TypeStore.UNKNOWN and
                                arg_ownership_type != types_mod.TypeStore.ERROR;
                            // Three-tier resolution of the share's HIR
                            // source type, in order of preference:
                            //   1. `arg_ownership_type` from the call
                            //      target's parameter signature (most
                            //      authoritative when known).
                            //   2. `arg.expr.type_id` from the type checker
                            //      (works when the type checker resolved
                            //      the expression to a concrete type).
                            //   3. `local_hir_types[arg_local]` from the
                            //      IR-builder's type tracking (the
                            //      fallback that catches `t.left` /
                            //      `t.right` field accesses on indirect-
                            //      storage recursive struct types where
                            //      the HIR type checker leaves the
                            //      expression type as `UNKNOWN`. Without
                            //      this fallback, no `share_value` is
                            //      emitted at the call site, so no post-
                            //      call `.release` is paired with the
                            //      field-extracted local's `.retain` —
                            //      the binarytrees-class leak.
                            const arg_local_hir = self.local_hir_types.get(arg_local);
                            const arg_local_hir_is_arc = if (arg_local_hir) |tid|
                                self.isArcManagedType(tid)
                            else
                                false;
                            const share_hir_source = if (has_arg_ownership_type)
                                arg_ownership_type
                            else if (arg.expr.type_id != types_mod.TypeStore.UNKNOWN and arg.expr.type_id != types_mod.TypeStore.ERROR)
                                arg.expr.type_id
                            else if (arg_local_hir) |tid|
                                tid
                            else
                                arg.expr.type_id;
                            const should_share_arc = if (has_arg_ownership_type)
                                self.isArcManagedType(arg_ownership_type)
                            else if (self.isArcManagedType(arg.expr.type_id))
                                true
                            else
                                arg_local_hir_is_arc;
                            if (should_share_arc) {
                                const shared_local = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{ .share_value = .{ .dest = shared_local, .source = arg_local } });
                                // Phase 1 Class A item 2: emit an
                                // explicit `.retain { kind: .normal }`
                                // for the share's dest so the IR carries
                                // the retain semantics that the ZIR
                                // `.share_value` mode=retain handler
                                // used to emit implicitly via
                                // `retainAny`. The `.share_value` is
                                // now pure dataflow alias; the retain
                                // is the IR-level signal every analysis
                                // pass can see. The ConsumeSiteRewriter
                                // strips this `.retain` when it rewrites
                                // the `.share_value` to `.move_value`
                                // (consume mode transfers ownership
                                // without bumping refcount).
                                try self.current_instrs.append(self.allocator, .{ .retain = .{ .value = shared_local, .kind = .normal } });
                                if (self.known_local_types.get(arg_local)) |src_type| {
                                    try self.known_local_types.put(shared_local, src_type);
                                }
                                // Phase E.5 Gap 1: propagate the source's
                                // HIR type onto `shared_local` so the
                                // verifier's V2 invariant (release target
                                // must match the local's HIR-derived
                                // ownership class) sees the shared local
                                // as ARC-managed. Without this propagation
                                // a downstream `.release{value=shared_local}`
                                // looks like it targets a `.trivial` local
                                // (the default for unknown HIR types) and
                                // the verifier raises a spurious mismatch.
                                //
                                // Phase H.1: prefer `arg.expr.type_id` when
                                // it is ARC-managed and the source local's
                                // tracked HIR type is `UNKNOWN` or non-ARC.
                                // The for-comprehension desugaring produces
                                // call results whose `local_hir_types` entry
                                // ends up tagged with the synthetic
                                // `UNKNOWN` type, but the type checker has
                                // resolved the call's `expr.type_id` to the
                                // correct list type. Using the type-checked
                                // expression type at the share site keeps
                                // the shared-local's ownership class in
                                // sync with the runtime ABI: we already
                                // know `arg.expr.type_id` is ARC-managed
                                // (the surrounding `if` predicate gates
                                // the branch on exactly that).
                                const tracked_hir = self.local_hir_types.get(arg_local);
                                const shared_hir_type: hir_mod.TypeId = if (tracked_hir) |tid|
                                    (if (self.isArcManagedType(tid)) tid else share_hir_source)
                                else
                                    share_hir_source;
                                try self.local_hir_types.put(shared_local, shared_hir_type);
                                // Propagate param-backed marker so dispatch
                                // encoders that fall back to runtime type-
                                // derived helpers for `param: anytype`
                                // bridge calls still see the share'd local
                                // as param-backed. Otherwise the encoder
                                // would burn the post-monomorph nominal
                                // type into the call name, but the runtime
                                // value may carry a different instantiation
                                // (e.g. Map(K, Term)) and trip a type
                                // mismatch in the generated Zig.
                                if (self.param_backed_locals.contains(arg_local)) {
                                    try self.param_backed_locals.put(shared_local, {});
                                }
                                try shared_release_locals.append(self.allocator, shared_local);
                                break :blk shared_local;
                            }
                            break :blk arg_local;
                        },
                        .borrow => arg_local,
                    };
                    try args.append(self.allocator, lowered_arg);
                    try arg_modes.append(self.allocator, arg.mode);
                }

                // Phase 1.2.5 Gap 2 follow-up: call-site auto-boxing into
                // a `runtime.ProtocolBox`. When the target parameter slot
                // is typed as `.protocol_box(P)` (a `protocol_constraint`
                // function parameter) and the supplied argument is a
                // concrete struct value implementing `P`, wrap it via
                // `maybeBoxAsProtocol`. The struct-literal and union-
                // variant lowering paths already auto-box at construction
                // sites; this extends the same coercion to ordinary call
                // arguments. Without it, calling `Demo.walk(%Outer{})`
                // against `pub fn walk(e :: Error)` passes the bare
                // concrete value where a ProtocolBox is expected, and
                // downstream lowering attempts to emit a
                // `zap_runtime.Error` namespace member that does not
                // exist.
                if (self.type_store) |ts| {
                    for (call.args, 0..) |arg, i| {
                        if (i >= args.items.len) break;
                        const target_expected_type =
                            self.callTargetExpectedType(call.target, call.args.len, i) orelse
                            arg.expected_type;
                        if (target_expected_type == types_mod.TypeStore.UNKNOWN) continue;
                        if (target_expected_type == types_mod.TypeStore.ERROR) continue;
                        const expected_zig_type = typeIdToZigTypeWithStore(target_expected_type, ts);
                        if (expected_zig_type != .protocol_box) continue;
                        const boxed = try self.maybeBoxAsProtocol(args.items[i], expected_zig_type);
                        args.items[i] = boxed;
                    }
                }

                // Implicit numeric widening: insert int_widen/float_widen
                // when an arg's type is narrower than the expected param type.
                if (self.type_store) |ts| {
                    for (call.args, 0..) |arg, i| {
                        if (i >= args.items.len) break;
                        const expected = arg.expected_type;
                        if (expected == types_mod.TypeStore.UNKNOWN) continue;
                        const actual = self.typeOnlyArgType(arg);
                        if (actual == types_mod.TypeStore.UNKNOWN) continue;
                        if (ts.canWidenTo(actual, expected)) {
                            const widened_local = self.next_local;
                            self.next_local += 1;
                            const dest_zig_type = typeIdToZigTypeWithStore(expected, self.type_store);
                            const actual_type = ts.getType(actual);
                            if (actual_type == .int) {
                                try self.current_instrs.append(self.allocator, .{
                                    .int_widen = .{ .dest = widened_local, .source = args.items[i], .dest_type = dest_zig_type },
                                });
                            } else if (actual_type == .float) {
                                try self.current_instrs.append(self.allocator, .{
                                    .float_widen = .{ .dest = widened_local, .source = args.items[i], .dest_type = dest_zig_type },
                                });
                            } else {
                                continue;
                            }
                            args.items[i] = widened_local;
                        }
                    }
                }

                switch (call.target) {
                    .direct => |dc| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        try self.current_instrs.append(self.allocator, .{
                            .call_direct = .{ .dest = dest, .function = dc.function_group_id, .clause_index = dc.clause_index, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                        try self.trackCallResultType(dest, tracked_hir_type);
                    },
                    .named => |nc| {
                        const call_arity = call.args.len;

                        // Phase 1.2.5.d consumption-site dispatch. When the
                        // user writes `Protocol.method(receiver, ...)` and
                        // `receiver`'s static Zig type is
                        // `.protocol_box(<Protocol>)`, route the call
                        // through `protocol_dispatch` rather than the
                        // regular `call_named` path. The regular path
                        // would try to resolve `Protocol__method__N` and
                        // fall through to a bare-call lookup — there is
                        // no monomorphized impl symbol the dispatch can
                        // point at, because the box's concrete inner
                        // type is statically erased.
                        //
                        // The detection is opportunistic: we require
                        // (1) the call to be struct-qualified, (2) the
                        // first arg to be tracked as `.protocol_box(P)`
                        // for some protocol `P` matching `nc.struct_name`,
                        // and (3) the method to be declared on `P`.
                        // Any miss falls through to the existing path
                        // (which preserves backward compatibility for
                        // `Protocol.method(concreteValue)` shapes — the
                        // upstream `protocolDispatchStruct` already
                        // rewrites those to `<Impl>.method(...)` in HIR).
                        if (nc.struct_name) |mod| dispatch_blk: {
                            if (args.items.len == 0) break :dispatch_blk;
                            const receiver_local = args.items[0];
                            const receiver_zig_type =
                                self.known_local_types.get(receiver_local) orelse
                                typeIdToZigTypeWithStore(
                                    call.args[0].expr.type_id,
                                    self.type_store,
                                );
                            if (receiver_zig_type != .protocol_box) break :dispatch_blk;
                            if (!std.mem.eql(u8, receiver_zig_type.protocol_box, mod))
                                break :dispatch_blk;

                            const slot = self.findProtocolMethodSlotByScope(
                                mod,
                                nc.name,
                            ) orelse break :dispatch_blk;

                            // The receiver flows in as the implicit
                            // first slot of the synthesized
                            // dispatcher helper; the remaining args
                            // are the user's non-receiver arguments.
                            const lowered_args = try args.toOwnedSlice(self.allocator);
                            const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);

                            const non_recv_args = lowered_args[1..];
                            const non_recv_modes = lowered_modes[1..];

                            const owned_args = try self.allocator.dupe(LocalId, non_recv_args);
                            const owned_modes = try self.allocator.dupe(ValueMode, non_recv_modes);
                            // `lowered_args` / `lowered_modes` are
                            // arena-allocated by the surrounding
                            // ArrayList; we keep the receiver slot
                            // accessible through the dedicated
                            // `receiver` field rather than re-pack it.

                            const protocol_name_copy = try cloneBytes(self.allocator, mod);
                            const method_name_copy = try cloneBytes(self.allocator, nc.name);

                            try self.current_instrs.append(self.allocator, .{
                                .protocol_dispatch = .{
                                    .dest = dest,
                                    .receiver = receiver_local,
                                    .protocol_name = protocol_name_copy,
                                    .method_name = method_name_copy,
                                    .method_index = slot.method_index,
                                    .arity = slot.arity,
                                    .args = owned_args,
                                    .arg_modes = owned_modes,
                                    .return_type = slot.return_type,
                                },
                            });
                            try self.trackCallResultType(dest, tracked_hir_type);
                            // Track the dest's Zig type from the slot
                            // so downstream lowering sees a concrete
                            // return shape (mirrors call_named's
                            // `known_local_types` propagation through
                            // `trackCallResultType`).
                            if (slot.return_type != .any and slot.return_type != .void) {
                                try self.known_local_types.put(dest, slot.return_type);
                            }
                            return dest;
                        }

                        // For struct-qualified calls, try exact arity first, then higher
                        // arities for functions with default parameters. The function
                        // name is mangled so operator-named functions match the
                        // declarations registered in known_function_names.
                        const resolved_name = if (nc.struct_name) |mod| blk: {
                            const mangled_call_name = try mangleSymbolForZig(self.allocator, nc.name);
                            if (self.selectTypeOnlyNamedClause(mod, nc.name, call_arity, call.args, nc.clause_index)) |selected_clause| {
                                const candidate = try std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}__{s}__{d}__clause_{d}",
                                    .{ mod, mangled_call_name, selected_clause.declared_arity, selected_clause.clause_index },
                                );
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            if (nc.clause_index) |clause_index| {
                                const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}__clause_{d}", .{ mod, mangled_call_name, call_arity, clause_index });
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            var try_a: usize = call_arity;
                            while (try_a <= call_arity + 4) : (try_a += 1) {
                                const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, mangled_call_name, try_a });
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, mangled_call_name, call_arity });
                        } else try self.resolveBareCall(nc.name, @intCast(call_arity));

                        // Default params handled at ZIR call site (see zir_builder.zig call_named handler)

                        // Check if this function uses union dispatch — wrap args if needed
                        if (self.union_dispatch_map.get(resolved_name)) |info| {
                            var wrapped_args = try args.toOwnedSlice(self.allocator);
                            if (info.param_idx < wrapped_args.len) {
                                const arg_local = wrapped_args[info.param_idx];
                                // Determine the variant name from the argument's known type
                                const variant_name = blk: {
                                    if (self.known_local_types.get(arg_local)) |local_type| {
                                        if (local_type == .struct_ref) {
                                            if (info.variants.contains(local_type.struct_ref)) {
                                                break :blk local_type.struct_ref;
                                            }
                                        }
                                    }
                                    // Also check via HIR expr type_id
                                    if (info.param_idx < call.args.len) {
                                        const arg_type = typeIdToZigTypeWithStore(call.args[info.param_idx].expr.type_id, self.type_store);
                                        if (arg_type == .struct_ref) {
                                            if (info.variants.contains(arg_type.struct_ref)) {
                                                break :blk arg_type.struct_ref;
                                            }
                                        }
                                    }
                                    break :blk @as(?[]const u8, null);
                                };
                                if (variant_name) |vn| {
                                    // Emit union_init to wrap the arg
                                    const wrapped = self.next_local;
                                    self.next_local += 1;
                                    try self.current_instrs.append(self.allocator, .{
                                        .union_init = .{
                                            .dest = wrapped,
                                            .union_type = info.union_type_name,
                                            .variant_name = vn,
                                            .value = arg_local,
                                        },
                                    });
                                    try self.known_local_types.put(wrapped, .{ .struct_ref = info.union_type_name });
                                    wrapped_args[info.param_idx] = wrapped;
                                }
                            }
                            const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                            try self.current_instrs.append(self.allocator, .{
                                .call_named = .{ .dest = dest, .name = resolved_name, .args = wrapped_args, .arg_modes = lowered_modes },
                            });
                        } else {
                            const lowered_args = try args.toOwnedSlice(self.allocator);
                            const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                            try self.current_instrs.append(self.allocator, .{
                                .call_named = .{ .dest = dest, .name = resolved_name, .args = lowered_args, .arg_modes = lowered_modes },
                            });
                        }
                        try self.trackCallResultType(dest, tracked_hir_type);
                    },
                    .closure => |callee| {
                        const callee_local = try self.lowerExpr(callee);
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        const return_type = self.closureReturnType(expr.type_id, callee_local);
                        try self.current_instrs.append(self.allocator, .{
                            .call_closure = .{ .dest = dest, .callee = callee_local, .args = lowered_args, .arg_modes = lowered_modes, .return_type = return_type },
                        });
                        if (return_type != .any and return_type != .void) {
                            try self.known_local_types.put(dest, return_type);
                        }
                    },
                    .dispatch => |dc| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        try self.current_instrs.append(self.allocator, .{
                            .call_dispatch = .{ .dest = dest, .group_id = dc.function_group_id, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                        try self.trackCallResultType(dest, tracked_hir_type);
                    },
                    .builtin => |name| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        // Rewrite List builtins based on the argument's list element type.
                        // When a generic function like List.head(list :: [a]) is monomorphized
                        // with a = String, the `:zig.List.getHead(list)` call needs to
                        // become `StringList.getHead(list)` in the ZIR.
                        // Rewrite Map.method calls to the correct variant
                        // based on the first argument's map type.
                        const map_resolved = if (std.mem.startsWith(u8, name, "Map.") and lowered_args.len > 0) blk: {
                            const first_arg_type = self.known_local_types.get(lowered_args[0]) orelse .any;
                            if (std.meta.activeTag(first_arg_type) == .map) {
                                const key_zig = first_arg_type.map.key.*;
                                const val_zig = first_arg_type.map.value.*;
                                const method = name["Map.".len..];
                                // Generic-typed maps (typevars resolve to .any) cannot
                                // be encoded to a concrete `Map:K:V.method` name.
                                if (std.meta.activeTag(key_zig) == .any or std.meta.activeTag(val_zig) == .any) {
                                    break :blk name;
                                }
                                // Bridge calls inside generic functions (where `map`
                                // is a function parameter declared as `%{K=>V}`) are
                                // emitted with `param: anytype` in the Zap-generated
                                // Zig — which means the actual runtime `Map(K, V)`
                                // type at instantiation may differ from the param's
                                // post-monomorph nominal type (the canonical case is
                                // `Map(atom, term)` flowing into a `Map(atom, string)`
                                // monomorph). Detect this by checking whether the
                                // first arg's local was loaded via a `param_get`; if
                                // so, route through the runtime type-derived helpers
                                // (`mapGet`, ...) instead of burning the wrong
                                // concrete type into the call name.
                                if (self.localBackedByParam(lowered_args[0])) {
                                    break :blk name;
                                }
                                // Map(_, Term) in concrete callers (e.g. user code
                                // `Map.X(m, ...)` where m is a local with concrete
                                // `Map(atom, term)` storage) should also route
                                // through the helpers so wrap/unwrap happen.
                                if (std.meta.activeTag(val_zig) == .term or std.meta.activeTag(key_zig) == .term) {
                                    break :blk name;
                                }
                                // For struct/enum value types, encode for generic MapOf dispatch
                                if (std.meta.activeTag(val_zig) == .struct_ref) {
                                    const is_val_enum = if (self.type_store) |ts| val_enum: {
                                        for (ts.types.items) |typ| {
                                            if (typ == .tagged_union) {
                                                if (std.mem.eql(u8, ts.interner.get(typ.tagged_union.name), val_zig.struct_ref)) break :val_enum true;
                                            }
                                        }
                                        break :val_enum false;
                                    } else false;
                                    if (is_val_enum) {
                                        // Enum values lower to u32 atom IDs — route to Map(u32, u32) via the generic prefix.
                                        break :blk try std.fmt.allocPrint(self.allocator, "Map:u32:u32.{s}", .{method});
                                    } else {
                                        const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                        break :blk try std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ key_name, val_zig.struct_ref, method });
                                    }
                                }
                                // For nested map/list value types, encode for generic dispatch
                                if (std.meta.activeTag(val_zig) == .map or std.meta.activeTag(val_zig) == .list) {
                                    const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                    break :blk try std.fmt.allocPrint(self.allocator, "MapNested:{s}:{s}.{s}", .{ key_name, @tagName(std.meta.activeTag(val_zig)), method });
                                }
                                const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                const val_name = zigTypeToEncodedName(val_zig) orelse break :blk name;
                                break :blk try std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ key_name, val_name, method });
                            }
                            break :blk name;
                        } else name;

                        const resolved_name = if (std.mem.startsWith(u8, map_resolved, "List.") and lowered_args.len > 0) blk: {
                            const first_arg_type = self.known_local_types.get(lowered_args[0]) orelse .any;
                            if (std.meta.activeTag(first_arg_type) == .list) {
                                const elem_zig = first_arg_type.list.*;
                                const method = map_resolved["List.".len..];
                                // Generic-typed lists (element resolves to .any) defer
                                // encoding so the ZIR backend routes the call through
                                // the type-derived `listGetHead`/... helpers.
                                if (std.meta.activeTag(elem_zig) == .any) {
                                    break :blk map_resolved;
                                }
                                // Same anytype-param caveat as Map: bridge calls
                                // inside generic functions take `list: anytype`
                                // and the runtime element type may diverge from
                                // the post-monomorph nominal type. Defer to the
                                // type-derived helpers in those cases.
                                if (self.localBackedByParam(lowered_args[0])) {
                                    break :blk map_resolved;
                                }
                                if (std.meta.activeTag(elem_zig) == .term) {
                                    break :blk map_resolved;
                                }
                                // For struct element types, encode for generic dispatch.
                                // Enums (tagged_union mapped to struct_ref) use u32 atom IDs
                                // and go through the default named alias path.
                                if (std.meta.activeTag(elem_zig) == .struct_ref) {
                                    // Check if this is actually an enum — enums use u32 atom IDs
                                    const is_enum = if (self.type_store) |ts| blk_enum: {
                                        for (ts.types.items) |typ| {
                                            if (typ == .tagged_union) {
                                                if (std.mem.eql(u8, ts.interner.get(typ.tagged_union.name), elem_zig.struct_ref)) break :blk_enum true;
                                            }
                                        }
                                        break :blk_enum false;
                                    } else false;
                                    if (is_enum) {
                                        // Enum lists lower to u32 atom IDs — route to List(u32) via the generic prefix.
                                        break :blk try std.fmt.allocPrint(self.allocator, "List:u32.{s}", .{method});
                                    } else {
                                        break :blk try std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ elem_zig.struct_ref, method });
                                    }
                                }
                                if (std.meta.activeTag(elem_zig) == .list) {
                                    // Nested list: List(?*const List(T))
                                    // Use "ListNested:inner_type.method" encoding
                                    const inner_elem_name = zigTypeToEncodedName(elem_zig.list.*) orelse break :blk map_resolved;
                                    break :blk try std.fmt.allocPrint(self.allocator, "ListNested:{s}.{s}", .{ inner_elem_name, method });
                                }
                                const elem_name = zigTypeToEncodedName(elem_zig) orelse break :blk map_resolved;
                                break :blk try std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ elem_name, method });
                            }
                            break :blk map_resolved;
                        } else map_resolved;

                        // Track the call result's type from the HIR expression.
                        // The ZIR backend also consumes this metadata for
                        // constructor-style generic runtime calls such as
                        // `List.new_empty(capacity)`, where there is no receiver
                        // argument to recover `List(T)` from.
                        const call_result_type = typeIdToZigTypeWithStore(tracked_hir_type, self.type_store);
                        try self.current_instrs.append(self.allocator, .{
                            .call_builtin = .{
                                .dest = dest,
                                .name = resolved_name,
                                .args = lowered_args,
                                .arg_modes = lowered_modes,
                                .result_type = call_result_type,
                            },
                        });
                        if (call_result_type != .any and call_result_type != .void) {
                            try self.known_local_types.put(dest, call_result_type);
                        }
                    },
                }
                for (shared_release_locals.items) |shared_local| {
                    try self.current_instrs.append(self.allocator, .{ .release = .{ .value = shared_local } });
                }
            },
            .branch => {
                // branch should be desugared to case before reaching IR
                unreachable;
            },
            .tuple_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                var elem_zig_types: std.ArrayList(ZigType) = .empty;
                for (elems) |elem| {
                    const local = try self.lowerExpr(elem);
                    try locals.append(self.allocator, local);
                    try elem_zig_types.append(self.allocator, self.known_local_types.get(local) orelse .any);
                }
                const elements = try locals.toOwnedSlice(self.allocator);

                // Resolve the static tuple type for this expression (when
                // the type system inferred one). When the parent context
                // promoted some component to `Term` (heterogeneous unify),
                // the HIR-side type id reflects that — preferring it over
                // the per-element known_local_types means we can tell the
                // backend to wrap concrete values via `Term.from`.
                const inferred_tuple_type: ZigType = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const component_types: ?[]const ZigType = blk: {
                    if (inferred_tuple_type == .tuple and inferred_tuple_type.tuple.len == elems.len) {
                        // Copy the inferred component types so this slice is
                        // owned by the IR (the type-store-derived slice is
                        // owned elsewhere and may be aliased).
                        var copy: std.ArrayList(ZigType) = .empty;
                        for (inferred_tuple_type.tuple) |comp| {
                            try copy.append(self.allocator, comp);
                        }
                        break :blk try copy.toOwnedSlice(self.allocator);
                    }
                    break :blk null;
                };

                try self.current_instrs.append(self.allocator, .{
                    .tuple_init = .{ .dest = dest, .elements = elements, .component_types = component_types },
                });
                try self.known_local_types.put(dest, .{
                    .tuple = try elem_zig_types.toOwnedSlice(self.allocator),
                });
            },
            .list_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                for (elems) |elem| {
                    try locals.append(self.allocator, try self.lowerExpr(elem));
                }
                const elements = try locals.toOwnedSlice(self.allocator);
                const fallback_elem_type: ?ZigType = blk: {
                    if (elements.len > 0) {
                        break :blk self.listElementTypeFromLocal(elements[0]);
                    }
                    break :blk ZigType.i64;
                };
                const elem_type = self.chooseListElementType(expr.type_id, fallback_elem_type orelse .any);
                if (elem_type == .any and fallback_elem_type == null) return error.ListElementTypeUnavailable;
                try self.current_instrs.append(self.allocator, .{
                    .list_init = .{ .dest = dest, .elements = elements, .element_type = elem_type },
                });
                const list_zig_type = try self.listTypeFromHirOrElement(expr.type_id, elem_type);
                try self.known_local_types.put(dest, list_zig_type);
            },
            .list_cons => |lc| {
                const head = try self.lowerExpr(lc.head);
                const tail = try self.lowerExpr(lc.tail);
                const fallback_elem_type = self.listElementTypeFromTailLocal(tail) orelse
                    self.listElementTypeFromLocal(head);
                const elem_type = self.chooseListElementType(expr.type_id, fallback_elem_type orelse .any);
                if (elem_type == .any and fallback_elem_type == null) return error.ListElementTypeUnavailable;
                try self.current_instrs.append(self.allocator, .{
                    .list_cons = .{ .dest = dest, .head = head, .tail = tail, .element_type = elem_type },
                });
                const list_zig_type = try self.listTypeFromHirOrElement(expr.type_id, elem_type);
                try self.known_local_types.put(dest, list_zig_type);
            },
            .panic => |msg| {
                const msg_local = try self.lowerExpr(msg);
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "panic", .message_local = msg_local },
                });
            },
            .never => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "unreachable" },
                });
            },
            .unwrap => |inner| {
                const source = try self.lowerExpr(inner);
                try self.current_instrs.append(self.allocator, .{
                    .optional_unwrap = .{ .dest = dest, .source = source },
                });
                // The unwrapped type is the inner type of the optional
                if (self.known_local_types.get(source)) |source_type| {
                    switch (source_type) {
                        .optional => |inner_type| try self.known_local_types.put(dest, inner_type.*),
                        else => try self.known_local_types.put(dest, source_type),
                    }
                }
            },
            .case => |case_data| {
                // Case expressions are handled specially — see lowerExpr early return
                // (this branch should not be reached because of the early return above)
                try self.lowerCaseExprBody(dest, try self.lowerExpr(case_data.scrutinee), case_data);
            },
            .block => |blk| {
                // Lower each statement in the block; result is the last expression value
                var last_local: ?LocalId = null;
                for (blk.stmts) |stmt| {
                    switch (stmt) {
                        .expr => |e| {
                            last_local = try self.lowerExpr(e);
                        },
                        .local_set => |ls| {
                            const val = try self.lowerExpr(ls.value);
                            try self.current_instrs.append(self.allocator, .{
                                .local_set = .{ .dest = ls.index, .value = val },
                            });
                            // Propagate the source local's type so a
                            // downstream `field_get` on this binding can
                            // still resolve its struct nominal type and
                            // run indirect-storage auto-deref.
                            if (self.known_local_types.get(val)) |t| {
                                try self.known_local_types.put(ls.index, t);
                            }
                        },
                        .function_group => |group| {
                            // Anonymous functions and nested functions defined
                            // inside block expressions must be built as IR functions.
                            const saved_instrs = self.current_instrs;
                            const saved_next_local = self.next_local;
                            const saved_known_local_types = self.known_local_types;
                            const saved_local_hir_types = self.local_hir_types;
                            self.current_instrs = .empty;
                            self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                            self.local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(self.allocator);
                            defer {
                                self.known_local_types.deinit();
                                self.known_local_types = saved_known_local_types;
                                self.local_hir_types.deinit();
                                self.local_hir_types = saved_local_hir_types;
                            }
                            try self.buildFunctionGroup(group);
                            self.current_instrs = saved_instrs;
                            self.next_local = saved_next_local;
                        },
                    }
                }
                if (last_local) |ll| {
                    // Alias the block result to the destination
                    try self.current_instrs.append(self.allocator, .{
                        .local_set = .{ .dest = dest, .value = ll },
                    });
                } else {
                    try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
                }
            },
            .struct_init => |si| {
                // Lower struct initialization fields.
                //
                // Phase 1.2.5.c: per field, after lowering the value
                // expression, consult the field's declared ZigType
                // to decide whether the value flows into a
                // protocol-box slot. The construction-site detector
                // `maybeBoxAsProtocol` emits a `box_as_protocol`
                // coercion when the field is typed as `.protocol_box(P)`
                // and the value is a concrete struct implementing `P`.
                const struct_type_name = self.resolveTypeName(si.type_id);
                var ir_fields: std.ArrayList(StructFieldInit) = .empty;
                for (si.fields) |field| {
                    var val = try self.lowerExpr(field.value);
                    const field_name_str = self.interner.get(field.name);
                    if (self.fieldZigTypeAndStorage(struct_type_name, field_name_str)) |field_info| {
                        val = try self.maybeBoxAsProtocol(val, field_info.type_expr);
                    }
                    try ir_fields.append(self.allocator, .{
                        .name = field_name_str,
                        .value = val,
                    });
                }
                // Resolve type name from type_id (cached above for
                // the per-field coercion lookup; reuse here so the
                // struct_init instruction carries the same name).
                const type_name = struct_type_name;
                try self.current_instrs.append(self.allocator, .{
                    .struct_init = .{
                        .dest = dest,
                        .type_name = type_name,
                        .fields = try ir_fields.toOwnedSlice(self.allocator),
                    },
                });
                // Track the constructed value's nominal type so a later
                // `field_get` on this local can resolve struct identity
                // for indirect-storage auto-deref.
                try self.known_local_types.put(dest, .{ .struct_ref = type_name });
            },
            .error_pipe => |ep| {
                // Lower the error pipe so that a failure in any dispatched
                // step short-circuits the rest of the pipeline. The catch-
                // basin expression value is either the value of the last step
                // (when every dispatched step matched) or the value of the
                // handler (when one of them did not).
                //
                // To express the short-circuit without emitting a `ret`
                // (which would hijack the enclosing function's return), every
                // dispatched step is lowered as a `try_call_named` whose
                // success branch carries the rest of the pipe inline. The
                // ZIR backend turns this into a nested if-else block whose
                // value flows through `setLocal(dest, ...)` here.
                if (ep.steps.len == 0) return dest;

                const handler_hir = ep.handler;

                // Lower the base value at the top level (no try_call wraps it).
                var pipe_val = try self.lowerExpr(ep.steps[0].expr);

                const remaining_steps = ep.steps[1..];

                // Walk the remaining steps. As soon as we hit a dispatched
                // step, the rest of the pipe must be emitted INSIDE that
                // step's success branch (so a failure jumps over them all
                // and yields the handler's value). Non-dispatched steps
                // before any dispatched step can stay at the top level.
                var idx: usize = 0;
                while (idx < remaining_steps.len) : (idx += 1) {
                    const step = remaining_steps[idx];
                    if (step.expr.kind != .call) continue;
                    if (!step.is_dispatched) {
                        // Single-clause total step: emit a regular call
                        // inline, then continue with the next step.
                        const lowered = try self.lowerSingleErrorPipeCall(step, pipe_val);
                        pipe_val = lowered;
                        continue;
                    }
                    // Dispatched step: emit a try_call_named whose success
                    // branch holds the rest of the pipe (recursively built
                    // as a nested instruction list).
                    const try_local = try self.lowerErrorPipeTryStep(
                        step,
                        pipe_val,
                        remaining_steps[idx + 1 ..],
                        ep.err_local,
                        handler_hir,
                    );
                    return try_local;
                }
                // No dispatched step appeared after the base value (or there
                // were no dispatched calls at all). The handler is dead
                // code, but we still must produce the pipe's value: it is
                // the result of the last (non-dispatched) call.
                return pipe_val;
            },
            .union_init => |ui| {
                var value_local = try self.lowerExpr(ui.value);
                const type_name = self.resolveTypeName(ui.union_type_id);
                const variant_name_str = self.interner.get(ui.variant_name);
                // Phase 1.2.5.c: when the variant's payload is typed
                // as a `.protocol_box(P)` (e.g. `Option(Error).Some`
                // whose substituted payload is `protocol_box("Error")`)
                // and the supplied value is a concrete struct
                // implementing P, wrap the value in a
                // `runtime.ProtocolBox` via `box_as_protocol`.
                if (self.variantPayloadZigTypeByName(type_name, variant_name_str)) |variant_payload_type| {
                    value_local = try self.maybeBoxAsProtocol(value_local, variant_payload_type);
                }
                try self.current_instrs.append(self.allocator, .{
                    .union_init = .{
                        .dest = dest,
                        .union_type = type_name,
                        .variant_name = variant_name_str,
                        .value = value_local,
                    },
                });
            },
            .try_project => |tp| try self.lowerTryProject(tp, dest),
            .field_get => |fg| {
                // Check for enum variant access (object is nil_lit placeholder with enum type)
                if (fg.object.kind == .nil_lit and self.type_store != null) {
                    const typ = self.type_store.?.getType(fg.object.type_id);
                    if (typ == .tagged_union) {
                        try self.current_instrs.append(self.allocator, .{
                            .enum_literal = .{
                                .dest = dest,
                                .type_name = self.interner.get(typ.tagged_union.name),
                                .variant = self.interner.get(fg.field),
                            },
                        });
                        return dest;
                    }
                    // Parametric nullary variant: `Option(i64).None`.
                    // The HIR emits a `field_get` whose object is a
                    // `nil_lit` carrying the `.applied { base = TaggedUnion, args }`
                    // TypeId. Route this through `enum_literal` with the
                    // per-instantiation mangled name so the ZIR layer
                    // can resolve `@import("Option_i64").Option_i64.<Variant>`
                    // — distinct from the concrete-tagged-union case
                    // above (which uses the bare declaration name).
                    if (typ == .applied) {
                        if (typ.applied.base < self.type_store.?.types.items.len) {
                            const base_typ = self.type_store.?.getType(typ.applied.base);
                            if (base_typ == .tagged_union) {
                                // The IR's `EnumLiteral.type_name` is
                                // consumed by ZIR via `emitStructTypeRef`
                                // when the variant is unit-only. Carry
                                // the per-instantiation mangled name
                                // (`Option_i64`) so the synthetic
                                // source file from Step 3.6 resolves
                                // the union type.
                                const type_name = self.resolveTypeName(fg.object.type_id);
                                try self.current_instrs.append(self.allocator, .{
                                    .enum_literal = .{
                                        .dest = dest,
                                        .type_name = type_name,
                                        .variant = self.interner.get(fg.field),
                                    },
                                });
                                return dest;
                            }
                        }
                    }
                }
                const obj = try self.lowerExpr(fg.object);
                const field_name = self.interner.get(fg.field);
                const struct_type = self.structTypeForFieldReceiver(obj);
                // If the HIR type checker did not resolve the field
                // access to a concrete TypeId (it stays `UNKNOWN`),
                // fall back to the field's declared type from the
                // struct definition. Without this, a `t.left` access
                // on a `Tree { left :: Tree | nil }` value records
                // `local_hir_types[dest] = UNKNOWN`, and
                // `emitArcRetainOnAggregateExtract` short-circuits
                // because `isArcManagedTypeId(UNKNOWN)` is false. The
                // resulting missed retain is the binarytrees-class
                // leak: ~610M tree nodes never freed because their
                // field-extracted child locals never reached
                // `arc_managed_locals`.
                if (struct_type) |sname| {
                    if (self.lookupStructFieldHirTypeByName(sname, field_name)) |field_hir_type| {
                        try self.local_hir_types.put(dest, field_hir_type);
                    }
                }
                try self.current_instrs.append(self.allocator, .{
                    .field_get = .{
                        .dest = dest,
                        .object = obj,
                        .field = field_name,
                        .struct_type = struct_type,
                    },
                });
                // Retain the extracted ARC value at the IR level. A plain
                // (non-ARC) struct's `field_get` lowers to `field_val`, which
                // never bumps the cell's refcount. Mirrors the tuple
                // `index_get` retain — multiple field reads from distinct
                // parents that share the underlying ARC pointer would
                // otherwise share a single +1 and double-free at scope exit.
                //
                // ARC-managed parent aggregates (Map, List) extract via
                // dedicated opcodes (`map_get`, `list_head`, …) whose runtime
                // helpers retain children internally, so they never reach
                // this `.field_get` site.
                //
                // Indirect-storage recursive struct fields (`?Tree.left` in
                // a `Tree { left :: Tree | nil, … }` shape) ARE handled here:
                // `isArcManagedTypeId` returns true for boxed-recursive
                // struct types via `structTypeUsesRecursiveBoxing`, so the
                // helper emits `.retain` IR. The matching scope-exit
                // `.release` is emitted by `arc_drop_insertion`. The ZIR
                // `.field_get` lowering performs only the storage-shape
                // auto-deref (`?*const T → ?T`); no ZIR-level retain
                // emission. (Phase 1 Class A.)
                try self.emitArcRetainOnAggregateExtract(dest);
                if (struct_type) |sname| {
                    if (self.fieldZigTypeAndStorage(sname, field_name)) |info| {
                        try self.known_local_types.put(dest, info.type_expr);
                    }
                }
            },
            .tuple_index_get => |tig| {
                const obj = try self.lowerExpr(tig.object);
                try self.current_instrs.append(self.allocator, .{
                    .index_get = .{ .dest = dest, .object = obj, .index = tig.index },
                });
                // Retain the extracted ARC value: a tuple is non-ARC
                // and its `index_get` lowers to `elem_val_imm`, which
                // never bumps the cell's refcount. Without this retain,
                // multiple destructures of the same tuple (or of
                // distinct tuples that share the underlying ARC pointer)
                // would each fire a scope-exit release against a single
                // +1, double-freeing the cell. `lowerExpr` set
                // `local_hir_types[dest] = expr.type_id` on entry, so
                // `isArcManagedLocal(dest)` consults the element's HIR
                // type (recorded by `emitDestructureStep` /
                // `lowerAssignmentDestructure` from the parent tuple's
                // static element type).
                try self.emitArcRetainOnAggregateExtract(dest);
                if (self.type_store) |ts| {
                    const obj_type = ts.getType(tig.object.type_id);
                    if (obj_type == .tuple and tig.index < obj_type.tuple.elements.len) {
                        try self.known_local_types.put(dest, typeIdToZigTypeWithStore(obj_type.tuple.elements[tig.index], self.type_store));
                    }
                }
            },
            .list_index_get => |lig| {
                const list_local = try self.lowerExpr(lig.list);
                const elem_type = self.listElementTypeForLocal(list_local) orelse
                    return error.ListElementTypeUnavailable;
                try self.current_instrs.append(self.allocator, .{
                    .list_get = .{ .dest = dest, .list = list_local, .index = lig.index, .element_type = elem_type },
                });
                try self.known_local_types.put(dest, elem_type);
            },
            .list_head_get => |lhg| {
                const list_local = try self.lowerExpr(lhg.list);
                const elem_type = self.listElementTypeForLocal(list_local) orelse
                    return error.ListElementTypeUnavailable;
                try self.current_instrs.append(self.allocator, .{
                    .list_head = .{ .dest = dest, .list = list_local, .element_type = elem_type },
                });
                try self.known_local_types.put(dest, elem_type);
            },
            .list_tail_get => |ltg| {
                const list_local = try self.lowerExpr(ltg.list);
                const elem_type = self.listElementTypeForLocal(list_local) orelse
                    return error.ListElementTypeUnavailable;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = dest, .list = list_local, .element_type = elem_type, .start_index = ltg.start_index },
                });
                if (self.known_local_types.get(list_local)) |list_type| {
                    try self.known_local_types.put(dest, list_type);
                }
            },
            .map_value_get => |mvg| {
                const map_local = try self.lowerExpr(mvg.map);
                const key_local = try self.lowerExpr(mvg.key);
                // Pull the map's K/V from the lowered map's known
                // type so ZIR resolves the right `Map(K, V)` cell.
                // Default to atom→i64 for legacy callers.
                const map_zig_type = self.known_local_types.get(map_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                // Use a synthesized default matching the value type.
                // Destructure assumes the key exists, so the runtime
                // never observes this — it just has to typecheck.
                const default_local = try self.emitDefaultValueForType(value_type);
                try self.current_instrs.append(self.allocator, .{
                    .map_get = .{
                        .dest = dest,
                        .map = map_local,
                        .key = key_local,
                        .default = default_local,
                        .key_type = key_type,
                        .value_type = value_type,
                    },
                });
                try self.known_local_types.put(dest, value_type);
            },
            .map_init => |entries| {
                var ir_entries: std.ArrayList(MapEntry) = .empty;
                // Read key/value types from the unified map type computed in
                // HIR (which already collapses disagreeing scalars to TERM and
                // unifies tuple shapes component-wise). Fall back to the first
                // entry's types only when HIR couldn't fix a unified type.
                var key_type: ZigType = .atom;
                var value_type: ZigType = .i64;
                blk: {
                    if (self.type_store) |ts| {
                        if (expr.type_id < ts.types.items.len) {
                            const map_t = ts.types.items[expr.type_id];
                            if (map_t == .map) {
                                key_type = typeIdToZigTypeWithStore(map_t.map.key, self.type_store);
                                value_type = typeIdToZigTypeWithStore(map_t.map.value, self.type_store);
                                break :blk;
                            }
                        }
                    }
                    if (entries.len > 0) {
                        key_type = typeIdToZigTypeWithStore(entries[0].key.type_id, self.type_store);
                        value_type = typeIdToZigTypeWithStore(entries[0].value.type_id, self.type_store);
                    }
                }
                for (entries) |entry| {
                    const key = try self.lowerExpr(entry.key);
                    const value = try self.lowerExpr(entry.value);
                    try ir_entries.append(self.allocator, .{ .key = key, .value = value });
                }
                try self.current_instrs.append(self.allocator, .{
                    .map_init = .{
                        .dest = dest,
                        .entries = try ir_entries.toOwnedSlice(self.allocator),
                        .key_type = key_type,
                        .value_type = value_type,
                    },
                });
                // Track the map's concrete type so Map.method calls can dispatch
                const kt = try self.allocator.create(ZigType);
                kt.* = key_type;
                const vt = try self.allocator.create(ZigType);
                vt.* = value_type;
                try self.known_local_types.put(dest, .{ .map = .{ .key = kt, .value = vt } });
            },
            .capture_get => |index| {
                try self.current_instrs.append(self.allocator, .{
                    .capture_get = .{ .dest = dest, .index = index },
                });
                const capture_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                if (capture_zig_type != .any) {
                    try self.known_local_types.put(dest, capture_zig_type);
                }
            },
            .closure_create => |cc| {
                var capture_locals: std.ArrayList(LocalId) = .empty;
                for (cc.captures) |capture| {
                    try capture_locals.append(self.allocator, try self.lowerExpr(capture.expr));
                }
                try self.current_instrs.append(self.allocator, .{
                    .make_closure = .{
                        .dest = dest,
                        .function = cc.function_group_id,
                        .captures = try capture_locals.toOwnedSlice(self.allocator),
                    },
                });
            },
            else => {
                // Emit a nil placeholder for unhandled expressions
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
            },
        }

        return dest;
    }

    /// Resolve a type_id to a string name for struct/enum types.
    fn resolveTypeName(self: *IrBuilder, type_id: types_mod.TypeId) []const u8 {
        if (self.type_store) |ts| {
            const typ = ts.getType(type_id);
            switch (typ) {
                .struct_type => |st| return self.interner.get(st.name),
                .tagged_union => |tu| return self.interner.get(tu.name),
                .applied => {
                    // Route an `.applied` instantiation to its
                    // canonical per-instantiation mangled name
                    // (`Box_i64`). The ZIR layer emits one struct
                    // type per instantiation, so the IR's
                    // `struct_init.type_name` and `field_get.struct_type`
                    // strings must carry the per-instantiation name
                    // rather than the parametric base name — otherwise
                    // `Box(i64)` and `Box(String)` collide on a single
                    // `Box` struct decl at the ZIR layer and field
                    // offsets / layouts mismatch.
                    if (self.appliedSpecializationByTypeId(type_id)) |spec| {
                        return spec.mangled_name;
                    }
                    // Fallback: should not happen post-monomorphization,
                    // but keep the function total so callers never see
                    // a Zig-side panic.
                    return "UnknownType";
                },
                else => {},
            }
        }
        return "UnknownType";
    }

    /// Resolve a bare function call to a qualified name with arity.
    /// Resolution order: current struct → Kernel → top-level → bare name.
    /// Also checks higher arities for functions with default parameters.
    fn resolveBareCall(self: *IrBuilder, name: []const u8, arity: u32) ![]const u8 {
        // Names containing operator characters are mangled before lookup so the
        // qualified candidates match the entries registered in
        // known_function_names (which are also mangled).
        const mangled_name = try mangleSymbolForZig(self.allocator, name);
        // Try exact arity first, then higher arities (for default params)
        var try_arity: u32 = arity;
        while (try_arity <= arity + 4) : (try_arity += 1) {
            // 1. Current struct function
            if (self.current_struct_prefix) |prefix| {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, mangled_name, try_arity });
                if (self.known_function_names.contains(qualified)) return qualified;
            }
            // 2. Top-level function (bare name with arity)
            {
                const top_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_name, try_arity });
                if (self.known_function_names.contains(top_name)) return top_name;
            }
            // Kernel functions are resolved via auto-import in the collector —
            // they appear as regular imports in the struct scope, so steps 1-2
            // handle them. No hardcoded Kernel fallback needed.
        }
        // 4. Keep bare (unmangled) name — Zig compiler will error
        return name;
    }

    /// Convert an ast.StructName to a prefix string for function naming.
    /// Single-part: "IO". Multi-part: "IO_File".
    fn structNameToPrefix(self: *IrBuilder, name: ast.StructName) []const u8 {
        if (name.parts.len == 1) return self.interner.get(name.parts[0]);
        return name.joinedWith(self.allocator, self.interner, "_") catch self.interner.get(name.parts[0]);
    }

    fn allocSlice(self: *IrBuilder, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

/// Walk a Decision tree to find the param_get index used for the N-th tuple element.
/// The decision tree's check_tuple success subtree references element scrutinee IDs
/// via param_get nodes. This scans to find the ID associated with a given element index.
/// Convert a Zap function name into a Zig-safe identifier.
///
/// Zig identifiers allow `[A-Za-z0-9_]` (plus `?`/`!` in Zap-specific
/// positions which Zig's parser tolerates in @"..." form here). Operator
/// chars (`+ - * / < > = ! | & ^ ~ % @ # $ . :`) are not Zig identifier
/// chars, so any name containing them — `+`, `==`, or composite names like
/// `Kernel_==__i64` produced by monomorphization — must be rewritten.
///
/// Strategy: per-char inline replacement. Each unsafe char becomes
/// `_<spelled-out>` (e.g., `=` → `_eq`, `+` → `_plus`). Safe chars pass
/// through verbatim. Returns the input unchanged when no mangling is needed.
/// Look up the per-impl vtable instance constant name for a
/// `(protocol_name, target_type_name)` pair (Phase 1.2.5.c). Walks
/// the program's `protocol_vtable_instance_def` TypeDefs — populated
/// by `populateProtocolVTables` from `pub impl` declarations — and
/// returns the matching instance's TypeDef name (e.g.
/// `"ErrorVTable_for_MyError"` for `impl Error for MyError`, or
/// `"ErrorVTable_for_Box_i64"` for a parametric impl specialization).
///
/// Construction-site lowering (`box_as_protocol` -> ZIR) uses this
/// to resolve the vtable constant's symbol so it can take the
/// constant's address and write the result into `ProtocolBox.vtable`.
///
/// Returns `null` when no impl is registered for the requested
/// `(protocol, target)` pair. Callers must surface a rich
/// diagnostic in that case — silently boxing without a vtable would
/// produce a null `vtable` pointer that the consumption site
/// (Phase 1.2.5.d) cannot dispatch against.
///
/// Match semantics: both the protocol name and target name are
/// compared byte-for-byte against the instance def's stored fields,
/// matching the canonical mangled forms emitted by
/// `emitProtocolVTableInstance` (concrete: `"MyError"`; parametric
/// specialization: `"Box_i64"`).
/// Look up the `(method_index, method_arity)` for a named method on
/// a named protocol, by scanning the program's `protocol_vtable_def`
/// TypeDefs (populated by `populateProtocolVTables`). `method_index`
/// is the zero-based slot offset in the protocol's source-declaration
/// order; `method_arity` is the receiver-inclusive parameter count.
///
/// Returns `null` when the protocol isn't registered or when the
/// method name doesn't match any declared method on the protocol —
/// the consumption-site lowering relies on the null result to fall
/// through to the regular call-named path with a coherent
/// diagnostic (the type checker should have caught the mismatch
/// upstream, but the explicit null arm keeps the IR pass robust
/// against drift).
///
/// Phase 1.2.5.d consumption-site dispatch (`protocol_dispatch` IR
/// op) consumes this helper to fill the `method_index` and `arity`
/// fields on the emitted instruction.
pub const ProtocolMethodSlot = struct {
    method_index: u32,
    arity: u32,
    return_type: ZigType,
};

pub fn findProtocolMethodSlot(
    program: *const Program,
    protocol_name: []const u8,
    method_name: []const u8,
) ?ProtocolMethodSlot {
    for (program.type_defs) |type_def| {
        switch (type_def.kind) {
            .protocol_vtable_def => |vt| {
                if (!std.mem.eql(u8, vt.protocol_name, protocol_name)) continue;
                for (vt.methods, 0..) |method, idx| {
                    if (!std.mem.eql(u8, method.name, method_name)) continue;
                    return .{
                        .method_index = @intCast(idx),
                        .arity = method.arity,
                        .return_type = method.return_type,
                    };
                }
                return null;
            },
            else => {},
        }
    }
    return null;
}

pub fn findProtocolImplVTable(
    program: *const Program,
    protocol_name: []const u8,
    target_type_name: []const u8,
) ?[]const u8 {
    for (program.type_defs) |type_def| {
        switch (type_def.kind) {
            .protocol_vtable_instance_def => |inst| {
                if (!std.mem.eql(u8, inst.protocol_name, protocol_name)) continue;
                if (!std.mem.eql(u8, inst.target_type_name, target_type_name)) continue;
                return type_def.name;
            },
            else => {},
        }
    }
    return null;
}

pub fn mangleSymbolForZig(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return name;
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
    if (!needs_mangle) return name;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => try buf.append(allocator, c),
            '+' => try buf.appendSlice(allocator, "_plus"),
            '-' => try buf.appendSlice(allocator, "_minus"),
            '*' => try buf.appendSlice(allocator, "_star"),
            '/' => try buf.appendSlice(allocator, "_slash"),
            '<' => try buf.appendSlice(allocator, "_lt"),
            '>' => try buf.appendSlice(allocator, "_gt"),
            '=' => try buf.appendSlice(allocator, "_eq"),
            '|' => try buf.appendSlice(allocator, "_pipe"),
            '&' => try buf.appendSlice(allocator, "_amp"),
            '^' => try buf.appendSlice(allocator, "_caret"),
            '~' => try buf.appendSlice(allocator, "_tilde"),
            '%' => try buf.appendSlice(allocator, "_pct"),
            '@' => try buf.appendSlice(allocator, "_at"),
            '#' => try buf.appendSlice(allocator, "_hash"),
            '$' => try buf.appendSlice(allocator, "_dollar"),
            '.' => try buf.appendSlice(allocator, "_dot"),
            ':' => try buf.appendSlice(allocator, "_colon"),
            else => try buf.appendSlice(allocator, "_x"),
        }
    }
    return try buf.toOwnedSlice(allocator);
}

fn findParamGetIdInDecision(decision: *const hir_mod.Decision, target_element: u32) u32 {
    switch (decision.*) {
        .check_tuple => |ct| {
            // This is a nested tuple check. The scrutinee expr tells us the ID.
            if (ct.scrutinee.kind == .param_get) {
                return ct.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(ct.success, target_element);
        },
        .switch_literal => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                // The first switch_literal we encounter should be for element 0,
                // second for element 1, etc. But we need to trace the right one.
                // We track by counting: the decision tree puts elements in order.
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                // For other elements, look in default/cases
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .switch_tag => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .check_list => |cl| {
            if (cl.scrutinee.kind == .param_get) {
                return cl.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(cl.success, target_element);
        },
        .check_list_cons => |clc| {
            if (clc.scrutinee.kind == .param_get) {
                return clc.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(clc.success, target_element);
        },
        .check_binary => |cb| {
            if (cb.scrutinee.kind == .param_get) {
                return cb.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(cb.success, target_element);
        },
        .extract_struct => |es| {
            if (es.scrutinee.kind == .param_get) {
                return es.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(es.success, target_element);
        },
        .extract_map => |em| {
            if (em.scrutinee.kind == .param_get) {
                return em.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(em.success, target_element);
        },
        .switch_variant => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .guard => |g| return findParamGetIdInDecision(g.success, target_element),
        .bind => |b| {
            if (b.source.kind == .param_get) {
                if (target_element == 0) return b.source.kind.param_get;
                return findParamGetIdInDecision(b.next, target_element - 1);
            }
            return findParamGetIdInDecision(b.next, target_element);
        },
        .success => {
            // We need to derive the ID from the pattern. The compilePatternMatrix
            // allocates IDs sequentially starting from a base. The base for tuple
            // element N of scrutinee S is: the next_id at the time of tuple expansion.
            // Since we don't store that, use a heuristic: the first referenced param_get
            // ID + target_element offset.
            return target_element;
        },
        .failure => return target_element,
    }
}

/// Map a ZigType to a canonical short name for generic container encoding.
/// Used in call_builtin name encoding: "List:i64.method", "Map:u32:str.method".
fn zigTypeToEncodedName(zig_type: ZigType) ?[]const u8 {
    return switch (std.meta.activeTag(zig_type)) {
        .i64 => "i64",
        .i128 => "i128",
        .i32 => "i32",
        .i16 => "i16",
        .i8 => "i8",
        .u64 => "u64",
        .u128 => "u128",
        .u32 => "u32",
        .u16 => "u16",
        .u8 => "u8",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
        .f32 => "f32",
        .f16 => "f16",
        .bool_type => "bool",
        .string => "str",
        .atom => "u32",
        .term => "Term",
        .struct_ref => zig_type.struct_ref,
        .tagged_union => zig_type.tagged_union,
        else => null,
    };
}

/// Walks every destructure-binding kind on every clause and returns one past
/// the maximum local_index used. The result is the lower bound for fresh
/// Whether a HIR `MatchPattern` is total — guaranteed to match any value of
/// its declared parameter type without runtime inspection. Bare bindings and
/// wildcards qualify; literals, tuples, lists, struct patterns, maps, pins,
/// list-cons, and binary patterns all perform some structural check and so
/// can fail to match. Used by `__try`-variant generation to decide whether a
/// single-clause function needs a dispatch wrapper for catch-basin callers.
fn isTotalMatchPattern(pattern: *const hir_mod.MatchPattern) bool {
    return switch (pattern.*) {
        .wildcard, .bind => true,
        else => false,
    };
}

/// local allocation in the function body (binding locals live above this).
/// All six binding kinds (tuple/struct/list/cons_tail/binary/map) must be
/// covered — omitting any one silently corrupts the local layout for the
/// affected pattern shape (this was the bug that broke `__try` variants on
/// map-pattern functions).
///
/// Phase E.5 Gap 3: also counts assignment-binding (`local_set.index`)
/// indices used in each clause body. HIR allocates these indices from
/// the same per-clause `next_local` counter as pattern bindings, so an
/// assignment like `name = expr` inside the body produces a
/// `local_set.index` that occupies the same numbering space as
/// pattern-binding indices. If the IR-level `next_local` is initialized
/// only from pattern bindings, IR-level expression lowering allocates
/// fresh locals starting BELOW the assignment-binding indices and
/// silently collides, causing `local_set` propagation to overwrite the
/// IR builder's `local_hir_types[ls.index]` with a stale entry.
/// Walking the body for `local_set` indices closes that collision.
fn computeMaxBindingLocalForClauses(clauses: []const hir_mod.Clause) LocalId {
    var max_local: LocalId = 0;
    for (clauses) |clause| {
        for (clause.tuple_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.struct_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.list_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.cons_tail_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.binary_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.map_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        // Walk the clause body for `local_set` indices (assignment
        // bindings allocated via HIR's per-clause `next_local`).
        const body_max = maxLocalSetIndexInBlock(clause.body);
        max_local = @max(max_local, body_max);
    }
    return max_local;
}

/// Recursively walks a HIR block, returning one past the largest
/// `local_set.index` reached anywhere inside the block (including
/// nested blocks, function-group bodies, branches, case arms, error
/// pipes, etc.). Returns `0` when the block contains no `local_set`.
fn maxLocalSetIndexInBlock(block: *const hir_mod.Block) LocalId {
    var max_local: LocalId = 0;
    for (block.stmts) |stmt| {
        switch (stmt) {
            .local_set => |ls| {
                max_local = @max(max_local, ls.index + 1);
                const value_max = maxLocalSetIndexInExpr(ls.value);
                max_local = @max(max_local, value_max);
            },
            .expr => |expr| {
                const expr_max = maxLocalSetIndexInExpr(expr);
                max_local = @max(max_local, expr_max);
            },
            .function_group => |group| {
                // Closures capture by reference; their bodies use a
                // fresh `next_local` counter, so they cannot collide
                // with the enclosing function's local space. Skip.
                _ = group;
            },
        }
    }
    return max_local;
}

/// Recursively walks a HIR expression for `local_set` indices that
/// appear inside its sub-blocks (case arms, branches, error pipes,
/// blocks-as-expressions, ...). Mirrors `maxLocalSetIndexInBlock`.
fn maxLocalSetIndexInExpr(expr: *const hir_mod.Expr) LocalId {
    var max_local: LocalId = 0;
    switch (expr.kind) {
        .branch => |*br| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(br.condition));
            max_local = @max(max_local, maxLocalSetIndexInBlock(br.then_block));
            if (br.else_block) |eb| max_local = @max(max_local, maxLocalSetIndexInBlock(eb));
        },
        .case => |*ce| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(ce.scrutinee));
            for (ce.arms) |arm| {
                max_local = @max(max_local, maxLocalSetIndexInBlock(arm.body));
                // Phase H.5: case-arm bindings allocate `local_index`
                // from the HIR builder's per-clause `next_local`
                // counter (see `collectCasePatternBindings`). The
                // IR-builder reservation in
                // `computeMaxBindingLocalForClauses` walks every
                // `tuple_bindings`/`list_bindings`/etc. on the clause
                // to keep its own `next_local` above any reserved
                // index, but it never visited the case arm's
                // `bindings` list — so a case-arm binding's
                // `local_index` could collide with a top-level
                // `local_set` (e.g. `opts = [...]` whose list_init
                // dest gets `next_local++`). The collision rebinds
                // an already-ARC-managed local mid-function, which
                // makes `local_ownership[binding] = .owned` and
                // causes the classifier to emit `copy_value` (with
                // a runtime retain) on top of a non-ARC value
                // (e.g. a String binding inside a keyword pattern).
                // Walk the arm's bindings here so the reservation is
                // sound across every case-arm pattern shape.
                for (arm.bindings) |binding| {
                    max_local = @max(max_local, binding.local_index + 1);
                }
            }
        },
        .block => |*blk| {
            max_local = @max(max_local, maxLocalSetIndexInBlock(blk));
        },
        .binary => |b| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(b.lhs));
            max_local = @max(max_local, maxLocalSetIndexInExpr(b.rhs));
        },
        .unary => |u| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(u.operand));
        },
        .call => |c| {
            for (c.args) |arg| {
                max_local = @max(max_local, maxLocalSetIndexInExpr(arg.expr));
            }
        },
        .union_init => |ui| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(ui.value));
        },
        .error_pipe => |ep| {
            for (ep.steps) |step| {
                max_local = @max(max_local, maxLocalSetIndexInExpr(step.expr));
            }
            max_local = @max(max_local, maxLocalSetIndexInExpr(ep.handler));
        },
        else => {},
    }
    return max_local;
}

/// Check if a HIR function group is generic (has unresolved type variables in params/return).
fn isGenericHirGroup(store: *const types_mod.TypeStore, group: *const hir_mod.FunctionGroup) bool {
    if (group.clauses.len == 0) return false;

    // Synthesized protocol dispatch functions (scope_id = 0) are NOT generic.
    // They merge clauses from different impl blocks for type-based dispatch.
    if (group.scope_id == 0 and group.clauses.len > 1) return false;

    const first_clause = &group.clauses[0];
    for (first_clause.params) |param| {
        // UNKNOWN (any) parameters are NOT generic — they compile to anytype in Zig
        if (param.type_id == types_mod.TypeStore.UNKNOWN) continue;
        if (containsUnresolvedTypeVarForSpecialization(store, param.type_id)) {
            // Check if the actual type is a type_var that was unified from UNKNOWN
            if (param.type_id < store.types.items.len) {
                const actual = store.types.items[param.type_id];
                if (actual == .unknown or actual == .type_var) continue; // Not truly generic
            }
            return true;
        }
    }
    const ret = first_clause.return_type;
    if (ret != types_mod.TypeStore.UNKNOWN and containsUnresolvedTypeVarForSpecialization(store, ret)) return true;
    return false;
}

/// Returns true iff `type_id` still carries an unresolved type
/// variable — meaning the type is *not yet specialize-ready* and
/// must not be lowered to a per-instantiation TypeDef or used as a
/// concrete ZIR type. Callers include:
///
///   - `populateAppliedSpecializations`: skips `.applied` forms whose
///     arguments are still abstract.
///   - `usableContextType` / `shouldPreferContextType`: refuses to
///     adopt a still-generic HIR type as the inferred Zig-side
///     context for a local.
///   - The call-target return-type unifier: only re-applies the
///     substitution when the declared return is still abstract.
///   - The inferred-signature genericity check: declines to emit a
///     specialization for a generated helper whose signature still
///     carries a type variable.
///
/// **Important:** as of Phase 1.2.5.b, `protocol_constraint` is
/// concrete — it lowers to `ZigType.protocol_box` (the runtime fat
/// pointer carrier). A function whose parameter or return type is a
/// protocol existential is *not* generic in the parametric sense
/// (every call site passes a `ProtocolBox`, not a type variable);
/// likewise an `Option(Error)` is a per-instantiation TypeDef whose
/// `Some` variant carries `zap_runtime.ProtocolBox`. We therefore
/// return `false` for `protocol_constraint` even when its inner
/// `type_params` still contain abstractions — the existential
/// boxing erases the inner shape from the runtime ABI.
fn containsUnresolvedTypeVarForSpecialization(store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= store.types.items.len) return false;
    const typ = store.types.items[type_id];
    return switch (typ) {
        .type_var => true,
        .list => |lt| containsUnresolvedTypeVarForSpecialization(store, lt.element),
        .tuple => |tt| {
            for (tt.elements) |elem| {
                if (containsUnresolvedTypeVarForSpecialization(store, elem)) return true;
            }
            return false;
        },
        .function => |ft| {
            for (ft.params) |param| {
                if (containsUnresolvedTypeVarForSpecialization(store, param)) return true;
            }
            return containsUnresolvedTypeVarForSpecialization(store, ft.return_type);
        },
        .map => |mt| containsUnresolvedTypeVarForSpecialization(store, mt.key) or
            containsUnresolvedTypeVarForSpecialization(store, mt.value),
        .applied => |at| {
            for (at.args) |arg| {
                if (containsUnresolvedTypeVarForSpecialization(store, arg)) return true;
            }
            return false;
        },
        .protocol_constraint => false,
        else => false,
    };
}

fn typeIdToZigType(type_id: types_mod.TypeId) ZigType {
    return typeIdToZigTypeWithStore(type_id, null);
}

fn typeIdToZigTypeWithStore(type_id: types_mod.TypeId, type_store: ?*const types_mod.TypeStore) ZigType {
    return switch (type_id) {
        types_mod.TypeStore.BOOL => .bool_type,
        types_mod.TypeStore.STRING => .string,
        types_mod.TypeStore.ATOM => .atom,
        types_mod.TypeStore.NIL => .nil,
        types_mod.TypeStore.NEVER => .never,
        types_mod.TypeStore.TERM => .term,
        types_mod.TypeStore.I128 => .i128,
        types_mod.TypeStore.I64 => .i64,
        types_mod.TypeStore.I32 => .i32,
        types_mod.TypeStore.I16 => .i16,
        types_mod.TypeStore.I8 => .i8,
        types_mod.TypeStore.U128 => .u128,
        types_mod.TypeStore.U64 => .u64,
        types_mod.TypeStore.U32 => .u32,
        types_mod.TypeStore.U16 => .u16,
        types_mod.TypeStore.U8 => .u8,
        types_mod.TypeStore.F128 => .f128,
        types_mod.TypeStore.F80 => .f80,
        types_mod.TypeStore.F64 => .f64,
        types_mod.TypeStore.F32 => .f32,
        types_mod.TypeStore.F16 => .f16,
        types_mod.TypeStore.USIZE => .usize,
        types_mod.TypeStore.ISIZE => .isize,
        else => {
            // Try to resolve user-defined struct/enum/union types
            if (type_store) |ts| {
                if (type_id < ts.types.items.len) {
                    const typ = ts.types.items[type_id];
                    switch (typ) {
                        .struct_type => |st| {
                            return .{ .struct_ref = ts.interner.get(st.name) };
                        },
                        .tagged_union => |tu| {
                            return .{ .struct_ref = ts.interner.get(tu.name) };
                        },
                        .opaque_type => |ot| {
                            return .{ .struct_ref = ts.interner.get(ot.name) };
                        },
                        .applied => {
                            // An `.applied { base, args }` parametric
                            // instantiation lowers to a `.struct_ref`
                            // whose name is the canonical mangled
                            // form (`Box_i64`, `Pair_i64_String`).
                            // The IR emits one per-instantiation
                            // TypeDef under this same name, so the
                            // ZIR backend's `@import("Box_i64")`
                            // resolves to the right struct/union
                            // type. Allocating the mangled name on
                            // the TypeStore allocator matches every
                            // other arm in this dispatcher (list /
                            // map / tuple all allocate on
                            // `ts.allocator`); the per-instantiation
                            // string is short-lived and bounded by
                            // the program's parametric instantiation
                            // count.
                            const mangled = types_mod.typeIdMangledName(ts.allocator, ts, type_id) catch
                                return .any;
                            return .{ .struct_ref = mangled };
                        },
                        .tuple => |tt| {
                            var zig_elems = ts.allocator.alloc(ZigType, tt.elements.len) catch return .any;
                            for (tt.elements, 0..) |elem, i| {
                                zig_elems[i] = typeIdToZigTypeWithStore(elem, type_store);
                            }
                            return .{ .tuple = zig_elems };
                        },
                        .list => |lt| {
                            const elem_zig = ts.allocator.create(ZigType) catch return .any;
                            elem_zig.* = typeIdToZigTypeWithStore(lt.element, type_store);
                            return .{ .list = elem_zig };
                        },
                        .map => |mt| {
                            const key_zig = ts.allocator.create(ZigType) catch return .any;
                            key_zig.* = typeIdToZigTypeWithStore(mt.key, type_store);
                            const val_zig = ts.allocator.create(ZigType) catch return .any;
                            val_zig.* = typeIdToZigTypeWithStore(mt.value, type_store);
                            return .{ .map = .{ .key = key_zig, .value = val_zig } };
                        },
                        .function => |ft| {
                            var zig_params = ts.allocator.alloc(ZigType, ft.params.len) catch return .any;
                            for (ft.params, 0..) |param, i| {
                                zig_params[i] = typeIdToZigTypeWithStore(param, type_store);
                            }
                            const ret_ptr = ts.allocator.create(ZigType) catch return .any;
                            ret_ptr.* = typeIdToZigTypeWithStore(ft.return_type, type_store);
                            return .{ .function = .{ .params = zig_params, .return_type = ret_ptr } };
                        },
                        .union_type => |ut| {
                            // T | nil → ?T (Zig optional)
                            if (ut.members.len == 2) {
                                var non_nil: ?types_mod.TypeId = null;
                                for (ut.members) |m| {
                                    if (m == types_mod.TypeStore.NIL) continue;
                                    non_nil = m;
                                }
                                if (non_nil) |inner| {
                                    const inner_zig = typeIdToZigTypeWithStore(inner, type_store);
                                    const inner_ptr = ts.allocator.create(ZigType) catch return .any;
                                    inner_ptr.* = inner_zig;
                                    return .{ .optional = inner_ptr };
                                }
                            }
                            // General union types → anytype
                            return .any;
                        },
                        .protocol_constraint => |pc| {
                            // Phase 1.2.5.b: lower a protocol existential
                            // to the runtime fat-pointer carrier. The
                            // payload is the protocol's bare name; the
                            // ZIR backend renders this as
                            // `zap_runtime.ProtocolBox` at every
                            // struct-field / union-variant / function-
                            // parameter / return-type position.
                            //
                            // The name is borrowed from the interner —
                            // same lifetime contract as the `struct_type`
                            // and `tagged_union` arms above. Interner
                            // strings outlive the IR build, so any
                            // downstream consumer that wants to retain
                            // the name (e.g. `cloneZigType`) is
                            // responsible for duplicating it.
                            return .{ .protocol_box = ts.interner.get(pc.protocol_name) };
                        },
                        else => {},
                    }
                }
            }
            return .any;
        },
    };
}

/// Walk a ZigType and return true if it transitively references a
/// nominal struct type matching `owner_name` via direct
/// `struct_ref` traversal alone — does NOT follow into other
/// structs' fields. Used as the inner step of the SCC-aware walker
/// below, and as the storage-decision criterion when no `TypeStore`
/// is attached (raw-IR unit tests).
///
/// Self-recursion only at this layer; for mutual recursion (`A → B
/// → A`) callers should use `zigTypeReachesStructInCycle`.
/// Peel `optional`/`ptr` wrappers and return the struct name when the
/// underlying nominal type is a struct. Used by `field_get` lowering
/// to look up the receiver's struct definition for indirect-storage
/// auto-deref.
fn zigTypeStructName(t: ZigType) ?[]const u8 {
    return switch (t) {
        .struct_ref => |name| name,
        .optional => |inner| zigTypeStructName(inner.*),
        .ptr => |inner| zigTypeStructName(inner.*),
        else => null,
    };
}

fn zigTypeReachesStruct(t: ZigType, owner_name: []const u8) bool {
    return switch (t) {
        .struct_ref => |name| std.mem.eql(u8, name, owner_name),
        .optional => |inner| zigTypeReachesStruct(inner.*, owner_name),
        .ptr => |pointee| zigTypeReachesStruct(pointee.*, owner_name),
        .list => |elem| zigTypeReachesStruct(elem.*, owner_name),
        .map => |mt| zigTypeReachesStruct(mt.key.*, owner_name) or
            zigTypeReachesStruct(mt.value.*, owner_name),
        .tuple => |elems| blk: {
            for (elems) |elem| {
                if (zigTypeReachesStruct(elem, owner_name)) break :blk true;
            }
            break :blk false;
        },
        .function => |ft| blk: {
            for (ft.params) |p| {
                if (zigTypeReachesStruct(p, owner_name)) break :blk true;
            }
            break :blk zigTypeReachesStruct(ft.return_type.*, owner_name);
        },
        // Primitives and tagged_union (a name reference, not a
        // structural type) cannot transitively reach a struct.
        // tagged_union variants currently lower as u32 enum tags
        // anyway; if/when payload variants land they'd need
        // separate recursion handling.
        //
        // `protocol_box` is a runtime fat pointer to an opaque
        // inner — it never reaches the *static* struct graph at
        // this layer (the inner type is dynamic). For SCC analysis
        // purposes, treat it as a leaf.
        .void,
        .bool_type,
        .nil,
        .never,
        .term,
        .any,
        .string,
        .atom,
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .f16,
        .f32,
        .f64,
        .f80,
        .f128,
        .usize,
        .isize,
        .tagged_union,
        .protocol_box,
        => false,
    };
}

/// SCC-aware variant of `zigTypeReachesStruct`. Returns true iff
/// `t` transitively references a struct that is in the same
/// strongly-connected component as `owner_name` over the struct
/// dependency graph. Catches both self-recursion (`A → A`, the
/// degenerate 1-element SCC) and mutual recursion (`A → B → A`,
/// where the cycle crosses one or more intermediate structs).
///
/// Without this, mutually-recursive struct families would lay out
/// inline by value and explode at type-check or codegen time
/// (Zig's "struct has infinite size" diagnostic, or worse, an LLVM
/// crash). The check uses an iterative DFS keyed on struct name with
/// a visited set, so the cost is bounded by the program's struct
/// graph regardless of how the user wraps fields in containers.
///
/// `interner_lookup` translates a `StringId` to a string; the caller
/// passes its own interner so this function stays free of any
/// `IrBuilder` state and remains usable from raw-IR unit tests once
/// they wire up a TypeStore.
fn zigTypeReachesStructInCycle(
    allocator: std.mem.Allocator,
    t: ZigType,
    owner_name: []const u8,
    type_store: *const types_mod.TypeStore,
    interner: *const ast.StringInterner,
) !bool {
    var visited = std.StringHashMapUnmanaged(void){};
    defer visited.deinit(allocator);
    return reachesStructInCycleImpl(allocator, t, owner_name, &visited, type_store, interner);
}

fn reachesStructInCycleImpl(
    allocator: std.mem.Allocator,
    t: ZigType,
    owner_name: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    type_store: *const types_mod.TypeStore,
    interner: *const ast.StringInterner,
) !bool {
    return switch (t) {
        .struct_ref => |name| blk: {
            if (std.mem.eql(u8, name, owner_name)) break :blk true;
            // Avoid revisiting structs already on the DFS stack —
            // bounds the walk to one pass over the struct graph.
            if (visited.contains(name)) break :blk false;
            try visited.put(allocator, name, {});
            // Walk the named struct's field types, looking for a
            // path back to `owner_name`. The TypeStore is the
            // authoritative source of struct field shapes; the
            // `IrBuilder.fields` representation is built only at IR
            // finalization and isn't available here.
            for (type_store.types.items) |typ| {
                if (typ != .struct_type) continue;
                const st = typ.struct_type;
                const sname = interner.get(st.name);
                if (!std.mem.eql(u8, sname, name)) continue;
                for (st.fields) |f| {
                    const f_zig_type = typeIdToZigTypeWithStore(f.type_id, type_store);
                    if (try reachesStructInCycleImpl(allocator, f_zig_type, owner_name, visited, type_store, interner))
                        break :blk true;
                }
                break;
            }
            break :blk false;
        },
        .optional => |inner| try reachesStructInCycleImpl(allocator, inner.*, owner_name, visited, type_store, interner),
        .ptr => |pointee| try reachesStructInCycleImpl(allocator, pointee.*, owner_name, visited, type_store, interner),
        .list => |elem| try reachesStructInCycleImpl(allocator, elem.*, owner_name, visited, type_store, interner),
        .map => |mt| (try reachesStructInCycleImpl(allocator, mt.key.*, owner_name, visited, type_store, interner)) or
            (try reachesStructInCycleImpl(allocator, mt.value.*, owner_name, visited, type_store, interner)),
        .tuple => |elems| blk: {
            for (elems) |elem| {
                if (try reachesStructInCycleImpl(allocator, elem, owner_name, visited, type_store, interner)) break :blk true;
            }
            break :blk false;
        },
        .function => |ft| blk: {
            for (ft.params) |p| {
                if (try reachesStructInCycleImpl(allocator, p, owner_name, visited, type_store, interner)) break :blk true;
            }
            break :blk try reachesStructInCycleImpl(allocator, ft.return_type.*, owner_name, visited, type_store, interner);
        },
        .void,
        .bool_type,
        .nil,
        .never,
        .term,
        .any,
        .string,
        .atom,
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .f16,
        .f32,
        .f64,
        .f80,
        .f128,
        .usize,
        .isize,
        .tagged_union,
        .protocol_box,
        => false,
    };
}

/// Convert a ZigType to its Zig source string representation.
/// Used by typeIdToZigTypeStrWithStore to avoid duplicating the TypeStore lookup.
fn zigTypeToStr(zig_type: ZigType) []const u8 {
    return switch (zig_type) {
        .void => "void",
        .bool_type => "bool",
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .i128 => "i128",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .u128 => "u128",
        .f16 => "f16",
        .f32 => "f32",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
        .usize => "usize",
        .isize => "isize",
        .string => "[]const u8",
        .atom => "[]const u8",
        .nil => "?void",
        .list => |element_type| switch (element_type.*) {
            .i64 => "?*const zap_runtime.List(i64)",
            .f64 => "?*const zap_runtime.List(f64)",
            else => "anytype",
        },
        .struct_ref => |name| name,
        .tagged_union => |name| name,
        .protocol_box => "zap_runtime.ProtocolBox",
        .function => "zap_runtime.DynClosure",
        .optional => "anytype",
        .any => "anytype",
        else => "anytype",
    };
}

/// Derives the string representation from the ZigType conversion,
/// eliminating duplicate TypeStore lookups.
fn typeIdToZigTypeStrWithStore(type_id: types_mod.TypeId, type_store: ?*const types_mod.TypeStore) []const u8 {
    const zig_type = typeIdToZigTypeWithStore(type_id, type_store);
    return zigTypeToStr(zig_type);
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const monomorphize_mod = @import("monomorphize.zig");

test "numeric list ZigType strings use runtime List target" {
    const i64_element_type: ZigType = .i64;
    const i64_list_type: ZigType = .{ .list = &i64_element_type };
    try std.testing.expectEqualStrings(
        "?*const zap_runtime.List(i64)",
        zigTypeToStr(i64_list_type),
    );

    const f64_element_type: ZigType = .f64;
    const f64_list_type: ZigType = .{ .list = &f64_element_type };
    try std.testing.expectEqualStrings(
        "?*const zap_runtime.List(f64)",
        zigTypeToStr(f64_list_type),
    );
}

test "list element type lookup does not default unknowns to i64" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var builder = IrBuilder.init(std.testing.allocator, &interner);
    defer builder.deinit();

    try std.testing.expect(builder.listElementTypeFromHirMaybe(types_mod.TypeStore.I64) == null);
    try std.testing.expect(builder.listElementTypeForLocal(42) == null);

    try builder.known_local_types.put(7, .i64);
    try std.testing.expect(builder.listElementTypeForLocal(7) == null);

    const element_type: ZigType = .f64;
    try builder.known_local_types.put(8, .{ .list = &element_type });
    try std.testing.expectEqual(ZigType.f64, builder.listElementTypeForLocal(8).?);
}

test "IR build simple function" {
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    try std.testing.expect(ir_program.functions[0].body.len > 0);
    try std.testing.expect(ir_program.functions[0].body[0].instructions.len > 0);
}

test "IR param_get indices are unique for multi-parameter functions" {
    const source =
        \\pub struct Test {
        \\  pub fn add(a, b) {
        \\    a + b
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    const func = ir_program.functions[0];
    try std.testing.expect(func.body.len > 0);

    // Collect all param_get instructions
    var param_gets: [2]u32 = .{ 0xFFFF, 0xFFFF };
    var pg_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .param_get => |pg| {
                if (pg_count < 2) {
                    param_gets[pg_count] = pg.index;
                }
                pg_count += 1;
            },
            else => {},
        }
    }

    // We should have exactly 2 param_get instructions
    try std.testing.expectEqual(@as(usize, 2), pg_count);
    // First param_get should have index 0, second should have index 1
    try std.testing.expectEqual(@as(u32, 0), param_gets[0]);
    try std.testing.expectEqual(@as(u32, 1), param_gets[1]);
}

test "IR call preserves HIR arg modes" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (String -> String), x :: String) {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const apply_clause = program.structs[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .unique;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var found_call = false;
    var found_move = false;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .move_value => found_move = true,
            .call_closure => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_move);
}

test "IR named call preserves move mode" {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const run_func = ir_program.functions[1];
    var found_call = false;
    var found_move = false;
    for (run_func.body[0].instructions) |instr| {
        switch (instr) {
            .move_value => found_move = true,
            .call_direct => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            .call_named => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_move);
}

test "IR closure call preserves borrow mode without ARC ops" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn apply(f :: (Handle -> Handle), x :: Handle) {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const apply_clause = program.structs[0].items[1].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .borrowed;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var found_call = false;
    var retain_count: usize = 0;
    var release_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .call_closure => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.borrow, call.arg_modes[0]);
                found_call = true;
            },
            .retain => retain_count += 1,
            .release => release_count += 1,
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expectEqual(@as(usize, 0), retain_count);
    try std.testing.expectEqual(@as(usize, 0), release_count);
}

test "IR shared opaque call emits retain and release" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(handle :: Handle) {
        \\    handle
        \\  }
        \\
        \\  pub fn run(use_fn :: (Handle -> Handle), handle :: Handle) {
        \\    use_fn(handle)
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const run_clause = program.structs[0].items[2].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(run_clause.meta.span)) orelse run_clause.meta.scope_id;
    const fn_binding = collector.graph.resolveBinding(clause_scope, run_clause.params[0].pattern.bind.name).?;
    const fn_type_id = collector.graph.bindings.items[fn_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[fn_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .shared;
    checker.store.types.items[fn_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const run_func = ir_program.functions[1];
    var share_count: usize = 0;
    var release_count: usize = 0;
    for (run_func.body[0].instructions) |instr| {
        switch (instr) {
            .share_value => share_count += 1,
            .release => release_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), share_count);
    try std.testing.expectEqual(@as(usize, 1), release_count);
}

test "isTcoSafeType: scalars are safe" {
    try std.testing.expect(IrBuilder.isTcoSafeType(.i64));
    try std.testing.expect(IrBuilder.isTcoSafeType(.f64));
    try std.testing.expect(IrBuilder.isTcoSafeType(.bool_type));
    try std.testing.expect(IrBuilder.isTcoSafeType(.atom));
    try std.testing.expect(IrBuilder.isTcoSafeType(.usize));
    try std.testing.expect(IrBuilder.isTcoSafeType(.never));
    try std.testing.expect(IrBuilder.isTcoSafeType(.void));
}

test "isTcoSafeType: byref aggregates are unsafe" {
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .struct_ref = "Body" }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.string));
    const elem: ZigType = .i64;
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .list = &elem }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .tuple = &.{} }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.term));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.any));
}

test "rewriteTailCalls marks byref recursion for loopification" {
    // A multi-clause recursive function whose parameter list contains
    // a struct still gets the `tail_call` rewrite — but the function's
    // `loopify` flag is set so the ZIR backend lowers to a loop +
    // stack-slot recurrence instead of LLVM `musttail` (which rejects
    // byref signatures under fastcc). Earlier passes silently kept the
    // recursion as `call_named + ret` for byref shapes, which compiled
    // cleanly but blew the stack at scale.
    const source =
        \\pub struct State {
        \\  a :: f64
        \\  b :: f64
        \\}
        \\
        \\pub struct LoopHost {
        \\  pub fn loop(s :: State, 0 :: i64) -> State {
        \\    s
        \\  }
        \\  pub fn loop(s :: State, n :: i64) -> State {
        \\    LoopHost.loop(s, n - 1)
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    var saw_loopify = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "LoopHost__loop")) continue;
        if (func.loopify) saw_loopify = true;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .tail_call) saw_tail_call = true;
                if (instr == .switch_return) {
                    for (instr.switch_return.cases) |case| {
                        for (case.body_instrs) |bi| if (bi == .tail_call) {
                            saw_tail_call = true;
                        };
                    }
                    for (instr.switch_return.default_instrs) |bi| if (bi == .tail_call) {
                        saw_tail_call = true;
                    };
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(saw_loopify);
}

test "rewriteTailCalls still rewrites primitive-only recursion" {
    // The companion to the byref test: a recursive function with
    // only scalar parameters and a scalar return must still get the
    // `tail_call` rewrite. This is the working primitive case the
    // existing TCO support targets, and the byref guard must not
    // accidentally disable it.
    const source =
        \\pub struct LoopHostScalar {
        \\  pub fn loop(0 :: i64, acc :: i64) -> i64 {
        \\    acc
        \\  }
        \\  pub fn loop(n :: i64, acc :: i64) -> i64 {
        \\    LoopHostScalar.loop(n - 1, acc + 1)
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "LoopHostScalar__loop")) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .tail_call) saw_tail_call = true;
                if (instr == .switch_return) {
                    for (instr.switch_return.cases) |case| {
                        for (case.body_instrs) |bi| if (bi == .tail_call) {
                            saw_tail_call = true;
                        };
                    }
                    for (instr.switch_return.default_instrs) |bi| if (bi == .tail_call) {
                        saw_tail_call = true;
                    };
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
}

test "rewriteTailCalls walks past intervening releases for ARC tail recursion" {
    // The k-nucleotide hot loop hits this shape: a self-recursive
    // tail-position call whose ARC-managed argument is shared via
    // `share_value` and gets a post-call `release{value=shared_dest}`
    // emitted by the call lowering. Without walking past the
    // trailing release the rewriter mistakes "is the immediately-
    // preceding instruction a call_named?" for "no" and leaves a
    // regular `call_named + ret`. At k-nucleotide-scale workloads
    // (~hundreds of thousands of recursive iterations) the missing
    // tail-call optimization blows the stack.
    //
    // This regression test pins the rewriter's behaviour: even when
    // a `.release` instruction sits between the recursive call and
    // the `ret`, the result must contain a `tail_call` (and the
    // per-arg release must be elided because the callee inherits
    // ownership through the tail jump).
    const source =
        \\pub struct Loop {
        \\  opaque Cell = String
        \\
        \\  pub fn step(c :: Cell) -> Cell {
        \\    Loop.step(c)
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    var saw_call_named_to_self = false;
    var saw_orphan_release = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "Loop__step")) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .tail_call => |tc| {
                        if (std.mem.startsWith(u8, tc.name, "Loop__step")) saw_tail_call = true;
                    },
                    .call_named => |cn| {
                        if (std.mem.startsWith(u8, cn.name, "Loop__step")) saw_call_named_to_self = true;
                    },
                    // After the rewrite, the per-arg release on the
                    // shared dest must be elided — the callee
                    // inherits ownership across the tail jump and the
                    // release would never fire (post-tail
                    // instructions are dead code) or, worse, fire
                    // before the tail jump and decrement the cell
                    // out from under the callee.
                    .release => saw_orphan_release = true,
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_call_named_to_self);
    try std.testing.expect(!saw_orphan_release);
}

test "rewriteTailCalls walks past borrow_value/copy_value/move_value/retain trailing instructions (Phase E.6)" {
    // Phase E.6 of the Phase 6 redux plan: between the recursive
    // `call_named` and the trailing `ret`, ARC infrastructure may
    // interleave any of:
    //
    //   * `.release` (post-call shared-arg cleanup, drop insertion)
    //   * `.retain` (refcount bump pairs)
    //   * `.borrow_value` / `.copy_value` (Phase C alias/copy)
    //   * `.move_value` (ownership transfer)
    //
    // The rewriter must walk past every one of these and recognise the
    // tail-position recursive call. This test hand-constructs an
    // instruction stream containing each kind of trailing instruction
    // and checks the rewrite produces a `.tail_call` with no surviving
    // `.call_named` to self.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    // Hand-built layout for `pub fn step(c) -> Cell { step(c) }` after
    // arg lowering, drop insertion, and Phase C ownership normalisation
    // have run:
    //
    //   %0 = call_named(name="step", args=[%10], dest=%20)
    //   borrow_value %30 <- %10        // Phase C alias (no runtime effect)
    //   copy_value   %31 <- %10        // Phase C copy (retain)
    //   move_value   %32 <- %20        // ownership transfer of call result
    //   retain       %31               // refcount bump
    //   release      %10               // shared-arg release (DROPPED on rewrite — %10 in args)
    //   release      %99               // non-arg release (PRESERVED before tail_call)
    //   ret          %20
    const args = try alloc.alloc(LocalId, 1);
    args[0] = 10;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 8);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[1] = .{ .borrow_value = .{ .dest = 30, .source = 10 } };
    instrs[2] = .{ .copy_value = .{ .dest = 31, .source = 10 } };
    instrs[3] = .{ .move_value = .{ .dest = 32, .source = 20 } };
    instrs[4] = .{ .retain = .{ .value = 31 } };
    instrs[5] = .{ .release = .{ .value = 10 } };
    instrs[6] = .{ .release = .{ .value = 99 } };
    instrs[7] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_borrow_value = false;
    var saw_copy_value = false;
    var saw_move_value = false;
    var saw_retain = false;
    var preserved_non_arg_release = false;
    var dropped_arg_release = true;
    var saw_call_named_to_self = false;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                if (std.mem.eql(u8, tc.name, "step")) saw_tail_call = true;
            },
            .call_named => |cn| {
                if (std.mem.eql(u8, cn.name, "step")) saw_call_named_to_self = true;
            },
            .borrow_value => saw_borrow_value = true,
            .copy_value => saw_copy_value = true,
            .move_value => saw_move_value = true,
            .retain => saw_retain = true,
            .release => |r| {
                if (r.value == 99) preserved_non_arg_release = true;
                if (r.value == 10) dropped_arg_release = false;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_call_named_to_self);
    try std.testing.expect(saw_borrow_value);
    try std.testing.expect(saw_copy_value);
    try std.testing.expect(saw_move_value);
    try std.testing.expect(saw_retain);
    try std.testing.expect(preserved_non_arg_release);
    try std.testing.expect(dropped_arg_release);
}

test "rewriteTailCalls bails out on non-tail-mappable trailing instruction (Phase E.6)" {
    // Phase E.6: when an instruction sitting between the recursive
    // call and the `ret` is NOT in the tail-mappable set (for example
    // a `.struct_init`), the rewriter must NOT silently fall back to
    // `.call_named + .ret` — that would hide the regression behind a
    // stack-blowing recursion at runtime. Instead, it leaves the call
    // unchanged so the verifier's V6 invariant fires at compile time.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 0);
    _ = args;
    const arg_modes = try alloc.alloc(ValueMode, 0);
    _ = arg_modes;

    const fields = try alloc.alloc(StructFieldInit, 1);
    fields[0] = .{ .name = "f", .value = 5 };

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = &.{}, .arg_modes = &.{} } };
    instrs[1] = .{ .struct_init = .{ .dest = 21, .type_name = "T", .fields = fields } };
    instrs[2] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 0);

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_call_named = false;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => saw_tail_call = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(!saw_tail_call);
    try std.testing.expect(saw_call_named);
}

test "rewriteTailCalls elides matched share_value/release pair and substitutes call arg (Phase E.8)" {
    // Phase E.8 of the Phase 6 redux plan — orphan-share fix.
    //
    // The tail-call rewriter drops a trailing `.release{value=X}` of a
    // call-arg slot because the callee inherits ownership through the
    // tail jump. Without a matching cleanup of the prelude, the
    // `.share_value{dest=X, source=Y}` that originally retained the
    // cell for the call argument becomes an "orphan share" — a +1
    // retain whose paired release no longer exists. At iteration
    // scale (millions of calls) the orphan retains accumulate and
    // produce the exact pool-leak signature observed in Phase F's
    // retry-3 (8.75M Map cells/run, refcount=2 at every step).
    //
    // The fix: when the rewriter drops a trailing `.release{value=X}`,
    // it must also drop the matching `.share_value{dest=X, source=Y}`
    // earlier in the body and substitute the call's arg `X` with `Y`.
    //
    // Hand-built layout:
    //   share_value  %30 <- %10            // retain for call arg
    //   call_named   step args=[%30] -> %20
    //   release      %30                   // post-call cleanup (DROPPED)
    //   ret          %20
    //
    // After rewrite:
    //   tail_call    step args=[%10]       // arg substituted to source
    //   (no share_value, no release, no call_named)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 1);
    args[0] = 30;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .share_value = .{ .dest = 30, .source = 10 } };
    instrs[1] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[2] = .{ .release = .{ .value = 30 } };
    instrs[3] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_share_value = false;
    var saw_release = false;
    var saw_call_named = false;
    var tail_call_arg: ?LocalId = null;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                saw_tail_call = true;
                if (tc.args.len > 0) tail_call_arg = tc.args[0];
            },
            .share_value => saw_share_value = true,
            .release => saw_release = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_share_value);
    try std.testing.expect(!saw_release);
    try std.testing.expect(!saw_call_named);
    // The tail_call's arg must be the original source local (10),
    // not the now-removed share dest (30).
    try std.testing.expectEqual(@as(?LocalId, 10), tail_call_arg);
}

test "rewriteTailCalls handles unmatched release without breaking (Phase E.8)" {
    // Phase E.8: the orphan-share fix must not regress the pre-existing
    // E.6 behaviour for releases that have no matching `share_value`
    // earlier in the body. This can happen e.g. when the source local
    // was passed in as a parameter that was bumped via `.retain`
    // rather than aliased through `.share_value`. The rewriter still
    // drops the release (it's an arg-cleanup release), but there is
    // no share to find — the call's arg stays as-is.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 1);
    args[0] = 10;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[1] = .{ .release = .{ .value = 10 } };
    instrs[2] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_release = false;
    var saw_call_named = false;
    var tail_call_arg: ?LocalId = null;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                saw_tail_call = true;
                if (tc.args.len > 0) tail_call_arg = tc.args[0];
            },
            .release => saw_release = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_release);
    try std.testing.expect(!saw_call_named);
    // Without a matching share, the arg stays as the original local.
    try std.testing.expectEqual(@as(?LocalId, 10), tail_call_arg);
}

test "IR local_get of ARC-managed source emits retain on dest" {
    // Phase 6 — Option B ownership protocol: every named binding of an
    // ARC-managed value owns an independent +1 refcount on the underlying
    // cell. The IR builder honors this by emitting a `.retain{value=dest}`
    // immediately after every `.local_get` whose source is ARC-managed,
    // making the alias a stand-alone ownership unit. This test pins the
    // invariant for `opaque_type` (the only currently-flagged ARC type).
    //
    // Source pattern:
    //   pub fn alias_use(h :: Handle) {
    //     aliased = h
    //     aliased
    //   }
    // - `h` is a parameter. `aliased = h` lowers to a local_set that records
    //   `h` (a param_get's dest) into the binding's local. The trailing
    //   `aliased` expression lowers to a `.local_get{dest=N, source=binding}`.
    // - With the Phase 6 retain rule, that local_get is followed by
    //   `.retain{value=N}` because Handle is ARC-managed (opaque_type).
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn alias_use(h :: Handle) {
        \\    aliased = h
        \\    aliased
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];

    // Walk the body and find every `.local_get`. For each, the *immediately
    // following* instruction must be a `.retain` whose `value` equals the
    // local_get's `dest`. There must be at least one such pair (the body's
    // tail expression `aliased`).
    var found_pair: bool = false;
    const instrs = func.body[0].instructions;
    for (instrs, 0..) |instr, idx| {
        if (instr != .local_get) continue;
        const lg = instr.local_get;
        try std.testing.expect(idx + 1 < instrs.len);
        const next = instrs[idx + 1];
        try std.testing.expect(next == .retain);
        try std.testing.expectEqual(lg.dest, next.retain.value);
        found_pair = true;
    }
    try std.testing.expect(found_pair);
}

test "IR local_get of non-ARC source does NOT emit retain" {
    // Counter-test: scalar locals (e.g. i64) must not generate an extra
    // retain after `.local_get`. Phase 6 retain emission is gated on
    // `IrBuilder.isArcManagedType(expr.type_id)`. This pins the gate.
    const source =
        \\pub struct Test {
        \\  pub fn alias_use(n :: i64) -> i64 {
        \\    aliased = n
        \\    aliased
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var retain_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .retain => retain_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), retain_count);
}

test "ShareValue defaults to retain mode" {
    // Phase 3: every existing IR construction site that does not
    // explicitly set `mode` must carry `.retain`, so default behavior
    // is preserved bit-for-bit until the ARC liveness pass starts
    // upgrading sites in phase 4. This test pins the default and
    // makes any accidental change to it (e.g. flipping the default
    // to `.consume`) surface as an immediate test failure.
    const default_share = ShareValue{ .dest = 1, .source = 2 };
    try std.testing.expectEqual(ShareMode.retain, default_share.mode);

    const explicit_consume = ShareValue{ .dest = 3, .source = 4, .mode = .consume };
    try std.testing.expectEqual(ShareMode.consume, explicit_consume.mode);
}

test "ShareMode enum has exactly retain and consume" {
    // Phase 3: the lowering switch in `zir_builder.zig` is exhaustive
    // over `ShareMode`. Anyone adding a new variant must update the
    // lowering and break the build at the switch site, but we also
    // pin the variant set here so a renaming or accidental addition
    // surfaces as a test diff rather than a silent semantic change.
    const fields = std.meta.fields(ShareMode);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("retain", fields[0].name);
    try std.testing.expectEqualStrings("consume", fields[1].name);
}

test "IR pattern-binding local_get of ARC-managed scrutinee emits retain" {
    // Phase 6 — Option B ownership protocol: the four pattern-binding
    // `.local_get` sites (case scrutinee bind, switch_literal default-arm
    // bind, decision-tree `.bind` node, guard scrutinee resolve) must
    // also emit `.retain{value=dest}` when the source is ARC-managed.
    // Before the unified `emitLocalGet` helper landed, the named-binding
    // `local_get` retained but pattern bindings did not, leaving case-
    // dispatch on ARC values with under-counted refcounts.
    //
    // The source pins the simplest pattern that exercises the
    // `lowerCaseExprBody` decision-tree path with a scrutinee bind:
    //   case h {
    //     bound -> bound
    //   }
    // After lowering, the bind's `.local_get{dest=bound, source=scr}`
    // must be immediately followed by `.retain{value=bound}`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn case_bind(h :: Handle) -> Handle {
        \\    case h {
        \\      bound -> bound
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];

    // Walk every instruction (including those nested inside structural
    // sub-streams like case_block.pre_instrs) and search for any
    // `.local_get` whose immediately following sibling is a `.retain`
    // matching the same dest. Since `case h { bound -> bound }` lowers
    // to a `case_block` containing a decision-tree leaf with a
    // scrutinee-bind followed by the body's `bound` reference, we
    // expect at least one such pair somewhere in the function.
    const Walker = struct {
        found_pair: bool = false,

        fn visit(ctx: *@This(), instr_stream: []const Instruction) void {
            for (instr_stream, 0..) |instr, idx| {
                if (instr == .local_get and idx + 1 < instr_stream.len) {
                    const lg = instr.local_get;
                    const next = instr_stream[idx + 1];
                    if (next == .retain and next.retain.value == lg.dest) {
                        ctx.found_pair = true;
                    }
                }
                switch (instr) {
                    .case_block => |cb| {
                        ctx.visit(cb.pre_instrs);
                        for (cb.arms) |arm| {
                            ctx.visit(arm.cond_instrs);
                            ctx.visit(arm.body_instrs);
                        }
                        ctx.visit(cb.default_instrs);
                    },
                    .if_expr => |ie| {
                        ctx.visit(ie.then_instrs);
                        ctx.visit(ie.else_instrs);
                    },
                    .guard_block => |gb| ctx.visit(gb.body),
                    .switch_literal => |sw| {
                        for (sw.cases) |c| ctx.visit(c.body_instrs);
                        ctx.visit(sw.default_instrs);
                    },
                    else => {},
                }
            }
        }
    };

    var walker = Walker{};
    for (func.body) |block| {
        walker.visit(block.instructions);
    }
    try std.testing.expect(walker.found_pair);
}

test "IR case expression records ARC-managed result ownership" {
    const source =
        \\pub struct Test {
        \\  pub fn choose(xs :: [i64]) -> [i64] {
        \\    case xs {
        \\      [] -> []
        \\      [head | tail] -> xs
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = blk: {
        for (ir_program.functions) |candidate| {
            if (std.mem.indexOf(u8, candidate.name, "choose") != null) break :blk candidate;
        }
        return error.MissingChooseFunction;
    };
    try std.testing.expectEqual(ResultConvention.owned, func.result_convention);

    const Finder = struct {
        case_dest: ?LocalId = null,

        fn visit(self: *@This(), stream: []const Instruction) void {
            for (stream) |instr| {
                switch (instr) {
                    .case_block => |cb| {
                        if (self.case_dest == null) self.case_dest = cb.dest;
                        self.visit(cb.pre_instrs);
                        for (cb.arms) |arm| {
                            self.visit(arm.cond_instrs);
                            self.visit(arm.body_instrs);
                        }
                        self.visit(cb.default_instrs);
                    },
                    .if_expr => |ie| {
                        self.visit(ie.then_instrs);
                        self.visit(ie.else_instrs);
                    },
                    .guard_block => |gb| self.visit(gb.body),
                    .switch_literal => |sw| {
                        for (sw.cases) |c| self.visit(c.body_instrs);
                        self.visit(sw.default_instrs);
                    },
                    else => {},
                }
            }
        }
    };

    var finder = Finder{};
    for (func.body) |block| {
        finder.visit(block.instructions);
    }

    const dest = finder.case_dest orelse return error.MissingCaseBlock;
    try std.testing.expect(dest < func.local_ownership.len);
    try std.testing.expectEqual(OwnershipClass.owned, func.local_ownership[dest]);
}

test "IR list cons pattern with multiple heads uses indexed gets and one suffix slice" {
    const source =
        \\pub struct Test {
        \\  pub fn score(xs :: [i64]) -> i64 {
        \\    case xs {
        \\      [a, b, c | rest] -> (a * 100) + (b * 10) + c + List.length(rest)
        \\      _ -> -1
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = blk: {
        for (ir_program.functions) |candidate| {
            if (std.mem.indexOf(u8, candidate.name, "score") != null) break :blk candidate;
        }
        return error.MissingScoreFunction;
    };

    const Finder = struct {
        min_len_checks: u32 = 0,
        indexed_heads: [3]bool = .{ false, false, false },
        suffix_slices: u32 = 0,
        unit_tails: u32 = 0,

        fn visit(self: *@This(), stream: []const Instruction) void {
            for (stream) |instr| {
                switch (instr) {
                    .list_len_check => |check| {
                        if (check.minimum and check.expected_len == 3) self.min_len_checks += 1;
                    },
                    .list_get => |get| {
                        if (get.index < self.indexed_heads.len) self.indexed_heads[get.index] = true;
                    },
                    .list_tail => |tail| {
                        if (tail.start_index == 3) self.suffix_slices += 1;
                        if (tail.start_index == 1) self.unit_tails += 1;
                    },
                    .case_block => |cb| {
                        self.visit(cb.pre_instrs);
                        for (cb.arms) |arm| {
                            self.visit(arm.cond_instrs);
                            self.visit(arm.body_instrs);
                        }
                        self.visit(cb.default_instrs);
                    },
                    .if_expr => |ie| {
                        self.visit(ie.then_instrs);
                        self.visit(ie.else_instrs);
                    },
                    .guard_block => |gb| self.visit(gb.body),
                    .switch_literal => |sw| {
                        for (sw.cases) |c| self.visit(c.body_instrs);
                        self.visit(sw.default_instrs);
                    },
                    else => {},
                }
            }
        }
    };

    var finder = Finder{};
    for (func.body) |block| {
        finder.visit(block.instructions);
    }

    try std.testing.expectEqual(@as(u32, 1), finder.min_len_checks);
    try std.testing.expect(finder.indexed_heads[0]);
    try std.testing.expect(finder.indexed_heads[1]);
    try std.testing.expect(finder.indexed_heads[2]);
    try std.testing.expectEqual(@as(u32, 1), finder.suffix_slices);
    try std.testing.expectEqual(@as(u32, 0), finder.unit_tails);
}

test "IR list assignment destructure with multiple heads uses indexed gets and one suffix slice" {
    const source =
        \\pub struct Test {
        \\  pub fn score(xs :: [i64]) -> i64 {
        \\    [a, b, c | rest] = xs
        \\    (a * 100) + (b * 10) + c + List.length(rest)
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = blk: {
        for (ir_program.functions) |candidate| {
            if (std.mem.indexOf(u8, candidate.name, "score") != null) break :blk candidate;
        }
        return error.MissingScoreFunction;
    };

    var indexed_heads = [_]bool{ false, false, false };
    var suffix_slices: u32 = 0;
    var unit_tails: u32 = 0;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .list_get => |get| {
                    if (get.index < indexed_heads.len) indexed_heads[get.index] = true;
                },
                .list_tail => |tail| {
                    if (tail.start_index == 3) suffix_slices += 1;
                    if (tail.start_index == 1) unit_tails += 1;
                },
                else => {},
            }
        }
    }

    try std.testing.expect(indexed_heads[0]);
    try std.testing.expect(indexed_heads[1]);
    try std.testing.expect(indexed_heads[2]);
    try std.testing.expectEqual(@as(u32, 1), suffix_slices);
    try std.testing.expectEqual(@as(u32, 0), unit_tails);
}

test "Instruction.share_value carries the mode field through union storage" {
    // Phase 3: confirm an Instruction value built with a `.consume`-
    // mode `ShareValue` round-trips through the tagged-union storage
    // without losing the mode. Catches any future flattening of
    // ShareValue that accidentally drops the new field.
    const instr: Instruction = .{
        .share_value = .{ .dest = 5, .source = 6, .mode = .consume },
    };
    try std.testing.expectEqual(ShareMode.consume, instr.share_value.mode);

    const default_instr: Instruction = .{
        .share_value = .{ .dest = 7, .source = 8 },
    };
    try std.testing.expectEqual(ShareMode.retain, default_instr.share_value.mode);
}

test "ownership metadata: ARC-managed identity function gets borrowed param + owned result" {
    // Phase A of the Phase 6 redux plan: a function whose single
    // parameter has an ARC-managed type must default to a `.borrowed`
    // calling convention, and a function that returns an ARC-managed
    // value must default to an `.owned` result convention. The
    // parameter local in `local_ownership` is also `.borrowed` —
    // matching the convention so drop insertion (Phase B onwards)
    // skips it correctly when scope-exit destroys are emitted.
    //
    // We use `opaque_type` (Handle) here because it's already
    // ARC-flagged and exercises the same `isArcManagedTypeId`
    // predicate Phase F will eventually flip on for `.map`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var found_id_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "Test__id") != null) {
            found_id_func = function;
            break;
        }
    }
    const id_func = found_id_func orelse return error.MissingFunction;

    // Per-parameter conventions match the params slice exactly.
    try std.testing.expectEqual(id_func.params.len, id_func.param_conventions.len);
    try std.testing.expectEqual(@as(usize, 1), id_func.params.len);
    try std.testing.expectEqual(ParamConvention.borrowed, id_func.param_conventions[0]);

    // ARC-managed return type defaults to .owned.
    try std.testing.expectEqual(ResultConvention.owned, id_func.result_convention);

    // local_ownership is sized to local_count; the param-bound local
    // (LocalId 0 by `param_get` allocation order) is ARC-managed, so
    // Phase A's stub classifier marks it `.owned`. Phase C will
    // refine this to `.borrowed` once the borrow/copy split lands.
    try std.testing.expectEqual(@as(usize, id_func.local_count), id_func.local_ownership.len);
    try std.testing.expect(id_func.local_count >= 1);
    // The first local emitted is the param_get for the single arg.
    try std.testing.expectEqual(OwnershipClass.owned, id_func.local_ownership[0]);
}

test "ownership metadata: non-ARC parameters classify as trivial" {
    // Phase A counter-test: scalar parameters (i64, Bool, ...) must
    // never receive a non-trivial calling convention. ARC discipline
    // does not fire on these locals: `param_conventions` reports
    // `.trivial`, the result convention is `.trivial`, and every
    // local in the function defaults to `.trivial` since none hold
    // an ARC-managed cell.
    const source =
        \\pub struct Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 { x + y }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const ast_program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&ast_program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&ast_program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&ast_program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var found_add_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "add") != null) {
            found_add_func = function;
            break;
        }
    }
    const add_func = found_add_func orelse return error.MissingFunction;

    try std.testing.expectEqual(@as(usize, 2), add_func.param_conventions.len);
    try std.testing.expectEqual(ParamConvention.trivial, add_func.param_conventions[0]);
    try std.testing.expectEqual(ParamConvention.trivial, add_func.param_conventions[1]);

    try std.testing.expectEqual(ResultConvention.trivial, add_func.result_convention);

    // No local in this function holds an ARC cell, so every entry in
    // local_ownership must be `.trivial`.
    try std.testing.expectEqual(@as(usize, add_func.local_count), add_func.local_ownership.len);
    for (add_func.local_ownership) |class| {
        try std.testing.expectEqual(OwnershipClass.trivial, class);
    }
}

test "ownership metadata: defaultParamConvention and defaultResultConvention agree on ARC predicate" {
    // The free-function helpers (`defaultParamConvention`,
    // `defaultResultConvention`) must agree with the IrBuilder's
    // type-resolution path so analysis passes outside the IrBuilder
    // (arc_ownership, arc_verifier in later phases) reach the same
    // conclusions about a given type. This is a property test on the
    // helpers themselves; it pins the contract that ARC-managed
    // types map to (.borrowed param, .owned result) and non-ARC
    // types map to (.trivial param, .trivial result).
    //
    // Because the helpers tolerate a null `type_store`, the unit
    // test asserts the null-fallback path too: callers without
    // type information default to `.trivial` so the analysis never
    // accidentally classifies an unknown local as ARC-managed.
    try std.testing.expectEqual(ParamConvention.trivial, defaultParamConvention(null, null));
    try std.testing.expectEqual(ResultConvention.trivial, defaultResultConvention(null, null));
    try std.testing.expectEqual(ParamConvention.trivial, defaultParamConvention(null, 0));
    try std.testing.expectEqual(ResultConvention.trivial, defaultResultConvention(null, 0));
}

test "ownership metadata: ARC predicate recognizes recursive boxed structs" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var store = types_mod.TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const node_name = try interner.intern("Node");
    const value_name = try interner.intern("value");
    const next_name = try interner.intern("next");

    const node_type_id = try store.addType(.{ .struct_type = .{
        .name = node_name,
        .fields = &.{},
    } });
    try store.name_to_type.put(node_name, node_type_id);

    const optional_members = try std.testing.allocator.alloc(types_mod.TypeId, 2);
    defer std.testing.allocator.free(optional_members);
    optional_members[0] = node_type_id;
    optional_members[1] = types_mod.TypeStore.NIL;
    const optional_node_type_id = try store.addType(.{ .union_type = .{
        .members = optional_members,
    } });

    const fields = try std.testing.allocator.alloc(types_mod.Type.StructField, 2);
    defer std.testing.allocator.free(fields);
    fields[0] = .{ .name = value_name, .type_id = types_mod.TypeStore.I64 };
    fields[1] = .{ .name = next_name, .type_id = optional_node_type_id };
    store.types.items[node_type_id] = .{ .struct_type = .{
        .name = node_name,
        .fields = fields,
    } };

    try std.testing.expect(isArcManagedTypeId(&store, node_type_id));
    try std.testing.expect(isArcManagedTypeId(&store, optional_node_type_id));
    try std.testing.expectEqual(ParamConvention.borrowed, defaultParamConvention(&store, node_type_id));
    try std.testing.expectEqual(ParamConvention.borrowed, defaultParamConvention(&store, optional_node_type_id));
    try std.testing.expectEqual(ResultConvention.owned, defaultResultConvention(&store, node_type_id));
    try std.testing.expectEqual(ResultConvention.owned, defaultResultConvention(&store, optional_node_type_id));
}

test "ownership metadata: synthetic optional recursive params use borrowed convention" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var store = types_mod.TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    const node_name = try interner.intern("LinkedNode");
    const value_name = try interner.intern("value");
    const next_name = try interner.intern("next");

    const node_type_id = try store.addType(.{ .struct_type = .{
        .name = node_name,
        .fields = &.{},
    } });
    try store.name_to_type.put(node_name, node_type_id);

    const optional_members = try std.testing.allocator.alloc(types_mod.TypeId, 2);
    defer std.testing.allocator.free(optional_members);
    optional_members[0] = node_type_id;
    optional_members[1] = types_mod.TypeStore.NIL;
    const optional_node_type_id = try store.addType(.{ .union_type = .{
        .members = optional_members,
    } });

    const fields = try std.testing.allocator.alloc(types_mod.Type.StructField, 2);
    defer std.testing.allocator.free(fields);
    fields[0] = .{ .name = value_name, .type_id = types_mod.TypeStore.I64 };
    fields[1] = .{ .name = next_name, .type_id = optional_node_type_id };
    store.types.items[node_type_id] = .{ .struct_type = .{
        .name = node_name,
        .fields = fields,
    } };

    var ir_builder = IrBuilder.init(std.testing.allocator, &interner);
    ir_builder.type_store = &store;
    defer ir_builder.deinit();

    const inner_type = try std.testing.allocator.create(ZigType);
    defer std.testing.allocator.destroy(inner_type);
    inner_type.* = .{ .struct_ref = "LinkedNode" };
    const optional_type = ZigType{ .optional = inner_type };

    const param_with_type_id = Param{
        .name = "__arg_0",
        .type_expr = optional_type,
        .type_id = optional_node_type_id,
    };
    const param_without_type_id = Param{
        .name = "__arg_0",
        .type_expr = optional_type,
        .type_id = null,
    };

    const conventions_with_type_id = try ir_builder.computeParamConventions(&.{param_with_type_id});
    defer std.testing.allocator.free(conventions_with_type_id);
    const conventions_without_type_id = try ir_builder.computeParamConventions(&.{param_without_type_id});
    defer std.testing.allocator.free(conventions_without_type_id);

    try std.testing.expectEqual(optional_node_type_id, findOptionalUnionTypeId(&store, node_type_id).?);
    try std.testing.expectEqual(ParamConvention.borrowed, conventions_with_type_id[0]);
    try std.testing.expectEqual(ParamConvention.borrowed, conventions_without_type_id[0]);
}

test "Phase E.5 Gap 1: share_value shared_local has ARC-managed local_ownership" {
    // When IrBuilder lowers a call argument with `.share` mode and an
    // ARC-managed expression type, it allocates a fresh `shared_local`
    // and emits `share_value{shared_local, source_local}`. The shared
    // local owns +1 from the share's retain and must be classified as
    // ARC-managed in `Function.local_ownership`. Without HIR-type
    // propagation onto `shared_local`, `local_ownership[shared_local]`
    // would default to `.trivial` and the verifier's V2 invariant
    // (release target's HIR type matches the local's ownership class)
    // would mismatch when the post-call `release{shared_local}` fires.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.use(h)
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var run_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "run") != null) {
            run_func = function;
            break;
        }
    }
    const func = run_func orelse return error.MissingFunction;

    // Find the share_value instruction in the function body.
    var found_share = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .share_value => |sv| {
                    found_share = true;
                    // The shared local must be classified as ARC-managed
                    // in local_ownership. Phase A's stub classifier
                    // labels every ARC-managed local as `.owned` until
                    // arc_ownership refines it; either `.owned` or
                    // `.borrowed` is acceptable here, but never
                    // `.trivial`.
                    try std.testing.expect(sv.dest < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[sv.dest] != .trivial);
                    // Likewise the source must be ARC-managed (the share
                    // only fires when the source's HIR type is ARC).
                    try std.testing.expect(sv.source < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[sv.source] != .trivial);
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_share);
}

test "Phase E.5 Gap 2: param_get HIR-expression dest gets ARC-managed local_ownership in single-clause function" {
    // A single-clause function `pub fn id(h :: Handle) -> Handle { h }`
    // lowers `h` to a HIR `param_get` expression. The IR's
    // `lowerExpr.param_get` arm allocates a fresh dest local and
    // emits `param_get{dest, index=0}`. The dest local must be
    // classified as ARC-managed in `local_ownership` because its
    // value originates from a borrowed-convention parameter of an
    // ARC-managed type. Without populating `local_hir_types[dest]`
    // from the function's declared param types,
    // `local_ownership[dest]` would default to `.trivial` and
    // arc_liveness would never include the dest in
    // `arc_managed_locals`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var id_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "id") != null) {
            id_func = function;
            break;
        }
    }
    const func = id_func orelse return error.MissingFunction;

    // Walk the body for every `param_get` instruction. Each dest
    // local must be classified as ARC-managed (non-trivial) since
    // the parameter's HIR type is the ARC-managed `Handle` opaque.
    var found_param_get = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .param_get => |pg| {
                    found_param_get = true;
                    try std.testing.expect(pg.dest < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[pg.dest] != .trivial);
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_param_get);
}

test "Phase E.5 Gap 3: assignment-binding indices reserved before IR-level next_local allocation" {
    // A function with `name = expr; ... name ...` allocates `name`'s
    // local index via HIR's per-clause `next_local` counter. That
    // counter is shared with pattern bindings, so the resulting
    // index can land in the IR builder's expression-lowering range
    // unless `computeMaxBindingLocalForClauses` accounts for body
    // `local_set.index` values. Concretely: the IR builder must
    // reserve enough locals up-front so no `lowerExpr` allocation
    // collides with an assignment binding's index.
    //
    // We exercise this by writing a function whose body assigns a
    // local then reads it. Every `local_set.dest` index must be at
    // least as large as `func.local_ownership.len` would be if the
    // pre-allocation were missing — equivalently: every local_set
    // dest must fall within `func.local_count`, and no IR-emitted
    // instruction before the local_set targets that same dest.
    const source =
        \\pub struct Test {
        \\  pub fn assign_then_read() -> i64 {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var assign_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "assign_then_read") != null) {
            assign_func = function;
            break;
        }
    }
    const func = assign_func orelse return error.MissingFunction;

    // Find every local_set; its dest index must be valid.
    var local_set_dest: ?LocalId = null;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .local_set => |ls| {
                    try std.testing.expect(ls.dest < func.local_count);
                    local_set_dest = ls.dest;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(local_set_dest != null);

    // The local_set's dest must NOT have been allocated as a fresh
    // dest by an earlier `lowerExpr` in the same function — i.e. it
    // must be in the reserved binding-local range. Walk the body
    // once and assert no instruction *before* the local_set defines
    // ls.dest as its own dest (that would indicate a collision).
    const dest = local_set_dest.?;
    var seen_local_set_for_dest = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .local_set and instr.local_set.dest == dest) {
                seen_local_set_for_dest = true;
                continue;
            }
            if (seen_local_set_for_dest) break;
            // Before the local_set: ensure no instruction's dest
            // equals our binding-local index.
            const conflicting_dest: ?LocalId = switch (instr) {
                .const_int => |x| x.dest,
                .const_float => |x| x.dest,
                .const_string => |x| x.dest,
                .const_bool => |x| x.dest,
                .const_atom => |x| x.dest,
                .binary_op => |x| x.dest,
                .unary_op => |x| x.dest,
                .call_named => |x| x.dest,
                .call_direct => |x| x.dest,
                .call_builtin => |x| x.dest,
                else => null,
            };
            if (conflicting_dest) |cd| {
                try std.testing.expect(cd != dest);
            }
        }
    }
}

test "Phase E.5 Gap 5: arc_managed_locals registers map_init / list_init / call dests of ARC type" {
    // `arc_liveness.identifyArcLocals` must register every local
    // whose value is ARC-managed by construction — not only those
    // that flow through `share_value` / `retain` / `release`. The
    // canonical anchor is `Function.local_ownership[L] != .trivial`
    // (populated by IrBuilder from `local_hir_types`). Without this
    // registration, scope-exit drops never fire on owned bindings
    // such as `m = map_init(...)`, leaking the cell on every
    // function exit.
    //
    // We use `opaque_type` (Handle) as our ARC-managed scalar. A
    // function that calls another ARC-returning function and binds
    // the result must register that binding local as ARC-managed
    // even though no `share_value` mentions it on the value side.
    //
    // This test pins the contract; the implementation lives in
    // `arc_liveness.identifyArcLocals`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make() -> Handle {
        \\    Test.fresh()
        \\  }
        \\
        \\  pub fn fresh() -> Handle {
        \\    "x"
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var make_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "make") != null) {
            make_func = function;
            break;
        }
    }
    const func = make_func orelse return error.MissingFunction;

    // Find the call instruction; its dest must be ARC-managed in
    // local_ownership (precondition for arc_liveness to register
    // it). This is a Phase A/B/C invariant the gap relies on.
    var call_dest: ?LocalId = null;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .call_named => |c| {
                    if (c.dest < func.local_ownership.len and
                        func.local_ownership[c.dest] != .trivial)
                    {
                        call_dest = c.dest;
                    }
                },
                .call_direct => |c| {
                    if (c.dest < func.local_ownership.len and
                        func.local_ownership[c.dest] != .trivial)
                    {
                        call_dest = c.dest;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(call_dest != null);

    // Now run arc_liveness and assert the call dest is in
    // arc_managed_locals.
    const arc_liveness = @import("arc_liveness.zig");
    var ownership = try arc_liveness.computeArcOwnership(
        std.testing.allocator,
        func,
        checker.store,
        arc_liveness.defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(ownership.arc_managed_locals.contains(call_dest.?));
}

test "tuple destructure of ARC-managed value emits retain on extracted local" {
    // Regression for the heap corruption bug surfaced by Phase 1.3:
    // when an ARC-managed value (e.g. an opaque type, a Map, or a
    // List) is extracted from a tuple via `tuple_index_get`,
    // the lowering must emit `.retain{value=dest}` immediately
    // after the `.index_get`. A tuple is non-ARC; its `index_get`
    // lowers to `elem_val_imm`, which never bumps the cell's
    // refcount. Without the retain, the Phase E.10 "aggregate-
    // store consumes" rule transfers the producer's +1 into the
    // tuple, but every destructure produces a fresh `.owned` alias
    // whose scope-exit `release` decrements a refcount that was
    // never incremented. With two destructures of the same tuple
    // (or of distinct tuples sharing the same ARC pointer) this
    // fired two scope-exit releases against a single +1 and
    // double-freed the cell.
    //
    // The fix is local to `IrBuilder.lowerExpr`'s `tuple_index_get`
    // branch and `IrBuilder.emitTupleBindings`, both of which now
    // call `emitArcRetainOnAggregateExtract` after the
    // `.index_get`. This pins the let-binding destructure path
    // (`{a, b} = some_tuple`) which lowers via
    // `lowerAssignmentDestructure` → `tuple_index_get` expression.
    //
    // Uses `opaque Handle = String` because an opaque type is the
    // canonical ARC-managed scalar that the type checker recognises
    // without `lib/*.zap` plumbing. The bug and the fix are agnostic
    // to which ARC-managed type appears in the tuple —
    // `isArcManagedType` returns true for `.opaque_type`, `.map`,
    // and `.list` alike.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  fn pair(h :: Handle) -> {Handle, Bool} { {h, false} }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    pp = Test.pair(h)
        \\    {x, _y} = pp
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    // Find `run` and confirm it contains an `.index_get` whose
    // dest is the immediately preceding instr's `.value` of a
    // following `.retain`.
    var run_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "run") != null) {
            run_func = function;
            break;
        }
    }
    const func = run_func orelse return error.MissingFunction;

    var saw_index_get_retain_pair = false;
    for (func.body) |block| {
        const stream = block.instructions;
        for (stream, 0..) |instr, idx| {
            if (instr != .index_get) continue;
            if (idx + 1 >= stream.len) continue;
            const next = stream[idx + 1];
            if (next == .retain and next.retain.value == instr.index_get.dest) {
                saw_index_get_retain_pair = true;
            }
        }
    }
    try std.testing.expect(saw_index_get_retain_pair);
}

test "struct field_get of ARC-managed value emits retain on extracted local" {
    // Companion regression for the same bug exposed via struct
    // destructure rather than tuple destructure. Plain (non-ARC)
    // structs lower `field_get` to `field_val`, which never bumps
    // the cell's refcount. Without a follow-up `.retain`, two
    // distinct struct parents that share the underlying ARC
    // pointer would each fire a scope-exit release against a
    // single +1 and double-free.
    //
    // Pins the let-binding destructure path (`field_get` HIR
    // expression in `lowerExpr`). Uses an opaque type rather than
    // a concrete native list so the unit-test pipeline does not need the
    // `@native_type` scope-graph plumbing — see the sibling tuple
    // regression test for the rationale.
    //
    // The field access `pair.a` must be an *intermediate* use (not
    // the function's return value). When `pair.a` is the return,
    // `arc_drop_insertion`'s retain-on-ret discipline produces the
    // matching retain at function exit instead. The pre-fix bug
    // surfaced in benchmarks specifically because every
    // intermediate field-extraction of an ARC-managed value
    // shared a single +1 with the parent struct; multiple such
    // extractions across distinct parents that aliased the same
    // ARC pointer fired multiple scope-exit releases against one
    // refcount. We pin the *intermediate* shape here by feeding
    // the extracted value into another function call before
    // returning the call's result.
    const source =
        \\pub struct HPair {
        \\  a :: Handle
        \\  b :: Handle
        \\}
        \\
        \\pub struct Driver {
        \\  opaque Handle = String
        \\
        \\  fn make(h :: Handle) -> HPair { %HPair{a: h, b: h} }
        \\  fn echo(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    pair = Driver.make(h)
        \\    Driver.echo(pair.a)
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var run_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "run") != null) {
            run_func = function;
            break;
        }
    }
    const func = run_func orelse return error.MissingFunction;

    var saw_field_get_retain_pair = false;
    for (func.body) |block| {
        const stream = block.instructions;
        for (stream, 0..) |instr, idx| {
            if (instr != .field_get) continue;
            if (idx + 1 >= stream.len) continue;
            const next = stream[idx + 1];
            if (next == .retain and next.retain.value == instr.field_get.dest) {
                saw_field_get_retain_pair = true;
            }
        }
    }
    try std.testing.expect(saw_field_get_retain_pair);
}

test "tuple param-binding destructure of ARC-managed value emits retain" {
    // Pin the parallel pattern-binding path: `emitTupleBindings`
    // emits `.param_get` + `.index_get` for each tuple binding on
    // a clause, and that `.index_get` must also receive a follow-
    // up `.retain` when its dest's HIR type is ARC-managed.
    //
    // Source: a clause that pattern-matches a `{Handle, Bool}`
    // tuple parameter. The first binding's `local_index` extracts
    // the handle — that extraction is the `index_get` whose dest
    // must be retained. The second binding extracts a Bool which
    // is non-ARC and must NOT receive a retain. Uses an opaque
    // type rather than a concrete native list for the same unit-test pipeline
    // reason as the sibling regression tests.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn first({v, _b} :: {Handle, Bool}) -> Handle {
        \\    v
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var first_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "first") != null) {
            first_func = function;
            break;
        }
    }
    const func = first_func orelse return error.MissingFunction;

    // Search every nested instruction stream for an `.index_get`
    // whose dest is followed by `.retain{value=dest}`. The first
    // tuple binding extracts the ARC-managed handle and must
    // emit the retain; the second binding extracts a Bool (non-
    // ARC) and must NOT.
    var saw_arc_pair = false;
    var saw_non_arc_with_retain = false;
    for (func.body) |block| {
        const stream = block.instructions;
        for (stream, 0..) |instr, idx| {
            if (instr != .index_get) continue;
            if (idx + 1 >= stream.len) continue;
            const next = stream[idx + 1];
            const has_retain = (next == .retain and next.retain.value == instr.index_get.dest);
            if (instr.index_get.index == 0 and has_retain) saw_arc_pair = true;
            if (instr.index_get.index == 1 and has_retain) saw_non_arc_with_retain = true;
        }
    }
    try std.testing.expect(saw_arc_pair);
    try std.testing.expect(!saw_non_arc_with_retain);
}

// ============================================================
// Per-instantiation parametric type emission (Phase 1.1.5.d)
// ============================================================

/// Build a `Program` from Zap source, running the full pipeline up to
/// IR (parse → collect → typecheck → HIR → monomorphize → IR). Used by
/// the per-instantiation parametric tests below so each one stays a
/// single readable block of assertions instead of repeating the
/// 25-line scaffold inline. Returns a `Program` whose memory lives in
/// `arena_allocator`.
fn buildIrProgramForParametricTest(
    arena_allocator: std.mem.Allocator,
    source: []const u8,
    interner_out: **ast.StringInterner,
) !Program {
    const parser_local: Parser = Parser.init(arena_allocator, source);
    // Move parser into a heap slot so its `interner` pointer stays
    // valid across the rest of the pipeline (every stage borrows it).
    const parser_box = try arena_allocator.create(Parser);
    parser_box.* = parser_local;
    const program = try parser_box.parseProgram();
    const program_box = try arena_allocator.create(ast.Program);
    program_box.* = program;

    var collector = Collector.init(arena_allocator, parser_box.interner, null);
    try collector.collectProgram(program_box);

    var checker = types_mod.TypeChecker.init(arena_allocator, parser_box.interner, &collector.graph);
    try checker.checkProgram(program_box);

    var hir_builder = hir_mod.HirBuilder.init(arena_allocator, parser_box.interner, &collector.graph, checker.store);
    const hir_program_value = try hir_builder.buildProgram(program_box);
    const hir_program_box = try arena_allocator.create(hir_mod.Program);
    hir_program_box.* = hir_program_value;

    var next_id: u32 = hir_builder.next_group_id;
    const mono_result = try monomorphize_mod.monomorphize(
        arena_allocator,
        hir_program_box,
        checker.store,
        &next_id,
        @constCast(parser_box.interner),
    );
    const post_mono = try arena_allocator.create(hir_mod.Program);
    post_mono.* = mono_result.program;

    var ir_builder = IrBuilder.init(arena_allocator, parser_box.interner);
    ir_builder.type_store = checker.store;
    interner_out.* = @constCast(parser_box.interner);
    return try ir_builder.buildProgram(post_mono);
}

/// Locate a `TypeDef` by name. Returns `null` when none of the
/// program's type defs carry the requested name — that's the
/// failure mode the per-instantiation tests assert against.
fn findTypeDefByName(program: Program, name: []const u8) ?TypeDef {
    for (program.type_defs) |type_def| {
        if (std.mem.eql(u8, type_def.name, name)) return type_def;
    }
    return null;
}

test "IR emits per-instantiation TypeDef for each parametric struct applied form" {
    // Two distinct .applied { Box, i64 } / { Box, String } TypeIds must
    // each produce a TypeDef with the canonical mangled name (Box_i64 /
    // Box_String) and the substituted field type. The parametric
    // template `Box` itself must NOT be emitted as a runtime TypeDef:
    // it has no layout (its `value :: T` field still carries a type
    // variable).
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

    var interner: *ast.StringInterner = undefined;
    const program = try buildIrProgramForParametricTest(alloc, source, &interner);

    // The parametric base must not appear as a runtime TypeDef.
    try std.testing.expect(findTypeDefByName(program, "Box") == null);

    // Each concrete instantiation must appear, with its substituted
    // field shape.
    const box_i64 = findTypeDefByName(program, "Box_i64") orelse
        return error.MissingBoxI64;
    try std.testing.expect(box_i64.kind == .struct_def);
    const box_i64_def = box_i64.kind.struct_def;
    try std.testing.expectEqual(@as(usize, 1), box_i64_def.fields.len);
    try std.testing.expectEqualStrings("value", box_i64_def.fields[0].name);
    try std.testing.expectEqual(ZigType.i64, box_i64_def.fields[0].type_expr);

    const box_string = findTypeDefByName(program, "Box_String") orelse
        return error.MissingBoxString;
    try std.testing.expect(box_string.kind == .struct_def);
    const box_string_def = box_string.kind.struct_def;
    try std.testing.expectEqual(@as(usize, 1), box_string_def.fields.len);
    try std.testing.expectEqualStrings("value", box_string_def.fields[0].name);
    try std.testing.expectEqual(ZigType.string, box_string_def.fields[0].type_expr);
}

test "IR struct_init for parametric literal names its per-instantiation type" {
    // The HIR `.struct_init` carries the canonical .applied TypeId.
    // The IR `lowerExpr` for struct_init resolves that TypeId through
    // `resolveTypeName`, which must produce the mangled per-
    // instantiation form (Box_i64) so the ZIR backend imports the
    // right struct type. Without per-instantiation routing every
    // instantiation would collapse onto the parametric base name
    // ("Box") and field offsets would mismatch.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn make_int() -> Box(i64) {
        \\    %Box(i64){value: 42}
        \\  }
        \\  pub fn make_str() -> Box(String) {
        \\    %Box(String){value: "hi"}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    const program = try buildIrProgramForParametricTest(alloc, source, &interner);

    var saw_int_init = false;
    var saw_str_init = false;
    for (program.functions) |func| {
        const is_int = std.mem.indexOf(u8, func.name, "make_int") != null;
        const is_str = std.mem.indexOf(u8, func.name, "make_str") != null;
        if (!is_int and !is_str) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr != .struct_init) continue;
                if (is_int) {
                    try std.testing.expectEqualStrings("Box_i64", instr.struct_init.type_name);
                    saw_int_init = true;
                } else {
                    try std.testing.expectEqualStrings("Box_String", instr.struct_init.type_name);
                    saw_str_init = true;
                }
            }
        }
    }
    try std.testing.expect(saw_int_init);
    try std.testing.expect(saw_str_init);
}

test "IR emits per-instantiation TypeDef for tagged-union applied forms" {
    // A parametric `union Maybe(t) { Some(t), None }` should produce a
    // distinct per-instantiation enum/union TypeDef for each concrete
    // arg: Maybe_i64 with a u32-or-i64 variant, Maybe_String with a
    // u32-or-String variant. The parametric template itself must not
    // appear as a runtime TypeDef.
    const source =
        \\pub union Maybe(t) {
        \\  Some :: t
        \\  None
        \\}
        \\pub struct Demo {
        \\  pub fn wrap_int(x :: i64) -> Maybe(i64) {
        \\    %Maybe(i64).Some(x)
        \\  }
        \\  pub fn wrap_str(s :: String) -> Maybe(String) {
        \\    %Maybe(String).Some(s)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    const program = try buildIrProgramForParametricTest(alloc, source, &interner);

    try std.testing.expect(findTypeDefByName(program, "Maybe") == null);
    const maybe_i64 = findTypeDefByName(program, "Maybe_i64") orelse
        return error.MissingMaybeI64;
    const maybe_string = findTypeDefByName(program, "Maybe_String") orelse
        return error.MissingMaybeString;
    // Concrete tagged unions with payload-bearing variants lower to
    // `union_def`; pure-unit ones lower to `enum_def`. `Maybe(t)` has
    // a `Some(t)` data variant, so both per-instantiation forms must
    // be union_def. The Some-variant payload type must match the
    // substituted arg.
    try std.testing.expect(maybe_i64.kind == .union_def);
    try std.testing.expect(maybe_string.kind == .union_def);
    var saw_i64_payload = false;
    var saw_string_payload = false;
    for (maybe_i64.kind.union_def.variants) |v| {
        if (std.mem.eql(u8, v.name, "Some")) {
            if (v.type_name) |tn| if (std.mem.eql(u8, tn, "i64")) {
                saw_i64_payload = true;
            };
        }
    }
    for (maybe_string.kind.union_def.variants) |v| {
        if (std.mem.eql(u8, v.name, "Some")) {
            // String values render as `[]const u8` per `ZigType.string`
            // through `typeIdToZigTypeStrWithStore` — the same rendering
            // used by every other String-typed slot in the IR.
            if (v.type_name) |tn| if (std.mem.eql(u8, tn, "[]const u8")) {
                saw_string_payload = true;
            };
        }
    }
    try std.testing.expect(saw_i64_payload);
    try std.testing.expect(saw_string_payload);
}

test "IR per-instantiation TypeDef substitutes nested field types" {
    // `Pair(a, b) { left :: a, right :: b }` instantiated as
    // `Pair(i64, String)` must produce a single Pair_i64_String TypeDef
    // whose two field types are i64 and String respectively — proves
    // the substitution map walks every field, not just the first.
    const source =
        \\pub struct Pair(a, b) {
        \\  left :: a
        \\  right :: b
        \\}
        \\pub struct Demo {
        \\  pub fn build() -> Pair(i64, String) {
        \\    %Pair(i64, String){left: 1, right: "x"}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    const program = try buildIrProgramForParametricTest(alloc, source, &interner);

    try std.testing.expect(findTypeDefByName(program, "Pair") == null);
    const pair = findTypeDefByName(program, "Pair_i64_String") orelse
        return error.MissingPairI64String;
    try std.testing.expect(pair.kind == .struct_def);
    const fields = pair.kind.struct_def.fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    // Field ordering follows declaration order — left first, right second.
    try std.testing.expectEqualStrings("left", fields[0].name);
    try std.testing.expectEqual(ZigType.i64, fields[0].type_expr);
    try std.testing.expectEqualStrings("right", fields[1].name);
    try std.testing.expectEqual(ZigType.string, fields[1].type_expr);
}

test "IR field_get on parametric receiver carries per-instantiation struct_type" {
    // After `b :: Box(i64)` flows through `b.value`, the IR's
    // `field_get` instruction must record `struct_type =
    // \"Box_i64\"` — not the parametric base name `Box`. The ZIR
    // backend imports the per-instantiation ZIR file by this name,
    // and field offsets / ARC ownership decisions all key off it.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn read_int() -> i64 {
        \\    b = %Box(i64){value: 7}
        \\    b.value
        \\  }
        \\  pub fn read_str() -> String {
        \\    b = %Box(String){value: "hi"}
        \\    b.value
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    const program = try buildIrProgramForParametricTest(alloc, source, &interner);

    var saw_int_fg = false;
    var saw_str_fg = false;
    for (program.functions) |func| {
        const is_int = std.mem.indexOf(u8, func.name, "read_int") != null;
        const is_str = std.mem.indexOf(u8, func.name, "read_str") != null;
        if (!is_int and !is_str) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr != .field_get) continue;
                const struct_type = instr.field_get.struct_type orelse continue;
                if (is_int and std.mem.eql(u8, struct_type, "Box_i64")) saw_int_fg = true;
                if (is_str and std.mem.eql(u8, struct_type, "Box_String")) saw_str_fg = true;
            }
        }
    }
    try std.testing.expect(saw_int_fg);
    try std.testing.expect(saw_str_fg);
}

test "IR builder's applied specialization table indexes by name and TypeId" {
    // White-box: confirm `populateAppliedSpecializations` registered
    // every `.applied` form under both the mangled-name index and
    // the canonical TypeId index, and that the substituted field
    // ZigTypes match expectation. Two distinct instantiations of
    // the same parametric struct must NOT alias.
    const source =
        \\pub struct Box(t) {
        \\  value :: t
        \\}
        \\pub struct Demo {
        \\  pub fn a() -> Box(i64) {
        \\    %Box(i64){value: 1}
        \\  }
        \\  pub fn b() -> Box(String) {
        \\    %Box(String){value: "x"}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parser_local: Parser = Parser.init(alloc, source);
    const parser_box = try alloc.create(Parser);
    parser_box.* = parser_local;
    const parsed = try parser_box.parseProgram();
    const program_ast = try alloc.create(ast.Program);
    program_ast.* = parsed;

    var collector = Collector.init(alloc, parser_box.interner, null);
    try collector.collectProgram(program_ast);

    var checker = types_mod.TypeChecker.init(alloc, parser_box.interner, &collector.graph);
    try checker.checkProgram(program_ast);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser_box.interner, &collector.graph, checker.store);
    const hir_program_value = try hir_builder.buildProgram(program_ast);
    const hir_program_box = try alloc.create(hir_mod.Program);
    hir_program_box.* = hir_program_value;

    var next_id: u32 = hir_builder.next_group_id;
    const mono_result = try monomorphize_mod.monomorphize(
        alloc,
        hir_program_box,
        checker.store,
        &next_id,
        @constCast(parser_box.interner),
    );
    const post_mono = try alloc.create(hir_mod.Program);
    post_mono.* = mono_result.program;

    var ir_builder = IrBuilder.init(alloc, parser_box.interner);
    ir_builder.type_store = checker.store;
    _ = try ir_builder.buildProgram(post_mono);

    // Both per-instantiation mangled names are indexed.
    const box_i64_spec = ir_builder.appliedSpecializationByMangledName("Box_i64") orelse
        return error.MissingBoxI64Spec;
    const box_str_spec = ir_builder.appliedSpecializationByMangledName("Box_String") orelse
        return error.MissingBoxStringSpec;

    // The two specializations carry distinct applied TypeIds and
    // distinct substituted field shapes.
    try std.testing.expect(box_i64_spec.applied_type_id != box_str_spec.applied_type_id);
    try std.testing.expectEqual(@as(usize, 1), box_i64_spec.substituted_field_zig_types.len);
    try std.testing.expectEqual(@as(usize, 1), box_str_spec.substituted_field_zig_types.len);
    try std.testing.expectEqual(ZigType.i64, box_i64_spec.substituted_field_zig_types[0]);
    try std.testing.expectEqual(ZigType.string, box_str_spec.substituted_field_zig_types[0]);

    // The HIR-side substituted field TypeIds match the canonical
    // primitive TypeIds — this is what `lookupStructFieldHirTypeByName`
    // returns to the IR's ARC-management classifier.
    try std.testing.expectEqual(types_mod.TypeStore.I64, box_i64_spec.substituted_field_hir_types[0]);
    try std.testing.expectEqual(types_mod.TypeStore.STRING, box_str_spec.substituted_field_hir_types[0]);

    // The TypeId index agrees with the name index for both.
    const i64_by_id = ir_builder.appliedSpecializationByTypeId(box_i64_spec.applied_type_id) orelse
        return error.MissingBoxI64ById;
    try std.testing.expectEqualStrings(box_i64_spec.mangled_name, i64_by_id.mangled_name);
}

// ============================================================
// Phase 1.2.5.a: per-protocol vtable + per-impl vtable instance
// emission tests
// ============================================================

/// Test-only variant of `buildIrProgramForParametricTest` that
/// also wires the scope graph onto the IR builder. The
/// protocol/impl population in `populateProtocolVTables` reads
/// `graph.protocols` / `graph.impls` through this channel; the
/// parametric tests above skip it because they exercise only the
/// type-store-driven `populateAppliedSpecializations` path.
fn buildIrProgramForProtocolTest(
    arena_allocator: std.mem.Allocator,
    source: []const u8,
    interner_out: **ast.StringInterner,
    graph_out: **const scope_mod.ScopeGraph,
) !Program {
    const parser_local: Parser = Parser.init(arena_allocator, source);
    const parser_box = try arena_allocator.create(Parser);
    parser_box.* = parser_local;
    const program = try parser_box.parseProgram();
    const program_box = try arena_allocator.create(ast.Program);
    program_box.* = program;

    const collector_box = try arena_allocator.create(Collector);
    collector_box.* = Collector.init(arena_allocator, parser_box.interner, null);
    try collector_box.collectProgram(program_box);

    var checker = types_mod.TypeChecker.init(arena_allocator, parser_box.interner, &collector_box.graph);
    try checker.checkProgram(program_box);

    var hir_builder = hir_mod.HirBuilder.init(arena_allocator, parser_box.interner, &collector_box.graph, checker.store);
    const hir_program_value = try hir_builder.buildProgram(program_box);
    const hir_program_box = try arena_allocator.create(hir_mod.Program);
    hir_program_box.* = hir_program_value;

    var next_id: u32 = hir_builder.next_group_id;
    const mono_result = try monomorphize_mod.monomorphize(
        arena_allocator,
        hir_program_box,
        checker.store,
        &next_id,
        @constCast(parser_box.interner),
    );
    const post_mono = try arena_allocator.create(hir_mod.Program);
    post_mono.* = mono_result.program;

    var ir_builder = IrBuilder.init(arena_allocator, parser_box.interner);
    ir_builder.type_store = checker.store;
    ir_builder.scope_graph = &collector_box.graph;
    interner_out.* = @constCast(parser_box.interner);
    graph_out.* = &collector_box.graph;
    return try ir_builder.buildProgram(post_mono);
}

test "IR emits protocol_vtable_def for every reachable pub protocol" {
    // A `pub protocol Foo { fn m(x) -> i64 }` reachable from the
    // program must produce a `protocol_vtable_def` TypeDef whose
    // name is `FooVTable` and whose method-slot list mirrors the
    // protocol's method signatures (in declaration order). The
    // ZIR backend's step 3.7 lowers this TypeDef into a synthetic
    // `pub const FooVTable = extern struct { m: *const fn(...)... }`
    // source file at codegen time.
    //
    // Two protocols are declared so we can verify each lands as a
    // separate vtable type with the right number of slots.
    const source =
        \\pub protocol Greeting {
        \\  fn hello(g) -> String
        \\}
        \\pub protocol Counter {
        \\  fn current(c) -> i64
        \\  fn step(c, n :: i64) -> i64
        \\}
        \\pub struct UseSite {
        \\  pub fn dummy() -> i64 { 0 }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    // Greeting vtable: one method (`hello`) returning String.
    const greeting_vt = findTypeDefByName(program, "GreetingVTable") orelse
        return error.MissingGreetingVTable;
    try std.testing.expect(greeting_vt.kind == .protocol_vtable_def);
    const greeting_def = greeting_vt.kind.protocol_vtable_def;
    try std.testing.expectEqualStrings("Greeting", greeting_def.protocol_name);
    try std.testing.expectEqual(@as(usize, 1), greeting_def.methods.len);
    try std.testing.expectEqualStrings("hello", greeting_def.methods[0].name);
    try std.testing.expectEqual(@as(u32, 1), greeting_def.methods[0].arity);
    try std.testing.expectEqual(@as(usize, 0), greeting_def.methods[0].extra_param_types.len);
    try std.testing.expectEqual(ZigType.string, greeting_def.methods[0].return_type);

    // Counter vtable: two methods, the second with an extra param.
    const counter_vt = findTypeDefByName(program, "CounterVTable") orelse
        return error.MissingCounterVTable;
    try std.testing.expect(counter_vt.kind == .protocol_vtable_def);
    const counter_def = counter_vt.kind.protocol_vtable_def;
    try std.testing.expectEqualStrings("Counter", counter_def.protocol_name);
    try std.testing.expectEqual(@as(usize, 2), counter_def.methods.len);
    try std.testing.expectEqualStrings("current", counter_def.methods[0].name);
    try std.testing.expectEqual(@as(u32, 1), counter_def.methods[0].arity);
    try std.testing.expectEqual(@as(usize, 0), counter_def.methods[0].extra_param_types.len);
    try std.testing.expectEqual(ZigType.i64, counter_def.methods[0].return_type);
    try std.testing.expectEqualStrings("step", counter_def.methods[1].name);
    try std.testing.expectEqual(@as(u32, 2), counter_def.methods[1].arity);
    try std.testing.expectEqual(@as(usize, 1), counter_def.methods[1].extra_param_types.len);
    try std.testing.expectEqual(ZigType.i64, counter_def.methods[1].extra_param_types[0]);
    try std.testing.expectEqual(ZigType.i64, counter_def.methods[1].return_type);
}

test "IR emits protocol_vtable_instance_def for every reachable pub impl" {
    // For every concrete `pub impl Foo for Bar`, IR must emit a
    // `protocol_vtable_instance_def` named `FooVTable_for_Bar`
    // whose method-pointer entries name the impl's monomorphized
    // function symbols. The construction-site lowering (Phase
    // 1.2.5.c) reads these constants to populate the
    // `ProtocolBox.vtable` field at boxing sites.
    //
    // The Greeting protocol with a single concrete impl is the
    // minimal exercise: the IR must surface both the vtable type
    // and the vtable constant.
    const source =
        \\pub protocol Greeting {
        \\  fn hello(g) -> String
        \\}
        \\pub struct Friendly {
        \\  message :: String = "hi"
        \\}
        \\pub impl Greeting for Friendly {
        \\  pub fn hello(g :: Friendly) -> String {
        \\    g.message
        \\  }
        \\}
        \\pub struct UseSite {
        \\  pub fn dummy() -> i64 { 0 }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    // Vtable type must exist.
    const greeting_vt = findTypeDefByName(program, "GreetingVTable") orelse
        return error.MissingGreetingVTable;
    try std.testing.expect(greeting_vt.kind == .protocol_vtable_def);

    // Per-impl vtable constant must exist with the right shape.
    const instance = findTypeDefByName(program, "GreetingVTable_for_Friendly") orelse
        return error.MissingGreetingVTableForFriendly;
    try std.testing.expect(instance.kind == .protocol_vtable_instance_def);
    const inst_def = instance.kind.protocol_vtable_instance_def;
    try std.testing.expectEqualStrings("Greeting", inst_def.protocol_name);
    try std.testing.expectEqualStrings("Friendly", inst_def.target_type_name);
    try std.testing.expectEqual(@as(usize, 1), inst_def.methods.len);

    // The slot's `method_name` matches the protocol's, and the
    // `impl_function_name` follows the `<TargetStruct>__<method>__<arity>`
    // convention every call site uses for the same impl method.
    const slot = inst_def.methods[0];
    try std.testing.expectEqualStrings("hello", slot.method_name);
    try std.testing.expectEqualStrings("Friendly__hello__1", slot.impl_function_name);
    try std.testing.expectEqual(@as(u32, 1), slot.arity);
    try std.testing.expectEqual(@as(usize, 0), slot.extra_param_types.len);
    try std.testing.expectEqual(ZigType.string, slot.return_type);
}

test "IR vtable emission survives Program.clone (deep-copy correctness)" {
    // The cache-correctness path serializes Program through
    // `cloneProgram` so a downstream consumer that holds the
    // clone observes the same vtable shapes. `cloneTypeDef` must
    // round-trip both new variants.
    const source =
        \\pub protocol Counter {
        \\  fn current(c) -> i64
        \\}
        \\pub struct Tick {
        \\  value :: i64 = 0
        \\}
        \\pub impl Counter for Tick {
        \\  pub fn current(c :: Tick) -> i64 { c.value }
        \\}
        \\pub struct UseSite { pub fn dummy() -> i64 { 0 } }
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const original = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);
    const cloned = try cloneProgram(alloc, original);

    const counter_vt = findTypeDefByName(cloned, "CounterVTable") orelse
        return error.MissingCounterVTable;
    try std.testing.expect(counter_vt.kind == .protocol_vtable_def);
    const counter_def = counter_vt.kind.protocol_vtable_def;
    try std.testing.expectEqualStrings("Counter", counter_def.protocol_name);
    try std.testing.expectEqual(@as(usize, 1), counter_def.methods.len);
    try std.testing.expectEqualStrings("current", counter_def.methods[0].name);
    try std.testing.expectEqual(ZigType.i64, counter_def.methods[0].return_type);

    const instance = findTypeDefByName(cloned, "CounterVTable_for_Tick") orelse
        return error.MissingCounterVTableForTick;
    try std.testing.expect(instance.kind == .protocol_vtable_instance_def);
    const inst_def = instance.kind.protocol_vtable_instance_def;
    try std.testing.expectEqualStrings("Counter", inst_def.protocol_name);
    try std.testing.expectEqualStrings("Tick", inst_def.target_type_name);
    try std.testing.expectEqual(@as(usize, 1), inst_def.methods.len);
    try std.testing.expectEqualStrings("current", inst_def.methods[0].method_name);
    try std.testing.expectEqualStrings("Tick__current__1", inst_def.methods[0].impl_function_name);
}

// ============================================================
// Phase 1.2.5.b: TypeStore + IR plumbing for protocol_constraint
// — `ZigType.protocol_box` representation, mangler routing,
// applied-specialization filter promotion, parametric vtable
// enumeration, and `astTypeExprToZigTypeForProtocol`'s protocol-
// existential lowering.
// ============================================================

test "typeIdMangledName lowers protocol_constraint to its protocol bare name" {
    // The mangler joins per-instantiation argument names with `_`, so
    // `Option(Error)` must mangle to `Option_Error`. Until 1.2.5.b
    // the `.protocol_constraint` arm fell through to the `T` default,
    // which produced the wrong joined form `Option_T` and collapsed
    // every protocol-existential instantiation onto a single name.
    var interner_local = ast.StringInterner.init(std.testing.allocator);
    defer interner_local.deinit();
    var store = types_mod.TypeStore.init(std.testing.allocator, &interner_local);
    defer store.deinit();

    const error_name_id = try interner_local.intern("Error");
    const pc_id = try store.addType(.{
        .protocol_constraint = .{
            .protocol_name = error_name_id,
            .type_params = &.{},
        },
    });

    const mangled = try types_mod.typeIdMangledName(std.testing.allocator, &store, pc_id);
    defer std.testing.allocator.free(mangled);
    try std.testing.expectEqualStrings("Error", mangled);
}

test "typeIdToZigTypeWithStore lowers protocol_constraint to ZigType.protocol_box" {
    // The Phase 1.2.5.b plumbing replaces the `.any` fallback with a
    // first-class `.protocol_box` carrier so per-instantiation
    // structs holding protocol-existential fields (e.g.
    // `Option(Error)`) lower to a concrete struct shape (with a
    // `zap_runtime.ProtocolBox` payload) rather than `anytype`.
    var interner_local = ast.StringInterner.init(std.testing.allocator);
    defer interner_local.deinit();
    var store = types_mod.TypeStore.init(std.testing.allocator, &interner_local);
    defer store.deinit();

    const error_name_id = try interner_local.intern("Error");
    const pc_id = try store.addType(.{
        .protocol_constraint = .{
            .protocol_name = error_name_id,
            .type_params = &.{},
        },
    });

    const zig_type = typeIdToZigTypeWithStore(pc_id, &store);
    try std.testing.expect(zig_type == .protocol_box);
    try std.testing.expectEqualStrings("Error", zig_type.protocol_box);
}

test "zigTypeToStr renders ZigType.protocol_box as zap_runtime.ProtocolBox" {
    // Variant payload-string emission for parametric tagged unions
    // (e.g. `Option(Error).Some(:: protocol_box(Error))`) routes
    // through `zigTypeToStr`. The protocol-box payload must land as
    // the runtime fat-pointer type — anything else would either
    // mis-shape the generated `union(enum)` or collapse to
    // `anytype`, both of which would defeat the existential
    // boxing's whole purpose.
    const pb: ZigType = .{ .protocol_box = "Error" };
    try std.testing.expectEqualStrings("zap_runtime.ProtocolBox", zigTypeToStr(pb));
}

test "IR emits per-instantiation TypeDef for Option(Error)-shaped applied form" {
    // The acid test: an applied form whose argument is a
    // `protocol_constraint` (the Phase 1.2 `Error` protocol) must
    // produce a per-instantiation `union_def` TypeDef named
    // `Option_Error` whose `Some` variant carries the runtime
    // ProtocolBox payload. Before 1.2.5.b the filter in
    // `populateAppliedSpecializations` treated protocol_constraint as
    // unresolved-type-var and skipped the entire instantiation, so
    // no `Option_Error` TypeDef was emitted and any field of that
    // type fell back to `anytype` at the ZIR layer.
    //
    // The Zap program declares a custom protocol + impl + a struct
    // field of type `Option(Foo)`. The IR must surface `Option_Foo`
    // as a `union_def` whose `Some` variant lowers to
    // `zap_runtime.ProtocolBox`.
    const source =
        \\pub union Option(t) {
        \\  Some :: t
        \\  None
        \\}
        \\pub protocol Foo {
        \\  fn ping(f) -> i64
        \\}
        \\pub struct Bar {
        \\  value :: i64 = 0
        \\}
        \\pub impl Foo for Bar {
        \\  pub fn ping(f :: Bar) -> i64 { f.value }
        \\}
        \\pub struct UseSite {
        \\  pub fn make_none() -> Option(Foo) { %Option(Foo).None }
        \\  pub fn dummy() -> i64 { 0 }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    // The parametric template `Option` must not appear as a runtime
    // TypeDef — only the per-instantiation `Option_Foo` form should.
    const option_foo = findTypeDefByName(program, "Option_Foo") orelse
        return error.MissingOptionFoo;
    // Option(t) is a parametric tagged union with one payload variant
    // (`Some :: t`) and one unit variant (`None`), so its per-
    // instantiation form lowers to `union_def`.
    try std.testing.expect(option_foo.kind == .union_def);
    const option_foo_def = option_foo.kind.union_def;
    try std.testing.expectEqual(@as(usize, 2), option_foo_def.variants.len);

    // Find the Some variant (variant order is the union declaration
    // order, but we look up by name to be order-independent).
    var some_index: ?usize = null;
    for (option_foo_def.variants, 0..) |variant, idx| {
        if (std.mem.eql(u8, variant.name, "Some")) some_index = idx;
    }
    const some_idx = some_index orelse return error.MissingSomeVariant;
    const some_type_name = option_foo_def.variants[some_idx].type_name orelse
        return error.MissingSomePayloadType;
    try std.testing.expectEqualStrings("zap_runtime.ProtocolBox", some_type_name);
}

test "IR emits per-instantiation vtables for parametric impls" {
    // The 1.2.5.a populator skipped any impl with type params. 1.2.5.b
    // lifts the guard via the `applied_specializations` enumeration:
    // a parametric impl `impl Foo for Bar(t)` instantiated against
    // `Bar(i64)` must emit one `FooVTable_for_Bar_i64` constant per
    // applied instantiation.
    //
    // The Zap source declares a concrete protocol with a parametric
    // impl against `Tag(t)` and a use site that instantiates
    // `Tag(i64)`. The IR's `applied_specializations` table picks up
    // the `Tag_i64` mangled name (driven by 1.2.5.b's
    // `populateAppliedSpecializations` filter, which is now correct
    // for protocol_constraint-bearing applied forms). The
    // parametric-impl populator walks every applied specialization
    // whose base is the impl's target nominal and emits one vtable
    // instance per instantiation.
    const source =
        \\pub protocol Mark {
        \\  fn label(m) -> String
        \\}
        \\pub struct Tag(t) {
        \\  value :: t
        \\}
        \\pub impl Mark for Tag(t) {
        \\  pub fn label(m :: Tag(t)) -> String { "tag" }
        \\}
        \\pub struct UseSite {
        \\  pub fn use_int() -> String {
        \\    Mark.label(%Tag(i64){value: 1})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    // The protocol's vtable type must exist (a concrete protocol's
    // vtable is unchanged from 1.2.5.a).
    const mark_vt = findTypeDefByName(program, "MarkVTable") orelse
        return error.MissingMarkVTable;
    try std.testing.expect(mark_vt.kind == .protocol_vtable_def);

    // The parametric impl must surface as a vtable instance per
    // applied target instantiation, named after the mangled
    // per-instantiation target.
    const instance = findTypeDefByName(program, "MarkVTable_for_Tag_i64") orelse
        return error.MissingMarkVTableForTagI64;
    try std.testing.expect(instance.kind == .protocol_vtable_instance_def);
    const inst_def = instance.kind.protocol_vtable_instance_def;
    try std.testing.expectEqualStrings("Mark", inst_def.protocol_name);
    try std.testing.expectEqualStrings("Tag_i64", inst_def.target_type_name);
    try std.testing.expectEqual(@as(usize, 1), inst_def.methods.len);
    // The impl-method-pointer naming for a parametric target uses the
    // monomorphized-impl-asymmetry symbol layout from 1.1.5.c — the
    // calling-mod is the impl's owning struct (auto-generated by
    // 1.1.5's parametric impl lowering), target-mod is the mangled
    // target, and the elem-type encodes the substituted argument.
    // For the simpler concrete-naming used by the vtable populator
    // we encode the slot as `<Target_Mangled>__<method>__<arity>`.
    try std.testing.expectEqualStrings(
        "Tag_i64__label__1",
        inst_def.methods[0].impl_function_name,
    );
}

test "ZigType.protocol_box round-trips through cloneZigType / cloneProgram" {
    // The cache-correctness layer serializes Program through
    // `cloneProgram` so downstream consumers observe deep-copy
    // semantics. The new `.protocol_box` carrier must clone its
    // owned `[]const u8` name like every other byte-slice-bearing
    // variant. Without this clone the cloned Program would share
    // the original's name pointer and a later free of either side
    // would invalidate the other.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: ZigType = .{ .protocol_box = "Error" };
    const cloned = try cloneZigType(alloc, source);
    try std.testing.expect(cloned == .protocol_box);
    try std.testing.expectEqualStrings("Error", cloned.protocol_box);
    // Distinct backing storage — the clone must not share the
    // original's pointer.
    try std.testing.expect(source.protocol_box.ptr != cloned.protocol_box.ptr);
}

// ============================================================
// Phase 1.2.5.c: construction-site auto-boxing tests
// ============================================================

test "box_as_protocol instruction round-trips through cloneInstruction" {
    // The new construction-site IR op must clone its owned byte-slice
    // payloads (`protocol_name`, `target_type_name`) and its
    // `value_zig_type` independently of the source. Without this the
    // cache-correctness diff (which round-trips Programs through
    // `cloneProgram`) would alias the original's storage and a later
    // free of either side would invalidate the other.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: Instruction = .{ .box_as_protocol = .{
        .dest = 7,
        .value = 3,
        .protocol_name = "Error",
        .target_type_name = "MyError",
        .value_zig_type = .{ .struct_ref = "MyError" },
    } };

    const cloned = try cloneInstruction(alloc, source);
    try std.testing.expect(cloned == .box_as_protocol);
    const inst = cloned.box_as_protocol;
    try std.testing.expectEqual(@as(LocalId, 7), inst.dest);
    try std.testing.expectEqual(@as(LocalId, 3), inst.value);
    try std.testing.expectEqualStrings("Error", inst.protocol_name);
    try std.testing.expectEqualStrings("MyError", inst.target_type_name);
    try std.testing.expect(inst.value_zig_type == .struct_ref);
    try std.testing.expectEqualStrings("MyError", inst.value_zig_type.struct_ref);
    // Independent backing storage — the clone must not share the
    // source's pointers.
    try std.testing.expect(source.box_as_protocol.protocol_name.ptr !=
        inst.protocol_name.ptr);
    try std.testing.expect(source.box_as_protocol.target_type_name.ptr !=
        inst.target_type_name.ptr);
}

test "protocol_dispatch instruction round-trips through cloneInstruction" {
    // Phase 1.2.5.d consumption-site dispatch IR op. Mirrors the
    // `box_as_protocol` clone contract: byte-slice payloads
    // (`protocol_name`, `method_name`), the per-arg slices (`args`,
    // `arg_modes`), and the captured `return_type` ZigType must each
    // be cloned with independent storage so the cache-correctness
    // round-trip (which calls `cloneProgram` and frees the source's
    // arena) cannot dangle pointers in the cloned program.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try alloc.dupe(LocalId, &[_]LocalId{42});
    const modes = try alloc.dupe(ValueMode, &[_]ValueMode{.share});

    const source: Instruction = .{ .protocol_dispatch = .{
        .dest = 9,
        .receiver = 5,
        .protocol_name = "Error",
        .method_name = "message",
        .method_index = 0,
        .arity = 1,
        .args = args,
        .arg_modes = modes,
        .return_type = .string,
    } };

    const cloned = try cloneInstruction(alloc, source);
    try std.testing.expect(cloned == .protocol_dispatch);
    const pd = cloned.protocol_dispatch;
    try std.testing.expectEqual(@as(LocalId, 9), pd.dest);
    try std.testing.expectEqual(@as(LocalId, 5), pd.receiver);
    try std.testing.expectEqualStrings("Error", pd.protocol_name);
    try std.testing.expectEqualStrings("message", pd.method_name);
    try std.testing.expectEqual(@as(u32, 0), pd.method_index);
    try std.testing.expectEqual(@as(u32, 1), pd.arity);
    try std.testing.expectEqual(@as(usize, 1), pd.args.len);
    try std.testing.expectEqual(@as(LocalId, 42), pd.args[0]);
    try std.testing.expectEqual(@as(usize, 1), pd.arg_modes.len);
    try std.testing.expect(pd.return_type == .string);

    // Independent backing storage.
    try std.testing.expect(source.protocol_dispatch.protocol_name.ptr != pd.protocol_name.ptr);
    try std.testing.expect(source.protocol_dispatch.method_name.ptr != pd.method_name.ptr);
}

test "protocol_box_unbox instruction round-trips through cloneInstruction" {
    // Phase 1.2.5.d downcast IR op. Same clone-independence contract
    // as `protocol_dispatch`: every owned byte-slice payload must
    // get its own backing storage.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source: Instruction = .{ .protocol_box_unbox = .{
        .dest = 11,
        .box = 3,
        .protocol_name = "Error",
        .target_type_name = "MyError",
        .target_zig_type = .{ .struct_ref = "MyError" },
    } };

    const cloned = try cloneInstruction(alloc, source);
    try std.testing.expect(cloned == .protocol_box_unbox);
    const bu = cloned.protocol_box_unbox;
    try std.testing.expectEqual(@as(LocalId, 11), bu.dest);
    try std.testing.expectEqual(@as(LocalId, 3), bu.box);
    try std.testing.expectEqualStrings("Error", bu.protocol_name);
    try std.testing.expectEqualStrings("MyError", bu.target_type_name);
    try std.testing.expect(bu.target_zig_type == .struct_ref);
    try std.testing.expectEqualStrings("MyError", bu.target_zig_type.struct_ref);

    // Independent backing storage.
    try std.testing.expect(source.protocol_box_unbox.protocol_name.ptr != bu.protocol_name.ptr);
    try std.testing.expect(source.protocol_box_unbox.target_type_name.ptr != bu.target_type_name.ptr);
}

test "findProtocolImplVTable resolves concrete (protocol, target) pair" {
    // The construction-site lowering needs to take the address of the
    // per-impl vtable instance constant. `findProtocolImplVTable`
    // bridges from the box's source-level `(protocol_name,
    // target_type_name)` pair to the synthesized constant's TypeDef
    // name — the symbol the ZIR backend imports and address-takes.
    //
    // A concrete `pub impl Error for MyError { ... }` registers a
    // `protocol_vtable_instance_def` named `ErrorVTable_for_MyError`
    // with `protocol_name = "Error"` and `target_type_name = "MyError"`.
    // The lookup must return that exact name.
    const source =
        \\pub protocol Logger {
        \\  fn log(l) -> String
        \\}
        \\pub struct Console {
        \\  prefix :: String = ">"
        \\}
        \\pub impl Logger for Console {
        \\  pub fn log(l :: Console) -> String { l.prefix }
        \\}
        \\pub struct UseSite {
        \\  pub fn run() -> String {
        \\    Logger.log(%Console{prefix: "->"})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    const vt_name = findProtocolImplVTable(&program, "Logger", "Console") orelse
        return error.MissingLoggerForConsole;
    try std.testing.expectEqualStrings("LoggerVTable_for_Console", vt_name);

    // The unmatched pair must return null — the construction site
    // depends on this null result to surface a rich diagnostic
    // ("type X does not implement protocol Y").
    try std.testing.expect(findProtocolImplVTable(&program, "Logger", "Missing") == null);
    try std.testing.expect(findProtocolImplVTable(&program, "Missing", "Console") == null);
}

test "IR emits protocol_dispatch when method call's receiver is a protocol_box" {
    // Phase 1.2.5.d HIR/IR routing contract: when the user writes
    // `Logger.log(e)` and `e` is statically typed as the protocol
    // existential (`l :: Logger` in the function signature), the
    // IR builder must emit a `.protocol_dispatch` instruction
    // rather than the usual `.call_named` to a non-existent
    // `Logger__log__1` function. The dispatch carries the
    // protocol/method name pair and the method-index slot the
    // ZIR backend uses to dereference the box's vtable.
    const source =
        \\pub protocol Logger {
        \\  fn log(l) -> String
        \\}
        \\pub struct Console {
        \\  prefix :: String = ">"
        \\}
        \\pub impl Logger for Console {
        \\  pub fn log(l :: Console) -> String { l.prefix }
        \\}
        \\pub struct UseSite {
        \\  pub fn use_box(l :: Logger) -> String {
        \\    Logger.log(l)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    var saw_protocol_dispatch = false;
    for (program.functions) |func| {
        if (!std.mem.eql(u8, func.name, "UseSite__use_box__1")) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .protocol_dispatch) {
                    const pd = instr.protocol_dispatch;
                    try std.testing.expectEqualStrings("Logger", pd.protocol_name);
                    try std.testing.expectEqualStrings("log", pd.method_name);
                    try std.testing.expectEqual(@as(u32, 0), pd.method_index);
                    try std.testing.expectEqual(@as(u32, 1), pd.arity);
                    saw_protocol_dispatch = true;
                    break;
                }
            }
            if (saw_protocol_dispatch) break;
        }
    }
    try std.testing.expect(saw_protocol_dispatch);
}

test "findProtocolImplVTable resolves parametric specialization" {
    // A parametric impl `impl Logger for Tagged(t)` instantiated at
    // `Tagged(i64)` produces an instance `LoggerVTable_for_Tagged_i64`.
    // The lookup must accept the mangled per-instantiation target
    // name — that's the form the construction-site lowering produces
    // when boxing a `Tagged_i64` value.
    const source =
        \\pub protocol Logger {
        \\  fn log(l) -> String
        \\}
        \\pub struct Tagged(t) {
        \\  value :: t
        \\}
        \\pub impl Logger for Tagged(t) {
        \\  pub fn log(l :: Tagged(t)) -> String { "tagged" }
        \\}
        \\pub struct UseSite {
        \\  pub fn run() -> String {
        \\    Logger.log(%Tagged(i64){value: 1})
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner: *ast.StringInterner = undefined;
    var graph: *const scope_mod.ScopeGraph = undefined;
    const program = try buildIrProgramForProtocolTest(alloc, source, &interner, &graph);

    const vt_name = findProtocolImplVTable(&program, "Logger", "Tagged_i64") orelse
        return error.MissingLoggerForTaggedI64;
    try std.testing.expectEqualStrings("LoggerVTable_for_Tagged_i64", vt_name);
}
