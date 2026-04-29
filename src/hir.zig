const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Typed HIR (High-level Intermediate Representation)
//
// A typed, desugared representation after type checking.
// Every expression carries its resolved type.
// Dispatch is resolved to specific function groups.
// Match compilation converts patterns to decision trees.
// ============================================================

pub const TypeId = types_mod.TypeId;
pub const Ownership = types_mod.Ownership;

pub const ValueMode = enum {
    share,
    move,
    borrow,
};

// ============================================================
// HIR Program
// ============================================================

pub const Program = struct {
    modules: []const Module,
    top_functions: []const FunctionGroup,
    protocols: []const ProtocolInfo = &.{},
    impls: []const ImplInfo = &.{},
};

pub const ProtocolInfo = struct {
    name: ast.StringId,
    function_names: []const ast.StringId,
    function_arities: []const u32,
};

pub const ImplInfo = struct {
    protocol_name: ast.StringId,
    target_module: ast.StringId,
    impl_scope_id: scope_mod.ScopeId,
    function_group_ids: []const u32,
};

pub const Module = struct {
    name: ast.StructName,
    scope_id: scope_mod.ScopeId,
    functions: []const FunctionGroup,
    types: []const TypeDef,
};

// ============================================================
// HIR Function Group (with fallback chain)
// ============================================================

pub const FunctionGroup = struct {
    id: u32,
    scope_id: scope_mod.ScopeId,
    name: ast.StringId,
    arity: u32,
    is_local: bool = false,
    captures: []const Capture = &.{},
    clauses: []const Clause,
    fallback_parent: ?u32, // ID of the outer scope's function group
};

pub const Capture = struct {
    name: ast.StringId,
    type_id: TypeId,
    ownership: Ownership,
};

pub const Clause = struct {
    params: []const TypedParam,
    return_type: TypeId,
    decision: *const Decision, // compiled match decision
    body: *const Block,
    refinement: ?*const Expr,
    tuple_bindings: []const TupleBinding,
    struct_bindings: []const StructBinding = &.{},
    list_bindings: []const ListBinding = &.{},
    cons_tail_bindings: []const ConsTailBinding = &.{},
    binary_bindings: []const BinaryBinding = &.{},
    map_bindings: []const MapBinding = &.{},
};

pub const TupleBinding = struct {
    name: ast.StringId,
    param_index: u32,
    element_index: u32,
    local_index: u32,
};

pub const StructBinding = struct {
    name: ast.StringId,
    param_index: u32,
    field_name: ast.StringId,
    local_index: u32,
};

pub const MapBinding = struct {
    name: ast.StringId,
    param_index: u32,
    key_expr: *const Expr,
    local_index: u32,
};

pub const ListBinding = struct {
    name: ast.StringId,
    param_index: u32,
    element_index: u32,
    local_index: u32,
};

/// Binding for a cons pattern tail: [_ | tail] binds the remaining list.
pub const ConsTailBinding = struct {
    name: ast.StringId,
    param_index: u32,
    local_index: u32,
};

pub const BinaryBinding = struct {
    name: ast.StringId,
    param_index: u32,
    segment_index: u32,
    local_index: u32,
    segment: BinaryMatchSegment,
};

pub const TypedParam = struct {
    name: ?ast.StringId,
    type_id: TypeId,
    ownership: Ownership = .shared,
    pattern: ?*const MatchPattern,
    default: ?*const Expr = null,
};

// ============================================================
// HIR Type definitions
// ============================================================

pub const TypeDef = struct {
    name: ast.StringId,
    type_id: TypeId,
    kind: TypeDefKind,
};

pub const TypeDefKind = enum {
    alias,
    opaque_type,
    struct_type,
};

// ============================================================
// HIR Expressions (typed)
// ============================================================

pub const Expr = struct {
    kind: ExprKind,
    type_id: TypeId,
    span: ast.SourceSpan,
};

pub const ExprKind = union(enum) {
    // Literals
    int_lit: i64,
    float_lit: f64,
    string_lit: ast.StringId,
    atom_lit: ast.StringId,
    bool_lit: bool,
    nil_lit,

    // References
    local_get: u32, // local variable index
    param_get: u32, // parameter index
    capture_get: u32,

    // Compound
    tuple_init: []const *const Expr,
    list_init: []const *const Expr,
    list_cons: ListConsHir,
    map_init: []const MapEntry,
    struct_init: StructInit,

    // Operations
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    field_get: FieldGetExpr,
    /// Tuple element extraction by zero-based positional index.
    tuple_index_get: TupleIndexGetExpr,
    /// List element extraction by zero-based positional index.
    list_index_get: ListIndexGetExpr,
    /// First element of a non-empty list (head).
    list_head_get: ListHeadGetExpr,
    /// All-but-first elements of a list (tail), preserving the list type.
    list_tail_get: ListTailGetExpr,
    /// Map value lookup by key expression.
    map_value_get: MapValueGetExpr,

    // Control flow
    branch: BranchExpr,
    match: MatchExpr,
    case: CaseData,
    block: Block,

    // Error handling
    panic: *const Expr,
    unwrap: *const Expr, // optional force-unwrap (expr!)

    // Union
    union_init: UnionInitExpr,
    error_pipe: ErrorPipeHir,

    // Special
    closure_create: ClosureCreate,
    never,
};

pub const UnionInitExpr = struct {
    union_type_id: types_mod.TypeId,
    variant_name: ast.StringId,
    value: *const Expr,
};

pub const ErrorPipeHir = struct {
    /// The chain steps: first is the base call, rest are pipe steps.
    /// Each step except the first takes the previous step's Ok value as first arg.
    steps: []const ErrorPipeStep,
    /// The error handler — called when a pipe step can't match its input.
    /// References `err_local` for the failing input value.
    handler: *const Expr,
    /// Local index that the IR will populate with the failing pipe value
    /// before lowering `handler`. The HIR builder allocates this so that
    /// `__err` references inside the handler resolve to the same local.
    /// `null` indicates no `__err` allocation (function-style handler), in
    /// which case the failing value is passed to the handler function as
    /// its first call argument by the IR-level lowering.
    err_local: ?u32 = null,
};

pub const ErrorPipeStep = struct {
    /// The HIR expression for this step. For step 0, it's the base call.
    /// For step N > 0, it's a call expression where the first arg should be
    /// substituted with the previous step's result piped as first arg.
    expr: *const Expr,
    /// Whether this step calls a multi-clause function (has __try variant).
    /// When true, the ~> catch basin can intercept unmatched values.
    is_dispatched: bool = false,
};

pub const BinaryExpr = struct {
    op: ast.BinaryOp.Op,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const UnaryExpr = struct {
    op: ast.UnaryOp.Op,
    operand: *const Expr,
};

pub const CallExpr = struct {
    target: CallTarget,
    args: []const CallArg,
};

pub const CallArg = struct {
    expr: *const Expr,
    mode: ValueMode = .share,
    expected_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN,
};

pub const NamedCall = struct {
    module: ?[]const u8,
    name: []const u8,
};

pub const CallTarget = union(enum) {
    direct: DirectCall,
    named: NamedCall,
    closure: *const Expr,
    dispatch: DispatchCall,
    builtin: []const u8,
};

pub const DirectCall = struct {
    function_group_id: u32,
    clause_index: u32,
};

pub const DispatchCall = struct {
    function_group_id: u32,
};

pub const FieldGetExpr = struct {
    object: *const Expr,
    field: ast.StringId,
};

pub const TupleIndexGetExpr = struct {
    object: *const Expr,
    index: u32,
};

pub const ListIndexGetExpr = struct {
    list: *const Expr,
    index: u32,
};

pub const ListHeadGetExpr = struct {
    list: *const Expr,
};

pub const ListTailGetExpr = struct {
    list: *const Expr,
};

pub const MapValueGetExpr = struct {
    map: *const Expr,
    key: *const Expr,
};

pub const BranchExpr = struct {
    condition: *const Expr,
    then_block: *const Block,
    else_block: ?*const Block,
};

pub const MatchExpr = struct {
    scrutinee: *const Expr,
    decision: *const Decision,
};

pub const CaseData = struct {
    scrutinee: *const Expr,
    arms: []const CaseArm,
};

pub const CaseArm = struct {
    pattern: ?*const MatchPattern,
    guard: ?*const Expr,
    body: *const Block,
    bindings: []const CaseBinding,
};

pub const CaseBinding = struct {
    name: ast.StringId,
    local_index: u32,
    kind: CaseBindKind,
    element_index: u32, // only used for binary_element
};

pub const CaseBindKind = enum {
    scrutinee, // bind the whole scrutinee value (top-level `name -> body`)
    extracted, // bind extracted by a decision tree .bind node (tuple/list/struct/map/list_cons element)
    binary_element, // bind a segment extracted from binary data
};

pub const AssignmentBinding = struct {
    name: ast.StringId,
    local_index: u32,
    type_id: types_mod.TypeId = types_mod.TypeStore.UNKNOWN,
};

pub const ListConsHir = struct {
    head: *const Expr,
    tail: *const Expr,
};

pub const MapEntry = struct {
    key: *const Expr,
    value: *const Expr,
};

pub const StructInit = struct {
    type_id: TypeId,
    fields: []const StructFieldInit,
};

pub const StructFieldInit = struct {
    name: ast.StringId,
    value: *const Expr,
};

pub const ClosureCreate = struct {
    function_group_id: u32,
    captures: []const CaptureValue,
};

pub const CaptureValue = struct {
    expr: *const Expr,
    ownership: Ownership,
};

// ============================================================
// HIR Block
// ============================================================

pub const Block = struct {
    stmts: []const Stmt,
    result_type: TypeId,
};

pub const Stmt = union(enum) {
    expr: *const Expr,
    local_set: LocalSet,
    function_group: *const FunctionGroup,
};

pub const LocalSet = struct {
    index: u32,
    value: *const Expr,
};

// ============================================================
// Match compilation — Decision trees (spec §17)
//
// Patterns compile to a decision tree of tests and branches.
// Each leaf is either a success (with bindings) or a failure
// that triggers the next fallback.
// ============================================================

pub const Decision = union(enum) {
    /// Pattern match succeeded — execute body with bindings
    success: SuccessLeaf,
    /// Pattern match failed — try fallback
    failure,
    /// Test a value and branch
    guard: GuardNode,
    /// Switch on tag/literal
    switch_tag: SwitchNode,
    /// Switch on literal value
    switch_literal: SwitchLiteralNode,
    /// Check tuple arity
    check_tuple: CheckTupleNode,
    /// Check list length
    check_list: CheckListNode,
    /// Check list cons (non-empty list with head/tail extraction)
    check_list_cons: CheckListConsNode,
    /// Check binary data (length + segment extraction)
    check_binary: CheckBinaryNode,
    /// Bind a variable and continue
    bind: BindNode,
    /// Extract named struct fields and continue. Statically-typed structs
    /// always match the layout (the type checker rejected anything else),
    /// so no runtime tag check is needed; this just plumbs each requested
    /// field into the success subtree as a fresh scrutinee.
    extract_struct: ExtractStructNode,
    /// Extract map values for named keys and continue. Each key is verified
    /// to exist; missing keys route to `failure`.
    extract_map: ExtractMapNode,
};

pub const SuccessLeaf = struct {
    bindings: []const Binding,
    body_index: u32,
};

pub const Binding = struct {
    name: ast.StringId,
    local_index: u32,
};

pub const GuardNode = struct {
    condition: *const Expr,
    success: *const Decision,
    failure: *const Decision,
};

pub const SwitchNode = struct {
    scrutinee: *const Expr,
    cases: []const SwitchCase,
    default: *const Decision,
};

pub const SwitchCase = struct {
    tag: ast.StringId,
    bindings: []const Binding,
    next: *const Decision,
};

pub const SwitchLiteralNode = struct {
    scrutinee: *const Expr,
    cases: []const LiteralCase,
    default: *const Decision,
};

pub const LiteralCase = struct {
    value: LiteralValue,
    next: *const Decision,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: ast.StringId,
    atom: ast.StringId,
    bool_val: bool,
    nil,
};

pub const ExtractStructNode = struct {
    scrutinee: *const Expr,
    fields: []const StructFieldExtraction,
    success: *const Decision,
    failure: *const Decision,
};

pub const StructFieldExtraction = struct {
    field_name: ast.StringId,
    scrutinee_id: u32,
};

pub const ExtractMapNode = struct {
    scrutinee: *const Expr,
    keys: []const MapKeyExtraction,
    success: *const Decision,
    failure: *const Decision,
};

pub const MapKeyExtraction = struct {
    /// Key expression (literal or computed) evaluated at runtime.
    key: *const Expr,
    /// Scrutinee ID assigned to the looked-up value.
    scrutinee_id: u32,
};

pub const CheckTupleNode = struct {
    scrutinee: *const Expr,
    expected_arity: u32,
    /// Scrutinee IDs assigned to each tuple element by the pattern compiler.
    /// element_scrutinee_ids[i] is the ID for element i, used to populate
    /// the scrutinee_map in IR lowering. This avoids the fragile heuristic
    /// of walking the decision tree to discover IDs (which breaks with wildcards).
    element_scrutinee_ids: []const u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckListNode = struct {
    scrutinee: *const Expr,
    expected_length: u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckListConsNode = struct {
    scrutinee: *const Expr,
    /// Number of head elements extracted (typically 1 for [h | t])
    head_count: u32,
    /// Scrutinee IDs for extracted heads and tail
    head_scrutinee_ids: []const u32,
    tail_scrutinee_id: u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckBinaryNode = struct {
    scrutinee: *const Expr,
    min_byte_size: u32,
    segments: []const BinaryMatchSegment,
    success: *const Decision,
    failure: *const Decision,
};

pub const BindNode = struct {
    name: ast.StringId,
    local_index: u32,
    source: *const Expr,
    next: *const Decision,
};

// ============================================================
// Match pattern (intermediate representation)
// ============================================================

pub const MatchPattern = union(enum) {
    wildcard,
    bind: ast.StringId,
    literal: LiteralValue,
    tuple: []const *const MatchPattern,
    list: []const *const MatchPattern,
    list_cons: ListConsMatch,
    pin: ast.StringId,
    struct_match: StructMatch,
    map_match: MapMatch,
    binary_match: BinaryMatchData,
};

pub const BinaryMatchData = struct {
    segments: []const BinaryMatchSegment,
};

pub const BinaryMatchSegment = struct {
    pattern: ?*const MatchPattern,
    type_spec: ast.BinarySegmentType,
    endianness: ast.Endianness,
    size: ?ast.BinarySegmentSize,
    string_literal: ?ast.StringId,
};

pub const ListConsMatch = struct {
    heads: []const *const MatchPattern,
    tail: *const MatchPattern,
};

pub const StructMatch = struct {
    type_name: ast.StringId,
    field_bindings: []const StructFieldBind,
};

pub const StructFieldBind = struct {
    field_name: ast.StringId,
    pattern: *const MatchPattern,
};

pub const MapMatch = struct {
    field_bindings: []const MapFieldBind,
};

pub const MapFieldBind = struct {
    key: *const ast.Expr,
    pattern: *const MatchPattern,
};

pub const PatternRow = struct {
    patterns: []const ?*const MatchPattern,
    body_index: u32,
    guard: ?*const Expr,
};

pub const PatternMatrix = struct {
    rows: []const PatternRow,
    column_count: u32,
};

// ============================================================
// Pattern matrix compilation — Wadler algorithm
//
// Compiles a matrix of patterns into a Decision tree.
// ============================================================

/// Maps bind names to their scrutinee IDs for variable unification (pin patterns).
pub const BoundScrutinees = std.AutoHashMap(ast.StringId, u32);

pub fn compilePatternMatrix(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
) anyerror!*const Decision {
    var empty_bound: BoundScrutinees = BoundScrutinees.init(allocator);
    return compilePatternMatrixWithBindings(allocator, matrix, scrutinee_ids, next_id, &empty_bound);
}

fn compilePatternMatrixWithBindings(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Base case: no rows → failure
    if (matrix.rows.len == 0) {
        const d = try allocator.create(Decision);
        d.* = .failure;
        return d;
    }

    // Base case: no columns → first row's body (success)
    if (matrix.column_count == 0) {
        const row = matrix.rows[0];
        const d = try allocator.create(Decision);
        if (row.guard) |guard_expr| {
            // Recurse for remaining rows on guard failure
            const success = try allocator.create(Decision);
            success.* = .{ .success = .{ .bindings = &.{}, .body_index = row.body_index } };
            const remaining_rows = try allocator.alloc(PatternRow, matrix.rows.len - 1);
            @memcpy(remaining_rows, matrix.rows[1..]);
            const failure = try compilePatternMatrix(allocator, .{
                .rows = remaining_rows,
                .column_count = 0,
            }, scrutinee_ids, next_id);
            d.* = .{ .guard = .{
                .condition = guard_expr,
                .success = success,
                .failure = failure,
            } };
        } else {
            d.* = .{ .success = .{ .bindings = &.{}, .body_index = row.body_index } };
        }
        return d;
    }

    // Classify column 0
    const col0_class = classifyColumn(matrix);

    switch (col0_class) {
        .all_wildcard => {
            // Variable Rule: strip column 0, recurse.
            // Record any bind in column 0 so pins in later columns can reference it.
            if (matrix.rows.len > 0 and matrix.rows[0].patterns.len > 0) {
                const pat = matrix.rows[0].patterns[0];
                if (pat != null and pat.?.* == .bind and scrutinee_ids.len > 0) {
                    bound_scrutinees.put(pat.?.bind, scrutinee_ids[0]) catch {};
                }
            }
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
        .all_constructor, .mixture => {
            return compileConstructorColumn(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
    }
}

const ColumnClass = enum { all_wildcard, all_constructor, mixture };

fn classifyColumn(matrix: PatternMatrix) ColumnClass {
    var has_constructor = false;
    var has_wildcard = false;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) {
            has_wildcard = true;
            continue;
        }
        const pat = row.patterns[0];
        if (pat == null) {
            has_wildcard = true;
        } else {
            switch (pat.?.*) {
                .wildcard, .bind => has_wildcard = true,
                // Pin (variable unification) acts as a constructor — it
                // constrains which values match via an equality guard.
                .pin => has_constructor = true,
                else => has_constructor = true,
            }
        }
    }
    if (has_constructor and has_wildcard) return .mixture;
    if (has_constructor) return .all_constructor;
    return .all_wildcard;
}

fn isWildcardPattern(pat: ?*const MatchPattern) bool {
    if (pat == null) return true;
    return switch (pat.?.*) {
        .wildcard, .bind => true,
        else => false,
    };
}

fn stripColumnAndRecurse(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect bindings from column 0 for first matching row
    // Then strip column 0 and recurse
    var new_rows = try allocator.alloc(PatternRow, matrix.rows.len);
    for (matrix.rows, 0..) |row, i| {
        const new_pats = if (row.patterns.len > 1)
            row.patterns[1..]
        else
            @as([]const ?*const MatchPattern, &.{});
        new_rows[i] = .{
            .patterns = new_pats,
            .body_index = row.body_index,
            .guard = row.guard,
        };
    }

    const new_scrutinees = if (scrutinee_ids.len > 1)
        scrutinee_ids[1..]
    else
        @as([]const u32, &.{});

    // Check if column 0 first row has a bind pattern that needs to be recorded
    const first_pat = if (matrix.rows[0].patterns.len > 0) matrix.rows[0].patterns[0] else null;
    const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = new_rows,
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    if (first_pat != null and first_pat.?.* == .bind) {
        // Emit a bind node
        const scrutinee_expr = try allocator.create(Expr);
        scrutinee_expr.* = .{
            .kind = .{ .param_get = scrutinee_ids[0] },
            .type_id = types_mod.TypeStore.UNKNOWN,
            .span = .{ .start = 0, .end = 0 },
        };
        const d = try allocator.create(Decision);
        d.* = .{
            .bind = .{
                .name = first_pat.?.bind,
                .local_index = 0, // resolved during IR lowering
                .source = scrutinee_expr,
                .next = sub_decision,
            },
        };
        return d;
    }

    return sub_decision;
}

fn compileConstructorColumn(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct constructors
    const scrutinee_id = scrutinee_ids[0];

    // Determine constructor type from first non-wildcard pattern
    var first_constructor: ?*const MatchPattern = null;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            first_constructor = row.patterns[0].?;
            break;
        }
    }

    if (first_constructor == null) {
        // All wildcards - use variable rule
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    const scrutinee_expr = try allocator.create(Expr);
    scrutinee_expr.* = .{
        .kind = .{ .param_get = scrutinee_id },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    // Check if any row has a list_cons pattern — if so, prefer compileListConsCheck
    // because it handles both cons and empty patterns correctly.
    var has_list_cons = false;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            if (row.patterns[0].?.* == .list_cons) {
                has_list_cons = true;
                break;
            }
        }
    }

    if (has_list_cons) {
        return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
    }

    switch (first_constructor.?.*) {
        .literal => |lit| {
            switch (lit) {
                .atom => {
                    // Atom literals -> switch_tag
                    return compileAtomSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
                },
                else => {
                    // Int/float/string/bool/nil literals -> switch_literal
                    return compileLiteralSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
                },
            }
        },
        .tuple => {
            // Tuple constructors -> check_tuple
            return compileTupleCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .list => {
            // List constructors -> check_list (same structure as check_tuple but for slices)
            return compileListCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .list_cons => {
            // List cons patterns -> check_list_cons (non-empty check + head/tail extraction)
            return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .binary_match => {
            // Binary constructors -> check_binary
            return compileBinaryCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .pin => {
            // Pin (variable unification) -> guard with equality check
            return compilePinGuard(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .struct_match => {
            return compileStructFields(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .map_match => {
            return compileMapFields(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        else => {
            // Fallback: treat as variable rule
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
    }
}

/// Compile a column where the first pattern is `struct_match`. Collects the
/// union of all field names referenced across rows, extracts each field into
/// a fresh scrutinee, and rewrites each row with one column per extracted
/// field — falling through to the generic matrix compiler so nested patterns
/// (literals, sub-binds, nested compounds) keep being handled correctly.
fn compileStructFields(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    var field_names: std.ArrayList(ast.StringId) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .struct_match) continue;
        for (pat.?.struct_match.field_bindings) |fb| {
            var found = false;
            for (field_names.items) |existing| {
                if (existing == fb.field_name) {
                    found = true;
                    break;
                }
            }
            if (!found) try field_names.append(allocator, fb.field_name);
        }
    }

    if (field_names.items.len == 0) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    var extractions: std.ArrayList(StructFieldExtraction) = .empty;
    var field_scrutinee_ids: std.ArrayList(u32) = .empty;
    for (field_names.items) |fname| {
        const sid = next_id.*;
        next_id.* += 1;
        try extractions.append(allocator, .{ .field_name = fname, .scrutinee_id = sid });
        try field_scrutinee_ids.append(allocator, sid);
    }

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var combined_ids: std.ArrayList(u32) = .empty;
    try combined_ids.appendSlice(allocator, field_scrutinee_ids.items);
    try combined_ids.appendSlice(allocator, remaining_scrutinees);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    var failure_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const head = row.patterns[0];
        const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        if (isWildcardPattern(head)) {
            // Wildcard matches every constructor — broadcast to wildcards
            // for each extracted field.
            var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
            for (field_names.items) |_| {
                try new_pats.append(allocator, null);
            }
            try new_pats.appendSlice(allocator, tail);
            try success_rows.append(allocator, .{
                .patterns = try new_pats.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
            try failure_rows.append(allocator, .{
                .patterns = tail,
                .body_index = row.body_index,
                .guard = row.guard,
            });
            continue;
        }
        if (head.?.* != .struct_match) continue;
        const sm = head.?.struct_match;
        var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
        for (field_names.items) |fname| {
            var matched: ?*const MatchPattern = null;
            for (sm.field_bindings) |fb| {
                if (fb.field_name == fname) {
                    matched = fb.pattern;
                    break;
                }
            }
            try new_pats.append(allocator, matched);
        }
        try new_pats.appendSlice(allocator, tail);
        try success_rows.append(allocator, .{
            .patterns = try new_pats.toOwnedSlice(allocator),
            .body_index = row.body_index,
            .guard = row.guard,
        });
    }

    const success_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = @as(u32, @intCast(field_names.items.len)) + (matrix.column_count - 1),
        },
        try combined_ids.toOwnedSlice(allocator),
        next_id,
        bound_scrutinees,
    );
    const failure_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try failure_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        },
        remaining_scrutinees,
        next_id,
        bound_scrutinees,
    );

    const node = try allocator.create(Decision);
    node.* = .{ .extract_struct = .{
        .scrutinee = scrutinee_expr,
        .fields = try extractions.toOwnedSlice(allocator),
        .success = success_decision,
        .failure = failure_decision,
    } };
    return node;
}

/// Compile a column where the first pattern is `map_match`. The shape mirrors
/// `compileStructFields` but indexes by key expression rather than field name.
fn compileMapFields(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct keys by AST pointer identity (parser de-duplicates
    // literal keys — a coarser equivalence check would need an interpreter).
    var keys: std.ArrayList(*const ast.Expr) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .map_match) continue;
        for (pat.?.map_match.field_bindings) |fb| {
            var found = false;
            for (keys.items) |existing| {
                if (existing == fb.key) {
                    found = true;
                    break;
                }
            }
            if (!found) try keys.append(allocator, fb.key);
        }
    }

    if (keys.items.len == 0) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    var extractions: std.ArrayList(MapKeyExtraction) = .empty;
    var key_scrutinee_ids: std.ArrayList(u32) = .empty;
    for (keys.items) |key_expr| {
        const sid = next_id.*;
        next_id.* += 1;
        // key_expr_hir built lazily — the IR converts the AST key inline;
        // here we just want a placeholder Expr so the Decision can
        // reference the key for its own diagnostics.
        const placeholder = try allocator.create(Expr);
        placeholder.* = .{
            .kind = .nil_lit,
            .type_id = types_mod.TypeStore.UNKNOWN,
            .span = key_expr.getMeta().span,
        };
        try extractions.append(allocator, .{ .key = placeholder, .scrutinee_id = sid });
        try key_scrutinee_ids.append(allocator, sid);
    }

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var combined_ids: std.ArrayList(u32) = .empty;
    try combined_ids.appendSlice(allocator, key_scrutinee_ids.items);
    try combined_ids.appendSlice(allocator, remaining_scrutinees);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    var failure_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const head = row.patterns[0];
        const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        if (isWildcardPattern(head)) {
            var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
            for (keys.items) |_| try new_pats.append(allocator, null);
            try new_pats.appendSlice(allocator, tail);
            try success_rows.append(allocator, .{
                .patterns = try new_pats.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
            try failure_rows.append(allocator, .{
                .patterns = tail,
                .body_index = row.body_index,
                .guard = row.guard,
            });
            continue;
        }
        if (head.?.* != .map_match) continue;
        const mm = head.?.map_match;
        var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
        for (keys.items) |k| {
            var matched: ?*const MatchPattern = null;
            for (mm.field_bindings) |fb| {
                if (fb.key == k) {
                    matched = fb.pattern;
                    break;
                }
            }
            try new_pats.append(allocator, matched);
        }
        try new_pats.appendSlice(allocator, tail);
        try success_rows.append(allocator, .{
            .patterns = try new_pats.toOwnedSlice(allocator),
            .body_index = row.body_index,
            .guard = row.guard,
        });
    }

    const success_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = @as(u32, @intCast(keys.items.len)) + (matrix.column_count - 1),
        },
        try combined_ids.toOwnedSlice(allocator),
        next_id,
        bound_scrutinees,
    );
    const failure_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try failure_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        },
        remaining_scrutinees,
        next_id,
        bound_scrutinees,
    );

    const node = try allocator.create(Decision);
    node.* = .{ .extract_map = .{
        .scrutinee = scrutinee_expr,
        .keys = try extractions.toOwnedSlice(allocator),
        .success = success_decision,
        .failure = failure_decision,
    } };
    return node;
}

fn compileLiteralSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct literal values
    const DistinctLit = struct {
        value: LiteralValue,
    };
    var distinct: std.ArrayList(DistinctLit) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* == .literal) {
            const lit = pat.?.literal;
            var found = false;
            for (distinct.items) |d| {
                if (literalEquals(d.value, lit)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try distinct.append(allocator, .{ .value = lit });
            }
        }
    }

    // For each distinct value, collect matching+wildcard rows, strip column, recurse
    var cases: std.ArrayList(LiteralCase) = .empty;
    for (distinct.items) |dv| {
        var sub_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            if (isWildcardPattern(pat)) {
                // Wildcard rows match every constructor
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (pat.?.* == .literal and literalEquals(pat.?.literal, dv.value)) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
        const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id, bound_scrutinees);

        try cases.append(allocator, .{
            .value = dv.value,
            .next = sub_decision,
        });
    }

    // Default: wildcard-only rows
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    const default_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .switch_literal = .{
        .scrutinee = scrutinee_expr,
        .cases = try cases.toOwnedSlice(allocator),
        .default = default_decision,
    } };
    return d;
}

fn compileAtomSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct atom values
    var distinct_atoms: std.ArrayList(ast.StringId) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* == .literal and pat.?.literal == .atom) {
            const atom_id = pat.?.literal.atom;
            var found = false;
            for (distinct_atoms.items) |existing| {
                if (existing == atom_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try distinct_atoms.append(allocator, atom_id);
            }
        }
    }

    var switch_cases: std.ArrayList(SwitchCase) = .empty;
    for (distinct_atoms.items) |atom_id| {
        var sub_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            if (isWildcardPattern(pat)) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (pat.?.* == .literal and pat.?.literal == .atom and pat.?.literal.atom == atom_id) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
        const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id, bound_scrutinees);

        try switch_cases.append(allocator, .{
            .tag = atom_id,
            .bindings = &.{},
            .next = sub_decision,
        });
    }

    // Default
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }
    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    const default_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .switch_tag = .{
        .scrutinee = scrutinee_expr,
        .cases = try switch_cases.toOwnedSlice(allocator),
        .default = default_decision,
    } };
    return d;
}

/// Compile a pin pattern (variable unification) into a guard node.
/// `fn foo(x, [x | rest])` — the pin on the second `x` becomes a guard
/// checking that the scrutinee equals the binding from the earlier column.
fn compilePinGuard(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Find the pin name from the first non-wildcard row
    var pin_name: ?ast.StringId = null;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            if (row.patterns[0].?.* == .pin) {
                pin_name = row.patterns[0].?.pin;
                break;
            }
        }
    }
    if (pin_name == null) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    // Build a guard expression: scrutinee == pinned_variable
    // The pinned variable is a param_get referencing the earlier binding's scrutinee.
    // We look up the scrutinee ID from bound_scrutinees which was recorded when the
    // original bind was processed.
    const bound_id = bound_scrutinees.get(pin_name.?) orelse 0;
    const pin_var_expr = try allocator.create(Expr);
    pin_var_expr.* = .{
        .kind = .{ .param_get = bound_id },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    const guard_condition = try allocator.create(Expr);
    guard_condition.* = .{
        .kind = .{ .binary = .{
            .op = .equal,
            .lhs = scrutinee_expr,
            .rhs = pin_var_expr,
        } },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    // Matching rows: rows with pin or wildcard in column 0
    var match_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat) or (pat != null and pat.?.* == .pin)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try match_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    // Default rows: only wildcards
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        if (isWildcardPattern(row.patterns[0])) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    const success = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try match_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .guard = .{
        .condition = guard_condition,
        .success = success,
        .failure = failure,
    } };
    return d;
}

fn compileTupleCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect unique arities from tuple patterns
    var arities: std.ArrayList(u32) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .tuple) {
            const arity: u32 = @intCast(pat.?.tuple.len);
            var found = false;
            for (arities.items) |a| {
                if (a == arity) {
                    found = true;
                    break;
                }
            }
            if (!found) try arities.append(allocator, arity);
        }
    }

    // Sort arities ascending so we test smallest first
    std.sort.pdq(u32, arities.items, {}, std.sort.asc(u32));

    // Build wildcard-only failure base
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    var current_failure: *const Decision = undefined;
    if (wildcard_rows.items.len > 0) {
        current_failure = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try wildcard_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, remaining_scrutinees, next_id, bound_scrutinees);
    } else {
        const f = try allocator.create(Decision);
        f.* = .failure;
        current_failure = f;
    }

    // If all patterns have the same arity (or there's only one), use single check_tuple
    // Otherwise, chain check_tuple nodes from largest arity to smallest
    var i = arities.items.len;
    while (i > 0) {
        i -= 1;
        const arity = arities.items[i];

        // Build success rows for this specific arity
        var success_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];

            var new_cols: std.ArrayList(?*const MatchPattern) = .empty;
            if (!isWildcardPattern(pat) and pat.?.* == .tuple) {
                const pat_arity: u32 = @intCast(pat.?.tuple.len);
                if (pat_arity != arity) continue; // Only include patterns with this arity

                for (pat.?.tuple) |sub_pat| {
                    try new_cols.append(allocator, sub_pat);
                }
            } else if (isWildcardPattern(pat)) {
                // Wildcard matches any tuple — expand to this arity's worth of wildcards
                var j: u32 = 0;
                while (j < arity) : (j += 1) {
                    const wc = try allocator.create(MatchPattern);
                    wc.* = .wildcard;
                    try new_cols.append(allocator, wc);
                }
            } else {
                continue;
            }

            // Append remaining columns
            if (row.patterns.len > 1) {
                for (row.patterns[1..]) |p| {
                    try new_cols.append(allocator, p);
                }
            }

            try success_rows.append(allocator, .{
                .patterns = try new_cols.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }

        // Build new scrutinee IDs for this arity's elements.
        // Save element IDs separately for the CheckTupleNode so IR lowering
        // can map element positions to scrutinee locals directly.
        var element_ids: std.ArrayList(u32) = .empty;
        var new_scrutinee_list: std.ArrayList(u32) = .empty;
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
            try element_ids.append(allocator, next_id.*);
            try new_scrutinee_list.append(allocator, next_id.*);
            next_id.* += 1;
        }
        if (scrutinee_ids.len > 1) {
            for (scrutinee_ids[1..]) |sid| {
                try new_scrutinee_list.append(allocator, sid);
            }
        }

        const new_col_count = arity + (matrix.column_count - 1);
        const success_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

        const d = try allocator.create(Decision);
        d.* = .{ .check_tuple = .{
            .scrutinee = scrutinee_expr,
            .expected_arity = arity,
            .element_scrutinee_ids = try element_ids.toOwnedSlice(allocator),
            .success = success_decision,
            .failure = current_failure,
        } };
        current_failure = d;
    }

    return current_failure;
}

fn compileListCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect unique lengths from list patterns
    var lengths: std.ArrayList(u32) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .list) {
            const length: u32 = @intCast(pat.?.list.len);
            var found = false;
            for (lengths.items) |l| {
                if (l == length) {
                    found = true;
                    break;
                }
            }
            if (!found) try lengths.append(allocator, length);
        }
    }

    std.sort.pdq(u32, lengths.items, {}, std.sort.asc(u32));

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Build wildcard failure base
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        if (isWildcardPattern(row.patterns[0])) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{ .patterns = new_pats, .body_index = row.body_index, .guard = row.guard });
        }
    }
    var current_failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id, bound_scrutinees);

    // For each unique length, build a check_list node
    var i: usize = lengths.items.len;
    while (i > 0) {
        i -= 1;
        const length = lengths.items[i];

        // Allocate new scrutinee IDs for list elements
        var new_scrutinee_list: std.ArrayList(u32) = .empty;
        for (0..length) |_| {
            try new_scrutinee_list.append(allocator, next_id.*);
            next_id.* += 1;
        }
        for (remaining_scrutinees) |s| {
            try new_scrutinee_list.append(allocator, s);
        }

        const new_col_count = length + (matrix.column_count - 1);

        // Build rows: expand list elements for matching rows, pass wildcards through
        var success_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            const rest_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});

            if (!isWildcardPattern(pat) and pat.?.* == .list and pat.?.list.len == length) {
                // Matching list — expand elements into columns
                var expanded: std.ArrayList(?*const MatchPattern) = .empty;
                for (pat.?.list) |elem| {
                    try expanded.append(allocator, elem);
                }
                for (rest_pats) |rp| {
                    try expanded.append(allocator, rp);
                }
                try success_rows.append(allocator, .{
                    .patterns = try expanded.toOwnedSlice(allocator),
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (isWildcardPattern(pat)) {
                // Wildcards match any length — expand as N wildcards
                var expanded: std.ArrayList(?*const MatchPattern) = .empty;
                for (0..length) |_| {
                    try expanded.append(allocator, null);
                }
                for (rest_pats) |rp| {
                    try expanded.append(allocator, rp);
                }
                try success_rows.append(allocator, .{
                    .patterns = try expanded.toOwnedSlice(allocator),
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const success_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

        const d = try allocator.create(Decision);
        d.* = .{ .check_list = .{
            .scrutinee = scrutinee_expr,
            .expected_length = length,
            .success = success_decision,
            .failure = current_failure,
        } };
        current_failure = d;
    }

    return current_failure;
}

fn compileListConsCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Build wildcard/empty failure base (rows with wildcard or [] patterns)
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat) or (pat != null and pat.?.* == .list and pat.?.list.len == 0)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{ .patterns = new_pats, .body_index = row.body_index, .guard = row.guard });
        }
    }
    const failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id, bound_scrutinees);

    // For cons patterns, extract heads and tail into new scrutinee columns.
    // Determine head_count from the first cons pattern.
    var head_count: u32 = 1;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .list_cons) {
            head_count = @intCast(pat.?.list_cons.heads.len);
            break;
        }
    }

    // Allocate scrutinee IDs for head elements and tail
    var head_ids: std.ArrayList(u32) = .empty;
    for (0..head_count) |_| {
        try head_ids.append(allocator, next_id.*);
        next_id.* += 1;
    }
    const tail_id = next_id.*;
    next_id.* += 1;

    // Build success rows: expand [h | t] into h, t columns
    var new_scrutinee_list: std.ArrayList(u32) = .empty;
    for (head_ids.items) |hid| try new_scrutinee_list.append(allocator, hid);
    try new_scrutinee_list.append(allocator, tail_id);
    for (remaining_scrutinees) |s| try new_scrutinee_list.append(allocator, s);

    const new_col_count = head_count + 1 + (matrix.column_count - 1);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        const rest_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});

        if (!isWildcardPattern(pat) and pat.?.* == .list_cons) {
            // Expand [h1, h2, ... | t] into h1, h2, ..., t columns
            var expanded: std.ArrayList(?*const MatchPattern) = .empty;
            for (pat.?.list_cons.heads) |head| {
                try expanded.append(allocator, head);
            }
            try expanded.append(allocator, pat.?.list_cons.tail);
            for (rest_pats) |rp| try expanded.append(allocator, rp);
            try success_rows.append(allocator, .{
                .patterns = try expanded.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        } else if (isWildcardPattern(pat)) {
            // Wildcards match cons too — expand as N+1 wildcards
            var expanded: std.ArrayList(?*const MatchPattern) = .empty;
            for (0..(head_count + 1)) |_| {
                try expanded.append(allocator, null);
            }
            for (rest_pats) |rp| try expanded.append(allocator, rp);
            try success_rows.append(allocator, .{
                .patterns = try expanded.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const success_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try success_rows.toOwnedSlice(allocator),
        .column_count = new_col_count,
    }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .check_list_cons = .{
        .scrutinee = scrutinee_expr,
        .head_count = head_count,
        .head_scrutinee_ids = try head_ids.toOwnedSlice(allocator),
        .tail_scrutinee_id = tail_id,
        .success = success_decision,
        .failure = failure,
    } };
    return d;
}

fn compileBinaryCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Wildcard rows form the terminal failure: when no binary pattern
    // matches, fall through to wildcard-only matrix (which may itself
    // contain further constructors on remaining columns).
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const wildcard_failure: *const Decision = blk: {
        if (wildcard_rows.items.len > 0) {
            break :blk try compilePatternMatrixWithBindings(allocator, .{
                .rows = try wildcard_rows.toOwnedSlice(allocator),
                .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
            }, remaining_scrutinees, next_id, bound_scrutinees);
        }
        const f = try allocator.create(Decision);
        f.* = .failure;
        break :blk f;
    };

    // Build a per-row chain in REVERSE order so that the first matrix row
    // ends up at the outermost `check_binary`. Earlier code only handled
    // the first row's segments and silently dropped clauses 2+; chaining
    // each row preserves clause order while letting the IR see every
    // pattern's segment shape.
    var chain: *const Decision = wildcard_failure;
    var idx: usize = matrix.rows.len;
    while (idx > 0) {
        idx -= 1;
        const row = matrix.rows[idx];
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .binary_match) continue;

        const segments = pat.?.binary_match.segments;
        const min_byte_size = computeBinaryMinByteSize(segments);

        const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        var success_rows: std.ArrayList(PatternRow) = .empty;
        try success_rows.append(allocator, .{
            .patterns = new_pats,
            .body_index = row.body_index,
            .guard = row.guard,
        });
        // Wildcards still need to be reachable from this success branch
        // when the remaining columns demand them, so keep them in scope.
        for (matrix.rows) |w| {
            if (w.patterns.len == 0) continue;
            if (!isWildcardPattern(w.patterns[0])) continue;
            const tail = if (w.patterns.len > 1) w.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try success_rows.append(allocator, .{
                .patterns = tail,
                .body_index = w.body_index,
                .guard = w.guard,
            });
        }
        const success = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        }, remaining_scrutinees, next_id, bound_scrutinees);

        const node = try allocator.create(Decision);
        node.* = .{ .check_binary = .{
            .scrutinee = scrutinee_expr,
            .min_byte_size = min_byte_size,
            .segments = segments,
            .success = success,
            .failure = chain,
        } };
        chain = node;
    }

    return chain;
}

/// Compute the minimum byte size required by a binary pattern's segments.
/// Sub-byte integer/float types accumulate bit-wise and round up; string
/// segments with literal sizes contribute their byte length.
fn computeBinaryMinByteSize(segments: []const BinaryMatchSegment) u32 {
    var min_bits: u32 = 0;
    for (segments) |seg| {
        switch (seg.type_spec) {
            .default => min_bits += 8,
            .integer => |i| min_bits += i.bits,
            .float => |f| min_bits += f.bits,
            .string => {
                if (min_bits % 8 != 0) min_bits = (min_bits + 7) / 8 * 8;
                if (seg.size) |sz| {
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
    return (min_bits + 7) / 8;
}

fn literalEquals(a: LiteralValue, b: LiteralValue) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .int => |v| v == b.int,
        .float => |v| v == b.float,
        .string => |v| v == b.string,
        .atom => |v| v == b.atom,
        .bool_val => |v| v == b.bool_val,
        .nil => true,
    };
}

// ============================================================
// Operator → protocol mapping
// ============================================================

/// Metadata for routing a binary operator through a protocol impl call.
const OperatorMeta = struct {
    /// Protocol that defines the operator (`Arithmetic`, `Comparator`).
    protocol: []const u8,
    /// Method name as it appears in the impl (`+`, `==`, `rem`, ...).
    method: []const u8,
    /// Result type derived from the operand type. Arithmetic returns
    /// the operand type; comparison returns Bool.
    result_type: *const fn (operand_type: types_mod.TypeId) types_mod.TypeId,
};

fn sameAsOperand(operand_type: types_mod.TypeId) types_mod.TypeId {
    return operand_type;
}

/// Unify two type IDs for the purpose of typing a heterogeneous
/// collection. Equal types unify to themselves. Disagreeing scalar
/// types collapse to `TERM`. Tuples of identical arity unify
/// component-wise — each disagreeing slot becomes `TERM`. Differing
/// arities fall back to the whole element type being `TERM`.
fn unifyForCollection(store: *types_mod.TypeStore, a: types_mod.TypeId, b: types_mod.TypeId) types_mod.TypeId {
    if (a == b) return a;
    if (a == types_mod.TypeStore.UNKNOWN) return b;
    if (b == types_mod.TypeStore.UNKNOWN) return a;
    if (a == types_mod.TypeStore.TERM or b == types_mod.TypeStore.TERM) {
        return types_mod.TypeStore.TERM;
    }
    const ta = store.getType(a);
    const tb = store.getType(b);
    if (ta == .tuple and tb == .tuple and ta.tuple.elements.len == tb.tuple.elements.len) {
        var any_changed = false;
        const unified = store.allocator.alloc(types_mod.TypeId, ta.tuple.elements.len) catch return types_mod.TypeStore.TERM;
        for (ta.tuple.elements, tb.tuple.elements, 0..) |ea, eb, i| {
            const u = unifyForCollection(store, ea, eb);
            if (u != ea) any_changed = true;
            unified[i] = u;
        }
        if (!any_changed) return a;
        return store.addType(.{ .tuple = .{ .elements = unified } }) catch types_mod.TypeStore.TERM;
    }
    if (ta == .list and tb == .list) {
        const u = unifyForCollection(store, ta.list.element, tb.list.element);
        if (u == ta.list.element) return a;
        return store.addType(.{ .list = .{ .element = u } }) catch types_mod.TypeStore.TERM;
    }
    if (ta == .map and tb == .map) {
        const uk = unifyForCollection(store, ta.map.key, tb.map.key);
        const uv = unifyForCollection(store, ta.map.value, tb.map.value);
        if (uk == ta.map.key and uv == ta.map.value) return a;
        return store.addType(.{ .map = .{ .key = uk, .value = uv } }) catch types_mod.TypeStore.TERM;
    }
    return types_mod.TypeStore.TERM;
}

fn alwaysBool(_: types_mod.TypeId) types_mod.TypeId {
    return types_mod.TypeStore.BOOL;
}

/// Map a binary AST op to its protocol/method, or null when the op is
/// handled directly by the primitive ZIR path (logical and/or, in,
/// concat). Operators routed here lower to a call against the matching
/// `impl PROTOCOL for OperandType` when one exists; otherwise they fall
/// through to the primitive path.
fn operatorProtocol(op: ast.BinaryOp.Op) ?OperatorMeta {
    return switch (op) {
        .add => .{ .protocol = "Arithmetic", .method = "+", .result_type = sameAsOperand },
        .sub => .{ .protocol = "Arithmetic", .method = "-", .result_type = sameAsOperand },
        .mul => .{ .protocol = "Arithmetic", .method = "*", .result_type = sameAsOperand },
        .div => .{ .protocol = "Arithmetic", .method = "/", .result_type = sameAsOperand },
        .rem_op => .{ .protocol = "Arithmetic", .method = "rem", .result_type = sameAsOperand },
        .equal => .{ .protocol = "Comparator", .method = "==", .result_type = alwaysBool },
        .not_equal => .{ .protocol = "Comparator", .method = "!=", .result_type = alwaysBool },
        .less => .{ .protocol = "Comparator", .method = "<", .result_type = alwaysBool },
        .greater => .{ .protocol = "Comparator", .method = ">", .result_type = alwaysBool },
        .less_equal => .{ .protocol = "Comparator", .method = "<=", .result_type = alwaysBool },
        .greater_equal => .{ .protocol = "Comparator", .method = ">=", .result_type = alwaysBool },
        else => null,
    };
}

// ============================================================
// HIR builder — converts typed AST to HIR
// ============================================================

pub const HirBuilder = struct {
    allocator: std.mem.Allocator,
    interner: *const ast.StringInterner,
    graph: *const scope_mod.ScopeGraph,
    type_store: *types_mod.TypeStore,
    next_group_id: u32,
    next_local: u32,
    current_param_names: []const ?ast.StringId,
    /// Parallel to `current_param_names`. Holds each parameter's TypeId
    /// so var_ref resolution against a parameter sees the type the type
    /// checker (or `inferred_signatures` for synthetic helpers like
    /// for-comp `__for_N`) assigned. The scope-graph binding entry
    /// often doesn't have `type_id` populated for synthetic helpers,
    /// so this in-memory copy is the source of truth during HIR build.
    /// Critical for HIR-time protocol dispatch on
    /// `Enumerable.next(state)` where `state` is the helper's param.
    current_param_types: []const TypeId,
    current_tuple_bindings: std.ArrayList(TupleBinding),
    current_struct_bindings: std.ArrayList(StructBinding),
    current_list_bindings: std.ArrayList(ListBinding),
    current_cons_tail_bindings: std.ArrayList(ConsTailBinding),
    current_binary_bindings: std.ArrayList(BinaryBinding),
    current_map_bindings: std.ArrayList(MapBinding),
    current_case_bindings: std.ArrayList(CaseBinding),
    current_assignment_bindings: std.ArrayList(AssignmentBinding),
    /// Parent function's assignment bindings — used for closure capture detection.
    /// When a closure references a variable from the parent function's bindings,
    /// it generates capture_get instead of local_get.
    parent_assignment_bindings: std.ArrayList(AssignmentBinding),
    current_module_scope: ?scope_mod.ScopeId,
    current_clause_scope: ?scope_mod.ScopeId,
    /// Set while building the function groups for an `impl Protocol for
    /// Target(K, V)` block. Carries the impl's declared type parameters
    /// so each clause's `hir_type_var_scope` can be pre-populated with
    /// the same K, V bindings as the type checker used. Without this,
    /// `Map(K, V)` in the impl's signatures would resolve to an UNKNOWN
    /// type because HIR's type-var lookup wouldn't find K or V.
    current_impl: ?*const ast.ImplDecl = null,
    current_function_root_scope: ?scope_mod.ScopeId,
    current_function_name: ?[]const u8,
    current_function_name_id: ?ast.StringId,
    /// Variable names already bound in the current clause's parameters.
    /// When a bind pattern reuses a name from this set, it becomes a pin
    /// (equality check) instead of a fresh binding — Elixir-style variable
    /// unification.
    clause_bound_names: std.AutoHashMap(ast.StringId, void),
    family_to_group: std.AutoHashMap(scope_mod.FunctionFamilyId, u32),
    group_captures: std.AutoHashMap(u32, []const Capture),
    current_capture_map: std.AutoHashMap(ast.StringId, u32),
    current_capture_list: std.ArrayList(Capture),
    /// Maps type variable names to TypeIds within the current function clause,
    /// ensuring `a` in `fn foo(x :: a) -> a` refers to the same type variable.
    hir_type_var_scope: std.StringHashMap(types_mod.TypeId),
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        interner: *const ast.StringInterner,
        graph: *const scope_mod.ScopeGraph,
        type_store: *types_mod.TypeStore,
    ) HirBuilder {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .type_store = type_store,
            .next_group_id = 0,
            .next_local = 0,
            .current_param_names = &.{},
            .current_param_types = &.{},
            .current_tuple_bindings = .empty,
            .current_struct_bindings = .empty,
            .current_list_bindings = .empty,
            .current_cons_tail_bindings = .empty,
            .current_binary_bindings = .empty,
            .current_map_bindings = .empty,
            .current_case_bindings = .empty,
            .current_assignment_bindings = .empty,
            .parent_assignment_bindings = .empty,
            .current_module_scope = null,
            .current_clause_scope = null,
            .current_function_root_scope = null,
            .current_function_name = null,
            .current_function_name_id = null,
            .clause_bound_names = std.AutoHashMap(ast.StringId, void).init(allocator),
            .family_to_group = std.AutoHashMap(scope_mod.FunctionFamilyId, u32).init(allocator),
            .group_captures = std.AutoHashMap(u32, []const Capture).init(allocator),
            .current_capture_map = std.AutoHashMap(ast.StringId, u32).init(allocator),
            .current_capture_list = .empty,
            .hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(allocator),
            .errors = .empty,
        };
    }

    pub fn deinit(self: *HirBuilder) void {
        self.family_to_group.deinit();
        self.group_captures.deinit();
        self.current_capture_map.deinit();
        self.current_capture_list.deinit(self.allocator);
        self.current_assignment_bindings.deinit(self.allocator);
        self.current_tuple_bindings.deinit(self.allocator);
        self.current_struct_bindings.deinit(self.allocator);
        self.current_list_bindings.deinit(self.allocator);
        self.current_cons_tail_bindings.deinit(self.allocator);
        self.current_binary_bindings.deinit(self.allocator);
        self.current_map_bindings.deinit(self.allocator);
        self.current_case_bindings.deinit(self.allocator);
        self.parent_assignment_bindings.deinit(self.allocator);
        self.hir_type_var_scope.deinit();
        self.errors.deinit(self.allocator);
    }

    /// Look up a binding's type_id from the scope graph.
    /// Returns the type_id if found, otherwise UNKNOWN.
    fn resolveBindingType(self: *const HirBuilder, name: ast.StringId) types_mod.TypeId {
        // Check assignment bindings first — these have types from the value
        // expression and are always valid regardless of scope chain direction.
        for (self.current_assignment_bindings.items) |binding| {
            if (binding.name == name and binding.type_id != types_mod.TypeStore.UNKNOWN) {
                return binding.type_id;
            }
        }
        // Scope graph binding — populated by the type checker. Tests rely on
        // mutating the type at this site after type-checking but before HIR
        // build, so this must take precedence over the in-memory parameter
        // copy populated below.
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveBinding(scope_id, name)) |bid| {
            const binding = self.graph.bindings.items[bid];
            if (binding.type_id) |prov| {
                return prov.type_id;
            }
        }
        if (self.current_clause_scope) |cs| {
            const scope = self.graph.getScope(cs);
            var it = scope.bindings.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* == name) {
                    const bid = entry.value_ptr.*;
                    const binding = self.graph.bindings.items[bid];
                    if (binding.type_id) |prov| {
                        return prov.type_id;
                    }
                }
            }
        }
        // Fall back to in-memory parameter types. The scope graph binding
        // for a parameter doesn't carry an inferred type for synthetic
        // helpers (e.g. for-comp `__for_N`), so this parallel array
        // populated in buildClause is the source of truth in that case.
        for (self.current_param_names, 0..) |maybe_name, idx| {
            if (maybe_name) |pn| {
                if (pn == name and idx < self.current_param_types.len) {
                    const tid = self.current_param_types[idx];
                    if (tid != types_mod.TypeStore.UNKNOWN) return tid;
                }
            }
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Look up a function's declared return type from the scope graph.
    /// Searches current module scope, then prelude.
    /// Resolve a generic function's return type by unifying argument types with
    /// parameter types and applying the substitution to the raw return type.
    fn resolveGenericReturnType(
        self: *const HirBuilder,
        mod_name: []const u8,
        func_name: []const u8,
        arity: u32,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        // Find the function's parameter types
        for (self.graph.structs.items) |mod_entry| {
            if (mod_entry.name.parts.len == 0) continue;
            const last_part = self.interner.get(mod_entry.name.parts[mod_entry.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, mod_name)) continue;
            for (self.graph.families.items) |family| {
                if (family.scope_id != mod_entry.scope_id) continue;
                if (family.arity != arity) continue;
                if (!std.mem.eql(u8, self.interner.get(family.name), func_name)) continue;
                if (family.clauses.items.len == 0) continue;
                const first_clause = family.clauses.items[0];
                if (first_clause.clause_index >= first_clause.decl.clauses.len) continue;
                const clause = first_clause.decl.clauses[first_clause.clause_index];
                if (clause.params.len != arity) continue;
                return self.substituteReturnTypeFromArgs(&clause, call_args, raw_return);
            }
        }
        return raw_return;
    }

    /// Resolve a generic function's return type for a local-scope call by
    /// walking the scope chain to find the family. Mirrors
    /// `resolveGenericReturnType` but uses scope-based resolution instead
    /// of module-name-based.
    fn resolveGenericReturnTypeLocal(
        self: *const HirBuilder,
        name: ast.StringId,
        arity: u32,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        const fam_id = self.graph.resolveFamily(scope_id, name, arity) orelse return raw_return;
        const family = self.graph.getFamily(fam_id);
        if (family.clauses.items.len == 0) return raw_return;
        const first_clause = family.clauses.items[0];
        if (first_clause.clause_index >= first_clause.decl.clauses.len) return raw_return;
        const clause = first_clause.decl.clauses[first_clause.clause_index];
        if (clause.params.len != arity) return raw_return;
        return self.substituteReturnTypeFromArgs(&clause, call_args, raw_return);
    }

    /// Shared inference: walk params, unify with arg types into a substitution
    /// map, apply the substitution to the raw return type. Returns the raw
    /// return type unchanged when no inference is possible.
    ///
    /// The CALLED function's type variables (e.g., `a` in `pub fn +(a, a) -> a`)
    /// are resolved in a fresh `hir_type_var_scope` so that the surrounding
    /// clause's existing type-var bindings (e.g., `element` in the enclosing
    /// `fn map(list :: [element], f) -> [element]`) survive across the inference.
    fn substituteReturnTypeFromArgs(
        self: *const HirBuilder,
        clause: *const ast.FunctionClause,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        const self_mut: *HirBuilder = @constCast(self);
        const saved_scope = self_mut.hir_type_var_scope;
        self_mut.hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(self.allocator);
        defer {
            self_mut.hir_type_var_scope.deinit();
            self_mut.hir_type_var_scope = saved_scope;
        }

        var subs = types_mod.SubstitutionMap.init(self.allocator);
        for (clause.params, 0..) |param, i| {
            if (i >= call_args.len) break;
            var arg_type = call_args[i].expr.type_id;
            if (arg_type == types_mod.TypeStore.UNKNOWN) {
                if (call_args[i].expr.kind == .list_init and call_args[i].expr.kind.list_init.len == 0) {
                    const store_ptr2: *types_mod.TypeStore = @constCast(self.type_store);
                    arg_type = store_ptr2.addType(.{ .list = .{ .element = types_mod.TypeStore.I64 } }) catch types_mod.TypeStore.UNKNOWN;
                }
                if (arg_type == types_mod.TypeStore.UNKNOWN) continue;
            }
            if (param.type_annotation) |ta| {
                const param_type = self.resolveTypeExpr(ta);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                _ = store_ptr.unify(param_type, arg_type, &subs) catch {};
            }
        }
        if (subs.bindings.count() > 0) {
            // Resolve raw_return through the same type var scope, then substitute.
            if (clause.return_type) |rt| {
                const resolved_return = self.resolveTypeExpr(rt);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return subs.applyToType(store_ptr, resolved_return);
            }
            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
            return subs.applyToType(store_ptr, raw_return);
        }
        // No inference possible (all args UNKNOWN, e.g. case-clause bindings
        // without propagated types). Return UNKNOWN rather than an unresolved
        // type variable so downstream UNKNOWN-tolerant checks apply.
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
        if (store_ptr.containsTypeVars(raw_return)) return types_mod.TypeStore.UNKNOWN;
        return raw_return;
    }

    /// Resolve a function's return type within a specific struct
    /// (for cross-struct calls).
    fn resolveFunctionReturnTypeInModule(self: *const HirBuilder, struct_simple: []const u8, func_name: []const u8, arity: u32) types_mod.TypeId {
        // Find the matching struct's scope, then look up the family
        // via the scope's `function_families` map. The map covers
        // both functions declared inside the struct AND impl
        // functions registered via
        // `registerImplFunctionsInTargetScopes` — critical for
        // protocol dispatch through `String.concat`, `List.next`,
        // etc., where the impl-defined family lives in the impl's
        // own scope but is reachable from the target struct's scope
        // via the registered map entry.
        const func_name_id = self.interner.lookupExisting(func_name) orelse return types_mod.TypeStore.UNKNOWN;
        const key = scope_mod.FamilyKey{ .name = func_name_id, .arity = arity };
        for (self.graph.structs.items) |struct_entry| {
            if (struct_entry.name.parts.len == 0) continue;
            const last_part = self.interner.get(struct_entry.name.parts[struct_entry.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, struct_simple)) continue;
            const struct_scope = self.graph.getScope(struct_entry.scope_id);
            const fam_id = struct_scope.function_families.get(key) orelse continue;
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 0) {
                const first_clause = family.clauses.items[0];
                if (first_clause.clause_index < first_clause.decl.clauses.len) {
                    const clause = first_clause.decl.clauses[first_clause.clause_index];
                    if (clause.return_type) |rt| {
                        return self.resolveTypeExpr(rt);
                    }
                }
            }
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    fn resolveFunctionReturnType(self: *const HirBuilder, name: ast.StringId, arity: u32) types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveFamily(scope_id, name, arity)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 0) {
                const first_clause = family.clauses.items[0];
                if (first_clause.clause_index < first_clause.decl.clauses.len) {
                    const clause = first_clause.decl.clauses[first_clause.clause_index];
                    if (clause.return_type) |rt| {
                        return self.resolveTypeExpr(rt);
                    }
                }
            }
        }
        // Synthetic helpers (`__for_N`) carry no source-level return
        // annotation but the type checker writes a call-site-inferred
        // return type into `inferred_signatures` once the body has been
        // checked. Falling back to that here lets recursive calls see
        // the right element type for cons emission, etc.
        if (self.type_store.inferred_signatures.get(name)) |sig| {
            return sig.return_type;
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Check if a function (by name and arity) is dispatched: i.e., one of its
    /// clauses can fail to match at runtime, so the call may produce a "no
    /// matching clause" outcome that a `~>` catch basin should be able to catch.
    ///
    /// A function is dispatched when EITHER:
    ///   * it has multiple clauses (the dispatcher must select one), OR
    ///   * its single clause has a non-trivial parameter pattern or a
    ///     refinement guard, so calling it with an unmatched argument is a
    ///     dispatch failure rather than a sure-match.
    ///
    /// Pure variable-binding / wildcard clauses with no guard are always
    /// total — they don't need a `__try` variant and would not benefit from
    /// catch-basin handling.
    fn isFunctionMultiClause(self: *const HirBuilder, name: ast.StringId, arity: u32) bool {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveFamily(scope_id, name, arity)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 1) return true;
            if (family.clauses.items.len == 1) {
                const clause_ref = family.clauses.items[0];
                const clause = clause_ref.decl.clauses[clause_ref.clause_index];
                if (clause.refinement != null) return true;
                for (clause.params) |param| {
                    if (!isTotalParamPattern(param.pattern)) return true;
                }
            }
        }
        return false;
    }

    /// A parameter pattern is "total" when it is guaranteed to match any
    /// runtime value of its declared type without inspecting the value.
    /// Bare bindings, wildcards, and parenthesised total patterns qualify.
    /// Anything that does runtime structural inspection (literals, tuples,
    /// lists, maps, struct patterns, binaries, pins) is non-total.
    fn isTotalParamPattern(pattern: *const ast.Pattern) bool {
        return switch (pattern.*) {
            .wildcard, .bind => true,
            .paren => |p| isTotalParamPattern(p.inner),
            else => false,
        };
    }

    fn applyCallArgModes(self: *const HirBuilder, args: []CallArg, callee_type_id: types_mod.TypeId) void {
        if (callee_type_id == types_mod.TypeStore.UNKNOWN) return;
        const callee_type = self.type_store.getType(callee_type_id);
        if (callee_type != .function) return;
        const ownerships = callee_type.function.param_ownerships orelse return;
        const count = @min(args.len, ownerships.len);
        for (args[0..count], ownerships[0..count]) |*arg, ownership| {
            arg.mode = switch (ownership) {
                .shared => .share,
                .unique => .move,
                .borrowed => .borrow,
            };
        }
    }

    fn defaultOwnershipForType(self: *const HirBuilder, type_id: types_mod.TypeId) Ownership {
        const typ = self.type_store.getType(type_id);
        return switch (typ) {
            .opaque_type => .unique,
            else => .shared,
        };
    }

    fn resolveParamOwnership(self: *const HirBuilder, param: ast.Param, resolved_type: types_mod.TypeId) Ownership {
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

    fn resolveFunctionParamOwnerships(self: *HirBuilder, name: ast.StringId, arity: u32) ?[]const Ownership {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];

        const ownerships = self.allocator.alloc(Ownership, clause.params.len) catch return null;
        for (clause.params, 0..) |param, idx| {
            ownerships[idx] = blk: {
                if (param.pattern.* == .bind) {
                    const clause_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
                    if (self.graph.resolveBinding(clause_scope, param.pattern.bind.name)) |binding_id| {
                        if (self.graph.bindings.items[binding_id].type_id) |prov| {
                            break :blk self.resolveParamOwnership(param, prov.type_id);
                        }
                    }
                }
                if (param.type_annotation) |ann| {
                    break :blk self.resolveParamOwnership(param, self.resolveTypeExpr(ann));
                }
                break :blk .shared;
            };
        }
        return ownerships;
    }

    /// Resolve the declared parameter types for a function by name and arity.
    /// Used to populate CallArg.expected_type for implicit numeric widening.
    fn resolveFunctionParamTypes(self: *HirBuilder, name: ast.StringId, arity: u32) ?[]const types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];

        const param_types = self.allocator.alloc(types_mod.TypeId, clause.params.len) catch return null;
        for (clause.params, 0..) |param, idx| {
            param_types[idx] = blk: {
                if (param.pattern.* == .bind) {
                    const clause_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
                    if (self.graph.resolveBinding(clause_scope, param.pattern.bind.name)) |binding_id| {
                        if (self.graph.bindings.items[binding_id].type_id) |prov| {
                            break :blk prov.type_id;
                        }
                    }
                }
                if (param.type_annotation) |ann| {
                    break :blk self.resolveTypeExpr(ann);
                }
                break :blk types_mod.TypeStore.UNKNOWN;
            };
        }
        return param_types;
    }

    fn resolveFunctionValueGroup(self: *const HirBuilder, name: ast.StringId) ?u32 {
        var current: ?scope_mod.ScopeId = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        var found: ?u32 = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                const group_id = self.family_to_group.get(entry.value_ptr.*) orelse continue;
                if (found != null) return null;
                found = group_id;
            }
            current = self.graph.getScope(sid).parent;
        }
        return found;
    }

    fn buildResolvedFunctionType(self: *HirBuilder, clause: ast.FunctionClause) anyerror!types_mod.TypeId {
        const params = try self.allocator.alloc(types_mod.TypeId, clause.params.len);
        const ownerships = try self.allocator.alloc(Ownership, clause.params.len);
        for (clause.params, 0..) |param, idx| {
            const param_type = if (param.type_annotation) |ann|
                self.resolveTypeExpr(ann)
            else
                types_mod.TypeStore.UNKNOWN;
            params[idx] = param_type;
            ownerships[idx] = self.resolveParamOwnership(param, param_type);
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
        else
            types_mod.TypeStore.UNKNOWN;

        return try self.type_store.addFunctionType(params, return_type, ownerships, self.defaultOwnershipForType(return_type));
    }

    fn resolveFunctionValueType(self: *HirBuilder, name: ast.StringId) anyerror!types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        var current: ?scope_mod.ScopeId = scope_id;
        var found_clause: ?ast.FunctionClause = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                const family = self.graph.getFamily(entry.value_ptr.*);
                if (family.clauses.items.len == 0) continue;
                const clause_ref = family.clauses.items[0];
                const clause = clause_ref.decl.clauses[clause_ref.clause_index];
                if (found_clause == null) {
                    found_clause = clause;
                }
                // Don't reject duplicates — the first match wins.
                // Duplicates can occur when a function is visible from both
                // the current scope and a parent scope in the chain.
            }
            current = self.graph.getScope(sid).parent;
        }

        if (found_clause) |clause| {
            return try self.buildResolvedFunctionType(clause);
        }

        return types_mod.TypeStore.UNKNOWN;
    }

    fn resolveFunctionRefType(self: *HirBuilder, fr: ast.FunctionRefExpr) anyerror!types_mod.TypeId {
        const scope_id = if (fr.module) |module_name|
            self.graph.findStructScope(module_name)
        else
            self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;

        const resolved_scope = scope_id orelse return types_mod.TypeStore.UNKNOWN;
        const family_id = self.graph.resolveFamily(resolved_scope, fr.function, fr.arity) orelse return types_mod.TypeStore.UNKNOWN;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return types_mod.TypeStore.UNKNOWN;
        const clause_ref = family.clauses.items[0];
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        return try self.buildResolvedFunctionType(clause);
    }

    fn resolveFunctionRefGroup(self: *const HirBuilder, fr: ast.FunctionRefExpr) ?u32 {
        const scope_id = if (fr.module) |module_name|
            self.graph.findStructScope(module_name)
        else
            self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;

        const resolved_scope = scope_id orelse return null;
        const family_id = self.graph.resolveFamily(resolved_scope, fr.function, fr.arity) orelse return null;
        return self.family_to_group.get(family_id);
    }

    fn buildFunctionValueExpr(self: *HirBuilder, group_id: u32, type_id: types_mod.TypeId, span: ast.SourceSpan) anyerror!*const Expr {
        const group_captures = self.group_captures.get(group_id) orelse &.{};
        var capture_values: std.ArrayList(CaptureValue) = .empty;
        for (group_captures) |capture| {
            try capture_values.append(self.allocator, .{
                .expr = (try self.buildBindingReference(capture.name, capture.type_id, span)) orelse return error.OutOfMemory,
                .ownership = capture.ownership,
            });
        }
        return try self.create(Expr, .{
            .kind = .{ .closure_create = .{
                .function_group_id = group_id,
                .captures = try capture_values.toOwnedSlice(self.allocator),
            } },
            .type_id = type_id,
            .span = span,
        });
    }

    fn isScopeWithinFunctionRoot(self: *const HirBuilder, scope_id: scope_mod.ScopeId) bool {
        const root = self.current_function_root_scope orelse return false;
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            if (sid == root) return true;
            current = self.graph.getScope(sid).parent;
        }
        return false;
    }

    fn captureIndexForBinding(self: *HirBuilder, binding_id: scope_mod.BindingId) !?u32 {
        const binding = self.graph.bindings.items[binding_id];
        if (self.isScopeWithinFunctionRoot(binding.scope_id)) return null;

        if (self.current_capture_map.get(binding.name)) |idx| return idx;

        const idx: u32 = @intCast(self.current_capture_list.items.len);
        const ownership = if (binding.type_id) |prov| switch (prov.ownership) {
            .shared => Ownership.shared,
            .unique => Ownership.unique,
            .borrowed => Ownership.borrowed,
        } else Ownership.shared;
        try self.current_capture_list.append(self.allocator, .{
            .name = binding.name,
            .type_id = if (binding.type_id) |prov| prov.type_id else types_mod.TypeStore.UNKNOWN,
            .ownership = ownership,
        });
        try self.current_capture_map.put(binding.name, idx);
        return idx;
    }

    fn buildBindingReference(self: *HirBuilder, name: ast.StringId, type_id: TypeId, span: ast.SourceSpan) anyerror!?*const Expr {
        for (self.current_param_names, 0..) |param_name, idx| {
            if (param_name) |pn| {
                if (pn == name) {
                    return try self.create(Expr, .{
                        .kind = .{ .param_get = @intCast(idx) },
                        .type_id = type_id,
                        .span = span,
                    });
                }
            }
        }
        for (self.current_tuple_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_struct_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_list_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_cons_tail_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_binary_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_map_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_case_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_assignment_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }

        // Check parent function's assignment bindings — these are variables
        // from the enclosing function that need to be captured, not accessed
        // directly via local_get.
        for (self.parent_assignment_bindings.items) |binding| {
            if (binding.name == name) {
                // Create a capture for this parent binding
                const capture_type = binding.type_id;
                const idx: u32 = @intCast(self.current_capture_list.items.len);
                try self.current_capture_list.append(self.allocator, .{
                    .name = binding.name,
                    .type_id = capture_type,
                    .ownership = .shared,
                });
                try self.current_capture_map.put(binding.name, idx);
                return try self.create(Expr, .{
                    .kind = .{ .capture_get = idx },
                    .type_id = type_id,
                    .span = span,
                });
            }
        }

        if (self.current_clause_scope) |scope_id| {
            if (self.graph.resolveBinding(scope_id, name)) |binding_id| {
                const capture_result = try self.captureIndexForBinding(binding_id);
                if (capture_result) |capture_idx| {
                    return try self.create(Expr, .{
                        .kind = .{ .capture_get = capture_idx },
                        .type_id = type_id,
                        .span = span,
                    });
                }
            }
        }

        return null;
    }

    // ============================================================
    // Program lowering
    // ============================================================

    pub fn buildProgram(self: *HirBuilder, program: *const ast.Program) !Program {
        var modules: std.ArrayList(Module) = .empty;
        for (program.structs) |*mod| {
            const mod_scope = self.graph.findStructScope(mod.name) orelse
                self.graph.prelude_scope;
            self.current_module_scope = mod_scope;
            try modules.append(self.allocator, try self.buildStruct(mod, mod_scope));
            self.current_module_scope = null;
        }

        // Group top-level functions by name, merging clauses
        var fn_order: std.ArrayList(ast.StringId) = .empty;
        var fn_groups = std.AutoHashMap(ast.StringId, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
        defer fn_groups.deinit();

        for (program.top_items) |item| {
            const func = switch (item) {
                .function => |f| f,
                .priv_function => |f| f,
                else => continue,
            };
            const entry = try fn_groups.getOrPut(func.name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                try fn_order.append(self.allocator, func.name);
            }
            try entry.value_ptr.append(self.allocator, func);
        }

        var top_fns: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |name| {
            if (fn_groups.getPtr(name)) |decls| {
                try top_fns.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, self.graph.prelude_scope));
            }
        }

        // Build impl function groups and place them in the target module's
        // functions array so cross-module calls (`Integer.+`) resolve through
        // the normal module-qualified call path. Each module compilation
        // pass sees the global impl set; we skip impls whose target isn't in
        // the modules list for this pass to avoid emitting them as orphan
        // root-level functions.
        for (self.graph.impls.items) |impl_entry| {
            var target_module_idx: ?usize = null;
            for (modules.items, 0..) |mod, idx| {
                if (self.structNamesEqual(mod.name, impl_entry.target_type)) {
                    target_module_idx = idx;
                    break;
                }
            }
            if (target_module_idx == null) continue;

            self.current_module_scope = impl_entry.scope_id;
            const prev_impl = self.current_impl;
            self.current_impl = impl_entry.decl;
            defer self.current_impl = prev_impl;
            // Group impl functions by name (multi-clause merge), local to this impl.
            var impl_fn_order: std.ArrayList(ast.StringId) = .empty;
            var impl_fn_groups = std.AutoHashMap(ast.StringId, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
            defer impl_fn_groups.deinit();
            for (impl_entry.decl.functions) |func| {
                const entry = try impl_fn_groups.getOrPut(func.name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                    try impl_fn_order.append(self.allocator, func.name);
                }
                try entry.value_ptr.append(self.allocator, func);
            }
            var impl_groups: std.ArrayList(FunctionGroup) = .empty;
            for (impl_fn_order.items) |name| {
                if (impl_fn_groups.getPtr(name)) |decls| {
                    const group = try self.buildMergedFunctionGroup(decls.items, impl_entry.scope_id);
                    try impl_groups.append(self.allocator, group);
                }
            }
            self.current_module_scope = null;

            // Splice impl groups onto the target module's functions list.
            var combined: std.ArrayList(FunctionGroup) = .empty;
            try combined.appendSlice(self.allocator, modules.items[target_module_idx.?].functions);
            try combined.appendSlice(self.allocator, impl_groups.items);
            modules.items[target_module_idx.?].functions = try combined.toOwnedSlice(self.allocator);
        }

        // Build protocol info from scope graph
        var protocol_infos: std.ArrayList(ProtocolInfo) = .empty;
        for (self.graph.protocols.items) |proto| {
            var names: std.ArrayList(ast.StringId) = .empty;
            var arities: std.ArrayList(u32) = .empty;
            for (proto.decl.functions) |sig| {
                try names.append(self.allocator, sig.name);
                try arities.append(self.allocator, @intCast(sig.params.len));
            }
            try protocol_infos.append(self.allocator, .{
                .name = proto.name.parts[proto.name.parts.len - 1],
                .function_names = try names.toOwnedSlice(self.allocator),
                .function_arities = try arities.toOwnedSlice(self.allocator),
            });
        }

        // Build impl info from scope graph
        var impl_infos: std.ArrayList(ImplInfo) = .empty;
        for (self.graph.impls.items) |impl_entry| {
            var group_ids: std.ArrayList(u32) = .empty;
            // Find function groups that were built from this impl
            for (top_fns.items) |group| {
                if (group.scope_id == impl_entry.scope_id) {
                    try group_ids.append(self.allocator, group.id);
                }
            }
            if (impl_entry.protocol_name.parts.len > 0 and impl_entry.target_type.parts.len > 0) {
                try impl_infos.append(self.allocator, .{
                    .protocol_name = impl_entry.protocol_name.parts[impl_entry.protocol_name.parts.len - 1],
                    .target_module = impl_entry.target_type.parts[impl_entry.target_type.parts.len - 1],
                    .impl_scope_id = impl_entry.scope_id,
                    .function_group_ids = try group_ids.toOwnedSlice(self.allocator),
                });
            }
        }

        return .{
            .modules = try modules.toOwnedSlice(self.allocator),
            .top_functions = try top_fns.toOwnedSlice(self.allocator),
            .protocols = try protocol_infos.toOwnedSlice(self.allocator),
            .impls = try impl_infos.toOwnedSlice(self.allocator),
        };
    }

    fn buildStruct(self: *HirBuilder, mod: *const ast.StructDecl, mod_scope: scope_mod.ScopeId) !Module {
        // Group module functions by {name, arity} so that same-name
        // functions with different arities become separate groups.
        const FnGroupKey = struct { name: ast.StringId, arity: u32 };
        var fn_order: std.ArrayList(FnGroupKey) = .empty;
        var fn_groups = std.AutoHashMap(FnGroupKey, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
        defer fn_groups.deinit();

        var type_defs: std.ArrayList(TypeDef) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                    const key = FnGroupKey{ .name = func.name, .arity = arity };
                    const entry = try fn_groups.getOrPut(key);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .empty;
                        try fn_order.append(self.allocator, key);
                    }
                    try entry.value_ptr.append(self.allocator, func);
                },
                .type_decl => |td| {
                    try type_defs.append(self.allocator, .{
                        .name = td.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .alias,
                    });
                },
                .opaque_decl => |od| {
                    try type_defs.append(self.allocator, .{
                        .name = od.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .opaque_type,
                    });
                },
                .struct_decl => |sd| {
                    try type_defs.append(self.allocator, .{
                        .name = if (sd.name.parts.len > 0) sd.name.parts[0] else 0,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .struct_type,
                    });
                },
                .union_decl => |ed| {
                    try type_defs.append(self.allocator, .{
                        .name = ed.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .alias, // enums are emitted directly as type defs
                    });
                },
                else => {},
            }
        }

        // If the module has module-level expressions (e.g., describe/test macro
        // calls), synthesize a pub fn run() -> String { <exprs>; "done" } and
        // add it to fn_groups — unless the module already declares run/0.
        {
            var module_exprs: std.ArrayList(*const ast.Expr) = .empty;
            for (mod.items) |item| {
                if (item == .struct_level_expr) {
                    try module_exprs.append(self.allocator, item.struct_level_expr);
                }
            }
            if (module_exprs.items.len > 0) {
                // Find the StringId for "run" by scanning existing interned strings
                const run_name: ?ast.StringId = blk: {
                    var sid: ast.StringId = 0;
                    while (sid < self.interner.strings.items.len) : (sid += 1) {
                        if (std.mem.eql(u8, self.interner.get(sid), "run")) break :blk sid;
                    }
                    break :blk null;
                };

                // Only generate run/0 if the string "run" exists in the interner
                // (it will exist because test modules import Zest.Runner which has run)
                if (run_name) |rn| {
                    var has_run = false;
                    if (fn_groups.get(.{ .name = rn, .arity = 0 })) |_| has_run = true;
                    if (!has_run) {
                        // Build AST statements from the module-level expressions
                        var stmts = try self.allocator.alloc(ast.Stmt, module_exprs.items.len);
                        for (module_exprs.items, 0..) |expr, idx| {
                            stmts[idx] = .{ .expr = expr };
                        }

                        // Find StringId for the native string type. Falls
                        // back to scanning the interner only if the
                        // stdlib hasn't registered a `@native_type =
                        // "string"` struct yet (e.g. compiling the
                        // string stdlib module itself).
                        const string_tid: ast.StringId = self.graph.nativeTypeStructName(.string) orelse st_blk: {
                            var sid: ast.StringId = 0;
                            while (sid < self.interner.strings.items.len) : (sid += 1) {
                                if (std.mem.eql(u8, self.interner.get(sid), "String")) break :st_blk sid;
                            }
                            break :st_blk 0;
                        };

                        // Synthesize: pub fn run() -> String { <stmts> }
                        const string_type = try self.allocator.create(ast.TypeExpr);
                        string_type.* = .{ .name = .{
                            .meta = mod.meta,
                            .name = string_tid,
                            .args = &.{},
                        } };
                        const clause = try self.allocator.create(ast.FunctionClause);
                        clause.* = .{
                            .meta = mod.meta,
                            .params = &.{},
                            .return_type = string_type,
                            .refinement = null,
                            .body = stmts,
                        };
                        const run_decl = try self.allocator.create(ast.FunctionDecl);
                        run_decl.* = .{
                            .meta = mod.meta,
                            .name = rn,
                            .clauses = try self.allocator.dupe(ast.FunctionClause, &.{clause.*}),
                            .visibility = .public,
                        };

                        const run_key = FnGroupKey{ .name = rn, .arity = 0 };
                        const entry = try fn_groups.getOrPut(run_key);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = .empty;
                            try fn_order.append(self.allocator, run_key);
                        }
                        try entry.value_ptr.append(self.allocator, run_decl);
                    }
                }
            }
        }

        // Pre-register all declared function families in family_to_group
        // so that function references like &name/arity can resolve any
        // sibling function regardless of declaration order.
        for (fn_order.items) |key| {
            if (fn_groups.getPtr(key)) |_| {
                if (self.graph.resolveFamily(mod_scope, key.name, key.arity)) |family_id| {
                    if (!self.family_to_group.contains(family_id)) {
                        const pre_id = self.next_group_id;
                        self.next_group_id += 1;
                        try self.family_to_group.put(family_id, pre_id);
                    }
                }
            }
        }

        var functions: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |key| {
            if (fn_groups.getPtr(key)) |decls| {
                try functions.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, mod_scope));
            }
        }

        return .{
            .name = mod.name,
            .scope_id = mod_scope,
            .functions = try functions.toOwnedSlice(self.allocator),
            .types = try type_defs.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Function group building
    // ============================================================

    fn buildMergedFunctionGroup(
        self: *HirBuilder,
        decls: []const *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
    ) !FunctionGroup {
        // Reuse a pre-assigned group ID if one exists (from pre-registration),
        // otherwise allocate a new one.
        const arity: u32 = if (decls[0].clauses.len > 0) @intCast(decls[0].clauses[0].params.len) else 0;
        const group_id = blk: {
            if (self.graph.resolveFamily(scope_id, decls[0].name, arity)) |family_id| {
                if (self.family_to_group.get(family_id)) |existing_id| {
                    break :blk existing_id;
                }
                const new_id = self.next_group_id;
                self.next_group_id += 1;
                try self.family_to_group.put(family_id, new_id);
                break :blk new_id;
            }
            const new_id = self.next_group_id;
            self.next_group_id += 1;
            break :blk new_id;
        };

        self.current_function_name = self.interner.get(decls[0].name);
        self.current_function_name_id = decls[0].name;

        var clauses: std.ArrayList(Clause) = .empty;
        for (decls) |func| {
            for (func.clauses) |clause| {
                try clauses.append(self.allocator, try self.buildClause(&clause));
            }
        }

        const first = decls[0];
        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = first.name,
            .arity = arity,
            .is_local = false,
            .captures = &.{},
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = null,
        };
    }

    fn buildFunctionGroup(
        self: *HirBuilder,
        func: *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
        fallback_parent: ?u32,
        is_local: bool,
    ) !FunctionGroup {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

        const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
        if (self.graph.resolveFamily(scope_id, func.name, arity)) |family_id| {
            try self.family_to_group.put(family_id, group_id);
        }

        const saved_function_name = self.current_function_name;
        const saved_function_name_id = self.current_function_name_id;
        self.current_function_name = self.interner.get(func.name);
        self.current_function_name_id = func.name;
        const saved_next_local = self.next_local;
        const saved_root_scope = self.current_function_root_scope;
        const saved_capture_map = self.current_capture_map;
        const saved_capture_list = self.current_capture_list;
        // Save the enclosing function's parameter signature so that any
        // expressions built AFTER this nested group returns (e.g., the rest
        // of the parent body, including direct calls into this nested
        // closure) still resolve names against the outer params. Without
        // this, `add(10)` inside `make_adder(x)` would lower a reference
        // to `x` against `add`'s param list and synthesise a spurious
        // capture in the parent.
        const saved_param_names = self.current_param_names;
        const saved_param_types = self.current_param_types;
        self.current_function_root_scope = if (func.clauses.len > 0) self.graph.resolveClauseScope(func.clauses[0].meta) else null;
        self.current_capture_map = std.AutoHashMap(ast.StringId, u32).init(self.allocator);
        self.current_capture_list = .empty;

        // Save parent function's local bindings. These need to be available
        // for capture detection — when a closure references a parent's local
        // variable, it should generate a capture_get, not a local_get.
        const saved_assignment_bindings = self.current_assignment_bindings;
        const saved_tuple_bindings = self.current_tuple_bindings;
        const saved_struct_bindings = self.current_struct_bindings;
        const saved_list_bindings = self.current_list_bindings;
        const saved_cons_tail_bindings = self.current_cons_tail_bindings;
        const saved_binary_bindings = self.current_binary_bindings;
        const saved_map_bindings = self.current_map_bindings;
        const saved_case_bindings = self.current_case_bindings;
        // Store parent bindings for capture detection in the nested function
        const saved_parent_bindings = self.parent_assignment_bindings;
        self.parent_assignment_bindings = self.current_assignment_bindings;
        self.current_assignment_bindings = .empty;
        self.current_tuple_bindings = .empty;
        self.current_struct_bindings = .empty;
        self.current_list_bindings = .empty;
        self.current_cons_tail_bindings = .empty;
        self.current_binary_bindings = .empty;
        self.current_map_bindings = .empty;
        self.current_case_bindings = .empty;

        var clauses: std.ArrayList(Clause) = .empty;
        for (func.clauses) |clause| {
            try clauses.append(self.allocator, try self.buildClause(&clause));
        }

        const captures = try self.current_capture_list.toOwnedSlice(self.allocator);
        try self.group_captures.put(group_id, captures);

        // Validate function naming conventions:
        // - Functions ending with ? must return Bool
        // - Functions ending with ! must call raise() or another ! function
        const func_name = self.interner.get(func.name);
        if (func_name.len > 0) {
            const last_char = func_name[func_name.len - 1];
            if (last_char == '?') {
                // ? functions must return Bool
                for (clauses.items) |clause| {
                    if (clause.return_type != types_mod.TypeStore.BOOL and
                        clause.return_type != types_mod.TypeStore.UNKNOWN and
                        clause.return_type != types_mod.TypeStore.ERROR)
                    {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator,
                                "function '{s}' ends with '?' but does not return Bool — ? functions must always return Bool",
                                .{func_name}),
                            .span = func.clauses[0].meta.span,
                        });
                        break;
                    }
                }
            }
            if (last_char == '!') {
                // ! functions must call raise() or another ! function
                var has_raise = false;
                for (clauses.items) |clause| {
                    if (self.bodyContainsRaise(clause.body)) {
                        has_raise = true;
                        break;
                    }
                }
                if (!has_raise) {
                    try self.errors.append(self.allocator, .{
                        .message = try std.fmt.allocPrint(self.allocator,
                            "function '{s}' ends with '!' but does not raise — ! functions must call raise() or another ! function",
                            .{func_name}),
                        .span = func.clauses[0].meta.span,
                    });
                }
            }
        }

        self.current_capture_map.deinit();
        self.current_capture_list = saved_capture_list;
        self.current_capture_map = saved_capture_map;
        self.current_function_root_scope = saved_root_scope;
        self.next_local = saved_next_local;
        self.current_function_name = saved_function_name;
        self.current_function_name_id = saved_function_name_id;
        self.current_param_names = saved_param_names;
        self.current_param_types = saved_param_types;
        self.current_assignment_bindings = saved_assignment_bindings;
        self.current_tuple_bindings = saved_tuple_bindings;
        self.current_struct_bindings = saved_struct_bindings;
        self.current_list_bindings = saved_list_bindings;
        self.current_cons_tail_bindings = saved_cons_tail_bindings;
        self.current_binary_bindings = saved_binary_bindings;
        self.current_map_bindings = saved_map_bindings;
        self.current_case_bindings = saved_case_bindings;
        self.parent_assignment_bindings = saved_parent_bindings;

        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = func.name,
            .arity = arity,
            .is_local = is_local,
            .captures = captures,
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = fallback_parent,
        };
    }

    /// Check if a HIR block contains a call to raise() or a ! function.
    fn bodyContainsRaise(self: *const HirBuilder, block: *const Block) bool {
        for (block.stmts) |stmt| {
            if (self.exprContainsRaise(stmt.expr)) return true;
        }
        return false;
    }

    fn exprContainsRaise(self: *const HirBuilder, expr: *const Expr) bool {
        return switch (expr.kind) {
            .call => |call| {
                // Check if this call targets raise() or a ! function
                switch (call.target) {
                    .named => |named| {
                        if (std.mem.eql(u8, named.name, "raise")) return true;
                        if (named.name.len > 0 and named.name[named.name.len - 1] == '!') return true;
                    },
                    .direct => |direct| {
                        // Check if the direct target's name ends with !
                        for (self.graph.families.items) |family| {
                            if (family.id == direct.function_group_id) {
                                const fname = self.interner.get(family.name);
                                if (std.mem.eql(u8, fname, "raise")) return true;
                                if (fname.len > 0 and fname[fname.len - 1] == '!') return true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
                // Also check args recursively
                for (call.args) |arg| {
                    if (self.exprContainsRaise(arg.expr)) return true;
                }
                return false;
            },
            .case => |ce| {
                for (ce.arms) |arm| {
                    if (self.bodyContainsRaise(arm.body)) return true;
                }
                return false;
            },
            .binary => |bo| {
                return self.exprContainsRaise(bo.lhs) or self.exprContainsRaise(bo.rhs);
            },
            .block => |blk| {
                return self.bodyContainsRaise(&blk);
            },
            .branch => |br| {
                if (self.bodyContainsRaise(br.then_block)) return true;
                if (br.else_block) |eb| return self.bodyContainsRaise(eb);
                return false;
            },
            else => false,
        };
    }

    fn buildClause(self: *HirBuilder, clause: *const ast.FunctionClause) !Clause {
        self.next_local = 0;
        self.hir_type_var_scope.clearRetainingCapacity();

        // While building an impl block's clauses, pre-populate the
        // type-var scope with the impl's declared type parameters so
        // their occurrences in this clause's signatures resolve to the
        // same fresh TypeVar across params and return type. Mirrors the
        // type checker's pre-population in checkFunctionClause.
        if (self.current_impl) |impl_d| {
            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
            for (impl_d.type_params) |tp_name_id| {
                const tp_name = self.interner.get(tp_name_id);
                if (!self.hir_type_var_scope.contains(tp_name)) {
                    const fresh = store_ptr.freshVar() catch continue;
                    self.hir_type_var_scope.put(tp_name, fresh) catch {};
                }
            }
        }
        const prev_clause_scope = self.current_clause_scope;
        // Resolve the clause's scope. Prefers `meta.scope_id` (set
        // directly by the collector) over `node_scope_map` so macro-
        // generated clauses with synthetic span 0:0 don't collide.
        self.current_clause_scope = self.graph.resolveClauseScope(clause.meta) orelse self.current_module_scope orelse clause.meta.scope_id;
        defer self.current_clause_scope = prev_clause_scope;

        // Check for inferred signature from the type checker (populated for
        // generated helpers like __for_N from call-site argument types).
        const inferred_sig = if (self.current_function_name_id) |name_id|
            self.type_store.inferred_signatures.get(name_id)
        else
            null;

        // Track bound names for variable unification. When a bind pattern
        // reuses a name from an earlier parameter, compilePattern converts
        // it to a pin (equality guard) — like Elixir's variable unification.
        self.clause_bound_names.clearRetainingCapacity();

        var params: std.ArrayList(TypedParam) = .empty;
        for (clause.params, 0..) |param, param_idx| {
            const type_id = if (param.type_annotation) |ann|
                self.resolveTypeExpr(ann)
            else if (inferred_sig) |sig| blk: {
                // Use type inferred from call-site argument types
                break :blk if (param_idx < sig.param_types.len)
                    sig.param_types[param_idx]
                else
                    types_mod.TypeStore.UNKNOWN;
            } else types_mod.TypeStore.UNKNOWN;

            // When a struct pattern has no module_name (parsed from %{...} :: Type),
            // inject the type name from the type annotation
            const match_pattern = blk: {
                if (param.pattern.* == .struct_pattern and param.type_annotation != null) {
                    const sp = param.pattern.struct_pattern;
                    if (sp.module_name.parts.len == 0) {
                        const ann = param.type_annotation.?;
                        if (ann.* == .name) {
                            var bindings: std.ArrayList(StructFieldBind) = .empty;
                            for (sp.fields) |field| {
                                if (try self.compilePattern(field.pattern)) |p| {
                                    try bindings.append(self.allocator, .{
                                        .field_name = field.name,
                                        .pattern = p,
                                    });
                                }
                            }
                            break :blk try self.create(MatchPattern, .{
                                .struct_match = .{
                                    .type_name = ann.name.name,
                                    .field_bindings = try bindings.toOwnedSlice(self.allocator),
                                },
                            });
                        }
                        // The parser routes `%{key: pat, ...}` into
                        // `.struct_pattern` with empty module_name (the
                        // syntax is shared with struct destructure). When
                        // the annotation is a map type (`%{K -> V}`), build
                        // a `map_match` so the IR's map-binding extraction
                        // path runs and the fields are looked up by key
                        // rather than as positional struct fields.
                        if (ann.* == .map) {
                            var bindings: std.ArrayList(MapFieldBind) = .empty;
                            for (sp.fields) |field| {
                                if (try self.compilePattern(field.pattern)) |p| {
                                    // Synthesise an atom-literal key
                                    // expression matching the field name.
                                    const key_ast: *ast.Expr = try self.allocator.create(ast.Expr);
                                    key_ast.* = .{ .atom_literal = .{
                                        .meta = .{ .span = sp.meta.span },
                                        .value = field.name,
                                    } };
                                    try bindings.append(self.allocator, .{
                                        .key = key_ast,
                                        .pattern = p,
                                    });
                                }
                            }
                            break :blk try self.create(MatchPattern, .{
                                .map_match = .{
                                    .field_bindings = try bindings.toOwnedSlice(self.allocator),
                                },
                            });
                        }
                    }
                }
                break :blk try self.compilePattern(param.pattern);
            };

            const name = if (param.pattern.* == .bind) param.pattern.bind.name else null;
            const default_expr = if (param.default) |def| try self.buildExpr(def) else null;
            try params.append(self.allocator, .{
                .name = name,
                .type_id = type_id,
                .ownership = self.resolveParamOwnership(param, type_id),
                .pattern = match_pattern,
                .default = default_expr,
            });

            // Record bound names from this parameter so later parameters
            // can detect variable unification (repeated names → pin patterns).
            self.collectBoundNames(param.pattern);
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
        else if (inferred_sig) |sig|
            sig.return_type
        else
            types_mod.TypeStore.NEVER;

        // Track param names for var_ref resolution
        var param_names: std.ArrayList(?ast.StringId) = .empty;
        var param_types: std.ArrayList(TypeId) = .empty;
        for (params.items) |p| {
            try param_names.append(self.allocator, p.name);
            try param_types.append(self.allocator, p.type_id);
        }
        self.current_param_names = try param_names.toOwnedSlice(self.allocator);
        self.current_param_types = try param_types.toOwnedSlice(self.allocator);

        // Process tuple patterns to create bindings for destructured variables
        self.current_tuple_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .tuple) {
                    for (pat.tuple, 0..) |sub_pat, elem_idx| {
                        if (sub_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_tuple_bindings.append(self.allocator, .{
                                .name = sub_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                }
            }
        }

        // Process struct patterns to create bindings for destructured field variables
        self.current_struct_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .struct_match) {
                    for (pat.struct_match.field_bindings) |fb| {
                        if (fb.pattern.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_struct_bindings.append(self.allocator, .{
                                .name = fb.pattern.bind,
                                .param_index = @intCast(param_idx),
                                .field_name = fb.field_name,
                                .local_index = local_idx,
                            });
                        }
                    }
                }
            }
        }

        // Process list patterns to create bindings for destructured list elements
        self.current_list_bindings = .empty;
        self.current_cons_tail_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .list) {
                    for (pat.list, 0..) |sub_pat, elem_idx| {
                        if (sub_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_list_bindings.append(self.allocator, .{
                                .name = sub_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                }
                // Cons patterns [h | t]: register head elements as list bindings
                // and the tail as an assignment binding so the body can reference
                // them via local_get instead of falling through to capture_get.
                if (pat.* == .list_cons) {
                    for (pat.list_cons.heads, 0..) |head_pat, elem_idx| {
                        if (head_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_list_bindings.append(self.allocator, .{
                                .name = head_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                    if (pat.list_cons.tail.* == .bind) {
                        const tail_local_idx = self.next_local;
                        self.next_local += 1;
                        try self.current_cons_tail_bindings.append(self.allocator, .{
                            .name = pat.list_cons.tail.bind,
                            .param_index = @intCast(param_idx),
                            .local_index = tail_local_idx,
                        });
                    }
                }
            }
        }

        // Process binary patterns to create bindings for destructured segments
        self.current_binary_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .binary_match) {
                    for (pat.binary_match.segments, 0..) |seg, seg_idx| {
                        if (seg.pattern) |sub_pat| {
                            if (sub_pat.* == .bind) {
                                // Skip user-discard bindings (`_x`) but
                                // keep `__synth` names — see
                                // `ast.isDiscardBindName` for the
                                // distinction.
                                const name_str = self.interner.get(sub_pat.bind);
                                if (ast.isDiscardBindName(name_str)) continue;
                                const local_idx = self.next_local;
                                self.next_local += 1;
                                try self.current_binary_bindings.append(self.allocator, .{
                                    .name = sub_pat.bind,
                                    .param_index = @intCast(param_idx),
                                    .segment_index = @intCast(seg_idx),
                                    .local_index = local_idx,
                                    .segment = seg,
                                });
                            }
                        }
                    }
                }
            }
        }

        // Process map patterns to create bindings for destructured map fields
        self.current_map_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .map_match) {
                    for (pat.map_match.field_bindings) |fb| {
                        if (fb.pattern.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            const key_hir = try self.buildExpr(fb.key);
                            try self.current_map_bindings.append(self.allocator, .{
                                .name = fb.pattern.bind,
                                .param_index = @intCast(param_idx),
                                .key_expr = key_hir,
                                .local_index = local_idx,
                            });
                        }
                    }
                }
            }
        }

        // Build decision tree for this clause
        const decision = try self.create(Decision, .{
            .success = .{ .bindings = &.{}, .body_index = 0 },
        });

        // Build refinement expression (guard predicate)
        const refinement_expr = if (clause.refinement) |ref| blk: {
            const rexpr = try self.buildExpr(ref);
            if (rexpr.kind == .call) {
            }
            break :blk rexpr;
        } else null;

        // Build body block (empty for bodyless declarations: protocol sigs, forward decls)
        const body = if (clause.body) |body_stmts|
            try self.buildBlock(body_stmts)
        else
            try self.buildBlock(&.{});

        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .decision = decision,
            .body = body,
            .refinement = refinement_expr,
            .tuple_bindings = try self.current_tuple_bindings.toOwnedSlice(self.allocator),
            .struct_bindings = try self.current_struct_bindings.toOwnedSlice(self.allocator),
            .list_bindings = try self.current_list_bindings.toOwnedSlice(self.allocator),
            .cons_tail_bindings = try self.current_cons_tail_bindings.toOwnedSlice(self.allocator),
            .binary_bindings = try self.current_binary_bindings.toOwnedSlice(self.allocator),
            .map_bindings = try self.current_map_bindings.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Pattern compilation (spec §17)
    // ============================================================

    /// Recursively collect all bound variable names from an AST pattern.
    fn collectBoundNames(self: *HirBuilder, pattern: *const ast.Pattern) void {
        switch (pattern.*) {
            .bind => |b| {
                // Don't track user-discard names (`_x`) — they should
                // never participate in pin-style variable unification.
                // Compiler-synthesised `__*` names are unique per
                // generation site and likewise don't unify, so we treat
                // them the same here.
                const name_str = self.interner.get(b.name);
                if (name_str.len > 0 and name_str[0] != '_') {
                    self.clause_bound_names.put(b.name, {}) catch {};
                }
            },
            .list_cons => |lc| {
                for (lc.heads) |h| self.collectBoundNames(h);
                self.collectBoundNames(lc.tail);
            },
            .tuple => |t| {
                for (t.elements) |e| self.collectBoundNames(e);
            },
            .list => |l| {
                for (l.elements) |e| self.collectBoundNames(e);
            },
            .paren => |p| self.collectBoundNames(p.inner),
            else => {},
        }
    }

    fn compilePattern(self: *HirBuilder, pattern: *const ast.Pattern) anyerror!?*const MatchPattern {
        return switch (pattern.*) {
            .wildcard => try self.create(MatchPattern, .wildcard),
            .bind => |b| {
                // Variable unification: if this name was already bound by a
                // previous parameter, emit a pin (equality check) instead of
                // a fresh binding. This implements Elixir-style patterns like
                // `fn foo(x, [x | rest])` where the second `x` must equal the first.
                const name_str = self.interner.get(b.name);
                if (name_str.len > 0 and name_str[0] != '_' and self.clause_bound_names.contains(b.name)) {
                    return try self.create(MatchPattern, .{ .pin = b.name });
                }
                return try self.create(MatchPattern, .{ .bind = b.name });
            },
            .literal => |lit| try self.create(MatchPattern, .{
                .literal = switch (lit) {
                    .int => |v| .{ .int = v.value },
                    .float => |v| .{ .float = v.value },
                    .string => |v| .{ .string = v.value },
                    .atom => |v| .{ .atom = v.value },
                    .bool_lit => |v| .{ .bool_val = v.value },
                    .nil => .nil,
                },
            }),
            .tuple => |t| {
                var elems: std.ArrayList(*const MatchPattern) = .empty;
                for (t.elements) |elem| {
                    if (try self.compilePattern(elem)) |p| {
                        try elems.append(self.allocator, p);
                    }
                }
                return try self.create(MatchPattern, .{
                    .tuple = try elems.toOwnedSlice(self.allocator),
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const MatchPattern) = .empty;
                for (l.elements) |elem| {
                    if (try self.compilePattern(elem)) |p| {
                        try elems.append(self.allocator, p);
                    }
                }
                return try self.create(MatchPattern, .{
                    .list = try elems.toOwnedSlice(self.allocator),
                });
            },
            .list_cons => |lc| {
                var heads: std.ArrayList(*const MatchPattern) = .empty;
                for (lc.heads) |h| {
                    if (try self.compilePattern(h)) |p| {
                        try heads.append(self.allocator, p);
                    }
                }
                const tail = try self.compilePattern(lc.tail);
                return try self.create(MatchPattern, .{
                    .list_cons = .{
                        .heads = try heads.toOwnedSlice(self.allocator),
                        .tail = tail orelse try self.create(MatchPattern, .wildcard),
                    },
                });
            },
            .pin => |p| try self.create(MatchPattern, .{ .pin = p.name }),
            .paren => |p| self.compilePattern(p.inner),
            .struct_pattern => |sp| {
                // Get the type name from the module_name (first part)
                // When module_name is empty, the type comes from param annotation (handled in buildClause)
                const type_name = if (sp.module_name.parts.len > 0) sp.module_name.parts[0] else return null;
                var bindings: std.ArrayList(StructFieldBind) = .empty;
                for (sp.fields) |field| {
                    if (try self.compilePattern(field.pattern)) |p| {
                        try bindings.append(self.allocator, .{
                            .field_name = field.name,
                            .pattern = p,
                        });
                    }
                }
                return try self.create(MatchPattern, .{
                    .struct_match = .{
                        .type_name = type_name,
                        .field_bindings = try bindings.toOwnedSlice(self.allocator),
                    },
                });
            },
            .map => |mp| {
                var bindings: std.ArrayList(MapFieldBind) = .empty;
                for (mp.fields) |field| {
                    const value_pat = try self.compilePattern(field.value) orelse continue;
                    try bindings.append(self.allocator, .{
                        .key = field.key,
                        .pattern = value_pat,
                    });
                }
                return try self.create(MatchPattern, .{
                    .map_match = .{
                        .field_bindings = try bindings.toOwnedSlice(self.allocator),
                    },
                });
            },
            .binary => |bin| {
                return try self.create(MatchPattern, .{
                    .binary_match = .{
                        .segments = try self.compileBinarySegments(bin.segments),
                    },
                });
            },
        };
    }

    fn compileBinarySegments(self: *HirBuilder, segments: []const ast.BinarySegment) ![]const BinaryMatchSegment {
        var result: std.ArrayList(BinaryMatchSegment) = .empty;
        for (segments) |seg| {
            const pattern: ?*const MatchPattern = switch (seg.value) {
                .pattern => |pat| try self.compilePattern(pat),
                .expr => null,
                .string_literal => null,
            };
            const string_lit: ?ast.StringId = switch (seg.value) {
                .string_literal => |s| s,
                else => null,
            };
            try result.append(self.allocator, .{
                .pattern = pattern,
                .type_spec = seg.type_spec,
                .endianness = seg.endianness,
                .size = seg.size,
                .string_literal = string_lit,
            });
        }
        return try result.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Block building
    // ============================================================

    fn buildBlock(self: *HirBuilder, stmts: []const ast.Stmt) anyerror!*const Block {
        var hir_stmts: std.ArrayList(Stmt) = .empty;
        // Inherit outer bindings so variables from enclosing scopes are
        // visible inside block expressions (e.g., macro-expanded quote blocks).
        // Track the entry length so bindings added inside this block are
        // removed on exit — they don't leak to the outer scope.
        const bindings_base_len = self.current_assignment_bindings.items.len;
        defer self.current_assignment_bindings.shrinkRetainingCapacity(bindings_base_len);

        for (stmts) |stmt| {
            switch (stmt) {
                .function_decl => |func| {
                    const group_scope = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
                    const group = try self.buildFunctionGroup(func, group_scope, null, true);
                    const group_ptr = try self.create(FunctionGroup, group);
                    try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                },
                else => {},
            }
        }

        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const hir_expr = try self.buildExpr(expr);
                    try hir_stmts.append(self.allocator, .{ .expr = hir_expr });
                },
                .assignment => |assign| {
                    // For anonymous function assignments, extract the function
                    // group as a separate statement (same as named function_decl)
                    // so the IR can build it properly. The assignment value becomes
                    // just the closure_create expression.
                    const value = if (assign.value.* == .anonymous_function) blk: {
                        const anon = assign.value.anonymous_function;
                        const function_type = try self.resolveFunctionValueType(anon.decl.name);
                        const group_scope = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
                        const group = try self.buildFunctionGroup(anon.decl, group_scope, null, true);
                        const group_ptr = try self.create(FunctionGroup, group);
                        try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                        break :blk try self.buildFunctionValueExpr(group.id, function_type, anon.meta.span);
                    } else try self.buildExpr(assign.value);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    try hir_stmts.append(self.allocator, .{
                        .local_set = .{ .index = value_local, .value = value },
                    });

                    // For `name = expr`, just bind the name to `value_local`.
                    // For destructure patterns ({a,b} = pair, [h|t] = lst,
                    // %Foo{x: x} = p, %{k => v} = m), recursively walk the
                    // pattern and emit one `local_set` per inner bind, each
                    // with an extractor expression that reads from a local
                    // holding the parent compound value.
                    if (assign.pattern.* == .bind) {
                        try self.current_assignment_bindings.append(self.allocator, .{
                            .name = assign.pattern.bind.name,
                            .local_index = value_local,
                            .type_id = value.type_id,
                        });
                    } else {
                        try self.lowerAssignmentDestructure(
                            assign.pattern,
                            value_local,
                            value.type_id,
                            assign.value.getMeta().span,
                            &hir_stmts,
                        );
                    }
                },
                .function_decl => {},
                else => {},
            }
        }

        const owned_stmts = try hir_stmts.toOwnedSlice(self.allocator);
        // The block's result type is the last expression's type — same
        // convention every other expression-oriented language uses,
        // and what `case_expr`'s arm-type unifier expects to read so
        // it can propagate a concrete container type back into
        // structurally-empty siblings (`[]`, `%{}`).
        var block_result_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
        if (owned_stmts.len > 0) {
            const last = owned_stmts[owned_stmts.len - 1];
            switch (last) {
                .expr => |expr| block_result_type = expr.type_id,
                .local_set => |ls| block_result_type = ls.value.type_id,
                .function_group => {},
            }
        }
        return try self.create(Block, .{
            .stmts = owned_stmts,
            .result_type = block_result_type,
        });
    }

    // ============================================================
    // Expression building
    // ============================================================

    fn buildExpr(self: *HirBuilder, expr: *const ast.Expr) anyerror!*const Expr {
        return switch (expr.*) {
            .int_literal => |v| try self.create(Expr, .{
                .kind = .{ .int_lit = v.value },
                .type_id = types_mod.TypeStore.I64,
                .span = v.meta.span,
            }),
            .float_literal => |v| try self.create(Expr, .{
                .kind = .{ .float_lit = v.value },
                .type_id = types_mod.TypeStore.F64,
                .span = v.meta.span,
            }),
            .string_literal => |v| try self.create(Expr, .{
                .kind = .{ .string_lit = v.value },
                .type_id = types_mod.TypeStore.STRING,
                .span = v.meta.span,
            }),
            .atom_literal => |v| try self.create(Expr, .{
                .kind = .{ .atom_lit = v.value },
                .type_id = types_mod.TypeStore.ATOM,
                .span = v.meta.span,
            }),
            .bool_literal => |v| try self.create(Expr, .{
                .kind = .{ .bool_lit = v.value },
                .type_id = types_mod.TypeStore.BOOL,
                .span = v.meta.span,
            }),
            .nil_literal => |v| try self.create(Expr, .{
                .kind = .nil_lit,
                .type_id = types_mod.TypeStore.NIL,
                .span = v.meta.span,
            }),
            .var_ref => |v| {
                var resolved_type = self.resolveBindingType(v.name);
                if (resolved_type == types_mod.TypeStore.UNKNOWN) {
                    resolved_type = try self.resolveFunctionValueType(v.name);
                }

                if (self.current_clause_scope != null) {
                    if (try self.buildBindingReference(v.name, resolved_type, v.meta.span)) |ref| {
                        return ref;
                    }
                }
                if (self.resolveFunctionValueGroup(v.name)) |group_id| {
                    return try self.buildFunctionValueExpr(group_id, resolved_type, v.meta.span);
                }
                // Last-resort fallback when a var_ref didn't resolve to a
                // capture, parameter, named function, or scope-graph binding.
                // Reaching here typically means the type checker accepted a
                // reference that the HIR build path can't ground (e.g. a
                // synthetic helper's parameter not yet in scope). Emit a
                // local_get of slot 0 so downstream code has *something*; the
                // backend will surface any genuine miss as a Zig compile error
                // rather than a silent runtime read of a wrong value.
                return try self.create(Expr, .{
                    .kind = .{ .local_get = 0 },
                    .type_id = resolved_type,
                    .span = v.meta.span,
                });
            },
            .binary_op => |bo| {
                const lhs_expr = try self.buildExpr(bo.lhs);
                const rhs_expr = try self.buildExpr(bo.rhs);

                // Protocol-driven dispatch: when either operand has a known
                // concrete type and the corresponding `impl PROTOCOL for T`
                // exists, lower `a OP b` to a call against the impl's
                // operator function (`Integer.+`, `Float.<`, ...). The
                // mangler turns the operator name into a Zig-safe identifier
                // downstream, and the impl body handles the type-specific
                // runtime path. Otherwise (UNKNOWN operand types, no impl)
                // fall through to the primitive ZIR binary op.
                if (operatorProtocol(bo.op)) |op_meta| {
                    const operand_type: types_mod.TypeId = if (lhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                        lhs_expr.type_id
                    else
                        rhs_expr.type_id;
                    if (operand_type != types_mod.TypeStore.UNKNOWN) {
                        if (self.type_store.typeToModuleName(operand_type, self.interner)) |module_name| {
                            if (self.hasImpl(op_meta.protocol, module_name)) {
                                var args: std.ArrayList(CallArg) = .empty;
                                try args.append(self.allocator, .{ .expr = lhs_expr, .mode = .share });
                                try args.append(self.allocator, .{ .expr = rhs_expr, .mode = .share });

                                return try self.create(Expr, .{
                                    .kind = .{ .call = .{
                                        .target = .{ .named = .{ .module = module_name, .name = op_meta.method } },
                                        .args = try args.toOwnedSlice(self.allocator),
                                    } },
                                    .type_id = op_meta.result_type(operand_type),
                                    .span = bo.meta.span,
                                });
                            }
                        }
                    }
                }

                // Derive result type from operands and operator (primitive path).
                const result_type = switch (bo.op) {
                    // Arithmetic: same type as operands
                    .add, .sub, .mul, .div, .rem_op => blk: {
                        if (lhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk lhs_expr.type_id;
                        if (rhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk rhs_expr.type_id;
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    // Comparison/logical/membership: Bool
                    .equal, .not_equal, .less, .greater, .less_equal, .greater_equal, .and_op, .or_op, .in_op => types_mod.TypeStore.BOOL,
                    // String concat
                    .concat => types_mod.TypeStore.STRING,
                };
                return try self.create(Expr, .{
                    .kind = .{ .binary = .{
                        .op = bo.op,
                        .lhs = lhs_expr,
                        .rhs = rhs_expr,
                    } },
                    .type_id = result_type,
                    .span = bo.meta.span,
                });
            },
            .unary_op => |uo| try self.create(Expr, .{
                .kind = .{ .unary = .{
                    .op = uo.op,
                    .operand = try self.buildExpr(uo.operand),
                } },
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = uo.meta.span,
            }),
            .call => |call| {
                // Check for union variant constructor: Result.Ok("hello")
                // Parsed as call(module_ref(["Result", "Ok"]), args)
                if (call.callee.* == .module_ref and call.args.len >= 1) {
                    const parts = call.callee.module_ref.name.parts;
                    if (parts.len == 2) {
                        if (self.type_store.name_to_type.get(parts[0])) |tid| {
                            const typ = self.type_store.getType(tid);
                            if (typ == .tagged_union) {
                                for (typ.tagged_union.variants) |v| {
                                    if (v.name == parts[1] and v.type_id != null) {
                                        const arg_expr = try self.buildExpr(call.args[0]);
                                        return try self.create(Expr, .{
                                            .kind = .{ .union_init = .{
                                                .union_type_id = tid,
                                                .variant_name = parts[1],
                                                .value = arg_expr,
                                            } },
                                            .type_id = tid,
                                            .span = call.meta.span,
                                        });
                                    }
                                }
                            }
                        }
                    }
                }

                var args: std.ArrayList(CallArg) = .empty;
                for (call.args) |arg| {
                    try args.append(self.allocator, .{
                        .expr = try self.buildExpr(arg),
                        .mode = .share,
                    });
                }

                var callee_expr: ?*const Expr = null;

                // Check for module-qualified call: IO.puts(...), Math.square(...)
                // or :zig runtime bridge: :zig.println(...)
                const target: CallTarget = if (call.callee.* == .field_access) blk: {
                    const fa = call.callee.field_access;
                    if (fa.object.* == .module_ref) {
                        const func_name = self.interner.get(fa.field);
                        const initial_mod = self.structNameToString(fa.object.module_ref.name);
                        // Protocol-call dispatch: rewrite `Protocol.method(arg, ...)`
                        // to `Impl.method(arg, ...)` when the first arg's type has
                        // a matching impl. Mirrors the binary_op dispatch path so
                        // every protocol-method invocation goes through the same
                        // type-driven lookup. Falls through to the literal module
                        // name when the call isn't protocol-qualified or the type
                        // is UNKNOWN.
                        const dispatched_mod = if (args.items.len > 0)
                            self.protocolDispatchModule(initial_mod, args.items[0].expr.type_id) orelse initial_mod
                        else
                            initial_mod;
                        break :blk .{ .named = .{ .module = dispatched_mod, .name = func_name } };
                    }
                    // :zig.function() or :zig.Module.function() — bridge to Zig runtime
                    if (fa.object.* == .atom_literal) {
                        const atom_name = self.interner.get(fa.object.atom_literal.value);
                        if (std.mem.eql(u8, atom_name, "zig")) {
                            const func_name = self.interner.get(fa.field);
                            break :blk .{ .builtin = func_name };
                        }
                    }
                    // :zig.Module.function() — chained field access
                    if (fa.object.* == .field_access) {
                        const inner = fa.object.field_access;
                        if (inner.object.* == .atom_literal) {
                            const atom_name = self.interner.get(inner.object.atom_literal.value);
                            if (std.mem.eql(u8, atom_name, "zig")) {
                                // Build "Module.function" qualified name. For
                                // generic containers (List, Map), encode the
                                // element type from the first arg so the ZIR
                                // backend can instantiate the right
                                // specialization (e.g. `List:str.next` ->
                                // `List(String).next`). Without this, every
                                // List.* call defaulted to `List(i64)`.
                                const mod_part = self.interner.get(inner.field);
                                const func_part = self.interner.get(fa.field);
                                const typed_qualified: ?[]const u8 = blk_t: {
                                    if (args.items.len == 0) break :blk_t null;
                                    if (!(std.mem.eql(u8, mod_part, "List") or std.mem.eql(u8, mod_part, "Map"))) break :blk_t null;
                                    const arg_type = args.items[0].expr.type_id;
                                    if (arg_type == types_mod.TypeStore.UNKNOWN) break :blk_t null;
                                    const t = self.type_store.getType(arg_type);
                                    if (std.mem.eql(u8, mod_part, "List") and t == .list) {
                                        const enc = encodeContainerElemName(self.type_store, t.list.element) orelse break :blk_t null;
                                        break :blk_t std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ enc, func_part }) catch null;
                                    }
                                    if (std.mem.eql(u8, mod_part, "Map") and t == .map) {
                                        const k_enc = encodeContainerElemName(self.type_store, t.map.key) orelse break :blk_t null;
                                        const v_enc = encodeContainerElemName(self.type_store, t.map.value) orelse break :blk_t null;
                                        break :blk_t std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ k_enc, v_enc, func_part }) catch null;
                                    }
                                    break :blk_t null;
                                };
                                if (typed_qualified) |tq| break :blk .{ .builtin = tq };
                                const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod_part, func_part }) catch break :blk .{ .builtin = func_part };
                                break :blk .{ .builtin = qualified };
                            }
                        }
                    }
                    callee_expr = try self.buildExpr(call.callee);
                    break :blk .{ .closure = callee_expr.? };
                } else if (call.callee.* == .var_ref) blk: {
                    // Check if callee is a parameter (function value) or a named function
                    const vr = call.callee.var_ref;
                    var is_param = false;
                    for (self.current_param_names) |param_name| {
                        if (param_name) |pn| {
                            if (pn == vr.name) {
                                is_param = true;
                                break;
                            }
                        }
                    }
                    if (is_param) {
                        callee_expr = try self.buildExpr(call.callee);
                        break :blk .{ .closure = callee_expr.? };
                    }
                    if (self.current_clause_scope != null) {
                        if (try self.buildBindingReference(vr.name, self.resolveBindingType(vr.name), vr.meta.span)) |binding_ref| {
                            callee_expr = binding_ref;
                            break :blk .{ .closure = callee_expr.? };
                        }
                    }
                    const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
                    if (self.graph.resolveFamily(scope_id, vr.name, @intCast(call.args.len))) |family_id| {
                        if (self.family_to_group.get(family_id)) |group_id| {
                            break :blk .{ .direct = .{ .function_group_id = group_id, .clause_index = 0 } };
                        }
                    }
                    // Check if this bare call resolves to an imported function
                    const import_module = self.resolveImport(vr.name, @intCast(call.args.len));
                    break :blk .{ .named = .{ .module = import_module, .name = self.interner.get(vr.name) } };
                } else blk: {
                    callee_expr = try self.buildExpr(call.callee);
                    break :blk .{ .closure = callee_expr.? };
                };

                if (callee_expr) |callee| {
                    self.applyCallArgModes(args.items, callee.type_id);
                }

                // Populate expected_type on each arg for implicit widening.
                // For direct and bare-named calls, resolve from the scope graph.
                if (call.callee.* == .var_ref) {
                    if (self.resolveFunctionParamTypes(call.callee.var_ref.name, @intCast(call.args.len))) |param_types| {
                        const count = @min(args.items.len, param_types.len);
                        for (args.items[0..count], param_types[0..count]) |*arg, param_type| {
                            arg.expected_type = param_type;
                        }
                    }
                } else if (call.callee.* == .field_access) {
                    // Module-qualified call: resolve via callee's function type
                    if (callee_expr) |callee| {
                        const callee_type = self.type_store.getType(callee.type_id);
                        if (callee_type == .function) {
                            const count = @min(args.items.len, callee_type.function.params.len);
                            for (args.items[0..count], callee_type.function.params[0..count]) |*arg, param_type| {
                                arg.expected_type = param_type;
                            }
                        }
                    }
                }

                // Propagate expected_type to argument expressions with UNKNOWN type.
                // This is critical for empty list literals ([]) which have no elements
                // to infer from — their type comes from the calling context.
                for (args.items) |*arg| {
                    if (arg.expr.type_id == types_mod.TypeStore.UNKNOWN and arg.expected_type != types_mod.TypeStore.UNKNOWN) {
                        // Check if the expected type is concrete (no type variables)
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                        if (!store_ptr.containsTypeVars(arg.expected_type)) {
                            @constCast(arg.expr).type_id = arg.expected_type;
                        }
                    }
                }

                if (target == .direct) {
                    const group_id = target.direct.function_group_id;
                    const group_captures = self.group_captures.get(group_id) orelse &.{};
                    if (group_captures.len > 0) {
                        var full_args: std.ArrayList(CallArg) = .empty;
                        for (group_captures) |capture| {
                            try full_args.append(self.allocator, .{
                                .expr = (try self.buildBindingReference(capture.name, capture.type_id, call.meta.span)) orelse return error.OutOfMemory,
                                .mode = switch (capture.ownership) {
                                    .shared => .share,
                                    .unique => .move,
                                    .borrowed => .borrow,
                                },
                            });
                        }
                        for (args.items) |arg| try full_args.append(self.allocator, arg);
                        args.deinit(self.allocator);
                        args = full_args;
                    }
                }

                // Resolve return type for named calls
                const call_return_type: types_mod.TypeId = switch (target) {
                    .direct => blk: {
                        if (call.callee.* == .var_ref) {
                            const raw = self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                            if (raw != types_mod.TypeStore.UNKNOWN) {
                                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                if (store_ptr.containsTypeVars(raw)) {
                                    break :blk self.resolveGenericReturnTypeLocal(call.callee.var_ref.name, @intCast(call.args.len), args.items, raw);
                                }
                            }
                            break :blk raw;
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    .named => |n| blk: {
                        if (n.module == null) {
                            if (call.callee.* == .var_ref) {
                                const raw = self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                                if (raw != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw)) {
                                        break :blk self.resolveGenericReturnTypeLocal(call.callee.var_ref.name, @intCast(call.args.len), args.items, raw);
                                    }
                                }
                                break :blk raw;
                            }
                        } else {
                            if (call.callee.* == .field_access) {
                                const raw_return = self.resolveFunctionReturnTypeInModule(n.module.?, n.name, @intCast(call.args.len));
                                if (raw_return != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw_return)) {
                                        const resolved = self.resolveGenericReturnType(n.module.?, n.name, @intCast(call.args.len), args.items, raw_return);
                                        break :blk resolved;
                                    }
                                }
                                break :blk raw_return;
                            }
                            // Bare-name var_ref (`a + b` rewritten to `+(a, b)`) that
                            // resolves to an imported module's function. Same inference
                            // as the field_access case.
                            if (call.callee.* == .var_ref) {
                                const raw_return = self.resolveFunctionReturnTypeInModule(n.module.?, n.name, @intCast(call.args.len));
                                if (raw_return != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw_return)) {
                                        const resolved = self.resolveGenericReturnType(n.module.?, n.name, @intCast(call.args.len), args.items, raw_return);
                                        break :blk resolved;
                                    }
                                }
                                break :blk raw_return;
                            }
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    else => types_mod.TypeStore.UNKNOWN,
                };

                if (target == .named and call.callee.* == .var_ref) {
                    const named = target.named;
                    if (named.module == null) {
                        if (self.resolveFunctionParamOwnerships(call.callee.var_ref.name, @intCast(call.args.len))) |ownerships| {
                            const count = @min(args.items.len, ownerships.len);
                            for (args.items[0..count], ownerships[0..count]) |*arg, ownership| {
                                arg.mode = switch (ownership) {
                                    .shared => .share,
                                    .unique => .move,
                                    .borrowed => .borrow,
                                };
                            }
                        }
                    }
                }
                if (target == .direct and call.callee.* == .var_ref) {
                    if (self.resolveFunctionParamOwnerships(call.callee.var_ref.name, @intCast(call.args.len))) |ownerships| {
                        const offset = args.items.len - call.args.len;
                        const count = @min(call.args.len, ownerships.len);
                        for (args.items[offset .. offset + count], ownerships[0..count]) |*arg, ownership| {
                            arg.mode = switch (ownership) {
                                .shared => .share,
                                .unique => .move,
                                .borrowed => .borrow,
                            };
                        }
                    }
                }

                return try self.create(Expr, .{
                    .kind = .{ .call = .{
                        .target = target,
                        .args = try args.toOwnedSlice(self.allocator),
                    } },
                    .type_id = call_return_type,
                    .span = call.meta.span,
                });
            },
            .if_expr => {
                // if_expr should be desugared to case_expr before reaching HIR
                unreachable;
            },
            .case_expr => |ce| {
                const scrutinee = try self.buildExpr(ce.scrutinee);
                var arms: std.ArrayList(CaseArm) = .empty;

                for (ce.clauses) |clause| {
                    // Append THIS clause's pattern bindings to the running
                    // `current_case_bindings` instead of resetting it. A
                    // nested case (e.g. the filter-case the desugarer
                    // emits inside a for-comp's cont arm) still needs the
                    // outer arm's bindings — the user's loop variable and
                    // `__next_state` — visible while building its own
                    // clause bodies. Save the start index, append this
                    // clause's pattern bindings, build the body, snapshot
                    // just this clause's slice for the lowered arm, then
                    // shrink back so siblings see the outer arm's
                    // bindings unchanged.
                    const start_idx = self.current_case_bindings.items.len;

                    const pattern = try self.compilePattern(clause.pattern);

                    // Process bindings from the pattern. Top-level `.bind` is the
                    // whole-scrutinee bind (kind=.scrutinee, set by the success
                    // leaf). Anything nested inside a compound pattern is .extracted
                    // and set by a `.bind` decision-tree node. Binary segments use
                    // .binary_element with their segment index.
                    if (pattern) |pat| {
                        try self.collectCasePatternBindings(pat, true);
                    }

                    // Switch into the clause's scope while building the
                    // guard and body so var_refs to pattern-bound names
                    // (e.g. `c` in `{:cont, c, _} -> c <> "!"`) pick up
                    // the type the type checker recorded on the
                    // case-clause binding. Without this, `resolveBindingType`
                    // walks UP from `current_clause_scope` (the
                    // surrounding function clause's scope) and never
                    // visits the case-clause scope (a child), leaving
                    // the var_ref typed as UNKNOWN — which breaks
                    // first-arg-type-driven protocol dispatch in the
                    // body (`Concatenable.concat`, `Arithmetic.+`, …).
                    const saved_clause_scope = self.current_clause_scope;
                    if (self.graph.resolveClauseScope(clause.meta)) |cs| {
                        self.current_clause_scope = cs;
                    }

                    const guard_expr = if (clause.guard) |g| try self.buildExpr(g) else null;
                    const body = try self.buildBlock(clause.body);

                    self.current_clause_scope = saved_clause_scope;

                    // Snapshot just THIS clause's bindings (those appended
                    // at or after start_idx) so the lowered arm carries
                    // only the bindings introduced by its own pattern.
                    const clause_slice = self.current_case_bindings.items[start_idx..];
                    const bindings = try self.allocator.dupe(CaseBinding, clause_slice);

                    try arms.append(self.allocator, .{
                        .pattern = pattern,
                        .guard = guard_expr,
                        .body = body,
                        .bindings = bindings,
                    });

                    // Drop this clause's bindings; siblings see the outer
                    // arm's bindings as they did before this clause.
                    self.current_case_bindings.shrinkRetainingCapacity(start_idx);
                }

                const arm_slice = try arms.toOwnedSlice(self.allocator);
                // The case's result type is the unified type of its
                // arms. If one arm has a concrete element type (e.g.
                // the for-comp's cont arm produces `[String]`) and
                // another is structurally compatible but stamped
                // UNKNOWN (e.g. the done arm's empty literal `[]`),
                // propagate the concrete shape so downstream cons /
                // list_init monomorphisation doesn't default to i64.
                // Falls back to UNKNOWN when no arm carries a concrete
                // type or when arms disagree concretely (the latter
                // gets caught downstream as a structural mismatch).
                const case_type_id: types_mod.TypeId = blk: {
                    var chosen: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
                    for (arm_slice) |arm| {
                        const t = arm.body.result_type;
                        if (t == types_mod.TypeStore.UNKNOWN) continue;
                        if (chosen == types_mod.TypeStore.UNKNOWN) {
                            chosen = t;
                            continue;
                        }
                        if (chosen != t) {
                            chosen = types_mod.TypeStore.UNKNOWN;
                            break;
                        }
                    }
                    break :blk chosen;
                };
                // When a unified type is known, propagate it back into
                // any arm whose result is structurally compatible but
                // currently UNKNOWN — the canonical case is the done
                // arm's `[]` empty list inside a for-comprehension's
                // cont/done split. Without this patch the IR would
                // emit `list_init(elem=i64)` for `[]` and `list_cons`
                // with String for the cont arm, and Zig sema rejects
                // the union of `?*const List(i64) | ?*const List(String)`.
                if (case_type_id != types_mod.TypeStore.UNKNOWN) {
                    for (arm_slice) |arm| {
                        if (arm.body.result_type == types_mod.TypeStore.UNKNOWN) {
                            self.patchEmptyContainerTypes(arm.body, case_type_id);
                        }
                    }
                }
                return try self.create(Expr, .{
                    .kind = .{ .case = .{
                        .scrutinee = scrutinee,
                        .arms = arm_slice,
                    } },
                    .type_id = case_type_id,
                    .span = ce.meta.span,
                });
            },
            .error_pipe => |ep| {
                return try self.buildErrorPipe(ep);
            },
            .panic_expr => |pe| try self.create(Expr, .{
                .kind = .{ .panic = try self.buildExpr(pe.message) },
                .type_id = types_mod.TypeStore.NEVER,
                .span = pe.meta.span,
            }),
            .tuple => |t| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (t.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                const built_elems = try elems.toOwnedSlice(self.allocator);
                // Compute the tuple's type_id from its element types when all
                // children have concrete types. This lets downstream list/map
                // inference reason about tuples as proper compound types
                // (essential for keyword lists like `[{:name, "Alice"}, ...]`
                // where the list element is a tuple).
                var all_known = true;
                for (built_elems) |elem| {
                    if (elem.type_id == types_mod.TypeStore.UNKNOWN) {
                        all_known = false;
                        break;
                    }
                }
                const tuple_type_id: types_mod.TypeId = blk: {
                    if (!all_known) break :blk types_mod.TypeStore.UNKNOWN;
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    var elem_type_ids = self.allocator.alloc(types_mod.TypeId, built_elems.len) catch break :blk types_mod.TypeStore.UNKNOWN;
                    for (built_elems, 0..) |elem, i| {
                        elem_type_ids[i] = elem.type_id;
                    }
                    break :blk store_ptr.addType(.{ .tuple = .{ .elements = elem_type_ids } }) catch types_mod.TypeStore.UNKNOWN;
                };
                return try self.create(Expr, .{
                    .kind = .{ .tuple_init = built_elems },
                    .type_id = tuple_type_id,
                    .span = t.meta.span,
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (l.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                const built_elems = try elems.toOwnedSlice(self.allocator);
                const list_type_id = if (built_elems.len > 0)
                    self.inferListElementType(built_elems)
                else
                    types_mod.TypeStore.UNKNOWN;
                return try self.create(Expr, .{
                    .kind = .{ .list_init = built_elems },
                    .type_id = list_type_id,
                    .span = l.meta.span,
                });
            },
            .list_cons_expr => |lce| {
                const head_expr = try self.buildExpr(lce.head);
                const tail_expr = try self.buildExpr(lce.tail);
                // Infer the cons cell's list type from the head's type
                // when known. Without this, downstream IR/ZIR
                // monomorphisation defaults the element type to i64,
                // which breaks `[String | rest]` (and any other non-i64
                // element) emitted by the for-comp desugarer.
                const cons_type_id: types_mod.TypeId = blk: {
                    if (head_expr.type_id != types_mod.TypeStore.UNKNOWN) {
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                        break :blk store_ptr.addType(.{ .list = .{ .element = head_expr.type_id } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    if (tail_expr.type_id != types_mod.TypeStore.UNKNOWN) {
                        const tail_typ = self.type_store.getType(tail_expr.type_id);
                        if (tail_typ == .list) break :blk tail_expr.type_id;
                    }
                    break :blk types_mod.TypeStore.UNKNOWN;
                };
                return try self.create(Expr, .{
                    .kind = .{ .list_cons = .{
                        .head = head_expr,
                        .tail = tail_expr,
                    } },
                    .type_id = cons_type_id,
                    .span = lce.meta.span,
                });
            },
            .map => |m| {
                var entries: std.ArrayList(MapEntry) = .empty;
                for (m.fields) |field| {
                    const key = try self.buildExpr(field.key);
                    const value = try self.buildExpr(field.value);
                    try entries.append(self.allocator, .{
                        .key = key,
                        .value = value,
                    });
                }
                const built_entries = try entries.toOwnedSlice(self.allocator);
                // Infer map type by unifying all entry types. If keys (or
                // values) disagree across entries we promote the disagreeing
                // axis to `Term`, so the runtime container instantiates as
                // `Map(K, Term)` and individual values can be wrapped at
                // construction sites. Tuple values are unified component-wise.
                const map_type_id = if (built_entries.len > 0) blk: {
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    var key_type = built_entries[0].key.type_id;
                    var val_type = built_entries[0].value.type_id;
                    for (built_entries[1..]) |entry| {
                        if (entry.key.type_id != types_mod.TypeStore.UNKNOWN) {
                            key_type = unifyForCollection(store_ptr, key_type, entry.key.type_id);
                        }
                        if (entry.value.type_id != types_mod.TypeStore.UNKNOWN) {
                            val_type = unifyForCollection(store_ptr, val_type, entry.value.type_id);
                        }
                    }
                    if (key_type != types_mod.TypeStore.UNKNOWN and val_type != types_mod.TypeStore.UNKNOWN) {
                        break :blk store_ptr.addType(.{ .map = .{ .key = key_type, .value = val_type } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    break :blk types_mod.TypeStore.UNKNOWN;
                } else types_mod.TypeStore.UNKNOWN;
                return try self.create(Expr, .{
                    .kind = .{ .map_init = built_entries },
                    .type_id = map_type_id,
                    .span = m.meta.span,
                });
            },
            .pipe => {
                // Pipe should be desugared before reaching HIR
                unreachable;
            },
            .range => {
                // Range is rewritten to a struct_expr by the desugarer
                // (see desugar.zig). Reaching HIR with a raw `.range` means
                // a code path bypassed desugaring — surface it loudly rather
                // than silently re-desugaring here.
                unreachable;
            },
            .struct_expr => |se| {
                // Resolve struct type from module name (e.g., %Point{x: 1, y: 2})
                var struct_type_id = types_mod.TypeStore.UNKNOWN;
                if (se.module_name.parts.len > 0) {
                    const type_name_id = se.module_name.parts[se.module_name.parts.len - 1];
                    if (self.type_store.name_to_type.get(type_name_id)) |tid| {
                        struct_type_id = tid;
                    }
                }
                // Build field expressions
                var hir_fields: std.ArrayList(StructFieldInit) = .empty;
                for (se.fields) |field| {
                    const value = try self.buildExpr(field.value);
                    try hir_fields.append(self.allocator, .{
                        .name = field.name,
                        .value = value,
                    });
                }
                return try self.create(Expr, .{
                    .kind = .{ .struct_init = .{
                        .type_id = struct_type_id,
                        .fields = try hir_fields.toOwnedSlice(self.allocator),
                    } },
                    .type_id = struct_type_id,
                    .span = se.meta.span,
                });
            },
            .field_access => |fa| {
                // Module-qualified reference (e.g. Math.square without call parens)
                if (fa.object.* == .module_ref) {
                    const func_name = self.interner.get(fa.field);
                    const mod_name = self.structNameToString(fa.object.module_ref.name);

                    // Check if this is an enum variant access (e.g. Color.Red
                    // or IO.Mode.Raw for a dotted-name union)
                    const mod_parts = fa.object.module_ref.name.parts;

                    // Try to resolve as a union type. For dotted names like IO.Mode,
                    // build the full dotted name and look it up.
                    const resolved_tid: ?types_mod.TypeId = blk: {
                        if (mod_parts.len >= 2) {
                            // Build full dotted name (e.g., "IO.Mode")
                            var name_buf: std.ArrayList(u8) = .empty;
                            for (mod_parts, 0..) |part, i| {
                                if (i > 0) name_buf.append(self.allocator, '.') catch {};
                                name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
                            }
                            const interner_mut = @constCast(self.interner);
                            const full_name_id = interner_mut.intern(name_buf.items) catch break :blk null;
                            if (self.type_store.name_to_type.get(full_name_id)) |tid| break :blk tid;
                            // Fall back to last part only
                            if (self.type_store.name_to_type.get(mod_parts[mod_parts.len - 1])) |tid| break :blk tid;
                        } else if (mod_parts.len == 1) {
                            if (self.type_store.name_to_type.get(mod_parts[0])) |tid| break :blk tid;
                        }
                        break :blk null;
                    };

                    if (resolved_tid) |tid| {
                        const typ = self.type_store.getType(tid);
                        if (typ == .tagged_union) {
                            return try self.create(Expr, .{
                                .kind = .{
                                    .field_get = .{
                                        .object = try self.create(Expr, .{
                                            .kind = .nil_lit, // placeholder for enum type ref
                                            .type_id = tid,
                                            .span = fa.object.getMeta().span,
                                        }),
                                        .field = fa.field,
                                    },
                                },
                                .type_id = tid,
                                .span = fa.meta.span,
                            });
                        }
                    }

                    return try self.create(Expr, .{
                        .kind = .{ .call = .{
                            .target = .{ .named = .{ .module = mod_name, .name = func_name } },
                            .args = &.{},
                        } },
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .span = fa.meta.span,
                    });
                }
                // Struct field access (e.g. user.name)
                const object = try self.buildExpr(fa.object);
                return try self.create(Expr, .{
                    .kind = .{ .field_get = .{
                        .object = object,
                        .field = fa.field,
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = fa.meta.span,
                });
            },
            .unwrap => |ue| {
                const inner = try self.buildExpr(ue.expr);
                return try self.create(Expr, .{
                    .kind = .{ .unwrap = inner },
                    .type_id = inner.type_id,
                    .span = ue.meta.span,
                });
            },
            .block => |blk| {
                const inner = try self.buildBlock(blk.stmts);
                return try self.create(Expr, .{
                    .kind = .{ .block = inner.* },
                    .type_id = inner.result_type,
                    .span = blk.meta.span,
                });
            },
            .type_annotated => |ta| {
                // expr :: Type — lower the inner expression with the annotated type
                const inner = try self.buildExpr(ta.expr);
                const annotated_type = self.resolveTypeExpr(ta.type_expr);
                return try self.create(Expr, .{
                    .kind = inner.kind,
                    .type_id = annotated_type,
                    .span = ta.meta.span,
                });
            },
            .function_ref => |fr| {
                const function_type = try self.resolveFunctionRefType(fr);
                if (self.resolveFunctionRefGroup(fr)) |group_id| {
                    return try self.buildFunctionValueExpr(group_id, function_type, fr.meta.span);
                }
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = function_type,
                    .span = fr.meta.span,
                });
            },
            .anonymous_function => |anon| {
                var function_type = try self.resolveFunctionValueType(anon.decl.name);
                // Fall back to building type from the clause directly if scope lookup fails
                if (function_type == types_mod.TypeStore.UNKNOWN and anon.decl.clauses.len > 0) {
                    function_type = try self.buildResolvedFunctionType(anon.decl.clauses[0]);
                }
                const group_scope = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
                const group = try self.buildFunctionGroup(anon.decl, group_scope, null, true);
                const group_ptr = try self.create(FunctionGroup, group);
                const closure_expr = try self.buildFunctionValueExpr(group.id, function_type, anon.meta.span);
                const block = try self.create(Block, .{
                    .stmts = try self.allocator.dupe(Stmt, &.{
                        .{ .function_group = group_ptr },
                        .{ .expr = closure_expr },
                    }),
                    .result_type = function_type,
                });
                return try self.create(Expr, .{
                    .kind = .{ .block = block.* },
                    .type_id = function_type,
                    .span = anon.meta.span,
                });
            },
            .module_ref => |mr| {
                // Check for enum variant reference:
                //   Color.Red → parts ["Color", "Red"] (type is parts[0], variant is parts[1])
                //   IO.Mode.Raw → parts ["IO", "Mode", "Raw"] (type is "IO.Mode", variant is "Raw")
                if (mr.name.parts.len >= 2) {
                    const variant_name = mr.name.parts[mr.name.parts.len - 1];
                    // Build the type name from all parts except the last (the variant)
                    const type_tid: ?types_mod.TypeId = blk: {
                        // Try just the penultimate part (e.g., "Color" from Color.Red)
                        const simple_name = mr.name.parts[mr.name.parts.len - 2];
                        if (self.type_store.name_to_type.get(simple_name)) |tid| break :blk tid;
                        // Try the full dotted prefix (e.g., "IO.Mode" from IO.Mode.Raw)
                        if (mr.name.parts.len >= 3) {
                            var name_buf: std.ArrayList(u8) = .empty;
                            for (mr.name.parts[0 .. mr.name.parts.len - 1], 0..) |part, i| {
                                if (i > 0) name_buf.append(self.allocator, '.') catch {};
                                name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
                            }
                            const interner_mut = @constCast(self.interner);
                            const full_name_id = interner_mut.intern(name_buf.items) catch break :blk null;
                            if (self.type_store.name_to_type.get(full_name_id)) |tid| break :blk tid;
                        }
                        break :blk null;
                    };
                    if (type_tid) |tid| {
                        const typ = self.type_store.getType(tid);
                        if (typ == .tagged_union) {
                            return try self.create(Expr, .{
                                .kind = .{
                                    .field_get = .{
                                        .object = try self.create(Expr, .{
                                            .kind = .nil_lit, // placeholder for enum type ref
                                            .type_id = tid,
                                            .span = mr.meta.span,
                                        }),
                                        .field = variant_name,
                                    },
                                },
                                .type_id = tid,
                                .span = mr.meta.span,
                            });
                        }
                    }
                }
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = mr.meta.span,
                });
            },
            else => {
                const meta = expr.getMeta();
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
            },
        };
    }

    // ============================================================
    // Error pipe lowering
    // ============================================================

    /// Build an error pipe expression: chain ~> handler
    /// Flattens the pipe chain, builds each step, detects which return tagged
    /// unions, and produces an ErrorPipeHir that the IR builder lowers to
    /// nested union_switch instructions.
    fn buildErrorPipe(self: *HirBuilder, ep: ast.ErrorPipeExpr) anyerror!*const Expr {
        // Flatten the AST pipe chain into individual steps
        var ast_steps: std.ArrayList(*const ast.Expr) = .empty;
        self.flattenAstPipeChain(ep.chain, &ast_steps);

        if (ast_steps.items.len == 0) {
            return try self.create(Expr, .{
                .kind = .nil_lit,
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = ep.meta.span,
            });
        }

        // Build each step as a HIR expression.
        // Step 0 is the base call. Steps 1+ are pipe rhs (need lhs piped in as first arg).
        var hir_steps: std.ArrayList(ErrorPipeStep) = .empty;
        for (ast_steps.items) |step| {
            const hir_expr = try self.buildExpr(step);
            // Check if this step calls a multi-clause function (needs __try variant)
            const is_dispatched = blk: {
                if (step.* == .call) {
                    const callee = step.call.callee;
                    const arity: u32 = @intCast(step.call.args.len + 1);
                    if (callee.* == .var_ref) {
                        break :blk self.isFunctionMultiClause(callee.var_ref.name, arity);
                    } else if (callee.* == .field_access) {
                        break :blk self.isFunctionMultiClause(callee.field_access.field, arity);
                    }
                }
                break :blk false;
            };
            try hir_steps.append(self.allocator, .{
                .expr = hir_expr,
                .is_dispatched = is_dispatched,
            });
        }

        // Build the error handler expression
        const handler_lowering = try self.buildErrorHandlerExpr(ep.handler, ep.meta);

        // Result type is the last step's type (the catch basin handler
        // must return the same type for the expression to be well-typed).
        const result_type = if (hir_steps.items.len > 0)
            hir_steps.items[hir_steps.items.len - 1].expr.type_id
        else
            types_mod.TypeStore.UNKNOWN;

        return try self.create(Expr, .{
            .kind = .{ .error_pipe = .{
                .steps = try hir_steps.toOwnedSlice(self.allocator),
                .handler = handler_lowering.expr,
                .err_local = handler_lowering.err_local,
            } },
            .type_id = result_type,
            .span = ep.meta.span,
        });
    }

    /// Flatten a pipe chain AST expression into individual steps.
    fn flattenAstPipeChain(self: *HirBuilder, expr: *const ast.Expr, steps: *std.ArrayList(*const ast.Expr)) void {
        switch (expr.*) {
            .pipe => |pe| {
                self.flattenAstPipeChain(pe.lhs, steps);
                steps.append(self.allocator, pe.rhs) catch {};
            },
            else => {
                steps.append(self.allocator, expr) catch {};
            },
        }
    }

    const HandlerLowering = struct {
        expr: *const Expr,
        /// `null` → no `__err` allocation (function-style handler).
        /// Some(idx) → IR populates local `idx` with the failing pipe value
        /// before lowering the handler; pattern bindings on `__err` resolve
        /// to the same local index.
        err_local: ?u32,
    };

    /// Build an error handler HIR expression from an AST ErrorHandler.
    /// For block handlers `~> { pattern -> body, ... }`, builds a case
    /// expression that pattern-matches on a fresh `__err` local. The IR
    /// populates that local with the failing pipe value before lowering
    /// the handler. For function handlers `~> handler_fn(...)` the function
    /// expression is returned directly with no `__err` allocation; the IR
    /// passes the failing value as the function's first argument.
    fn buildErrorHandlerExpr(self: *HirBuilder, handler: ast.ErrorHandler, meta: ast.NodeMeta) !HandlerLowering {
        switch (handler) {
            .block => |clauses| {
                // Allocate a fresh local for `__err`. The IR sets this local
                // to the failing pipe value before lowering the handler, so
                // both pattern bindings and the synthesized var_ref to __err
                // resolve to the same index.
                const err_local = self.next_local;
                self.next_local += 1;

                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                const err_name = try interner_mut.intern("__err");

                // Make `__err` resolvable as a normal binding for the
                // duration of the case build. Restored on exit so the
                // surrounding scope sees no leaked binding.
                try self.current_assignment_bindings.append(self.allocator, .{
                    .name = err_name,
                    .local_index = err_local,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                });
                const saved_bindings_len = self.current_assignment_bindings.items.len;
                defer {
                    if (self.current_assignment_bindings.items.len == saved_bindings_len) {
                        _ = self.current_assignment_bindings.pop();
                    }
                }

                const scrutinee_expr = try self.create(Expr, .{
                    .kind = .{ .local_get = err_local },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });

                // Build case arms by reusing the regular case-expr binding/
                // pattern machinery. Each arm gets its own binding state via
                // save/restore so cross-arm leakage cannot occur.
                var arms: std.ArrayList(CaseArm) = .empty;
                for (clauses) |clause| {
                    const saved_case_bindings = self.current_case_bindings;
                    self.current_case_bindings = .empty;

                    const pattern = try self.compilePattern(clause.pattern);
                    if (pattern) |pat| {
                        try self.collectCasePatternBindings(pat, true);
                    }

                    const guard_expr = if (clause.guard) |g| try self.buildExpr(g) else null;
                    const body = try self.buildBlock(clause.body);
                    const bindings = try self.current_case_bindings.toOwnedSlice(self.allocator);

                    try arms.append(self.allocator, .{
                        .pattern = pattern,
                        .guard = guard_expr,
                        .body = body,
                        .bindings = bindings,
                    });

                    self.current_case_bindings = saved_case_bindings;
                }

                const case_expr = try self.create(Expr, .{
                    .kind = .{ .case = .{
                        .scrutinee = scrutinee_expr,
                        .arms = try arms.toOwnedSlice(self.allocator),
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
                return .{ .expr = case_expr, .err_local = err_local };
            },
            .function => |func| {
                return .{ .expr = try self.buildExpr(func), .err_local = null };
            },
        }
    }

    // ============================================================
    // Allocation helper
    // ============================================================

    fn resolveTypeExpr(self: *const HirBuilder, type_expr: *const ast.TypeExpr) TypeId {
        return switch (type_expr.*) {
            .name => |n| {
                const name_str = self.interner.get(n.name);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);

                // Names already bound as type variables in the active
                // hir_type_var_scope short-circuit to the bound TypeId.
                // Mirrors the type checker's behaviour so impl-declared
                // parameters like `K`, `V` resolve consistently across
                // params and return types.
                if (n.args.len == 0) {
                    if (self.hir_type_var_scope.get(name_str)) |existing| return existing;
                }

                // Built-in generic containers: `Map(K, V)` and `List(T)`
                // map onto the dedicated TypeStore variants the rest of
                // the pipeline already understands. Same shape that the
                // existing `[T]` and `%{K=>V}` sigils produce. The native
                // type identity comes from the `@native_type` attribute
                // on the corresponding stdlib struct (see ScopeGraph
                // `NativeTypeKind`), so users can shadow `List`/`Map`
                // safely without triggering compiler-special handling.
                if (n.args.len > 0) {
                    if (self.graph.isNativeTypeName(.map, n.name) and n.args.len == 2) {
                        const key_t = self.resolveTypeExpr(n.args[0]);
                        const value_t = self.resolveTypeExpr(n.args[1]);
                        return store_ptr.addType(.{ .map = .{ .key = key_t, .value = value_t } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    if (self.graph.isNativeTypeName(.list, n.name) and n.args.len == 1) {
                        const elem_t = self.resolveTypeExpr(n.args[0]);
                        return store_ptr.addType(.{ .list = .{ .element = elem_t } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                }

                // First check builtins
                if (self.type_store.resolveTypeName(name_str)) |id| return id;
                // Then check user-defined types (struct/enum) from scope graph
                if (self.graph.resolveTypeByName(n.name)) |scope_type_id| {
                    // Resolve scope TypeId to TypeStore TypeId via name_to_type map
                    if (self.type_store.name_to_type.get(n.name)) |ts_id| return ts_id;
                    // If not in TypeStore yet, it may be a forward reference
                    _ = scope_type_id;
                }
                // Check if this is a protocol name — create a protocol_constraint type
                for (self.graph.protocols.items) |proto| {
                    if (proto.name.parts.len > 0 and proto.name.parts[proto.name.parts.len - 1] == n.name) {
                        // Resolve type parameters (e.g., Enumerable(member) → [type_var_for_member])
                        var type_params: std.ArrayList(types_mod.TypeId) = .empty;
                        for (n.args) |arg| {
                            type_params.append(self.allocator, self.resolveTypeExpr(arg)) catch {};
                        }
                        return store_ptr.addType(.{
                            .protocol_constraint = .{
                                .protocol_name = n.name,
                                .type_params = type_params.toOwnedSlice(self.allocator) catch &.{},
                            },
                        }) catch types_mod.TypeStore.UNKNOWN;
                    }
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .never => types_mod.TypeStore.NEVER,
            .paren => |p| self.resolveTypeExpr(p.inner),
            .literal => |lt| {
                return switch (lt.value) {
                    .int => types_mod.TypeStore.I64,
                    .string => types_mod.TypeStore.STRING,
                    .bool_val => types_mod.TypeStore.BOOL,
                    .nil => types_mod.TypeStore.NIL,
                };
            },
            .union_type => |ut| {
                // General union type — resolve each member
                var member_types: std.ArrayList(TypeId) = .empty;
                for (ut.members) |member| {
                    member_types.append(self.allocator, self.resolveTypeExpr(member)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const members = member_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                for (self.type_store.types.items, 0..) |typ, i| {
                    if (typ == .union_type) {
                        const existing = typ.union_type;
                        if (existing.members.len == members.len) {
                            var match = true;
                            for (existing.members, members) |a, b| {
                                if (a != b) {
                                    match = false;
                                    break;
                                }
                            }
                            if (match) return @intCast(i);
                        }
                    }
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .tuple => |tt| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (tt.elements) |elem| {
                    elem_types.append(self.allocator, self.resolveTypeExpr(elem)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const elements = elem_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return store_ptr.addType(.{ .tuple = .{ .elements = elements } }) catch types_mod.TypeStore.UNKNOWN;
            },
            .function => |ft| {
                var param_types: std.ArrayList(TypeId) = .empty;
                for (ft.params) |param| {
                    param_types.append(self.allocator, self.resolveTypeExpr(param)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const params = param_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                const param_ownerships = self.allocator.alloc(Ownership, ft.param_ownerships.len) catch return types_mod.TypeStore.UNKNOWN;
                for (ft.param_ownerships, ft.param_ownerships_explicit, params, 0..) |ownership, explicit, param_type, idx| {
                    param_ownerships[idx] = if (explicit)
                        mapAstOwnership(ownership)
                    else if (mapAstOwnership(ownership) == .shared)
                        self.defaultOwnershipForType(param_type)
                    else
                        mapAstOwnership(ownership);
                }
                const return_type = self.resolveTypeExpr(ft.return_type);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                const ret_ownership = if (ft.return_ownership_explicit)
                    mapAstOwnership(ft.return_ownership)
                else if (mapAstOwnership(ft.return_ownership) == .shared)
                    self.defaultOwnershipForType(return_type)
                else
                    mapAstOwnership(ft.return_ownership);
                return store_ptr.addFunctionType(params, return_type, param_ownerships, ret_ownership) catch types_mod.TypeStore.UNKNOWN;
            },
            .list => |lt| {
                const elem_type = self.resolveTypeExpr(lt.element);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return store_ptr.addType(.{ .list = .{ .element = elem_type } }) catch types_mod.TypeStore.UNKNOWN;
            },
            .map => |mt| {
                if (mt.fields.len > 0) {
                    const key_type = self.resolveTypeExpr(mt.fields[0].key);
                    const value_type = self.resolveTypeExpr(mt.fields[0].value);
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    return store_ptr.addType(.{ .map = .{ .key = key_type, .value = value_type } }) catch types_mod.TypeStore.UNKNOWN;
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .variable => |tv| {
                // Type variable — ensure the same name within a function clause maps
                // to the same TypeId so that `fn foo(x :: a) -> a` has consistent types.
                const var_name = self.interner.get(tv.name);
                if (self.hir_type_var_scope.get(var_name)) |existing| {
                    return existing;
                }
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                const fresh = store_ptr.freshVar() catch return types_mod.TypeStore.UNKNOWN;
                const self_mut: *HirBuilder = @constCast(self);
                self_mut.hir_type_var_scope.put(var_name, fresh) catch {};
                return fresh;
            },
            else => types_mod.TypeStore.UNKNOWN,
        };
    }

    /// Resolve a bare call to an imported module via the current scope's imports.
    /// Returns the module name string if the function is imported, null otherwise.
    /// Resolution follows Elixir semantics: local module > imports > Kernel/top-level.
    fn resolveImport(self: *const HirBuilder, name: ast.StringId, arity: u32) ?[]const u8 {
        const mod_scope_id = self.current_module_scope orelse return null;
        const mod_scope = self.graph.getScope(mod_scope_id);

        // Check if the function is defined locally in this module (local takes priority)
        const local_key = scope_mod.FamilyKey{ .name = name, .arity = arity };
        if (mod_scope.function_families.get(local_key) != null) return null;

        // Check imports on this scope
        for (mod_scope.imports.items) |imp| {
            if (self.importMatchesFunction(imp, name, arity)) {
                return self.structNameToString(imp.source_module);
            }
        }

        return null;
    }

    /// Check if an import declaration makes a specific function name/arity available.
    fn importMatchesFunction(self: *const HirBuilder, imp: scope_mod.ImportedScope, name: ast.StringId, arity: u32) bool {
        switch (imp.filter) {
            .all => {
                // Import all — verify the source module actually exports this function
                return self.sourceModuleHasFunction(imp.source_module, name, arity);
            },
            .only => |entries| {
                // Only import listed functions
                for (entries) |entry| {
                    if (entry.name == name) {
                        if (entry.arity) |a| {
                            if (a == arity) return true;
                        } else {
                            // Type import (arity null) — doesn't match function calls
                            continue;
                        }
                    }
                }
                return false;
            },
            .except => |entries| {
                // Import all except listed — first check source module exports it
                if (!self.sourceModuleHasFunction(imp.source_module, name, arity)) return false;
                // Then check it's not excluded
                for (entries) |entry| {
                    if (entry.name == name) {
                        if (entry.arity) |a| {
                            if (a == arity) return false; // excluded
                        }
                    }
                }
                return true;
            },
        }
    }

    /// Check if a module (by name) exports a specific function.
    fn sourceModuleHasFunction(self: *const HirBuilder, mod_name: ast.StructName, name: ast.StringId, arity: u32) bool {
        // Find the module in the scope graph
        for (self.graph.structs.items) |mod_entry| {
            if (self.structNamesEqual(mod_entry.name, mod_name)) {
                const mod_scope = self.graph.getScope(mod_entry.scope_id);
                const key = scope_mod.FamilyKey{ .name = name, .arity = arity };
                return mod_scope.function_families.get(key) != null;
            }
        }
        return false;
    }

    /// Compare two StructNames for equality (all parts must match).
    fn structNamesEqual(_: *const HirBuilder, a: ast.StructName, b: ast.StructName) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |pa, pb| {
            if (pa != pb) return false;
        }
        return true;
    }

    fn structNameToString(self: *const HirBuilder, name: ast.StructName) []const u8 {
        if (name.parts.len == 1) return self.interner.get(name.parts[0]);
        return name.joinedWith(self.allocator, self.interner, "_") catch self.interner.get(name.parts[0]);
    }

    /// True iff `impl <protocol_simple> for <target_simple>` exists in the
    /// scope graph. Both names are matched as single-part struct names —
    /// adequate for the current built-in protocols (`Arithmetic`,
    /// `Comparator`, etc.) that target single-segment types like
    /// `Integer` or `Float`.
    fn hasImpl(self: *const HirBuilder, protocol_simple: []const u8, target_simple: []const u8) bool {
        for (self.graph.impls.items) |entry| {
            if (entry.protocol_name.parts.len != 1 or entry.target_type.parts.len != 1) continue;
            const p = self.interner.get(entry.protocol_name.parts[0]);
            const t = self.interner.get(entry.target_type.parts[0]);
            if (std.mem.eql(u8, p, protocol_simple) and std.mem.eql(u8, t, target_simple)) return true;
        }
        return false;
    }

    /// True iff `name` matches a registered single-segment protocol
    /// (e.g., `Enumerable`, `Arithmetic`).
    fn isProtocolName(self: *const HirBuilder, name: []const u8) bool {
        for (self.graph.protocols.items) |entry| {
            if (entry.name.parts.len != 1) continue;
            if (std.mem.eql(u8, self.interner.get(entry.name.parts[0]), name)) return true;
        }
        return false;
    }

    /// Generic protocol-call dispatch: when a user writes `Protocol.method(arg, ...)`
    /// and `Protocol` is a registered protocol with an `impl Protocol for T`
    /// matching the first argument's type, returns the target type's module
    /// name so the call lowers to `T.method(arg, ...)`.
    ///
    /// Returns null when:
    ///   - `mod_name` is not a registered protocol
    ///   - the first arg's type is UNKNOWN or has no canonical module name
    ///   - no impl exists for the resolved target type
    /// Callers fall through to the original module name when null is returned.
    fn protocolDispatchModule(
        self: *const HirBuilder,
        mod_name: []const u8,
        first_arg_type: types_mod.TypeId,
    ) ?[]const u8 {
        if (!self.isProtocolName(mod_name)) return null;
        if (first_arg_type == types_mod.TypeStore.UNKNOWN) return null;
        const target_module = self.type_store.typeToModuleName(first_arg_type, self.interner) orelse return null;
        if (!self.hasImpl(mod_name, target_module)) return null;
        return target_module;
    }

    /// Walk a block and stamp `expected_type` on any UNKNOWN-typed
    /// empty container literals (currently `list_init []` and
    /// `map_init {}`). Used by `case_expr` to propagate a unified arm
    /// type back into siblings whose result is an empty literal — the
    /// for-comprehension's `{:done, _, _} -> []` arm being the canonical
    /// example. Mutates the block's HIR in place via @constCast; the
    /// HIR allocator owns these expressions and they're not shared
    /// across modules.
    /// Compute the element TypeId for a list literal whose entries are
    /// already lowered to HIR. Performs structural unification so that
    /// disagreeing scalar elements promote to `TERM`, and disagreeing
    /// tuple components promote position-wise to `TERM`.
    ///
    /// Examples:
    ///   `[1, 2, 3]`              → `[i64]`
    ///   `[1, "x"]`               → `[Term]`
    ///   `[{:a, 1}, {:b, "s"}]`   → `[{Atom, Term}]` (component-wise)
    ///   `[{:a, 1}, {:b, "s", 7}]`→ `[Term]` (different arity → fall back)
    fn inferListElementType(self: *const HirBuilder, built_elems: []const *const Expr) types_mod.TypeId {
        if (built_elems.len == 0) return types_mod.TypeStore.UNKNOWN;
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);

        // First pass: pick a starting concrete type.
        var element_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
        for (built_elems) |elem| {
            if (elem.type_id != types_mod.TypeStore.UNKNOWN) {
                element_type = elem.type_id;
                break;
            }
        }

        // Fallback: detect string-literal lists when nothing carries type info.
        if (element_type == types_mod.TypeStore.UNKNOWN) {
            for (built_elems) |elem| {
                if (elem.kind == .string_lit) {
                    element_type = types_mod.TypeStore.STRING;
                    break;
                }
            }
        }

        if (element_type == types_mod.TypeStore.UNKNOWN) return types_mod.TypeStore.UNKNOWN;

        // Second pass: unify the chosen type with every other element.
        for (built_elems) |elem| {
            if (elem.type_id == types_mod.TypeStore.UNKNOWN) continue;
            element_type = unifyForCollection(store_ptr, element_type, elem.type_id);
        }

        return store_ptr.addType(.{ .list = .{ .element = element_type } }) catch types_mod.TypeStore.UNKNOWN;
    }

    fn patchEmptyContainerTypes(self: *const HirBuilder, block: *const Block, expected_type: types_mod.TypeId) void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| self.patchEmptyContainerTypesExpr(expr, expected_type),
                .local_set => |ls| self.patchEmptyContainerTypesExpr(ls.value, expected_type),
                .function_group => {},
            }
        }
        if (block.result_type == types_mod.TypeStore.UNKNOWN) {
            const mut: *Block = @constCast(block);
            mut.result_type = expected_type;
        }
    }

    fn patchEmptyContainerTypesExpr(self: *const HirBuilder, expr: *const Expr, expected_type: types_mod.TypeId) void {
        const expected_kind = self.type_store.getType(expected_type);
        switch (expr.kind) {
            .list_init => |elems| {
                if (elems.len == 0 and expr.type_id == types_mod.TypeStore.UNKNOWN and expected_kind == .list) {
                    const mut: *Expr = @constCast(expr);
                    mut.type_id = expected_type;
                }
            },
            .map_init => |entries| {
                if (entries.len == 0 and expr.type_id == types_mod.TypeStore.UNKNOWN and expected_kind == .map) {
                    const mut: *Expr = @constCast(expr);
                    mut.type_id = expected_type;
                }
            },
            else => {},
        }
    }

    /// Recursively collect case-arm bindings from a match pattern.
    /// `is_top_level` distinguishes a top-level `name -> body` bind (kind=.scrutinee,
    /// emitted by the success leaf) from binds nested inside a compound pattern
    /// (kind=.extracted, emitted by a decision-tree `.bind` node).
    fn collectCasePatternBindings(self: *HirBuilder, pat: *const MatchPattern, is_top_level: bool) !void {
        switch (pat.*) {
            .bind => |name| {
                const name_str = self.interner.get(name);
                // Skip user-intent discards (`_x`) but keep compiler-
                // synthesised names (`__next_state`, `__err`, …) — those
                // back generated bindings the IR's bind-decision-tree
                // handler must resolve to extract decomposed values
                // (e.g. the cont-arm tail in a for-comprehension).
                if (ast.isDiscardBindName(name_str)) return;
                const local_idx = self.next_local;
                self.next_local += 1;
                try self.current_case_bindings.append(self.allocator, .{
                    .name = name,
                    .local_index = local_idx,
                    .kind = if (is_top_level) .scrutinee else .extracted,
                    .element_index = 0,
                });
            },
            .tuple => |sub_pats| {
                for (sub_pats) |sub_pat| {
                    try self.collectCasePatternBindings(sub_pat, false);
                }
            },
            .list => |sub_pats| {
                for (sub_pats) |sub_pat| {
                    try self.collectCasePatternBindings(sub_pat, false);
                }
            },
            .list_cons => |lc| {
                for (lc.heads) |head_pat| {
                    try self.collectCasePatternBindings(head_pat, false);
                }
                try self.collectCasePatternBindings(lc.tail, false);
            },
            .struct_match => |sm| {
                for (sm.field_bindings) |field| {
                    try self.collectCasePatternBindings(field.pattern, false);
                }
            },
            .map_match => |mm| {
                for (mm.field_bindings) |field| {
                    try self.collectCasePatternBindings(field.pattern, false);
                }
            },
            .binary_match => |bm| {
                for (bm.segments, 0..) |seg, seg_idx| {
                    if (seg.pattern) |sub_pat| {
                        if (sub_pat.* != .bind) continue;
                        const name_str = self.interner.get(sub_pat.bind);
                        // Same discard convention as the case-pattern
                        // collector — see `ast.isDiscardBindName`.
                        if (ast.isDiscardBindName(name_str)) continue;
                        const local_idx = self.next_local;
                        self.next_local += 1;
                        try self.current_case_bindings.append(self.allocator, .{
                            .name = sub_pat.bind,
                            .local_index = local_idx,
                            .kind = .binary_element,
                            .element_index = @intCast(seg_idx),
                        });
                    }
                }
            },
            .wildcard, .literal, .pin => {},
        }
    }

    fn create(self: *HirBuilder, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    /// Recursively destructure an assignment LHS pattern, emitting one
    /// `local_set` per inner `bind` and registering each as an
    /// `AssignmentBinding` for later var_ref resolution. The parent
    /// compound value lives in `parent_local`; nested patterns reference
    /// it via a `local_get` extractor.
    fn lowerAssignmentDestructure(
        self: *HirBuilder,
        pat: *const ast.Pattern,
        parent_local: u32,
        parent_type: TypeId,
        span: ast.SourceSpan,
        out_stmts: *std.ArrayList(Stmt),
    ) !void {
        switch (pat.*) {
            .wildcard, .literal => {},
            .pin => {},
            .paren => |inner| try self.lowerAssignmentDestructure(inner.inner, parent_local, parent_type, span, out_stmts),
            .bind => |b| {
                // A bind nested in a compound: alias the parent's local (no
                // copy, no extraction). The parent extractor already produced
                // a fresh local; the bind just gives it a name.
                try self.current_assignment_bindings.append(self.allocator, .{
                    .name = b.name,
                    .local_index = parent_local,
                    .type_id = parent_type,
                });
            },
            .tuple => |tp| {
                const parent_typ = self.type_store.getType(parent_type);
                for (tp.elements, 0..) |sub_pat, idx| {
                    if (sub_pat.* == .wildcard or sub_pat.* == .literal) continue;
                    const elem_type = if (parent_typ == .tuple and idx < parent_typ.tuple.elements.len)
                        parent_typ.tuple.elements[idx]
                    else
                        types_mod.TypeStore.UNKNOWN;
                    const elem_local = try self.emitDestructureStep(.{ .tuple = .{
                        .object = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .index = @intCast(idx),
                    } }, elem_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(sub_pat, elem_local, elem_type, span, out_stmts);
                }
            },
            .list => |lp| {
                const parent_typ = self.type_store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                for (lp.elements, 0..) |sub_pat, idx| {
                    if (sub_pat.* == .wildcard or sub_pat.* == .literal) continue;
                    const elem_local = try self.emitDestructureStep(.{ .list_at = .{
                        .list = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .index = @intCast(idx),
                    } }, elem_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(sub_pat, elem_local, elem_type, span, out_stmts);
                }
            },
            .list_cons => |lc| {
                const parent_typ = self.type_store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                var current_list_local = parent_local;
                var current_list_type = parent_type;
                for (lc.heads) |head_pat| {
                    if (!(head_pat.* == .wildcard or head_pat.* == .literal)) {
                        const head_local = try self.emitDestructureStep(.{ .list_head = .{
                            .list = try self.create(Expr, .{ .kind = .{ .local_get = current_list_local }, .type_id = current_list_type, .span = span }),
                        } }, elem_type, span, out_stmts);
                        try self.lowerAssignmentDestructure(head_pat, head_local, elem_type, span, out_stmts);
                    }
                    const tail_local = try self.emitDestructureStep(.{ .list_tail = .{
                        .list = try self.create(Expr, .{ .kind = .{ .local_get = current_list_local }, .type_id = current_list_type, .span = span }),
                    } }, parent_type, span, out_stmts);
                    current_list_local = tail_local;
                    current_list_type = parent_type;
                }
                if (!(lc.tail.* == .wildcard or lc.tail.* == .literal)) {
                    try self.lowerAssignmentDestructure(lc.tail, current_list_local, current_list_type, span, out_stmts);
                }
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| {
                    if (field.pattern.* == .wildcard or field.pattern.* == .literal) continue;
                    const field_type = self.resolveStructFieldType(parent_type, field.name);
                    const field_local = try self.emitDestructureStep(.{ .field = .{
                        .object = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .field = field.name,
                    } }, field_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(field.pattern, field_local, field_type, span, out_stmts);
                }
            },
            .map => |mp| {
                const parent_typ = self.type_store.getType(parent_type);
                const value_type = if (parent_typ == .map) parent_typ.map.value else types_mod.TypeStore.UNKNOWN;
                for (mp.fields) |field| {
                    if (field.value.* == .wildcard or field.value.* == .literal) continue;
                    const key_expr = try self.buildExpr(field.key);
                    const value_local = try self.emitDestructureStep(.{ .map_at = .{
                        .map = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .key = key_expr,
                    } }, value_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(field.value, value_local, value_type, span, out_stmts);
                }
            },
            .binary => {
                // Binary patterns on assignment LHS are uncommon. Treat as a
                // no-op for now — when this becomes a real use case, build a
                // case expression via the binary segment extractor.
            },
        }
    }

    const DestructureStep = union(enum) {
        tuple: TupleIndexGetExpr,
        list_at: ListIndexGetExpr,
        list_head: ListHeadGetExpr,
        list_tail: ListTailGetExpr,
        field: FieldGetExpr,
        map_at: MapValueGetExpr,
    };

    fn emitDestructureStep(
        self: *HirBuilder,
        step: DestructureStep,
        elem_type: TypeId,
        span: ast.SourceSpan,
        out_stmts: *std.ArrayList(Stmt),
    ) !u32 {
        const dest_local = self.next_local;
        self.next_local += 1;
        const expr_kind: ExprKind = switch (step) {
            .tuple => |s| .{ .tuple_index_get = s },
            .list_at => |s| .{ .list_index_get = s },
            .list_head => |s| .{ .list_head_get = s },
            .list_tail => |s| .{ .list_tail_get = s },
            .field => |s| .{ .field_get = s },
            .map_at => |s| .{ .map_value_get = s },
        };
        const value_expr = try self.create(Expr, .{
            .kind = expr_kind,
            .type_id = elem_type,
            .span = span,
        });
        try out_stmts.append(self.allocator, .{
            .local_set = .{ .index = dest_local, .value = value_expr },
        });
        return dest_local;
    }

    fn resolveStructFieldType(self: *const HirBuilder, struct_type: TypeId, field_name: ast.StringId) TypeId {
        const typ = self.type_store.getType(struct_type);
        if (typ != .struct_type) return types_mod.TypeStore.UNKNOWN;
        for (typ.struct_type.fields) |f| {
            if (f.name == field_name) return f.type_id;
        }
        return types_mod.TypeStore.UNKNOWN;
    }
};

/// Encode a TypeId into the short token used by ZIR's typed-builtin
/// dispatch (matches `ir.zigTypeToEncodedName`). Used to materialize
/// `:zig.List.fn` calls into `List:Elem.fn` so the runtime container
/// instantiates with the right element type.
/// Encode a HIR type as the short name used in `:zig.List.method` /
/// `:zig.Map.method` builtin call dispatch (e.g. `List:str.next`,
/// `Map:u32:bool.put`). Returns null for types the encoder cannot
/// resolve to a concrete instantiation — type variables, unknown,
/// or container types still bound to a generic parameter — so
/// callers fall through to the unqualified `Struct.method` form.
/// The IR's lowerCall arm then re-encodes from each call site's
/// actual local type, which is what makes monomorphized
/// specializations dispatch to the right runtime variant.
fn encodeContainerElemName(store: *const types_mod.TypeStore, type_id: types_mod.TypeId) ?[]const u8 {
    if (type_id == types_mod.TypeStore.UNKNOWN) return null;
    const t = store.getType(type_id);
    return switch (t) {
        .int => |i| switch (i.bits) {
            8 => if (i.signedness == .signed) "i8" else "u8",
            16 => if (i.signedness == .signed) "i16" else "u16",
            32 => if (i.signedness == .signed) "i32" else "u32",
            64 => if (i.signedness == .signed) "i64" else "u64",
            else => "i64",
        },
        .float => |f| switch (f.bits) {
            16 => "f16",
            32 => "f32",
            64 => "f64",
            else => "f64",
        },
        .bool_type => "bool",
        .string_type => "str",
        .atom_type => "u32",
        .term_type => "Term",
        .struct_type => |s| store.interner.get(s.name),
        .tagged_union => |tu| store.interner.get(tu.name),
        else => null,
    };
}

// Standard library resolution removed — IO, Kernel, etc. are now
// real Zap modules defined in lib/ and compiled with the program.

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "HIR build simple function" {
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

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.modules.len);
    try std.testing.expectEqual(@as(u32, 2), hir_program.modules[0].functions[0].arity);
}

test "HIR build module" {
    const source =
        \\pub struct Math {
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

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.modules.len);
    try std.testing.expectEqual(@as(usize, 1), hir_program.modules[0].functions.len);
}

test "HIR pattern compilation" {
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

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    // Should have built the function with case expression
    try std.testing.expectEqual(@as(usize, 1), hir_program.modules[0].functions.len);
    try std.testing.expectEqual(@as(usize, 0), builder.errors.items.len);
}

test "HIR typed params default to shared ownership" {
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

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.modules[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqual(Ownership.shared, params[0].ownership);
    try std.testing.expectEqual(Ownership.shared, params[1].ownership);
}

test "HIR opaque typed params default to unique ownership" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(handle :: Handle) -> Handle {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.modules[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqual(Ownership.unique, params[0].ownership);
}

test "HIR respects borrowed param annotation" {
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.modules[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(Ownership.borrowed, params[0].ownership);
}

test "HIR call args default to share mode" {
    const source =
        \\pub struct Test {
        \\  pub fn foo(x) {
        \\    x
        \\  }
        \\
        \\  pub fn bar(y) {
        \\    foo(y)
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

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const bar_clause = hir_program.modules[0].functions[1].clauses[0];
    const call_expr = bar_clause.body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.share, call_expr.kind.call.args[0].mode);
}

test "HIR call args adopt function ownership modes" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (String -> String), x :: String) -> String {
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
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const apply_clause = program.structs[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.resolveClauseScope(apply_clause.meta) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const param_ownerships = try alloc.alloc(Ownership, original_fn_type.params.len);
    for (param_ownerships, 0..) |*ownership, idx| {
        ownership.* = original_fn_type.param_ownerships.?[idx];
    }
    param_ownerships[0] = .unique;
    checker.store.types.items[f_type_id] = .{
        .function = .{
            .params = original_fn_type.params,
            .return_type = original_fn_type.return_type,
            .param_ownerships = param_ownerships,
            .return_ownership = original_fn_type.return_ownership,
        },
    };

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const call_expr = hir_program.modules[0].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.move, call_expr.kind.call.args[0].mode);
}

test "HIR named calls use resolved parameter ownership" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn take(handle :: Handle) -> Handle {
        \\    handle
        \\  }
        \\
        \\  pub fn run(handle :: Handle) -> Handle {
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
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const run_clause = hir_program.modules[0].functions[1].clauses[0];
    const call_expr = run_clause.body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.move, call_expr.kind.call.args[0].mode);
}

test "HIR closure calls adopt borrowed ownership mode" {
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
    const clause_scope = collector.graph.resolveClauseScope(apply_clause.meta) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .borrowed;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const call_expr = hir_program.modules[0].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(ValueMode.borrow, call_expr.kind.call.args[0].mode);
}

test "HIR function_ref keeps concrete function type" {
    const source =
        \\pub struct Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn run() -> (i64 -> i64) {
        \\    &double/1
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
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.modules[0].functions[1].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .closure_create);
    try std.testing.expect(expr.type_id != types_mod.TypeStore.UNKNOWN);

    const typ = checker.store.getType(expr.type_id);
    try std.testing.expect(typ == .function);
    try std.testing.expectEqual(@as(usize, 1), typ.function.params.len);
    try std.testing.expectEqual(types_mod.TypeStore.I64, typ.function.params[0]);
    try std.testing.expectEqual(types_mod.TypeStore.I64, typ.function.return_type);
}

/// Map a TypeId to a human-readable name string for synthesized type naming.
/// Must produce the same strings as TypeChecker.typeToString for deterministic matching.
fn typeIdToName(type_id: types_mod.TypeId, type_store: *const types_mod.TypeStore) []const u8 {
    return switch (type_id) {
        types_mod.TypeStore.BOOL => "Bool",
        types_mod.TypeStore.STRING => "String",
        types_mod.TypeStore.ATOM => "Atom",
        types_mod.TypeStore.NIL => "Nil",
        types_mod.TypeStore.NEVER => "Never",
        types_mod.TypeStore.I64 => "i64",
        types_mod.TypeStore.I32 => "i32",
        types_mod.TypeStore.I16 => "i16",
        types_mod.TypeStore.I8 => "i8",
        types_mod.TypeStore.U64 => "u64",
        types_mod.TypeStore.U32 => "u32",
        types_mod.TypeStore.U16 => "u16",
        types_mod.TypeStore.U8 => "u8",
        types_mod.TypeStore.F64 => "f64",
        types_mod.TypeStore.F32 => "f32",
        types_mod.TypeStore.F16 => "f16",
        types_mod.TypeStore.USIZE => "usize",
        types_mod.TypeStore.ISIZE => "isize",
        types_mod.TypeStore.UNKNOWN => "{unknown}",
        types_mod.TypeStore.ERROR => "{error}",
        else => {
            if (type_id < type_store.types.items.len) {
                const typ = type_store.types.items[type_id];
                return switch (typ) {
                    .tagged_union => |tu| type_store.interner.get(tu.name),
                    .struct_type => |st| type_store.interner.get(st.name),
                    else => "{type}",
                };
            }
            return "{type}";
        },
    };
}
