const std = @import("std");
const ast = @import("ast.zig");

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

    pub fn init(id: FunctionFamilyId, scope_id: ScopeId, name: ast.StringId, arity: u32, visibility: ast.FunctionDecl.Visibility) FunctionFamily {
        return .{
            .id = id,
            .scope_id = scope_id,
            .name = name,
            .arity = arity,
            .clauses = .empty,
            .visibility = visibility,
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

pub const Binding = struct {
    id: BindingId,
    name: ast.StringId,
    scope_id: ScopeId,
    kind: BindingKind,
    span: ast.SourceSpan,
    type_id: ?u32 = null,
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
};

// ============================================================
// Module registration
// ============================================================

pub const ModuleEntry = struct {
    name: ast.ModuleName,
    scope_id: ScopeId,
    decl: *const ast.ModuleDecl,
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
    prelude_scope: ScopeId,

    pub fn init(allocator: std.mem.Allocator) ScopeGraph {
        var graph = ScopeGraph{
            .allocator = allocator,
            .scopes = .empty,
            .bindings = .empty,
            .families = .empty,
            .macro_families = .empty,
            .types = .empty,
            .modules = .empty,
            .prelude_scope = 0,
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
        return id;
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
    pub fn resolveFamily(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?FunctionFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const scope = self.getScope(sid);
            if (scope.function_families.get(key)) |fid| {
                return fid;
            }
            current = scope.parent;
        }
        return null;
    }

    /// Look up a macro family by name and arity, walking up the scope chain.
    pub fn resolveMacro(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?MacroFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const scope = self.getScope(sid);
            if (scope.macros.get(key)) |mid| {
                return mid;
            }
            current = scope.parent;
        }
        return null;
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
