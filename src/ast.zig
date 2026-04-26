const std = @import("std");
const Token = @import("token.zig").Token;

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

pub const NodeMeta = struct {
    span: SourceSpan,
    scope_id: u32 = 0,
};

pub fn makeMeta(span: SourceSpan) NodeMeta {
    return .{ .span = span };
}

// ============================================================
// String interning
// ============================================================

pub const StringId = u32;

pub const StringInterner = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
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
        self.strings.deinit(self.allocator);
        self.map.deinit();
    }

    pub fn intern(self: *StringInterner, str: []const u8) !StringId {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.map.get(str)) |id| {
            return id;
        }
        const id: StringId = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, str);
        try self.map.put(str, id);
        return id;
    }

    pub fn get(self: *const StringInterner, id: StringId) []const u8 {
        const mutex_ptr = @constCast(&self.mutex);
        while (!mutex_ptr.tryLock()) std.atomic.spinLoopHint();
        defer mutex_ptr.unlock();
        return self.strings.items[id];
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
};

// ============================================================
// Protocol declarations
// ============================================================

pub const ProtocolDecl = struct {
    meta: NodeMeta,
    name: StructName,
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
    /// Collected into an auto-generated run/0 function by the HIR builder.
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
    variants: []const UnionVariant,
};

pub const UnionVariant = struct {
    meta: NodeMeta,
    name: StringId,
    type_expr: ?*const TypeExpr = null, // null = unit variant
};

// ============================================================
// Function declarations
// ============================================================

pub const FunctionDecl = struct {
    meta: NodeMeta,
    name: StringId,
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
// Module system directives
// ============================================================

pub const AliasDecl = struct {
    meta: NodeMeta,
    module_path: StructName,
    as_name: ?StructName,
};

pub const ImportDecl = struct {
    meta: NodeMeta,
    module_path: StructName,
    filter: ?ImportFilter,
};

pub const UseDecl = struct {
    meta: NodeMeta,
    module_path: StructName,
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
// Module attributes
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
    module_ref: ModuleRef,

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

    // List construction
    list_cons_expr: ListConsExpr,

    // Macros
    quote_expr: QuoteExpr,
    unquote_expr: UnquoteExpr,
    unquote_splicing_expr: UnquoteSplicingExpr,

    // Error handling
    panic_expr: PanicExpr,
    error_pipe: ErrorPipeExpr,

    // Block
    block: BlockExpr,

    // Intrinsics
    intrinsic: IntrinsicExpr,

    // Attribute reference: @name in expression position
    attr_ref: AttrRefExpr,

    // Binary literal: <<1, 2, 3>>
    binary_literal: BinaryLiteral,

    // Function reference: Module.func/arity
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
            .module_ref => |v| v.meta,
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
            .list_cons_expr => |v| v.meta,
            .quote_expr => |v| v.meta,
            .unquote_expr => |v| v.meta,
            .unquote_splicing_expr => |v| v.meta,
            .panic_expr => |v| v.meta,
            .error_pipe => |v| v.meta,
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

pub const ModuleRef = struct {
    meta: NodeMeta,
    name: StructName,
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
    module_name: StructName,
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
    module_name: StructName,
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

pub const FunctionRefExpr = struct {
    meta: NodeMeta,
    module: ?StructName, // null for local function references
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
    module_name: StructName,
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
