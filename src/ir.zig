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
    match_atom: MatchAtom,
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
    scrutinee: LocalId,
    cases: []const LitCase,
    default: LabelId,
};

pub const LitCase = struct {
    value: LiteralValue,
    target: LabelId,
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
};

pub const MatchString = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected: []const u8,
};

pub const MatchType = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_type: ZigType,
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
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        self.functions.deinit(self.allocator);
        self.current_blocks.deinit(self.allocator);
        self.current_instrs.deinit(self.allocator);
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

        // Use first clause for param types and return type
        const first_clause = &group.clauses[0];

        // Build params with generic names (__arg_N)
        var params: std.ArrayList(Param) = .empty;
        for (first_clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = typeIdToZigType(param.type_id),
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
        } else {
            // Multiple clauses — emit pattern match dispatch
            for (group.clauses, 0..) |clause, clause_idx| {
                const is_last = clause_idx == group.clauses.len - 1;

                // Classify clause pattern type
                const pattern_kind = classifyClausePattern(&clause);

                if (is_last and pattern_kind == .tuple) {
                    // Last clause with tuple pattern — use guard_block for scoping,
                    // then add match_fail fallback
                    try self.emitTupleDispatch(&clause);
                    try self.current_instrs.append(self.allocator, .{
                        .match_fail = .{ .message = "no matching clause" },
                    });
                } else if (is_last) {
                    // Last clause without tuple — unconditional fallback
                    const result_local = try self.lowerBlock(clause.body);
                    try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
                } else if (pattern_kind == .tuple) {
                    // Tuple pattern dispatch — uses guard_block for scoped bindings
                    try self.emitTupleDispatch(&clause);
                } else if (pattern_kind == .literal) {
                    // Literal pattern dispatch
                    var condition_local: ?LocalId = null;
                    condition_local = try self.emitLiteralCondition(&clause);

                    if (condition_local) |cond| {
                        // AND with refinement if present
                        const final_cond = try self.emitRefinement(&clause, cond);
                        const result = try self.lowerBlock(clause.body);
                        try self.current_instrs.append(self.allocator, .{
                            .cond_return = .{ .condition = final_cond, .value = result },
                        });
                    }
                } else {
                    // Non-last, non-literal, non-tuple — check param type if typed
                    var type_guard: ?LocalId = null;
                    for (clause.params, 0..) |param, i| {
                        const zig_type = typeIdToZigType(param.type_id);
                        if (zig_type != .any) {
                            const arg_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .param_get = .{ .dest = arg_local, .index = @intCast(i) },
                            });
                            const guard_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .match_type = .{ .dest = guard_local, .scrutinee = arg_local, .expected_type = zig_type },
                            });
                            type_guard = guard_local;
                        }
                    }
                    if (type_guard) |guard| {
                        // AND with refinement if present
                        const final_cond = try self.emitRefinement(&clause, guard);
                        const result_local = try self.lowerBlock(clause.body);
                        try self.current_instrs.append(self.allocator, .{
                            .cond_return = .{ .condition = final_cond, .value = result_local },
                        });
                    } else if (clause.refinement != null) {
                        // Has refinement but no type guard — use refinement as condition
                        const ref_cond = try self.lowerExpr(clause.refinement.?);
                        const result_local = try self.lowerBlock(clause.body);
                        try self.current_instrs.append(self.allocator, .{
                            .cond_return = .{ .condition = ref_cond, .value = result_local },
                        });
                    } else {
                        // Untyped non-last clause — emit unconditional return
                        const result_local = try self.lowerBlock(clause.body);
                        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
                    }
                }
            }
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

    const PatternKind = enum { literal, tuple, other };

    fn classifyClausePattern(clause: *const hir_mod.Clause) PatternKind {
        for (clause.params) |param| {
            if (param.pattern) |pat| {
                if (pat.* == .literal) return .literal;
                if (pat.* == .tuple) return .tuple;
            }
        }
        return .other;
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

    /// Build condition for literal patterns. Returns the condition local.
    fn emitLiteralCondition(self: *IrBuilder, clause: *const hir_mod.Clause) !?LocalId {
        var condition_local: ?LocalId = null;
        for (clause.params, 0..) |param, i| {
            if (param.pattern) |pat| {
                if (pat.* == .literal) {
                    const this_cond = try self.emitLiteralCheck(pat.literal, @intCast(i));
                    condition_local = if (condition_local) |prev|
                        try self.emitAnd(prev, this_cond)
                    else
                        this_cond;
                }
            }
        }
        return condition_local;
    }

    /// Emit a comparison check for a single literal pattern against a param.
    fn emitLiteralCheck(self: *IrBuilder, lit: hir_mod.LiteralValue, param_idx: u32) !LocalId {
        const arg_local = self.next_local;
        self.next_local += 1;
        try self.current_instrs.append(self.allocator, .{
            .param_get = .{ .dest = arg_local, .index = param_idx },
        });
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = arg_local, .atom_name = self.interner.get(v) },
                });
                return match_local;
            },
            .int => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = arg_local, .rhs = lit_local },
                });
                return cmp_local;
            },
            .float => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = arg_local, .rhs = lit_local },
                });
                return cmp_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = arg_local, .expected = self.interner.get(v) },
                });
                return match_local;
            },
            .bool_val => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = arg_local, .rhs = lit_local },
                });
                return cmp_local;
            },
            .nil => {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{ .const_nil = lit_local });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = arg_local, .rhs = lit_local },
                });
                return cmp_local;
            },
        };
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

    /// Emit tuple pattern dispatch with guard_block for scoped bindings.
    fn emitTupleDispatch(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        // Build condition by checking literal sub-patterns in tuples
        var condition_local: ?LocalId = null;

        for (clause.params, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .tuple) {
                    // Get the param tuple
                    const tuple_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .param_get = .{ .dest = tuple_local, .index = @intCast(param_idx) },
                    });

                    // Check each sub-pattern that's a literal
                    for (pat.tuple, 0..) |sub_pat, elem_idx| {
                        if (sub_pat.* == .literal) {
                            // Extract element
                            const elem_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .index_get = .{
                                    .dest = elem_local,
                                    .object = tuple_local,
                                    .index = @intCast(elem_idx),
                                },
                            });

                            // Check the literal
                            const check_local = try self.emitSubPatternCheck(elem_local, sub_pat.literal);
                            condition_local = if (condition_local) |prev|
                                try self.emitAnd(prev, check_local)
                            else
                                check_local;
                        }
                    }
                }
            }
        }

        if (condition_local) |cond| {
            // AND with refinement if present
            const final_cond = try self.emitRefinement(clause, cond);

            // Build guard block body: extract bindings + lower body + return
            const saved_instrs = self.current_instrs;
            self.current_instrs = .empty;

            // Emit tuple bindings inside the guard block
            try self.emitTupleBindings(clause);

            // Lower body
            const result_local = try self.lowerBlock(clause.body);
            try self.current_instrs.append(self.allocator, .{
                .ret = .{ .value = result_local },
            });

            const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved_instrs;

            // Emit guard_block
            try self.current_instrs.append(self.allocator, .{
                .guard_block = .{ .condition = final_cond, .body = guard_body },
            });
        }
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
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = elem_local, .rhs = lit_local },
                });
                return cmp_local;
            },
            .float => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = elem_local, .rhs = lit_local },
                });
                return cmp_local;
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

    /// Build the case_block instruction body.
    fn lowerCaseExprBody(self: *IrBuilder, dest: LocalId, scrutinee_local: LocalId, case_data: hir_mod.CaseData) !void {
        var ir_arms: std.ArrayList(IrCaseArm) = .empty;
        var pre_instrs_list: std.ArrayList(Instruction) = .empty;
        var default_instrs: ?[]const Instruction = null;
        var default_result: ?LocalId = null;

        for (case_data.arms, 0..) |arm, arm_idx| {
            const is_last = arm_idx == case_data.arms.len - 1;
            const pat = if (arm.pattern) |p| p else null;

            // Determine if this is a default arm
            const is_default = if (pat) |p| (p.* == .wildcard or p.* == .bind) else true;

            if (is_default and is_last) {
                // Default arm — no condition, just body
                const saved = self.current_instrs;
                self.current_instrs = .empty;

                if (pat) |p| {
                    if (p.* == .bind) {
                        for (arm.bindings) |binding| {
                            if (binding.kind == .scrutinee) {
                                try self.current_instrs.append(self.allocator, .{
                                    .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                                });
                            }
                        }
                    }
                }

                const body_result = try self.lowerBlock(arm.body);
                default_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                default_result = body_result;
                self.current_instrs = saved;
            } else if (pat != null and pat.?.* == .tuple) {
                // Tuple pattern arm — emit as guarded pre_instrs with case_break.
                // Uses nested guard_blocks: outer type check + inner tag check.
                // This avoids indexing non-tuple types at compile time.
                const saved = self.current_instrs;

                // Build the innermost body: bindings + guard check + user body + case_break
                self.current_instrs = .empty;
                for (arm.bindings) |binding| {
                    switch (binding.kind) {
                        .scrutinee => {
                            try self.current_instrs.append(self.allocator, .{
                                .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                            });
                        },
                        .tuple_element => {
                            try self.current_instrs.append(self.allocator, .{
                                .index_get = .{
                                    .dest = binding.local_index,
                                    .object = scrutinee_local,
                                    .index = binding.element_index,
                                },
                            });
                        },
                    }
                }

                if (arm.guard) |guard_expr| {
                    // Guard present — wrap body + case_break in a guard_block
                    const guard_local = try self.lowerExpr(guard_expr);
                    const saved_inner = self.current_instrs;
                    self.current_instrs = .empty;
                    const body_result = try self.lowerBlock(arm.body);
                    try self.current_instrs.append(self.allocator, .{
                        .case_break = .{ .value = body_result },
                    });
                    const guarded_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved_inner;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = guard_local, .body = guarded_body },
                    });
                } else {
                    const body_result = try self.lowerBlock(arm.body);
                    try self.current_instrs.append(self.allocator, .{
                        .case_break = .{ .value = body_result },
                    });
                }
                const inner_body = try self.current_instrs.toOwnedSlice(self.allocator);

                // Build tag check condition + inner guard_block
                self.current_instrs = .empty;
                var tag_condition: ?LocalId = null;
                for (pat.?.tuple, 0..) |sub_pat, elem_idx| {
                    if (sub_pat.* == .literal) {
                        const elem_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .index_get = .{
                                .dest = elem_local,
                                .object = scrutinee_local,
                                .index = @intCast(elem_idx),
                            },
                        });
                        const check = try self.emitSubPatternCheck(elem_local, sub_pat.literal);
                        tag_condition = if (tag_condition) |prev|
                            try self.emitAnd(prev, check)
                        else
                            check;
                    }
                }
                if (tag_condition) |tag_cond| {
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = tag_cond, .body = inner_body },
                    });
                } else {
                    // No literal sub-patterns (all binds) — just emit inner body directly
                    for (inner_body) |instr| {
                        try self.current_instrs.append(self.allocator, instr);
                    }
                }
                const tag_check_body = try self.current_instrs.toOwnedSlice(self.allocator);

                // Build outer type check: @typeInfo(@TypeOf(scrutinee)) == .@"struct"
                self.current_instrs = .empty;
                const type_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_type = .{ .dest = type_check_local, .scrutinee = scrutinee_local, .expected_type = .{ .tuple = &.{} } },
                });
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = tag_check_body },
                });

                // Append to pre_instrs
                const outer_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                for (outer_instrs) |instr| {
                    try pre_instrs_list.append(self.allocator, instr);
                }

                self.current_instrs = saved;
            } else {
                // Non-tuple conditional arm (literal, bind, wildcard)
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var condition_local: ?LocalId = null;

                if (pat) |p| {
                    switch (p.*) {
                        .literal => |lit| {
                            condition_local = try self.emitCasePatternCheck(scrutinee_local, lit);
                        },
                        .bind => {
                            const true_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .const_bool = .{ .dest = true_local, .value = true },
                            });
                            condition_local = true_local;
                        },
                        .wildcard => {
                            const true_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .const_bool = .{ .dest = true_local, .value = true },
                            });
                            condition_local = true_local;
                        },
                        else => {},
                    }
                }

                if (condition_local) |cond| {
                    if (arm.guard) |guard_expr| {
                        const guard_local = try self.lowerExpr(guard_expr);
                        condition_local = try self.emitAnd(cond, guard_local);
                    }
                }

                const cond_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                const final_cond = condition_local orelse blk: {
                    self.current_instrs = saved;
                    const true_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .const_bool = .{ .dest = true_local, .value = true },
                    });
                    break :blk true_local;
                };

                self.current_instrs = .empty;
                for (arm.bindings) |binding| {
                    switch (binding.kind) {
                        .scrutinee => {
                            try self.current_instrs.append(self.allocator, .{
                                .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                            });
                        },
                        .tuple_element => {
                            try self.current_instrs.append(self.allocator, .{
                                .index_get = .{
                                    .dest = binding.local_index,
                                    .object = scrutinee_local,
                                    .index = binding.element_index,
                                },
                            });
                        },
                    }
                }

                const body_result = try self.lowerBlock(arm.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try ir_arms.append(self.allocator, .{
                    .cond_instrs = cond_instrs,
                    .condition = final_cond,
                    .body_instrs = body_instrs,
                    .result = body_result,
                });
            }
        }

        if (default_instrs == null) {
            const saved = self.current_instrs;
            self.current_instrs = .empty;
            try self.current_instrs.append(self.allocator, .{
                .match_fail = .{ .message = "no matching case clause" },
            });
            default_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            default_result = null;
            self.current_instrs = saved;
        }

        try self.current_instrs.append(self.allocator, .{
            .case_block = .{
                .dest = dest,
                .pre_instrs = try pre_instrs_list.toOwnedSlice(self.allocator),
                .arms = try ir_arms.toOwnedSlice(self.allocator),
                .default_instrs = default_instrs.?,
                .default_result = default_result,
            },
        });
    }

    /// Emit a comparison of a scrutinee local against a literal value (for case patterns).
    fn emitCasePatternCheck(self: *IrBuilder, scrutinee: LocalId, lit: hir_mod.LiteralValue) !LocalId {
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = scrutinee, .atom_name = self.interner.get(v) },
                });
                return match_local;
            },
            .int => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = scrutinee, .rhs = lit_local },
                });
                return cmp_local;
            },
            .float => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = scrutinee, .rhs = lit_local },
                });
                return cmp_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = scrutinee, .expected = self.interner.get(v) },
                });
                return match_local;
            },
            .bool_val => |v| {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = lit_local, .value = v },
                });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = scrutinee, .rhs = lit_local },
                });
                return cmp_local;
            },
            .nil => {
                const lit_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{ .const_nil = lit_local });
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = scrutinee, .rhs = lit_local },
                });
                return cmp_local;
            },
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
            },
            .float_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = dest, .value = v },
                });
            },
            .string_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = dest, .value = self.interner.get(v) },
                });
            },
            .atom_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_atom = .{ .dest = dest, .value = self.interner.get(v) },
                });
            },
            .bool_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = dest, .value = v },
                });
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
