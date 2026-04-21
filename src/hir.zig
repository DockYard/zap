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
    name: ast.ModuleName,
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
    binding_id: scope_mod.BindingId,
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
    handler: *const Expr,
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
    element_index: u32, // only used for tuple_element
};

pub const CaseBindKind = enum {
    scrutinee, // bind the whole scrutinee value
    tuple_element, // bind an element extracted from the scrutinee tuple
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

pub fn compilePatternMatrix(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
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
            // Variable Rule: strip column 0, recurse
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id);
        },
        .all_constructor, .mixture => {
            return compileConstructorColumn(allocator, matrix, scrutinee_ids, next_id);
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
    const sub_decision = try compilePatternMatrix(allocator, .{
        .rows = new_rows,
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id);

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
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id);
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
        return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
    }

    switch (first_constructor.?.*) {
        .literal => |lit| {
            switch (lit) {
                .atom => {
                    // Atom literals -> switch_tag
                    return compileAtomSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
                },
                else => {
                    // Int/float/string/bool/nil literals -> switch_literal
                    return compileLiteralSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
                },
            }
        },
        .tuple => {
            // Tuple constructors -> check_tuple
            return compileTupleCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
        },
        .list => {
            // List constructors -> check_list (same structure as check_tuple but for slices)
            return compileListCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
        },
        .list_cons => {
            // List cons patterns -> check_list_cons (non-empty check + head/tail extraction)
            return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
        },
        .binary_match => {
            // Binary constructors -> check_binary
            return compileBinaryCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id);
        },
        else => {
            // Fallback: treat as variable rule
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id);
        },
    }
}

fn compileLiteralSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
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
        const sub_decision = try compilePatternMatrix(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id);

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
    const default_decision = try compilePatternMatrix(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id);

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
        const sub_decision = try compilePatternMatrix(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id);

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
    const default_decision = try compilePatternMatrix(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id);

    const d = try allocator.create(Decision);
    d.* = .{ .switch_tag = .{
        .scrutinee = scrutinee_expr,
        .cases = try switch_cases.toOwnedSlice(allocator),
        .default = default_decision,
    } };
    return d;
}

fn compileTupleCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
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
        current_failure = try compilePatternMatrix(allocator, .{
            .rows = try wildcard_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, remaining_scrutinees, next_id);
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
        const success_decision = try compilePatternMatrix(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id);

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
    var current_failure = try compilePatternMatrix(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id);

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

        const success_decision = try compilePatternMatrix(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id);

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
    const failure = try compilePatternMatrix(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id);

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

    const success_decision = try compilePatternMatrix(allocator, .{
        .rows = try success_rows.toOwnedSlice(allocator),
        .column_count = new_col_count,
    }, try new_scrutinee_list.toOwnedSlice(allocator), next_id);

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
) anyerror!*const Decision {
    // Calculate min byte size from the first binary pattern's segments
    // Accumulate bits for sub-byte types, then convert to bytes
    var min_bits: u32 = 0;
    var segments: []const BinaryMatchSegment = &.{};
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .binary_match) {
            segments = pat.?.binary_match.segments;
            for (segments) |seg| {
                switch (seg.type_spec) {
                    .default => min_bits += 8,
                    .integer => |i| min_bits += i.bits,
                    .float => |f| min_bits += f.bits,
                    .string => {
                        if (min_bits % 8 != 0) min_bits = (min_bits + 7) / 8 * 8;
                        if (seg.string_literal) |sl| {
                            _ = sl;
                            // String literal prefix — can't easily get length here without interner
                            // The IR emitter handles this more precisely
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
            break;
        }
    }

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

    var failure: *const Decision = undefined;
    if (wildcard_rows.items.len > 0) {
        failure = try compilePatternMatrix(allocator, .{
            .rows = try wildcard_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, remaining_scrutinees, next_id);
    } else {
        const f = try allocator.create(Decision);
        f.* = .failure;
        failure = f;
    }

    // Build success rows (strip column 0, keep remaining)
    var success_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .binary_match) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try success_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        } else if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try success_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const success = try compilePatternMatrix(allocator, .{
        .rows = try success_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, remaining_scrutinees, next_id);

    const d = try allocator.create(Decision);
    d.* = .{ .check_binary = .{
        .scrutinee = scrutinee_expr,
        .min_byte_size = (min_bits + 7) / 8,
        .segments = segments,
        .success = success,
        .failure = failure,
    } };
    return d;
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
    current_function_root_scope: ?scope_mod.ScopeId,
    current_function_name: ?[]const u8,
    current_function_name_id: ?ast.StringId,
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
        // Fall back to scope graph binding
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveBinding(scope_id, name)) |bid| {
            const binding = self.graph.bindings.items[bid];
            if (binding.type_id) |prov| {
                return prov.type_id;
            }
        }
        // Also check if this is a parameter with a type annotation
        // by looking at the current function's parameter types
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
        for (self.graph.modules.items) |mod_entry| {
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
                // Resolve param AND return types in the same type var scope
                // so that type variables like `element` and `result` are shared.
                const self_mut: *HirBuilder = @constCast(self);
                self_mut.hir_type_var_scope.clearRetainingCapacity();
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
                    // Resolve return type in the SAME type var scope as params
                    if (clause.return_type) |rt| {
                        const resolved_return = self.resolveTypeExpr(rt);
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                        return subs.applyToType(store_ptr, resolved_return);
                    }
                }
            }
        }
        return raw_return;
    }

    /// Resolve a function's return type within a specific module (for cross-module calls).
    fn resolveFunctionReturnTypeInModule(self: *const HirBuilder, mod_name: []const u8, func_name: []const u8, arity: u32) types_mod.TypeId {
        // Find the module's scope in the scope graph, then search families by scope
        for (self.graph.modules.items) |mod_entry| {
            if (mod_entry.name.parts.len == 0) continue;
            const last_part = self.interner.get(mod_entry.name.parts[mod_entry.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, mod_name)) continue;
            // Search families that belong to this module's scope
            for (self.graph.families.items) |family| {
                if (family.scope_id != mod_entry.scope_id) continue;
                if (family.arity != arity) continue;
                if (!std.mem.eql(u8, self.interner.get(family.name), func_name)) continue;
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
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Check if a function (by name and arity) has multiple clauses.
    /// Multi-clause functions are the ones that get __try variants for ~> catch basins.
    fn isFunctionMultiClause(self: *const HirBuilder, name: ast.StringId, arity: u32) bool {
        const scope_id = self.current_clause_scope orelse self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveFamily(scope_id, name, arity)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            return family.clauses.items.len > 1;
        }
        return false;
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
                    const clause_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
                    const clause_scope = self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(clause.meta.span)) orelse clause.meta.scope_id;
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
            self.graph.findModuleScope(module_name)
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
            self.graph.findModuleScope(module_name)
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
            .binding_id = binding_id,
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
                    .binding_id = 0, // No scope graph binding ID — using local index
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
        for (program.modules) |*mod| {
            const mod_scope = self.graph.findModuleScope(mod.name) orelse
                self.graph.prelude_scope;
            self.current_module_scope = mod_scope;
            try modules.append(self.allocator, try self.buildModule(mod, mod_scope));
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

        // Build impl function groups as top-level functions
        for (self.graph.impls.items) |impl_entry| {
            self.current_module_scope = impl_entry.scope_id;
            for (impl_entry.decl.functions) |func| {
                const entry = try fn_groups.getOrPut(func.name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                    try fn_order.append(self.allocator, func.name);
                }
                try entry.value_ptr.append(self.allocator, func);
            }
            // Build each impl function as a top-level function group
            for (impl_entry.decl.functions) |func| {
                if (fn_groups.getPtr(func.name)) |decls| {
                    const group = try self.buildMergedFunctionGroup(decls.items, impl_entry.scope_id);
                    try top_fns.append(self.allocator, group);
                    // Record group ID for ImplInfo
                    decls.clearRetainingCapacity();
                }
            }
            self.current_module_scope = null;
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

    fn buildModule(self: *HirBuilder, mod: *const ast.ModuleDecl, mod_scope: scope_mod.ScopeId) !Module {
        // Group module functions by name
        var fn_order: std.ArrayList(ast.StringId) = .empty;
        var fn_groups = std.AutoHashMap(ast.StringId, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
        defer fn_groups.deinit();

        var type_defs: std.ArrayList(TypeDef) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const entry = try fn_groups.getOrPut(func.name);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .empty;
                        try fn_order.append(self.allocator, func.name);
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
                        .name = sd.name orelse 0,
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
                if (item == .module_level_expr) {
                    try module_exprs.append(self.allocator, item.module_level_expr);
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
                    if (fn_groups.get(rn)) |_| has_run = true;
                    if (!has_run) {
                        // Build AST statements from the module-level expressions
                        var stmts = try self.allocator.alloc(ast.Stmt, module_exprs.items.len);
                        for (module_exprs.items, 0..) |expr, idx| {
                            stmts[idx] = .{ .expr = expr };
                        }

                        // Find StringId for "String" type
                        const string_tid: ast.StringId = st_blk: {
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

                        const entry = try fn_groups.getOrPut(rn);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = .empty;
                            try fn_order.append(self.allocator, rn);
                        }
                        try entry.value_ptr.append(self.allocator, run_decl);
                    }
                }
            }
        }

        // Pre-register all declared function families in family_to_group
        // so that function references like &name/arity can resolve any
        // sibling function regardless of declaration order.
        for (fn_order.items) |name| {
            if (fn_groups.getPtr(name)) |decls| {
                const arity: u32 = if (decls.items[0].clauses.len > 0) @intCast(decls.items[0].clauses[0].params.len) else 0;
                if (self.graph.resolveFamily(mod_scope, decls.items[0].name, arity)) |family_id| {
                    if (!self.family_to_group.contains(family_id)) {
                        const pre_id = self.next_group_id;
                        self.next_group_id += 1;
                        try self.family_to_group.put(family_id, pre_id);
                    }
                }
            }
        }

        var functions: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |name| {
            if (fn_groups.getPtr(name)) |decls| {
                try functions.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, mod_scope));
            }
        }

        // Build inherited functions from scope graph (module extends).
        // Only include families whose clauses come from this module's own AST
        // or from parent scopes (via __using__ injection). Skip families from
        // sibling modules that leak into the scope during merged compilation.
        const mod_scope_data = self.graph.getScope(mod_scope);
        var inherited_iter = mod_scope_data.function_families.iterator();
        while (inherited_iter.next()) |entry| {
            const family_key = entry.key_ptr.*;
            if (fn_groups.contains(family_key.name)) continue;

            const family_id = entry.value_ptr.*;
            const family = self.graph.getFamily(family_id);
            if (family.clauses.items.len == 0) continue;

            // Check if any clause's decl belongs to this module's AST items
            var belongs_to_module = false;
            for (family.clauses.items) |clause_ref| {
                for (mod.items) |item| {
                    const mod_func = switch (item) {
                        .function, .priv_function => |f| f,
                        else => continue,
                    };
                    if (mod_func == clause_ref.decl) {
                        belongs_to_module = true;
                        break;
                    }
                }
                if (belongs_to_module) break;
            }
            if (belongs_to_module) continue; // Already handled via fn_groups

            // Skip function families from other modules. Each module's
            // functions are compiled when that module is processed — including
            // them here pollutes the namespace and causes anytype
            // monomorphization to pick up wrong types from foreign functions.
            continue;
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

    /// Register a function group: assign an ID and populate family_to_group,
    /// but do NOT build clause bodies yet. Returns a skeleton FunctionGroup
    /// with empty clauses that will be filled in by buildGroupClauses.
    fn registerFunctionGroup(
        self: *HirBuilder,
        decls: []const *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
    ) !FunctionGroup {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

        const arity: u32 = if (decls[0].clauses.len > 0) @intCast(decls[0].clauses[0].params.len) else 0;
        if (self.graph.resolveFamily(scope_id, decls[0].name, arity)) |family_id| {
            try self.family_to_group.put(family_id, group_id);
        }

        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = decls[0].name,
            .arity = arity,
            .is_local = false,
            .captures = &.{},
            .clauses = &.{},
            .fallback_parent = null,
        };
    }

    /// Build clause bodies for a function group.
    fn buildGroupClauses(
        self: *HirBuilder,
        decls: []const *const ast.FunctionDecl,
    ) ![]const Clause {
        self.current_function_name = self.interner.get(decls[0].name);
        self.current_function_name_id = decls[0].name;

        var clauses: std.ArrayList(Clause) = .empty;
        for (decls) |func| {
            for (func.clauses) |clause| {
                try clauses.append(self.allocator, try self.buildClause(&clause));
            }
        }
        return try clauses.toOwnedSlice(self.allocator);
    }

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
        self.current_function_root_scope = if (func.clauses.len > 0) self.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(func.clauses[0].meta.span)) orelse func.clauses[0].meta.scope_id else null;
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
        self.current_assignment_bindings = saved_assignment_bindings;
        self.current_tuple_bindings = saved_tuple_bindings;
        self.current_struct_bindings = saved_struct_bindings;
        self.current_list_bindings = saved_list_bindings;
        self.current_cons_tail_bindings = saved_cons_tail_bindings;
        self.current_binary_bindings = saved_binary_bindings;
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
        const prev_clause_scope = self.current_clause_scope;
        // Look up the clause's scope from the node_scope_map using the
        // composite (source_id, span.start) key. This prevents collisions
        // between AST nodes at the same byte offset in different source files.
        self.current_clause_scope = self.graph.node_scope_map.get(
            scope_mod.ScopeGraph.spanKey(clause.meta.span),
        ) orelse self.current_module_scope orelse clause.meta.scope_id;
        defer self.current_clause_scope = prev_clause_scope;

        // Check for inferred signature from the type checker (populated for
        // generated helpers like __for_N from call-site argument types).
        const inferred_sig = if (self.current_function_name_id) |name_id|
            self.type_store.inferred_signatures.get(name_id)
        else
            null;

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
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
        else if (inferred_sig) |sig|
            sig.return_type
        else
            types_mod.TypeStore.NEVER;

        // Track param names for var_ref resolution
        var param_names: std.ArrayList(?ast.StringId) = .empty;
        for (params.items) |p| {
            try param_names.append(self.allocator, p.name);
        }
        self.current_param_names = try param_names.toOwnedSlice(self.allocator);

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
                                // Skip _-prefixed bindings (intentionally unused)
                                const name_str = self.interner.get(sub_pat.bind);
                                if (name_str.len > 0 and name_str[0] == '_') continue;
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
        const refinement_expr = if (clause.refinement) |ref| try self.buildExpr(ref) else null;

        // Build body block (empty for @native bodyless declarations)
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

    fn compilePattern(self: *HirBuilder, pattern: *const ast.Pattern) anyerror!?*const MatchPattern {
        return switch (pattern.*) {
            .wildcard => try self.create(MatchPattern, .wildcard),
            .bind => |b| try self.create(MatchPattern, .{ .bind = b.name }),
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
                    const idx = self.next_local;
                    self.next_local += 1;
                    if (assign.pattern.* == .bind) {
                        try self.current_assignment_bindings.append(self.allocator, .{
                            .name = assign.pattern.bind.name,
                            .local_index = idx,
                            .type_id = value.type_id,
                        });
                    }
                    try hir_stmts.append(self.allocator, .{
                        .local_set = .{ .index = idx, .value = value },
                    });
                },
                .function_decl => {},
                else => {},
            }
        }

        return try self.create(Block, .{
            .stmts = try hir_stmts.toOwnedSlice(self.allocator),
            .result_type = types_mod.TypeStore.UNKNOWN,
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
                return try self.create(Expr, .{
                    .kind = .{ .local_get = 0 }, // TODO: resolve to local index
                    .type_id = resolved_type,
                    .span = v.meta.span,
                });
            },
            .binary_op => |bo| {
                const lhs_expr = try self.buildExpr(bo.lhs);
                const rhs_expr = try self.buildExpr(bo.rhs);
                // Derive result type from operands and operator
                const result_type = switch (bo.op) {
                    // Arithmetic: same type as operands
                    .add, .sub, .mul, .div, .rem_op => blk: {
                        if (lhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk lhs_expr.type_id;
                        if (rhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk rhs_expr.type_id;
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    // Comparison/logical: Bool
                    .equal, .not_equal, .less, .greater, .less_equal, .greater_equal, .and_op, .or_op => types_mod.TypeStore.BOOL,
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
                        // Check if the target is a protocol — direct calls on
                        // protocols are not allowed. Protocols define interfaces;
                        // use the implementing module (e.g., Enum) instead.
                        if (self.graph.findProtocol(fa.object.module_ref.name)) |_| {
                            const protocol_name = self.moduleNameToString(fa.object.module_ref.name);
                            const func_name = self.interner.get(fa.field);
                            const msg = std.fmt.allocPrint(self.allocator,
                                "cannot call '{s}.{s}()' — '{s}' is a protocol, not a module. " ++
                                "Protocol functions are dispatched through implementing modules.",
                                .{ protocol_name, func_name, protocol_name },
                            ) catch "cannot call functions directly on a protocol";
                            try self.errors.append(self.allocator, .{
                                .message = msg,
                                .span = call.meta.span,
                            });
                            return error.CompileError;
                        }
                        const func_name = self.interner.get(fa.field);
                        const mod_name = self.moduleNameToString(fa.object.module_ref.name);
                        // Module-qualified call — @native resolution happens at IR level
                        break :blk .{ .named = .{ .module = mod_name, .name = func_name } };
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
                                // Build "Module.function" qualified name
                                const mod_part = self.interner.get(inner.field);
                                const func_part = self.interner.get(fa.field);
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
                            break :blk self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    .named => |n| blk: {
                        if (n.module == null) {
                            if (call.callee.* == .var_ref) {
                                break :blk self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
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
                    // Save binding state for this arm
                    const saved_case_bindings = self.current_case_bindings;
                    self.current_case_bindings = .empty;

                    const pattern = try self.compilePattern(clause.pattern);

                    // Process bindings from the pattern
                    if (pattern) |pat| {
                        switch (pat.*) {
                            .bind => |name| {
                                const local_idx = self.next_local;
                                self.next_local += 1;
                                try self.current_case_bindings.append(self.allocator, .{
                                    .name = name,
                                    .local_index = local_idx,
                                    .kind = .scrutinee,
                                    .element_index = 0,
                                });
                            },
                            .tuple => |sub_pats| {
                                try self.collectTuplePatternBindings(sub_pats);
                            },
                            .binary_match => |bm| {
                                for (bm.segments, 0..) |seg, seg_idx| {
                                    if (seg.pattern) |sub_pat| {
                                        if (sub_pat.* == .bind) {
                                            // Skip _-prefixed bindings (intentionally unused)
                                            const name_str = self.interner.get(sub_pat.bind);
                                            if (name_str.len > 0 and name_str[0] == '_') continue;
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
                                }
                            },
                            else => {},
                        }
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

                    // Restore binding state
                    self.current_case_bindings = saved_case_bindings;
                }

                return try self.create(Expr, .{
                    .kind = .{ .case = .{
                        .scrutinee = scrutinee,
                        .arms = try arms.toOwnedSlice(self.allocator),
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
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
                return try self.create(Expr, .{
                    .kind = .{ .tuple_init = try elems.toOwnedSlice(self.allocator) },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = t.meta.span,
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (l.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                const built_elems = try elems.toOwnedSlice(self.allocator);
                // Infer list type from elements — use first element with known type
                const list_type_id = if (built_elems.len > 0) blk: {
                    for (built_elems) |elem| {
                        if (elem.type_id != types_mod.TypeStore.UNKNOWN) {
                            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                            break :blk store_ptr.addType(.{ .list = .{ .element = elem.type_id } }) catch types_mod.TypeStore.UNKNOWN;
                        }
                    }
                    // All elements UNKNOWN — check element kinds for type inference
                    // String literals that went through CtValue round-trip may be
                    // encoded as call expressions to the string interpolation form.
                    // Check if elements are string_lit directly.
                    for (built_elems) |elem| {
                        if (elem.kind == .string_lit) {
                            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                            break :blk store_ptr.addType(.{ .list = .{ .element = types_mod.TypeStore.STRING } }) catch types_mod.TypeStore.UNKNOWN;
                        }
                    }
                    break :blk types_mod.TypeStore.UNKNOWN;
                } else types_mod.TypeStore.UNKNOWN;
                return try self.create(Expr, .{
                    .kind = .{ .list_init = built_elems },
                    .type_id = list_type_id,
                    .span = l.meta.span,
                });
            },
            .list_cons_expr => |lce| {
                return try self.create(Expr, .{
                    .kind = .{ .list_cons = .{
                        .head = try self.buildExpr(lce.head),
                        .tail = try self.buildExpr(lce.tail),
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
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
                // Infer map type from first entry's key and value types
                const map_type_id = if (built_entries.len > 0) blk: {
                    const key_type = built_entries[0].key.type_id;
                    const val_type = built_entries[0].value.type_id;
                    if (key_type != types_mod.TypeStore.UNKNOWN and val_type != types_mod.TypeStore.UNKNOWN) {
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
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
            .struct_expr => |se| {
                // Resolve struct type from module name (e.g., %{name: "Alice"} :: User)
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
                    const mod_name = self.moduleNameToString(fa.object.module_ref.name);

                    // Check if this is an enum variant access (e.g. Color.Red)
                    const mod_parts = fa.object.module_ref.name.parts;
                    if (mod_parts.len == 1) {
                        if (self.type_store.name_to_type.get(mod_parts[0])) |tid| {
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
                // Check for enum variant reference (e.g., Color.Red parsed as module_ref ["Color", "Red"])
                if (mr.name.parts.len == 2) {
                    if (self.type_store.name_to_type.get(mr.name.parts[0])) |tid| {
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
                                        .field = mr.name.parts[1],
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
        const handler_expr = try self.buildErrorHandlerExpr(ep.handler, ep.meta);

        // Result type is the last step's type (the catch basin handler
        // must return the same type for the expression to be well-typed).
        const result_type = if (hir_steps.items.len > 0)
            hir_steps.items[hir_steps.items.len - 1].expr.type_id
        else
            types_mod.TypeStore.UNKNOWN;

        return try self.create(Expr, .{
            .kind = .{ .error_pipe = .{
                .steps = try hir_steps.toOwnedSlice(self.allocator),
                .handler = handler_expr,
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

    /// Build an error handler HIR expression from an AST ErrorHandler.
    fn buildErrorHandlerExpr(self: *HirBuilder, handler: ast.ErrorHandler, meta: ast.NodeMeta) !*const Expr {
        switch (handler) {
            .block => |clauses| {
                // Build a case expression: case __err { pattern -> body, ... }
                // The scrutinee will be substituted by the IR builder
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                const err_name = interner_mut.intern("__err") catch unreachable;
                const scrutinee = try self.create(Expr, .{
                    .kind = .{ .local_get = 0 }, // placeholder, will be substituted
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
                _ = scrutinee;
                _ = err_name;

                // For now, build the handler bodies directly
                // The block handler has case clauses; build the first body as fallback
                if (clauses.len > 0) {
                    const first_body = try self.buildBlock(clauses[0].body);
                    if (first_body.stmts.len > 0) {
                        const last = first_body.stmts[first_body.stmts.len - 1];
                        if (last == .expr) return last.expr;
                    }
                }
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
            },
            .function => |func| {
                return try self.buildExpr(func);
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
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
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
                return self.moduleNameToString(imp.source_module);
            }
        }

        return null;
    }

    /// Check if a function (resolved by family ID) has a @native attribute.
    /// Returns the native binding string (e.g., "ZestRuntime.fail") if found, null otherwise.
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
    fn sourceModuleHasFunction(self: *const HirBuilder, mod_name: ast.ModuleName, name: ast.StringId, arity: u32) bool {
        // Find the module in the scope graph
        for (self.graph.modules.items) |mod_entry| {
            if (self.moduleNamesEqual(mod_entry.name, mod_name)) {
                const mod_scope = self.graph.getScope(mod_entry.scope_id);
                const key = scope_mod.FamilyKey{ .name = name, .arity = arity };
                return mod_scope.function_families.get(key) != null;
            }
        }
        return false;
    }

    /// Compare two ModuleNames for equality (all parts must match).
    fn moduleNamesEqual(_: *const HirBuilder, a: ast.ModuleName, b: ast.ModuleName) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |pa, pb| {
            if (pa != pb) return false;
        }
        return true;
    }

    fn moduleNameToString(self: *const HirBuilder, name: ast.ModuleName) []const u8 {
        // For single-part module names like "IO", just return the part
        if (name.parts.len == 1) {
            return self.interner.get(name.parts[0]);
        }
        // For multi-part names like "IO.File", join with "_"
        var buf: std.ArrayList(u8) = .empty;
        for (name.parts, 0..) |part, i| {
            if (i > 0) buf.appendSlice(self.allocator, "_") catch return self.interner.get(name.parts[0]);
            buf.appendSlice(self.allocator, self.interner.get(part)) catch return self.interner.get(name.parts[0]);
        }
        return buf.toOwnedSlice(self.allocator) catch return self.interner.get(name.parts[0]);
    }

    /// Recursively collect bindings from tuple sub-patterns (including nested tuples).
    fn collectTuplePatternBindings(self: *HirBuilder, sub_pats: []const *const MatchPattern) !void {
        for (sub_pats, 0..) |sub_pat, elem_idx| {
            switch (sub_pat.*) {
                .bind => |name| {
                    const local_idx = self.next_local;
                    self.next_local += 1;
                    try self.current_case_bindings.append(self.allocator, .{
                        .name = name,
                        .local_index = local_idx,
                        .kind = .tuple_element,
                        .element_index = @intCast(elem_idx),
                    });
                },
                .tuple => |nested_pats| {
                    // Recurse into nested tuples
                    try self.collectTuplePatternBindings(nested_pats);
                },
                else => {},
            }
        }
    }

    fn create(self: *HirBuilder, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }
};

// Standard library resolution removed — IO, Kernel, etc. are now
// real Zap modules defined in lib/ and compiled with the program.

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "HIR build simple function" {
    const source =
        \\pub module Test {
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
        \\pub module Math {
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
        \\pub module Test {
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
        \\pub module Test {
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
        \\pub module Test {
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
        \\pub module Test {
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
        \\pub module Test {
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
        \\pub module Test {
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

    const apply_clause = program.modules[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
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
        \\pub module Test {
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
        \\pub module Test {
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

    const apply_clause = program.modules[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
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
        \\pub module Test {
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
