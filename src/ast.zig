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

    pub fn from(loc: Token.Location) SourceSpan {
        return .{ .start = loc.start, .end = loc.end, .line = loc.line, .col = loc.col };
    }

    pub fn merge(a: SourceSpan, b: SourceSpan) SourceSpan {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
            .line = a.line,
            .col = a.col,
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
        if (self.map.get(str)) |id| {
            return id;
        }
        const id: StringId = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, str);
        try self.map.put(str, id);
        return id;
    }

    pub fn get(self: *const StringInterner, id: StringId) []const u8 {
        return self.strings.items[id];
    }
};

// ============================================================
// Top-level program
// ============================================================

pub const Program = struct {
    modules: []const ModuleDecl,
    top_items: []const TopItem,
};

pub const TopItem = union(enum) {
    module: *const ModuleDecl,
    type_decl: *const TypeDecl,
    opaque_decl: *const OpaqueDecl,
    struct_decl: *const StructDecl,
    enum_decl: *const EnumDecl,
    function: *const FunctionDecl,
    priv_function: *const FunctionDecl,
    macro: *const FunctionDecl,
};

// ============================================================
// Module
// ============================================================

pub const ModuleDecl = struct {
    meta: NodeMeta,
    name: ModuleName,
    parent: ?StringId = null,
    items: []const ModuleItem,
};

pub const ModuleName = struct {
    parts: []const StringId,
    span: SourceSpan,
};

pub const ModuleItem = union(enum) {
    type_decl: *const TypeDecl,
    opaque_decl: *const OpaqueDecl,
    struct_decl: *const StructDecl,
    enum_decl: *const EnumDecl,
    function: *const FunctionDecl,
    priv_function: *const FunctionDecl,
    macro: *const FunctionDecl,
    alias_decl: *const AliasDecl,
    import_decl: *const ImportDecl,
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
    name: ?StringId = null,
    parent: ?StringId = null,
    fields: []const StructFieldDecl,
};

pub const StructFieldDecl = struct {
    meta: NodeMeta,
    name: StringId,
    type_expr: *const TypeExpr,
    default: ?*const Expr,
};

// ============================================================
// Enum declarations
// ============================================================

pub const EnumDecl = struct {
    meta: NodeMeta,
    name: StringId,
    variants: []const EnumVariant,
};

pub const EnumVariant = struct {
    meta: NodeMeta,
    name: StringId,
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
    body: []const Stmt,
};

pub const Param = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    type_annotation: ?*const TypeExpr,
    default: ?*const Expr = null,
};

// ============================================================
// Module system directives
// ============================================================

pub const AliasDecl = struct {
    meta: NodeMeta,
    module_path: ModuleName,
    as_name: ?ModuleName,
};

pub const ImportDecl = struct {
    meta: NodeMeta,
    module_path: ModuleName,
    filter: ?ImportFilter,
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
    with_expr: WithExpr,
    cond_expr: CondExpr,

    // Macros
    quote_expr: QuoteExpr,
    unquote_expr: UnquoteExpr,

    // Error handling
    panic_expr: PanicExpr,

    // Block
    block: BlockExpr,

    // Intrinsics
    intrinsic: IntrinsicExpr,

    // Binary literal: <<1, 2, 3>>
    binary_literal: BinaryLiteral,

    // Function reference: Module.func/arity
    function_ref: FunctionRefExpr,

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
            .binary_op => |v| v.meta,
            .unary_op => |v| v.meta,
            .call => |v| v.meta,
            .field_access => |v| v.meta,
            .pipe => |v| v.meta,
            .unwrap => |v| v.meta,
            .if_expr => |v| v.meta,
            .case_expr => |v| v.meta,
            .with_expr => |v| v.meta,
            .cond_expr => |v| v.meta,
            .quote_expr => |v| v.meta,
            .unquote_expr => |v| v.meta,
            .panic_expr => |v| v.meta,
            .block => |v| v.meta,
            .intrinsic => |v| v.meta,
            .binary_literal => |v| v.meta,
            .function_ref => |v| v.meta,
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
    name: ModuleName,
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
    fields: []const MapField,
};

pub const MapField = struct {
    key: *const Expr,
    value: *const Expr,
};

pub const StructExpr = struct {
    meta: NodeMeta,
    module_name: ModuleName,
    update_source: ?*const Expr,
    fields: []const StructField,
};

pub const StructField = struct {
    name: StringId,
    value: *const Expr,
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

pub const WithExpr = struct {
    meta: NodeMeta,
    items: []const WithItem,
    body: []const Stmt,
    else_clauses: ?[]const WithElseClause,
};

pub const WithItem = union(enum) {
    bind: WithBind,
    expr: *const Expr,
};

pub const WithBind = struct {
    meta: NodeMeta,
    pattern: *const Pattern,
    source: *const Expr,
};

pub const WithElseClause = struct {
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

pub const QuoteExpr = struct {
    meta: NodeMeta,
    body: []const Stmt,
};

pub const UnquoteExpr = struct {
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
    module_name: ModuleName,
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
    module: ?ModuleName,    // null for local function references
    function: StringId,
    arity: u32,
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
    module_name: ModuleName,
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
    return_type: *const TypeExpr,
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
