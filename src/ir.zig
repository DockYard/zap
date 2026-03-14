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

    // Calls
    call_direct: CallDirect,
    call_closure: CallClosure,
    call_dispatch: CallDispatch,
    call_builtin: CallBuiltin,

    // Control flow
    branch: Branch,
    cond_branch: CondBranch,
    switch_tag: SwitchTag,
    switch_literal: SwitchLiteral,
    match_fail: MatchFail,
    ret: Return,
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

pub const CallDirect = struct {
    dest: LocalId,
    function: FunctionId,
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

pub const MatchFail = struct {
    message: []const u8,
};

pub const Return = struct {
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
        for (group.clauses) |clause| {
            const func_id = self.next_function_id;
            self.next_function_id += 1;
            self.next_local = 0;
            self.next_label = 0;

            // Build params
            var params: std.ArrayList(Param) = .empty;
            for (clause.params) |param| {
                const name = if (param.name) |n| self.interner.get(n) else "_";
                try params.append(self.allocator, .{
                    .name = name,
                    .type_expr = typeIdToZigType(param.type_id),
                });
            }

            // Build body
            self.current_instrs = .empty;
            try self.lowerBlock(clause.body);

            // Finish with implicit return
            if (self.current_instrs.items.len > 0) {
                const last_local: LocalId = if (self.next_local > 0) self.next_local - 1 else 0;
                try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = last_local } });
            } else {
                try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = null } });
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
                .return_type = typeIdToZigType(clause.return_type),
                .body = try self.allocSlice(Block, &.{entry_block}),
                .is_closure = false,
                .captures = &.{},
            });
        }
    }

    fn lowerBlock(self: *IrBuilder, block: *const hir_mod.Block) !void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| _ = try self.lowerExpr(expr),
                .local_set => |ls| {
                    const val = try self.lowerExpr(ls.value);
                    try self.current_instrs.append(self.allocator, .{
                        .local_set = .{ .dest = ls.index, .value = val },
                    });
                },
                .function_group => {},
            }
        }
    }

    fn lowerExpr(self: *IrBuilder, expr: *const hir_mod.Expr) anyerror!LocalId {
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
                // Emit as a direct call to the operator function
                try self.current_instrs.append(self.allocator, .{
                    .call_direct = .{ .dest = dest, .function = 0, .args = try self.allocSlice(LocalId, &.{ lhs, rhs }) },
                });
            },
            .unary => |un| {
                const operand = try self.lowerExpr(un.operand);
                try self.current_instrs.append(self.allocator, .{
                    .call_direct = .{ .dest = dest, .function = 0, .args = try self.allocSlice(LocalId, &.{operand}) },
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
                const then_label = self.next_label;
                self.next_label += 1;
                const else_label = self.next_label;
                self.next_label += 1;
                try self.current_instrs.append(self.allocator, .{
                    .cond_branch = .{ .condition = cond, .then_target = then_label, .else_target = else_label },
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
