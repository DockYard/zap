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
// ScopeSet — Flatt 2016 "Bindings as Sets of Scopes"
//
// Each identifier (binder or reference) carries a *set* of scopes
// rather than a single owning scope. Macro expansion adds and flips
// scopes asymmetrically: the macro-introduction scope tags template
// identifiers; the macro-use scope is added to user-supplied syntax
// on entry and flipped on exit, so identifiers from the user retain
// their original scope set while identifiers introduced by the macro
// pick up the macro-use scope.
//
// Resolution: among bindings with the same name, pick the binding
// whose scope set is the largest subset of the reference's scope
// set. This is what discriminates between user-supplied `tmp` and
// macro-introduced `tmp` in the canonical swap-macro example.
//
// Representation: sorted ArrayListUnmanaged. Sets are tiny in
// practice (fewer than 8 scopes for typical identifiers); a sorted
// array gives O(n+m) union/intersect with cache-friendly access and
// no allocator overhead per element. The sorted invariant lets `eq`
// run in O(n) and `subsetOf` run in O(n+m).
// ============================================================

pub const ScopeSet = struct {
    items: std.ArrayListUnmanaged(ScopeId) = .empty,

    pub const empty: ScopeSet = .{};

    pub fn deinit(self: *ScopeSet, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn isEmpty(self: ScopeSet) bool {
        return self.items.items.len == 0;
    }

    pub fn len(self: ScopeSet) usize {
        return self.items.items.len;
    }

    pub fn contains(self: ScopeSet, scope_id: ScopeId) bool {
        // Binary search the sorted slice.
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.items.items[mid];
            if (v == scope_id) return true;
            if (v < scope_id) lo = mid + 1 else hi = mid;
        }
        return false;
    }

    /// Add `scope_id` to the set. Idempotent — re-adding a present
    /// scope is a no-op. Maintains the sorted invariant.
    pub fn add(self: *ScopeSet, allocator: std.mem.Allocator, scope_id: ScopeId) !void {
        const idx = self.lowerBound(scope_id);
        if (idx < self.items.items.len and self.items.items[idx] == scope_id) return;
        try self.items.insert(allocator, idx, scope_id);
    }

    /// Remove `scope_id` from the set. No-op when absent.
    pub fn remove(self: *ScopeSet, scope_id: ScopeId) void {
        const idx = self.lowerBound(scope_id);
        if (idx < self.items.items.len and self.items.items[idx] == scope_id) {
            _ = self.items.orderedRemove(idx);
        }
    }

    /// XOR `scope_id` into the set: present → removed, absent → added.
    /// This is Flatt's "flip-scope" operation. Used at the macro
    /// expansion boundary to give the asymmetric treatment of template
    /// vs user-supplied identifiers.
    pub fn flip(self: *ScopeSet, allocator: std.mem.Allocator, scope_id: ScopeId) !void {
        const idx = self.lowerBound(scope_id);
        if (idx < self.items.items.len and self.items.items[idx] == scope_id) {
            _ = self.items.orderedRemove(idx);
        } else {
            try self.items.insert(allocator, idx, scope_id);
        }
    }

    /// True iff `self ⊆ other`. Both sets are sorted, so a linear
    /// merge-style walk is O(self.len + other.len).
    pub fn subsetOf(self: ScopeSet, other: ScopeSet) bool {
        var i: usize = 0;
        var j: usize = 0;
        const a = self.items.items;
        const b = other.items.items;
        while (i < a.len) {
            if (j >= b.len) return false;
            if (a[i] == b[j]) {
                i += 1;
                j += 1;
            } else if (b[j] < a[i]) {
                j += 1;
            } else {
                return false; // a[i] not in b
            }
        }
        return true;
    }

    /// Set equality. Linear in length.
    pub fn eq(self: ScopeSet, other: ScopeSet) bool {
        const a = self.items.items;
        const b = other.items.items;
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (x != y) return false;
        }
        return true;
    }

    /// Allocate a fresh ScopeSet that is the intersection of `self`
    /// and `other`. Used by the resolver tie-break path.
    pub fn intersect(self: ScopeSet, other: ScopeSet, allocator: std.mem.Allocator) !ScopeSet {
        var result: ScopeSet = .{};
        const a = self.items.items;
        const b = other.items.items;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.len and j < b.len) {
            if (a[i] == b[j]) {
                try result.items.append(allocator, a[i]);
                i += 1;
                j += 1;
            } else if (a[i] < b[j]) {
                i += 1;
            } else {
                j += 1;
            }
        }
        return result;
    }

    /// Deep-clone the scope set so the result owns its storage.
    pub fn clone(self: ScopeSet, allocator: std.mem.Allocator) !ScopeSet {
        var result: ScopeSet = .{};
        try result.items.appendSlice(allocator, self.items.items);
        return result;
    }

    /// Find the insertion point that preserves sortedness.
    fn lowerBound(self: ScopeSet, scope_id: ScopeId) usize {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.items.items[mid] < scope_id) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Returns the most specific scope in the set — the largest
    /// ScopeId, which by construction is the most recently created
    /// (and therefore innermost) scope. Used by lowering passes that
    /// want a single scope handle as a fallback resolution.
    pub fn primary(self: ScopeSet) ?ScopeId {
        const items = self.items.items;
        if (items.len == 0) return null;
        return items[items.len - 1];
    }

    pub fn slice(self: ScopeSet) []const ScopeId {
        return self.items.items;
    }
};

// ============================================================
// Scope
// ============================================================

pub const ScopeKind = enum {
    prelude,
    struct_scope,
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
    source_struct: ast.StructName,
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
    /// Capabilities this macro requires at compile time, populated by
    /// the static inference pass in `capability_inference.zig`. Each
    /// flag is set when the body — or a function/macro it transitively
    /// calls — invokes a capability-bearing intrinsic. The macro
    /// evaluator and CTFE interpreter consult this set to grant the
    /// matching permissions during expansion.
    required_caps: ctfe.CapabilitySet = .{},
    /// Per-family Flatt-2016 macro-introduction scope. Allocated lazily
    /// the first time a macro in this family is expanded, then reused
    /// for every subsequent expansion of any of its clauses. The
    /// asymmetric add/flip plumbing (`MacroEngine.expandMacroCall`)
    /// stamps this scope onto every identifier in the template body
    /// (including identifiers introduced by `quote { ... }`). Per-call
    /// `use_scope` lifetimes live alongside this on the engine, not
    /// here: the use_scope is allocated fresh per macro invocation and
    /// never cached, since two adjacent calls to the same macro must
    /// produce distinguishable scope-set marks for resolution.
    intro_scope: ?ScopeId = null,

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
    /// Flatt-2016 hygiene scope set for this binding. Populated by the
    /// collector and macro engine when bindings are introduced; defaults
    /// to the empty set so non-hygiene callsites see the same behaviour
    /// as before. Resolution against this field happens through
    /// `ScopeGraph.resolveBindingByScopes`; the legacy scope-chain
    /// `resolveBinding` ignores it.
    scopes: ScopeSet = .empty,
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
    /// Type-level attributes (@doc, @deprecated, etc.)
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,
};

pub const TypeKind = union(enum) {
    type_alias: *const ast.TypeExpr,
    opaque_type: *const ast.TypeExpr,
    struct_type: *const ast.StructDecl,
    union_type: *const ast.UnionDecl,
};

// ============================================================
// Struct registration
// ============================================================

/// A compile-time attribute stored on a struct or function.
///
/// Attributes are append-only at compile time. A single declared
/// `@name = value` produces one row; macros that call
/// `Struct.put_attribute(:name, value)` append additional rows.
/// When `accumulate` is true (set via `Struct.register_attribute`),
/// reads return the full accumulated list; otherwise reads return
/// the latest row's value.
pub const Attribute = struct {
    name: ast.StringId,
    type_expr: ?*const ast.TypeExpr = null,
    value: ?*const ast.Expr = null,
    computed_value: ?ctfe.ConstValue = null,
    /// When true, multiple `put_attribute` calls accumulate; reads
    /// see the list of values in append order.
    accumulate: bool = false,
};

pub const StructEntry = struct {
    name: ast.StructName,
    scope_id: ScopeId,
    decl: *const ast.StructDecl,
    /// Struct-level attributes (@doc, @author, etc.)
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,
};

pub const SourceFileEntry = struct {
    id: u32,
    path: []const u8,
    /// Source bytes for the file. Allows reflection callers to resolve
    /// span byte-offsets to 1-based line numbers without threading
    /// `compiler.SourceUnit` slices through every API. Empty when the
    /// caller registered only the path (legacy entry points).
    source: []const u8 = "",
};

// ============================================================
// Protocol and Impl entries
// ============================================================

pub const ProtocolEntry = struct {
    name: ast.StructName,
    scope_id: ScopeId,
    decl: *const ast.ProtocolDecl,
    attributes: std.ArrayListUnmanaged(Attribute) = .empty,
};

pub const ImplEntry = struct {
    protocol_name: ast.StructName,
    target_type: ast.StructName,
    scope_id: ScopeId,
    decl: *const ast.ImplDecl,
    is_private: bool,
};

// ============================================================
// Scope graph — the central store
// ============================================================

/// Compiler-recognised primitive runtime types. Each kind names a
/// runtime container the compiler must lower or dispatch specially
/// (e.g. List for cons-cell IR, Map for k/v-aware ZIR encoding,
/// Range for `in_range` literal switching, String for the byte-string
/// primitive). The Zap stdlib structs that back these kinds opt in
/// by writing a `@native_type = "list"|"map"|"range"|"string"`
/// attribute on the struct declaration; the collector scans those
/// attributes and populates `ScopeGraph.native_type_names`. Compiler
/// passes that previously string-compared struct names against
/// hardcoded literals consult the registry instead — that way the
/// "is this struct the runtime List type?" question is answered by
/// the user-visible declaration in `lib/list.zap`, not by a string
/// literal embedded in the compiler.
pub const NativeTypeKind = enum {
    list,
    map,
    range,
    string,

    pub fn fromName(name: []const u8) ?NativeTypeKind {
        if (std.mem.eql(u8, name, "list")) return .list;
        if (std.mem.eql(u8, name, "map")) return .map;
        if (std.mem.eql(u8, name, "range")) return .range;
        if (std.mem.eql(u8, name, "string")) return .string;
        return null;
    }
};

pub const ScopeGraph = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    bindings: std.ArrayList(Binding),
    families: std.ArrayList(FunctionFamily),
    macro_families: std.ArrayList(MacroFamily),
    types: std.ArrayList(TypeEntry),
    structs: std.ArrayList(StructEntry),
    source_files: std.ArrayList(SourceFileEntry),
    protocols: std.ArrayList(ProtocolEntry),
    impls: std.ArrayList(ImplEntry),
    prelude_scope: ScopeId,
    /// Maps (source_id, span.start) → scope_id, so the type checker can
    /// find the scope for function clauses and structs without mutating
    /// the AST. Uses a composite key to prevent collisions between
    /// AST nodes at the same byte offset in different source files.
    node_scope_map: std.AutoHashMap(u64, ScopeId),
    /// Maps type name (StringId) → TypeId for global type resolution
    type_name_to_id: std.AutoHashMap(ast.StringId, TypeId),
    /// Maps each NativeTypeKind to the StringId of the user-visible
    /// stdlib struct that opts in via `@native_type = "<kind>"`. Empty
    /// when no struct has registered for that kind. See `NativeTypeKind`
    /// for the design rationale.
    native_type_names: std.EnumArray(NativeTypeKind, ?ast.StringId),

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
            .structs = .empty,
            .source_files = .empty,
            .protocols = .empty,
            .impls = .empty,
            .prelude_scope = 0,
            .node_scope_map = std.AutoHashMap(u64, ScopeId).init(allocator),
            .type_name_to_id = std.AutoHashMap(ast.StringId, TypeId).init(allocator),
            .native_type_names = std.EnumArray(NativeTypeKind, ?ast.StringId).initFill(null),
        };
        // Create prelude scope as scope 0
        const prelude = Scope.init(allocator, 0, null, .prelude);
        graph.scopes.append(allocator, prelude) catch {};
        return graph;
    }

    /// Record the user-visible stdlib struct that opts in to a native
    /// type kind via its `@native_type` attribute. Idempotent — calling
    /// twice with the same name is a no-op; calling twice with
    /// different names keeps the first registration so the compiler
    /// has a stable answer to `nativeTypeStructName`.
    pub fn registerNativeType(self: *ScopeGraph, kind: NativeTypeKind, name: ast.StringId) void {
        const slot = self.native_type_names.getPtr(kind);
        if (slot.*) |_| return;
        slot.* = name;
    }

    /// Return the StringId of the struct registered for `kind`, or
    /// null if no struct has opted in. Used by lookup helpers like
    /// `isNativeTypeName`.
    pub fn nativeTypeStructName(self: *const ScopeGraph, kind: NativeTypeKind) ?ast.StringId {
        return self.native_type_names.get(kind);
    }

    /// True iff `name` (a single-segment struct name's StringId) refers
    /// to the struct registered for `kind`. Replaces the old pattern of
    /// comparing the rendered name against a hardcoded literal like
    /// `"List"`, `"Map"`, `"Range"`, `"String"`.
    pub fn isNativeTypeName(self: *const ScopeGraph, kind: NativeTypeKind, name: ast.StringId) bool {
        const registered = self.nativeTypeStructName(kind) orelse return false;
        return registered == name;
    }

    /// Convenience: identify the native-type kind for a given struct
    /// name, if any. Returns null when the name isn't a registered
    /// native type.
    pub fn classifyNativeType(self: *const ScopeGraph, name: ast.StringId) ?NativeTypeKind {
        for (std.enums.values(NativeTypeKind)) |kind| {
            if (self.native_type_names.get(kind)) |registered| {
                if (registered == name) return kind;
            }
        }
        return null;
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
        self.structs.deinit(self.allocator);
        self.source_files.deinit(self.allocator);
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
        return self.createBindingWithScopes(name, scope_id, kind, span, .empty);
    }

    /// Create a binding with an explicit hygiene scope set (Flatt 2016).
    /// The set is cloned so callers can free their input. The lexical
    /// `scope_id` is preserved separately for the lexical-chain resolver
    /// (`resolveBinding`); the new `resolveBindingByScopes` consults the
    /// scope set instead.
    pub fn createBindingWithScopes(
        self: *ScopeGraph,
        name: ast.StringId,
        scope_id: ScopeId,
        kind: BindingKind,
        span: ast.SourceSpan,
        scopes: ScopeSet,
    ) !BindingId {
        const id: BindingId = @intCast(self.bindings.items.len);
        const cloned = try scopes.clone(self.allocator);
        try self.bindings.append(self.allocator, .{
            .id = id,
            .name = name,
            .scope_id = scope_id,
            .kind = kind,
            .span = span,
            .scopes = cloned,
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
            .attributes = .empty,
        });
        // Register named types for global lookup (skip sentinel 0 for struct-scoped unnamed structs)
        if (name != 0) {
            try self.type_name_to_id.put(name, id);
        }
        return id;
    }

    /// Look up a type by its interned name string ID.
    pub fn resolveTypeByName(self: *const ScopeGraph, name: ast.StringId) ?TypeId {
        return self.type_name_to_id.get(name);
    }

    pub fn registerStruct(self: *ScopeGraph, name: ast.StructName, scope_id: ScopeId, decl: *const ast.StructDecl) !void {
        try self.structs.append(self.allocator, .{
            .name = name,
            .scope_id = scope_id,
            .decl = decl,
        });
    }

    /// Record the source path assigned to a parser source id. Reflection
    /// APIs use this to answer path-scoped source graph queries without
    /// guessing from struct names.
    pub fn registerSourceFile(self: *ScopeGraph, source_id: u32, path: []const u8) !void {
        try self.registerSourceFileWithContent(source_id, path, "");
    }

    /// Like `registerSourceFile`, but also stashes the source bytes so
    /// reflection callers can compute line numbers from span offsets.
    pub fn registerSourceFileWithContent(
        self: *ScopeGraph,
        source_id: u32,
        path: []const u8,
        source: []const u8,
    ) !void {
        for (self.source_files.items) |*entry| {
            if (entry.id == source_id) {
                entry.path = path;
                if (source.len > 0) entry.source = source;
                return;
            }
        }
        try self.source_files.append(self.allocator, .{
            .id = source_id,
            .path = path,
            .source = source,
        });
    }

    pub fn sourcePathById(self: *const ScopeGraph, source_id: u32) ?[]const u8 {
        for (self.source_files.items) |entry| {
            if (entry.id == source_id) return entry.path;
        }
        return null;
    }

    /// Return the registered source bytes for `source_id`, or an empty
    /// slice when the file was registered without content (older entry
    /// points). Reflection helpers use this to convert span byte offsets
    /// into 1-based line numbers.
    pub fn sourceContentById(self: *const ScopeGraph, source_id: u32) []const u8 {
        for (self.source_files.items) |entry| {
            if (entry.id == source_id) return entry.source;
        }
        return "";
    }

    /// Resolve a clause's owning scope. Prefers `meta.scope_id` (set
    /// directly by the collector — unambiguous even for macro-generated
    /// clauses with synthetic spans) over `node_scope_map` (which keys
    /// on span and collides whenever multiple clauses share the
    /// span 0:0 produced by macro expansion). Source-written clauses
    /// have both consistently set, so the priority change is a no-op
    /// for them and the fix only matters for macro-generated code.
    pub fn resolveClauseScope(self: *const ScopeGraph, meta: ast.NodeMeta) ?ScopeId {
        if (meta.scope_id != 0) return meta.scope_id;
        return self.node_scope_map.get(spanKey(meta.span));
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

    /// Flatt-2016 hygiene resolution. Among all bindings with the given
    /// `name`, considers only those whose `scopes` field is a subset
    /// of the reference's `scopes`. Returns the one whose set is
    /// strictly the largest (most-specific match wins). When two or
    /// more candidate bindings tie at the maximum size and neither
    /// dominates the other, the result is `null` — the contract is
    /// "no decision" rather than an error code, so the caller (the
    /// resolver/diagnostics pass) can attach a descriptive ambiguity
    /// diagnostic with the relevant spans. Returns `null` when no
    /// binding's `scopes` is a subset of the reference set, including
    /// the simple "no binding with this name" case.
    ///
    /// This sits alongside `resolveBinding` rather than replacing it;
    /// non-hygiene callsites continue to use the lexical chain
    /// resolver while hygiene-aware passes consult this one.
    pub fn resolveBindingByScopes(
        self: *const ScopeGraph,
        reference_scopes: ScopeSet,
        name: ast.StringId,
    ) ?BindingId {
        var best: ?BindingId = null;
        var best_len: usize = 0;
        var tied: bool = false;
        for (self.bindings.items) |binding| {
            if (binding.name != name) continue;
            if (!binding.scopes.subsetOf(reference_scopes)) continue;
            const candidate_len = binding.scopes.len();
            if (best == null or candidate_len > best_len) {
                best = binding.id;
                best_len = candidate_len;
                tied = false;
            } else if (candidate_len == best_len) {
                // Equal-sized subsets: only a tie if the existing best
                // and this candidate cover different sets. If they're
                // actually equal, the bindings collide on hygiene
                // grounds — still ambiguous.
                tied = true;
            }
        }
        if (tied) return null;
        return best;
    }

    /// Hygiene-aware binding resolution. When the reference's scope set
    /// is non-empty, consult `resolveBindingByScopes` first so Flatt-2016
    /// marks discriminate macro-introduced bindings from user-supplied
    /// identifiers; if that returns null (no binding's `scopes` is a
    /// subset of the reference's set, or the candidates tied) fall back
    /// to the lexical-chain walker. When the reference carries no
    /// hygiene marks (the common case for user code untouched by a
    /// macro), skip the scope-set query and use the lexical walker
    /// directly. The combination preserves existing semantics for
    /// non-hygiene callsites while enabling discrimination at hygiene-
    /// aware sites — bindings introduced before hygiene plumbing is
    /// fully wired (empty `Binding.scopes`) are still found by the
    /// largest-subset rule (empty set is a subset of every set), and
    /// the lexical fallback handles the remaining edge cases where a
    /// binding is registered only via the scope-table chain.
    pub fn resolveBindingHygienic(
        self: *const ScopeGraph,
        scope_id: ScopeId,
        name: ast.StringId,
        reference_scopes: ScopeSet,
    ) ?BindingId {
        if (!reference_scopes.isEmpty()) {
            if (self.resolveBindingByScopes(reference_scopes, name)) |bid| {
                return bid;
            }
        }
        return self.resolveBinding(scope_id, name);
    }

    /// Look up a function family by name and arity, walking up the scope chain.
    /// Also checks imported struct scopes for unqualified access.
    pub fn resolveFamily(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?FunctionFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const s = self.getScope(sid);
            if (s.function_families.get(key)) |fid| {
                return fid;
            }
            // Check imported struct scopes
            for (s.imports.items) |imp| {
                // Check pre-populated imported_families
                if (imp.imported_families.get(key)) |fid| {
                    return fid;
                }
                // Also search the source struct's scope directly
                if (self.findStructScope(imp.source_struct)) |mod_scope_id| {
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

    /// Result of `resolveFamilyAllowingDefaults` — the resolved family plus the
    /// declared arity so callers can detect when defaults were used to bridge
    /// a shorter call-site arity.
    pub const ResolvedFamilyWithDefaults = struct {
        family_id: FunctionFamilyId,
        declared_arity: u32,
    };

    /// Look up a function family that can be invoked with `call_arity`
    /// arguments. If no exact-arity family exists, search for a family with
    /// declared_arity > call_arity whose tail parameters (positions
    /// `call_arity..declared_arity-1`) all have default values, in every
    /// clause. The call site is allowed to omit those trailing arguments
    /// because the codegen layer (zir_builder) inlines the constant defaults
    /// when emitting the call.
    ///
    /// Mirrors the resolution path of `resolveFamily` so the same scope
    /// chain (including imports) is searched.
    pub fn resolveFamilyAllowingDefaults(
        self: *const ScopeGraph,
        scope_id: ScopeId,
        name: ast.StringId,
        call_arity: u32,
    ) ?ResolvedFamilyWithDefaults {
        // Exact arity wins — never reinterpret a present family with a
        // different arity even if a longer declared family also has
        // defaults that would technically permit the call.
        if (self.resolveFamily(scope_id, name, call_arity)) |fid| {
            return .{ .family_id = fid, .declared_arity = call_arity };
        }

        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const s = self.getScope(sid);
            if (self.matchFamilyWithDefaults(s, name, call_arity)) |hit| {
                return hit;
            }
            for (s.imports.items) |imp| {
                if (self.findStructScope(imp.source_struct)) |mod_scope_id| {
                    const mod_scope = self.getScope(mod_scope_id);
                    if (self.matchFamilyWithDefaults(mod_scope, name, call_arity)) |hit| {
                        const filter_key = FamilyKey{ .name = name, .arity = hit.declared_arity };
                        if (self.passesImportFilter(imp.filter, filter_key)) return hit;
                    }
                }
            }
            current = s.parent;
        }
        return null;
    }

    /// Inspect every family registered in `scope` whose name matches
    /// `name` and whose declared arity is greater than `call_arity`,
    /// returning the first family in which every clause's tail
    /// parameters (`call_arity..declared_arity-1`) have default values.
    fn matchFamilyWithDefaults(
        self: *const ScopeGraph,
        scope: *const Scope,
        name: ast.StringId,
        call_arity: u32,
    ) ?ResolvedFamilyWithDefaults {
        var it = scope.function_families.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key.name != name) continue;
            if (key.arity <= call_arity) continue;
            const family = self.getFamily(entry.value_ptr.*);
            if (allClausesAcceptDefaults(family, call_arity)) {
                return .{ .family_id = entry.value_ptr.*, .declared_arity = key.arity };
            }
        }
        return null;
    }

    fn allClausesAcceptDefaults(family: *const FunctionFamily, call_arity: u32) bool {
        if (family.clauses.items.len == 0) return false;
        for (family.clauses.items) |clause_ref| {
            if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return false;
            const clause = clause_ref.decl.clauses[clause_ref.clause_index];
            if (clause.params.len != family.arity) return false;
            if (call_arity > clause.params.len) return false;
            var idx: usize = call_arity;
            while (idx < clause.params.len) : (idx += 1) {
                if (clause.params[idx].default == null) return false;
            }
        }
        return true;
    }

    /// Look up a macro family by name and arity, walking up the scope chain.
    /// Also checks imported struct scopes.
    pub fn resolveMacro(self: *const ScopeGraph, scope_id: ScopeId, name: ast.StringId, arity: u32) ?MacroFamilyId {
        const key = FamilyKey{ .name = name, .arity = arity };
        var current: ?ScopeId = scope_id;
        while (current) |sid| {
            const s = self.getScope(sid);
            if (s.macros.get(key)) |mid| {
                return mid;
            }
            for (s.imports.items) |imp| {
                if (self.findStructScope(imp.source_struct)) |mod_scope_id| {
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

    /// Find a struct's scope by its name.
    pub fn findStructScope(self: *const ScopeGraph, struct_name: ast.StructName) ?ScopeId {
        for (self.structs.items) |mod_entry| {
            // Use stored name (not decl.name) for consistency after remapping
            if (mod_entry.name.parts.len == struct_name.parts.len) {
                var match = true;
                for (mod_entry.name.parts, struct_name.parts) |a, b| {
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

    /// Find the StructEntry whose scope is `scope_id`, returning a
    /// mutable pointer so callers can append attributes. Used by macro
    /// intrinsics that have only a ScopeId in hand (the macro engine's
    /// `current_struct_scope`).
    pub fn findStructByScope(self: *ScopeGraph, scope_id: ScopeId) ?*StructEntry {
        for (self.structs.items) |*entry| {
            if (entry.scope_id == scope_id) return entry;
        }
        return null;
    }

    /// Find a StructEntry by name, returning a mutable pointer.
    pub fn findStructEntryByName(self: *ScopeGraph, struct_name: ast.StructName) ?*StructEntry {
        for (self.structs.items) |*entry| {
            if (structNamesMatch(entry.name, struct_name)) return entry;
        }
        return null;
    }

    /// Mark `name` on `mod_entry` as an accumulating attribute. After
    /// this call, `putStructAttribute` appends new values rather than
    /// overwriting; `getStructAttribute` returns the full accumulated
    /// list when read. Idempotent — calling twice with the same name
    /// is a no-op.
    pub fn registerAccumulatingAttribute(
        self: *ScopeGraph,
        mod_entry: *StructEntry,
        name: ast.StringId,
    ) !void {
        // If a row already exists, flip its accumulate flag and ensure
        // any later rows with the same name match.
        var found = false;
        for (mod_entry.attributes.items) |*attr| {
            if (attr.name == name) {
                attr.accumulate = true;
                found = true;
            }
        }
        if (!found) {
            try mod_entry.attributes.append(self.allocator, .{
                .name = name,
                .accumulate = true,
            });
        }
    }

    /// Append `value` as an attribute named `name` on `mod_entry`. If
    /// any existing row with this name has `accumulate=true`, append a
    /// new row tagged accumulate=true. Otherwise, replace any existing
    /// single-value row (write-once-or-overwrite semantics, matching
    /// `@name = value` source declarations).
    pub fn putStructAttribute(
        self: *ScopeGraph,
        mod_entry: *StructEntry,
        name: ast.StringId,
        value: ctfe.ConstValue,
    ) !void {
        var is_accumulating = false;
        for (mod_entry.attributes.items) |attr| {
            if (attr.name == name and attr.accumulate) {
                is_accumulating = true;
                break;
            }
        }

        if (is_accumulating) {
            try mod_entry.attributes.append(self.allocator, .{
                .name = name,
                .computed_value = value,
                .accumulate = true,
            });
            return;
        }

        // Single-value semantics: overwrite the latest row with this
        // name, or append a new one.
        for (mod_entry.attributes.items) |*attr| {
            if (attr.name == name) {
                attr.computed_value = value;
                attr.value = null;
                attr.type_expr = null;
                return;
            }
        }
        try mod_entry.attributes.append(self.allocator, .{
            .name = name,
            .computed_value = value,
        });
    }

    /// Read the value of attribute `name` from `mod_entry`. Returns:
    ///   - For accumulating attributes: a list of all values in
    ///     append order (or an empty list if only a register call
    ///     happened and no values were appended).
    ///   - For single-value attributes: the latest value.
    ///   - null when no row with that name exists.
    pub fn getStructAttribute(
        self: *ScopeGraph,
        mod_entry: *const StructEntry,
        name: ast.StringId,
    ) !?ctfe.ConstValue {
        // Decide on shape by inspecting the rows.
        var is_accumulating = false;
        var match_count: usize = 0;
        var latest_value: ?ctfe.ConstValue = null;
        for (mod_entry.attributes.items) |attr| {
            if (attr.name != name) continue;
            match_count += 1;
            if (attr.accumulate) is_accumulating = true;
            if (attr.computed_value) |cv| latest_value = cv;
        }
        if (match_count == 0) return null;

        if (!is_accumulating) return latest_value;

        // Accumulating: collect all computed values into a list.
        var elems: std.ArrayListUnmanaged(ctfe.ConstValue) = .empty;
        for (mod_entry.attributes.items) |attr| {
            if (attr.name != name) continue;
            if (attr.computed_value) |cv| try elems.append(self.allocator, cv);
        }
        return ctfe.ConstValue{
            .list = try elems.toOwnedSlice(self.allocator),
        };
    }

    /// Find a protocol by name (matching all parts of StructName).
    pub fn findProtocol(self: *const ScopeGraph, name: ast.StructName) ?*const ProtocolEntry {
        for (self.protocols.items) |*entry| {
            if (structNamesMatch(entry.name, name)) return entry;
        }
        return null;
    }

    /// Find the impl of a given protocol for a given target type.
    pub fn findImpl(self: *const ScopeGraph, protocol_name: ast.StructName, target_type: ast.StructName) ?*const ImplEntry {
        for (self.impls.items) |*entry| {
            if (structNamesMatch(entry.protocol_name, protocol_name) and
                structNamesMatch(entry.target_type, target_type)) return entry;
        }
        return null;
    }

    /// Find ALL impls for a given protocol. Returns matching entries from the impls list.
    pub fn findImplsForProtocol(self: *const ScopeGraph, protocol_name: ast.StructName, allocator: std.mem.Allocator) ![]const *const ImplEntry {
        var results: std.ArrayListUnmanaged(*const ImplEntry) = .empty;
        for (self.impls.items) |*entry| {
            if (structNamesMatch(entry.protocol_name, protocol_name)) {
                try results.append(allocator, entry);
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    fn structNamesMatch(a: ast.StructName, b: ast.StructName) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |ap, bp| {
            if (ap != bp) return false;
        }
        return true;
    }

    /// Check if a function key passes an import filter.
    pub fn passesImportFilter(self: *const ScopeGraph, filter: ImportFilter, key: FamilyKey) bool {
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

    // Create a struct scope
    const mod_scope = try graph.createScope(0, .struct_scope);
    try std.testing.expectEqual(@as(ScopeId, 1), mod_scope);
    try std.testing.expectEqual(@as(?ScopeId, 0), graph.getScope(mod_scope).parent);

    // Create a function scope
    const fn_scope = try graph.createScope(mod_scope, .function);
    try std.testing.expectEqual(@as(ScopeId, 2), fn_scope);
}

test "scope graph binding resolution" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .struct_scope);
    const fn_scope = try graph.createScope(mod_scope, .function);

    const span = ast.SourceSpan{ .start = 0, .end = 1 };
    const name_id: ast.StringId = 42;

    _ = try graph.createBinding(name_id, mod_scope, .variable, span);

    // Resolve from function scope should find binding in struct scope
    const found = graph.resolveBinding(fn_scope, name_id);
    try std.testing.expect(found != null);

    // Resolve non-existent name
    const not_found = graph.resolveBinding(fn_scope, 999);
    try std.testing.expect(not_found == null);
}

test "scope graph family creation" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    const mod_scope = try graph.createScope(0, .struct_scope);
    const name_id: ast.StringId = 10;

    const fam_id = try graph.createFamily(mod_scope, name_id, 2, .public);

    // Resolve from same scope
    const found = graph.resolveFamily(mod_scope, name_id, 2);
    try std.testing.expectEqual(fam_id, found.?);

    // Different arity should not match
    const wrong_arity = graph.resolveFamily(mod_scope, name_id, 3);
    try std.testing.expect(wrong_arity == null);
}

test "native type kind name parsing" {
    try std.testing.expectEqual(@as(?NativeTypeKind, .list), NativeTypeKind.fromName("list"));
    try std.testing.expectEqual(@as(?NativeTypeKind, .map), NativeTypeKind.fromName("map"));
    try std.testing.expectEqual(@as(?NativeTypeKind, .range), NativeTypeKind.fromName("range"));
    try std.testing.expectEqual(@as(?NativeTypeKind, .string), NativeTypeKind.fromName("string"));
    try std.testing.expectEqual(@as(?NativeTypeKind, null), NativeTypeKind.fromName("List"));
    try std.testing.expectEqual(@as(?NativeTypeKind, null), NativeTypeKind.fromName(""));
    try std.testing.expectEqual(@as(?NativeTypeKind, null), NativeTypeKind.fromName("nope"));
}

test "ScopeSet add/contains/remove preserves sorted invariant" {
    const alloc = std.testing.allocator;
    var set: ScopeSet = .{};
    defer set.deinit(alloc);

    try std.testing.expect(set.isEmpty());
    try std.testing.expect(!set.contains(5));

    try set.add(alloc, 5);
    try set.add(alloc, 2);
    try set.add(alloc, 7);
    try set.add(alloc, 2); // idempotent

    try std.testing.expectEqual(@as(usize, 3), set.len());
    try std.testing.expect(set.contains(2));
    try std.testing.expect(set.contains(5));
    try std.testing.expect(set.contains(7));
    try std.testing.expect(!set.contains(3));

    // Sorted invariant: items must be in ascending order.
    try std.testing.expectEqualSlices(ScopeId, &[_]ScopeId{ 2, 5, 7 }, set.slice());

    set.remove(5);
    try std.testing.expect(!set.contains(5));
    try std.testing.expectEqualSlices(ScopeId, &[_]ScopeId{ 2, 7 }, set.slice());

    // Remove of absent element is a no-op.
    set.remove(99);
    try std.testing.expectEqual(@as(usize, 2), set.len());
}

test "ScopeSet flip XORs membership" {
    const alloc = std.testing.allocator;
    var set: ScopeSet = .{};
    defer set.deinit(alloc);

    // Flip absent → adds.
    try set.flip(alloc, 10);
    try std.testing.expect(set.contains(10));

    // Flip present → removes.
    try set.flip(alloc, 10);
    try std.testing.expect(!set.contains(10));

    // Mixed: pre-populate, flip selectively.
    try set.add(alloc, 1);
    try set.add(alloc, 3);
    try set.flip(alloc, 2); // adds 2
    try set.flip(alloc, 3); // removes 3
    try std.testing.expectEqualSlices(ScopeId, &[_]ScopeId{ 1, 2 }, set.slice());
}

test "ScopeSet subsetOf and eq" {
    const alloc = std.testing.allocator;
    var a: ScopeSet = .{};
    defer a.deinit(alloc);
    var b: ScopeSet = .{};
    defer b.deinit(alloc);

    // empty ⊆ anything
    try std.testing.expect(a.subsetOf(b));
    try std.testing.expect(b.subsetOf(a));
    try std.testing.expect(a.eq(b));

    try a.add(alloc, 1);
    try a.add(alloc, 3);

    try b.add(alloc, 1);
    try b.add(alloc, 2);
    try b.add(alloc, 3);

    try std.testing.expect(a.subsetOf(b)); // {1,3} ⊆ {1,2,3}
    try std.testing.expect(!b.subsetOf(a)); // {1,2,3} ⊄ {1,3}
    try std.testing.expect(!a.eq(b));

    var c = try a.clone(alloc);
    defer c.deinit(alloc);
    try std.testing.expect(c.eq(a));
    try std.testing.expect(c.subsetOf(a));
    try std.testing.expect(a.subsetOf(c));
}

test "ScopeSet intersect" {
    const alloc = std.testing.allocator;
    var a: ScopeSet = .{};
    defer a.deinit(alloc);
    var b: ScopeSet = .{};
    defer b.deinit(alloc);

    try a.add(alloc, 1);
    try a.add(alloc, 3);
    try a.add(alloc, 5);

    try b.add(alloc, 2);
    try b.add(alloc, 3);
    try b.add(alloc, 5);
    try b.add(alloc, 7);

    var inter = try a.intersect(b, alloc);
    defer inter.deinit(alloc);
    try std.testing.expectEqualSlices(ScopeId, &[_]ScopeId{ 3, 5 }, inter.slice());

    var disjoint: ScopeSet = .{};
    defer disjoint.deinit(alloc);
    try disjoint.add(alloc, 100);

    var inter2 = try a.intersect(disjoint, alloc);
    defer inter2.deinit(alloc);
    try std.testing.expect(inter2.isEmpty());
}

test "ScopeSet primary returns innermost (largest id)" {
    const alloc = std.testing.allocator;
    var set: ScopeSet = .{};
    defer set.deinit(alloc);

    try std.testing.expectEqual(@as(?ScopeId, null), set.primary());

    try set.add(alloc, 5);
    try set.add(alloc, 100);
    try set.add(alloc, 50);
    try std.testing.expectEqual(@as(?ScopeId, 100), set.primary());
}

test "scope graph native type registry" {
    var graph = ScopeGraph.init(std.testing.allocator);
    defer graph.deinit();

    const list_name: ast.StringId = 11;
    const map_name: ast.StringId = 12;
    const other_name: ast.StringId = 13;

    // Lookup before registration returns null.
    try std.testing.expectEqual(@as(?ast.StringId, null), graph.nativeTypeStructName(.list));
    try std.testing.expect(!graph.isNativeTypeName(.list, list_name));

    graph.registerNativeType(.list, list_name);
    graph.registerNativeType(.map, map_name);

    try std.testing.expectEqual(list_name, graph.nativeTypeStructName(.list).?);
    try std.testing.expectEqual(map_name, graph.nativeTypeStructName(.map).?);

    try std.testing.expect(graph.isNativeTypeName(.list, list_name));
    try std.testing.expect(graph.isNativeTypeName(.map, map_name));
    try std.testing.expect(!graph.isNativeTypeName(.list, map_name));
    try std.testing.expect(!graph.isNativeTypeName(.list, other_name));

    // Registration is first-wins so callers get a stable answer.
    graph.registerNativeType(.list, other_name);
    try std.testing.expectEqual(list_name, graph.nativeTypeStructName(.list).?);
    try std.testing.expect(!graph.isNativeTypeName(.list, other_name));

    // classifyNativeType reverse-lookup.
    try std.testing.expectEqual(NativeTypeKind.list, graph.classifyNativeType(list_name).?);
    try std.testing.expectEqual(NativeTypeKind.map, graph.classifyNativeType(map_name).?);
    try std.testing.expectEqual(@as(?NativeTypeKind, null), graph.classifyNativeType(other_name));
}

// ============================================================
// resolveBindingByScopes — Flatt-2016 hygiene resolution
//
// These tests build Binding rows directly into a ScopeGraph rather
// than going through the parser/collector, exercising the resolver
// algebra in isolation.
// ============================================================

/// Test helper: append a Binding with an explicit scope set onto the
/// graph's bindings list, bypassing scope-table registration. The
/// resolver under test only consults `graph.bindings`, so this is the
/// minimal setup that lets a test assert behaviour against synthetic
/// binding rows.
fn testAppendBindingWithScopes(
    graph: *ScopeGraph,
    name: ast.StringId,
    scopes: ScopeSet,
) !BindingId {
    const id: BindingId = @intCast(graph.bindings.items.len);
    try graph.bindings.append(graph.allocator, .{
        .id = id,
        .name = name,
        .scope_id = 0,
        .kind = .variable,
        .span = .{ .start = 0, .end = 0 },
        .scopes = scopes,
    });
    return id;
}

test "resolveBindingByScopes returns null when no binding matches name" {
    const alloc = std.testing.allocator;
    var graph = ScopeGraph.init(alloc);
    defer graph.deinit();

    var binding_scopes: ScopeSet = .{};
    defer binding_scopes.deinit(alloc);
    try binding_scopes.add(alloc, 1);

    _ = try testAppendBindingWithScopes(&graph, 100, binding_scopes);

    var ref_scopes: ScopeSet = .{};
    defer ref_scopes.deinit(alloc);
    try ref_scopes.add(alloc, 1);

    // Different name → no match.
    try std.testing.expectEqual(@as(?BindingId, null), graph.resolveBindingByScopes(ref_scopes, 999));
}

test "resolveBindingByScopes picks the binding whose scopes is the largest subset" {
    const alloc = std.testing.allocator;
    var graph = ScopeGraph.init(alloc);
    defer graph.deinit();

    const name: ast.StringId = 42;

    // Outer binding: {1}
    var outer_scopes: ScopeSet = .{};
    defer outer_scopes.deinit(alloc);
    try outer_scopes.add(alloc, 1);
    const outer_id = try testAppendBindingWithScopes(&graph, name, outer_scopes);

    // Inner binding: {1, 2} — strictly more specific.
    var inner_scopes: ScopeSet = .{};
    defer inner_scopes.deinit(alloc);
    try inner_scopes.add(alloc, 1);
    try inner_scopes.add(alloc, 2);
    const inner_id = try testAppendBindingWithScopes(&graph, name, inner_scopes);

    // Reference inside inner: {1, 2, 3} — both bindings are subsets.
    var ref_scopes: ScopeSet = .{};
    defer ref_scopes.deinit(alloc);
    try ref_scopes.add(alloc, 1);
    try ref_scopes.add(alloc, 2);
    try ref_scopes.add(alloc, 3);

    const resolved = graph.resolveBindingByScopes(ref_scopes, name);
    try std.testing.expectEqual(@as(?BindingId, inner_id), resolved);

    // Reference at outer level: {1} — only the outer binding qualifies.
    var outer_ref: ScopeSet = .{};
    defer outer_ref.deinit(alloc);
    try outer_ref.add(alloc, 1);

    try std.testing.expectEqual(@as(?BindingId, outer_id), graph.resolveBindingByScopes(outer_ref, name));
}

test "resolveBindingByScopes returns null on ambiguity (tied maximal subsets)" {
    const alloc = std.testing.allocator;
    var graph = ScopeGraph.init(alloc);
    defer graph.deinit();

    const name: ast.StringId = 7;

    // Two bindings whose scope sets have the same size but cover
    // different scopes. Both are subsets of the reference; neither
    // dominates the other.
    var a_scopes: ScopeSet = .{};
    defer a_scopes.deinit(alloc);
    try a_scopes.add(alloc, 1);

    var b_scopes: ScopeSet = .{};
    defer b_scopes.deinit(alloc);
    try b_scopes.add(alloc, 2);

    _ = try testAppendBindingWithScopes(&graph, name, a_scopes);
    _ = try testAppendBindingWithScopes(&graph, name, b_scopes);

    var ref_scopes: ScopeSet = .{};
    defer ref_scopes.deinit(alloc);
    try ref_scopes.add(alloc, 1);
    try ref_scopes.add(alloc, 2);

    // Ambiguity contract: returns null. Caller is expected to surface
    // a diagnostic with the candidate spans.
    try std.testing.expectEqual(@as(?BindingId, null), graph.resolveBindingByScopes(ref_scopes, name));
}

test "resolveBindingByScopes ignores bindings whose scopes are NOT a subset of the reference" {
    const alloc = std.testing.allocator;
    var graph = ScopeGraph.init(alloc);
    defer graph.deinit();

    const name: ast.StringId = 13;

    // Binding tagged with a scope that the reference does not carry.
    // This is the macro-introduced-name vs user-reference case: the
    // user reference must not see the macro's hidden binding.
    var hidden_scopes: ScopeSet = .{};
    defer hidden_scopes.deinit(alloc);
    try hidden_scopes.add(alloc, 99);

    _ = try testAppendBindingWithScopes(&graph, name, hidden_scopes);

    // A second binding the reference CAN see — empty set ⊆ anything.
    var visible_scopes: ScopeSet = .{};
    defer visible_scopes.deinit(alloc);
    const visible_id = try testAppendBindingWithScopes(&graph, name, visible_scopes);

    var ref_scopes: ScopeSet = .{};
    defer ref_scopes.deinit(alloc);
    try ref_scopes.add(alloc, 1);
    try ref_scopes.add(alloc, 2);

    const resolved = graph.resolveBindingByScopes(ref_scopes, name);
    try std.testing.expectEqual(@as(?BindingId, visible_id), resolved);

    // With NO visible binding, the result must be null even though the
    // hidden binding shares the name.
    var graph2 = ScopeGraph.init(alloc);
    defer graph2.deinit();

    var hidden2: ScopeSet = .{};
    defer hidden2.deinit(alloc);
    try hidden2.add(alloc, 99);
    _ = try testAppendBindingWithScopes(&graph2, name, hidden2);

    try std.testing.expectEqual(@as(?BindingId, null), graph2.resolveBindingByScopes(ref_scopes, name));
}
