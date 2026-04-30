const std = @import("std");
const ir = @import("ir.zig");
const lattice = @import("escape_lattice.zig");

pub fn rewriteContifiedContinuations(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    ctx: *const lattice.AnalysisContext,
) !void {
    const functions = @constCast(program.functions);
    var next_label = maxLabel(program) + 1;

    for (functions) |*func| {
        var block_index: usize = 0;
        while (block_index < func.body.len) : (block_index += 1) {
            const block = func.body[block_index];
            const rewritten = try rewriteBlock(allocator, program, ctx, func.id, block, next_label);
            if (rewritten == null) continue;

            const result = rewritten.?;
            next_label = result.next_label;

            const old_body = func.body;
            const new_body = try allocator.alloc(ir.Block, old_body.len + 1);
            @memcpy(new_body[0..block_index], old_body[0..block_index]);
            new_body[block_index] = result.current_block;
            new_body[block_index + 1] = result.continuation_block;
            @memcpy(new_body[block_index + 2 ..], old_body[block_index + 1 ..]);
            func.body = new_body;
            block_index += 1;
        }
    }
}

const RewriteResult = struct {
    current_block: ir.Block,
    continuation_block: ir.Block,
    next_label: ir.LabelId,
};

fn rewriteBlock(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    ctx: *const lattice.AnalysisContext,
    function_id: ir.FunctionId,
    block: ir.Block,
    next_label: ir.LabelId,
) !?RewriteResult {
    for (block.instructions, 0..) |instr, instr_index| {
        const cc = switch (instr) {
            .call_closure => |call| call,
            else => continue,
        };

        if (instr_index + 1 >= block.instructions.len) continue;

        const spec = ctx.getCallSiteSpecialization(.{
            .function = function_id,
            .block = block.label,
            .instr_index = @intCast(instr_index),
        }) orelse continue;
        if (spec.decision != .contified) continue;
        if (!spec.lambda_set.isSingleton()) continue;

        const target_id = spec.lambda_set.members[0];
        if (target_id >= program.functions.len) continue;
        const target_func = program.functions[target_id];
        if (target_func.body.len != 1) continue;

        const resolved = resolveClosureCallTarget(block.instructions[0 .. instr_index + 1], cc.callee) orelse if (target_func.captures.len == 0)
            ResolvedClosureTarget{ .function_id = target_id, .captures = &.{} }
        else
            continue;
        if (resolved.function_id != target_id) continue;

        const continuation_label = next_label;
        const suffix = block.instructions[instr_index + 1 ..];
        if (!isStraightLineSuffix(suffix)) continue;

        var next_local = maxLocalInFunction(block.instructions, target_func.body[0].instructions);
        var local_map = std.AutoHashMap(ir.LocalId, ir.LocalId).init(allocator);
        defer local_map.deinit();
        var cloned: std.ArrayListUnmanaged(ir.Instruction) = .empty;
        defer cloned.deinit(allocator);

        try cloned.appendSlice(allocator, block.instructions[0..instr_index]);

        for (target_func.body[0].instructions) |closure_instr| {
            switch (closure_instr) {
                .param_get => |pg| {
                    if (pg.index >= cc.args.len) return null;
                    try local_map.put(pg.dest, cc.args[pg.index]);
                },
                .capture_get => |cg| {
                    if (cg.index >= resolved.captures.len) return null;
                    try local_map.put(cg.dest, resolved.captures[cg.index]);
                },
                .ret => |ret| {
                    const mapped = if (ret.value) |value| remapLocal(value, &local_map) else null;
                    try cloned.append(allocator, .{ .jump = .{
                        .target = continuation_label,
                        .value = mapped,
                        .bind_dest = cc.dest,
                    } });
                },
                else => {
                    const cloned_instr = try cloneInstruction(allocator, closure_instr, &local_map, &next_local);
                    try cloned.append(allocator, cloned_instr);
                },
            }
        }

        const current_instrs = try cloned.toOwnedSlice(allocator);
        const continuation_instrs = try allocator.dupe(ir.Instruction, suffix);

        return RewriteResult{
            .current_block = .{ .label = block.label, .instructions = current_instrs },
            .continuation_block = .{ .label = continuation_label, .instructions = continuation_instrs },
            .next_label = continuation_label + 1,
        };
    }

    return null;
}

const ResolvedClosureTarget = struct {
    function_id: ir.FunctionId,
    captures: []const ir.LocalId,
};

fn resolveClosureCallTarget(instrs: []const ir.Instruction, local: ir.LocalId) ?ResolvedClosureTarget {
    return resolveClosureCallTargetDepth(instrs, local, 0);
}

fn resolveClosureCallTargetDepth(instrs: []const ir.Instruction, local: ir.LocalId, depth: u8) ?ResolvedClosureTarget {
    if (depth > 32) return null;
    var idx = instrs.len;
    while (idx > 0) {
        idx -= 1;
        switch (instrs[idx]) {
            .make_closure => |mc| if (mc.dest == local) return .{ .function_id = mc.function, .captures = mc.captures },
            .local_get => |lg| if (lg.dest == local) return resolveClosureCallTargetDepth(instrs[0 .. idx + 1], lg.source, depth + 1),
            .local_set => |ls| if (ls.dest == local) return resolveClosureCallTargetDepth(instrs[0 .. idx + 1], ls.value, depth + 1),
            .move_value => |mv| if (mv.dest == local) return resolveClosureCallTargetDepth(instrs[0 .. idx + 1], mv.source, depth + 1),
            .share_value => |sv| if (sv.dest == local) return resolveClosureCallTargetDepth(instrs[0 .. idx + 1], sv.source, depth + 1),
            else => {},
        }
    }
    return null;
}

fn cloneInstruction(
    allocator: std.mem.Allocator,
    instr: ir.Instruction,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) anyerror!ir.Instruction {
    return switch (instr) {
        .const_int => |ci| .{ .const_int = .{ .dest = try remapDest(ci.dest, local_map, next_local), .value = ci.value } },
        .const_float => |cf| .{ .const_float = .{ .dest = try remapDest(cf.dest, local_map, next_local), .value = cf.value } },
        .const_string => |cs| .{ .const_string = .{ .dest = try remapDest(cs.dest, local_map, next_local), .value = try allocator.dupe(u8, cs.value) } },
        .const_bool => |cb| .{ .const_bool = .{ .dest = try remapDest(cb.dest, local_map, next_local), .value = cb.value } },
        .const_atom => |ca| .{ .const_atom = .{ .dest = try remapDest(ca.dest, local_map, next_local), .value = try allocator.dupe(u8, ca.value) } },
        .const_nil => |dest| .{ .const_nil = try remapDest(dest, local_map, next_local) },
        .local_get => |lg| .{ .local_get = .{ .dest = try remapDest(lg.dest, local_map, next_local), .source = remapLocal(lg.source, local_map) } },
        .local_set => |ls| .{ .local_set = .{ .dest = try remapDest(ls.dest, local_map, next_local), .value = remapLocal(ls.value, local_map) } },
        .move_value => |mv| .{ .move_value = .{ .dest = try remapDest(mv.dest, local_map, next_local), .source = remapLocal(mv.source, local_map) } },
        .share_value => |sv| .{ .share_value = .{ .dest = try remapDest(sv.dest, local_map, next_local), .source = remapLocal(sv.source, local_map) } },
        .binary_op => |bo| .{ .binary_op = .{ .dest = try remapDest(bo.dest, local_map, next_local), .op = bo.op, .lhs = remapLocal(bo.lhs, local_map), .rhs = remapLocal(bo.rhs, local_map) } },
        .unary_op => |uo| .{ .unary_op = .{ .dest = try remapDest(uo.dest, local_map, next_local), .op = uo.op, .operand = remapLocal(uo.operand, local_map) } },
        .field_get => |fg| .{ .field_get = .{ .dest = try remapDest(fg.dest, local_map, next_local), .object = remapLocal(fg.object, local_map), .field = try allocator.dupe(u8, fg.field) } },
        .index_get => |ig| .{ .index_get = .{ .dest = try remapDest(ig.dest, local_map, next_local), .object = remapLocal(ig.object, local_map), .index = ig.index } },
        .tuple_init => |ti| .{ .tuple_init = .{ .dest = try remapDest(ti.dest, local_map, next_local), .elements = try remapLocalSlice(allocator, ti.elements, local_map) } },
        .list_init => |li| .{ .list_init = .{ .dest = try remapDest(li.dest, local_map, next_local), .elements = try remapLocalSlice(allocator, li.elements, local_map) } },
        .struct_init => |si| .{ .struct_init = .{ .dest = try remapDest(si.dest, local_map, next_local), .type_name = try allocator.dupe(u8, si.type_name), .fields = try cloneStructFields(allocator, si.fields, local_map) } },
        .union_init => |ui| .{ .union_init = .{ .dest = try remapDest(ui.dest, local_map, next_local), .union_type = try allocator.dupe(u8, ui.union_type), .variant_name = try allocator.dupe(u8, ui.variant_name), .value = remapLocal(ui.value, local_map) } },
        .enum_literal => |el| .{ .enum_literal = .{ .dest = try remapDest(el.dest, local_map, next_local), .type_name = try allocator.dupe(u8, el.type_name), .variant = try allocator.dupe(u8, el.variant) } },
        .call_direct => |cd| .{ .call_direct = .{ .dest = try remapDest(cd.dest, local_map, next_local), .function = cd.function, .args = try remapLocalSlice(allocator, cd.args, local_map), .arg_modes = try allocator.dupe(ir.ValueMode, cd.arg_modes) } },
        .call_named => |cn| .{ .call_named = .{ .dest = try remapDest(cn.dest, local_map, next_local), .name = try allocator.dupe(u8, cn.name), .args = try remapLocalSlice(allocator, cn.args, local_map), .arg_modes = try allocator.dupe(ir.ValueMode, cn.arg_modes) } },
        .call_builtin => |cb| .{ .call_builtin = .{ .dest = try remapDest(cb.dest, local_map, next_local), .name = try allocator.dupe(u8, cb.name), .args = try remapLocalSlice(allocator, cb.args, local_map), .arg_modes = try allocator.dupe(ir.ValueMode, cb.arg_modes) } },
        .optional_unwrap => |ou| .{ .optional_unwrap = .{ .dest = try remapDest(ou.dest, local_map, next_local), .source = remapLocal(ou.source, local_map) } },
        .if_expr => |ie| .{ .if_expr = .{
            .dest = try remapDest(ie.dest, local_map, next_local),
            .condition = remapLocal(ie.condition, local_map),
            .then_instrs = try cloneInstructionSlice(allocator, ie.then_instrs, local_map, next_local),
            .then_result = if (ie.then_result) |result| remapLocal(result, local_map) else null,
            .else_instrs = try cloneInstructionSlice(allocator, ie.else_instrs, local_map, next_local),
            .else_result = if (ie.else_result) |result| remapLocal(result, local_map) else null,
        } },
        .switch_literal => |sl| .{ .switch_literal = .{
            .dest = try remapDest(sl.dest, local_map, next_local),
            .scrutinee = remapLocal(sl.scrutinee, local_map),
            .cases = try cloneLitCases(allocator, sl.cases, local_map, next_local),
            .default_instrs = try cloneInstructionSlice(allocator, sl.default_instrs, local_map, next_local),
            .default_result = if (sl.default_result) |result| remapLocal(result, local_map) else null,
        } },
        .switch_return => |sr| .{ .switch_return = .{
            .scrutinee_param = sr.scrutinee_param,
            .cases = try cloneReturnCases(allocator, sr.cases, local_map, next_local),
            .default_instrs = try cloneInstructionSlice(allocator, sr.default_instrs, local_map, next_local),
            .default_result = if (sr.default_result) |result| remapLocal(result, local_map) else null,
        } },
        .case_block => |cb| .{ .case_block = .{
            .dest = try remapDest(cb.dest, local_map, next_local),
            .pre_instrs = try cloneInstructionSlice(allocator, cb.pre_instrs, local_map, next_local),
            .arms = try cloneCaseArms(allocator, cb.arms, local_map, next_local),
            .default_instrs = try cloneInstructionSlice(allocator, cb.default_instrs, local_map, next_local),
            .default_result = if (cb.default_result) |result| remapLocal(result, local_map) else null,
        } },
        else => error.UnsupportedContifiedRewrite,
    };
}

fn cloneInstructionSlice(
    allocator: std.mem.Allocator,
    instrs: []const ir.Instruction,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) anyerror![]const ir.Instruction {
    const out = try allocator.alloc(ir.Instruction, instrs.len);
    for (instrs, 0..) |instr, i| {
        out[i] = try cloneInstruction(allocator, instr, local_map, next_local);
    }
    return out;
}

fn remapLocalSlice(allocator: std.mem.Allocator, slice: []const ir.LocalId, local_map: *const std.AutoHashMap(ir.LocalId, ir.LocalId)) ![]const ir.LocalId {
    const out = try allocator.alloc(ir.LocalId, slice.len);
    for (slice, 0..) |local, i| out[i] = remapLocal(local, local_map);
    return out;
}

fn cloneStructFields(allocator: std.mem.Allocator, fields: []const ir.StructFieldInit, local_map: *const std.AutoHashMap(ir.LocalId, ir.LocalId)) ![]const ir.StructFieldInit {
    const out = try allocator.alloc(ir.StructFieldInit, fields.len);
    for (fields, 0..) |field, i| {
        out[i] = .{ .name = try allocator.dupe(u8, field.name), .value = remapLocal(field.value, local_map) };
    }
    return out;
}

fn cloneLitCases(
    allocator: std.mem.Allocator,
    cases: []const ir.LitCase,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) anyerror![]const ir.LitCase {
    const out = try allocator.alloc(ir.LitCase, cases.len);
    for (cases, 0..) |case, i| {
        out[i] = .{
            .value = try cloneLiteralValue(allocator, case.value),
            .body_instrs = try cloneInstructionSlice(allocator, case.body_instrs, local_map, next_local),
            .result = if (case.result) |result| remapLocal(result, local_map) else null,
        };
    }
    return out;
}

fn cloneReturnCases(
    allocator: std.mem.Allocator,
    cases: []const ir.ReturnCase,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) anyerror![]const ir.ReturnCase {
    const out = try allocator.alloc(ir.ReturnCase, cases.len);
    for (cases, 0..) |case, i| {
        out[i] = .{
            .value = try cloneLiteralValue(allocator, case.value),
            .body_instrs = try cloneInstructionSlice(allocator, case.body_instrs, local_map, next_local),
            .return_value = if (case.return_value) |value| remapLocal(value, local_map) else null,
        };
    }
    return out;
}

fn cloneCaseArms(
    allocator: std.mem.Allocator,
    arms: []const ir.IrCaseArm,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) anyerror![]const ir.IrCaseArm {
    const out = try allocator.alloc(ir.IrCaseArm, arms.len);
    for (arms, 0..) |arm, i| {
        out[i] = .{
            .cond_instrs = try cloneInstructionSlice(allocator, arm.cond_instrs, local_map, next_local),
            .condition = remapLocal(arm.condition, local_map),
            .body_instrs = try cloneInstructionSlice(allocator, arm.body_instrs, local_map, next_local),
            .result = if (arm.result) |result| remapLocal(result, local_map) else null,
        };
    }
    return out;
}

fn cloneLiteralValue(allocator: std.mem.Allocator, value: ir.LiteralValue) !ir.LiteralValue {
    return switch (value) {
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .bool_val => |v| .{ .bool_val = v },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
    };
}

fn remapDest(
    local: ir.LocalId,
    local_map: *std.AutoHashMap(ir.LocalId, ir.LocalId),
    next_local: *ir.LocalId,
) !ir.LocalId {
    if (local_map.get(local)) |mapped| return mapped;
    const mapped = next_local.* + 1;
    next_local.* = mapped;
    try local_map.put(local, mapped);
    return mapped;
}

fn remapLocal(local: ir.LocalId, local_map: *const std.AutoHashMap(ir.LocalId, ir.LocalId)) ir.LocalId {
    return local_map.get(local) orelse local;
}

fn maxLocalInFunction(caller_instrs: []const ir.Instruction, callee_instrs: []const ir.Instruction) ir.LocalId {
    var max_local: ir.LocalId = 0;
    for (caller_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    for (callee_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    return max_local;
}

fn maxLocalInInstruction(instr: ir.Instruction) ir.LocalId {
    return switch (instr) {
        .const_int => |ci| ci.dest,
        .const_float => |cf| cf.dest,
        .const_string => |cs| cs.dest,
        .const_bool => |cb| cb.dest,
        .const_atom => |ca| ca.dest,
        .const_nil => |dest| dest,
        .local_get => |lg| @max(lg.dest, lg.source),
        .local_set => |ls| @max(ls.dest, ls.value),
        .move_value => |mv| @max(mv.dest, mv.source),
        .share_value => |sv| @max(sv.dest, sv.source),
        .binary_op => |bo| @max(bo.dest, @max(bo.lhs, bo.rhs)),
        .unary_op => |uo| @max(uo.dest, uo.operand),
        .param_get => |pg| pg.dest,
        .capture_get => |cg| cg.dest,
        .field_get => |fg| @max(fg.dest, fg.object),
        .index_get => |ig| @max(ig.dest, ig.object),
        .tuple_init => |ti| maxLocalSlice(ti.dest, ti.elements),
        .list_init => |li| maxLocalSlice(li.dest, li.elements),
        .struct_init => |si| maxStructInitLocal(si),
        .union_init => |ui| @max(ui.dest, ui.value),
        .enum_literal => |el| el.dest,
        .call_direct => |cd| maxLocalSlice(cd.dest, cd.args),
        .call_named => |cn| maxLocalSlice(cn.dest, cn.args),
        .call_builtin => |cb| maxLocalSlice(cb.dest, cb.args),
        .optional_unwrap => |ou| @max(ou.dest, ou.source),
        .if_expr => |ie| maxIfExprLocal(ie),
        .switch_literal => |sl| maxSwitchLiteralLocal(sl),
        .switch_return => |sr| maxSwitchReturnLocal(sr),
        .case_block => |cb| maxCaseBlockLocal(cb),
        .call_closure => |cc| cc.dest,
        .ret => |ret| ret.value orelse 0,
        else => 0,
    };
}

fn maxLocalSlice(dest: ir.LocalId, slice: []const ir.LocalId) ir.LocalId {
    var max_local = dest;
    for (slice) |local| max_local = @max(max_local, local);
    return max_local;
}

fn maxStructInitLocal(si: ir.StructInit) ir.LocalId {
    var max_local = si.dest;
    for (si.fields) |field| max_local = @max(max_local, field.value);
    return max_local;
}

fn maxIfExprLocal(ie: ir.IfExpr) ir.LocalId {
    var max_local = @max(ie.dest, ie.condition);
    for (ie.then_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    for (ie.else_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    if (ie.then_result) |result| max_local = @max(max_local, result);
    if (ie.else_result) |result| max_local = @max(max_local, result);
    return max_local;
}

fn maxSwitchLiteralLocal(sl: ir.SwitchLiteral) ir.LocalId {
    var max_local = @max(sl.dest, sl.scrutinee);
    for (sl.cases) |case| {
        for (case.body_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
        if (case.result) |result| max_local = @max(max_local, result);
    }
    for (sl.default_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    if (sl.default_result) |result| max_local = @max(max_local, result);
    return max_local;
}

fn maxSwitchReturnLocal(sr: ir.SwitchReturn) ir.LocalId {
    var max_local: ir.LocalId = 0;
    for (sr.cases) |case| {
        for (case.body_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
        if (case.return_value) |value| max_local = @max(max_local, value);
    }
    for (sr.default_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    if (sr.default_result) |value| max_local = @max(max_local, value);
    return max_local;
}

fn maxCaseBlockLocal(cb: ir.CaseBlock) ir.LocalId {
    var max_local = cb.dest;
    for (cb.pre_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    for (cb.arms) |arm| {
        for (arm.cond_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
        max_local = @max(max_local, arm.condition);
        for (arm.body_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
        if (arm.result) |result| max_local = @max(max_local, result);
    }
    for (cb.default_instrs) |instr| max_local = @max(max_local, maxLocalInInstruction(instr));
    if (cb.default_result) |result| max_local = @max(max_local, result);
    return max_local;
}

fn maxLabel(program: *const ir.Program) ir.LabelId {
    var max_label: ir.LabelId = 0;
    for (program.functions) |func| {
        for (func.body) |block| {
            max_label = @max(max_label, block.label);
        }
    }
    return max_label;
}

fn isStraightLineSuffix(instrs: []const ir.Instruction) bool {
    for (instrs) |instr| {
        switch (instr) {
            .branch, .cond_branch, .jump, .switch_tag, .switch_literal, .switch_return, .union_switch_return, .union_switch => return false,
            else => {},
        }
    }
    return true;
}

test "rewrite contified non-tail call into continuation jump" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{2}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 3, .value = 1 } },
        .{ .binary_op = .{ .dest = 4, .op = .add, .lhs = 1, .rhs = 3 } },
        .{ .ret = .{ .value = 4 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const closure_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 2 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "add_two", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    try std.testing.expectEqual(@as(usize, 2), program.functions[0].body.len);
    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[3]));
    const jump = rewritten[3].jump;
    try std.testing.expectEqual(@as(?ir.LocalId, 6), jump.value);
    try std.testing.expectEqual(@as(?ir.LocalId, 1), jump.bind_dest);
    try std.testing.expectEqual(program.functions[0].body[1].label, jump.target);
}

test "rewrite contified capturing closure into continuation jump" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const captures = [_]ir.LocalId{2};
    const main_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 2, .value = 40 } },
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &captures } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{3}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 4, .value = 1 } },
        .{ .binary_op = .{ .dest = 5, .op = .add, .lhs = 1, .rhs = 4 } },
        .{ .ret = .{ .value = 5 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .param_get = .{ .dest = 1, .index = 0 } },
        .{ .binary_op = .{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 } },
        .{ .ret = .{ .value = 2 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};
    const closure_captures = [_]ir.Capture{.{ .name = "cap", .type_expr = .i64, .ownership = .shared }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "add_cap", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &closure_captures },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 2 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .binary_op), std.meta.activeTag(rewritten[2]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[3]));
    try std.testing.expectEqual(@as(?ir.LocalId, 1), rewritten[3].jump.bind_dest);
}

test "rewrite contified closure supports field get and direct call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const struct_fields = [_]ir.StructFieldInit{.{ .name = "first", .value = 2 }};
    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 2, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{4}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 6, .value = 1 } },
        .{ .binary_op = .{ .dest = 7, .op = .add, .lhs = 1, .rhs = 6 } },
        .{ .ret = .{ .value = 7 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};

    const helper_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const helper_blocks = [_]ir.Block{.{ .label = 2, .instructions = &helper_instrs }};
    const helper_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const closure_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 5 } },
        .{ .struct_init = .{ .dest = 1, .type_name = "Pair", .fields = &struct_fields } },
        .{ .field_get = .{ .dest = 2, .object = 1, .field = "first" } },
        .{ .call_direct = .{ .dest = 3, .function = 1, .args = &[_]ir.LocalId{2}, .arg_modes = &[_]ir.ValueMode{.share} } },
        .{ .ret = .{ .value = 3 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 0, .params = &.{}, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "id", .scope_id = 0, .arity = 1, .params = &helper_params, .return_type = .i64, .body = &helper_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 2, .name = "closure_fn", .scope_id = 0, .arity = 1, .params = &helper_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 2;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .struct_init), std.meta.activeTag(rewritten[2]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .field_get), std.meta.activeTag(rewritten[3]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .call_direct), std.meta.activeTag(rewritten[4]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[5]));
}

test "rewrite contified closure supports if expr body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const then_instrs = [_]ir.Instruction{.{ .const_int = .{ .dest = 1, .value = 5 } }};
    const else_instrs = [_]ir.Instruction{.{ .const_int = .{ .dest = 2, .value = 7 } }};

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{3}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 4, .value = 1 } },
        .{ .binary_op = .{ .dest = 5, .op = .add, .lhs = 1, .rhs = 4 } },
        .{ .ret = .{ .value = 5 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    const closure_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .if_expr = .{
            .dest = 3,
            .condition = 0,
            .then_instrs = &then_instrs,
            .then_result = 1,
            .else_instrs = &else_instrs,
            .else_result = 2,
        } },
        .{ .ret = .{ .value = 3 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "pick", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .if_expr), std.meta.activeTag(rewritten[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[2]));
}

test "rewrite contified closure supports switch literal body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const case_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 1, .value = 5 } }};
    const default_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 2, .value = 7 } }};
    const cases = [_]ir.LitCase{.{ .value = .{ .bool_val = true }, .body_instrs = &case_body, .result = 1 }};

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{3}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 4, .value = 1 } },
        .{ .binary_op = .{ .dest = 5, .op = .add, .lhs = 1, .rhs = 4 } },
        .{ .ret = .{ .value = 5 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    const closure_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .switch_literal = .{ .dest = 3, .scrutinee = 0, .cases = &cases, .default_instrs = &default_body, .default_result = 2 } },
        .{ .ret = .{ .value = 3 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "pick", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .switch_literal), std.meta.activeTag(rewritten[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[2]));
}

test "rewrite contified closure supports case block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arm0_cond = [_]ir.Instruction{.{ .const_bool = .{ .dest = 1, .value = true } }};
    const arm0_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 2, .value = 5 } }};
    const arm1_cond = [_]ir.Instruction{.{ .const_bool = .{ .dest = 3, .value = false } }};
    const arm1_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 4, .value = 7 } }};
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &arm0_cond, .condition = 1, .body_instrs = &arm0_body, .result = 2 },
        .{ .cond_instrs = &arm1_cond, .condition = 3, .body_instrs = &arm1_body, .result = 4 },
    };

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{5}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .const_int = .{ .dest = 6, .value = 1 } },
        .{ .binary_op = .{ .dest = 7, .op = .add, .lhs = 1, .rhs = 6 } },
        .{ .ret = .{ .value = 7 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    const closure_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .case_block = .{ .dest = 8, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
        .{ .ret = .{ .value = 8 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "pick", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    const rewritten = program.functions[0].body[0].instructions;
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .case_block), std.meta.activeTag(rewritten[1]));
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .jump), std.meta.activeTag(rewritten[2]));
}

test "rewrite skips contified closure with multi-block body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{2}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .ret = .{ .value = 1 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const closure_block0_instrs = [_]ir.Instruction{.{ .param_get = .{ .dest = 0, .index = 0 } }};
    const closure_block1_instrs = [_]ir.Instruction{.{ .ret = .{ .value = 0 } }};
    const closure_blocks = [_]ir.Block{
        .{ .label = 1, .instructions = &closure_block0_instrs },
        .{ .label = 2, .instructions = &closure_block1_instrs },
    };
    const closure_params = [_]ir.Param{.{ .name = "y", .type_expr = .i64 }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "multi", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .i64, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    try std.testing.expectEqual(@as(usize, 1), program.functions[0].body.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .call_closure), std.meta.activeTag(program.functions[0].body[0].instructions[1]));
}

test "rewrite skips contified closure with unsupported continuation suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const switch_cases = [_]ir.LitCase{.{
        .value = .{ .bool_val = true },
        .body_instrs = &[_]ir.Instruction{.{ .const_int = .{ .dest = 3, .value = 1 } }},
        .result = 3,
    }};

    const main_instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 0, .function = 1, .captures = &.{} } },
        .{ .call_closure = .{ .dest = 1, .callee = 0, .args = &[_]ir.LocalId{2}, .arg_modes = &[_]ir.ValueMode{.share}, .return_type = .i64 } },
        .{ .switch_literal = .{ .dest = 4, .scrutinee = 2, .cases = &switch_cases, .default_instrs = &.{}, .default_result = null } },
        .{ .ret = .{ .value = 4 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    const closure_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 1, .instructions = &closure_instrs }};
    const closure_params = [_]ir.Param{.{ .name = "flag", .type_expr = .bool_type }};

    var functions = [_]ir.Function{
        .{ .id = 0, .name = "main", .scope_id = 0, .arity = 1, .params = &params, .return_type = .i64, .body = &main_blocks, .is_closure = false, .captures = &.{} },
        .{ .id = 1, .name = "id", .scope_id = 0, .arity = 1, .params = &closure_params, .return_type = .bool_type, .body = &closure_blocks, .is_closure = true, .captures = &.{} },
    };
    var program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var ctx = lattice.AnalysisContext.init(allocator);
    defer ctx.deinit();
    const members = try allocator.alloc(ir.FunctionId, 1);
    members[0] = 1;
    try ctx.call_specializations.put(.{ .function = 0, .block = 0, .instr_index = 1 }, .{
        .decision = .contified,
        .lambda_set = .{ .members = members },
    });

    try rewriteContifiedContinuations(allocator, &program, &ctx);

    try std.testing.expectEqual(@as(usize, 1), program.functions[0].body.len);
    try std.testing.expectEqual(@as(std.meta.Tag(ir.Instruction), .call_closure), std.meta.activeTag(program.functions[0].body[0].instructions[1]));
}
