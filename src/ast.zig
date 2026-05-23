const std = @import("std");
const Token = @import("token.zig").Token;
const scope_mod = @import("scope.zig");

// ============================================================
// Source span and metadata
// ============================================================

pub const SourceSpan = struct {
    start: u32,
    end: u32,
    line: u32 = 0,
    col: u32 = 0,
    source_id: ?u32 = null,

    pub fn from(loc: Token.Location) SourceSpan {
        return .{ .start = loc.start, .end = loc.end, .line = loc.line, .col = loc.col, .source_id = loc.source_id };
    }

    pub fn merge(a: SourceSpan, b: SourceSpan) SourceSpan {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = a.line,
            .col = a.col,
            .source_id = a.source_id,
        };
    }
};

/// Per-AST-node metadata. Four channels:
///
/// 1. `span` — source location for diagnostics.
/// 2. `scope_id` — the legacy "owning lexical scope" handle. Several
///    consumers conflate this with hygiene marking (e.g. clause-owning
///    scope vs macro-introduction tag); splitting those is callsite
///    work that is sequenced after the ScopeSet plumbing lands. KEEP
///    during the transition.
/// 3. `scopes` — Flatt-2016 set of scopes attached to identifiers and
///    syntax fragments. Macro expansion adds, removes, and flips
///    members; resolution picks the binding whose `scopes` is the
///    largest subset of the reference's `scopes`. Defaults to the
///    empty set so existing AST construction sites that don't know
///    about hygiene compile unchanged.
/// 4. `expansion` — provenance pointer for macro-expanded nodes. Null
///    for source-level nodes (the common case). When set, points at a
///    long-lived `ExpansionInfo` describing the macro call that
///    produced this node. Diagnostic-only: existing semantic passes
///    do not consult this field. See `ExpansionInfo` below.
pub const NodeMeta = struct {
    span: SourceSpan,
    scope_id: u32 = 0,
    scopes: scope_mod.ScopeSet = .empty,
    expansion: ?*const ExpansionInfo = null,

    /// Most-specific scope in the hygiene set, used by lowering passes
    /// that still want a single ScopeId handle as a fallback. Returns
    /// null when the set is empty (the common case before any macro
    /// expansion has tagged the node).
    pub fn primaryScope(self: NodeMeta) ?scope_mod.ScopeId {
        return self.scopes.primary();
    }

    /// The span to attribute this node to in user-facing debug output
    /// (DWARF line entries, crash-report backtraces). For a source-level
    /// node this is its own `span`. For a macro-expanded node it is the
    /// OUTERMOST macro call site — the place in user source where the
    /// (possibly nested) macro invocation was written — so a backtrace
    /// frame inside macro-generated code points at the user's call, not
    /// the macro template body in `kernel.zap`. This mirrors how Rust's
    /// `#[track_caller]` and Elixir's macro location handling attribute
    /// expanded code to its invocation site.
    pub fn debugSpan(self: NodeMeta) SourceSpan {
        const info = self.expansion orelse return self.span;
        return info.outermostCallSite();
    }
};

/// Reference to a source-level binding that was substituted away by a
/// macro. Carries enough information for an LSP server to round-trip
/// the binding back to its source position and (optionally) its scope.
pub const BindingRef = struct {
    name: StringId,
    span: SourceSpan,
    scope_id: u32,
};

/// Provenance information attached (via `NodeMeta.expansion`) to every
/// AST node produced by a macro expansion. The pointer is shared by all
/// nodes in a single expansion frame so a tool can identify "everything
/// that came from THIS macro call" by pointer-equality.
///
/// The `parent` chain links nested expansions: if macro `B` is invoked
/// inside the expansion of macro `A`, `B`'s `ExpansionInfo.parent` points
/// at `A`'s `ExpansionInfo`. Following `parent` to null walks the
/// expansion stack back out to user source.
///
/// `disappeared_uses` and `disappeared_bindings` are intentionally
/// stubbed empty for the MVP. The macro engine does not yet track which
/// source-level identifiers were consumed by a macro without being
/// re-emitted. Populating them precisely will be driven by a real LSP
/// consumer; stubbing them empty now keeps the data model fixed while
/// avoiding wrong-format churn later.
///
/// References:
///   - Matthew Flatt, "Bindings as Sets of Scopes" (POPL 2016).
///   - Racket's `'disappeared-use` / `'disappeared-binding` syntax
///     properties — the model these fields mirror.
pub const ExpansionInfo = struct {
    /// Source span of the macro-call expression that triggered this
    /// expansion. Used by Go-to-Definition to jump from a synthesized
    /// node back to its call site.
    call_site: SourceSpan,
    /// Interned name of the macro that was invoked.
    macro_name: StringId,
    /// Source-level identifier spans the macro consumed without
    /// re-emitting them in the expansion. Empty in the MVP — see the
    /// type-level doc comment.
    disappeared_uses: []const SourceSpan = &.{},
    /// Source-level binders the macro absorbed (e.g. desugared away).
    /// Empty in the MVP — see the type-level doc comment.
    disappeared_bindings: []const BindingRef = &.{},
    /// Parent expansion frame for nested macros. Null for an expansion
    /// triggered from user source (the outermost frame).
    parent: ?*const ExpansionInfo = null,

    /// Walk the `parent` chain to the outermost expansion frame and return
    /// its `call_site` — the span in genuine user source where the macro
    /// invocation was written. For a single-level expansion this is just
    /// `self.call_site`; for a macro that expanded into another macro it is
    /// the user-source call of the outermost macro. This is the span debug
    /// output should attribute expanded nodes to.
    pub fn outermostCallSite(self: *const ExpansionInfo) SourceSpan {
        var frame: *const ExpansionInfo = self;
        while (frame.parent) |parent_frame| frame = parent_frame;
        return frame.call_site;
    }
};

pub fn makeMeta(span: SourceSpan) NodeMeta {
    return .{ .span = span };
}

/// Whether a binding name follows the user-discard convention (Elixir-
/// style `_name` for "intentionally unused"). Compiler-synthesised names
/// use a double-underscore prefix (e.g. `__next_state`, `__loop_raw`,
/// `__err`, `__state`, `__loop_raw`) and must NOT be treated as discards
/// — they back generated bindings that downstream lowering passes
/// reference. The bare wildcard `_` is parsed as a wildcard pattern, not
/// a bind, so it never reaches this helper.
pub fn isDiscardBindName(name: []const u8) bool {
    return name.len >= 2 and name[0] == '_' and name[1] != '_';
}

// ============================================================
// String interning
// ============================================================

pub const StringId = u32;

pub const StringInterner = struct {
    allocator: std.mem.Allocator,
    /// Each entry is owned by the interner — `intern` duplicates the
    /// caller's input via `allocator.dupe` so the stored slice has the
    /// interner's lifetime rather than the caller's. This is mandatory:
    /// many callers pass short-lived buffers (`ArrayList.items`, parser
    /// scratch, format temporaries) and would otherwise leave the
    /// interner holding dangling pointers as soon as those buffers go
    /// out of scope. The same duplicated slice is used as both the
    /// `strings.items[id]` entry and the `map` key so a single free in
    /// `deinit` cleans up both.
    strings: std.ArrayList([]u8),
    map: std.StringHashMap(StringId),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator) StringInterner {
        return .{
            .allocator = allocator,
            .strings = .empty,
            .map = std.StringHashMap(StringId).init(allocator),
        };
    }

    pub fn deinit(self: *StringInterner) void {
        for (self.strings.items) |buf| self.allocator.free(buf);
        self.strings.deinit(self.allocator);
        self.map.deinit();
    }

    pub fn intern(self: *StringInterner, str: []const u8) !StringId {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        // Lookup uses the caller's slice as a transient key; the
        // hashmap hashes the bytes immediately and the duplicated
        // entry below replaces the transient slice as the map's
        // permanent key.
        if (self.map.get(str)) |id| {
            return id;
        }
        const id: StringId = @intCast(self.strings.items.len);
        const owned = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(owned);
        try self.strings.append(self.allocator, owned);
        errdefer _ = self.strings.pop();
        try self.map.put(owned, id);
        return id;
    }

    pub fn get(self: *const StringInterner, id: StringId) []const u8 {
        const mutex_ptr = @constCast(&self.mutex);
        while (!mutex_ptr.tryLock()) std.atomic.spinLoopHint();
        defer mutex_ptr.unlock();
        return self.strings.items[id];
    }

    /// Look up a string's ID without interning a new entry. Returns null
    /// when the string isn't already present. Lets `*const StringInterner`
    /// holders (e.g. TypeChecker) ask "is this name registered?" without
    /// being upgraded to a mutable pointer.
    pub fn lookupExisting(self: *const StringInterner, str: []const u8) ?StringId {
        const mutex_ptr = @constCast(&self.mutex);
        while (!mutex_ptr.tryLock()) std.atomic.spinLoopHint();
        defer mutex_ptr.unlock();
        return self.map.get(str);
    }
};

// ============================================================
// Top-level program
// ============================================================

pub const Program = struct {
    structs: []const StructDecl,
    top_items: []const TopItem,
};

pub const TopItem = union(enum) {
    struct_decl: *const StructDecl,
    priv_struct_decl: *const StructDecl,
    protocol: *const ProtocolDecl,
    priv_protocol: *const ProtocolDecl,
    impl_decl: *const ImplDecl,
    priv_impl_decl: *const ImplDecl,
    /// `pub error Name { ... }` — public matchable error type. Carried as
    /// a distinct top-item kind so the front-end desugar pass
    /// (`src/desugar.zig`) can recognise the declaration form and rewrite
    /// it to `pub struct Name + pub impl Error for Name` before any
    /// downstream stage sees it. After desugar there is no `ErrorDecl`
    /// left in the program.
    error_decl: *const ErrorDecl,
    /// Bare `error Name { ... }` — private renderable-only error type.
    /// Same desugar treatment as `error_decl`, but the resulting struct
    /// and impl are non-`pub` so the type cannot be matched from outside
    /// its declaring file/module.
    priv_error_decl: *const ErrorDecl,
    type_decl: *const TypeDecl,
    opaque_decl: *const OpaqueDecl,
    union_decl: *const UnionDecl,
    function: *const FunctionDecl,
    priv_function: *const FunctionDecl,
    macro: *const FunctionDecl,
    priv_macro: *const FunctionDecl,
    attribute: *const AttributeDecl,
};

// ============================================================
// Names
// ============================================================

pub const StructName = struct {
    parts: []const StringId,
    span: SourceSpan,

    /// Render this struct name in its canonical dotted form
    /// (`Foo.Bar.Baz`). The dotted form is the user-facing
    /// representation used wherever structs are addressed
    /// textually — diagnostics, the `struct_programs` registry,
    /// and the runtime bridge. Single-segment names return the
    /// interned string directly without copying; multi-segment
    /// names allocate a fresh slice owned by `alloc`.
    pub fn toDottedString(
        self: StructName,
        alloc: std.mem.Allocator,
        interner: *const StringInterner,
    ) ![]const u8 {
        return self.joinedWith(alloc, interner, ".");
    }

    /// Join the segments of this struct name using `separator`. Used by
    /// the IR/ZIR layers which need `_`-joined prefixes (e.g. `Foo_Bar` for
    /// the function-name prefix of `Foo.Bar.add/2`) and by the type-checker
    /// path that mangles names with `__`. Single-segment names allocate a
    /// fresh dup so the caller can free uniformly.
    pub fn joinedWith(
        self: StructName,
        alloc: std.mem.Allocator,
        interner: *const StringInterner,
        separator: []const u8,
    ) ![]const u8 {
        if (self.parts.len == 0) return alloc.alloc(u8, 0);
        if (self.parts.len == 1) return alloc.dupe(u8, interner.get(self.parts[0]));
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (self.parts, 0..) |part, i| {
            if (i > 0) try buf.appendSlice(alloc, separator);
            try buf.appendSlice(alloc, interner.get(part));
        }
        return buf.toOwnedSlice(alloc);
    }
};

// ============================================================
// Protocol declarations
// ============================================================

pub const ProtocolDecl = struct {
    meta: NodeMeta,
    name: StructName,
    type_params: []const StringId = &.{},
    functions: []const ProtocolFunctionSig,
    is_private: bool = false,
};

pub const ProtocolFunctionSig = struct {
    meta: NodeMeta,
    name: StringId,
    params: []const ProtocolParam,
    return_type: ?*const TypeExpr,
};

pub const ProtocolParam = struct {
    meta: NodeMeta,
    name: StringId,
    type_annotation: ?*const TypeExpr,
};

// ============================================================
// Impl declarations
// ============================================================

pub const ImplDecl = struct {
    meta: NodeMeta,
    protocol_name: StructName,
    /// Type arguments supplied to the protocol being implemented, e.g.
    /// `element` in `impl Enumerable(element) for List(element)`.
    protocol_type_args: []const *const TypeExpr = &.{},
    target_type: StructName,
    /// Type parameters declared on the impl header, e.g. `K, V` in
    /// `impl Enumerable for Map(K, V)`. Empty when the target type is
    /// concrete. These names are bound as type variables inside the
    /// impl's function signatures so the same parameter symbol resolves
    /// to the same type variable across params and return type.
    type_params: []const StringId = &.{},
    functions: []const *const FunctionDecl,
    is_private: bool = false,
};

pub const StructItem = union(enum) {
    type_decl: *const TypeDecl,
    opaque_decl: *const OpaqueDecl,
    struct_decl: *const StructDecl,
    union_decl: *const UnionDecl,
    function: *const FunctionDecl,
    priv_function: *const FunctionDecl,
    macro: *const FunctionDecl,
    priv_macro: *const FunctionDecl,
    alias_decl: *const AliasDecl,
    import_decl: *const ImportDecl,
    use_decl: *const UseDecl,
    attribute: *const AttributeDecl,
    /// Expression at struct level (e.g., macro calls like describe/test).
    /// Collected into an auto-generated run/0 function by desugaring.
    struct_level_expr: *const Expr,
};

// ============================================================
// Type declarations
// ============================================================

pub const TypeDecl = struct {
    meta: NodeMeta,
    name: StringId,
    params: []const TypeParam,
    body: *const TypeExpr,
};

pub const OpaqueDecl = struct {
    meta: NodeMeta,
    name: StringId,
    params: []const TypeParam,
    body: *const TypeExpr,
};

pub const TypeParam = struct {
    meta: NodeMeta,
    name: StringId,
};

// ============================================================
// Struct declarations
// ============================================================

pub const StructDecl = struct {
    meta: NodeMeta,
    name: StructName,
    parent: ?StringId = null,
    /// Optional type parameters declared on the struct header, e.g. `T` in
    /// `pub struct Box(T) { value :: T }`. Each entry is a bare type-variable
    /// name visible inside the struct's field type expressions, function
    /// signatures, and field-default expressions. Empty when the struct is
    /// concrete (the common case). Mirrors `ImplDecl.type_params`.
    type_params: []const StringId = &.{},
    items: []const StructItem = &.{},
    fields: []const StructFieldDecl = &.{},
    is_private: bool = false,
};

pub const StructFieldDecl = struct {
    meta: NodeMeta,
    name: StringId,
    type_expr: *const TypeExpr,
    default: ?*const Expr,
};

// ============================================================
// Union declarations
// ============================================================

pub const UnionDecl = struct {
    meta: NodeMeta,
    name: StringId,
    /// Optional type parameters declared on the union header, e.g. `T` in
    /// `pub union Option(T) { Some(T), None }` or `T, E` in
    /// `pub union Result(T, E) { Ok(T), Error(E) }`. Each entry is a bare
    /// type-variable name visible inside the union's variant payload type
    /// expressions. Empty for concrete unions like `union Color { Red, Green }`.
    /// Mirrors `ImplDecl.type_params` and `StructDecl.type_params`.
    type_params: []const StringId = &.{},
    variants: []const UnionVariant,
    is_private: bool = false,
};

pub const UnionVariant = struct {
    meta: NodeMeta,
    name: StringId,
    type_expr: ?*const TypeExpr = null, // null = unit variant
};

// ============================================================
// Error declarations
// ============================================================

/// `pub error Name { ... }` / `error Name { ... }` — the canonical
/// declaration form for an exception type. Mirrors `StructDecl` in shape:
/// optional type parameters (parametric errors via the 1.1.5 machinery),
/// a body of fields with optional defaults, and a body of inline
/// methods. The front-end-only desugar (`src/desugar.zig`) rewrites this
/// node into a `StructDecl` with the user fields plus auto-injected
/// `message :: String = "<TypeName>"` and `cause :: Option(Error) = Option.None`,
/// together with an `ImplDecl` for `Error for Name` whose `message`,
/// `kind`, `source`, and `code` methods are auto-generated. After desugar
/// no downstream stage sees `ErrorDecl` — the rest of the pipeline only
/// looks at the produced struct + impl.
pub const ErrorDecl = struct {
    meta: NodeMeta,
    /// Name of the error type. Single-segment in the MVP, kept as a
    /// `StructName` so future dotted forms (`MyApp.ParseError`) don't
    /// require AST churn.
    name: StructName,
    /// Optional parametric header (`pub error DeserializeError(T) { ... }`).
    /// Empty for concrete errors; the desugar propagates these to the
    /// generated `StructDecl` and `ImplDecl` so the existing 1.1.5
    /// parametric machinery picks them up untouched.
    type_params: []const StringId = &.{},
    /// Items declared inside the body. Restricted to `pub fn` / `fn`
    /// declarations and `@doc` / `@code` attributes — the parser refuses
    /// nested structs, unions, type/alias/import/use. The desugar walks
    /// these to discover inline-method overrides for `Error` protocol
    /// methods and to forward unrelated methods onto the struct itself.
    items: []const StructItem = &.{},
    /// Field declarations exactly as for `StructDecl`. The desugar
    /// preserves all user fields with their declared defaults and
    /// adds `message` / `cause` only when not already present.
    fields: []const StructFieldDecl = &.{},
    /// Value of the optional `@code Z<digits>` attribute, interned as
    /// the bareword (`"Z3041"`). `null` when the user did not supply a
    /// numeric code. The desugar wraps the present value in
    /// `Option.Some(:Zxxxx)` for the auto-generated `code/1` method and
    /// returns `Option.None` otherwise.
    code: ?StringId = null,
    /// Optional `@doc = """..."""` attached to the declaration. The
    /// desugar attaches this back to the rewritten `pub struct` so the
    /// canonical `@doc` lookup path (a struct-level `@doc` attribute
    /// item) keeps working unchanged.
    doc: ?*const AttributeDecl = null,
    is_private: bool = false,
};

// ============================================================
// Function declarations
// ============================================================

pub const FunctionDecl = struct {
    meta: NodeMeta,
    name: StringId,
    /// When non-null the function's name is determined at macro
    /// expansion time. The expression must evaluate at compile time
    /// to a string or atom; the macro engine resolves it and writes
    /// the result back into `name`. This enables
    /// `def unquote(fn_name)(args) { ... }` inside `quote { ... }`.
    /// Null means `name` was set directly by the parser.
    name_expr: ?*const Expr = null,
    clauses: []const FunctionClause,
    visibility: Visibility,

    pub const Visibility = enum { public, private };
};

pub const FunctionClause = struct {
    meta: NodeMeta,
    params: []const Param,
    return_type: ?*const TypeExpr,
    refinement: ?*const Expr,
    body: ?[]const Stmt = null,
    /// Declared error row from a `raises` annotation on the signature.
    ///
    /// `null` means the function carries no `raises` annotation — the
    /// type-checker then *infers* the row from the `?` propagation sites
    /// in the body and attaches it to the function's type. A non-null
    /// slice is the explicitly declared row: each entry is one error type
    /// expression (`raises ParseError` is a one-element slice; `raises
    /// (ParseError | IOError)` is a two-element slice). An empty non-null
    /// slice declares that the function raises nothing.
    raises: ?[]const *const TypeExpr = null,
};

pub const Ownership = enum {
    shared,
    unique,
    borrowed,
};

pub const Param = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    type_annotation: ?*const TypeExpr,
    ownership: Ownership = .shared,
    ownership_explicit: bool = false,
    default: ?*const Expr = null,
};

// ============================================================
// Macro meta-types — typed splice categories
//
// When a macro parameter is annotated with one of these names, the
// macro engine validates that the bound argument matches the
// corresponding AST shape. The default `Expr` is the most permissive
// (any expression-shaped CtValue); narrower kinds catch mistakes at
// macro-expansion time rather than at the splice site.
// ============================================================

pub const MacroSpliceKind = enum {
    /// Any expression. The default; matches anything.
    expr,
    /// A pattern (used in `case` arms or function heads).
    pattern,
    /// A type expression.
    type_expr,
    /// A declaration: `pub fn`, `pub macro`, `import`, etc.
    decl,
    /// A bare identifier (variable name or atom).
    ident,
    /// A `__block__` of statements.
    block,
    /// An atom literal (`:foo`).
    atom_lit,
    /// An integer literal.
    integer_lit,
    /// A string literal.
    string_lit,
    /// A bare list of CtValues (used by `unquote_splicing`).
    list_lit,

    /// Map an annotation name (e.g., `Expr`, `Pat`, `Decl`) to the
    /// corresponding kind. Returns `null` for non-meta-type names so
    /// the caller can fall through to ordinary type resolution.
    pub fn fromName(name: []const u8) ?MacroSpliceKind {
        if (std.mem.eql(u8, name, "Expr")) return .expr;
        if (std.mem.eql(u8, name, "Pat")) return .pattern;
        if (std.mem.eql(u8, name, "Type")) return .type_expr;
        if (std.mem.eql(u8, name, "Decl")) return .decl;
        if (std.mem.eql(u8, name, "Ident")) return .ident;
        if (std.mem.eql(u8, name, "Block")) return .block;
        if (std.mem.eql(u8, name, "AtomLit")) return .atom_lit;
        if (std.mem.eql(u8, name, "IntLit")) return .integer_lit;
        if (std.mem.eql(u8, name, "StringLit")) return .string_lit;
        if (std.mem.eql(u8, name, "ListLit")) return .list_lit;
        return null;
    }

    pub fn displayName(self: MacroSpliceKind) []const u8 {
        return switch (self) {
            .expr => "Expr",
            .pattern => "Pat",
            .type_expr => "Type",
            .decl => "Decl",
            .ident => "Ident",
            .block => "Block",
            .atom_lit => "AtomLit",
            .integer_lit => "IntLit",
            .string_lit => "StringLit",
            .list_lit => "ListLit",
        };
    }
};

// ============================================================
// Struct system directives
// ============================================================

pub const AliasDecl = struct {
    meta: NodeMeta,
    struct_path: StructName,
    as_name: ?StructName,
};

pub const ImportDecl = struct {
    meta: NodeMeta,
    struct_path: StructName,
    filter: ?ImportFilter,
};

pub const UseDecl = struct {
    meta: NodeMeta,
    struct_path: StructName,
    opts: ?*const Expr,
};

pub const ImportFilter = union(enum) {
    only: []const ImportEntry,
    except: []const ImportEntry,
};

pub const ImportEntry = union(enum) {
    function: struct {
        name: StringId,
        arity: u32,
    },
    type_import: StringId,
};

// ============================================================
// Struct attributes
// ============================================================

pub const AttributeDecl = struct {
    meta: NodeMeta,
    name: StringId,
    /// Type annotation — null for marker attributes (@name with no value)
    type_expr: ?*const TypeExpr = null,
    /// Value expression — null for marker attributes
    value: ?*const Expr = null,
};

// ============================================================
// Statements
// ============================================================

pub const Stmt = union(enum) {
    expr: *const Expr,
    assignment: *const Assignment,
    function_decl: *const FunctionDecl,
    macro_decl: *const FunctionDecl,
    import_decl: *const ImportDecl,
    attribute: *const AttributeDecl,
    /// `defer <expr>` / `errdefer <expr>` (Phase 2.d). Schedules a
    /// cleanup expression to run at the enclosing block's scope exit.
    defer_stmt: *const DeferStmt,
};

/// Which value-return paths a scheduled cleanup runs on (Phase 2.d).
pub const DeferKind = enum {
    /// `defer` — runs on EVERY value-return path (normal fall-through
    /// return AND the `?` Error early-return).
    always,
    /// `errdefer` — runs ONLY on an error-return path (the `?` Error
    /// early-return). Skipped on the normal/success path.
    on_error,
};

/// A `defer <expr>` or `errdefer <expr>` statement (Phase 2.d).
///
/// The cleanup `expr` is NOT evaluated where it is written; it is
/// recorded onto the enclosing block's LIFO cleanup stack and lowered
/// (re-read against its captured locals' exit-time values) at each
/// scope-exit edge — matching Zig's `defer`/`errdefer` model. `defer`
/// and `errdefer` share ONE stack; on the success path the `errdefer`
/// entries are skipped, on the `?` Error early-return path they fire.
pub const DeferStmt = struct {
    meta: NodeMeta,
    kind: DeferKind,
    expr: *const Expr,
};

pub const Assignment = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    value: *const Expr,
};

// ============================================================
// Expressions
// ============================================================

pub const Expr = union(enum) {
    // Literals
    int_literal: IntLiteral,
    float_literal: FloatLiteral,
    string_literal: StringLiteral,
    string_interpolation: StringInterpolation,
    atom_literal: AtomLiteral,
    bool_literal: BoolLiteral,
    nil_literal: NilLiteral,

    // References
    var_ref: VarRef,
    struct_ref: StructRef,

    // Compound literals
    tuple: TupleExpr,
    list: ListExpr,
    map: MapExpr,
    struct_expr: StructExpr,
    range: RangeExpr,

    // Operations
    binary_op: BinaryOp,
    unary_op: UnaryOp,
    call: CallExpr,
    field_access: FieldAccess,
    pipe: PipeExpr,
    unwrap: UnwrapExpr,

    // Control flow
    if_expr: IfExpr,
    case_expr: CaseExpr,
    cond_expr: CondExpr,
    for_expr: ForExpr,
    with_expr: WithExpr,

    // List construction
    list_cons_expr: ListConsExpr,

    // Macros
    quote_expr: QuoteExpr,
    unquote_expr: UnquoteExpr,
    unquote_splicing_expr: UnquoteSplicingExpr,

    // Error handling
    panic_expr: PanicExpr,
    raise_expr: RaiseExpr,
    error_pipe: ErrorPipeExpr,
    try_expr: TryExpr,
    try_rescue: TryRescueExpr,

    // Block
    block: BlockExpr,

    // Intrinsics
    intrinsic: IntrinsicExpr,

    // Attribute reference: @name in expression position
    attr_ref: AttrRefExpr,

    // Binary literal: <<1, 2, 3>>
    binary_literal: BinaryLiteral,

    // Function reference: Struct.func/arity
    function_ref: FunctionRefExpr,

    // Anonymous function expression
    anonymous_function: AnonymousFunctionExpr,

    // Type annotation on expression: expr :: Type
    type_annotated: TypeAnnotatedExpr,

    pub fn getMeta(self: *const Expr) NodeMeta {
        return switch (self.*) {
            .int_literal => |v| v.meta,
            .float_literal => |v| v.meta,
            .string_literal => |v| v.meta,
            .string_interpolation => |v| v.meta,
            .atom_literal => |v| v.meta,
            .bool_literal => |v| v.meta,
            .nil_literal => |v| v.meta,
            .var_ref => |v| v.meta,
            .struct_ref => |v| v.meta,
            .tuple => |v| v.meta,
            .list => |v| v.meta,
            .map => |v| v.meta,
            .struct_expr => |v| v.meta,
            .range => |v| v.meta,
            .binary_op => |v| v.meta,
            .unary_op => |v| v.meta,
            .call => |v| v.meta,
            .field_access => |v| v.meta,
            .pipe => |v| v.meta,
            .unwrap => |v| v.meta,
            .if_expr => |v| v.meta,
            .case_expr => |v| v.meta,
            .cond_expr => |v| v.meta,
            .for_expr => |v| v.meta,
            .with_expr => |v| v.meta,
            .list_cons_expr => |v| v.meta,
            .quote_expr => |v| v.meta,
            .unquote_expr => |v| v.meta,
            .unquote_splicing_expr => |v| v.meta,
            .panic_expr => |v| v.meta,
            .raise_expr => |v| v.meta,
            .error_pipe => |v| v.meta,
            .try_expr => |v| v.meta,
            .try_rescue => |v| v.meta,
            .block => |v| v.meta,
            .intrinsic => |v| v.meta,
            .attr_ref => |v| v.meta,
            .binary_literal => |v| v.meta,
            .function_ref => |v| v.meta,
            .anonymous_function => |v| v.meta,
            .type_annotated => |v| v.meta,
        };
    }
};

pub const IntLiteral = struct {
    meta: NodeMeta,
    value: i64,
};

pub const FloatLiteral = struct {
    meta: NodeMeta,
    value: f64,
};

pub const StringLiteral = struct {
    meta: NodeMeta,
    value: StringId,
};

pub const StringInterpolation = struct {
    meta: NodeMeta,
    parts: []const StringPart,
};

pub const StringPart = union(enum) {
    literal: StringId,
    expr: *const Expr,
};

pub const AtomLiteral = struct {
    meta: NodeMeta,
    value: StringId,
};

pub const BoolLiteral = struct {
    meta: NodeMeta,
    value: bool,
};

pub const NilLiteral = struct {
    meta: NodeMeta,
};

pub const VarRef = struct {
    meta: NodeMeta,
    name: StringId,
};

pub const StructRef = struct {
    meta: NodeMeta,
    name: StructName,

    /// Type arguments attached to a parametric struct/union receiver
    /// at the use site, e.g. the `(i64)` in `Option(i64).Some(42)`,
    /// `Option(i64).None`, or `%Option(i64).Some(42)`. Empty for every
    /// non-parametric reference — keeping the slice optional via an
    /// empty default preserves the existing `Color.Red` shape used by
    /// concrete enum/tagged-union variant constructors. When non-empty
    /// the receiver name's leading parts identify the parametric base
    /// (e.g. `Option`) and the trailing part identifies the variant
    /// (e.g. `Some`) — exactly the shape the HIR variant matcher
    /// expects, with the type-args bridging through to per-instantiation
    /// substitution.
    type_args: []const *const TypeExpr = &.{},
};

pub const TupleExpr = struct {
    meta: NodeMeta,
    elements: []const *const Expr,
};

pub const ListExpr = struct {
    meta: NodeMeta,
    elements: []const *const Expr,
};

pub const MapExpr = struct {
    meta: NodeMeta,
    update_source: ?*const Expr = null,
    fields: []const MapField,
};

pub const MapField = struct {
    key: *const Expr,
    value: *const Expr,
};

pub const StructExpr = struct {
    meta: NodeMeta,
    struct_name: StructName,
    /// Optional generic type arguments supplied at the instantiation
    /// site, e.g. `i64` in `%Box(i64){value: 42}`. Empty for concrete
    /// struct literals (the common case). The parser only populates
    /// this when the source writes `(...)` directly after the struct
    /// name and before the `{` body. Validation that the count
    /// matches the declaration's `type_params` arity happens in the
    /// type checker (see `inferStructExprType`).
    type_args: []const *const TypeExpr = &.{},
    /// True when the user wrote an explicit `(...)` (possibly empty)
    /// after the struct name. Combined with `type_args.len == 0`, this
    /// distinguishes `%Box{...}` (no parens — defer to context-driven
    /// inference) from `%Box(){...}` (explicit empty parens — an arity
    /// error against a parametric declaration). Without this flag both
    /// forms would parse to the same AST and the latter would silently
    /// fall through to the inference path.
    type_args_parens_present: bool = false,
    update_source: ?*const Expr,
    fields: []const StructField,
};

pub const StructField = struct {
    name: StringId,
    value: *const Expr,
};

pub const RangeExpr = struct {
    meta: NodeMeta,
    start: *const Expr,
    end: *const Expr,
    step: ?*const Expr,
};

pub const BinaryOp = struct {
    meta: NodeMeta,
    op: Op,
    lhs: *const Expr,
    rhs: *const Expr,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        rem_op,
        equal,
        not_equal,
        less,
        greater,
        less_equal,
        greater_equal,
        and_op,
        or_op,
        concat, // <>
        in_op, // in
    };
};

pub const UnaryOp = struct {
    meta: NodeMeta,
    op: Op,
    operand: *const Expr,

    pub const Op = enum {
        negate,
        not_op,
    };
};

pub const CallExpr = struct {
    meta: NodeMeta,
    callee: *const Expr,
    args: []const *const Expr,
};

pub const FieldAccess = struct {
    meta: NodeMeta,
    object: *const Expr,
    field: StringId,
};

pub const PipeExpr = struct {
    meta: NodeMeta,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const UnwrapExpr = struct {
    meta: NodeMeta,
    expr: *const Expr,
};

/// Postfix `?` Result-propagation operator: `value?`.
///
/// Desugars (in `src/desugar.zig`) into the canonical two-arm
/// `case` over `Result(t, e)`:
///
///     case value {
///       Result.Ok(__try_ok) -> __try_ok
///       Result.Error(__try_err) -> return Result.Error(__try_err)
///     }
///
/// The `Ok` arm yields the success payload; the `Error` arm
/// re-wraps the failure payload and early-returns it from the
/// enclosing function. Because the desugar targets `case`, the
/// existing tagged-union match pipeline
/// (`buildUnionSwitchFromVariantNode` → `union_switch` →
/// comptime-safe `switch_block`) lowers `?` with no new HIR/IR
/// machinery: `union_switch` IS the realized form of the research
/// brief's proposed `TryProject(value, ok_var, err_var)` node.
pub const TryExpr = struct {
    meta: NodeMeta,
    /// The `Result(t, e)`-typed operand the `?` is applied to.
    value: *const Expr,
};

pub const ErrorPipeExpr = struct {
    meta: NodeMeta,
    chain: *const Expr, // the pipe chain expression
    handler: ErrorHandler,
};

pub const ErrorHandler = union(enum) {
    block: []const CaseClause, // inline pattern -> body arms
    function: *const Expr, // function call handler
};

pub const TypeAnnotatedExpr = struct {
    meta: NodeMeta,
    expr: *const Expr,
    type_expr: *const TypeExpr,
};

pub const IfExpr = struct {
    meta: NodeMeta,
    condition: *const Expr,
    then_block: []const Stmt,
    else_block: ?[]const Stmt,
};

pub const CaseExpr = struct {
    meta: NodeMeta,
    scrutinee: *const Expr,
    clauses: []const CaseClause,
};

pub const CaseClause = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    type_annotation: ?*const TypeExpr,
    guard: ?*const Expr,
    body: []const Stmt,
};

pub const CondExpr = struct {
    meta: NodeMeta,
    clauses: []const CondClause,
};

pub const CondClause = struct {
    meta: NodeMeta,
    condition: *const Expr,
    body: []const Stmt,
};

pub const ForExpr = struct {
    meta: NodeMeta,
    /// Loop variable as a full pattern. A bare identifier still parses as
    /// `Pattern.bind`, preserving the legacy `for x <- ...` form;
    /// destructuring patterns like `{k, v}` or `{:ok, n}` flow through the
    /// same lowering pipeline that powers function params and case arms.
    var_pattern: *const Pattern,
    /// Optional `:: Type` annotation on the loop variable. Mirrors the
    /// `Param.type_annotation` field so the desugar can splice both the
    /// pattern and the annotation into the generated helper clause's
    /// param slot, where the type checker resolves it through the
    /// existing param-typing path.
    var_type_annotation: ?*const TypeExpr = null,
    iterable: *const Expr,
    filter: ?*const Expr,
    body: *const Expr,
};

/// The `with` multi-step Result/pattern-match composition (Phase 3.c,
/// Elixir-style).
///
/// `with pat1 <- expr1, pat2 <- expr2 { do_body } else { clauses }`
/// sequences a series of pattern-match steps. Each step evaluates its
/// `expr` and matches it against `pattern`: on a match the binding is
/// introduced and the next step runs; on the first non-matching step
/// the whole `with` short-circuits. With an `else`, the non-matching
/// value is dispatched through the `else` clauses; without an `else`,
/// the non-matching value is the result verbatim. The `do_body` runs
/// only when every step matched.
///
/// This is pure sugar over nested `case` expressions — it is desugared
/// in `src/macro.zig` (the same bootstrap layer that lowers `if`/`cond`/
/// `and`/`or` to `case_expr`) and introduces no new HIR/IR primitive.
/// `Kernel.with` in `lib/kernel.zap` documents the surface and is the
/// user-overridable hook, mirroring how `Kernel.if` coexists with the
/// `if_expr` desugar. The `<-` step arrow reuses the `.back_arrow` token
/// already used by `for x <- list` comprehensions.
pub const WithExpr = struct {
    meta: NodeMeta,
    steps: []const WithStep,
    do_body: []const Stmt,
    /// `null` selects the else-less form (the non-matching value is the
    /// result). A non-null (possibly empty) slice selects the else form:
    /// the non-matching value is matched against these clauses.
    else_clauses: ?[]const CaseClause,
};

/// One `pattern <- expr` step of a `with` expression. The `pattern`
/// accepts the full pattern grammar (reusing `parsePattern`, like a
/// `case` arm or a `for` generator), with an optional `:: Type`
/// annotation mirroring `ForExpr.var_type_annotation`.
pub const WithStep = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    type_annotation: ?*const TypeExpr = null,
    expr: *const Expr,
};

pub const ListConsExpr = struct {
    meta: NodeMeta,
    head: *const Expr,
    tail: *const Expr,
};

pub const QuoteExpr = struct {
    meta: NodeMeta,
    body: []const Stmt,
};

pub const UnquoteExpr = struct {
    meta: NodeMeta,
    expr: *const Expr,
};

pub const UnquoteSplicingExpr = struct {
    meta: NodeMeta,
    expr: *const Expr,
};

pub const PanicExpr = struct {
    meta: NodeMeta,
    message: *const Expr,
};

/// The Error-aware `raise` keyword (Phase 1.4).
///
/// `raise <value>` aborts the program by routing `value` — which must
/// implement the `Error` protocol — through `Kernel.do_raise/1`, which
/// extracts `Error.message`/`Error.kind` and aborts non-zero. The
/// `raise "string"` shorthand is normalised in `src/desugar.zig` by
/// wrapping the string literal in a `%RuntimeError{message: <string>}`
/// struct expression, so by HIR time every `raise` carries a concrete
/// Error value. The type-checker records `value`'s type into the
/// enclosing function's inferred `raises` row; the expression's own
/// type is `Never`.
pub const RaiseExpr = struct {
    meta: NodeMeta,
    value: *const Expr,
};

/// The `try { … } rescue { pat -> … } after { … }` recoverable-error
/// handler (Phase 3.a).
///
/// `try` introduces a dynamic handler scope: a `raise` whose dynamic
/// extent is enclosed by this expression unwinds to the `rescue` arms
/// (the effect handler) instead of aborting via `crashReport`. The
/// `rescue` arms are exhaustiveness-checked pattern→body clauses on the
/// raised `Error` value — they reuse `CaseClause` so the `e :: IOError`
/// type-binding, `%IOError{kind: :x}` struct-pattern, and `_` wildcard
/// forms are parsed by the same machinery as `case`. `after` is optional
/// finally-semantics: it runs unconditionally on the normal-completion,
/// rescued, and re-raise/propagate edges (lowered through the Phase 2.d
/// `defer_stack`, ARC-correct on every edge).
///
/// The expression's type is the join of the `try` body's success type
/// and the `rescue` clause result types. Error types covered by a
/// `rescue` arm are discharged from the enclosing function's `raises`
/// row; uncovered raises propagate.
pub const TryRescueExpr = struct {
    meta: NodeMeta,
    body: []const Stmt,
    rescue_clauses: []const CaseClause,
    after_block: ?[]const Stmt,
};

pub const BlockExpr = struct {
    meta: NodeMeta,
    stmts: []const Stmt,
};

pub const IntrinsicExpr = struct {
    meta: NodeMeta,
    name: StringId,
    args: []const *const Expr,
};

pub const AttrRefExpr = struct {
    meta: NodeMeta,
    name: StringId,
};

// ============================================================
// Patterns
// ============================================================

pub const Pattern = union(enum) {
    wildcard: WildcardPattern,
    bind: BindPattern,
    literal: LiteralPattern,
    tuple: TuplePattern,
    list: ListPattern,
    list_cons: ListConsPattern,
    map: MapPattern,
    struct_pattern: StructPattern,
    pin: PinPattern,
    paren: ParenPattern,
    binary: BinaryPattern,
    tagged_union_variant: TaggedUnionVariantPattern,

    pub fn getMeta(self: *const Pattern) NodeMeta {
        return switch (self.*) {
            .wildcard => |v| v.meta,
            .bind => |v| v.meta,
            .literal => |v| v.getMeta(),
            .tuple => |v| v.meta,
            .list => |v| v.meta,
            .list_cons => |v| v.meta,
            .map => |v| v.meta,
            .struct_pattern => |v| v.meta,
            .pin => |v| v.meta,
            .paren => |v| v.meta,
            .binary => |v| v.meta,
            .tagged_union_variant => |v| v.meta,
        };
    }
};

pub const WildcardPattern = struct {
    meta: NodeMeta,
};

pub const BindPattern = struct {
    meta: NodeMeta,
    name: StringId,
};

pub const LiteralPattern = union(enum) {
    int: struct { meta: NodeMeta, value: i64 },
    float: struct { meta: NodeMeta, value: f64 },
    string: struct { meta: NodeMeta, value: StringId },
    atom: struct { meta: NodeMeta, value: StringId },
    bool_lit: struct { meta: NodeMeta, value: bool },
    nil: struct { meta: NodeMeta },

    pub fn getMeta(self: LiteralPattern) NodeMeta {
        return switch (self) {
            .int => |v| v.meta,
            .float => |v| v.meta,
            .string => |v| v.meta,
            .atom => |v| v.meta,
            .bool_lit => |v| v.meta,
            .nil => |v| v.meta,
        };
    }
};

pub const TuplePattern = struct {
    meta: NodeMeta,
    elements: []const *const Pattern,
};

pub const ListPattern = struct {
    meta: NodeMeta,
    elements: []const *const Pattern,
};

pub const ListConsPattern = struct {
    meta: NodeMeta,
    heads: []const *const Pattern,
    tail: *const Pattern,
};

pub const MapPattern = struct {
    meta: NodeMeta,
    fields: []const MapPatternField,
};

pub const MapPatternField = struct {
    key: *const Expr,
    value: *const Pattern,
};

pub const StructPattern = struct {
    meta: NodeMeta,
    struct_name: StructName,
    fields: []const StructPatternField,
};

pub const StructPatternField = struct {
    name: StringId,
    pattern: *const Pattern,
};

pub const PinPattern = struct {
    meta: NodeMeta,
    name: StringId,
};

pub const ParenPattern = struct {
    meta: NodeMeta,
    inner: *const Pattern,
};

// ============================================================
// Binary pattern matching types
// ============================================================

pub const Endianness = enum {
    big,
    little,
    native,
};

pub const BinarySegmentType = union(enum) {
    default, // bare value → u8
    integer: struct { signed: bool, bits: u16 },
    float: struct { bits: u16 },
    string,
    utf8,
    utf16,
    utf32,
};

pub const BinarySegmentSize = union(enum) {
    literal: u32,
    variable: StringId,
};

pub const BinarySegmentValue = union(enum) {
    expr: *const Expr,
    pattern: *const Pattern,
    string_literal: StringId,
};

pub const BinarySegment = struct {
    meta: NodeMeta,
    value: BinarySegmentValue,
    type_spec: BinarySegmentType,
    endianness: Endianness,
    size: ?BinarySegmentSize,
};

pub const BinaryLiteral = struct {
    meta: NodeMeta,
    segments: []const BinarySegment,
};

pub const BinaryPattern = struct {
    meta: NodeMeta,
    segments: []const BinarySegment,
};

/// A tagged-union variant pattern in case-arm position:
/// `Option.Some(v)`, `Option(i64).Some(v)`, `Option.None`, etc.
///
/// `qualifier.parts` always has at least two segments — the receiver
/// name (`Option`, `Result`, ...) followed by the variant name
/// (`Some`, `None`, `Ok`, `Err`). Multi-segment receivers like
/// `IO.Mode` are not parametric union receivers under Phase 1.1.5 and
/// never produce this pattern.
///
/// `type_args` carries explicit type arguments (`Option(i64).Some(v)`);
/// an empty slice means the receiver's instantiation is inferred from
/// the case scrutinee's type (`case opt :: Option(i64) { Option.Some(v) -> v }`).
///
/// `payload` is `null` for nullary variants (`Option.None`, `Result.Err`
/// with no payload). When the variant carries a payload, `payload`
/// holds the destructuring pattern — a `bind` for a fresh local, a
/// `wildcard` for `_`, or any other nested pattern. Multi-field
/// payloads (currently not surfaced for tagged-union variants whose
/// payloads are single typed values, but reserved for forward
/// compatibility) would carry a `tuple` pattern.
pub const TaggedUnionVariantPattern = struct {
    meta: NodeMeta,
    qualifier: StructName,
    type_args: []const *const TypeExpr = &.{},
    payload: ?*const Pattern = null,
};

pub const FunctionRefExpr = struct {
    meta: NodeMeta,
    struct_name: ?StructName, // null for local function references
    function: StringId,
    arity: u32,
};

pub const AnonymousFunctionExpr = struct {
    meta: NodeMeta,
    decl: *const FunctionDecl,
};

// ============================================================
// Type expressions
// ============================================================

pub const TypeExpr = union(enum) {
    name: TypeNameExpr,
    variable: TypeVarExpr,
    tuple: TypeTupleExpr,
    list: TypeListExpr,
    map: TypeMapExpr,
    struct_type: TypeStructExpr,
    union_type: TypeUnionExpr,
    function: TypeFunExpr,
    literal: TypeLiteralExpr,
    never: TypeNeverExpr,
    paren: TypeParenExpr,

    pub fn getMeta(self: *const TypeExpr) NodeMeta {
        return switch (self.*) {
            .name => |v| v.meta,
            .variable => |v| v.meta,
            .tuple => |v| v.meta,
            .list => |v| v.meta,
            .map => |v| v.meta,
            .struct_type => |v| v.meta,
            .union_type => |v| v.meta,
            .function => |v| v.meta,
            .literal => |v| v.meta,
            .never => |v| v.meta,
            .paren => |v| v.meta,
        };
    }
};

pub const TypeNameExpr = struct {
    meta: NodeMeta,
    name: StringId,
    args: []const *const TypeExpr,
};

pub const TypeVarExpr = struct {
    meta: NodeMeta,
    name: StringId,
};

pub const TypeTupleExpr = struct {
    meta: NodeMeta,
    elements: []const *const TypeExpr,
};

pub const TypeListExpr = struct {
    meta: NodeMeta,
    element: *const TypeExpr,
};

pub const TypeMapExpr = struct {
    meta: NodeMeta,
    fields: []const TypeMapField,
};

pub const TypeMapField = struct {
    key: *const TypeExpr,
    value: *const TypeExpr,
};

pub const TypeStructExpr = struct {
    meta: NodeMeta,
    struct_name: StructName,
    fields: []const TypeStructField,
};

pub const TypeStructField = struct {
    name: StringId,
    type_expr: *const TypeExpr,
};

pub const TypeUnionExpr = struct {
    meta: NodeMeta,
    members: []const *const TypeExpr,
};

pub const TypeFunExpr = struct {
    meta: NodeMeta,
    params: []const *const TypeExpr,
    param_ownerships: []const Ownership,
    param_ownerships_explicit: []const bool,
    return_type: *const TypeExpr,
    return_ownership: Ownership = .shared,
    return_ownership_explicit: bool = false,
};

pub const TypeLiteralExpr = struct {
    meta: NodeMeta,
    value: LiteralValue,

    pub const LiteralValue = union(enum) {
        int: i64,
        string: StringId,
        bool_val: bool,
        nil,
    };
};

pub const TypeNeverExpr = struct {
    meta: NodeMeta,
};

pub const TypeParenExpr = struct {
    meta: NodeMeta,
    inner: *const TypeExpr,
};

// ============================================================
// AST exhaustiveness tripwires
// ============================================================
//
// Adding a new variant to one of the central AST unions
// (`Expr`, `Pattern`, `TypeExpr`, `Stmt`, `StructItem`, `TopItem`)
// requires updating every visitor that walks the tree. The
// compiler already catches forgotten cases in switches that omit
// the `else =>` arm — `Expr.getMeta`, `Pattern.getMeta`, and the
// `types.TypeResolver.resolve` switch in `types.zig` are
// intentionally exhaustive for that reason. Visitors that DO have
// `else =>` (most of `desugar.zig`, `macro.zig`, `attr_substitute.zig`,
// the IR builder's expression walker, etc.) silently swallow new
// variants, so the tests below act as tripwires: when a variant is
// added or removed, the count assertion fires and the failure
// message points at every visitor that needs an update.
//
// Update procedure when one of these tests fails:
//   1. Bump the corresponding `expected_*_variants` constant to
//      the new count.
//   2. Walk the visitor checklist in the failing test's comment
//      and confirm each one handles the new variant correctly.
//   3. Add or update a test in the appropriate test file (see the
//      checklist) that exercises the new variant end-to-end.
//
// The checklists are NOT exhaustive — they cover the high-traffic
// visitors. Adding a variant always warrants a `git grep` for the
// nearby variants to find any pass-specific handlers.

const expected_expr_variants: usize = 40;
const expected_pattern_variants: usize = 12;
const expected_type_expr_variants: usize = 11;
const expected_top_item_variants: usize = 16;

test "ast.Expr variant count is locked" {
    // When this test fails, you've added or removed an Expr
    // variant. Visitors to verify before bumping the count:
    //   - src/desugar.zig:desugarExpr  (transformations during desugar)
    //   - src/macro.zig:cloneExpr      (macro AST clone for hygiene)
    //   - src/attr_substitute.zig      (@-attribute substitution clone)
    //   - src/types.zig:inferExpr      (expression type inference)
    //   - src/hir.zig:buildExpr        (AST → HIR lowering)
    //   - src/collector.zig:collectFromExpr (scope/binding discovery)
    //   - src/ast_data.zig             (CTFE serialization, if applicable)
    //   - Expr.getMeta in this file (exhaustive — compiler catches misses)
    try std.testing.expectEqual(
        expected_expr_variants,
        std.meta.fields(Expr).len,
    );
}

test "ast.Pattern variant count is locked" {
    // When this test fails, walk these visitors:
    //   - src/desugar.zig pattern paths
    //   - src/macro.zig:clonePattern
    //   - src/types.zig pattern type inference
    //   - src/hir.zig:compilePattern
    //   - src/collector.zig pattern bindings
    //   - Pattern.getMeta in this file (exhaustive)
    try std.testing.expectEqual(
        expected_pattern_variants,
        std.meta.fields(Pattern).len,
    );
}

test "ast.TypeExpr variant count is locked" {
    // When this test fails, walk these visitors:
    //   - src/types.zig:TypeResolver.resolve (exhaustive — compiler catches misses)
    //   - src/macro.zig:cloneTypeExpr
    //   - src/attr_substitute.zig type-expression clone
    //   - TypeExpr.getMeta in this file (exhaustive)
    try std.testing.expectEqual(
        expected_type_expr_variants,
        std.meta.fields(TypeExpr).len,
    );
}

test "ast.TopItem variant count is locked" {
    // When this test fails, walk these visitors:
    //   - src/collector.zig top-item collection
    //   - src/desugar.zig top-item desugaring
    //   - src/macro.zig top-item expansion
    //   - src/compiler.zig:buildStructPrograms (per-struct routing)
    try std.testing.expectEqual(
        expected_top_item_variants,
        std.meta.fields(TopItem).len,
    );
}

// ============================================================
// Tests
// ============================================================

test "source span merge" {
    const a = SourceSpan{ .start = 0, .end = 5, .line = 1 };
    const b = SourceSpan{ .start = 10, .end = 20, .line = 2 };
    const merged = SourceSpan.merge(a, b);
    try std.testing.expectEqual(@as(u32, 0), merged.start);
    try std.testing.expectEqual(@as(u32, 20), merged.end);
}

test "string interner" {
    var interner = StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const id1 = try interner.intern("hello");
    const id2 = try interner.intern("world");
    const id3 = try interner.intern("hello");

    try std.testing.expectEqual(id1, id3);
    try std.testing.expect(id1 != id2);
    try std.testing.expectEqualStrings("hello", interner.get(id1));
    try std.testing.expectEqualStrings("world", interner.get(id2));
}
