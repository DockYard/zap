const std = @import("std");
const ast = @import("ast.zig");
const ctfe = @import("ctfe.zig");

// ============================================================
// IDs — typed wrappers for type safety
// ============================================================

pub const ScopeId = u32;
pub const BindingId = u32;
pub const FunctionFamilyId = u32;
pub const MacroFamilyId = u32;
pub const TypeId = u32;

pub const FamilyKey = struct {
    name: ast.StringId,
    arity: u32,
};

// ============================================================
// Scope
// ============================================================

pub const ScopeKind = enum {
    prelude,
    module,
    function,
    block,
    case_clause,
    macro_expansion,
    import,
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    kind: ScopeKind,
    bindings: std.AutoHashMap(ast.StringId, BindingId),
    function_families: std.AutoHashMap(FamilyKey, FunctionFamilyId),
    macros: std.AutoHashMap(FamilyKey, MacroFamilyId),
    imports: std.ArrayList(ImportedScope),
    aliases: std.AutoHashMap(ast.StringId, ast.StringId),

    pub fn init(allocator: std.mem.Allocator, id: ScopeId, parent: ?ScopeId, kind: ScopeKind) Scope {
        return .{
            .id = id,
            .parent = parent,
            .kind = kind,
            .bindings = std.AutoHashMap(ast.StringId, BindingId).init(allocator),
            .function_families = std.AutoHashMap(FamilyKey, FunctionFamilyId).init(allocator),
            .macros = std.AutoHashMap(FamilyKey, MacroFamilyId).init(allocator),
            .imports = .empty,
            .aliases = std.AutoHashMap(ast.StringId, ast.StringId).init(allocator),
        };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.bindings.deinit();
        self.function_families.deinit();
        self.macros.deinit();
        self.imports.deinit(allocator);
        self.aliases.deinit();
    }
};

// ============================================================
// Imports
// ============================================================

pub const ImportedScope = struct {
    source_module: ast.ModuleName,
    filter: ImportFilter,
    imported_families: std.AutoHashMap(FamilyKey, FunctionFamilyId),
    imported_types: std.AutoHashMap(ast.StringId, TypeId),
};

pub const ImportFilter = union(enum) {
    all,
    only: []const ImportEntry,
    except: []const ImportEntry,
};

pub const ImportEntry = struct {
    name: ast.StringId,
    arity: ?u32,
};

// ============================================================
// Function family
// ============================================================

pub const FunctionFamily = struct {
    id: FunctionFamilyId,
    scope_id: ScopeId,
    name: ast.StringId,
    arity: u32,
    clauses: std.ArrayList(FunctionClauseRef),
    visibility: ast.FunctionDecl.Visibility,
    /// Attributes attached to this function (@doc, @deprecated, etc.)
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,

    pub fn init(id: FunctionFamilyId, scope_id: ScopeId, name: ast.StringId, arity: u32, visibility: ast.FunctionDecl.Visibility) FunctionFamily {
        return .{
            .id = id,
            .scope_id = scope_id,
            .name = name,
            .arity = arity,
            .clauses = .empty,
            .visibility = visibility,
            .attributes = .empty,
        };
    }

    pub fn deinit(self: *FunctionFamily, allocator: std.mem.Allocator) void {
        self.clauses.deinit(allocator);
    }
};

pub const FunctionClauseRef = struct {
    decl: *const ast.FunctionDecl,
    clause_index: u32,
};

// ============================================================
// Macro family
// ============================================================

pub const MacroFamily = struct {
    id: MacroFamilyId,
    scope_id: ScopeId,
    name: ast.StringId,
    arity: u32,
    clauses: std.ArrayList(FunctionClauseRef),
    /// Attributes attached to this macro (@doc, @debug, etc.)
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,

    pub fn init(id: MacroFamilyId, scope_id: ScopeId, name: ast.StringId, arity: u32) MacroFamily {
        return .{
            .id = id,
            .scope_id = scope_id,
            .name = name,
            .arity = arity,
            .clauses = .empty,
        };
    }

    pub fn deinit(self: *MacroFamily, allocator: std.mem.Allocator) void {
        self.clauses.deinit(allocator);
    }
};

// ============================================================
// Binding
// ============================================================

pub const TypeProvenance = struct {
    type_id: u32,
    ownership: ast.Ownership = .shared,
    source_span: ast.SourceSpan,
};

pub const Binding = struct {
    id: BindingId,
    name: ast.StringId,
    scope_id: ScopeId,
    kind: BindingKind,
    span: ast.SourceSpan,
    type_id: ?TypeProvenance = null,
};

pub const BindingKind = enum {
    variable,
    parameter,
    pattern_bind,
};

// ============================================================
// Type registration
// ============================================================

pub const TypeEntry = struct {
    id: TypeId,
    name: ast.StringId,
    scope_id: ScopeId,
    kind: TypeKind,
    params: []const ast.TypeParam,
};

pub const TypeKind = union(enum) {
    type_alias: *const ast.TypeExpr,
    opaque_type: *const ast.TypeExpr,
    struct_type: *const ast.StructDecl,
    union_type: *const ast.UnionDecl,
};

// ============================================================
// Module registration
// ============================================================

/// A compile-time attribute stored on a module or function.
pub const Attribute = struct {
    name: ast.StringId,
    type_expr: ?*const ast.TypeExpr = null,
    value: ?*const ast.Expr = null,
    computed_value: ?ctfe.ConstValue = null,
};

pub const ModuleEntry = struct {
    name: ast.ModuleName,
    scope_id: ScopeId,
    decl: *const ast.ModuleDecl,
    /// Module-level attributes (@moduledoc, @author, etc.)
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,
};

// ============================================================
// Protocol and Impl entries
// ============================================================

pub const ProtocolEntry = struct {
    name: ast.ModuleName,
    scope_id: ScopeId,
    decl: *const ast.ProtocolDecl,
};

pub const ImplEntry = struct {
    protocol_name: ast.ModuleName,
    target_type: ast.ModuleName,
    scope_id: ScopeId,
    decl: *const ast.ImplDecl,
    is_private: bool,
};

// ============================================================
// Scope graph — the central store
// ============================================================

pub const ScopeGraph = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    bindings: std.ArrayList(Binding),
    families: std.ArrayList(FunctionFamily),
    macro_families: std.ArrayList(MacroFamily),
    types: std.ArrayList(TypeEntry),
    modules: std.ArrayList(ModuleEntry),
    protocols: std.ArrayList(ProtocolEntry),
    impls: std.ArrayList(ImplEntry),
    prelude_scope: ScopeId,
    /// Maps (source_id, span.start) → scope_id, so the type checker can
    /// find the scope for function clauses and modules without mutating
    /// the AST. Uses a composite key to prevent collisions between
    /// AST nodes at the same byte offset in different source files.
    node_scope_map: std.AutoHashMap(u64, ScopeId),
    /// Maps type name (StringId) → TypeId for global type resolution
    type_name_to_id: std.AutoHashMap(ast.StringId, TypeId),

    /// Build the composite key for node_scope_map from a SourceSpan.
    /// Encodes source_id in the high 32 bits and span.start in the low 32 bits.
    /// source_id=null maps to 0xFFFFFFFF to avoid colliding with real file IDs.
    pub fn spanKey(span: ast.SourceSpan) u64 {
        const sid: u64 = span.source_id orelse 0xFFFFFFFF;
        return (sid << 32) | @as(u64, span.start);
    }

    pub fn init(allocator: std.mem.Allocator) ScopeGraph {
        var graph = ScopeGraph{
            .allocator = allocator,
            .scopes = .empty,
            .bindings = .empty,
            .families = .empty,
            .macro_families = .empty,
            .types = .empty,
            .modules = .empty,
            .protocols = .empty,
            .impls = .empty,
            .prelude_scope = 0,
            .node_scope_map = std.AutoHashMap(u64, ScopeId).init(allocator),
            .type_name_to_id = std.AutoHashMap(ast.StringId, TypeId).init(allocator),
        };
        // Create prelude scope as scope 0
        const prelude = Scope.init(allocator, 0, null, .prelude);
        graph.scopes.append(allocator, prelude) catch {};
        return graph;
    }

    pub fn deinit(self: *ScopeGraph) void {
        for (self.scopes.items) |*s| {
            s.deinit(self.allocator);
        }
        self.scopes.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        for (self.families.items) |*f| {
            f.deinit(self.allocator);
        }
        self.families.deinit(self.allocator);
        for (self.macro_families.items) |*m| {
            m.deinit(self.allocator);
        }
        self.macro_families.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.protocols.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        self.node_scope_map.deinit();
        self.type_name_to_id.deinit();
    }

    pub fn createScope(self: *ScopeGraph, parent: ?ScopeId, kind: ScopeKind) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        const s = Scope.init(self.allocator, id, parent, kind);
        try self.scopes.append(self.allocator, s);
        return id;
    }

    pub fn getScope(self: *const ScopeGraph, id: ScopeId) *const Scope {
        return &self.scopes.items[id];
    }

    pub fn getScopeMut(self: *ScopeGraph, id: ScopeId) *Scope {
        return &self.scopes.items[id];
    }

    pub fn createBinding(self: *ScopeGraph, name: ast.StringId, scope_id: ScopeId, kind: BindingKind, span: ast.SourceSpan) !BindingId {
        const id: BindingId = @intCast(self.bindings.items.len);
        try self.bindings.append(self.allocator, .{
            .id = id,
            .name = name,
            .scope_id = scope_id,
            .kind = kind,
            .span = span,
        });
        try self.getScopeMut(scope_id).bindings.put(name, id);
        return id;
    }

    pub fn createFamily(self: *ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32, visibility: ast.FunctionDecl.Visibility) !FunctionFamilyId {
        const id: FunctionFamilyId = @intCast(self.families.items.len);
        const family = FunctionFamily.init(id, scope_id, name, arity, visibility);
        try self.families.append(self.allocator, family);
        const key = FamilyKey{ .name = name, .arity = arity };
        try self.getScopeMut(scope_id).function_families.put(key, id);
        return id;
    }

    pub fn getFamily(self: *const ScopeGraph, id: FunctionFamilyId) *const FunctionFamily {
        return &self.families.items[id];
    }

    pub fn getFamilyMut(self: *ScopeGraph, id: FunctionFamilyId) *FunctionFamily {
        return &self.families.items[id];
    }

    pub fn createMacroFamily(self: *ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) !MacroFamilyId {
        const id: MacroFamilyId = @intCast(self.macro_families.items.len);
        const family = MacroFamily.init(id, scope_id, name, arity);
        try self.macro_families.append(self.allocator, family);
        const key = FamilyKey{ .name = name, .arity = arity };
        try self.getScopeMut(scope_id).macros.put(key, id);
        return id;
    }

    pub fn registerType(self: *ScopeGraph, name: ast.StringId, scope_id: ScopeId, kind: TypeKind, params: []const ast.TypeParam) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(self.allocator, .{
            .id = id,
            .name = name,
            .scope_id = scope_id,
            .kind = kind,
            .params = params,
        });
        // Register named types for global lookup (skip sentinel 0 for module-scoped unnamed structs)
        if (name != 0) {
            try self.type_name_to_id.put(name, id);
        }
        return id;
    }

    /// Look up a type by its interned name string ID.
    pub fn resolveTypeByName(self: *const ScopeGraph, name: ast.StringId) ?TypeId {
        return self.type_name_to_id.get(name);
    }

    pub fn registerModule(self: *ScopeGraph, name: ast.ModuleName, scope_id: ScopeId, decl: *const ast.ModuleDecl) !void {
        try self.modules.append(self.allocator, .{
            .name = name,
            .scope_id = scope_id,
            .decl = decl,
        });
    }

    /// Look up a binding by name, walking up the scope chain.
    pub fn resolveBinding(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId) ?BindingId {
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const scope = self.getScope(sid);
            if (scope.bindings.get(name)) |bid| {
                return bid;
            }
            current = scope.parent;
        }
        return null;
    }

    /// Look up a function family by name and arity, walking up the scope chain.
    /// Also checks imported module scopes for unqualified access.
    pub fn resolveFamily(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?FunctionFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const s = self.getScope(sid);
            if (s.function_families.get(key)) |fid| {
                return fid;
            }
            // Check imported module scopes
            for (s.imports.items) |imp| {
                // Check pre-populated imported_families
                if (imp.imported_families.get(key)) |fid| {
                    return fid;
                }
                // Also search the source module's scope directly
                if (self.findModuleScope(imp.source_module)) |mod_scope_id| {
                    const mod_scope = self.getScope(mod_scope_id);
                    if (mod_scope.function_families.get(key)) |fid| {
                        // Check import filter
                        if (self.passesImportFilter(imp.filter, key)) return fid;
                    }
                }
            }
            current = s.parent;
        }
        return null;
    }

    /// Look up a macro family by name and arity, walking up the scope chain.
    /// Also checks imported module scopes.
    pub fn resolveMacro(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?MacroFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const s = self.getScope(sid);
            if (s.macros.get(key)) |mid| {
                return mid;
            }
            // Check imported module scopes for macros
            for (s.imports.items) |imp| {
                if (self.findModuleScope(imp.source_module)) |mod_scope_id| {
                    const mod_scope = self.getScope(mod_scope_id);
                    if (mod_scope.macros.get(key)) |mid| {
                        if (self.passesImportFilter(imp.filter, key)) return mid;
                    }
                }
            }
            current = s.parent;
        }
        return null;
    }

    /// Find a module's scope by its name.
    pub fn findModuleScope(self: *const ScopeGraph, module_name: ast.ModuleName) ?ScopeId {
        for (self.modules.items) |mod_entry| {
            if (mod_entry.decl.name.parts.len == module_name.parts.len) {
                var match = true;
                for (mod_entry.decl.name.parts, module_name.parts) |a, b| {
                    if (a != b) {
                        match = false;
                        break;
                    }
                }
                if (match) return mod_entry.scope_id;
            }
        }
        return null;
    }

    /// Find a protocol by name (matching all parts of ModuleName).
    pub fn findProtocol(self: *const ScopeGraph, name: ast.ModuleName) ?*const ProtocolEntry {
        for (self.protocols.items) |*entry| {
            if (moduleNamesMatch(entry.name, name)) return entry;
        }
        return null;
    }

    /// Find the impl of a given protocol for a given target type.
    pub fn findImpl(self: *const ScopeGraph, protocol_name: ast.ModuleName, target_type: ast.ModuleName) ?*const ImplEntry {
        for (self.impls.items) |*entry| {
            if (moduleNamesMatch(entry.protocol_name, protocol_name) and
                moduleNamesMatch(entry.target_type, target_type)) return entry;
        }
        return null;
    }

    /// Find ALL impls for a given protocol. Returns matching entries from the impls list.
    pub fn findImplsForProtocol(self: *const ScopeGraph, protocol_name: ast.ModuleName, allocator: std.mem.Allocator) ![]const *const ImplEntry {
        var results: std.ArrayListUnmanaged(*const ImplEntry) = .empty;
        for (self.impls.items) |*entry| {
            if (moduleNamesMatch(entry.protocol_name, protocol_name)) {
                try results.append(allocator, entry);
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    fn moduleNamesMatch(a: ast.ModuleName, b: ast.ModuleName) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |ap, bp| {
            if (ap != bp) return false;
        }
        return true;
    }

    /// Check if a function key passes an import filter.
    fn passesImportFilter(self: *const ScopeGraph, filter: ImportFilter, key: FamilyKey) bool {
        _ = self;
        switch (filter) {
            .all => return true,
            .only => |entries| {
                for (entries) |entry| {
                    if (entry.name == key.name) {
                        if (entry.arity == null or entry.arity.? == key.arity) return true;
                    }
                }
                return false;
            },
            .except => |entries| {
                for (entries) |entry| {
                    if (entry.name == key.name) {
                        if (entry.arity == null or entry.arity.? == key.arity) return false;
                    }
                }
                return true;
            },
        }
    }

    /// Collect all binding names visible from a scope, walking up the chain.
    /// Returns a list of interned string IDs (caller must resolve via interner).
    pub fn collectVisibleBindingNames(self: *const ScopeGraph, scope_id: ScopeId, allocator: std.mem.Allocator) ![]ast.StringId {
        var names: std.ArrayList(ast.StringId) = .empty;
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const scope = self.getScope(sid);
            var iter = scope.bindings.iterator();
            while (iter.next()) |entry| {
                try names.append(allocator, entry.key_ptr.*);
            }
            current = scope.parent;
        }
        return names.toOwnedSlice(allocator);
    }

    /// Collect all function family names visible from a scope.
    pub fn collectVisibleFunctionNames(self: *const ScopeGraph, scope_id: ScopeId, allocator: std.mem.Allocator) ![]FamilyKey {
        var names: std.ArrayList(FamilyKey) = .empty;
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const scope = self.getScope(sid);
            var iter = scope.function_families.iterator();
            while (iter.next()) |entry| {
                try names.append(allocator, entry.key_ptr.*);
            }
            current = scope.parent;
        }
        return names.toOwnedSlice(allocator);
    }
};

// ============================================================
// Tests
// ============================================================

test "scope graph basic operations" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    // Prelude scope exists
    try std.testing.expectEqual(@as(usize, 1), graph.scopes.items.len);
    try std.testing.expectEqual(ScopeKind.prelude, graph.getScope(0).kind);

    // Create a module scope
    const mod_scope = try graph.createScope(0, .module);
    try std.testing.expectEqual(@as(ScopeId, 1), mod_scope);
    try std.testing.expectEqual(@as(?ScopeId, 0), graph.getScope(mod_scope).parent);

    // Create a function scope
    const fn_scope = try graph.createScope(mod_scope, .function);
    try std.testing.expectEqual(@as(ScopeId, 2), fn_scope);
}

test "scope graph binding resolution" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .module);
    const fn_scope = try graph.createScope(mod_scope, .function);

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const name_id: ast.StringId = 42;

    _ = try graph.createBinding(name_id, mod_scope, .variable, span);

    // Resolve from function scope should find binding in module scope
    const found = graph.resolveBinding(fn_scope, name_id);
    try std.testing.expect(found != null);

    // Resolve non-existent name
    const not_found = graph.resolveBinding(fn_scope, 999);
    try std.testing.expect(not_found == null);
}

test "scope graph family creation" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .module);
    const name_id: ast.StringId = 10;

    const fam_id = try graph.createFamily(mod_scope, name_id, 2, .public);

    // Resolve from same scope
    const found = graph.resolveFamily(mod_scope, name_id, 2);
    try std.testing.expectEqual(fam_id, found.?);

    // Different arity should not match
    const wrong_arity = graph.resolveFamily(mod_scope, name_id, 3);
    try std.testing.expect(wrong_arity == null);
}
