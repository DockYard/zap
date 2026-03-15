const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");

// ============================================================
// Zig-shaped IR (spec §19)
//
// A low-level IR that sits between typed HIR and Zig emission.
// Represents explicit control flow, locals, calls, closures,
// and ARC operations.
// ============================================================

pub const FunctionId = u32;
pub const BlockId = u32;
pub const LocalId = u32;
pub const LabelId = u32;

// ============================================================
// IR Program
// ============================================================

pub const Program = struct {
    functions: []const Function,
    entry: ?FunctionId,
};

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    params: []const Param,
    return_type: ZigType,
    body: []const Block,
    is_closure: bool,
    captures: []const Capture,
};

pub const Param = struct {
    name: []const u8,
    type_expr: ZigType,
};

pub const Capture = struct {
    name: []const u8,
    type_expr: ZigType,
};

pub const Block = struct {
    label: LabelId,
    instructions: []const Instruction,
};

// ============================================================
// Instructions (spec §19.2)
// ============================================================

pub const Instruction = union(enum) {
    // Constants
    const_int: ConstInt,
    const_float: ConstFloat,
    const_string: ConstString,
    const_bool: ConstBool,
    const_atom: ConstAtom,
    const_nil: LocalId,

    // Locals
    local_get: LocalGet,
    local_set: LocalSet,
    param_get: ParamGet,

    // Aggregates
    tuple_init: AggregateInit,
    list_init: AggregateInit,
    map_init: MapInit,
    struct_init: StructInit,
    field_get: FieldGet,
    field_set: FieldSet,
    index_get: IndexGet,

    // Arithmetic / logic
    binary_op: BinaryOp,
    unary_op: UnaryOp,

    // Calls
    call_direct: CallDirect,
    call_named: CallNamed,
    call_closure: CallClosure,
    call_dispatch: CallDispatch,
    call_builtin: CallBuiltin,

    // Control flow
    if_expr: IfExpr,
    guard_block: GuardBlock,
    case_block: CaseBlock,
    branch: Branch,
    cond_branch: CondBranch,
    switch_tag: SwitchTag,
    switch_literal: SwitchLiteral,
    switch_return: SwitchReturn,
    match_atom: MatchAtom,
    match_int: MatchInt,
    match_float: MatchFloat,
    match_string: MatchString,
    match_type: MatchType,
    match_fail: MatchFail,
    ret: Return,
    cond_return: CondReturn,
    case_break: CaseBreak,
    jump: Jump,

    // Closures
    make_closure: MakeClosure,
    capture_get: CaptureGet,

    // Memory / ARC
    alloc_owned: AllocOwned,
    retain: Retain,
    release: Release,

    // Phi
    phi: Phi,
};

pub const ConstInt = struct {
    dest: LocalId,
    value: i64,
};

pub const ConstFloat = struct {
    dest: LocalId,
    value: f64,
};

pub const ConstString = struct {
    dest: LocalId,
    value: []const u8,
};

pub const ConstBool = struct {
    dest: LocalId,
    value: bool,
};

pub const ConstAtom = struct {
    dest: LocalId,
    value: []const u8,
};

pub const LocalGet = struct {
    dest: LocalId,
    source: LocalId,
};

pub const LocalSet = struct {
    dest: LocalId,
    value: LocalId,
};

pub const ParamGet = struct {
    dest: LocalId,
    index: u32,
};

pub const AggregateInit = struct {
    dest: LocalId,
    elements: []const LocalId,
};

pub const MapInit = struct {
    dest: LocalId,
    entries: []const MapEntry,
};

pub const MapEntry = struct {
    key: LocalId,
    value: LocalId,
};

pub const StructInit = struct {
    dest: LocalId,
    type_name: []const u8,
    fields: []const StructFieldInit,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: LocalId,
};

pub const FieldGet = struct {
    dest: LocalId,
    object: LocalId,
    field: []const u8,
};

pub const FieldSet = struct {
    object: LocalId,
    field: []const u8,
    value: LocalId,
};

pub const IndexGet = struct {
    dest: LocalId,
    object: LocalId,
    index: u32,
};

pub const GuardBlock = struct {
    condition: LocalId,
    body: []const Instruction,
};

pub const CaseBreak = struct {
    value: ?LocalId,
};

pub const CaseBlock = struct {
    dest: LocalId,
    pre_instrs: []const Instruction, // tuple arm guards (emit before regular arms)
    arms: []const IrCaseArm,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const IrCaseArm = struct {
    cond_instrs: []const Instruction,
    condition: LocalId,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

pub const IfExpr = struct {
    dest: LocalId,
    condition: LocalId,
    then_instrs: []const Instruction,
    then_result: ?LocalId,
    else_instrs: []const Instruction,
    else_result: ?LocalId,
};

pub const BinaryOp = struct {
    dest: LocalId,
    op: Op,
    lhs: LocalId,
    rhs: LocalId,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        rem_op,
        eq,
        neq,
        lt,
        gt,
        lte,
        gte,
        bool_and,
        bool_or,
        concat,
    };
};

pub const UnaryOp = struct {
    dest: LocalId,
    op: Op,
    operand: LocalId,

    pub const Op = enum {
        negate,
        bool_not,
    };
};

pub const CallDirect = struct {
    dest: LocalId,
    function: FunctionId,
    args: []const LocalId,
};

pub const CallNamed = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
};

pub const CallClosure = struct {
    dest: LocalId,
    callee: LocalId,
    args: []const LocalId,
};

pub const CallDispatch = struct {
    dest: LocalId,
    group_id: u32,
    args: []const LocalId,
};

pub const CallBuiltin = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
};

pub const Branch = struct {
    target: LabelId,
};

pub const CondBranch = struct {
    condition: LocalId,
    then_target: LabelId,
    else_target: LabelId,
};

pub const SwitchTag = struct {
    scrutinee: LocalId,
    cases: []const TagCase,
    default: LabelId,
};

pub const TagCase = struct {
    tag: []const u8,
    target: LabelId,
};

pub const SwitchLiteral = struct {
    dest: LocalId,
    scrutinee: LocalId,
    cases: []const LitCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const LitCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

pub const SwitchReturn = struct {
    scrutinee_param: u32,
    cases: []const ReturnCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const ReturnCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    return_value: ?LocalId,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
};

pub const MatchAtom = struct {
    dest: LocalId,
    scrutinee: LocalId,
    atom_name: []const u8,
    skip_type_check: bool = false,
};

pub const MatchInt = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: i64,
    skip_type_check: bool = false,
};

pub const MatchFloat = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: f64,
    skip_type_check: bool = false,
};

pub const MatchString = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected: []const u8,
    skip_type_check: bool = false,
};

pub const MatchType = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_type: ZigType,
    skip_type_check: bool = false,
};

pub const MatchFail = struct {
    message: []const u8,
};

pub const Return = struct {
    value: ?LocalId,
};

pub const CondReturn = struct {
    condition: LocalId,
    value: ?LocalId,
};

pub const Jump = struct {
    target: LabelId,
};

pub const MakeClosure = struct {
    dest: LocalId,
    function: FunctionId,
    captures: []const LocalId,
};

pub const CaptureGet = struct {
    dest: LocalId,
    index: u32,
};

pub const AllocOwned = struct {
    dest: LocalId,
    type_name: []const u8,
};

pub const Retain = struct {
    value: LocalId,
};

pub const Release = struct {
    value: LocalId,
};

pub const Phi = struct {
    dest: LocalId,
    sources: []const PhiSource,
};

pub const PhiSource = struct {
    from_block: LabelId,
    value: LocalId,
};

// ============================================================
// Zig types (for codegen)
// ============================================================

pub const ZigType = union(enum) {
    void,
    bool_type,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f16,
    f32,
    f64,
    usize,
    isize,
    string, // []const u8
    atom, // enum literal or interned string
    nil, // void or optional
    tuple: []const ZigType,
    list: *const ZigType,
    map: MapType,
    struct_ref: []const u8,
    function: FnType,
    tagged_union: []const u8,
    optional: *const ZigType,
    ptr: *const ZigType,
    any, // for generics

    pub const MapType = struct {
        key: *const ZigType,
        value: *const ZigType,
    };

    pub const FnType = struct {
        params: []const ZigType,
        return_type: *const ZigType,
    };
};

// ============================================================
// IR Builder — lowers HIR to IR
// ============================================================

pub const IrBuilder = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(Function),
    next_function_id: FunctionId,
    next_local: LocalId,
    next_label: LabelId,
    current_blocks: std.ArrayList(Block),
    current_instrs: std.ArrayList(Instruction),
    interner: *const ast.StringInterner,
    known_local_types: std.AutoHashMap(LocalId, ZigType),

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) IrBuilder {
        return .{
            .allocator = allocator,
            .functions = .empty,
            .next_function_id = 0,
            .next_local = 0,
            .next_label = 0,
            .current_blocks = .empty,
            .current_instrs = .empty,
            .interner = interner,
            .known_local_types = std.AutoHashMap(LocalId, ZigType).init(allocator),
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        self.functions.deinit(self.allocator);
        self.current_blocks.deinit(self.allocator);
        self.current_instrs.deinit(self.allocator);
        self.known_local_types.deinit();
    }

    pub fn buildProgram(self: *IrBuilder, hir_program: *const hir_mod.Program) !Program {
        for (hir_program.modules) |mod| {
            for (mod.functions) |func_group| {
                try self.buildFunctionGroup(&func_group);
            }
        }
        for (hir_program.top_functions) |func_group| {
            try self.buildFunctionGroup(&func_group);
        }

        return .{
            .functions = try self.functions.toOwnedSlice(self.allocator),
            .entry = null,
        };
    }

    fn buildFunctionGroup(self: *IrBuilder, group: *const hir_mod.FunctionGroup) !void {
        if (group.clauses.len == 0) return;

        const func_id = self.next_function_id;
        self.next_function_id += 1;
        self.next_local = 0;
        self.next_label = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();

        // Use first clause for arity and return type
        const first_clause = &group.clauses[0];

        // Build params with generic names (__arg_N).
        // If all clauses agree on a param's type, use that type.
        // If any clause differs (or is untyped), fall back to anytype.
        var params: std.ArrayList(Param) = .empty;
        for (first_clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            var resolved_type = typeIdToZigType(param.type_id);
            if (group.clauses.len > 1) {
                for (group.clauses[1..]) |clause| {
                    if (i < clause.params.len) {
                        const other_type = typeIdToZigType(clause.params[i].type_id);
                        if (std.meta.activeTag(other_type) != std.meta.activeTag(resolved_type)) {
                            resolved_type = .any;
                            break;
                        }
                    }
                }
            }
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = resolved_type,
            });
        }

        // Reserve local indices used by tuple bindings across all clauses.
        // These locals are defined inside guard_blocks (separate Zig scopes),
        // so top-level code must start allocating ABOVE this range.
        {
            var max_binding_local: u32 = 0;
            for (group.clauses) |clause| {
                for (clause.tuple_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
            }
            self.next_local = max_binding_local;
        }

        if (group.clauses.len == 1) {
            // Single clause — no dispatch needed
            // Emit tuple bindings if present
            try self.emitTupleBindings(first_clause);
            const result_local = try self.lowerBlock(first_clause.body);
            try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
        } else if (self.canSwitchDispatch(group)) |switch_param| {
            // Emit switch_return for integer literal dispatch
            var return_cases: std.ArrayList(ReturnCase) = .empty;
            var default_instrs_result: []const Instruction = &.{};
            var default_result: ?LocalId = null;

            for (group.clauses, 0..) |clause, clause_idx| {
                const is_last = clause_idx == group.clauses.len - 1;

                if (is_last) {
                    // Default clause — lower body into default_instrs
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.emitTupleBindings(&clause);
                    const result_local = try self.lowerBlock(clause.body);
                    default_instrs_result = try self.current_instrs.toOwnedSlice(self.allocator);
                    default_result = result_local;
                    self.current_instrs = saved;
                } else {
                    // Literal case
                    const pat = clause.params[switch_param].pattern.?;
                    const lit_value: LiteralValue = switch (pat.literal) {
                        .int => |v| .{ .int = v },
                        else => unreachable,
                    };

                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    const body_result = try self.lowerBlock(clause.body);
                    const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try return_cases.append(self.allocator, .{
                        .value = lit_value,
                        .body_instrs = body_instrs,
                        .return_value = body_result,
                    });
                }
            }

            try self.current_instrs.append(self.allocator, .{
                .switch_return = .{
                    .scrutinee_param = switch_param,
                    .cases = try return_cases.toOwnedSlice(self.allocator),
                    .default_instrs = default_instrs_result,
                    .default_result = default_result,
                },
            });
        } else {
            // General multi-clause dispatch via decision tree
            // Build PatternMatrix from clause params
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (group.clauses, 0..) |clause, clause_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                for (clause.params) |param| {
                    try pats.append(self.allocator, param.pattern);
                }
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(clause_idx),
                    .guard = clause.refinement,
                });
            }

            // Set up scrutinee_map: param indices as scrutinee IDs
            var scrutinee_ids: std.ArrayList(u32) = .empty;
            for (0..group.arity) |i| {
                try scrutinee_ids.append(self.allocator, @intCast(i));
            }

            var next_scrutinee_id: u32 = group.arity;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = group.arity,
                },
                try scrutinee_ids.toOwnedSlice(self.allocator),
                &next_scrutinee_id,
            );

            // Set up scrutinee_map: map scrutinee IDs to param_get locals
            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            for (0..group.arity) |i| {
                const param_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = param_local, .index = @intCast(i) },
                });
                // Track known types for Phase 3
                const param_type = typeIdToZigType(first_clause.params[i].type_id);
                if (param_type != .any) {
                    try self.known_local_types.put(param_local, param_type);
                }
                try scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(decision, group.clauses, &scrutinee_map);
        }

        const entry_block = Block{
            .label = 0,
            .instructions = try self.current_instrs.toOwnedSlice(self.allocator),
        };

        const name_str = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";

        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = typeIdToZigType(first_clause.return_type),
            .body = try self.allocSlice(Block, &.{entry_block}),
            .is_closure = false,
            .captures = &.{},
        });
    }

    /// Check if multi-clause function can emit switch_return for integer literals.
    /// Returns the param index to switch on if eligible.
    fn canSwitchDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup) ?u32 {
        if (group.clauses.len < 2) return null;

        var switch_param_idx: ?u32 = null;

        for (group.clauses, 0..) |clause, clause_idx| {
            const is_last = clause_idx == group.clauses.len - 1;

            if (is_last) {
                // Last clause must be wildcard/bind fallback (no literal pattern)
                for (clause.params) |param| {
                    if (param.pattern) |pat| {
                        if (pat.* == .literal) return null;
                    }
                }
                break;
            }

            // Non-last clauses must have literal pattern with no refinement
            if (clause.refinement != null) return null;

            // Find the literal param
            var found_literal_param: ?u32 = null;
            for (clause.params, 0..) |param, i| {
                if (param.pattern) |pat| {
                    if (pat.* == .literal) {
                        // Only integer literals can use switch
                        switch (pat.literal) {
                            .int => {},
                            else => return null,
                        }
                        found_literal_param = @intCast(i);
                    }
                }
            }

            if (found_literal_param == null) return null;

            if (switch_param_idx) |idx| {
                if (idx != found_literal_param.?) return null; // different param positions
            } else {
                // Check that the param type is a known integer type
                const param_type = typeIdToZigType(clause.params[found_literal_param.?].type_id);
                switch (param_type) {
                    .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => {},
                    else => return null,
                }
                switch_param_idx = found_literal_param;
            }
        }

        return switch_param_idx orelse {
            _ = self; // suppress unused
            return null;
        };
    }

    /// Emit index_get instructions to populate tuple binding locals.
    fn emitTupleBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.tuple_bindings) |binding| {
            // Get the param (the tuple)
            const tuple_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = tuple_local, .index = binding.param_index },
            });
            // Extract the element into the binding's local index
            try self.current_instrs.append(self.allocator, .{
                .index_get = .{
                    .dest = binding.local_index,
                    .object = tuple_local,
                    .index = binding.element_index,
                },
            });
        }
    }

    /// AND two boolean locals together.
    fn emitAnd(self: *IrBuilder, lhs: LocalId, rhs: LocalId) !LocalId {
        const result = self.next_local;
        self.next_local += 1;
        try self.current_instrs.append(self.allocator, .{
            .binary_op = .{ .dest = result, .op = .bool_and, .lhs = lhs, .rhs = rhs },
        });
        return result;
    }

    /// AND a refinement predicate with an existing condition, if present.
    fn emitRefinement(self: *IrBuilder, clause: *const hir_mod.Clause, condition: LocalId) !LocalId {
        if (clause.refinement) |ref_expr| {
            const ref_local = try self.lowerExpr(ref_expr);
            return self.emitAnd(condition, ref_local);
        }
        return condition;
    }

    /// Emit a check for a literal sub-pattern against an already-extracted element local.
    fn emitSubPatternCheck(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue) !LocalId {
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v) },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v) },
                });
                return match_local;
            },
            else => {
                // For bool, nil sub-patterns in tuples
                const lit_local = self.next_local;
                self.next_local += 1;
                switch (lit) {
                    .bool_val => |v| try self.current_instrs.append(self.allocator, .{
                        .const_bool = .{ .dest = lit_local, .value = v },
                    }),
                    .nil => try self.current_instrs.append(self.allocator, .{ .const_nil = lit_local }),
                    else => unreachable,
                }
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = elem_local, .rhs = lit_local },
                });
                return cmp_local;
            },
        };
    }

    /// Lower a case expression: reserve binding locals, then allocate dest/scrutinee,
    /// then build the case_block. Returns the dest local ID.
    fn lowerCaseExpr(self: *IrBuilder, case_data: hir_mod.CaseData) !LocalId {
        // Reserve binding local indices FIRST so that dest and scrutinee
        // don't conflict with locals defined inside if-scoped blocks.
        {
            var max_binding_local: u32 = self.next_local;
            for (case_data.arms) |arm| {
                for (arm.bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
            }
            self.next_local = max_binding_local;
        }

        // NOW allocate dest (after reservation — no shadowing risk)
        const dest = self.next_local;
        self.next_local += 1;

        // Lower scrutinee (also after reservation)
        const scrutinee_local = try self.lowerExpr(case_data.scrutinee);

        try self.lowerCaseExprBody(dest, scrutinee_local, case_data);
        return dest;
    }

    /// Check if all non-default arms are integer or bool literals of the same type with no guards.
    const SwitchableType = enum { int, bool_val };
    fn canSwitchLiteral(arms: []const hir_mod.CaseArm) ?SwitchableType {
        if (arms.len < 2) return null;

        var switchable_type: ?SwitchableType = null;

        for (arms, 0..) |arm, arm_idx| {
            const is_last = arm_idx == arms.len - 1;
            const pat = arm.pattern orelse return null;

            // Any arm with a guard disqualifies
            if (arm.guard != null) return null;

            if (pat.* == .wildcard or pat.* == .bind) {
                // Wildcard/bind is allowed only as the last arm (default)
                if (!is_last) return null;
                // Default arm is ok
                continue;
            }

            if (pat.* != .literal) return null;

            const lit_type: SwitchableType = switch (pat.literal) {
                .int => .int,
                .bool_val => .bool_val,
                else => return null, // atoms, strings, floats can't switch
            };

            if (switchable_type) |st| {
                if (st != lit_type) return null; // mixed types
            } else {
                switchable_type = lit_type;
            }
        }

        return switchable_type;
    }


    /// Build the case_block instruction body.
    fn lowerCaseExprBody(self: *IrBuilder, dest: LocalId, scrutinee_local: LocalId, case_data: hir_mod.CaseData) !void {
        // Try to emit a switch for homogeneous integer/bool literals with no guards
        if (canSwitchLiteral(case_data.arms)) |_| {
            var lit_cases: std.ArrayList(LitCase) = .empty;

            for (case_data.arms, 0..) |arm, arm_idx| {
                const is_last = arm_idx == case_data.arms.len - 1;
                const pat = arm.pattern.?;

                if (is_last and (pat.* == .wildcard or pat.* == .bind)) {
                    // Default arm
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;

                    if (pat.* == .bind) {
                        for (arm.bindings) |binding| {
                            if (binding.kind == .scrutinee) {
                                try self.current_instrs.append(self.allocator, .{
                                    .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                                });
                            }
                        }
                    }

                    const body_result = try self.lowerBlock(arm.body);
                    const default_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try self.current_instrs.append(self.allocator, .{
                        .switch_literal = .{
                            .dest = dest,
                            .scrutinee = scrutinee_local,
                            .cases = try lit_cases.toOwnedSlice(self.allocator),
                            .default_instrs = default_instrs,
                            .default_result = body_result,
                        },
                    });
                    return;
                }

                // Literal case arm
                const lit_value: LiteralValue = switch (pat.literal) {
                    .int => |v| .{ .int = v },
                    .bool_val => |v| .{ .bool_val = v },
                    else => unreachable,
                };

                const saved = self.current_instrs;
                self.current_instrs = .empty;
                const body_result = try self.lowerBlock(arm.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try lit_cases.append(self.allocator, .{
                    .value = lit_value,
                    .body_instrs = body_instrs,
                    .result = body_result,
                });
            }

            // All arms are literal (no default) — add match_fail as default
            const saved = self.current_instrs;
            self.current_instrs = .empty;
            try self.current_instrs.append(self.allocator, .{
                .match_fail = .{ .message = "no matching case clause" },
            });
            const fail_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved;

            try self.current_instrs.append(self.allocator, .{
                .switch_literal = .{
                    .dest = dest,
                    .scrutinee = scrutinee_local,
                    .cases = try lit_cases.toOwnedSlice(self.allocator),
                    .default_instrs = fail_instrs,
                    .default_result = null,
                },
            });
            return;
        }

        // General path: compile pattern matrix and lower decision tree
        {
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (case_data.arms, 0..) |arm, arm_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                try pats.append(self.allocator, arm.pattern);
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(arm_idx),
                    .guard = arm.guard,
                });
            }

            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            try scrutinee_map.put(0, scrutinee_local);

            var next_scrutinee_id: u32 = 1;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = 1,
                },
                try self.allocSlice(u32, &.{0}),
                &next_scrutinee_id,
            );

            // Emit case_block wrapping the decision tree lowering
            const saved_outer = self.current_instrs;
            self.current_instrs = .empty;
            try self.lowerDecisionTreeForCase(decision, case_data.arms, &scrutinee_map, dest);
            const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved_outer;

            try self.current_instrs.append(self.allocator, .{
                .case_block = .{
                    .dest = dest,
                    .pre_instrs = case_body,
                    .arms = &.{},
                    .default_instrs = &.{},
                    .default_result = null,
                },
            });
            return;
        }

    }

    /// Lower a decision tree for case expressions, emitting case_break at leaves.
    fn lowerDecisionTreeForCase(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        case_arms: []const hir_mod.CaseArm,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
        dest: LocalId,
    ) anyerror!void {
        _ = dest;
        switch (decision.*) {
            .success => |leaf| {
                const arm = case_arms[leaf.body_index];
                // Emit only scrutinee bindings (whole-value binds like `v -> v`).
                // Tuple element bindings are handled by bind nodes in the
                // decision tree path, which resolve to the correct decomposed locals.
                for (arm.bindings) |binding| {
                    if (binding.kind == .scrutinee) {
                        const scr_local = scrutinee_map.get(0) orelse 0;
                        try self.current_instrs.append(self.allocator, .{
                            .local_get = .{ .dest = binding.local_index, .source = scr_local },
                        });
                    }
                }
                const body_result = try self.lowerBlock(arm.body);
                try self.current_instrs.append(self.allocator, .{
                    .case_break = .{ .value = body_result },
                });
            },
            .failure => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "no matching case clause" },
                });
            },
            .guard => |guard_node| {
                const guard_local = try self.lowerExpr(guard_node.condition);
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForCase(guard_node.success, case_arms, scrutinee_map, 0);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForCase(guard_node.failure, case_arms, scrutinee_map, 0);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const check_local = try self.emitSubPatternCheck(scrutinee_local, case.value);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, 0);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, 0);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, 0);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, 0);
            },
            .check_tuple => |ct| {
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                const type_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_type = .{ .dest = type_check_local, .scrutinee = scrutinee_local, .expected_type = .{ .tuple = &.{} } },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i },
                    });
                    try scrutinee_map.put(findParamGetIdInDecision(ct.success, i), elem_local);
                }
                try self.lowerDecisionTreeForCase(ct.success, case_arms, scrutinee_map, 0);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(ct.failure, case_arms, scrutinee_map, 0);
            },
            .bind => |bind_node| {
                // Emit binding: resolve scrutinee and assign to binding local
                const scrutinee_local = self.resolveScrutinee(bind_node.source, scrutinee_map);
                // Find matching CaseBinding by name to get the local_index
                for (case_arms) |arm| {
                    for (arm.bindings) |binding| {
                        if (binding.name == bind_node.name) {
                            try self.current_instrs.append(self.allocator, .{
                                .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                            });
                            break;
                        }
                    }
                }
                try self.lowerDecisionTreeForCase(bind_node.next, case_arms, scrutinee_map, 0);
            },
        }
    }

    /// Lower a decision tree for function dispatch, emitting ret at leaves.
    fn lowerDecisionTreeForDispatch(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        clauses: []const hir_mod.Clause,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
    ) anyerror!void {
        switch (decision.*) {
            .success => |leaf| {
                const clause = &clauses[leaf.body_index];
                for (clause.tuple_bindings) |binding| {
                    const tuple_local = scrutinee_map.get(binding.param_index) orelse blk: {
                        const pl = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = pl, .index = binding.param_index },
                        });
                        break :blk pl;
                    };
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{
                            .dest = binding.local_index,
                            .object = tuple_local,
                            .index = binding.element_index,
                        },
                    });
                }
                const result_local = try self.lowerBlock(clause.body);
                try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
            },
            .failure => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "no matching clause" },
                });
            },
            .guard => |guard_node| {
                const guard_local = try self.lowerExpr(guard_node.condition);
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForDispatch(guard_node.success, clauses, scrutinee_map);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForDispatch(guard_node.failure, clauses, scrutinee_map);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const skip = self.shouldSkipTypeCheck(scrutinee_local, case.value);
                    const check_local = try self.emitSubPatternCheckWithSkip(scrutinee_local, case.value, skip);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .check_tuple => |ct| {
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                const type_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_type = .{ .dest = type_check_local, .scrutinee = scrutinee_local, .expected_type = .{ .tuple = &.{} } },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i },
                    });
                    try scrutinee_map.put(findParamGetIdInDecision(ct.success, i), elem_local);
                }
                try self.lowerDecisionTreeForDispatch(ct.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(ct.failure, clauses, scrutinee_map);
            },
            .bind => |bind_node| {
                try self.lowerDecisionTreeForDispatch(bind_node.next, clauses, scrutinee_map);
            },
        }
    }

    /// Resolve a scrutinee expression from the decision tree to an IR local.
    fn resolveScrutinee(self: *IrBuilder, expr: *const hir_mod.Expr, scrutinee_map: *std.AutoHashMap(u32, LocalId)) LocalId {
        _ = self;
        if (expr.kind == .param_get) {
            if (scrutinee_map.get(expr.kind.param_get)) |local| {
                return local;
            }
        }
        return 0;
    }

    /// Check if a scrutinee has a known type that allows skipping runtime type checks (Phase 3).
    fn shouldSkipTypeCheck(self: *IrBuilder, scrutinee: LocalId, lit: hir_mod.LiteralValue) bool {
        const known_type = self.known_local_types.get(scrutinee) orelse return false;
        return switch (lit) {
            .int => switch (known_type) {
                .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => true,
                else => false,
            },
            .float => switch (known_type) {
                .f16, .f32, .f64 => true,
                else => false,
            },
            .atom => known_type == .atom,
            .string => known_type == .string,
            .bool_val => known_type == .bool_type,
            .nil => known_type == .nil,
        };
    }

    /// Emit a sub-pattern check with optional skip_type_check flag (Phase 3).
    fn emitSubPatternCheckWithSkip(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue, skip: bool) !LocalId {
        if (!skip) return self.emitSubPatternCheck(elem_local, lit);
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            else => self.emitSubPatternCheck(elem_local, lit),
        };
    }

    fn lowerBlock(self: *IrBuilder, block: *const hir_mod.Block) !?LocalId {
        var last_local: ?LocalId = null;
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| last_local = try self.lowerExpr(expr),
                .local_set => |ls| {
                    const val = try self.lowerExpr(ls.value);
                    try self.current_instrs.append(self.allocator, .{
                        .local_set = .{ .dest = ls.index, .value = val },
                    });
                },
                .function_group => {},
            }
        }
        return last_local;
    }

    fn lowerExpr(self: *IrBuilder, expr: *const hir_mod.Expr) anyerror!LocalId {
        // Case expressions need binding locals reserved before dest allocation
        // to avoid shadowing conflicts in the generated Zig.
        if (expr.kind == .case) {
            return self.lowerCaseExpr(expr.kind.case);
        }

        const dest = self.next_local;
        self.next_local += 1;

        switch (expr.kind) {
            .int_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = dest, .value = v },
                });
                try self.known_local_types.put(dest, .i64);
            },
            .float_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = dest, .value = v },
                });
                try self.known_local_types.put(dest, .f64);
            },
            .string_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .string);
            },
            .atom_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_atom = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .atom);
            },
            .bool_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = dest, .value = v },
                });
                try self.known_local_types.put(dest, .bool_type);
            },
            .nil_lit => {
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
            },
            .local_get => |idx| {
                try self.current_instrs.append(self.allocator, .{
                    .local_get = .{ .dest = dest, .source = idx },
                });
            },
            .param_get => |idx| {
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = dest, .index = idx },
                });
                // Phase 3: track known type from HIR expr type_id
                const param_zig_type = typeIdToZigType(expr.type_id);
                if (param_zig_type != .any) {
                    try self.known_local_types.put(dest, param_zig_type);
                }
            },
            .binary => |bin| {
                const lhs = try self.lowerExpr(bin.lhs);
                const rhs = try self.lowerExpr(bin.rhs);
                const ir_op: BinaryOp.Op = switch (bin.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .rem_op => .rem_op,
                    .equal => .eq,
                    .not_equal => .neq,
                    .less => .lt,
                    .greater => .gt,
                    .less_equal => .lte,
                    .greater_equal => .gte,
                    .and_op => .bool_and,
                    .or_op => .bool_or,
                    .concat => .concat,
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = dest, .op = ir_op, .lhs = lhs, .rhs = rhs },
                });
            },
            .unary => |un| {
                const operand = try self.lowerExpr(un.operand);
                const ir_op: UnaryOp.Op = switch (un.op) {
                    .negate => .negate,
                    .not_op => .bool_not,
                };
                try self.current_instrs.append(self.allocator, .{
                    .unary_op = .{ .dest = dest, .op = ir_op, .operand = operand },
                });
            },
            .call => |call| {
                var args: std.ArrayList(LocalId) = .empty;
                for (call.args) |arg| {
                    try args.append(self.allocator, try self.lowerExpr(arg));
                }
                switch (call.target) {
                    .direct => |dc| {
                        try self.current_instrs.append(self.allocator, .{
                            .call_direct = .{ .dest = dest, .function = dc.function_group_id, .args = try args.toOwnedSlice(self.allocator) },
                        });
                    },
                    .named => |name| {
                        try self.current_instrs.append(self.allocator, .{
                            .call_named = .{ .dest = dest, .name = name, .args = try args.toOwnedSlice(self.allocator) },
                        });
                    },
                    .closure => |callee| {
                        const callee_local = try self.lowerExpr(callee);
                        try self.current_instrs.append(self.allocator, .{
                            .call_closure = .{ .dest = dest, .callee = callee_local, .args = try args.toOwnedSlice(self.allocator) },
                        });
                    },
                    .dispatch => |dc| {
                        try self.current_instrs.append(self.allocator, .{
                            .call_dispatch = .{ .dest = dest, .group_id = dc.function_group_id, .args = try args.toOwnedSlice(self.allocator) },
                        });
                    },
                    .builtin => |name| {
                        try self.current_instrs.append(self.allocator, .{
                            .call_builtin = .{ .dest = dest, .name = name, .args = try args.toOwnedSlice(self.allocator) },
                        });
                    },
                }
            },
            .branch => |br| {
                const cond = try self.lowerExpr(br.condition);

                // Save current instruction list, lower then block into a fresh list
                const saved_instrs = self.current_instrs;
                self.current_instrs = .empty;
                const then_result = try self.lowerBlock(br.then_block);
                const then_instrs = try self.current_instrs.toOwnedSlice(self.allocator);

                // Lower else block (or emit const_nil if absent)
                self.current_instrs = .empty;
                var else_result: ?LocalId = null;
                if (br.else_block) |else_block| {
                    else_result = try self.lowerBlock(else_block);
                } else {
                    const nil_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{ .const_nil = nil_local });
                    else_result = nil_local;
                }
                const else_instrs = try self.current_instrs.toOwnedSlice(self.allocator);

                // Restore original instruction list and append if_expr
                self.current_instrs = saved_instrs;
                try self.current_instrs.append(self.allocator, .{
                    .if_expr = .{
                        .dest = dest,
                        .condition = cond,
                        .then_instrs = then_instrs,
                        .then_result = then_result,
                        .else_instrs = else_instrs,
                        .else_result = else_result,
                    },
                });
            },
            .tuple_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                for (elems) |elem| {
                    try locals.append(self.allocator, try self.lowerExpr(elem));
                }
                try self.current_instrs.append(self.allocator, .{
                    .tuple_init = .{ .dest = dest, .elements = try locals.toOwnedSlice(self.allocator) },
                });
            },
            .list_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                for (elems) |elem| {
                    try locals.append(self.allocator, try self.lowerExpr(elem));
                }
                try self.current_instrs.append(self.allocator, .{
                    .list_init = .{ .dest = dest, .elements = try locals.toOwnedSlice(self.allocator) },
                });
            },
            .panic => |msg| {
                _ = try self.lowerExpr(msg);
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "panic" },
                });
            },
            .never => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "unreachable" },
                });
            },
            .case => |case_data| {
                // Case expressions are handled specially — see lowerExpr early return
                // (this branch should not be reached because of the early return above)
                try self.lowerCaseExprBody(dest, try self.lowerExpr(case_data.scrutinee), case_data);
            },
            else => {
                // Emit a nil placeholder for unhandled expressions
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
            },
        }

        return dest;
    }

    fn allocSlice(self: *IrBuilder, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

/// Walk a Decision tree to find the param_get index used for the N-th tuple element.
/// The decision tree's check_tuple success subtree references element scrutinee IDs
/// via param_get nodes. This scans to find the ID associated with a given element index.
fn findParamGetIdInDecision(decision: *const hir_mod.Decision, target_element: u32) u32 {
    switch (decision.*) {
        .check_tuple => |ct| {
            // This is a nested tuple check. The scrutinee expr tells us the ID.
            if (ct.scrutinee.kind == .param_get) {
                return ct.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(ct.success, target_element);
        },
        .switch_literal => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                // The first switch_literal we encounter should be for element 0,
                // second for element 1, etc. But we need to trace the right one.
                // We track by counting: the decision tree puts elements in order.
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                // For other elements, look in default/cases
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .switch_tag => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .guard => |g| return findParamGetIdInDecision(g.success, target_element),
        .bind => |b| {
            if (b.source.kind == .param_get) {
                if (target_element == 0) return b.source.kind.param_get;
                return findParamGetIdInDecision(b.next, target_element - 1);
            }
            return findParamGetIdInDecision(b.next, target_element);
        },
        .success => {
            // We need to derive the ID from the pattern. The compilePatternMatrix
            // allocates IDs sequentially starting from a base. The base for tuple
            // element N of scrutinee S is: the next_id at the time of tuple expansion.
            // Since we don't store that, use a heuristic: the first referenced param_get
            // ID + target_element offset.
            return target_element;
        },
        .failure => return target_element,
    }
}

fn typeIdToZigType(type_id: types_mod.TypeId) ZigType {
    return switch (type_id) {
        types_mod.TypeStore.BOOL => .bool_type,
        types_mod.TypeStore.STRING => .string,
        types_mod.TypeStore.ATOM => .atom,
        types_mod.TypeStore.NIL => .nil,
        types_mod.TypeStore.NEVER => .void,
        types_mod.TypeStore.I64 => .i64,
        types_mod.TypeStore.I32 => .i32,
        types_mod.TypeStore.I16 => .i16,
        types_mod.TypeStore.I8 => .i8,
        types_mod.TypeStore.U64 => .u64,
        types_mod.TypeStore.U32 => .u32,
        types_mod.TypeStore.U16 => .u16,
        types_mod.TypeStore.U8 => .u8,
        types_mod.TypeStore.F64 => .f64,
        types_mod.TypeStore.F32 => .f32,
        types_mod.TypeStore.F16 => .f16,
        types_mod.TypeStore.USIZE => .usize,
        types_mod.TypeStore.ISIZE => .isize,
        else => .any,
    };
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "IR build simple function" {
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, &parser.interner);
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    try std.testing.expect(ir_program.functions[0].body.len > 0);
    try std.testing.expect(ir_program.functions[0].body[0].instructions.len > 0);
}
