//! ZIR Builder — thin driver that calls C-ABI builder functions.
//!
//! The actual ZIR encoding logic lives in the Zig fork (~/projects/zig).
//! This module maps Zap IR instructions to C-ABI calls exported by
//! zir_api.zig in that fork.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;

const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();

// ---------------------------------------------------------------------------
// Opaque handles for the C-ABI boundary
// ---------------------------------------------------------------------------

pub const ZirBuilderHandle = opaque {};
pub const ZirContext = opaque {};

// ---------------------------------------------------------------------------
// C-ABI extern declarations (from zig fork's zir_api.zig)
// ---------------------------------------------------------------------------

// Lifecycle
extern "c" fn zir_builder_create() ?*ZirBuilderHandle;
extern "c" fn zir_builder_destroy(handle: ?*ZirBuilderHandle) void;

// Functions
extern "c" fn zir_builder_begin_func(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, ret_type: u32) i32;
extern "c" fn zir_builder_end_func(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_emit_param(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, type_ref: u32) u32;

// Emit instructions (return u32 Ref, 0xFFFFFFFF on error)
extern "c" fn zir_builder_emit_int(handle: ?*ZirBuilderHandle, value: i64) u32;
extern "c" fn zir_builder_emit_float(handle: ?*ZirBuilderHandle, value: f64) u32;
extern "c" fn zir_builder_emit_str(handle: ?*ZirBuilderHandle, ptr: [*]const u8, len: u32) u32;
extern "c" fn zir_builder_emit_bool(handle: ?*ZirBuilderHandle, value: bool) u32;
extern "c" fn zir_builder_emit_void(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_enum_literal(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
extern "c" fn zir_builder_emit_binop(handle: ?*ZirBuilderHandle, tag: u8, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_negate(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_bool_not(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_call(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, args_ptr: [*]const u32, args_len: u32) u32;
extern "c" fn zir_builder_emit_ret(handle: ?*ZirBuilderHandle, operand: u32) i32;
extern "c" fn zir_builder_emit_ret_void(handle: ?*ZirBuilderHandle) i32;

// Import, field access, struct init, call-by-ref
extern "c" fn zir_builder_emit_import(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
extern "c" fn zir_builder_emit_field_val(handle: ?*ZirBuilderHandle, object: u32, field_ptr: [*]const u8, field_len: u32) u32;
extern "c" fn zir_builder_emit_call_ref(handle: ?*ZirBuilderHandle, callee: u32, args_ptr: [*]const u32, args_len: u32) u32;
extern "c" fn zir_builder_emit_typeof(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_type_info(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_if_else(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;
extern "c" fn zir_builder_emit_struct_init_anon(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;

// Body tracking control (for branch body emission)
extern "c" fn zir_builder_set_body_tracking(handle: ?*ZirBuilderHandle, enabled: bool) void;
extern "c" fn zir_builder_get_inst_count(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_begin_capture(handle: ?*ZirBuilderHandle) void;
extern "c" fn zir_builder_end_capture(handle: ?*ZirBuilderHandle, out_len: *u32) [*]const u32;
extern "c" fn zir_builder_emit_if_else_bodies(handle: ?*ZirBuilderHandle, condition: u32, then_insts_ptr: [*]const u32, then_insts_len: u32, then_result: u32, else_insts_ptr: [*]const u32, else_insts_len: u32, else_result: u32) u32;

// Finalize and inject
extern "c" fn zir_builder_inject(builder_handle: ?*ZirBuilderHandle, compilation_handle: ?*ZirContext) i32;

// Module management
extern "c" fn zir_compilation_add_module(ctx: ?*ZirContext, name: [*:0]const u8, source_path: [*:0]const u8) i32;

// ---------------------------------------------------------------------------
// Error sentinel
// ---------------------------------------------------------------------------

const error_ref: u32 = 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// Binary op tag mapping (ZIR Inst.Tag u8 values)
// ---------------------------------------------------------------------------

const Zir = std.zig.Zir;

fn mapBinopTag(op: ir.BinaryOp.Op) ?u8 {
    return switch (op) {
        .add => @intFromEnum(Zir.Inst.Tag.add),
        .sub => @intFromEnum(Zir.Inst.Tag.sub),
        .mul => @intFromEnum(Zir.Inst.Tag.mul),
        .div => @intFromEnum(Zir.Inst.Tag.div),
        .rem_op => @intFromEnum(Zir.Inst.Tag.rem),
        .eq => @intFromEnum(Zir.Inst.Tag.cmp_eq),
        .neq => @intFromEnum(Zir.Inst.Tag.cmp_neq),
        .lt => @intFromEnum(Zir.Inst.Tag.cmp_lt),
        .gt => @intFromEnum(Zir.Inst.Tag.cmp_gt),
        .lte => @intFromEnum(Zir.Inst.Tag.cmp_lte),
        .gte => @intFromEnum(Zir.Inst.Tag.cmp_gte),
        .bool_and => @intFromEnum(Zir.Inst.Tag.bit_and),
        .bool_or => @intFromEnum(Zir.Inst.Tag.bit_or),
        .concat => null, // TODO: array_cat
    };
}

// ---------------------------------------------------------------------------
// Index field name helper — maps numeric index to string ("0", "1", ...)
// ---------------------------------------------------------------------------

/// Static string table for numeric field names 0-31. All pointers are stable
/// comptime string literals, so they remain valid across multiple calls.
const index_field_names = [_][]const u8{
    "0",  "1",  "2",  "3",  "4",  "5",  "6",  "7",
    "8",  "9",  "10", "11", "12", "13", "14", "15",
    "16", "17", "18", "19", "20", "21", "22", "23",
    "24", "25", "26", "27", "28", "29", "30", "31",
};

/// Returns a stable string pointer for a numeric index. For indices 0-31
/// this uses a comptime table (no allocation, pointer is always valid).
/// For larger indices, falls back to a static buffer.
fn indexFieldName(index: anytype) struct { ptr: [*]const u8, len: u32 } {
    const idx: u32 = @intCast(index);
    if (idx < index_field_names.len) {
        const name = index_field_names[idx];
        return .{ .ptr = name.ptr, .len = @intCast(name.len) };
    }
    // Indices >= 32 are unlikely for tuples. Fall back to a static buffer
    // — only valid until the next call with idx >= 32.
    const F = struct {
        var buf: [10]u8 = undefined;
    };
    const slice = std.fmt.bufPrint(&F.buf, "{d}", .{idx}) catch "0";
    return .{ .ptr = slice.ptr, .len = @intCast(slice.len) };
}

// ---------------------------------------------------------------------------
// Return type mapping (ir.ZigType -> ZIR Ref u32 value)
// ---------------------------------------------------------------------------

/// For main(), Zig requires void or u8 return type.
/// Map integer types to u8 (exit code), keep void as void.
fn mapMainReturnType(zig_type: ir.ZigType) u32 {
    return switch (zig_type) {
        .void => 0,
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize, .isize => @intFromEnum(Zir.Inst.Ref.u8_type),
        else => 0, // default to void
    };
}

fn mapReturnType(zig_type: ir.ZigType) u32 {
    return switch (zig_type) {
        .void => 0,
        .bool_type => @intFromEnum(Zir.Inst.Ref.bool_type),
        .i8 => @intFromEnum(Zir.Inst.Ref.i8_type),
        .i16 => @intFromEnum(Zir.Inst.Ref.i16_type),
        .i32 => @intFromEnum(Zir.Inst.Ref.i32_type),
        .i64 => @intFromEnum(Zir.Inst.Ref.i64_type),
        .u8 => @intFromEnum(Zir.Inst.Ref.u8_type),
        .u16 => @intFromEnum(Zir.Inst.Ref.u16_type),
        .u32 => @intFromEnum(Zir.Inst.Ref.u32_type),
        .u64 => @intFromEnum(Zir.Inst.Ref.u64_type),
        .usize => @intFromEnum(Zir.Inst.Ref.usize_type),
        .isize => @intFromEnum(Zir.Inst.Ref.isize_type),
        .f16 => @intFromEnum(Zir.Inst.Ref.f16_type),
        .f32 => @intFromEnum(Zir.Inst.Ref.f32_type),
        .f64 => @intFromEnum(Zir.Inst.Ref.f64_type),
        .string => @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
        else => 0, // default to void for unsupported types
    };
}

// ---------------------------------------------------------------------------
// Return type inference from IR body
// ---------------------------------------------------------------------------

/// Scan function body blocks for a `.ret` instruction with a value and try
/// to infer the return type from the instruction that produced the returned
/// local. Returns the ZIR Ref for the inferred type, or 0 if not inferable.
fn inferReturnTypeFromBody(body: []const ir.Block) u32 {
    for (body) |block| {
        if (inferReturnTypeFromInstrs(block.instructions)) |t| return t;
    }
    return 0;
}

/// Recursively scan an instruction slice for `.ret` with a value.
/// When found, walk backward through the same slice to determine the type
/// of the local being returned.
fn inferReturnTypeFromInstrs(instrs: []const ir.Instruction) ?u32 {
    for (instrs) |instr| {
        switch (instr) {
            .ret => |ret| {
                if (ret.value) |val| {
                    // Walk the instruction list to find what produced `val`
                    if (inferTypeForLocal(instrs, val)) |t| return t;
                    // Fallback: default to i64 (most common Zap type)
                    return @intFromEnum(Zir.Inst.Ref.i64_type);
                }
            },
            // Recurse into nested control flow that may contain returns
            .if_expr => |ie| {
                if (inferReturnTypeFromInstrs(ie.then_instrs)) |t| return t;
                if (inferReturnTypeFromInstrs(ie.else_instrs)) |t| return t;
            },
            .guard_block => |gb| {
                if (inferReturnTypeFromInstrs(gb.body)) |t| return t;
            },
            .case_block => |cb| {
                for (cb.arms) |arm| {
                    if (inferReturnTypeFromInstrs(arm.body_instrs)) |t| return t;
                }
                if (inferReturnTypeFromInstrs(cb.default_instrs)) |t| return t;
            },
            .switch_literal => |sl| {
                for (sl.cases) |case| {
                    if (inferReturnTypeFromInstrs(case.body_instrs)) |t| return t;
                }
                if (inferReturnTypeFromInstrs(sl.default_instrs)) |t| return t;
            },
            .switch_return => |sr| {
                for (sr.cases) |case| {
                    if (inferReturnTypeFromInstrs(case.body_instrs)) |t| return t;
                }
                if (inferReturnTypeFromInstrs(sr.default_instrs)) |t| return t;
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    if (inferReturnTypeFromInstrs(case.body_instrs)) |t| return t;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Given an instruction slice and a local id, find the instruction that
/// defines `local` and return the corresponding ZIR type ref.
fn inferTypeForLocal(instrs: []const ir.Instruction, local: ir.LocalId) ?u32 {
    for (instrs) |instr| {
        switch (instr) {
            .const_int => |ci| if (ci.dest == local) return @intFromEnum(Zir.Inst.Ref.i64_type),
            .const_float => |cf| if (cf.dest == local) return @intFromEnum(Zir.Inst.Ref.f64_type),
            .const_string => |cs| if (cs.dest == local) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
            .const_bool => |cb| if (cb.dest == local) return @intFromEnum(Zir.Inst.Ref.bool_type),
            .binary_op => |bo| if (bo.dest == local) {
                // Arithmetic/comparison ops: infer from operands
                return switch (bo.op) {
                    .eq, .neq, .lt, .gt, .lte, .gte, .bool_and, .bool_or => @intFromEnum(Zir.Inst.Ref.bool_type),
                    .concat => @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
                    else => @intFromEnum(Zir.Inst.Ref.i64_type), // add, sub, mul, div, rem
                };
            },
            .call_named => |cn| if (cn.dest == local) return @intFromEnum(Zir.Inst.Ref.i64_type),
            .call_direct => |cd| if (cd.dest == local) return @intFromEnum(Zir.Inst.Ref.i64_type),
            .call_builtin => |cbl| if (cbl.dest == local) return @intFromEnum(Zir.Inst.Ref.i64_type),
            .local_get => |lg| if (lg.dest == local) {
                // Trace through to the source local
                return inferTypeForLocal(instrs, lg.source);
            },
            .local_set => |ls| if (ls.dest == local) {
                return inferTypeForLocal(instrs, ls.value);
            },
            .param_get => |pg| if (pg.dest == local) {
                // Parameter — default to i64 (Zap's default numeric type)
                return @intFromEnum(Zir.Inst.Ref.i64_type);
            },
            else => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// ZirDriver
// ---------------------------------------------------------------------------

pub const ZirDriver = struct {
    handle: *ZirBuilderHandle,
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, u32),
    allocator: Allocator,
    program: ?ir.Program,
    /// Tracks the dest local of the enclosing case_block so that case_break
    /// can propagate its result value to the correct destination.
    current_case_dest: ?ir.LocalId = null,

    pub fn init(allocator: Allocator) !ZirDriver {
        const handle = zir_builder_create() orelse return error.ZirCreateFailed;
        return .{
            .handle = handle,
            .local_refs = .empty,
            .program = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZirDriver) void {
        zir_builder_destroy(self.handle);
        self.local_refs.deinit(self.allocator);
    }

    // -- Helpers --------------------------------------------------------------

    fn setLocal(self: *ZirDriver, local: ir.LocalId, ref: u32) !void {
        try self.local_refs.put(self.allocator, local, ref);
    }

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        return self.local_refs.get(local) orelse return error.EmitFailed;
    }

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        self.program = program;
        for (program.functions) |func| {
            try self.emitFunction(func);
        }
    }

    fn emitFunction(self: *ZirDriver, func: ir.Function) !void {
        self.local_refs.clearRetainingCapacity();

        // Zig's main must return void or u8. Check if body has a return value.
        const is_main = std.mem.eql(u8, func.name, "main");
        var ret_type = if (is_main)
            mapMainReturnType(func.return_type)
        else
            mapReturnType(func.return_type);

        // Blocker 1 fix: If the IR says void but the function body has a ret
        // with a value, the return type wasn't inferred by the front-end.
        // Scan the body to infer the return type from the returned expression.
        if (ret_type == 0 and !is_main) {
            ret_type = inferReturnTypeFromBody(func.body);
        }

        if (zir_builder_begin_func(self.handle, func.name.ptr, @intCast(func.name.len), ret_type) != 0) {
            return error.BeginFuncFailed;
        }

        // Emit param instructions and register their Refs as locals.
        // Each .param instruction in ZIR declares a parameter with a name and type.
        // Sema reads these from the declaration value body to know the function's arity.
        for (func.params, 0..) |param, i| {
            const param_type_ref = mapReturnType(param.type_expr);
            // If the type maps to 0 (void/unknown), use anytype by passing a
            // generic param. For now, default to i64 for untyped params since
            // Zap's dynamic types typically map to i64 in ZIR.
            const effective_type: u32 = if (param_type_ref == 0)
                @intFromEnum(Zir.Inst.Ref.i64_type)
            else
                param_type_ref;
            const param_ref = zir_builder_emit_param(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                effective_type,
            );
            if (param_ref == error_ref) return error.EmitFailed;
            try self.setLocal(@intCast(i), param_ref);
        }

        // Emit body blocks.
        for (func.body) |block| {
            for (block.instructions) |instr| {
                try self.emitInstruction(instr);
            }
        }

        if (zir_builder_end_func(self.handle) != 0) {
            return error.EndFuncFailed;
        }
    }

    // -- Instruction dispatch -------------------------------------------------

    fn emitInstruction(self: *ZirDriver, instr: ir.Instruction) BuildError!void {
        switch (instr) {
            // Constants
            .const_int => |ci| {
                const ref = zir_builder_emit_int(self.handle, ci.value);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ci.dest, ref);
            },
            .const_float => |cf| {
                const ref = zir_builder_emit_float(self.handle, cf.value);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cf.dest, ref);
            },
            .const_string => |cs| {
                const ref = zir_builder_emit_str(self.handle, cs.value.ptr, @intCast(cs.value.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cs.dest, ref);
            },
            .const_bool => |cb| {
                const ref = zir_builder_emit_bool(self.handle, cb.value);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cb.dest, ref);
            },
            .const_nil => |dest| {
                // Zap nil maps to Zig's null, not void.
                // Use the well-known ZIR ref for null_value directly.
                const ref = @intFromEnum(Zir.Inst.Ref.null_value);
                try self.setLocal(dest, ref);
            },
            .const_atom => |ca| {
                const ref = zir_builder_emit_enum_literal(self.handle, ca.value.ptr, @intCast(ca.value.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ca.dest, ref);
            },

            // Locals
            .local_get => |lg| {
                if (self.local_refs.get(lg.source)) |ref| {
                    try self.setLocal(lg.dest, ref);
                }
            },
            .local_set => |ls| {
                if (self.local_refs.get(ls.value)) |ref| {
                    try self.setLocal(ls.dest, ref);
                }
            },
            .param_get => |pg| {
                if (self.local_refs.get(pg.index)) |ref| {
                    try self.setLocal(pg.dest, ref);
                }
            },

            // Binary operations
            .binary_op => |bo| {
                if (mapBinopTag(bo.op)) |tag| {
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;
                    const ref = zir_builder_emit_binop(self.handle, tag, lhs, rhs);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else {
                    // concat — emit @import("zap_runtime").ZapString.concat(page_allocator, lhs, rhs)
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;

                    // Get std.heap.page_allocator for the allocator argument
                    const std_import = zir_builder_emit_import(self.handle, "std", 3);
                    if (std_import == error_ref) return error.EmitFailed;
                    const heap_mod = zir_builder_emit_field_val(self.handle, std_import, "heap", 4);
                    if (heap_mod == error_ref) return error.EmitFailed;
                    const alloc_ref = zir_builder_emit_field_val(self.handle, heap_mod, "page_allocator", 14);
                    if (alloc_ref == error_ref) return error.EmitFailed;

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const zap_string = zir_builder_emit_field_val(self.handle, rt_import, "ZapString", 9);
                    if (zap_string == error_ref) return error.EmitFailed;
                    const concat_fn = zir_builder_emit_field_val(self.handle, zap_string, "concat", 6);
                    if (concat_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ alloc_ref, lhs, rhs };
                    const ref = zir_builder_emit_call_ref(self.handle, concat_fn, &args, 3);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                }
            },

            // Unary operations
            .unary_op => |uo| {
                const operand = self.refForLocal(uo.operand) catch return;
                const ref = switch (uo.op) {
                    .negate => zir_builder_emit_negate(self.handle, operand),
                    .bool_not => zir_builder_emit_bool_not(self.handle, operand),
                };
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(uo.dest, ref);
            },

            // Returns
            .ret => |ret| {
                if (ret.value) |val| {
                    const ref = try self.refForLocal(val);
                    if (zir_builder_emit_ret(self.handle, ref) != 0) {
                        return error.EmitFailed;
                    }
                } else {
                    if (zir_builder_emit_ret_void(self.handle) != 0) {
                        return error.EmitFailed;
                    }
                }
            },

            // Named calls
            .call_named => |cn| {
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (cn.args) |arg| {
                    const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }

                // Route Kernel__* calls through @import("zap_runtime").Prelude.*
                if (std.mem.startsWith(u8, cn.name, "Kernel__")) {
                    const func_name = cn.name["Kernel__".len..];

                    // @import("zap_runtime")
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;

                    // .Prelude
                    const prelude = zir_builder_emit_field_val(self.handle, rt_import, "Prelude", 7);
                    if (prelude == error_ref) return error.EmitFailed;

                    // .println (or whatever function)
                    const fn_ref = zir_builder_emit_field_val(self.handle, prelude, func_name.ptr, @intCast(func_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;

                    // call(fn_ref, args)
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cn.dest, ref);
                } else {
                    const ref = zir_builder_emit_call(
                        self.handle,
                        cn.name.ptr,
                        @intCast(cn.name.len),
                        args.items.ptr,
                        @intCast(args.items.len),
                    );
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cn.dest, ref);
                }
            },

            // Builtin calls — emit @import("zap_runtime").Module.function(args)
            .call_builtin => |cb| {
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (cb.args) |arg| {
                    const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }

                // Parse "Module.function" from the builtin name.
                // e.g., "Prelude.println" → import zap_runtime, field "Prelude", field "println"
                if (std.mem.indexOfScalar(u8, cb.name, '.')) |dot_idx| {
                    const mod_name = cb.name[0..dot_idx];
                    const func_name = cb.name[dot_idx + 1 ..];

                    // @import("zap_runtime")
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;

                    // .Module (e.g., .Prelude)
                    const mod_ref = zir_builder_emit_field_val(self.handle, rt_import, mod_name.ptr, @intCast(mod_name.len));
                    if (mod_ref == error_ref) return error.EmitFailed;

                    // .function (e.g., .println)
                    const fn_ref = zir_builder_emit_field_val(self.handle, mod_ref, func_name.ptr, @intCast(func_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;

                    // call(fn_ref, args)
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                } else {
                    // Simple name — call directly
                    const ref = zir_builder_emit_call(
                        self.handle,
                        cb.name.ptr,
                        @intCast(cb.name.len),
                        args.items.ptr,
                        @intCast(args.items.len),
                    );
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                }
            },

            // Tail calls — call + ret
            .tail_call => |tc| {
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (tc.args) |arg| {
                    const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                const call_ref = zir_builder_emit_call(
                    self.handle,
                    tc.name.ptr,
                    @intCast(tc.name.len),
                    args.items.ptr,
                    @intCast(args.items.len),
                );
                if (call_ref == error_ref) return error.EmitFailed;
                if (zir_builder_emit_ret(self.handle, call_ref) != 0) {
                    return error.EmitFailed;
                }
            },

            // Enum literal
            .enum_literal => |el| {
                const ref = zir_builder_emit_enum_literal(self.handle, el.variant.ptr, @intCast(el.variant.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(el.dest, ref);
            },

            // Direct call by function ID — resolve name from program's function table
            .call_direct => |cd| {
                if (self.program) |prog| {
                    if (cd.function < prog.functions.len) {
                        const func_name = prog.functions[cd.function].name;
                        var args = std.ArrayListUnmanaged(u32).empty;
                        defer args.deinit(self.allocator);
                        for (cd.args) |arg| {
                            const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                            try args.append(self.allocator, ref);
                        }
                        const ref = zir_builder_emit_call(
                            self.handle,
                            func_name.ptr,
                            @intCast(func_name.len),
                            args.items.ptr,
                            @intCast(args.items.len),
                        );
                        if (ref != error_ref) {
                            try self.setLocal(cd.dest, ref);
                        }
                    }
                }
            },

            // Control flow
            .if_expr => |ie| {
                // Emit branch instructions with body tracking OFF so they
                // are NOT added to the function's main body. They will be
                // placed inside the condbr_inline's then/else bodies, so
                // Sema only analyzes (and executes) the taken branch.
                try self.emitIfExpr(ie);
            },
            .case_block => |cb| {
                // Body-tracked emission: chain if-else-bodies for each arm
                // so Sema only analyzes the matching branch.
                try self.emitCaseBlock(cb);
            },
            .switch_literal => |sl| {
                // Body-tracked emission: chain if-else-bodies for each case
                // so Sema only analyzes the matching branch.
                try self.emitSwitchLiteral(sl);
            },
            .guard_block => |gb| {
                // Body-tracked emission: place body instructions inside a
                // condbr_inline's then branch so Sema only analyzes (and
                // executes) the body when the guard condition is true.
                try self.emitGuardBlock(gb);
            },
            // Never generated by IrBuilder — verified in ir.zig:
            // AST .branch is desugared before reaching IR (lowerExpr hits unreachable).
            .branch => {},
            // Never generated by IrBuilder — verified in ir.zig.
            // Goto-style conditional branch; no IR lowering path creates this.
            .cond_branch => {},
            // Never generated by IrBuilder — verified in ir.zig.
            // Decision-tree .switch_tag nodes are lowered to match_atom + guard_block,
            // not to Instruction.switch_tag.
            .switch_tag => {},
            .switch_return => |sr| {
                // Body-tracked emission: chain if-else-bodies for each case
                // so Sema only analyzes the matching branch.
                try self.emitSwitchReturn(sr);
            },
            .union_switch_return => |usr| {
                // Body-tracked emission: chain if-else-bodies for each case
                // so Sema only analyzes the matching branch.
                try self.emitUnionSwitchReturn(usr);
            },
            .cond_return => |cr| {
                // Conditional return: if condition is true, return the value.
                // In comptime context, we emit the condition check and conditional ret.
                const cond_ref = self.refForLocal(cr.condition) catch return;
                if (cr.value) |val| {
                    const val_ref = self.refForLocal(val) catch return;
                    // Emit: if (cond) return val else void
                    const void_ref = zir_builder_emit_void(self.handle);
                    if (void_ref == error_ref) return error.EmitFailed;
                    const ret_val = zir_builder_emit_if_else(self.handle, cond_ref, val_ref, void_ref);
                    if (ret_val == error_ref) return error.EmitFailed;
                    // We can't conditionally return at ZIR level without condbr,
                    // so we emit a ret of the if_else result. This means the function
                    // always returns here — correct only when cond_return is the last
                    // instruction in its block.
                    if (zir_builder_emit_ret(self.handle, ret_val) != 0) {
                        return error.EmitFailed;
                    }
                } else {
                    // cond_return with no value — return void if condition is true
                    const void_ref = zir_builder_emit_void(self.handle);
                    if (void_ref == error_ref) return error.EmitFailed;
                    const ret_val = zir_builder_emit_if_else(self.handle, cond_ref, void_ref, void_ref);
                    if (ret_val == error_ref) return error.EmitFailed;
                    if (zir_builder_emit_ret(self.handle, ret_val) != 0) {
                        return error.EmitFailed;
                    }
                }
            },
            .case_break => |cbr| {
                // Generated by IrBuilder in lowerDecisionTreeForCase at decision
                // tree leaves. Propagates the matched arm's result value to the
                // enclosing case_block's dest local (tracked via current_case_dest).
                if (self.current_case_dest) |dest| {
                    if (cbr.value) |val| {
                        if (self.local_refs.get(val)) |ref| {
                            try self.setLocal(dest, ref);
                        }
                    }
                }
            },
            // Never generated by IrBuilder — verified in ir.zig.
            // Goto-style jump; no IR lowering path creates this.
            .jump => {},

            // Aggregates
            .tuple_init => |ti| {
                // Build field names ("0", "1", "2", ...) and value refs
                var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens = std.ArrayListUnmanaged(u32).empty;
                defer names_lens.deinit(self.allocator);
                var values = std.ArrayListUnmanaged(u32).empty;
                defer values.deinit(self.allocator);

                for (ti.elements, 0..) |elem, i| {
                    const ref = self.refForLocal(elem) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    // Use a static digit table for index names
                    const name = indexFieldName(i);
                    try names_ptrs.append(self.allocator, name.ptr);
                    try names_lens.append(self.allocator, name.len);
                    try values.append(self.allocator, ref);
                }

                const result = zir_builder_emit_struct_init_anon(
                    self.handle,
                    names_ptrs.items.ptr,
                    names_lens.items.ptr,
                    values.items.ptr,
                    @intCast(values.items.len),
                );
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(ti.dest, result);
            },
            .list_init => |li| {
                // Lists use the same representation as tuples — anonymous struct with numeric fields
                var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens = std.ArrayListUnmanaged(u32).empty;
                defer names_lens.deinit(self.allocator);
                var values = std.ArrayListUnmanaged(u32).empty;
                defer values.deinit(self.allocator);

                for (li.elements, 0..) |elem, i| {
                    const ref = self.refForLocal(elem) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    const name = indexFieldName(i);
                    try names_ptrs.append(self.allocator, name.ptr);
                    try names_lens.append(self.allocator, name.len);
                    try values.append(self.allocator, ref);
                }

                const result = zir_builder_emit_struct_init_anon(
                    self.handle,
                    names_ptrs.items.ptr,
                    names_lens.items.ptr,
                    values.items.ptr,
                    @intCast(values.items.len),
                );
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(li.dest, result);
            },
            .map_init => |mi| {
                // Build a map as an anonymous struct of {key, value} entry structs.
                // Each entry becomes a field named "0", "1", ... whose value is
                // an anonymous struct .{ .key = k, .value = v }.
                var entry_refs = std.ArrayListUnmanaged(u32).empty;
                defer entry_refs.deinit(self.allocator);
                var entry_names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer entry_names_ptrs.deinit(self.allocator);
                var entry_names_lens = std.ArrayListUnmanaged(u32).empty;
                defer entry_names_lens.deinit(self.allocator);

                for (mi.entries, 0..) |entry, i| {
                    const key_ref = self.refForLocal(entry.key) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    const val_ref = self.refForLocal(entry.value) catch @intFromEnum(Zir.Inst.Ref.void_value);

                    // Build a 2-field anonymous struct: .{ .key = key_ref, .value = val_ref }
                    const kv_names = [_][*]const u8{ "key", "value" };
                    const kv_lens = [_]u32{ 3, 5 };
                    const kv_vals = [_]u32{ key_ref, val_ref };
                    const kv_struct = zir_builder_emit_struct_init_anon(
                        self.handle,
                        &kv_names,
                        &kv_lens,
                        &kv_vals,
                        2,
                    );
                    if (kv_struct == error_ref) return error.EmitFailed;

                    const name = indexFieldName(i);
                    try entry_refs.append(self.allocator, kv_struct);
                    try entry_names_ptrs.append(self.allocator, name.ptr);
                    try entry_names_lens.append(self.allocator, name.len);
                }

                if (entry_refs.items.len > 0) {
                    const result = zir_builder_emit_struct_init_anon(
                        self.handle,
                        entry_names_ptrs.items.ptr,
                        entry_names_lens.items.ptr,
                        entry_refs.items.ptr,
                        @intCast(entry_refs.items.len),
                    );
                    if (result == error_ref) return error.EmitFailed;
                    try self.setLocal(mi.dest, result);
                } else {
                    // Empty map — emit empty struct via the well-known empty_tuple ref
                    const ref = @intFromEnum(Zir.Inst.Ref.empty_tuple);
                    try self.setLocal(mi.dest, ref);
                }
            },
            .struct_init => |si| {
                // Named struct fields — use struct_init_anon with field names from IR
                var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens = std.ArrayListUnmanaged(u32).empty;
                defer names_lens.deinit(self.allocator);
                var values = std.ArrayListUnmanaged(u32).empty;
                defer values.deinit(self.allocator);

                for (si.fields) |field| {
                    const ref = self.refForLocal(field.value) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try names_ptrs.append(self.allocator, field.name.ptr);
                    try names_lens.append(self.allocator, @intCast(field.name.len));
                    try values.append(self.allocator, ref);
                }

                const result = zir_builder_emit_struct_init_anon(
                    self.handle,
                    names_ptrs.items.ptr,
                    names_lens.items.ptr,
                    values.items.ptr,
                    @intCast(values.items.len),
                );
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(si.dest, result);
            },
            .field_get => |fg| {
                const obj_ref = self.refForLocal(fg.object) catch return;
                const ref = zir_builder_emit_field_val(self.handle, obj_ref, fg.field.ptr, @intCast(fg.field.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(fg.dest, ref);
            },
            .field_set => |fs| {
                // Codegen pattern: object.field = value;
                //
                // In ZIR, mutation requires two instructions:
                //   1. field_ptr — get a pointer to the struct field
                //   2. store     — write the value through that pointer
                //
                // The C-ABI builder currently exposes field_val (read) but not
                // field_ptr or store. Proper field mutation needs:
                //   - zir_builder_emit_field_ptr(handle, object_ref, field_name, field_len) -> ref
                //   - zir_builder_emit_store(handle, ptr_ref, value_ref) -> i32
                //
                // These correspond to ZIR instructions:
                //   - Zir.Inst.Tag.field_ptr (gets *FieldType from struct pointer)
                //   - Zir.Inst.Tag.store (writes value to pointer)
                //
                // As a workaround, we rebuild the struct with the updated field.
                // This is semantically correct for value-type structs (creates a
                // new struct with the field changed) and matches ZIR comptime
                // immutable semantics. The IR local for the object is rebound to
                // the new struct value.
                const obj_ref = self.refForLocal(fs.object) catch return;
                const val_ref = self.refForLocal(fs.value) catch return;

                // Emit a new anonymous struct with just the updated field, then
                // conceptually this replaces the object. In practice, for single-
                // field updates in comptime, the downstream code should use the
                // latest binding of the local.
                //
                // For a full solution: iterate all fields of the struct and rebuild
                // with field_val for unchanged fields and the new value for the
                // changed field. Since we don't know the struct's field list at this
                // IR level, we emit a field_val read of the field (to validate it
                // exists) and then rebind the object local to itself — effectively
                // a no-op that documents intent.
                //
                // The field_val call validates the field name exists on the object.
                const field_check = zir_builder_emit_field_val(self.handle, obj_ref, fs.field.ptr, @intCast(fs.field.len));
                _ = field_check; // Validates field exists; value is discarded.
                _ = val_ref; // Value to store — used when field_ptr+store are available.

                // TODO: When the C-ABI builder exposes zir_builder_emit_field_ptr
                // and zir_builder_emit_store, replace this with:
                //   const ptr = zir_builder_emit_field_ptr(self.handle, obj_ref, field, len);
                //   zir_builder_emit_store(self.handle, ptr, val_ref);
            },
            .index_get => |ig| {
                // Tuple/list index access — use field_val with numeric field name
                const obj_ref = self.refForLocal(ig.object) catch return;
                const name = indexFieldName(ig.index);
                const ref = zir_builder_emit_field_val(self.handle, obj_ref, name.ptr, name.len);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ig.dest, ref);
            },
            .list_len_check => |llc| {
                const list_ref = self.refForLocal(llc.scrutinee) catch return;
                const len_ref = zir_builder_emit_field_val(self.handle, list_ref, "len", 3);
                if (len_ref == error_ref) return error.EmitFailed;
                const expected_ref = zir_builder_emit_int(self.handle, @intCast(llc.expected_len));
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, len_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(llc.dest, ref);
            },
            .list_get => |lg| {
                // List element access — same as index_get, use field_val with numeric field name
                const list_ref = self.refForLocal(lg.list) catch return;
                const name = indexFieldName(lg.index);
                const ref = zir_builder_emit_field_val(self.handle, list_ref, name.ptr, name.len);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lg.dest, ref);
            },
            .union_init => |ui| {
                const val_ref = self.refForLocal(ui.value) catch return;
                const names = [_][*]const u8{ui.variant_name.ptr};
                const lens = [_]u32{@intCast(ui.variant_name.len)};
                const vals = [_]u32{val_ref};
                const ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ui.dest, ref);
            },

            // Pattern matching — emit comparisons using binop cmp_eq
            .match_atom => |ma| {
                // Compare scrutinee (enum literal) against expected atom via cmp_eq
                const scrutinee_ref = self.refForLocal(ma.scrutinee) catch return;
                const expected_ref = zir_builder_emit_enum_literal(self.handle, ma.atom_name.ptr, @intCast(ma.atom_name.len));
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ma.dest, ref);
            },
            .match_int => |mi| {
                // Compare scrutinee against expected int via cmp_eq
                const scrutinee_ref = self.refForLocal(mi.scrutinee) catch return;
                const expected_ref = zir_builder_emit_int(self.handle, mi.value);
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mi.dest, ref);
            },
            .match_float => |mf| {
                // Compare scrutinee against expected float via cmp_eq
                const scrutinee_ref = self.refForLocal(mf.scrutinee) catch return;
                const expected_ref = zir_builder_emit_float(self.handle, mf.value);
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mf.dest, ref);
            },
            .match_string => |ms| {
                // Compare scrutinee against expected string via cmp_eq
                const scrutinee_ref = self.refForLocal(ms.scrutinee) catch return;
                const expected_ref = zir_builder_emit_str(self.handle, ms.expected.ptr, @intCast(ms.expected.len));
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ms.dest, ref);
            },
            .match_type => |mt| {
                const scrutinee_ref = self.refForLocal(mt.scrutinee) catch return;

                // For .any, always matches — emit true
                if (mt.expected_type == .any) {
                    const ref = zir_builder_emit_bool(self.handle, true);
                    if (ref != error_ref) try self.setLocal(mt.dest, ref);
                    return;
                }

                // For tuple/struct types: check @typeInfo(@TypeOf(x)) == .@"struct"
                // and optionally check .fields.len == expected_arity
                if (mt.expected_type == .tuple or mt.expected_type == .struct_ref) {
                    // Step 1: @TypeOf(scrutinee)
                    const typeof_ref = zir_builder_emit_typeof(self.handle, scrutinee_ref);
                    if (typeof_ref == error_ref) return error.EmitFailed;

                    // Step 2: @typeInfo(typeof_result)
                    const type_info_ref = zir_builder_emit_type_info(self.handle, typeof_ref);
                    if (type_info_ref == error_ref) return error.EmitFailed;

                    // Step 3: Compare against .@"struct" enum literal
                    const struct_tag = zir_builder_emit_enum_literal(self.handle, "struct", 6);
                    if (struct_tag == error_ref) return error.EmitFailed;

                    const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                    const is_struct = zir_builder_emit_binop(self.handle, cmp_tag, type_info_ref, struct_tag);
                    if (is_struct == error_ref) return error.EmitFailed;

                    // Step 4: If arity check requested, also check fields.len
                    if (mt.expected_arity) |arity| {
                        // Get .@"struct" field from typeInfo result
                        const struct_info = zir_builder_emit_field_val(self.handle, type_info_ref, "struct", 6);
                        if (struct_info == error_ref) return error.EmitFailed;
                        // Get .fields from struct info
                        const fields = zir_builder_emit_field_val(self.handle, struct_info, "fields", 6);
                        if (fields == error_ref) return error.EmitFailed;
                        // Get .len from fields
                        const fields_len = zir_builder_emit_field_val(self.handle, fields, "len", 3);
                        if (fields_len == error_ref) return error.EmitFailed;
                        // Compare against expected arity
                        const arity_ref = zir_builder_emit_int(self.handle, @intCast(arity));
                        if (arity_ref == error_ref) return error.EmitFailed;
                        const len_match = zir_builder_emit_binop(self.handle, cmp_tag, fields_len, arity_ref);
                        if (len_match == error_ref) return error.EmitFailed;
                        // Both conditions must be true: is_struct AND len_match
                        const and_tag: u8 = @intFromEnum(Zir.Inst.Tag.bit_and);
                        const ref = zir_builder_emit_binop(self.handle, and_tag, is_struct, len_match);
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(mt.dest, ref);
                    } else {
                        try self.setLocal(mt.dest, is_struct);
                    }
                    return;
                }

                // For simple types, emit: @TypeOf(scrutinee) == expected_type_ref
                const expected_type_raw = mapReturnType(mt.expected_type);
                if (expected_type_raw == 0) {
                    // Unsupported type or void — emit true as fallback
                    const ref = zir_builder_emit_bool(self.handle, true);
                    if (ref != error_ref) try self.setLocal(mt.dest, ref);
                    return;
                }

                const typeof_ref = zir_builder_emit_typeof(self.handle, scrutinee_ref);
                if (typeof_ref == error_ref) return error.EmitFailed;

                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, typeof_ref, expected_type_raw);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mt.dest, ref);
            },
            .match_fail => |mf| {
                // Emit @import("zap_runtime").Prelude.panic(message)
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;

                const prelude = zir_builder_emit_field_val(self.handle, rt_import, "Prelude", 7);
                if (prelude == error_ref) return error.EmitFailed;

                const panic_fn = zir_builder_emit_field_val(self.handle, prelude, "panic", 5);
                if (panic_fn == error_ref) return error.EmitFailed;

                const msg_ref = zir_builder_emit_str(self.handle, mf.message.ptr, @intCast(mf.message.len));
                if (msg_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{msg_ref};
                _ = zir_builder_emit_call_ref(self.handle, panic_fn, &args, 1);
            },

            .call_dispatch => |cd| {
                var name_buf: [20]u8 = undefined;
                const name_slice: []const u8 = std.fmt.bufPrint(&name_buf, "dispatch_{d}", .{cd.group_id}) catch
                    @as([]const u8, "dispatch");
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (cd.args) |arg| {
                    const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                const ref = zir_builder_emit_call(self.handle, name_slice.ptr, @intCast(name_slice.len), args.items.ptr, @intCast(args.items.len));
                if (ref != error_ref) try self.setLocal(cd.dest, ref);
            },
            .call_closure => |cc| {
                const callee_ref = self.refForLocal(cc.callee) catch return;
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (cc.args) |arg| {
                    const ref = self.refForLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cc.dest, ref);
            },
            .make_closure => |mc| {
                // Build closure as anonymous struct: .{ .call_fn = func_ref, .env = .{cap0, cap1, ...} }
                //
                // 1. Resolve the function reference by name from the program's function table.
                //    We access it via @import("zap_runtime") or direct name, but since the
                //    closure target is a Zap-compiled function, emit a named reference.
                const func_name: []const u8 = if (self.program) |prog| blk: {
                    break :blk if (mc.function < prog.functions.len)
                        prog.functions[mc.function].name
                    else
                        "unknown_closure";
                } else "unknown_closure";

                // 2. Build the environment tuple: .{ capture0, capture1, ... }
                var env_names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer env_names_ptrs.deinit(self.allocator);
                var env_names_lens = std.ArrayListUnmanaged(u32).empty;
                defer env_names_lens.deinit(self.allocator);
                var env_values = std.ArrayListUnmanaged(u32).empty;
                defer env_values.deinit(self.allocator);

                for (mc.captures, 0..) |cap, i| {
                    const cap_ref = self.refForLocal(cap) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    const name = indexFieldName(i);
                    try env_names_ptrs.append(self.allocator, name.ptr);
                    try env_names_lens.append(self.allocator, name.len);
                    try env_values.append(self.allocator, cap_ref);
                }

                const env_ref = zir_builder_emit_struct_init_anon(
                    self.handle,
                    env_names_ptrs.items.ptr,
                    env_names_lens.items.ptr,
                    env_values.items.ptr,
                    @intCast(env_values.items.len),
                );
                if (env_ref == error_ref) return error.EmitFailed;

                // 3. Build the closure struct: .{ .call_fn = func_ref, .env = env_ref }
                //    For call_fn, emit a call to the named function with zero args to get
                //    a reference. In ZIR comptime context, we store the function name as
                //    a string so it can be resolved at call time.
                const fn_name_ref = zir_builder_emit_str(self.handle, func_name.ptr, @intCast(func_name.len));
                if (fn_name_ref == error_ref) return error.EmitFailed;

                const closure_field_names = [_][*]const u8{ "call_fn", "env" };
                const closure_field_lens = [_]u32{ 7, 3 };
                const closure_field_vals = [_]u32{ fn_name_ref, env_ref };
                const closure_ref = zir_builder_emit_struct_init_anon(
                    self.handle,
                    &closure_field_names,
                    &closure_field_lens,
                    &closure_field_vals,
                    2,
                );
                if (closure_ref == error_ref) return error.EmitFailed;
                try self.setLocal(mc.dest, closure_ref);
            },
            .capture_get => |cg| {
                // Access the closure environment by index.
                // The closure environment is passed as an implicit parameter.
                // In ZIR, we access it from the current function's capture context.
                //
                // For now, emit field access on the closure env using numeric index.
                // The closure env local is conventionally the first local (local 0)
                // in a closure function body — it's the `env` field of the closure struct.
                //
                // Access pattern: env_local.@"N" where N is the capture index
                const env_local: ir.LocalId = 0; // closure env is always local 0
                const env_ref = self.refForLocal(env_local) catch {
                    // Fallback: emit void if env not available
                    const ref = zir_builder_emit_void(self.handle);
                    if (ref != error_ref) try self.setLocal(cg.dest, ref);
                    return;
                };
                const name = indexFieldName(cg.index);
                const ref = zir_builder_emit_field_val(self.handle, env_ref, name.ptr, name.len);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cg.dest, ref);
            },

            .optional_unwrap => |ou| {
                // Codegen pattern: source orelse zap_runtime.panic("attempted to unwrap nil value")
                //
                // ZIR lacks a direct `orelse` expression. The builder would need:
                //   - .is_non_null to test whether source is non-null
                //   - .condbr to branch on the result
                //   - .optional_payload_safe / .optional_payload_unsafe in the non-null branch
                //   - panic call in the null branch
                //
                // Without condbr/optional_payload in the C-ABI builder, we use if_else
                // as a best-effort guard: emit panic infrastructure so it's available
                // when the builder gains condbr support, and pass through the source
                // value (correct for comptime non-optional values).
                //
                // TODO: When the C-ABI builder exposes zir_builder_emit_is_non_null,
                // zir_builder_emit_condbr, and zir_builder_emit_optional_payload,
                // replace this with a proper null-check + unwrap + panic-on-null.
                const source_ref = self.refForLocal(ou.source) catch return;

                // Emit the panic infrastructure so it's wired when condbr is available.
                // @import("zap_runtime").Prelude.panic("attempted to unwrap nil value")
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const prelude = zir_builder_emit_field_val(self.handle, rt_import, "Prelude", 7);
                if (prelude == error_ref) return error.EmitFailed;
                const panic_fn = zir_builder_emit_field_val(self.handle, prelude, "panic", 5);
                if (panic_fn == error_ref) return error.EmitFailed;

                const msg = "attempted to unwrap nil value";
                const msg_ref = zir_builder_emit_str(self.handle, msg.ptr, @intCast(msg.len));
                if (msg_ref == error_ref) return error.EmitFailed;

                const panic_args = [_]u32{msg_ref};
                const panic_call = zir_builder_emit_call_ref(self.handle, panic_fn, &panic_args, 1);
                if (panic_call == error_ref) return error.EmitFailed;

                // Use if_else as a guard: if source is null (Zap nil = Zig null),
                // the panic branch triggers; otherwise pass through source.
                // Emit: if_else(source == null, panic_call, source)
                const null_ref = @as(u32, @intFromEnum(Zir.Inst.Ref.null_value));
                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const is_nil = zir_builder_emit_binop(self.handle, cmp_tag, source_ref, null_ref);
                if (is_nil == error_ref) return error.EmitFailed;

                const result = zir_builder_emit_if_else(self.handle, is_nil, panic_call, source_ref);
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(ou.dest, result);
            },

            .bin_len_check => |blc| {
                const data_ref = self.refForLocal(blc.scrutinee) catch return;
                const len_ref = zir_builder_emit_field_val(self.handle, data_ref, "len", 3);
                if (len_ref == error_ref) return error.EmitFailed;
                const min_ref = zir_builder_emit_int(self.handle, @intCast(blc.min_len));
                if (min_ref == error_ref) return error.EmitFailed;
                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_gte);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, len_ref, min_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(blc.dest, ref);
            },
            .bin_read_int => |bri| {
                // Emit: @import("zap_runtime").BinaryHelpers.<readFunc>(source, offset[, bit_offset])
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = zir_builder_emit_field_val(self.handle, rt_import, "BinaryHelpers", 13);
                if (helpers == error_ref) return error.EmitFailed;

                // Choose the concrete helper based on bits, signed, endianness
                const func_name: []const u8 = if (bri.bits < 8 or bri.bits % 8 != 0)
                    "readBitsU"
                else if (bri.signed) switch (bri.bits) {
                    8 => "readIntI8",
                    16 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntI16Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntI16Little") else "readIntI16Big",
                        .little => "readIntI16Little",
                    },
                    32 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntI32Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntI32Little") else "readIntI32Big",
                        .little => "readIntI32Little",
                    },
                    64 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntI64Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntI64Little") else "readIntI64Big",
                        .little => "readIntI64Little",
                    },
                    else => if (native_endian == .little) @as([]const u8, "readIntI64Little") else "readIntI64Big",
                } else switch (bri.bits) {
                    8 => @as([]const u8, "readIntU8"),
                    16 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntU16Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntU16Little") else "readIntU16Big",
                        .little => "readIntU16Little",
                    },
                    32 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntU32Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntU32Little") else "readIntU32Big",
                        .little => "readIntU32Little",
                    },
                    64 => switch (bri.endianness) {
                        .big => @as([]const u8, "readIntU64Big"),
                        .native => if (native_endian == .little) @as([]const u8, "readIntU64Little") else "readIntU64Big",
                        .little => "readIntU64Little",
                    },
                    else => if (native_endian == .little) @as([]const u8, "readIntU64Little") else "readIntU64Big",
                };

                const fn_ref = zir_builder_emit_field_val(self.handle, helpers, func_name.ptr, @intCast(func_name.len));
                if (fn_ref == error_ref) return error.EmitFailed;

                const source_ref = self.refForLocal(bri.source) catch return;
                const offset_ref = switch (bri.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return,
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                if (bri.bits < 8 or bri.bits % 8 != 0) {
                    // Sub-byte: readBitsU(data, offset, bit_offset, bits)
                    const bit_off_ref = zir_builder_emit_int(self.handle, @intCast(bri.bit_offset));
                    if (bit_off_ref == error_ref) return error.EmitFailed;
                    const bits_ref = zir_builder_emit_int(self.handle, @intCast(bri.bits));
                    if (bits_ref == error_ref) return error.EmitFailed;
                    const args = [_]u32{ source_ref, offset_ref, bit_off_ref, bits_ref };
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 4);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bri.dest, ref);
                } else {
                    const args = [_]u32{ source_ref, offset_ref };
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bri.dest, ref);
                }
            },
            .bin_read_float => |brf| {
                // Emit: @import("zap_runtime").BinaryHelpers.<readFloatFunc>(source, offset)
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = zir_builder_emit_field_val(self.handle, rt_import, "BinaryHelpers", 13);
                if (helpers == error_ref) return error.EmitFailed;

                const func_name: []const u8 = switch (brf.bits) {
                    32 => switch (brf.endianness) {
                        .big => @as([]const u8, "readF32Big"),
                        .little => "readF32Little",
                        .native => if (native_endian == .little) @as([]const u8, "readF32Little") else "readF32Big",
                    },
                    64 => switch (brf.endianness) {
                        .big => @as([]const u8, "readF64Big"),
                        .little => "readF64Little",
                        .native => if (native_endian == .little) @as([]const u8, "readF64Little") else "readF64Big",
                    },
                    else => if (native_endian == .little) @as([]const u8, "readF64Little") else "readF64Big",
                };

                const fn_ref = zir_builder_emit_field_val(self.handle, helpers, func_name.ptr, @intCast(func_name.len));
                if (fn_ref == error_ref) return error.EmitFailed;

                const source_ref = self.refForLocal(brf.source) catch return;
                const offset_ref = switch (brf.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return,
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{ source_ref, offset_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(brf.dest, ref);
            },
            .bin_slice => |bs| {
                // Emit: @import("zap_runtime").BinaryHelpers.slice(source, offset, length)
                // length=0 is the sentinel for "rest of data" (null length in IR)
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = zir_builder_emit_field_val(self.handle, rt_import, "BinaryHelpers", 13);
                if (helpers == error_ref) return error.EmitFailed;
                const fn_ref = zir_builder_emit_field_val(self.handle, helpers, "slice", 5);
                if (fn_ref == error_ref) return error.EmitFailed;

                const source_ref = self.refForLocal(bs.source) catch return;
                const offset_ref = switch (bs.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return,
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                // null length means "rest of data" -- pass 0 as sentinel
                const length_ref = if (bs.length) |len| switch (len) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return,
                } else zir_builder_emit_int(self.handle, 0);
                if (length_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{ source_ref, offset_ref, length_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 3);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(bs.dest, ref);
            },
            .bin_read_utf8 => |bru| {
                // Two calls: utf8ByteLen for dest_len, utf8Decode for dest_codepoint
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = zir_builder_emit_field_val(self.handle, rt_import, "BinaryHelpers", 13);
                if (helpers == error_ref) return error.EmitFailed;

                const source_ref = self.refForLocal(bru.source) catch return;
                const offset_ref = switch (bru.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return,
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                // 1. dest_len = BinaryHelpers.utf8ByteLen(source, offset)
                const byte_len_fn = zir_builder_emit_field_val(self.handle, helpers, "utf8ByteLen", 11);
                if (byte_len_fn == error_ref) return error.EmitFailed;
                const len_args = [_]u32{ source_ref, offset_ref };
                const len_ref = zir_builder_emit_call_ref(self.handle, byte_len_fn, &len_args, 2);
                if (len_ref == error_ref) return error.EmitFailed;
                try self.setLocal(bru.dest_len, len_ref);

                // 2. dest_codepoint = BinaryHelpers.utf8Decode(source, offset, len)
                const decode_fn = zir_builder_emit_field_val(self.handle, helpers, "utf8Decode", 10);
                if (decode_fn == error_ref) return error.EmitFailed;
                const decode_args = [_]u32{ source_ref, offset_ref, len_ref };
                const cp_ref = zir_builder_emit_call_ref(self.handle, decode_fn, &decode_args, 3);
                if (cp_ref == error_ref) return error.EmitFailed;
                try self.setLocal(bru.dest_codepoint, cp_ref);
            },
            .bin_match_prefix => |bmp| {
                // Emit: @import("zap_runtime").BinaryHelpers.matchPrefix(source, expected)
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = zir_builder_emit_field_val(self.handle, rt_import, "BinaryHelpers", 13);
                if (helpers == error_ref) return error.EmitFailed;
                const fn_ref = zir_builder_emit_field_val(self.handle, helpers, "matchPrefix", 11);
                if (fn_ref == error_ref) return error.EmitFailed;

                const source_ref = self.refForLocal(bmp.source) catch return;
                const expected_ref = zir_builder_emit_str(self.handle, bmp.expected.ptr, @intCast(bmp.expected.len));
                if (expected_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{ source_ref, expected_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(bmp.dest, ref);
            },

            // Memory/ARC
            .alloc_owned => |ao| {
                // Codegen pattern: Arc(TypeName).init(allocator, value)
                //
                // The runtime's Arc(T) is a generic type — it requires a comptime
                // type parameter that ZIR cannot express dynamically (the type_name
                // is a runtime string like "MyStruct", not a ZIR type ref).
                //
                // To properly implement this, the runtime needs a non-generic helper:
                //   pub fn alloc_create(type_name: []const u8) *anyopaque
                // or a per-struct factory emitted by the Zap compiler.
                //
                // Alternatively, the ZIR backend could emit the allocation inline:
                //   const inner = std.heap.page_allocator.create(ArcInner(T));
                //   inner.* = .{ .header = ArcHeader.init(), .value = initial_value };
                // But this requires knowing T as a ZIR type ref, not a string name.
                //
                // For now, emit a struct_init_anon with an __arc_type marker field
                // so downstream passes can identify allocation sites. The dest local
                // is bound to a struct carrying the type name for diagnostic purposes.
                //
                // TODO: When the compiler emits typed struct definitions into ZIR,
                // replace this with: zir_builder_emit_alloc + Arc(T).init pattern.
                // Required C-ABI additions:
                //   - zir_builder_emit_type_ref(handle, type_name, len) -> u32
                //   - zir_builder_emit_alloc(handle, type_ref) -> u32
                const type_str = zir_builder_emit_str(self.handle, ao.type_name.ptr, @intCast(ao.type_name.len));
                if (type_str == error_ref) return error.EmitFailed;

                const field_names = [_][*]const u8{"__arc_type"};
                const field_lens = [_]u32{10};
                const field_vals = [_]u32{type_str};
                const marker = zir_builder_emit_struct_init_anon(
                    self.handle,
                    &field_names,
                    &field_lens,
                    &field_vals,
                    1,
                );
                if (marker == error_ref) return error.EmitFailed;
                try self.setLocal(ao.dest, marker);
            },
            .retain => |ret| {
                // Emit: @import("zap_runtime").ArcHeader.retainOpaque(value)
                const val_ref = self.refForLocal(ret.value) catch return;

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_header = zir_builder_emit_field_val(self.handle, rt_import, "ArcHeader", 9);
                if (arc_header == error_ref) return error.EmitFailed;
                const retain_fn = zir_builder_emit_field_val(self.handle, arc_header, "retainOpaque", 12);
                if (retain_fn == error_ref) return error.EmitFailed;

                const args = [_]u32{val_ref};
                _ = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
            },
            .release => |rel| {
                // Emit: @import("zap_runtime").ArcHeader.releaseOpaque(value)
                const val_ref = self.refForLocal(rel.value) catch return;

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_header = zir_builder_emit_field_val(self.handle, rt_import, "ArcHeader", 9);
                if (arc_header == error_ref) return error.EmitFailed;
                const release_fn = zir_builder_emit_field_val(self.handle, arc_header, "releaseOpaque", 13);
                if (release_fn == error_ref) return error.EmitFailed;

                const args = [_]u32{val_ref};
                _ = zir_builder_emit_call_ref(self.handle, release_fn, &args, 1);
            },

            // Never generated by IrBuilder — verified in ir.zig.
            // SSA phi nodes would merge values from different control flow paths;
            // the IR builder uses structured control flow (if_expr, case_block)
            // instead of SSA phi.
            .phi => {},
        }
    }

    /// Emit an if/else expression so that only the taken branch executes.
    ///
    /// Branch instructions are emitted with body tracking OFF and capture ON.
    /// The capture buffer collects only the top-level instruction indices
    /// (excluding internal sub-body instructions like call arg bodies).
    /// These captured indices are placed inside the condbr_inline's then/else
    /// bodies so that Sema only analyzes the taken branch.
    fn emitIfExpr(self: *ZirDriver, ie: ir.IfExpr) BuildError!void {
        // --- then branch: capture top-level body instructions ---
        zir_builder_begin_capture(self.handle);
        for (ie.then_instrs) |ti| {
            try self.emitInstruction(ti);
        }
        var then_len: u32 = 0;
        const then_insts_ptr = zir_builder_end_capture(self.handle, &then_len);

        const then_ref: u32 = if (ie.then_result) |tr|
            try self.refForLocal(tr)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Copy then indices — the capture buffer will be reused for else branch
        var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
        defer then_insts.deinit(self.allocator);
        then_insts.appendSliceAssumeCapacity(then_insts_ptr[0..then_len]);

        // --- else branch: capture top-level body instructions ---
        zir_builder_begin_capture(self.handle);
        for (ie.else_instrs) |ei| {
            try self.emitInstruction(ei);
        }
        var else_len: u32 = 0;
        const else_insts_ptr = zir_builder_end_capture(self.handle, &else_len);

        const else_ref: u32 = if (ie.else_result) |er|
            try self.refForLocal(er)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Get condition ref and emit the if_else with bodies
        const cond_ref = try self.refForLocal(ie.condition);
        const ref = zir_builder_emit_if_else_bodies(
            self.handle,
            cond_ref,
            then_insts.items.ptr,
            @intCast(then_insts.items.len),
            then_ref,
            else_insts_ptr,
            else_len,
            else_ref,
        );
        if (ref == error_ref) return error.EmitFailed;
        try self.setLocal(ie.dest, ref);
    }

    /// Emit a guard block: if (condition) { body } else { void }.
    /// Body instructions are captured and placed inside a condbr_inline's
    /// then branch so Sema only analyzes them when the condition is true.
    fn emitGuardBlock(self: *ZirDriver, gb: ir.GuardBlock) BuildError!void {
        const cond_ref = try self.refForLocal(gb.condition);

        // Capture body instructions
        zir_builder_begin_capture(self.handle);
        for (gb.body) |bi| try self.emitInstruction(bi);
        var body_len: u32 = 0;
        const body_ptr = zir_builder_end_capture(self.handle, &body_len);

        // Copy body indices (capture buffer may be reused)
        var body_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, body_len);
        defer body_insts.deinit(self.allocator);
        body_insts.appendSliceAssumeCapacity(body_ptr[0..body_len]);

        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

        // Emit: if (cond) { body } else { void }
        // The else branch is empty with a void result.
        const empty = [_]u32{};
        _ = zir_builder_emit_if_else_bodies(
            self.handle,
            cond_ref,
            body_insts.items.ptr,
            @intCast(body_insts.items.len),
            void_ref,
            &empty,
            0,
            void_ref,
        );
    }

    /// Emit a switch_literal as a chain of if-else-bodies:
    ///   if (scrutinee == case0.value) { case0.body }
    ///   else if (scrutinee == case1.value) { case1.body }
    ///   else { default_body }
    ///
    /// Built from the last case backwards so each if-else wraps the
    /// remaining cases as its else branch.
    fn emitSwitchLiteral(self: *ZirDriver, sl: ir.SwitchLiteral) BuildError!void {
        const scrutinee_ref = try self.refForLocal(sl.scrutinee);

        if (sl.cases.len == 0) {
            // No cases — just emit the default body directly
            for (sl.default_instrs) |di| try self.emitInstruction(di);
            if (sl.default_result) |dr| {
                if (self.local_refs.get(dr)) |ref| {
                    try self.setLocal(sl.dest, ref);
                }
            }
            return;
        }

        // Capture the default body
        zir_builder_begin_capture(self.handle);
        for (sl.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = zir_builder_end_capture(self.handle, &default_len);
        const default_result: u32 = if (sl.default_result) |dr|
            self.refForLocal(dr) catch @intFromEnum(Zir.Inst.Ref.void_value)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Copy default instructions
        var current_else_insts = try self.allocator.alloc(u32, default_len);
        @memcpy(current_else_insts, default_ptr[0..default_len]);
        var current_else_result: u32 = default_result;

        // Process cases in REVERSE order, building nested if-else from inside out.
        // Each iteration creates: if (scrutinee == case_val) { case_body } else { previous_else }
        var i = sl.cases.len;
        while (i > 0) {
            i -= 1;
            const case = sl.cases[i];

            // Emit the literal value for comparison
            const case_val_ref = switch (case.value) {
                .int => |v| zir_builder_emit_int(self.handle, v),
                .float => |v| zir_builder_emit_float(self.handle, v),
                .string => |v| zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len)),
                .bool_val => |v| zir_builder_emit_bool(self.handle, v),
            };
            if (case_val_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Emit: scrutinee == case_value
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, case_val_ref);
            if (cond_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Capture the case body
            zir_builder_begin_capture(self.handle);
            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            var case_len: u32 = 0;
            const case_ptr = zir_builder_end_capture(self.handle, &case_len);

            const case_result: u32 = if (case.result) |r|
                self.refForLocal(r) catch @intFromEnum(Zir.Inst.Ref.void_value)
            else
                @intFromEnum(Zir.Inst.Ref.void_value);

            // Copy case body (capture buffer will be reused)
            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (cond) { case_body } else { current_else }
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                case_result,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(case_insts);
            self.allocator.free(current_else_insts);

            if (ref == error_ref) return error.EmitFailed;

            // For the next outer case, this if-else becomes the else branch.
            // The emit_if_else_bodies call returns a ref to the block result.
            // We wrap it as a single-element else body for the next level.
            // Since the block_inline result IS the ref, we use an empty else
            // body with the ref as the result.
            current_else_insts = try self.allocator.alloc(u32, 0);
            current_else_result = ref;
        }

        self.allocator.free(current_else_insts);

        // The last ref produced is the result of the entire switch
        try self.setLocal(sl.dest, current_else_result);
    }

    /// Emit a case_block as a chain of if-else-bodies, one per arm.
    /// Pre-instructions are emitted normally (they set up scrutinee bindings).
    /// Each arm's condition instructions are emitted before the if-else that
    /// guards that arm's body, producing a nested if-else chain.
    fn emitCaseBlock(self: *ZirDriver, cb: ir.CaseBlock) BuildError!void {
        const saved_case_dest = self.current_case_dest;
        self.current_case_dest = cb.dest;
        defer self.current_case_dest = saved_case_dest;

        // Pre-instructions are setup (e.g., tuple arm guards) — emit normally
        for (cb.pre_instrs) |pi| try self.emitInstruction(pi);

        if (cb.arms.len == 0) {
            // No arms — just emit the default body
            for (cb.default_instrs) |di| try self.emitInstruction(di);
            if (cb.default_result) |dr| {
                if (self.local_refs.get(dr)) |ref| {
                    try self.setLocal(cb.dest, ref);
                }
            }
            return;
        }

        // Capture the default body
        zir_builder_begin_capture(self.handle);
        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = zir_builder_end_capture(self.handle, &default_len);
        const default_result: u32 = if (cb.default_result) |dr|
            self.refForLocal(dr) catch @intFromEnum(Zir.Inst.Ref.void_value)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        var current_else_insts = try self.allocator.alloc(u32, default_len);
        @memcpy(current_else_insts, default_ptr[0..default_len]);
        var current_else_result: u32 = default_result;

        // Process arms in REVERSE order
        var i = cb.arms.len;
        while (i > 0) {
            i -= 1;
            const arm = cb.arms[i];

            // Emit condition setup instructions (these define the condition local)
            for (arm.cond_instrs) |ci| try self.emitInstruction(ci);

            // Get the condition ref
            const cond_ref = try self.refForLocal(arm.condition);

            // Capture the arm body
            zir_builder_begin_capture(self.handle);
            for (arm.body_instrs) |bi| try self.emitInstruction(bi);
            var arm_len: u32 = 0;
            const arm_ptr = zir_builder_end_capture(self.handle, &arm_len);

            const arm_result: u32 = if (arm.result) |r|
                self.refForLocal(r) catch @intFromEnum(Zir.Inst.Ref.void_value)
            else
                @intFromEnum(Zir.Inst.Ref.void_value);

            const arm_insts = try self.allocator.alloc(u32, arm_len);
            @memcpy(arm_insts, arm_ptr[0..arm_len]);

            // Emit: if (arm.condition) { arm_body } else { current_else }
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                arm_insts.ptr,
                @intCast(arm_insts.len),
                arm_result,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(arm_insts);
            self.allocator.free(current_else_insts);

            if (ref == error_ref) return error.EmitFailed;

            current_else_insts = try self.allocator.alloc(u32, 0);
            current_else_result = ref;
        }

        self.allocator.free(current_else_insts);

        // The last ref produced is the result of the entire case block
        try self.setLocal(cb.dest, current_else_result);
    }

    /// Emit a switch_return as a chain of if-else-bodies.
    /// Each case compares the scrutinee parameter against the literal value
    /// and the body contains the return instruction.
    fn emitSwitchReturn(self: *ZirDriver, sr: ir.SwitchReturn) BuildError!void {
        const scrutinee_ref = try self.refForLocal(sr.scrutinee_param);

        if (sr.cases.len == 0) {
            // No cases — just emit the default body
            for (sr.default_instrs) |di| try self.emitInstruction(di);
            if (sr.default_result) |dr| {
                const ref = try self.refForLocal(dr);
                if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
            }
            return;
        }

        // Capture the default body (includes the return)
        zir_builder_begin_capture(self.handle);
        for (sr.default_instrs) |di| try self.emitInstruction(di);
        if (sr.default_result) |dr| {
            const ref = try self.refForLocal(dr);
            if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
        }
        var default_len: u32 = 0;
        const default_ptr = zir_builder_end_capture(self.handle, &default_len);
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

        var current_else_insts = try self.allocator.alloc(u32, default_len);
        @memcpy(current_else_insts, default_ptr[0..default_len]);
        var current_else_result: u32 = void_ref;

        // Process cases in REVERSE order
        var i = sr.cases.len;
        while (i > 0) {
            i -= 1;
            const case = sr.cases[i];

            // Emit the literal value for comparison
            const case_val_ref = switch (case.value) {
                .int => |v| zir_builder_emit_int(self.handle, v),
                .float => |v| zir_builder_emit_float(self.handle, v),
                .string => |v| zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len)),
                .bool_val => |v| zir_builder_emit_bool(self.handle, v),
            };
            if (case_val_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Emit: scrutinee == case_value
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, case_val_ref);
            if (cond_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Capture case body (includes the return)
            zir_builder_begin_capture(self.handle);
            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            if (case.return_value) |rv| {
                const ref = try self.refForLocal(rv);
                if (zir_builder_emit_ret(self.handle, ref) != 0) {
                    return error.EmitFailed;
                }
            }
            var case_len: u32 = 0;
            const case_ptr = zir_builder_end_capture(self.handle, &case_len);

            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (cond) { case_body_with_ret } else { current_else }
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                void_ref,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(case_insts);
            self.allocator.free(current_else_insts);

            if (ref == error_ref) return error.EmitFailed;

            current_else_insts = try self.allocator.alloc(u32, 0);
            current_else_result = ref;
        }

        self.allocator.free(current_else_insts);
    }

    /// Emit a union_switch_return as a chain of if-else-bodies.
    /// Each case checks if the scrutinee matches a variant name (via match_atom
    /// pattern) and the body contains the return instruction.
    fn emitUnionSwitchReturn(self: *ZirDriver, usr: ir.UnionSwitchReturn) BuildError!void {
        const scrutinee_ref = try self.refForLocal(usr.scrutinee_param);
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

        if (usr.cases.len == 0) return;

        // Build from the last case backwards. The innermost else is unreachable
        // (all cases should be covered), so use an empty body with void result.
        var current_else_insts = try self.allocator.alloc(u32, 0);
        var current_else_result: u32 = void_ref;

        var i = usr.cases.len;
        while (i > 0) {
            i -= 1;
            const case = usr.cases[i];

            // Emit: scrutinee == .variant_name (using enum literal comparison)
            const variant_ref = zir_builder_emit_enum_literal(self.handle, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (variant_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, variant_ref);
            if (cond_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Capture case body (includes field bindings + body + return)
            zir_builder_begin_capture(self.handle);
            // Emit field bindings from the union variant
            for (case.field_bindings) |fb| {
                const field_ref = zir_builder_emit_field_val(self.handle, scrutinee_ref, fb.field_name.ptr, @intCast(fb.field_name.len));
                if (field_ref != error_ref) {
                    // Bind the field to a local using the local_name as a key
                    // We use the field_binding index mapped to a local id
                    _ = fb.local_name; // consumed by setLocal below via body instructions
                }
            }
            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            if (case.return_value) |rv| {
                const ref = try self.refForLocal(rv);
                if (zir_builder_emit_ret(self.handle, ref) != 0) {
                    return error.EmitFailed;
                }
            }
            var case_len: u32 = 0;
            const case_ptr = zir_builder_end_capture(self.handle, &case_len);

            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (scrutinee == .variant) { case_body_with_ret } else { current_else }
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                void_ref,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(case_insts);
            self.allocator.free(current_else_insts);

            if (ref == error_ref) return error.EmitFailed;

            current_else_insts = try self.allocator.alloc(u32, 0);
            current_else_result = ref;
        }

        self.allocator.free(current_else_insts);
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const BuildError = error{
    ZirCreateFailed,
    BeginFuncFailed,
    EndFuncFailed,
    EmitFailed,
    UnknownLocal,
    ZirInjectionFailed,
    OutOfMemory,
};

pub fn buildAndInject(
    allocator: Allocator,
    program: ir.Program,
    compilation_ctx: *ZirContext,
    runtime_path: ?[:0]const u8,
) BuildError!void {
    // Register the runtime module if a path was provided.
    if (runtime_path) |rpath| {
        if (zir_compilation_add_module(compilation_ctx, "zap_runtime", rpath) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    var driver = try ZirDriver.init(allocator);

    driver.buildProgram(program) catch |err| {
        driver.deinit(); // destroy builder on error path
        return err;
    };

    // zir_builder_inject consumes the builder handle (frees it internally),
    // so we must NOT call zir_builder_destroy afterward.
    const result = zir_builder_inject(driver.handle, compilation_ctx);

    // Only clean up local_refs — handle was already freed by inject.
    driver.local_refs.deinit(allocator);

    if (result != 0) {
        return error.ZirInjectionFailed;
    }
}
