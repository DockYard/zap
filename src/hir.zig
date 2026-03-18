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

// ============================================================
// HIR Program
// ============================================================

pub const Program = struct {
    modules: []const Module,
    top_functions: []const FunctionGroup,
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
    clauses: []const Clause,
    fallback_parent: ?u32, // ID of the outer scope's function group
};

pub const Clause = struct {
    params: []const TypedParam,
    return_type: TypeId,
    decision: *const Decision, // compiled match decision
    body: *const Block,
    refinement: ?*const Expr,
    tuple_bindings: []const TupleBinding,
    struct_bindings: []const StructBinding = &.{},
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

pub const TypedParam = struct {
    name: ?ast.StringId,
    type_id: TypeId,
    pattern: ?*const MatchPattern,
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

    // Compound
    tuple_init: []const *const Expr,
    list_init: []const *const Expr,
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

    // Special
    closure_create: ClosureCreate,
    never,
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
    args: []const *const Expr,
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
    captures: []const u32, // local variable indices
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
    pin: ast.StringId,
    struct_match: StructMatch,
};

pub const StructMatch = struct {
    type_name: ast.StringId,
    field_bindings: []const StructFieldBind,
};

pub const StructFieldBind = struct {
    field_name: ast.StringId,
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
        d.* = .{ .bind = .{
            .name = first_pat.?.bind,
            .local_index = 0, // resolved during IR lowering
            .source = scrutinee_expr,
            .next = sub_decision,
        } };
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

        // Build new scrutinee IDs for this arity's elements
        var new_scrutinee_list: std.ArrayList(u32) = .empty;
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
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
            .success = success_decision,
            .failure = current_failure,
        } };
        current_failure = d;
    }

    return current_failure;
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
    type_store: *const types_mod.TypeStore,
    next_group_id: u32,
    next_local: u32,
    current_param_names: []const ?ast.StringId,
    current_tuple_bindings: std.ArrayList(TupleBinding),
    current_struct_bindings: std.ArrayList(StructBinding),
    current_case_bindings: std.ArrayList(CaseBinding),
    current_module_scope: ?scope_mod.ScopeId,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        interner: *const ast.StringInterner,
        graph: *const scope_mod.ScopeGraph,
        type_store: *const types_mod.TypeStore,
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
            .current_case_bindings = .empty,
            .current_module_scope = null,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *HirBuilder) void {
        self.errors.deinit(self.allocator);
    }

    /// Look up a binding's type_id from the scope graph.
    /// Returns the type_id if found, otherwise UNKNOWN.
    fn resolveBindingType(self: *const HirBuilder, name: ast.StringId) types_mod.TypeId {
        const scope_id = self.current_module_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveBinding(scope_id, name)) |bid| {
            const binding = self.graph.bindings.items[bid];
            if (binding.type_id) |prov| {
                return prov.type_id;
            }
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Look up a function's declared return type from the scope graph.
    /// Searches current module scope, then prelude.
    fn resolveFunctionReturnType(self: *const HirBuilder, name: ast.StringId, arity: u32) types_mod.TypeId {
        const scope_id = self.current_module_scope orelse self.graph.prelude_scope;
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

    // ============================================================
    // Program lowering
    // ============================================================

    pub fn buildProgram(self: *HirBuilder, program: *const ast.Program) !Program {
        var modules: std.ArrayList(Module) = .empty;
        for (program.modules, 0..) |*mod, i| {
            const mod_scope = if (i < self.graph.modules.items.len)
                self.graph.modules.items[i].scope_id
            else
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

        return .{
            .modules = try modules.toOwnedSlice(self.allocator),
            .top_functions = try top_fns.toOwnedSlice(self.allocator),
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
                .enum_decl => |ed| {
                    try type_defs.append(self.allocator, .{
                        .name = ed.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .alias, // enums are emitted directly as type defs
                    });
                },
                else => {},
            }
        }

        var functions: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |name| {
            if (fn_groups.getPtr(name)) |decls| {
                try functions.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, mod_scope));
            }
        }

        // Build inherited functions from scope graph (module extends)
        // These are families in the module scope that weren't in the AST items
        const mod_scope_data = self.graph.getScope(mod_scope);
        var inherited_iter = mod_scope_data.function_families.iterator();
        while (inherited_iter.next()) |entry| {
            const family_key = entry.key_ptr.*;
            // Skip if already built from AST items
            if (fn_groups.contains(family_key.name)) continue;

            const family_id = entry.value_ptr.*;
            const family = self.graph.getFamily(family_id);
            if (family.clauses.items.len == 0) continue;

            // Build from the family's clause references (these point to parent's AST decls)
            var decl_list: std.ArrayList(*const ast.FunctionDecl) = .empty;
            for (family.clauses.items) |clause_ref| {
                try decl_list.append(self.allocator, clause_ref.decl);
            }
            if (decl_list.items.len > 0) {
                try functions.append(self.allocator, try self.buildMergedFunctionGroup(decl_list.items, mod_scope));
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
        const group_id = self.next_group_id;
        self.next_group_id += 1;

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
            .arity = if (first.clauses.len > 0) @intCast(first.clauses[0].params.len) else 0,
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = null,
        };
    }

    fn buildFunctionGroup(
        self: *HirBuilder,
        func: *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
        fallback_parent: ?u32,
    ) !FunctionGroup {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

        var clauses: std.ArrayList(Clause) = .empty;
        for (func.clauses) |clause| {
            try clauses.append(self.allocator, try self.buildClause(&clause));
        }

        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = func.name,
            .arity = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0,
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = fallback_parent,
        };
    }

    fn buildClause(self: *HirBuilder, clause: *const ast.FunctionClause) !Clause {
        self.next_local = 0;

        var params: std.ArrayList(TypedParam) = .empty;
        for (clause.params) |param| {
            const type_id = if (param.type_annotation) |ann|
                self.resolveTypeExpr(ann)
            else
                types_mod.TypeStore.UNKNOWN;

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
            try params.append(self.allocator, .{
                .name = name,
                .type_id = type_id,
                .pattern = match_pattern,
            });
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
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

        // Build decision tree for this clause
        const decision = try self.create(Decision, .{
            .success = .{ .bindings = &.{}, .body_index = 0 },
        });

        // Build refinement expression (guard predicate)
        const refinement_expr = if (clause.refinement) |ref| try self.buildExpr(ref) else null;

        // Build body block
        const body = try self.buildBlock(clause.body);

        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .decision = decision,
            .body = body,
            .refinement = refinement_expr,
            .tuple_bindings = try self.current_tuple_bindings.toOwnedSlice(self.allocator),
            .struct_bindings = try self.current_struct_bindings.toOwnedSlice(self.allocator),
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
            .map => null, // TODO
        };
    }

    // ============================================================
    // Block building
    // ============================================================

    fn buildBlock(self: *HirBuilder, stmts: []const ast.Stmt) anyerror!*const Block {
        var hir_stmts: std.ArrayList(Stmt) = .empty;

        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const hir_expr = try self.buildExpr(expr);
                    try hir_stmts.append(self.allocator, .{ .expr = hir_expr });
                },
                .assignment => |assign| {
                    const value = try self.buildExpr(assign.value);
                    const idx = self.next_local;
                    self.next_local += 1;
                    try hir_stmts.append(self.allocator, .{
                        .local_set = .{ .index = idx, .value = value },
                    });
                },
                .function_decl => |func| {
                    const group = try self.buildFunctionGroup(func, self.graph.prelude_scope, null);
                    const group_ptr = try self.create(FunctionGroup, group);
                    try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                },
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
                // Try to resolve type from scope graph binding
                const resolved_type = self.resolveBindingType(v.name);

                // Check if this var refers to a parameter
                for (self.current_param_names, 0..) |param_name, idx| {
                    if (param_name) |pn| {
                        if (pn == v.name) {
                            return try self.create(Expr, .{
                                .kind = .{ .param_get = @intCast(idx) },
                                .type_id = resolved_type,
                                .span = v.meta.span,
                            });
                        }
                    }
                }
                // Check if this var refers to a tuple binding (destructured variable)
                for (self.current_tuple_bindings.items) |binding| {
                    if (binding.name == v.name) {
                        return try self.create(Expr, .{
                            .kind = .{ .local_get = binding.local_index },
                            .type_id = resolved_type,
                            .span = v.meta.span,
                        });
                    }
                }
                // Check if this var refers to a struct field binding
                for (self.current_struct_bindings.items) |binding| {
                    if (binding.name == v.name) {
                        return try self.create(Expr, .{
                            .kind = .{ .local_get = binding.local_index },
                            .type_id = resolved_type,
                            .span = v.meta.span,
                        });
                    }
                }
                // Check if this var refers to a case binding
                for (self.current_case_bindings.items) |binding| {
                    if (binding.name == v.name) {
                        return try self.create(Expr, .{
                            .kind = .{ .local_get = binding.local_index },
                            .type_id = resolved_type,
                            .span = v.meta.span,
                        });
                    }
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
                var args: std.ArrayList(*const Expr) = .empty;
                for (call.args) |arg| {
                    try args.append(self.allocator, try self.buildExpr(arg));
                }

                // Check for module-qualified call: IO.puts(...), Math.square(...)
                // or :zig runtime bridge: :zig.println(...)
                const target: CallTarget = if (call.callee.* == .field_access) blk: {
                    const fa = call.callee.field_access;
                    if (fa.object.* == .module_ref) {
                        const func_name = self.interner.get(fa.field);
                        const mod_name = self.moduleNameToString(fa.object.module_ref.name);
                        // Module-qualified call — preserve module name
                        break :blk .{ .named = .{ .module = mod_name, .name = func_name } };
                    }
                    // :zig.function() — bridge to Zig runtime
                    if (fa.object.* == .atom_literal) {
                        const atom_name = self.interner.get(fa.object.atom_literal.value);
                        if (std.mem.eql(u8, atom_name, "zig")) {
                            const func_name = self.interner.get(fa.field);
                            break :blk .{ .builtin = func_name };
                        }
                    }
                    break :blk .{ .closure = try self.buildExpr(call.callee) };
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
                        break :blk .{ .closure = try self.buildExpr(call.callee) };
                    }
                    // Check if this bare call resolves to an imported function
                    const import_module = self.resolveImport(vr.name, @intCast(call.args.len));
                    break :blk .{ .named = .{ .module = import_module, .name = self.interner.get(vr.name) } };
                } else .{ .closure = try self.buildExpr(call.callee) };

                // Resolve return type for named calls
                const call_return_type: types_mod.TypeId = switch (target) {
                    .named => |n| blk: {
                        // For bare calls (no module prefix), look up in scope graph
                        if (n.module == null) {
                            if (call.callee.* == .var_ref) {
                                break :blk self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                            }
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    else => types_mod.TypeStore.UNKNOWN,
                };

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
                return try self.create(Expr, .{
                    .kind = .{ .list_init = try elems.toOwnedSlice(self.allocator) },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = l.meta.span,
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
                            if (typ == .enum_type) {
                                return try self.create(Expr, .{
                                    .kind = .{ .field_get = .{
                                        .object = try self.create(Expr, .{
                                            .kind = .nil_lit, // placeholder for enum type ref
                                            .type_id = tid,
                                            .span = fa.object.getMeta().span,
                                        }),
                                        .field = fa.field,
                                    } },
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
            .module_ref => |mr| {
                // Check for enum variant reference (e.g., Color.Red parsed as module_ref ["Color", "Red"])
                if (mr.name.parts.len == 2) {
                    if (self.type_store.name_to_type.get(mr.name.parts[0])) |tid| {
                        const typ = self.type_store.getType(tid);
                        if (typ == .enum_type) {
                            return try self.create(Expr, .{
                                .kind = .{ .field_get = .{
                                    .object = try self.create(Expr, .{
                                        .kind = .nil_lit, // placeholder for enum type ref
                                        .type_id = tid,
                                        .span = mr.meta.span,
                                    }),
                                    .field = mr.name.parts[1],
                                } },
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
                // Resolve each member type, then find matching union in the TypeStore
                // (the TypeChecker already created this union type during its pass)
                var member_types: std.ArrayList(TypeId) = .empty;
                for (ut.members) |member| {
                    member_types.append(self.allocator, self.resolveTypeExpr(member)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const members = member_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                // Search the TypeStore for a matching union type
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
        \\def add(x :: i64, y :: i64) :: i64 do
        \\  x + y
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

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.top_functions.len);
    try std.testing.expectEqual(@as(u32, 2), hir_program.top_functions[0].arity);
}

test "HIR build module" {
    const source =
        \\defmodule Math do
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

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.modules.len);
    try std.testing.expectEqual(@as(usize, 1), hir_program.modules[0].functions.len);
}

test "HIR pattern compilation" {
    const source =
        \\def foo(x) do
        \\  case x do
        \\    {:ok, v} ->
        \\      v
        \\    {:error, e} ->
        \\      e
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

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    // Should have built the function with case expression
    try std.testing.expectEqual(@as(usize, 1), hir_program.top_functions.len);
    try std.testing.expectEqual(@as(usize, 0), builder.errors.items.len);
}
