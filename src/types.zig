const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");
const similarity = @import("similarity.zig");

// ============================================================
// Type representation
// ============================================================

pub const TypeId = u32;
pub const TypeVarId = u32;

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

    // Enum
    enum_type: EnumType,

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
    };

    pub const AppliedType = struct {
        base: TypeId,
        args: []const TypeId,
    };

    pub const EnumType = struct {
        name: ast.StringId,
        variants: []const ast.StringId,
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

        // Everything is a supertype of Never
        _ = super_t;

        // Union subtyping: sub is a subtype if it's a member of the union
        if (self.getType(super) == .union_type) {
            const ut = self.getType(super).union_type;
            for (ut.members) |member| {
                if (self.isSubtype(sub, member)) return true;
            }
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
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.store.deinit();
        self.errors.deinit(self.allocator);
        self.expr_types.deinit();
        self.referenced_bindings.deinit();
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
                .enum_type => |et| return self.interner.get(et.name),
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
                            "move this function into a `defmodule`",
                            "all functions except `main` must be defined inside a `defmodule ... do ... end` block",
                        );
                    }
                },
                .priv_function => |func| {
                    const name = self.interner.get(func.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level private function `{s}` is not allowed — functions must be inside a module", .{name}),
                        func.meta.span,
                        "move this function into a `defmodule`",
                        "all functions must be defined inside a `defmodule ... do ... end` block",
                    );
                },
                .macro => |mac| {
                    const name = self.interner.get(mac.name);
                    try self.addHardError(
                        try std.fmt.allocPrint(self.allocator, "top-level macro `{s}` is not allowed — macros must be inside a module", .{name}),
                        mac.meta.span,
                        "move this macro into a `defmodule`",
                        "all macros must be defined inside a `defmodule ... do ... end` block",
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
                .enum_type => |ed| {
                    // Check if the name conflicts with a builtin type
                    const enum_name_str = self.interner.get(ed.name);
                    if (self.store.resolveTypeName(enum_name_str) != null) {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "`{s}` shadows a builtin type — choose a different name", .{enum_name_str}),
                            .span = ed.meta.span,
                            .label = "conflicts with builtin type",
                            .help = try std.fmt.allocPrint(self.allocator, "the builtin `{s}` type takes priority over this definition", .{enum_name_str}),
                            .severity = .warning,
                        });
                        continue; // builtin wins
                    }
                    var variant_names: std.ArrayList(ast.StringId) = .empty;
                    for (ed.variants) |v| {
                        try variant_names.append(self.allocator, v.name);
                    }
                    const type_id = try self.store.addType(.{ .enum_type = .{
                        .name = ed.name,
                        .variants = try variant_names.toOwnedSlice(self.allocator),
                    } });
                    try self.store.name_to_type.put(ed.name, type_id);
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
                .function => |func| try self.checkFunctionDecl(func),
                .priv_function => |func| try self.checkFunctionDecl(func),
                .macro => |mac| {
                    // Mark macro params as referenced — they're used in quote/unquote,
                    // not via normal var_ref, so the unused-binding check can't see them.
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
                    try self.checkFunctionDecl(mac);
                },
                else => {},
            }
        }
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
            .macro => |mac| try self.checkFunctionDecl(mac),
            .module => {},
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
                // Store type on the binding in scope graph if this is a bind pattern
                if (param.pattern.* == .bind) {
                    const bind_name = param.pattern.bind.name;
                    if (self.current_scope) |scope_id| {
                        if (self.graph.resolveBinding(scope_id, bind_name)) |bid| {
                            self.graph.bindings.items[bid].type_id = .{
                                .type_id = param_type,
                                .source_span = ta.getMeta().span,
                            };
                        }
                    }
                }
            }
        }

        // Resolve return type
        const declared_return = if (clause.return_type) |rt|
            try self.resolveTypeExpr(rt)
        else
            TypeStore.UNKNOWN;

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

        // Check body
        var body_type: TypeId = TypeStore.NIL;
        for (clause.body) |stmt| {
            body_type = try self.checkStmt(stmt);
        }

        // Verify return type matches (suppress if either side is ERROR/UNKNOWN/type_var from cascading)
        const declared_is_checkable = declared_return != TypeStore.UNKNOWN and
            declared_return != TypeStore.ERROR and
            self.store.getType(declared_return) != .type_var;
        if (declared_is_checkable and body_type != TypeStore.UNKNOWN and body_type != TypeStore.ERROR)
        {
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
                const value_type = try self.inferExpr(assign.value);
                // Store type on the target binding if it's a bind pattern
                if (assign.pattern.* == .bind) {
                    const bind_name = assign.pattern.bind.name;
                    if (self.current_scope) |scope_id| {
                        if (self.graph.resolveBinding(scope_id, bind_name)) |bid| {
                            self.graph.bindings.items[bid].type_id = .{
                                .type_id = value_type,
                                .source_span = assign.value.getMeta().span,
                            };
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
                }
                return TypeStore.UNKNOWN;
            },

            .binary_op => |bo| self.inferBinaryOp(&bo),
            .unary_op => |uo| self.inferUnaryOp(&uo),
            .call => |call| self.inferCall(&call),

            .tuple => |t| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (t.elements) |elem| {
                    try elem_types.append(self.allocator, try self.inferExpr(elem));
                }
                return try self.store.addType(.{
                    .tuple = .{ .elements = try elem_types.toOwnedSlice(self.allocator) },
                });
            },

            .list => |l| {
                if (l.elements.len == 0) return TypeStore.UNKNOWN;
                const elem_type = try self.inferExpr(l.elements[0]);
                return try self.store.addType(.{
                    .list = .{ .element = elem_type },
                });
            },

            // if_expr, with_expr, cond_expr, pipe are desugared to case_expr
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
                    if (scrutinee_t == .enum_type) {
                        const et = scrutinee_t.enum_type;
                        // Collect matched variants from case patterns
                        var matched_count: usize = 0;
                        for (et.variants) |variant| {
                            var variant_matched = false;
                            for (ce.clauses) |clause| {
                                // Check for module_ref pattern matching enum variant
                                // e.g. Color.Red → literal atom pattern or module_ref pattern
                                if (clause.pattern.* == .literal) {
                                    if (clause.pattern.literal == .atom) {
                                        if (clause.pattern.literal.atom.value == variant) {
                                            variant_matched = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (variant_matched) matched_count += 1;
                        }
                        if (matched_count < et.variants.len) {
                            // Find missing variants
                            var missing: std.ArrayList([]const u8) = .empty;
                            for (et.variants) |variant| {
                                var found = false;
                                for (ce.clauses) |clause| {
                                    if (clause.pattern.* == .literal) {
                                        if (clause.pattern.literal == .atom) {
                                            if (clause.pattern.literal.atom.value == variant) {
                                                found = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (!found) {
                                    missing.append(self.allocator, self.interner.get(variant)) catch {};
                                }
                            }
                            if (missing.items.len > 0) {
                                const missing_str = std.mem.join(self.allocator, ", ", missing.items) catch "...";
                                try self.addHardError(
                                    try std.fmt.allocPrint(self.allocator, "non-exhaustive match on enum `{s}`", .{
                                        self.interner.get(et.name),
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
                return try self.store.addType(.{
                    .function = .{
                        .params = params,
                        .return_type = TypeStore.UNKNOWN,
                    },
                });
            },
            .field_access => |fa| {
                // Check for enum variant access (e.g. Color.Red)
                if (fa.object.* == .module_ref) {
                    const parts = fa.object.module_ref.name.parts;
                    if (parts.len == 1) {
                        if (self.store.name_to_type.get(parts[0])) |tid| {
                            const t = self.store.getType(tid);
                            if (t == .enum_type) {
                                // Validate variant name
                                var valid = false;
                                for (t.enum_type.variants) |v| {
                                    if (v == fa.field) {
                                        valid = true;
                                        break;
                                    }
                                }
                                if (!valid) {
                                    try self.addHardError(
                                        try std.fmt.allocPrint(self.allocator, "`{s}` is not a variant of enum `{s}`", .{
                                            self.interner.get(fa.field),
                                            self.interner.get(t.enum_type.name),
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
            .panic_expr => TypeStore.NEVER,
            .unwrap => TypeStore.UNKNOWN,
            .pipe => TypeStore.UNKNOWN, // desugared before type checking
            .module_ref => |mr| {
                // Check for enum variant access (e.g. Color.Red parsed as module_ref ["Color", "Red"])
                if (mr.name.parts.len == 2) {
                    if (self.store.name_to_type.get(mr.name.parts[0])) |tid| {
                        const t = self.store.getType(tid);
                        if (t == .enum_type) {
                            // Validate variant name
                            var valid = false;
                            for (t.enum_type.variants) |v| {
                                if (v == mr.name.parts[1]) {
                                    valid = true;
                                    break;
                                }
                            }
                            if (!valid) {
                                try self.addHardError(
                                    try std.fmt.allocPrint(self.allocator, "`{s}` is not a variant of enum `{s}`", .{
                                        self.interner.get(mr.name.parts[1]),
                                        self.interner.get(t.enum_type.name),
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
            .unquote_expr => TypeStore.UNKNOWN,
            .with_expr => TypeStore.UNKNOWN, // desugared before type checking
            .cond_expr => TypeStore.UNKNOWN, // desugared before type checking
            .intrinsic => TypeStore.UNKNOWN,
            .binary_literal => TypeStore.STRING, // binary literals produce []const u8
            .type_annotated => |ta| {
                // Infer the inner expression, but prefer the annotated type
                _ = try self.inferExpr(ta.expr);
                return try self.resolveTypeExpr(ta.type_expr);
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
                            return t.function.return_type;
                        }
                    }
                }

                // Check function families
                if (self.graph.resolveFamily(scope_id, vr.name, arity)) |_| {
                    for (call.args) |arg| _ = try self.inferExpr(arg);
                    return TypeStore.UNKNOWN;
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

        // Non-var_ref callee (field access, lambda, etc.) — original path
        const callee_type = try self.inferExpr(call.callee);
        if (callee_type != TypeStore.UNKNOWN and callee_type != TypeStore.ERROR) {
            const ct = self.store.getType(callee_type);
            if (ct == .function) {
                for (call.args) |arg| _ = try self.inferExpr(arg);
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
                    "Bool", "String", "Atom", "Nil", "Never",
                    "i64",  "i32",    "i16",  "i8",
                    "u64",  "u32",    "u16",  "u8",
                    "f64",  "f32",    "f16",
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
                const builtins = [_][]const u8{
                    "Bool", "String", "Atom", "Nil", "Never",
                    "i64",  "i32",    "i16",  "i8",
                    "u64",  "u32",    "u16",  "u8",
                    "f64",  "f32",    "f16",
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
                return try self.store.addType(.{
                    .function = .{
                        .params = try param_types.toOwnedSlice(self.allocator),
                        .return_type = return_type,
                    },
                });
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

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "type check simple function" {
    const source =
        \\defmodule Test do
        \\  def add(x :: i64, y :: i64) :: i64 do
        \\    x + y
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check literals" {
    const source =
        \\defmodule Test do
        \\  def foo() do
        \\    42
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check case expression" {
    const source =
        \\defmodule Test do
        \\  def foo(x) do
        \\    case x do
        \\      {:ok, v} ->
        \\        v
        \\      {:error, e} ->
        \\        e
        \\    end
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check arithmetic mismatch reported" {
    // String + i64 should produce a type error
    const source =
        \\defmodule Test do
        \\  def bad() do
        \\    "hello" + 42
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def double(x :: i64) :: i64 do
        \\    x + x
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // Should have no errors — x resolves to i64 from param type
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check if condition must be Bool" {
    // Using an integer as if condition should produce an error
    const source =
        \\defmodule Test do
        \\  def bad() do
        \\    if 42 do
        \\      1
        \\    end
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def bad() :: i64 do
        \\    "not a number"
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def add(x :: i64) do
        \\    x
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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

test "return type mismatch has secondary span" {
    const source =
        \\defmodule Test do
        \\  def bad() :: i64 do
        \\    "not a number"
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def foo(a, b) do
        \\    a + b
        \\  end
        \\  def bar() do
        \\    fob(1, 2)
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def foo(a) do
        \\    a
        \\  end
        \\  def bar() do
        \\    zzzzz(1)
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def foo(a, b) do
        \\    a + b
        \\  end
        \\  def bar() do
        \\    foo(1, 2)
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    // No "cannot find function" errors
    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "cannot find a function") == null);
    }
}

test "unused variable produces warning" {
    const source =
        \\defmodule Test do
        \\  def foo() do
        \\    x = 42
        \\    1
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def foo() do
        \\    _x = 42
        \\    1
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "_x") == null);
    }
}

test "used variable no unused warning" {
    const source =
        \\defmodule Test do
        \\  def foo() do
        \\    x = 42
        \\    x + 1
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try checker.checkUnusedBindings();

    for (checker.errors.items) |err| {
        try std.testing.expect(std.mem.indexOf(u8, err.message, "variable `x` is unused") == null);
    }
}

test "unknown type name produces error" {
    const source =
        \\defmodule Test do
        \\  def foo(x :: Other) do
        \\    x
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
        \\defmodule Test do
        \\  def foo(x) do
        \\    42
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
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
