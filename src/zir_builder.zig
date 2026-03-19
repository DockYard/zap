//! ZIR Builder — thin driver that calls C-ABI builder functions.
//!
//! The actual ZIR encoding logic lives in the Zig fork (~/projects/zig).
//! This module maps Zap IR instructions to C-ABI calls exported by
//! zir_api.zig in that fork.

const std = @import("std");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;

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
        .div => @intFromEnum(Zir.Inst.Tag.div_trunc),
        .rem_op => @intFromEnum(Zir.Inst.Tag.rem),
        .eq => @intFromEnum(Zir.Inst.Tag.cmp_eq),
        .neq => @intFromEnum(Zir.Inst.Tag.cmp_neq),
        .lt => @intFromEnum(Zir.Inst.Tag.cmp_lt),
        .gt => @intFromEnum(Zir.Inst.Tag.cmp_gt),
        .lte => @intFromEnum(Zir.Inst.Tag.cmp_lte),
        .gte => @intFromEnum(Zir.Inst.Tag.cmp_gte),
        .bool_and => @intFromEnum(Zir.Inst.Tag.bool_br_and),
        .bool_or => @intFromEnum(Zir.Inst.Tag.bool_br_or),
        .concat => null, // TODO: array_cat
    };
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
        else => 0, // default to void for unsupported types
    };
}

// ---------------------------------------------------------------------------
// ZirDriver
// ---------------------------------------------------------------------------

pub const ZirDriver = struct {
    handle: *ZirBuilderHandle,
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, u32),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !ZirDriver {
        const handle = zir_builder_create() orelse return error.ZirCreateFailed;
        return .{
            .handle = handle,
            .local_refs = .empty,
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

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) !u32 {
        return self.local_refs.get(local) orelse return error.UnknownLocal;
    }

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        // Only emit the main/entry function (same as previous behavior).
        for (program.functions) |func| {
            if (!std.mem.eql(u8, func.name, "main")) continue;
            try self.emitFunction(func);
        }
    }

    fn emitFunction(self: *ZirDriver, func: ir.Function) !void {
        self.local_refs.clearRetainingCapacity();

        // Zig's main must return void or u8. Check if body has a return value.
        const is_main = std.mem.eql(u8, func.name, "main");
        const has_return_value = blk: {
            for (func.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .ret => |ret| if (ret.value != null) break :blk true,
                        else => {},
                    }
                }
            }
            break :blk false;
        };
        const ret_type = if (is_main and has_return_value)
            @intFromEnum(Zir.Inst.Ref.u8_type)
        else if (is_main)
            mapMainReturnType(func.return_type)
        else
            mapReturnType(func.return_type);
        if (zir_builder_begin_func(self.handle, func.name.ptr, @intCast(func.name.len), ret_type) != 0) {
            return error.BeginFuncFailed;
        }

        // Register params as locals.
        for (func.params, 0..) |_, i| {
            try self.setLocal(@intCast(i), @intCast(i));
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

    fn emitInstruction(self: *ZirDriver, instr: ir.Instruction) !void {
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
                const ref = zir_builder_emit_void(self.handle);
                if (ref == error_ref) return error.EmitFailed;
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
                const tag = mapBinopTag(bo.op) orelse return; // unsupported op (concat)
                const lhs = self.refForLocal(bo.lhs) catch return;
                const rhs = self.refForLocal(bo.rhs) catch return;
                const ref = zir_builder_emit_binop(self.handle, tag, lhs, rhs);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(bo.dest, ref);
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
                    const ref = self.refForLocal(val) catch return;
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
                    const ref = self.refForLocal(arg) catch continue;
                    try args.append(self.allocator, ref);
                }
                const ref = zir_builder_emit_call(
                    self.handle,
                    cn.name.ptr,
                    @intCast(cn.name.len),
                    args.items.ptr,
                    @intCast(args.items.len),
                );
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cn.dest, ref);
            },

            // Builtin calls — emit @import("zap_runtime").Module.function(args)
            .call_builtin => |cb| {
                var args = std.ArrayListUnmanaged(u32).empty;
                defer args.deinit(self.allocator);
                for (cb.args) |arg| {
                    const ref = self.refForLocal(arg) catch continue;
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
                    const ref = self.refForLocal(arg) catch continue;
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

            // TODO: call_direct — needs function table lookup
            .call_direct => {},

            // TODO: control flow (needs ZIR block support in C API)
            .if_expr => {},
            .case_block => {},
            .switch_literal => {},
            .guard_block => {},
            .branch => {},
            .cond_branch => {},
            .switch_tag => {},
            .switch_return => {},
            .union_switch_return => {},
            .cond_return => {},
            .case_break => {},
            .jump => {},

            // TODO: aggregates (needs C API support)
            .tuple_init => {},
            .list_init => {},
            .map_init => {},
            .struct_init => {},
            .field_get => {},
            .field_set => {},
            .index_get => {},
            .list_len_check => {},
            .list_get => {},
            .union_init => {},

            // TODO: pattern matching
            .match_atom => {},
            .match_int => {},
            .match_float => {},
            .match_string => {},
            .match_type => {},
            .match_fail => {},

            // TODO: closures
            .call_dispatch => {},
            .call_closure => {},
            .make_closure => {},
            .capture_get => {},

            // TODO: optional unwrap
            .optional_unwrap => {},

            // TODO: binary pattern matching
            .bin_len_check => {},
            .bin_read_int => {},
            .bin_read_float => {},
            .bin_slice => {},
            .bin_read_utf8 => {},
            .bin_match_prefix => {},

            // TODO: memory / ARC
            .alloc_owned => {},
            .retain => {},
            .release => {},

            // TODO: phi
            .phi => {},
        }
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
