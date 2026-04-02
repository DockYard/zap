const std = @import("std");
const ir = @import("ir.zig");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");

// ============================================================
// Zig source code generator (spec §22.1)
//
// Emits canonical Zig source from the Zig-shaped IR.
// Stage 1: plain Zig source for correctness and debugging.
// ============================================================

pub const CodeGen = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    indent_level: u32,
    referenced_locals: std.ArrayListUnmanaged(ir.LocalId),
    current_fn_is_void: bool,
    current_fn_params: []const ir.Param,
    next_block_label: u32,
    current_case_label: ?[]const u8,
    lib_mode: bool,
    function_names: std.AutoHashMap(ir.FunctionId, []const u8),
    function_defs: std.AutoHashMap(ir.FunctionId, *const ir.Function),
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext,
    current_function_id: ir.FunctionId,
    current_block_label: ir.LabelId,
    current_instr_index: u32,
    current_block_instructions: []const ir.Instruction,
    skip_next_ret_local: ?ir.LocalId,
    reuse_backed_struct_locals: std.AutoHashMap(ir.LocalId, []const u8),
    reuse_backed_union_locals: std.AutoHashMap(ir.LocalId, ir.UnionInit),
    reuse_backed_tuple_locals: std.AutoHashMap(ir.LocalId, usize),

    pub fn init(allocator: std.mem.Allocator) CodeGen {
        return .{
            .allocator = allocator,
            .output = .empty,
            .indent_level = 0,
            .referenced_locals = .empty,
            .current_fn_is_void = false,
            .current_fn_params = &.{},
            .next_block_label = 0,
            .current_case_label = null,
            .lib_mode = false,
            .function_names = std.AutoHashMap(ir.FunctionId, []const u8).init(allocator),
            .function_defs = std.AutoHashMap(ir.FunctionId, *const ir.Function).init(allocator),
            .analysis_context = null,
            .current_function_id = 0,
            .current_block_label = 0,
            .current_instr_index = 0,
            .current_block_instructions = &.{},
            .skip_next_ret_local = null,
            .reuse_backed_struct_locals = std.AutoHashMap(ir.LocalId, []const u8).init(allocator),
            .reuse_backed_union_locals = std.AutoHashMap(ir.LocalId, ir.UnionInit).init(allocator),
            .reuse_backed_tuple_locals = std.AutoHashMap(ir.LocalId, usize).init(allocator),
        };
    }

    pub fn deinit(self: *CodeGen) void {
        self.output.deinit(self.allocator);
        self.referenced_locals.deinit(self.allocator);
        self.function_names.deinit();
        self.function_defs.deinit();
        self.reuse_backed_struct_locals.deinit();
        self.reuse_backed_union_locals.deinit();
        self.reuse_backed_tuple_locals.deinit();
    }

    pub fn getOutput(self: *const CodeGen) []const u8 {
        return self.output.items;
    }

    /// Check if ARC operations should be skipped for a value.
    /// Only skips when the value was explicitly analyzed and found stack-eligible.
    fn shouldSkipArc(self: *const CodeGen, local: ir.LocalId) bool {
        if (self.analysis_context) |actx| {
            const lattice = @import("escape_lattice.zig");
            const vkey = lattice.ValueKey{
                .function = self.current_function_id,
                .local = local,
            };
            if (actx.escape_states.get(vkey)) |state| {
                return state.isStackEligible();
            }
        }
        return false;
    }

    fn findReusePairForDest(self: *const CodeGen, dest: ir.LocalId) ?@import("escape_lattice.zig").ReusePair {
        if (self.analysis_context) |actx| {
            for (actx.reuse_pairs.items) |pair| {
                if (pair.reuse.dest != dest) continue;
                const insertion_point = pair.reuse.insertion_point;
                if (insertion_point.function != self.current_function_id) continue;
                if (insertion_point.block != self.current_block_label) continue;
                if (insertion_point.instr_index != self.current_instr_index) continue;
                if (insertion_point.position != .before) continue;
                return pair;
            }
        }
        return null;
    }

    fn markReuseBackedStructLocal(self: *CodeGen, dest: ir.LocalId, type_name: []const u8) !void {
        try self.reuse_backed_struct_locals.put(dest, type_name);
    }

    fn propagateReuseBackedStructLocal(self: *CodeGen, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_struct_locals.get(source)) |type_name| {
            try self.reuse_backed_struct_locals.put(dest, type_name);
        } else {
            _ = self.reuse_backed_struct_locals.remove(dest);
        }
    }

    fn isReuseBackedStructLocal(self: *const CodeGen, local: ir.LocalId) bool {
        return self.reuse_backed_struct_locals.contains(local);
    }

    fn markReuseBackedUnionLocal(self: *CodeGen, union_init: ir.UnionInit) !void {
        try self.reuse_backed_union_locals.put(union_init.dest, union_init);
    }

    fn propagateReuseBackedUnionLocal(self: *CodeGen, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_union_locals.get(source)) |union_init| {
            var copied = union_init;
            copied.dest = dest;
            try self.reuse_backed_union_locals.put(dest, copied);
        } else {
            _ = self.reuse_backed_union_locals.remove(dest);
        }
    }

    fn isReuseBackedUnionLocal(self: *const CodeGen, local: ir.LocalId) bool {
        return self.reuse_backed_union_locals.contains(local);
    }

    fn markReuseBackedTupleLocal(self: *CodeGen, dest: ir.LocalId, arity: usize) !void {
        try self.reuse_backed_tuple_locals.put(dest, arity);
    }

    fn propagateReuseBackedTupleLocal(self: *CodeGen, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_tuple_locals.get(source)) |arity| {
            try self.reuse_backed_tuple_locals.put(dest, arity);
        } else {
            _ = self.reuse_backed_tuple_locals.remove(dest);
        }
    }

    fn isReuseBackedTupleLocal(self: *const CodeGen, local: ir.LocalId) bool {
        return self.reuse_backed_tuple_locals.contains(local);
    }

    const ClosureAllocation = enum { stack, heap };

    fn getClosureTier(self: *const CodeGen, function_id: ir.FunctionId) @import("escape_lattice.zig").ClosureEnvTier {
        if (self.analysis_context) |actx| return actx.getClosureTier(function_id);
        return .escaping;
    }

    fn closureEnvPrefix(self: *const CodeGen, function_id: ir.FunctionId) []const u8 {
        return switch (self.getClosureTier(function_id)) {
            .block_local => "__block_env_",
            .function_local => "__frame_env_",
            else => "__env_",
        };
    }

    const ClosureTarget = struct {
        function_id: ir.FunctionId,
        captures: []const ir.LocalId,
    };

    fn getClosureAllocation(self: *const CodeGen, function_id: ir.FunctionId) ClosureAllocation {
        return switch (self.getClosureTier(function_id)) {
            .lambda_lifted, .immediate_invocation, .block_local, .function_local => .stack,
            .escaping => .heap,
        };
    }

    fn getCallSiteSpecialization(self: *const CodeGen) ?@import("escape_lattice.zig").CallSiteSpecialization {
        if (self.analysis_context) |actx| {
            return actx.getCallSiteSpecialization(.{
                .function = self.current_function_id,
                .block = self.current_block_label,
                .instr_index = self.current_instr_index,
            });
        }
        return null;
    }

    fn findClosureTarget(self: *const CodeGen, local: ir.LocalId) ?ClosureTarget {
        const func = self.function_defs.get(self.current_function_id) orelse return null;
        return self.findClosureTargetInInstrs(func.body, local);
    }

    fn isParamDerivedClosure(self: *const CodeGen, local: ir.LocalId) bool {
        const func = self.function_defs.get(self.current_function_id) orelse return false;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .param_get => |pg| if (pg.dest == local) return true,
                    else => {},
                }
            }
        }
        return false;
    }

    fn findClosureTargetInInstrs(self: *const CodeGen, blocks: []const ir.Block, local: ir.LocalId) ?ClosureTarget {
        _ = self;
        for (blocks) |block| {
            if (findClosureTargetInList(block.instructions, local)) |target| return target;
        }
        return null;
    }

    fn findClosureTargetInList(instrs: []const ir.Instruction, local: ir.LocalId) ?ClosureTarget {
        return findClosureTargetInListDepth(instrs, local, 0);
    }

    fn findClosureTargetInListDepth(instrs: []const ir.Instruction, local: ir.LocalId, depth: u8) ?ClosureTarget {
        if (depth > 32) return null;
        for (instrs) |instr| {
            switch (instr) {
                .make_closure => |mc| {
                    if (mc.dest == local) {
                        return .{ .function_id = mc.function, .captures = mc.captures };
                    }
                },
                .local_get => |lg| if (lg.dest == local) {
                    if (findClosureTargetInListDepth(instrs, lg.source, depth + 1)) |target| return target;
                },
                .local_set => |ls| if (ls.dest == local) {
                    if (findClosureTargetInListDepth(instrs, ls.value, depth + 1)) |target| return target;
                },
                .move_value => |mv| if (mv.dest == local) {
                    if (findClosureTargetInListDepth(instrs, mv.source, depth + 1)) |target| return target;
                },
                .share_value => |sv| if (sv.dest == local) {
                    if (findClosureTargetInListDepth(instrs, sv.source, depth + 1)) |target| return target;
                },
                .if_expr => |ie| {
                    if (findClosureTargetInListDepth(ie.then_instrs, local, depth)) |target| return target;
                    if (findClosureTargetInListDepth(ie.else_instrs, local, depth)) |target| return target;
                },
                .case_block => |cb| {
                    if (findClosureTargetInListDepth(cb.pre_instrs, local, depth)) |target| return target;
                    for (cb.arms) |arm| {
                        if (findClosureTargetInListDepth(arm.cond_instrs, local, depth)) |target| return target;
                        if (findClosureTargetInListDepth(arm.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInListDepth(cb.default_instrs, local, depth)) |target| return target;
                },
                .guard_block => |gb| {
                    if (findClosureTargetInListDepth(gb.body, local, depth)) |target| return target;
                },
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        if (findClosureTargetInListDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInListDepth(sl.default_instrs, local, depth)) |target| return target;
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| {
                        if (findClosureTargetInListDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInListDepth(sr.default_instrs, local, depth)) |target| return target;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| {
                        if (findClosureTargetInListDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn closureInvokeName(self: *const CodeGen, function_id: ir.FunctionId) ?[]const u8 {
        _ = self.function_defs.get(function_id) orelse return null;
        const tier = if (self.analysis_context) |actx| actx.getClosureTier(function_id) else @import("escape_lattice.zig").ClosureEnvTier.escaping;
        if (!self.functionNeedsClosureWrapper(function_id) and tier == .lambda_lifted) return null;
        if (!self.functionNeedsClosureWrapper(function_id) and tier == .immediate_invocation) return null;
        return std.fmt.allocPrint(self.allocator, "__closure_invoke_{d}", .{function_id}) catch null;
    }

    fn functionNeedsClosureWrapper(self: *const CodeGen, function_id: ir.FunctionId) bool {
        if (self.function_defs.get(function_id)) |func| {
            if (func.is_closure or func.captures.len > 0) return true;
        }
        var func_iter = self.function_defs.iterator();
        while (func_iter.next()) |entry| {
            for (entry.value_ptr.*.body) |block| {
                if (self.blockCreatesClosureForFunction(block.instructions, function_id)) return true;
            }
        }
        return false;
    }

    fn blockCreatesClosureForFunction(self: *const CodeGen, instrs: []const ir.Instruction, function_id: ir.FunctionId) bool {
        for (instrs) |instr| {
            switch (instr) {
                .make_closure => |mc| if (mc.function == function_id) return true,
                .if_expr => |ie| {
                    if (self.blockCreatesClosureForFunction(ie.then_instrs, function_id)) return true;
                    if (self.blockCreatesClosureForFunction(ie.else_instrs, function_id)) return true;
                },
                .case_block => |cb| {
                    if (self.blockCreatesClosureForFunction(cb.pre_instrs, function_id)) return true;
                    for (cb.arms) |arm| {
                        if (self.blockCreatesClosureForFunction(arm.cond_instrs, function_id)) return true;
                        if (self.blockCreatesClosureForFunction(arm.body_instrs, function_id)) return true;
                    }
                    if (self.blockCreatesClosureForFunction(cb.default_instrs, function_id)) return true;
                },
                .guard_block => |gb| if (self.blockCreatesClosureForFunction(gb.body, function_id)) return true,
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        if (self.blockCreatesClosureForFunction(case.body_instrs, function_id)) return true;
                    }
                    if (self.blockCreatesClosureForFunction(sl.default_instrs, function_id)) return true;
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| {
                        if (self.blockCreatesClosureForFunction(case.body_instrs, function_id)) return true;
                    }
                    if (self.blockCreatesClosureForFunction(sr.default_instrs, function_id)) return true;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| {
                        if (self.blockCreatesClosureForFunction(case.body_instrs, function_id)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn emitDirectClosureCall(self: *CodeGen, dest: ir.LocalId, target: ClosureTarget, args: []const ir.LocalId) !bool {
        const target_name = self.function_names.get(target.function_id) orelse return false;
        try self.writeIndent();
        try self.writeDestLocal(dest);
        try self.write(" = ");
        try self.write(target_name);
        try self.write("(");
        for (target.captures, 0..) |capture, i| {
            if (i > 0) try self.write(", ");
            try self.writeValueLocal(capture);
        }
        for (args, 0..) |arg, i| {
            if (target.captures.len > 0 or i > 0) try self.write(", ");
            try self.writeValueLocal(arg);
        }
        try self.write(");\n");
        return true;
    }

    fn emitInvokeWrapperCall(self: *CodeGen, dest: ir.LocalId, callee: ir.LocalId, function_id: ir.FunctionId, args: []const ir.LocalId) !bool {
        const invoke_name = self.closureInvokeName(function_id) orelse return false;
        defer self.allocator.free(invoke_name);
        try self.writeIndent();
        try self.writeDestLocal(dest);
        try self.write(" = ");
        try self.write(invoke_name);
        try self.write("(");
        try self.writeLocal(callee);
        try self.write(".env, .{");
        if (self.function_defs.get(function_id)) |func_def| {
            for (func_def.params, 0..) |param, i| {
                if (i > 0) try self.write(", ");
                try self.write(".");
                try self.write(param.name);
                try self.write(" = ");
                if (i < args.len) {
                    try self.writeLocal(args[i]);
                } else {
                    try self.write("undefined");
                }
            }
        }
        try self.write(" });\n");
        return true;
    }

    fn emitTailDirectClosureCall(self: *CodeGen, target: ClosureTarget, args: []const ir.LocalId) !bool {
        const target_name = self.function_names.get(target.function_id) orelse return false;
        try self.writeIndent();
        try self.write("return @call(.always_tail, ");
        try self.write(target_name);
        try self.write(", .{");
        for (target.captures, 0..) |capture, i| {
            if (i > 0) try self.write(", ");
            try self.writeValueLocal(capture);
        }
        for (args, 0..) |arg, i| {
            if (target.captures.len > 0 or i > 0) try self.write(", ");
            try self.writeValueLocal(arg);
        }
        try self.write("});\n");
        return true;
    }

    fn emitTailInvokeWrapperCall(self: *CodeGen, callee: ir.LocalId, function_id: ir.FunctionId, args: []const ir.LocalId) !bool {
        const invoke_name = self.closureInvokeName(function_id) orelse return false;
        defer self.allocator.free(invoke_name);
        try self.writeIndent();
        try self.write("return @call(.always_tail, ");
        try self.write(invoke_name);
        try self.write(", .{");
        try self.writeLocal(callee);
        try self.write(".env, .{");
        if (self.function_defs.get(function_id)) |func_def| {
            for (func_def.params, 0..) |param, i| {
                if (i > 0) try self.write(", ");
                try self.write(".");
                try self.write(param.name);
                try self.write(" = ");
                if (i < args.len) try self.writeValueLocal(args[i]) else try self.write("undefined");
            }
        }
        try self.write(" }});\n");
        return true;
    }

    fn isTailReturnOf(self: *const CodeGen, local: ir.LocalId) bool {
        const next_idx = @as(usize, self.current_instr_index) + 1;
        if (next_idx >= self.current_block_instructions.len) return false;
        return switch (self.current_block_instructions[next_idx]) {
            .ret => |r| r.value != null and r.value.? == local,
            else => false,
        };
    }

    fn emitAnalysisArcOps(self: *CodeGen, before: bool) !void {
        if (self.analysis_context) |actx| {
            for (actx.arc_ops.items) |op| {
                if (op.insertion_point.function != self.current_function_id) continue;
                if (op.insertion_point.block != self.current_block_label) continue;
                if (op.insertion_point.instr_index != self.current_instr_index) continue;
                if ((op.insertion_point.position == .before) != before) continue;
                switch (op.kind) {
                    .retain => {
                        if (!self.shouldSkipArc(op.value)) {
                            try self.writeIndent();
                            try self.write("zap_runtime.ArcRuntime.retainAny(@TypeOf(");
                            try self.writeLocal(op.value);
                            try self.write("), ");
                            try self.writeLocal(op.value);
                            try self.write(");\n");
                        }
                    },
                    .release => {
                        if (op.reason == .perceus_drop) continue;
                        if (!self.shouldSkipArc(op.value)) {
                            try self.writeIndent();
                            try self.write("zap_runtime.ArcRuntime.releaseAny(@TypeOf(");
                            try self.writeLocal(op.value);
                            try self.write("), std.heap.page_allocator, ");
                            try self.writeLocal(op.value);
                            try self.write(");\n");
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn emitSwitchDispatch(self: *CodeGen, cc: ir.CallClosure, targets: []const ir.FunctionId) !bool {
        var emitted_any = false;
        for (targets, 0..) |target_id, i| {
            const invoke_name = self.closureInvokeName(target_id) orelse continue;
            defer self.allocator.free(invoke_name);
            emitted_any = true;
            try self.writeIndent();
            if (i == 0) {
                try self.write("if (");
            } else {
                try self.write("else if (");
            }
            try self.writeLocal(cc.callee);
            try self.write(".call_fn == @ptrCast(&");
            try self.write(invoke_name);
            try self.write(")) {\n");
            self.indent_level += 1;
            _ = try self.emitInvokeWrapperCall(cc.dest, cc.callee, target_id, cc.args);
            self.indent_level -= 1;
            try self.writeIndent();
            try self.write("} ");
        }

        if (!emitted_any) return false;

        try self.write("else {\n");
        self.indent_level += 1;
        try self.writeIndent();
        try self.writeDestLocal(cc.dest);
        try self.write(" = zap_runtime.invokeDynClosure(");
        try self.emitZigType(&cc.return_type);
        try self.write(", ");
        try self.writeLocal(cc.callee);
        try self.write(", .{");
        for (cc.args, 0..) |arg, i| {
            if (i > 0) try self.write(", ");
            try self.writeValueLocal(arg);
        }
        try self.write("});\n");
        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}\n");
        return true;
    }

    // ============================================================
    // Program emission
    // ============================================================

    pub fn emitProgram(self: *CodeGen, program: *const ir.Program) !void {
        for (program.functions) |*func| {
            try self.function_names.put(func.id, func.name);
            try self.function_defs.put(func.id, func);
        }
        // File header
        try self.write("// Generated by Zap compiler\n");
        try self.write("const std = @import(\"std\");\n");
        try self.write("const zap_runtime = @import(\"zap_runtime.zig\");\n");
        try self.write("\n");

        // Emit type definitions (structs, enums)
        for (program.type_defs) |td| {
            try self.emitTypeDef(&td);
            try self.write("\n");
        }

        for (program.functions) |func| {
            try self.emitFunction(&func);
            try self.write("\n");
        }
    }

    fn emitTypeDef(self: *CodeGen, td: *const ir.TypeDef) !void {
        switch (td.kind) {
            .struct_def => |sd| {
                try self.write("pub const ");
                try self.write(td.name);
                try self.write(" = struct {\n");
                self.indent_level += 1;
                for (sd.fields) |field| {
                    try self.writeIndent();
                    try self.write(field.name);
                    try self.write(": ");
                    try self.write(field.type_expr);
                    try self.write(",\n");
                }
                self.indent_level -= 1;
                try self.write("};\n");
            },
            .enum_def => |ed| {
                try self.write("pub const ");
                try self.write(td.name);
                try self.write(" = enum {\n");
                self.indent_level += 1;
                for (ed.variants) |variant| {
                    try self.writeIndent();
                    try self.write(variant);
                    try self.write(",\n");
                }
                self.indent_level -= 1;
                try self.write("};\n");
            },
            .union_def => |ud| {
                try self.write("pub const ");
                try self.write(td.name);
                try self.write(" = union(enum) {\n");
                self.indent_level += 1;
                for (ud.variants) |variant| {
                    try self.writeIndent();
                    try self.write(variant.name);
                    try self.write(": ");
                    try self.write(variant.type_name orelse "void");
                    try self.write(",\n");
                }
                self.indent_level -= 1;
                try self.write("};\n");
            },
        }
    }

    // ============================================================
    // Function emission
    // ============================================================

    fn emitFunction(self: *CodeGen, func: *const ir.Function) !void {
        self.current_function_id = func.id;
        self.reuse_backed_struct_locals.clearRetainingCapacity();
        self.reuse_backed_union_locals.clearRetainingCapacity();
        self.reuse_backed_tuple_locals.clearRetainingCapacity();
        const is_main = std.mem.eql(u8, func.name, "main") or
            std.mem.endsWith(u8, func.name, "__main");
        const closure_alloc = self.getClosureAllocation(func.id);
        // Call-local closures (immediate_invocation / lambda_lifted) don't need
        // wrapper infrastructure — captures are forwarded as arguments.
        const closure_tier = self.getClosureTier(func.id);
        const needs_closure_wrappers = (func.is_closure or func.captures.len > 0) and
            closure_tier != .lambda_lifted and closure_tier != .immediate_invocation;
        const needs_release_wrapper = needs_closure_wrappers and closure_alloc == .heap;

        if (!is_main and needs_closure_wrappers) {
            try self.write("const __closure_env_");
            try self.writeInt(@intCast(func.id));
            try self.write(" = struct { ");
            for (func.captures, 0..) |capture, i| {
                if (i > 0) try self.write(", ");
                try self.write(capture.name);
                try self.write(": ");
                try self.emitZigType(&capture.type_expr);
            }
            try self.write(" };\n");
        }

        if (!is_main and needs_closure_wrappers) {
            try self.write("fn __closure_invoke_");
            try self.writeInt(@intCast(func.id));
            try self.write("(env_ptr: ?*anyopaque, args: struct {");
            for (func.params, 0..) |param, i| {
                if (i > 0) try self.write(", ");
                try self.write(param.name);
                try self.write(": ");
                try self.emitZigType(&param.type_expr);
            }
            try self.write(" }) ");
            try self.emitZigType(&func.return_type);
            try self.write(" {\n");
            self.indent_level += 1;
            if (func.captures.len > 0) {
                try self.writeIndent();
                try self.write("const env: *__closure_env_");
                try self.writeInt(@intCast(func.id));
                try self.write(" = @ptrCast(@alignCast(env_ptr.?));\n");
            }
            try self.writeIndent();
            if (func.return_type == .void) {
                try self.write(func.name);
            } else {
                try self.write("return ");
                try self.write(func.name);
            }
            try self.write("(");
            for (func.captures, 0..) |capture, i| {
                if (i > 0) try self.write(", ");
                try self.write("env.");
                try self.write(capture.name);
            }
            for (func.params, 0..) |param, i| {
                if (func.captures.len > 0 or i > 0) try self.write(", ");
                try self.write("args.");
                try self.write(param.name);
            }
            try self.write(");\n");
            self.indent_level -= 1;
            try self.write("}\n");
        }

        if (!is_main and needs_release_wrapper) {
            try self.write("fn __closure_release_");
            try self.writeInt(@intCast(func.id));
            try self.write("(env_ptr: *anyopaque) void {\n");
            self.indent_level += 1;
            try self.writeIndent();
            try self.write("const env: *__closure_env_");
            try self.writeInt(@intCast(func.id));
            try self.write(" = @ptrCast(@alignCast(env_ptr));\n");
            for (func.captures) |capture| {
                if (capture.ownership == .shared and capture.type_expr == .struct_ref) {
                    try self.writeIndent();
                    try self.write("zap_runtime.ArcRuntime.releaseAny(@TypeOf(env.");
                    try self.write(capture.name);
                    try self.write("), std.heap.page_allocator, &env.");
                    try self.write(capture.name);
                    try self.write(");\n");
                }
            }
            try self.writeIndent();
            try self.write("std.heap.page_allocator.destroy(env);\n");
            self.indent_level -= 1;
            try self.write("}\n\n");
        }

        // In library mode, skip main and make all other functions pub
        if (self.lib_mode and is_main) return;

        // main with parameters: emit as __zap_main, then generate a pub fn main() wrapper
        const main_has_params = is_main and func.params.len > 0;

        // Use inline fn when return type is inferred (.any) — Zig can't express
        // the return type of list-returning functions (*const [N]T) so we let
        // Zig infer it at each call site via inline.
        const use_inline = !is_main and func.return_type == .any;

        // Function signature
        if (is_main and !main_has_params) {
            try self.write("pub fn ");
        } else if (self.lib_mode) {
            try self.write("pub fn ");
        } else if (use_inline) {
            try self.write("inline fn ");
        } else {
            try self.write("fn ");
        }
        // Emit main as "main" regardless of module prefix (unless it has params)
        if (is_main and !main_has_params) {
            try self.write("main");
        } else if (main_has_params) {
            try self.write("__zap_main");
        } else {
            try self.write(func.name);
        }
        try self.write("(");

        for (func.captures, 0..) |capture, i| {
            if (i > 0) try self.write(", ");
            try self.write(capture.name);
            try self.write(": ");
            try self.emitZigType(&capture.type_expr);
        }

        for (func.params, 0..) |param, i| {
            if (func.captures.len > 0 or i > 0) try self.write(", ");
            try self.write(param.name);
            try self.write(": ");
            if (main_has_params) {
                // main's args param is always []const []const u8
                try self.write("[]const []const u8");
            } else {
                try self.emitZigType(&param.type_expr);
            }
        }

        try self.write(") ");
        if (is_main) {
            try self.write("void");
        } else if (use_inline) {
            // Emit a computed return type by scanning the body for the list_init
            try self.emitInferredListReturnType(func);
        } else {
            try self.emitZigType(&func.return_type);
        }
        self.current_fn_is_void = is_main or (func.return_type == .void and !use_inline);
        self.current_fn_params = func.params;
        try self.write(" {\n");
        self.indent_level += 1;

        // Suppress unused parameter errors in generated Zig.
        // Only discard params that are truly unreferenced in the body.
        for (func.params, 0..) |param, param_idx| {
            var used = false;
            for (func.body) |block| {
                if (self.isParamUsedInInstrs(block.instructions, @intCast(param_idx))) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                try self.writeIndent();
                try self.write("_ = ");
                try self.write(param.name);
                try self.write(";\n");
            }
        }

        // Emit body blocks
        for (func.body) |block| {
            try self.emitBlock(&block);
        }

        self.indent_level -= 1;
        try self.write("}\n");

        // Generate pub fn main() wrapper that collects process args
        if (main_has_params) {
            try self.write("\npub fn main() void {\n");
            self.indent_level += 1;
            try self.writeIndent();
            try self.write("const __args = std.process.argsAlloc(std.heap.page_allocator) catch &[_][]const u8{};\n");
            try self.writeIndent();
            // Skip the program name (first arg)
            try self.write("const __user_args = if (__args.len > 0) __args[1..] else __args[0..0];\n");
            try self.writeIndent();
            try self.write("__zap_main(__user_args);\n");
            self.indent_level -= 1;
            try self.write("}\n");
        }
    }

    fn emitBlock(self: *CodeGen, block: *const ir.Block) !void {
        self.current_block_label = block.label;
        self.current_block_instructions = block.instructions;
        // Collect which locals are referenced as sources
        self.referenced_locals = .empty;
        for (block.instructions) |instr| {
            self.collectReferencedLocals(&instr);
        }

        for (block.instructions, 0..) |instr, instr_idx| {
            self.current_instr_index = @intCast(instr_idx);
            try self.emitAnalysisArcOps(true);
            try self.emitInstruction(&instr);
            try self.emitAnalysisArcOps(false);
        }
    }

    fn emitDropSpecializationsForCurrentInstr(self: *CodeGen, value_local: ir.LocalId, constructor_tag: ?u32) !void {
        if (self.analysis_context) |actx| {
            for (actx.drop_specializations.items) |spec| {
                if (spec.function != self.current_function_id) continue;
                if (spec.insertion_point.block != self.current_block_label) continue;
                if (spec.insertion_point.instr_index != self.current_instr_index) continue;
                if (spec.insertion_point.position != .after) continue;
                if (constructor_tag) |tag| {
                    if (spec.constructor_tag != tag) continue;
                }
                for (spec.field_drops) |field_drop| {
                    const drop_local = field_drop.local orelse value_local;
                    try self.writeIndent();
                    try self.write("zap_runtime.ArcRuntime.releaseAny(@TypeOf(");
                    try self.writeLocal(drop_local);
                    try self.write("), std.heap.page_allocator, ");
                    try self.writeLocal(drop_local);
                    try self.write(");\n");
                }
            }
        }
    }

    fn isLocalReferenced(self: *const CodeGen, id: ir.LocalId) bool {
        for (self.referenced_locals.items) |ref_id| {
            if (ref_id == id) return true;
        }
        return false;
    }

    fn collectReferencedLocals(self: *CodeGen, instr: *const ir.Instruction) void {
        switch (instr.*) {
            .local_get => |lg| self.referenced_locals.append(self.allocator, lg.source) catch {},
            .local_set => |ls| self.referenced_locals.append(self.allocator, ls.value) catch {},
            .move_value => |mv| self.referenced_locals.append(self.allocator, mv.source) catch {},
            .share_value => |sv| self.referenced_locals.append(self.allocator, sv.source) catch {},
            .binary_op => |bo| {
                self.referenced_locals.append(self.allocator, bo.lhs) catch {};
                self.referenced_locals.append(self.allocator, bo.rhs) catch {};
            },
            .unary_op => |uo| {
                self.referenced_locals.append(self.allocator, uo.operand) catch {};
            },
            .call_direct => |cd| {
                for (cd.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .call_named => |cn| {
                for (cn.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .call_closure => |cc| {
                self.referenced_locals.append(self.allocator, cc.callee) catch {};
                for (cc.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .jump => |j| {
                if (j.value) |value| self.referenced_locals.append(self.allocator, value) catch {};
            },
            .call_dispatch => |cd_disp| {
                for (cd_disp.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .tail_call => |tc| {
                for (tc.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .call_builtin => |cb| {
                for (cb.args) |arg| self.referenced_locals.append(self.allocator, arg) catch {};
            },
            .match_atom => |ma| self.referenced_locals.append(self.allocator, ma.scrutinee) catch {},
            .match_int => |mi| self.referenced_locals.append(self.allocator, mi.scrutinee) catch {},
            .match_float => |mf| self.referenced_locals.append(self.allocator, mf.scrutinee) catch {},
            .match_string => |ms| self.referenced_locals.append(self.allocator, ms.scrutinee) catch {},
            .match_type => |mt| self.referenced_locals.append(self.allocator, mt.scrutinee) catch {},
            .cond_branch => |cb| self.referenced_locals.append(self.allocator, cb.condition) catch {},
            .cond_return => |cr| {
                self.referenced_locals.append(self.allocator, cr.condition) catch {};
                if (!self.current_fn_is_void) {
                    if (cr.value) |v| self.referenced_locals.append(self.allocator, v) catch {};
                }
            },
            .ret => |r| {
                if (!self.current_fn_is_void) {
                    if (r.value) |v| self.referenced_locals.append(self.allocator, v) catch {};
                }
            },
            .tuple_init => |ti| {
                for (ti.elements) |elem| self.referenced_locals.append(self.allocator, elem) catch {};
            },
            .list_init => |li| {
                for (li.elements) |elem| self.referenced_locals.append(self.allocator, elem) catch {};
            },
            .make_closure => |mc| {
                for (mc.captures) |cap| self.referenced_locals.append(self.allocator, cap) catch {};
            },
            .if_expr => |ie| {
                self.referenced_locals.append(self.allocator, ie.condition) catch {};
                for (ie.then_instrs) |sub_instr| {
                    self.collectReferencedLocals(&sub_instr);
                }
                for (ie.else_instrs) |sub_instr| {
                    self.collectReferencedLocals(&sub_instr);
                }
                if (ie.then_result) |tr| self.referenced_locals.append(self.allocator, tr) catch {};
                if (ie.else_result) |er| self.referenced_locals.append(self.allocator, er) catch {};
            },
            .guard_block => |gb| {
                self.referenced_locals.append(self.allocator, gb.condition) catch {};
                for (gb.body) |sub_instr| {
                    self.collectReferencedLocals(&sub_instr);
                }
            },
            .case_block => |cb| {
                for (cb.pre_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                for (cb.arms) |arm| {
                    for (arm.cond_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                    self.referenced_locals.append(self.allocator, arm.condition) catch {};
                    for (arm.body_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                    if (arm.result) |r| self.referenced_locals.append(self.allocator, r) catch {};
                }
                for (cb.default_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                if (cb.default_result) |r| self.referenced_locals.append(self.allocator, r) catch {};
            },
            .case_break => |cbr| {
                if (cbr.value) |v| self.referenced_locals.append(self.allocator, v) catch {};
            },
            .switch_literal => |sl| {
                self.referenced_locals.append(self.allocator, sl.scrutinee) catch {};
                for (sl.cases) |case| {
                    for (case.body_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                    if (case.result) |r| self.referenced_locals.append(self.allocator, r) catch {};
                }
                for (sl.default_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                if (sl.default_result) |r| self.referenced_locals.append(self.allocator, r) catch {};
            },
            .switch_return => |sr| {
                for (sr.cases) |case| {
                    for (case.body_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                    if (case.return_value) |r| self.referenced_locals.append(self.allocator, r) catch {};
                }
                for (sr.default_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                if (sr.default_result) |r| self.referenced_locals.append(self.allocator, r) catch {};
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    for (case.body_instrs) |sub_instr| self.collectReferencedLocals(&sub_instr);
                    if (case.return_value) |r| self.referenced_locals.append(self.allocator, r) catch {};
                }
            },
            .index_get => |ig| {
                self.referenced_locals.append(self.allocator, ig.object) catch {};
            },
            .list_len_check => |llc| {
                self.referenced_locals.append(self.allocator, llc.scrutinee) catch {};
            },
            .list_get => |lg| {
                self.referenced_locals.append(self.allocator, lg.list) catch {};
            },
            .optional_unwrap => |ou| {
                self.referenced_locals.append(self.allocator, ou.source) catch {};
            },
            .struct_init => |si| {
                for (si.fields) |field| self.referenced_locals.append(self.allocator, field.value) catch {};
            },
            .union_init => |ui| {
                self.referenced_locals.append(self.allocator, ui.value) catch {};
            },
            .field_get => |fg| {
                self.referenced_locals.append(self.allocator, fg.object) catch {};
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    self.referenced_locals.append(self.allocator, entry.key) catch {};
                    self.referenced_locals.append(self.allocator, entry.value) catch {};
                }
            },
            .bin_len_check => |blc| {
                self.referenced_locals.append(self.allocator, blc.scrutinee) catch {};
            },
            .bin_read_int => |bri| {
                self.referenced_locals.append(self.allocator, bri.source) catch {};
                if (bri.offset == .dynamic) self.referenced_locals.append(self.allocator, bri.offset.dynamic) catch {};
            },
            .bin_read_float => |brf| {
                self.referenced_locals.append(self.allocator, brf.source) catch {};
                if (brf.offset == .dynamic) self.referenced_locals.append(self.allocator, brf.offset.dynamic) catch {};
            },
            .bin_slice => |bs| {
                self.referenced_locals.append(self.allocator, bs.source) catch {};
                if (bs.offset == .dynamic) self.referenced_locals.append(self.allocator, bs.offset.dynamic) catch {};
                if (bs.length) |len| {
                    if (len == .dynamic) self.referenced_locals.append(self.allocator, len.dynamic) catch {};
                }
            },
            .bin_read_utf8 => |bru| {
                self.referenced_locals.append(self.allocator, bru.source) catch {};
                if (bru.offset == .dynamic) self.referenced_locals.append(self.allocator, bru.offset.dynamic) catch {};
            },
            .bin_match_prefix => |bmp| {
                self.referenced_locals.append(self.allocator, bmp.source) catch {};
            },
            else => {},
        }
    }

    fn isParamUsedInInstrs(self: *const CodeGen, instrs: []const ir.Instruction, param_idx: u32) bool {
        for (instrs) |instr| {
            switch (instr) {
                .param_get => |pg| {
                    if (pg.index == param_idx) return true;
                },
                .if_expr => |ie| {
                    if (self.isParamUsedInInstrs(ie.then_instrs, param_idx)) return true;
                    if (self.isParamUsedInInstrs(ie.else_instrs, param_idx)) return true;
                },
                .guard_block => |gb| {
                    if (self.isParamUsedInInstrs(gb.body, param_idx)) return true;
                },
                .case_block => |cb| {
                    if (self.isParamUsedInInstrs(cb.pre_instrs, param_idx)) return true;
                    for (cb.arms) |arm| {
                        if (self.isParamUsedInInstrs(arm.cond_instrs, param_idx)) return true;
                        if (self.isParamUsedInInstrs(arm.body_instrs, param_idx)) return true;
                    }
                    if (self.isParamUsedInInstrs(cb.default_instrs, param_idx)) return true;
                },
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        if (self.isParamUsedInInstrs(case.body_instrs, param_idx)) return true;
                    }
                    if (self.isParamUsedInInstrs(sl.default_instrs, param_idx)) return true;
                },
                .switch_return => |sr| {
                    // The scrutinee_param is used directly
                    if (sr.scrutinee_param == param_idx) return true;
                    for (sr.cases) |case| {
                        if (self.isParamUsedInInstrs(case.body_instrs, param_idx)) return true;
                    }
                    if (self.isParamUsedInInstrs(sr.default_instrs, param_idx)) return true;
                },
                .union_switch_return => |usr| {
                    if (usr.scrutinee_param == param_idx) return true;
                    for (usr.cases) |case| {
                        if (self.isParamUsedInInstrs(case.body_instrs, param_idx)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    // ============================================================
    // Instruction emission
    // ============================================================

    fn emitInstruction(self: *CodeGen, instr: *const ir.Instruction) !void {
        switch (instr.*) {
            .const_int => |ci| {
                try self.writeIndent();
                try self.writeDestLocal(ci.dest);
                if (ci.type_hint) |hint| {
                    try self.write(": ");
                    try self.emitZigType(&hint);
                    try self.write(" = ");
                } else {
                    try self.write(" = ");
                }
                try self.writeInt(ci.value);
                try self.write(";\n");
            },
            .const_float => |cf| {
                try self.writeIndent();
                try self.writeDestLocal(cf.dest);
                if (cf.type_hint) |hint| {
                    try self.write(": ");
                    try self.emitZigType(&hint);
                    try self.write(" = ");
                } else {
                    try self.write(" = ");
                }
                try self.writeFloat(cf.value);
                try self.write(";\n");
            },
            .const_string => |cs| {
                try self.writeIndent();
                try self.writeDestLocal(cs.dest);
                try self.write(": []const u8 = \"");
                try self.write(cs.value);
                try self.write("\";\n");
            },
            .const_bool => |cb| {
                try self.writeIndent();
                try self.writeDestLocal(cb.dest);
                try self.write(if (cb.value) " = true;\n" else " = false;\n");
            },
            .const_atom => |ca| {
                try self.writeIndent();
                try self.writeDestLocal(ca.dest);
                try self.write(" = .@\"");
                try self.write(ca.value);
                try self.write("\";\n");
            },
            .const_nil => |dest| {
                try self.writeIndent();
                try self.writeDestLocal(dest);
                try self.write(" = null;\n");
            },
            .local_get => |lg| {
                try self.propagateReuseBackedStructLocal(lg.dest, lg.source);
                try self.propagateReuseBackedUnionLocal(lg.dest, lg.source);
                try self.propagateReuseBackedTupleLocal(lg.dest, lg.source);
                try self.writeIndent();
                try self.writeDestLocal(lg.dest);
                try self.write(" = ");
                try self.writeLocal(lg.source);
                try self.write(";\n");
            },
            .local_set => |ls| {
                try self.propagateReuseBackedStructLocal(ls.dest, ls.value);
                try self.propagateReuseBackedUnionLocal(ls.dest, ls.value);
                try self.propagateReuseBackedTupleLocal(ls.dest, ls.value);
                try self.writeIndent();
                try self.writeDestLocal(ls.dest);
                try self.write(" = ");
                try self.writeLocal(ls.value);
                try self.write(";\n");
            },
            .move_value => |mv| {
                try self.propagateReuseBackedStructLocal(mv.dest, mv.source);
                try self.propagateReuseBackedUnionLocal(mv.dest, mv.source);
                try self.propagateReuseBackedTupleLocal(mv.dest, mv.source);
                try self.writeIndent();
                try self.writeDestLocal(mv.dest);
                try self.write(" = ");
                try self.writeLocal(mv.source);
                try self.write(";\n");
            },
            .share_value => |sv| {
                try self.propagateReuseBackedStructLocal(sv.dest, sv.source);
                try self.propagateReuseBackedUnionLocal(sv.dest, sv.source);
                try self.propagateReuseBackedTupleLocal(sv.dest, sv.source);
                try self.writeIndent();
                try self.writeDestLocal(sv.dest);
                try self.write(" = ");
                try self.writeLocal(sv.source);
                try self.write(";\n");
                if (!self.shouldSkipArc(sv.source)) {
                    try self.writeIndent();
                    try self.write("zap_runtime.ArcRuntime.retainAny(@TypeOf(");
                    try self.writeLocal(sv.dest);
                    try self.write("), ");
                    try self.writeLocal(sv.dest);
                    try self.write(");\n");
                }
            },
            .param_get => |pg| {
                // Skip emitting param_get if the dest local is unreferenced.
                // Writing `_ = __arg_N;` would be a pointless discard in Zig
                // and causes a compile error if the param is used elsewhere.
                if (!self.isLocalReferenced(pg.dest)) return;
                try self.writeIndent();
                try self.writeDestLocal(pg.dest);
                try self.write(" = ");
                try self.writeParam(pg.index);
                try self.write(";\n");
            },
            .binary_op => |bo| {
                if (bo.op == .concat) {
                    // String concat uses runtime allocator
                    try self.writeIndent();
                    try self.writeDestLocal(bo.dest);
                    try self.write(" = zap_runtime.ZapString.concat(std.heap.page_allocator, ");
                    try self.writeLocal(bo.lhs);
                    try self.write(", ");
                    try self.writeLocal(bo.rhs);
                    try self.write(") catch \"\";\n");
                } else {
                    try self.writeIndent();
                    try self.writeDestLocal(bo.dest);
                    try self.write(" = ");
                    try self.writeLocal(bo.lhs);
                    try self.write(switch (bo.op) {
                        .add => " + ",
                        .sub => " - ",
                        .mul => " * ",
                        .div => " / ",
                        .rem_op => " % ",
                        .eq => " == ",
                        .neq => " != ",
                        .lt => " < ",
                        .gt => " > ",
                        .lte => " <= ",
                        .gte => " >= ",
                        .bool_and => " and ",
                        .bool_or => " or ",
                        .concat => unreachable,
                    });
                    try self.writeLocal(bo.rhs);
                    try self.write(";\n");
                }
            },
            .unary_op => |uo| {
                try self.writeIndent();
                try self.writeDestLocal(uo.dest);
                try self.write(switch (uo.op) {
                    .negate => " = -",
                    .bool_not => " = !",
                });
                try self.writeLocal(uo.operand);
                try self.write(";\n");
            },
            .call_direct => |cd| {
                try self.writeIndent();
                try self.writeDestLocal(cd.dest);
                try self.write(" = ");
                try self.write(self.function_names.get(cd.function) orelse "func_unknown");
                try self.write("(");
                for (cd.args, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeValueLocal(arg);
                }
                try self.write(");\n");
            },
            .call_named => |cn| {
                try self.writeIndent();
                try self.writeDestLocal(cn.dest);
                try self.write(" = ");
                try self.write(cn.name);
                try self.write("(");
                for (cn.args, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeValueLocal(arg);
                }
                try self.write(");\n");
            },
            .call_closure => |cc| {
                const lattice_mod = @import("escape_lattice.zig");
                const callee_is_param = self.isParamDerivedClosure(cc.callee);
                var emitted_specialized = false;
                if (self.getCallSiteSpecialization()) |spec| {
                    switch (spec.decision) {
                        .direct_call, .contified => {
                            if (spec.decision == .contified and self.isTailReturnOf(cc.dest)) {
                                if (!callee_is_param) {
                                    if (self.findClosureTarget(cc.callee)) |target| {
                                        if (try self.emitTailDirectClosureCall(target, cc.args)) {
                                            emitted_specialized = true;
                                            self.skip_next_ret_local = cc.dest;
                                        }
                                    }
                                }
                                if (!emitted_specialized and spec.lambda_set.isSingleton()) {
                                    if (try self.emitTailInvokeWrapperCall(cc.callee, spec.lambda_set.members[0], cc.args)) {
                                        emitted_specialized = true;
                                        self.skip_next_ret_local = cc.dest;
                                    }
                                }
                            }
                            if (!emitted_specialized and !callee_is_param) {
                                if (self.findClosureTarget(cc.callee)) |target| {
                                    if (try self.emitDirectClosureCall(cc.dest, target, cc.args)) {
                                        emitted_specialized = true;
                                    }
                                }
                            }
                            if (!emitted_specialized and spec.lambda_set.isSingleton()) {
                                if (try self.emitInvokeWrapperCall(cc.dest, cc.callee, spec.lambda_set.members[0], cc.args)) {
                                    emitted_specialized = true;
                                }
                            }
                        },
                        .switch_dispatch => {
                            if (try self.emitSwitchDispatch(cc, spec.lambda_set.members)) {
                                emitted_specialized = true;
                            }
                        },
                        .unreachable_call => {
                            try self.writeIndent();
                            try self.writeDestLocal(cc.dest);
                            try self.write(" = unreachable;\n");
                            emitted_specialized = true;
                        },
                        .dyn_closure_dispatch => {},
                    }
                }

                if (!emitted_specialized) {
                    if (self.analysis_context) |actx| {
                        const vkey = lattice_mod.ValueKey{
                            .function = self.current_function_id,
                            .local = cc.callee,
                        };
                        if (actx.getLambdaSet(vkey)) |ls| {
                            if (!callee_is_param and ls.isSingleton()) {
                                if (self.findClosureTarget(cc.callee)) |target| {
                                    if (try self.emitDirectClosureCall(cc.dest, target, cc.args)) {
                                        emitted_specialized = true;
                                    }
                                }
                            }
                        }
                    }
                }

                if (!emitted_specialized) {
                    try self.writeIndent();
                    try self.writeDestLocal(cc.dest);
                    try self.write(" = zap_runtime.invokeDynClosure(");
                    try self.emitZigType(&cc.return_type);
                    try self.write(", ");
                    try self.writeLocal(cc.callee);
                    try self.write(", .{");
                    for (cc.args, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeValueLocal(arg);
                    }
                    try self.write("});\n");
                }
            },
            .make_closure => |mc| {
                const mc_alloc = self.getClosureAllocation(mc.function);
                try self.writeIndent();
                if (mc.captures.len == 0) {
                    try self.writeDestLocal(mc.dest);
                    try self.write(" = zap_runtime.DynClosure{ .call_fn = @ptrCast(&__closure_invoke_");
                    try self.writeInt(@intCast(mc.function));
                    try self.write("), .env = null, .env_release = null };\n");
                } else {
                    const local_env = mc_alloc == .stack;
                    if (local_env) {
                        try self.write("var ");
                        try self.write(self.closureEnvPrefix(mc.function));
                        try self.writeInt(@intCast(mc.dest));
                        try self.write(" = __closure_env_");
                        try self.writeInt(@intCast(mc.function));
                        try self.write("{");
                    } else {
                        try self.write("const __env_");
                        try self.writeInt(@intCast(mc.dest));
                        try self.write(" = std.heap.page_allocator.create(__closure_env_");
                        try self.writeInt(@intCast(mc.function));
                        try self.write(") catch unreachable;\n");
                        try self.writeIndent();
                        try self.write("__env_");
                        try self.writeInt(@intCast(mc.dest));
                        try self.write(".* = .{");
                    }
                    for (mc.captures, 0..) |cap, i| {
                        if (i > 0) try self.write(", ");
                        try self.write(".__cap_");
                        try self.writeInt(@intCast(i));
                        try self.write(" = ");
                        try self.writeLocal(cap);
                    }
                    try self.write("};\n");
                    if (!local_env) {
                        if (self.function_defs.get(mc.function)) |func_def| {
                            for (func_def.captures, 0..) |capture, i| {
                                if (capture.ownership == .shared and capture.type_expr == .struct_ref) {
                                    try self.writeIndent();
                                    try self.write("zap_runtime.ArcRuntime.retainAny(@TypeOf(__env_");
                                    try self.writeInt(@intCast(mc.dest));
                                    try self.write(".__cap_");
                                    try self.writeInt(@intCast(i));
                                    try self.write("), &__env_");
                                    try self.writeInt(@intCast(mc.dest));
                                    try self.write(".__cap_");
                                    try self.writeInt(@intCast(i));
                                    try self.write(");\n");
                                }
                            }
                        }
                    }
                    try self.writeIndent();
                    try self.writeDestLocal(mc.dest);
                    try self.write(" = zap_runtime.DynClosure{ .call_fn = @ptrCast(&__closure_invoke_");
                    try self.writeInt(@intCast(mc.function));
                    try self.write("), .env = ");
                    if (local_env) {
                        try self.write("@ptrCast(&");
                        try self.write(self.closureEnvPrefix(mc.function));
                        try self.writeInt(@intCast(mc.dest));
                        try self.write(")");
                    } else {
                        try self.write("__env_");
                        try self.writeInt(@intCast(mc.dest));
                    }
                    try self.write(", .env_release = ");
                    if (local_env) {
                        try self.write("null");
                    } else {
                        try self.write("&__closure_release_");
                        try self.writeInt(@intCast(mc.function));
                    }
                    try self.write(" };\n");
                }
            },
            .capture_get => |cg| {
                try self.writeIndent();
                try self.writeDestLocal(cg.dest);
                try self.write(" = __cap_");
                try self.writeInt(@intCast(cg.index));
                try self.write(";\n");
            },
            .call_dispatch => |cd_disp| {
                try self.writeIndent();
                try self.writeDestLocal(cd_disp.dest);
                try self.write(" = dispatch_");
                try self.writeInt(@intCast(cd_disp.group_id));
                try self.write("(");
                for (cd_disp.args, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeValueLocal(arg);
                }
                try self.write(");\n");
            },
            .tail_call => |tc| {
                // Emit: return @call(.always_tail, func, .{args});
                try self.writeIndent();
                try self.write("return @call(.always_tail, ");
                try self.write(tc.name);
                try self.write(", .{");
                for (tc.args, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeValueLocal(arg);
                }
                try self.write("});\n");
            },
            .match_atom => |ma| {
                try self.writeIndent();
                try self.writeDestLocal(ma.dest);
                if (ma.skip_type_check) {
                    // Phase 3: known atom type — skip @TypeOf wrapper
                    try self.write(" = ");
                    try self.writeLocal(ma.scrutinee);
                    try self.write(" == .@\"");
                    try self.write(ma.atom_name);
                    try self.write("\";\n");
                } else {
                    // Type-safe atom comparison for anytype params
                    try self.write(" = @TypeOf(");
                    try self.writeLocal(ma.scrutinee);
                    try self.write(") == @TypeOf(.@\"");
                    try self.write(ma.atom_name);
                    try self.write("\") and ");
                    try self.writeLocal(ma.scrutinee);
                    try self.write(" == .@\"");
                    try self.write(ma.atom_name);
                    try self.write("\";\n");
                }
            },
            .match_int => |mi| {
                try self.writeIndent();
                try self.writeDestLocal(mi.dest);
                if (mi.skip_type_check) {
                    // Phase 3: known integer type — direct comparison
                    try self.write(" = ");
                    try self.writeLocal(mi.scrutinee);
                    try self.write(" == ");
                    try self.writeInt(mi.value);
                    try self.write(";\n");
                } else {
                    // Type-safe integer comparison for anytype params
                    try self.write(" = (@typeInfo(@TypeOf(");
                    try self.writeLocal(mi.scrutinee);
                    try self.write(")) == .int or @typeInfo(@TypeOf(");
                    try self.writeLocal(mi.scrutinee);
                    try self.write(")) == .comptime_int) and ");
                    try self.writeLocal(mi.scrutinee);
                    try self.write(" == ");
                    try self.writeInt(mi.value);
                    try self.write(";\n");
                }
            },
            .match_float => |mf| {
                try self.writeIndent();
                try self.writeDestLocal(mf.dest);
                if (mf.skip_type_check) {
                    // Phase 3: known float type — direct comparison
                    try self.write(" = ");
                    try self.writeLocal(mf.scrutinee);
                    try self.write(" == ");
                    try self.writeFloat(mf.value);
                    try self.write(";\n");
                } else {
                    // Type-safe float comparison for anytype params
                    try self.write(" = (@typeInfo(@TypeOf(");
                    try self.writeLocal(mf.scrutinee);
                    try self.write(")) == .float or @typeInfo(@TypeOf(");
                    try self.writeLocal(mf.scrutinee);
                    try self.write(")) == .comptime_float) and ");
                    try self.writeLocal(mf.scrutinee);
                    try self.write(" == ");
                    try self.writeFloat(mf.value);
                    try self.write(";\n");
                }
            },
            .match_string => |ms| {
                // Type-safe string comparison using std.mem.eql
                try self.writeIndent();
                try self.writeDestLocal(ms.dest);
                try self.write(" = @TypeOf(");
                try self.writeLocal(ms.scrutinee);
                try self.write(") == []const u8 and std.mem.eql(u8, ");
                try self.writeLocal(ms.scrutinee);
                try self.write(", \"");
                try self.write(ms.expected);
                try self.write("\");\n");
            },
            .match_type => |mt| {
                // Type guard for anytype params: @TypeOf(x) == expected
                // For integer/float types, also accept comptime_int/comptime_float
                // so that literal arguments (e.g. describe(20)) match properly.
                const needs_comptime_check = switch (mt.expected_type) {
                    .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => true,
                    .f16, .f32, .f64 => true,
                    else => false,
                };
                const is_struct_check = mt.expected_type == .tuple;
                try self.writeIndent();
                try self.writeDestLocal(mt.dest);
                if (is_struct_check) {
                    if (mt.expected_arity) |arity| {
                        // Tuple/struct type check with arity: check struct AND field count
                        try self.write(" = @typeInfo(@TypeOf(");
                        try self.writeLocal(mt.scrutinee);
                        try self.write(")) == .@\"struct\" and @typeInfo(@TypeOf(");
                        try self.writeLocal(mt.scrutinee);
                        try self.write(")).@\"struct\".fields.len == ");
                        try self.writeInt(@intCast(arity));
                        try self.write(";\n");
                    } else {
                        // Tuple/struct type check without arity
                        try self.write(" = @typeInfo(@TypeOf(");
                        try self.writeLocal(mt.scrutinee);
                        try self.write(")) == .@\"struct\";\n");
                    }
                } else {
                    try self.write(" = @TypeOf(");
                    try self.writeLocal(mt.scrutinee);
                    try self.write(") == ");
                    try self.emitZigType(&mt.expected_type);
                    if (needs_comptime_check) {
                        const is_float = switch (mt.expected_type) {
                            .f16, .f32, .f64 => true,
                            else => false,
                        };
                        try self.write(" or @typeInfo(@TypeOf(");
                        try self.writeLocal(mt.scrutinee);
                        if (is_float) {
                            try self.write(")) == .comptime_float");
                        } else {
                            try self.write(")) == .comptime_int");
                        }
                    }
                    try self.write(";\n");
                }
            },
            .index_get => |ig| {
                try self.writeIndent();
                try self.writeDestLocal(ig.dest);
                try self.write(" = ");
                try self.writeLocal(ig.object);
                try self.write("[");
                try self.writeInt(@intCast(ig.index));
                try self.write("];\n");
            },
            .list_len_check => |llc| {
                // Emit: const __local_N = scrutinee.len == expected;
                try self.writeIndent();
                try self.writeDestLocal(llc.dest);
                try self.write(" = ");
                try self.writeLocal(llc.scrutinee);
                try self.write(".len == ");
                try self.writeInt(@intCast(llc.expected_len));
                try self.write(";\n");
            },
            .list_get => |lg| {
                // Emit: const __local_N = list[index];
                try self.writeIndent();
                try self.writeDestLocal(lg.dest);
                try self.write(" = ");
                try self.writeLocal(lg.list);
                try self.write("[");
                try self.writeInt(@intCast(lg.index));
                try self.write("];\n");
            },
            .guard_block => |gb| {
                try self.writeIndent();
                try self.write("if (");
                try self.writeLocal(gb.condition);
                try self.write(") {\n");
                self.indent_level += 1;
                for (gb.body) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}\n");
            },
            .case_block => |cb| {
                const block_label = self.next_block_label;
                self.next_block_label += 1;
                const label_str = try std.fmt.allocPrint(self.allocator, "blk_case_{d}", .{block_label});

                const saved_case_label = self.current_case_label;
                self.current_case_label = label_str;

                // Perceus: emit reset for the scrutinee if there's a reuse pair.
                // The reset checks RC and produces a reuse token.
                if (self.analysis_context) |actx| {
                    for (actx.reuse_pairs.items) |pair| {
                        // Check if the scrutinee of this case_block matches the reset source.
                        // The pre_instrs usually contain the scrutinee setup.
                        if (pair.reset.source == cb.dest or
                            (cb.pre_instrs.len > 0 and self.instrDefinesLocal(cb.pre_instrs[0], pair.reset.source)))
                        {
                            try self.writeIndent();
                            try self.write("// Perceus: reset for potential reuse\n");
                            try self.writeIndent();
                            const token_local = try std.fmt.allocPrint(self.allocator, "const __local_{d}", .{pair.reset.dest});
                            try self.write(token_local);
                            try self.write(" = if (zap_runtime.ArcRuntime.refCountAny(@TypeOf(");
                            try self.writeLocal(pair.reset.source);
                            try self.write("), ");
                            try self.writeLocal(pair.reset.source);
                            try self.write(") == 1) @as(?*anyopaque, @ptrCast(");
                            try self.writeLocal(pair.reset.source);
                            try self.write(")) else null;\n");
                        }
                    }
                }

                // const __local_N = blk_case_L: { ... };
                try self.writeIndent();
                try self.writeDestLocal(cb.dest);
                try self.write(" = ");
                try self.write(label_str);
                try self.write(": {\n");
                self.indent_level += 1;

                // Emit pre-instructions (tuple arm guards with case_break)
                for (cb.pre_instrs) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }

                // Emit each conditional arm
                for (cb.arms, 0..) |arm, arm_idx| {
                    for (arm.cond_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    try self.writeIndent();
                    try self.write("if (");
                    try self.writeLocal(arm.condition);
                    try self.write(") {\n");
                    self.indent_level += 1;
                    for (arm.body_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (arm.result) |r| {
                        try self.emitDropSpecializationsForCurrentInstr(r, @intCast(arm_idx));
                    }
                    if (arm.result) |r| {
                        try self.writeIndent();
                        try self.write("break :");
                        try self.write(label_str);
                        try self.write(" ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("}\n");
                }

                // Default arm
                for (cb.default_instrs) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }
                if (cb.default_result) |r| {
                    try self.writeIndent();
                    try self.write("break :");
                    try self.write(label_str);
                    try self.write(" ");
                    try self.writeLocal(r);
                    try self.write(";\n");
                }

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");

                self.current_case_label = saved_case_label;
            },
            .switch_literal => |sl| {
                // Emit: const __local_N = switch (__local_S) { ... };
                try self.writeIndent();
                try self.writeDestLocal(sl.dest);
                try self.write(" = switch (");
                try self.writeLocal(sl.scrutinee);
                try self.write(") {\n");
                self.indent_level += 1;

                for (sl.cases, 0..) |case, case_i| {
                    try self.writeIndent();
                    try self.emitLiteralValue(&case.value);
                    try self.write(" => ");
                    const case_label = try std.fmt.allocPrint(self.allocator, "blk_sw_{d}", .{case_i});
                    try self.write(case_label);
                    try self.write(": {\n");
                    self.indent_level += 1;
                    for (case.body_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (case.result) |r| {
                        try self.writeIndent();
                        try self.write("break :");
                        try self.write(case_label);
                        try self.write(" ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("},\n");
                }

                // else (default) — skip if cases are exhaustive (e.g., bool true+false)
                const is_exhaustive = blk: {
                    var has_true = false;
                    var has_false = false;
                    for (sl.cases) |case| {
                        if (case.value == .bool_val) {
                            if (case.value.bool_val) has_true = true else has_false = true;
                        }
                    }
                    break :blk has_true and has_false;
                };
                if (!is_exhaustive) {
                    try self.writeIndent();
                    try self.write("else => blk_sw_else: {\n");
                    self.indent_level += 1;
                    for (sl.default_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (sl.default_result) |r| {
                        try self.writeIndent();
                        try self.write("break :blk_sw_else ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("},\n");
                }

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");
            },
            .switch_return => |sr| {
                // Emit: return switch (__arg_N) { ... };
                try self.writeIndent();
                try self.write("return switch (");
                try self.writeParam(sr.scrutinee_param);
                try self.write(") {\n");
                self.indent_level += 1;

                for (sr.cases, 0..) |case, case_i| {
                    // Check if case body ends with tail_call (no label needed)
                    const has_tail_call = case.body_instrs.len > 0 and
                        case.body_instrs[case.body_instrs.len - 1] == .tail_call;

                    try self.writeIndent();
                    try self.emitLiteralValue(&case.value);
                    try self.write(" => ");
                    if (!has_tail_call) {
                        const case_label = try std.fmt.allocPrint(self.allocator, "blk_sw_{d}", .{case_i});
                        try self.write(case_label);
                        try self.write(": ");
                    }
                    try self.write("{\n");
                    self.indent_level += 1;
                    for (case.body_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (!has_tail_call) {
                        const case_label2 = try std.fmt.allocPrint(self.allocator, "blk_sw_{d}", .{case_i});
                        if (case.return_value) |r| {
                            try self.writeIndent();
                            try self.write("break :");
                            try self.write(case_label2);
                            try self.write(" ");
                            try self.writeLocal(r);
                            try self.write(";\n");
                        }
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("},\n");
                }

                // else (default)
                const default_has_tail_call = sr.default_instrs.len > 0 and
                    sr.default_instrs[sr.default_instrs.len - 1] == .tail_call;
                try self.writeIndent();
                if (!default_has_tail_call) {
                    try self.write("else => blk_sw_else: {\n");
                } else {
                    try self.write("else => {\n");
                }
                self.indent_level += 1;
                for (sr.default_instrs) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }
                if (!default_has_tail_call) {
                    if (sr.default_result) |r| {
                        try self.writeIndent();
                        try self.write("break :blk_sw_else ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("},\n");

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");
            },
            .union_switch_return => |usr| {
                // Emit: return switch (__arg_N) { .Variant => |__payload| { ... }, ... };
                try self.writeIndent();
                try self.write("return switch (");
                try self.writeParam(usr.scrutinee_param);
                try self.write(") {\n");
                self.indent_level += 1;

                for (usr.cases, 0..) |case, case_i| {
                    try self.writeIndent();
                    try self.write(".");
                    try self.write(case.variant_name);
                    try self.write(" => |__payload| ");
                    const case_label = try std.fmt.allocPrint(self.allocator, "blk_u_{d}", .{case_i});
                    try self.write(case_label);
                    try self.write(": {\n");
                    self.indent_level += 1;

                    // Emit field bindings from payload
                    for (case.field_bindings) |fb| {
                        try self.writeIndent();
                        try self.write("const ");
                        try self.write(fb.local_name);
                        try self.write(" = __payload.");
                        try self.write(fb.field_name);
                        try self.write(";\n");
                    }

                    for (case.body_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (case.return_value) |r| {
                        try self.writeIndent();
                        try self.write("break :");
                        try self.write(case_label);
                        try self.write(" ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("},\n");
                }

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");
            },
            .union_switch => |us| {
                // Emit: const __local_N = switch (__local_M) { .Variant => |payload| { ... }, ... };
                try self.writeIndent();
                try self.writeDestLocal(us.dest);
                try self.write(" = switch (");
                try self.writeLocal(us.scrutinee);
                try self.write(") {\n");
                self.indent_level += 1;

                for (us.cases, 0..) |case, case_i| {
                    try self.writeIndent();
                    try self.write(".");
                    try self.write(case.variant_name);
                    if (case.field_bindings.len > 0 or case.body_instrs.len > 0) {
                        try self.write(" => |__payload| ");
                    } else {
                        try self.write(" => ");
                    }
                    const case_label = try std.fmt.allocPrint(self.allocator, "blk_us_{d}", .{case_i});
                    try self.write(case_label);
                    try self.write(": {\n");
                    self.indent_level += 1;

                    for (case.field_bindings) |fb| {
                        try self.writeIndent();
                        try self.write("const ");
                        try self.write(fb.local_name);
                        try self.write(" = __payload.");
                        try self.write(fb.field_name);
                        try self.write(";\n");
                    }

                    for (case.body_instrs) |sub_instr| {
                        try self.emitInstruction(&sub_instr);
                    }
                    if (case.return_value) |r| {
                        try self.writeIndent();
                        try self.write("break :");
                        try self.write(case_label);
                        try self.write(" ");
                        try self.writeLocal(r);
                        try self.write(";\n");
                    }
                    self.indent_level -= 1;
                    try self.writeIndent();
                    try self.write("},\n");
                }

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");
            },
            .case_break => |cbr| {
                if (self.current_case_label) |label| {
                    try self.writeIndent();
                    try self.write("break :");
                    try self.write(label);
                    if (cbr.value) |v| {
                        try self.write(" ");
                        try self.writeLocal(v);
                    }
                    try self.write(";\n");
                }
            },
            .if_expr => |ie| {
                const then_label = self.next_block_label;
                self.next_block_label += 1;
                const else_label = self.next_block_label;
                self.next_block_label += 1;

                // const __local_N = if (__local_C) blk_t_L: { ... } else blk_e_L: { ... };
                try self.writeIndent();
                try self.writeDestLocal(ie.dest);
                try self.write(" = if (");
                try self.writeLocal(ie.condition);
                try self.write(") ");

                // Then block
                const then_label_str = try std.fmt.allocPrint(self.allocator, "blk_t_{d}", .{then_label});
                try self.write(then_label_str);
                try self.write(": {\n");
                self.indent_level += 1;
                for (ie.then_instrs) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }
                if (ie.then_result) |tr| {
                    try self.writeIndent();
                    try self.write("break :");
                    try self.write(then_label_str);
                    try self.write(" ");
                    try self.writeLocal(tr);
                    try self.write(";\n");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("} else ");

                // Else block
                const else_label_str = try std.fmt.allocPrint(self.allocator, "blk_e_{d}", .{else_label});
                try self.write(else_label_str);
                try self.write(": {\n");
                self.indent_level += 1;
                for (ie.else_instrs) |sub_instr| {
                    try self.emitInstruction(&sub_instr);
                }
                if (ie.else_result) |er| {
                    try self.writeIndent();
                    try self.write("break :");
                    try self.write(else_label_str);
                    try self.write(" ");
                    try self.writeLocal(er);
                    try self.write(";\n");
                }
                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("};\n");
            },
            .cond_branch => |cb| {
                // TODO: proper block-based control flow
                try self.writeIndent();
                try self.write("_ = ");
                try self.writeLocal(cb.condition);
                try self.write("; // branch\n");
            },
            .cond_return => |cr| {
                try self.writeIndent();
                try self.write("if (");
                try self.writeLocal(cr.condition);
                try self.write(") return");
                if (!self.current_fn_is_void) {
                    if (cr.value) |v| {
                        try self.write(" ");
                        try self.writeLocal(v);
                    }
                }
                try self.write(";\n");
            },
            .branch => |br| {
                try self.writeIndent();
                try self.write("// goto label_");
                try self.writeInt(@intCast(br.target));
                try self.write("\n");
            },
            .ret => |r| {
                if (self.skip_next_ret_local) |local| {
                    if (r.value != null and r.value.? == local) {
                        self.skip_next_ret_local = null;
                        return;
                    }
                }
                try self.writeIndent();
                try self.write("return");
                if (!self.current_fn_is_void) {
                    if (r.value) |v| {
                        try self.write(" ");
                        try self.writeValueLocal(v);
                    }
                }
                try self.write(";\n");
            },
            .jump => |j| {
                if (j.bind_dest) |dest| {
                    if (j.value) |value| {
                        try self.writeIndent();
                        try self.writeDestLocal(dest);
                        try self.write(" = ");
                        try self.writeValueLocal(value);
                        try self.write(";\n");
                    }
                }
                try self.writeIndent();
                try self.write("// continuation jump label_");
                try self.writeInt(@intCast(j.target));
                try self.write("\n");
            },
            .tuple_init => |ti| {
                if (self.findReusePairForDest(ti.dest)) |pair| {
                    const token = pair.reuse.token orelse return error.EmitFailed;
                    try self.markReuseBackedTupleLocal(ti.dest, ti.elements.len);
                    try self.writeIndent();
                    try self.write("const __tuple_seed_");
                    try self.writeInt(@intCast(ti.dest));
                    try self.write(" = .{");
                    for (ti.elements, 0..) |elem, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeValueLocal(elem);
                    }
                    try self.write("};\n");
                    try self.writeIndent();
                    try self.writeDestLocal(ti.dest);
                    try self.write(" = zap_runtime.ArcRuntime.reuseAllocByType(@TypeOf(__tuple_seed_");
                    try self.writeInt(@intCast(ti.dest));
                    try self.write("), std.heap.page_allocator, ");
                    try self.writeLocal(token);
                    try self.write(");\n");
                    try self.writeIndent();
                    try self.writeLocal(ti.dest);
                    try self.write(".* = __tuple_seed_");
                    try self.writeInt(@intCast(ti.dest));
                    try self.write(";\n");
                } else {
                    _ = self.reuse_backed_tuple_locals.remove(ti.dest);
                    try self.writeIndent();
                    try self.writeDestLocal(ti.dest);
                    try self.write(" = .{");
                    for (ti.elements, 0..) |elem, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeValueLocal(elem);
                    }
                    try self.write("};\n");
                }
            },
            .list_init => |li| {
                try self.writeIndent();
                try self.writeDestLocal(li.dest);
                if (li.elements.len > 0) {
                    // Emit &[N]@TypeOf(first){...} for a typed runtime array
                    try self.write(" = &[_]@TypeOf(");
                    try self.writeValueLocal(li.elements[0]);
                    try self.write("){");
                    for (li.elements, 0..) |elem, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeValueLocal(elem);
                    }
                    try self.write("};\n");
                } else {
                    // Empty list: &[_]u8{} (zero-length array)
                    try self.write(" = &[_]u8{};\n");
                }
            },
            .match_fail => |mf| {
                try self.writeIndent();
                try self.write("@panic(\"");
                try self.write(mf.message);
                try self.write("\");\n");
            },
            .call_builtin => |cb| {
                try self.writeIndent();
                try self.writeDestLocal(cb.dest);
                try self.write(" = zap_runtime.Prelude.");
                try self.write(cb.name);
                try self.write("(");
                for (cb.args, 0..) |arg, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeValueLocal(arg);
                }
                try self.write(");\n");
            },
            .optional_unwrap => |ou| {
                try self.writeIndent();
                try self.writeDestLocal(ou.dest);
                try self.write(" = ");
                try self.writeValueLocal(ou.source);
                try self.write(" orelse zap_runtime.panic(\"attempted to unwrap nil value\");\n");
            },
            .struct_init => |si| {
                if (self.findReusePairForDest(si.dest)) |pair| {
                    const token = pair.reuse.token orelse return error.EmitFailed;
                    try self.markReuseBackedStructLocal(si.dest, si.type_name);
                    try self.writeIndent();
                    try self.writeDestLocal(si.dest);
                    try self.write(" = zap_runtime.ArcRuntime.reuseAllocByType(");
                    try self.write(si.type_name);
                    try self.write(", std.heap.page_allocator, ");
                    try self.writeLocal(token);
                    try self.write(");\n");
                    try self.writeIndent();
                    try self.writeLocal(si.dest);
                    try self.write(".* = ");
                    try self.write(si.type_name);
                    try self.write("{ ");
                    for (si.fields, 0..) |field, i| {
                        if (i > 0) try self.write(", ");
                        try self.write(".");
                        try self.write(field.name);
                        try self.write(" = ");
                        try self.writeValueLocal(field.value);
                    }
                    try self.write(" };\n");
                } else {
                    _ = self.reuse_backed_struct_locals.remove(si.dest);
                    _ = self.reuse_backed_union_locals.remove(si.dest);
                    try self.writeIndent();
                    try self.writeDestLocal(si.dest);
                    try self.write(" = ");
                    try self.write(si.type_name);
                    try self.write("{ ");
                    for (si.fields, 0..) |field, i| {
                        if (i > 0) try self.write(", ");
                        try self.write(".");
                        try self.write(field.name);
                        try self.write(" = ");
                        try self.writeValueLocal(field.value);
                    }
                    try self.write(" };\n");
                }
            },
            .union_init => |ui| {
                if (self.findReusePairForDest(ui.dest)) |pair| {
                    const token = pair.reuse.token orelse return error.EmitFailed;
                    _ = self.reuse_backed_struct_locals.remove(ui.dest);
                    try self.markReuseBackedUnionLocal(ui);
                    try self.writeIndent();
                    try self.writeDestLocal(ui.dest);
                    try self.write(" = zap_runtime.ArcRuntime.reuseAllocByType(");
                    try self.write(ui.union_type);
                    try self.write(", std.heap.page_allocator, ");
                    try self.writeLocal(token);
                    try self.write(");\n");
                    try self.writeIndent();
                    try self.writeLocal(ui.dest);
                    try self.write(".* = ");
                    try self.write(ui.union_type);
                    try self.write("{ .");
                    try self.write(ui.variant_name);
                    try self.write(" = ");
                    try self.writeValueLocal(ui.value);
                    try self.write(" };\n");
                } else {
                    _ = self.reuse_backed_union_locals.remove(ui.dest);
                    _ = self.reuse_backed_struct_locals.remove(ui.dest);
                    try self.writeIndent();
                    try self.writeDestLocal(ui.dest);
                    try self.write(": ");
                    try self.write(ui.union_type);
                    try self.write(" = .{ .");
                    try self.write(ui.variant_name);
                    try self.write(" = ");
                    try self.writeValueLocal(ui.value);
                    try self.write(" };\n");
                }
            },
            .field_get => |fg| {
                try self.writeIndent();
                try self.writeDestLocal(fg.dest);
                try self.write(" = ");
                try self.writeLocal(fg.object);
                try self.write(".");
                try self.write(fg.field);
                try self.write(";\n");
            },
            .enum_literal => |el| {
                try self.writeIndent();
                try self.writeDestLocal(el.dest);
                try self.write(" = ");
                try self.write(el.type_name);
                try self.write(".");
                try self.write(el.variant);
                try self.write(";\n");
            },
            .bin_len_check => |blc| {
                // __local_N = __local_M.len >= min_len;
                try self.writeIndent();
                try self.writeDestLocal(blc.dest);
                try self.write(" = ");
                try self.writeLocal(blc.scrutinee);
                try self.write(".len >= ");
                try self.writeInt(@intCast(blc.min_len));
                try self.write(";\n");
            },
            .bin_read_int => |bri| {
                try self.writeIndent();
                try self.writeDestLocal(bri.dest);
                if (bri.bits >= 8 and bri.bits % 8 == 0) {
                    // Byte-aligned: std.mem.readInt
                    const byte_count = bri.bits / 8;
                    const type_str = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{
                        if (bri.signed) @as([]const u8, "i") else @as([]const u8, "u"), bri.bits,
                    });
                    try self.write(" = std.mem.readInt(");
                    try self.write(type_str);
                    try self.write(", ");
                    try self.writeLocal(bri.source);
                    try self.write("[");
                    try self.emitBinOffset(bri.offset);
                    try self.write("..][0..");
                    try self.writeInt(@intCast(byte_count));
                    try self.write("], .");
                    try self.write(switch (bri.endianness) {
                        .big => "big",
                        .little => "little",
                        .native => "native",
                    });
                    try self.write(");\n");
                } else {
                    // Sub-byte: @as(u4, @truncate(data[byte_idx] >> shift))
                    const type_str = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{
                        if (bri.signed) @as([]const u8, "i") else @as([]const u8, "u"), bri.bits,
                    });
                    try self.write(": ");
                    try self.write(type_str);
                    try self.write(" = @truncate(");
                    try self.writeLocal(bri.source);
                    try self.write("[");
                    try self.emitBinOffset(bri.offset);
                    try self.write("]");
                    if (bri.bit_offset > 0) {
                        try self.write(" >> ");
                        try self.writeInt(@intCast(bri.bit_offset));
                    }
                    try self.write(");\n");
                }
            },
            .bin_read_float => |brf| {
                // @as(f64, @bitCast(std.mem.readInt(u64, data[off..][0..8], .big)))
                try self.writeIndent();
                try self.writeDestLocal(brf.dest);
                const byte_count = brf.bits / 8;
                const float_type = try std.fmt.allocPrint(self.allocator, "f{d}", .{brf.bits});
                const int_type = try std.fmt.allocPrint(self.allocator, "u{d}", .{brf.bits});
                try self.write(": ");
                try self.write(float_type);
                try self.write(" = @bitCast(std.mem.readInt(");
                try self.write(int_type);
                try self.write(", ");
                try self.writeLocal(brf.source);
                try self.write("[");
                try self.emitBinOffset(brf.offset);
                try self.write("..][0..");
                try self.writeInt(@intCast(byte_count));
                try self.write("], .");
                try self.write(switch (brf.endianness) {
                    .big => "big",
                    .little => "little",
                    .native => "native",
                });
                try self.write("));\n");
            },
            .bin_slice => |bs| {
                try self.writeIndent();
                try self.writeDestLocal(bs.dest);
                try self.write(" = ");
                try self.writeLocal(bs.source);
                try self.write("[");
                try self.emitBinOffset(bs.offset);
                if (bs.length) |len| {
                    try self.write("..][0..");
                    try self.emitBinOffset(len);
                    try self.write("]");
                } else {
                    try self.write("..]");
                }
                try self.write(";\n");
            },
            .bin_read_utf8 => |bru| {
                // const len = std.unicode.utf8ByteSequenceLength(data[off]) catch 1;
                // const codepoint = std.unicode.utf8Decode(data[off..][0..len]) catch 0xFFFD;
                try self.writeIndent();
                try self.writeDestLocal(bru.dest_len);
                try self.write(" = std.unicode.utf8ByteSequenceLength(");
                try self.writeLocal(bru.source);
                try self.write("[");
                try self.emitBinOffset(bru.offset);
                try self.write("]) catch 1;\n");
                try self.writeIndent();
                try self.writeDestLocal(bru.dest_codepoint);
                try self.write(" = std.unicode.utf8Decode(");
                try self.writeLocal(bru.source);
                try self.write("[");
                try self.emitBinOffset(bru.offset);
                try self.write("..][0..");
                try self.writeLocal(bru.dest_len);
                try self.write("]) catch 0xFFFD;\n");
            },
            .bin_match_prefix => |bmp| {
                // __local_N = data.len >= 4 and std.mem.eql(u8, data[0..4], "GET ");
                try self.writeIndent();
                try self.writeDestLocal(bmp.dest);
                try self.write(" = ");
                try self.writeLocal(bmp.source);
                try self.write(".len >= ");
                try self.writeInt(@intCast(bmp.expected.len));
                try self.write(" and std.mem.eql(u8, ");
                try self.writeLocal(bmp.source);
                try self.write("[0..");
                try self.writeInt(@intCast(bmp.expected.len));
                try self.write("], \"");
                try self.write(bmp.expected);
                try self.write("\");\n");
            },
            .retain => |ret| {
                if (!self.shouldSkipArc(ret.value)) {
                    try self.writeIndent();
                    try self.write("zap_runtime.ArcRuntime.retainAny(@TypeOf(");
                    try self.writeLocal(ret.value);
                    try self.write("), ");
                    try self.writeLocal(ret.value);
                    try self.write(");\n");
                }
            },
            .release => |rel| {
                if (!self.shouldSkipArc(rel.value)) {
                    try self.writeIndent();
                    try self.write("zap_runtime.ArcRuntime.releaseAny(@TypeOf(");
                    try self.writeLocal(rel.value);
                    try self.write("), std.heap.page_allocator, ");
                    try self.writeLocal(rel.value);
                    try self.write(");\n");
                }
            },
            .reset => |r| {
                // Perceus reset: if RC=1, reuse token = source ptr; else release and token = null.
                try self.writeIndent();
                try self.writeDestLocal(r.dest);
                try self.write(" = if (zap_runtime.ArcRuntime.refCountAny(@TypeOf(");
                try self.writeLocal(r.source);
                try self.write("), ");
                try self.writeLocal(r.source);
                try self.write(") == 1) @as(?*anyopaque, @ptrCast(");
                try self.writeLocal(r.source);
                try self.write(")) else blk: { zap_runtime.ArcRuntime.releaseAny(@TypeOf(");
                try self.writeLocal(r.source);
                try self.write("), std.heap.page_allocator, ");
                try self.writeLocal(r.source);
                try self.write("); break :blk null; };\n");
            },
            .reuse_alloc => |ra| {
                // Perceus reuse_alloc: if token non-null, reuse; else fresh alloc.
                try self.writeIndent();
                try self.writeDestLocal(ra.dest);
                if (ra.token) |token| {
                    try self.write(" = if (");
                    try self.writeLocal(token);
                    try self.write(") |reuse_ptr| @ptrCast(reuse_ptr) else ");
                    try self.write("std.heap.page_allocator.create(");
                    try self.emitZigType(&ra.dest_type);
                    try self.write(") catch unreachable;\n");
                } else {
                    try self.write(" = std.heap.page_allocator.create(");
                    try self.emitZigType(&ra.dest_type);
                    try self.write(") catch unreachable;\n");
                }
            },
            else => {
                try self.writeIndent();
                try self.write("// unhandled instruction\n");
            },
        }
    }

    /// Check if an instruction defines (produces) a given local.
    fn instrDefinesLocal(self: *const CodeGen, instr_val: ir.Instruction, local: ir.LocalId) bool {
        _ = self;
        return switch (instr_val) {
            .const_int => |ci| ci.dest == local,
            .const_float => |cf| cf.dest == local,
            .const_string => |cs| cs.dest == local,
            .const_bool => |cb| cb.dest == local,
            .const_atom => |ca| ca.dest == local,
            .const_nil => |dest| dest == local,
            .local_get => |lg| lg.dest == local,
            .local_set => |ls| ls.dest == local,
            .move_value => |mv| mv.dest == local,
            .share_value => |sv| sv.dest == local,
            .param_get => |pg| pg.dest == local,
            .struct_init => |si| si.dest == local,
            .tuple_init => |ti| ti.dest == local,
            .list_init => |li| li.dest == local,
            .map_init => |mi| mi.dest == local,
            .union_init => |ui| ui.dest == local,
            .field_get => |fg| fg.dest == local,
            .binary_op => |bo| bo.dest == local,
            .unary_op => |uo| uo.dest == local,
            .call_direct => |cd| cd.dest == local,
            .call_named => |cn| cn.dest == local,
            .call_closure => |cc| cc.dest == local,
            .make_closure => |mc| mc.dest == local,
            .capture_get => |cg| cg.dest == local,
            else => false,
        };
    }

    // ============================================================
    // Type emission
    // ============================================================

    fn emitInferredListReturnType(self: *CodeGen, func: *const ir.Function) !void {
        // Scan the body for the list_init instruction to determine the return type.
        // Lists in Zig are *const [N]T where T is the element type.
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .list_init => |li| {
                        if (li.elements.len > 0) {
                            // Find the element type by looking for how the first
                            // element was created (const_string → []const u8, tuple_init → struct, etc.)
                            const elem_type = self.findLocalType(block.instructions, li.elements[0]);
                            try self.write("*const [");
                            try self.writeInt(@intCast(li.elements.len));
                            try self.write("]");
                            try self.write(elem_type);
                        } else {
                            try self.write("*const [0]u8");
                        }
                        return;
                    },
                    else => {},
                }
            }
        }
        try self.write("void");
    }

    fn findLocalType(_: *CodeGen, instrs: []const ir.Instruction, local: ir.LocalId) []const u8 {
        for (instrs) |instr| {
            switch (instr) {
                .const_string => |cs| if (cs.dest == local) return "[]const u8",
                .const_int => |ci| if (ci.dest == local) return "i64",
                .const_float => |cf| if (cf.dest == local) return "f64",
                .const_bool => |cb| if (cb.dest == local) return "bool",
                .tuple_init => |ti| if (ti.dest == local) return "anytype",
                else => {},
            }
        }
        return "anytype";
    }

    fn emitBinOffset(self: *CodeGen, offset: ir.BinOffset) !void {
        switch (offset) {
            .static => |s| try self.writeInt(@intCast(s)),
            .dynamic => |d| try self.writeLocal(d),
        }
    }

    fn emitZigType(self: *CodeGen, zig_type: *const ir.ZigType) !void {
        switch (zig_type.*) {
            .void => try self.write("void"),
            .bool_type => try self.write("bool"),
            .i8 => try self.write("i8"),
            .i16 => try self.write("i16"),
            .i32 => try self.write("i32"),
            .i64 => try self.write("i64"),
            .u8 => try self.write("u8"),
            .u16 => try self.write("u16"),
            .u32 => try self.write("u32"),
            .u64 => try self.write("u64"),
            .f16 => try self.write("f16"),
            .f32 => try self.write("f32"),
            .f64 => try self.write("f64"),
            .usize => try self.write("usize"),
            .isize => try self.write("isize"),
            .string => try self.write("[]const u8"),
            .atom => try self.write("zap_runtime.Atom"),
            .nil => try self.write("?void"),
            .optional => |inner| {
                try self.write("?");
                try self.emitZigType(inner);
            },
            .tuple => |elems| {
                try self.write("struct { ");
                for (elems, 0..) |*elem, i| {
                    if (i > 0) try self.write(", ");
                    try self.emitZigType(elem);
                }
                try self.write(" }");
            },
            .function => try self.write("zap_runtime.DynClosure"),
            .any => try self.write("anytype"),
            .struct_ref => |name| try self.write(name),
            .tagged_union => |name| try self.write(name),
            else => try self.write("anytype"),
        }
    }

    // ============================================================
    // Write helpers
    // ============================================================

    fn write(self: *CodeGen, text: []const u8) !void {
        try self.output.appendSlice(self.allocator, text);
    }

    fn writeIndent(self: *CodeGen) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.write("    ");
        }
    }

    fn writeLocal(self: *CodeGen, id: ir.LocalId) !void {
        const str = try std.fmt.allocPrint(self.allocator, "__local_{d}", .{id});
        try self.write(str);
    }

    fn writeValueLocal(self: *CodeGen, id: ir.LocalId) !void {
        if (self.isReuseBackedStructLocal(id) or self.isReuseBackedUnionLocal(id) or self.isReuseBackedTupleLocal(id)) {
            try self.write("(");
            try self.writeLocal(id);
            try self.write(".*)");
            return;
        }
        try self.writeLocal(id);
    }

    fn writeDestLocal(self: *CodeGen, id: ir.LocalId) !void {
        if (self.isLocalReferenced(id)) {
            const str = try std.fmt.allocPrint(self.allocator, "const __local_{d}", .{id});
            try self.write(str);
        } else {
            try self.write("_");
        }
    }

    fn writeParam(self: *CodeGen, idx: u32) !void {
        if (idx < self.current_fn_params.len) {
            try self.write(self.current_fn_params[idx].name);
        } else {
            const str = try std.fmt.allocPrint(self.allocator, "__param_{d}", .{idx});
            try self.write(str);
        }
    }

    fn writeInt(self: *CodeGen, value: i64) !void {
        const str = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        try self.write(str);
    }

    fn emitLiteralValue(self: *CodeGen, value: *const ir.LiteralValue) !void {
        switch (value.*) {
            .int => |v| try self.writeInt(v),
            .float => |v| try self.writeFloat(v),
            .string => |v| {
                try self.write("\"");
                try self.write(v);
                try self.write("\"");
            },
            .bool_val => |v| try self.write(if (v) "true" else "false"),
        }
    }

    fn writeFloat(self: *CodeGen, value: f64) !void {
        const str = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        try self.write(str);
    }
};

test "CodeGen.findReusePairForDest matches exact insertion point" {
    const testing = std.testing;
    const lattice = @import("escape_lattice.zig");

    var analysis_context = lattice.AnalysisContext.init(testing.allocator);
    defer analysis_context.deinit();

    try analysis_context.addReusePair(.{
        .match_site = 1,
        .alloc_site = 10,
        .reset = .{ .dest = 10001, .source = 4, .source_type = 0 },
        .reuse = .{
            .dest = 9,
            .token = 10001,
            .insertion_point = .{ .function = 3, .block = 5, .instr_index = 7, .position = .before },
            .constructor_tag = 10,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });
    try analysis_context.addReusePair(.{
        .match_site = 2,
        .alloc_site = 11,
        .reset = .{ .dest = 10002, .source = 6, .source_type = 0 },
        .reuse = .{
            .dest = 9,
            .token = 10002,
            .insertion_point = .{ .function = 3, .block = 5, .instr_index = 8, .position = .before },
            .constructor_tag = 11,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var codegen = CodeGen.init(testing.allocator);
    defer codegen.deinit();
    codegen.analysis_context = &analysis_context;
    codegen.current_function_id = 3;
    codegen.current_block_label = 5;
    codegen.current_instr_index = 7;

    const pair = codegen.findReusePairForDest(9) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(ir.LocalId, 10001), pair.reset.dest);
    try testing.expectEqual(@as(u32, 7), pair.reuse.insertion_point.instr_index);
}

test "CodeGen.findReusePairForDest requires exact destination and site" {
    const testing = std.testing;
    const lattice = @import("escape_lattice.zig");

    var analysis_context = lattice.AnalysisContext.init(testing.allocator);
    defer analysis_context.deinit();

    try analysis_context.addReusePair(.{
        .match_site = 1,
        .alloc_site = 10,
        .reset = .{ .dest = 10001, .source = 4, .source_type = 0 },
        .reuse = .{
            .dest = 9,
            .token = 10001,
            .insertion_point = .{ .function = 3, .block = 5, .instr_index = 7, .position = .before },
            .constructor_tag = 10,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var wrong_instr = CodeGen.init(testing.allocator);
    defer wrong_instr.deinit();
    wrong_instr.analysis_context = &analysis_context;
    wrong_instr.current_function_id = 3;
    wrong_instr.current_block_label = 5;
    wrong_instr.current_instr_index = 6;
    try testing.expect(wrong_instr.findReusePairForDest(9) == null);

    var wrong_dest = CodeGen.init(testing.allocator);
    defer wrong_dest.deinit();
    wrong_dest.analysis_context = &analysis_context;
    wrong_dest.current_function_id = 3;
    wrong_dest.current_block_label = 5;
    wrong_dest.current_instr_index = 7;
    try testing.expect(wrong_dest.findReusePairForDest(10) == null);
}

test "CodeGen.findClosureTargetInList follows local aliases" {
    const captures = [_]ir.LocalId{7};
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 4, .function = 9, .captures = &captures } },
        .{ .local_set = .{ .dest = 5, .value = 4 } },
        .{ .share_value = .{ .dest = 6, .source = 5 } },
    };

    const target = CodeGen.findClosureTargetInList(&instrs, 6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ir.FunctionId, 9), target.function_id);
    try std.testing.expectEqual(@as(usize, 1), target.captures.len);
    try std.testing.expectEqual(@as(ir.LocalId, 7), target.captures[0]);
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const hir_mod = @import("hir.zig");
const lattice_test = @import("escape_lattice.zig");

test "codegen simple function" {
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

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = ir.IrBuilder.init(alloc, parser.interner);
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    try codegen.emitProgram(&ir_program);

    const output = codegen.getOutput();
    // Should contain function definition (module-prefixed)
    try std.testing.expect(std.mem.indexOf(u8, output, "fn Test__add") != null);
    // Should contain return statement
    try std.testing.expect(std.mem.indexOf(u8, output, "return") != null);
}

test "codegen produces valid structure" {
    const source =
        \\pub module Test {
        \\  pub fn foo() {
        \\    42
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = ir.IrBuilder.init(alloc, parser.interner);
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    try codegen.emitProgram(&ir_program);

    const output = codegen.getOutput();
    // Should contain header
    try std.testing.expect(std.mem.indexOf(u8, output, "Generated by Zap compiler") != null);
    // Should contain the literal 42
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
}

test "codegen emits analysis-owned ARC operations at insertion points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const instrs = [_]ir.Instruction{
        .{ .local_get = .{ .dest = 0, .source = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const params = [_]ir.Param{.{ .name = "value", .type_expr = .i64 }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "with_arc_ops",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = .i64,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.addArcOp(.{
        .kind = .retain,
        .value = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .before },
        .reason = .shared_binding,
    });
    try actx.addArcOp(.{
        .kind = .release,
        .value = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .after },
        .reason = .scope_exit,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.retainAny(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.releaseAny(") != null);
}

test "codegen lowers analysis-driven struct reuse via reuseAllocByType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const struct_fields = [_]ir.StructFieldDef{
        .{ .name = "first", .type_expr = "i64" },
        .{ .name = "second", .type_expr = "i64" },
    };
    const type_defs = [_]ir.TypeDef{.{
        .name = "Pair",
        .kind = .{ .struct_def = .{ .fields = &struct_fields } },
    }};
    const struct_init_fields = [_]ir.StructFieldInit{
        .{ .name = "first", .value = 11 },
        .{ .name = "second", .value = 10 },
    };
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .field_get = .{ .dest = 10, .object = 0, .field = "first" } },
        .{ .field_get = .{ .dest = 11, .object = 0, .field = "second" } },
        .{ .struct_init = .{ .dest = 20, .type_name = "Pair", .fields = &struct_init_fields } },
        .{ .ret = .{ .value = 20 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const params = [_]ir.Param{.{ .name = "pair", .type_expr = .{ .struct_ref = "Pair" } }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "swap_pair",
        .scope_id = 0,
        .arity = 1,
        .params = &params,
        .return_type = .{ .struct_ref = "Pair" },
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &type_defs, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.addReusePair(.{
        .match_site = 1,
        .alloc_site = 2,
        .reset = .{
            .dest = 10001,
            .source = 0,
            .source_type = 0,
        },
        .reuse = .{
            .dest = 20,
            .token = 10001,
            .insertion_point = .{ .function = 0, .block = 0, .instr_index = 3, .position = .before },
            .constructor_tag = 2,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.reuseAllocByType(Pair, std.heap.page_allocator, __local_10001)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__local_20.* = Pair{ .first = __local_11, .second = __local_10 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return (__local_20.*);") != null);
}

test "codegen lowers analysis-driven union reuse via reuseAllocByType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const union_variants = [_]ir.UnionVariant{
        .{ .name = "circle", .type_name = "f64" },
        .{ .name = "rect", .type_name = "f64" },
    };
    const type_defs = [_]ir.TypeDef{.{
        .name = "Shape",
        .kind = .{ .union_def = .{ .variants = &union_variants } },
    }};
    const instrs = [_]ir.Instruction{
        .{ .const_float = .{ .dest = 10, .value = 3.0 } },
        .{ .union_init = .{ .dest = 20, .union_type = "Shape", .variant_name = "circle", .value = 10 } },
        .{ .ret = .{ .value = 20 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "mk_shape",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .{ .tagged_union = "Shape" },
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &type_defs, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.addReusePair(.{
        .match_site = 1,
        .alloc_site = 2,
        .reset = .{ .dest = 10001, .source = 0, .source_type = 0 },
        .reuse = .{
            .dest = 20,
            .token = 10001,
            .insertion_point = .{ .function = 0, .block = 0, .instr_index = 1, .position = .before },
            .constructor_tag = 2,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.reuseAllocByType(Shape, std.heap.page_allocator, __local_10001)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__local_20.* = Shape{ .circle = __local_10 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return (__local_20.*);") != null);
}

test "codegen lowers continuation jump payload into bound local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block0_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 5, .value = 42 } },
        .{ .jump = .{ .target = 1, .value = 5, .bind_dest = 1 } },
    };
    const block1_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 2, .value = 1 } },
        .{ .binary_op = .{ .dest = 3, .op = .add, .lhs = 1, .rhs = 2 } },
        .{ .ret = .{ .value = 3 } },
    };
    const blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &block0_instrs },
        .{ .label = 1, .instructions = &block1_instrs },
    };
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "// continuation jump label_1") != null);
}

test "codegen lowers analysis-driven tuple reuse via reuseAllocByType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 10, .value = 1 } },
        .{ .const_int = .{ .dest = 11, .value = 2 } },
        .{ .tuple_init = .{ .dest = 20, .elements = &[_]ir.LocalId{ 10, 11 } } },
        .{ .ret = .{ .value = 20 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .{ .tuple = &[_]ir.ZigType{ .i64, .i64 } },
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.addReusePair(.{
        .match_site = 1,
        .alloc_site = 2,
        .reset = .{ .dest = 10001, .source = 0, .source_type = 0 },
        .reuse = .{
            .dest = 20,
            .token = 10001,
            .insertion_point = .{ .function = 0, .block = 0, .instr_index = 2, .position = .before },
            .constructor_tag = 2,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.reuseAllocByType(@TypeOf(__tuple_seed_20), std.heap.page_allocator, __local_10001)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__local_20.* = __tuple_seed_20;") != null);
}

test "codegen keeps plain tuple construction when reuse pair does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 10, .value = 1 } },
        .{ .const_int = .{ .dest = 11, .value = 2 } },
        .{ .tuple_init = .{ .dest = 20, .elements = &[_]ir.LocalId{ 10, 11 } } },
        .{ .ret = .{ .value = 20 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .{ .tuple = &[_]ir.ZigType{ .i64, .i64 } },
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.addReusePair(.{
        .match_site = 1,
        .alloc_site = 2,
        .reset = .{ .dest = 10001, .source = 0, .source_type = 0 },
        .reuse = .{
            .dest = 20,
            .token = 10001,
            .insertion_point = .{ .function = 0, .block = 0, .instr_index = 1, .position = .before },
            .constructor_tag = 2,
            .dest_type = 0,
        },
        .kind = .dynamic_reuse,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "ArcRuntime.reuseAllocByType(@TypeOf(__tuple_seed_20)") == null);
}

test "codegen emits arm-specific drop specializations without duplicate generic releases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const arm0_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 11, .value = 1 } }};
    const arm1_body = [_]ir.Instruction{.{ .const_int = .{ .dest = 21, .value = 2 } }};
    const arm0_cond = [_]ir.Instruction{.{ .const_bool = .{ .dest = 10, .value = true } }};
    const arm1_cond = [_]ir.Instruction{.{ .const_bool = .{ .dest = 20, .value = false } }};
    const arms = [_]ir.IrCaseArm{
        .{ .cond_instrs = &arm0_cond, .condition = 10, .body_instrs = &arm0_body, .result = 11 },
        .{ .cond_instrs = &arm1_cond, .condition = 20, .body_instrs = &arm1_body, .result = 21 },
    };
    const instrs = [_]ir.Instruction{
        .{ .case_block = .{ .dest = 30, .pre_instrs = &.{}, .arms = &arms, .default_instrs = &.{}, .default_result = null } },
        .{ .ret = .{ .value = 30 } },
    };
    const blocks = [_]ir.Block{.{ .label = 0, .instructions = &instrs }};
    const functions = [_]ir.Function{.{
        .id = 0,
        .name = "main",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .i64,
        .body = &blocks,
        .is_closure = false,
        .captures = &.{},
    }};
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    const fd0 = try alloc.alloc(lattice_test.FieldDrop, 1);
    fd0[0] = .{ .field_name = "left", .field_index = 0, .needs_recursive_drop = true, .local = 11 };
    const fd1 = try alloc.alloc(lattice_test.FieldDrop, 1);
    fd1[0] = .{ .field_name = "right", .field_index = 0, .needs_recursive_drop = true, .local = 21 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.drop_specializations.append(alloc, .{
        .match_site = 1,
        .constructor_tag = 0,
        .field_drops = fd0,
        .function = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .after },
    });
    try actx.drop_specializations.append(alloc, .{
        .match_site = 1,
        .constructor_tag = 1,
        .field_drops = fd1,
        .function = 0,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .after },
    });
    try actx.arc_ops.append(alloc, .{
        .kind = .release,
        .value = 30,
        .insertion_point = .{ .function = 0, .block = 0, .instr_index = 0, .position = .after },
        .reason = .perceus_drop,
    });

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "releaseAny(@TypeOf(__local_11), std.heap.page_allocator, __local_11);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "releaseAny(@TypeOf(__local_21), std.heap.page_allocator, __local_21);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "releaseAny(@TypeOf(__local_30)") == null);
}

test "codegen distinguishes block-local and function-local closure env names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const closure_instrs = [_]ir.Instruction{
        .{ .capture_get = .{ .dest = 0, .index = 0 } },
        .{ .ret = .{ .value = 0 } },
    };
    const closure_blocks = [_]ir.Block{.{ .label = 0, .instructions = &closure_instrs }};
    const closure_captures = [_]ir.Capture{.{ .name = "x", .type_expr = .i64, .ownership = .shared }};

    const main_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .make_closure = .{ .dest = 1, .function = 1, .captures = &[_]ir.LocalId{0} } },
        .{ .make_closure = .{ .dest = 2, .function = 2, .captures = &[_]ir.LocalId{0} } },
        .{ .ret = .{ .value = 0 } },
    };
    const main_blocks = [_]ir.Block{.{ .label = 0, .instructions = &main_instrs }};
    const main_params = [_]ir.Param{.{ .name = "x", .type_expr = .i64 }};

    const functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "main",
            .scope_id = 0,
            .arity = 1,
            .params = &main_params,
            .return_type = .i64,
            .body = &main_blocks,
            .is_closure = false,
            .captures = &.{},
        },
        .{
            .id = 1,
            .name = "block_cap",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &closure_blocks,
            .is_closure = true,
            .captures = &closure_captures,
        },
        .{
            .id = 2,
            .name = "frame_cap",
            .scope_id = 0,
            .arity = 0,
            .params = &.{},
            .return_type = .i64,
            .body = &closure_blocks,
            .is_closure = true,
            .captures = &closure_captures,
        },
    };
    const program = ir.Program{ .functions = &functions, .type_defs = &.{}, .entry = 0 };

    var actx = lattice_test.AnalysisContext.init(alloc);
    defer actx.deinit();
    try actx.closure_tiers.put(1, .block_local);
    try actx.closure_tiers.put(2, .function_local);

    var codegen = CodeGen.init(alloc);
    defer codegen.deinit();
    codegen.analysis_context = &actx;
    try codegen.emitProgram(&program);

    const output = codegen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "var __block_env_1 = __closure_env_1{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var __frame_env_2 = __closure_env_2{") != null);
}
