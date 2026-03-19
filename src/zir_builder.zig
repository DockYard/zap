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
extern "c" fn zir_builder_emit_if_else(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;
extern "c" fn zir_builder_emit_struct_init_anon(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;

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
    program: ?ir.Program,

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

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) !u32 {
        return self.local_refs.get(local) orelse return error.UnknownLocal;
    }

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        self.program = program;
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
        const ret_type = if (is_main)
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

            // Direct call by function ID — resolve name from program's function table
            .call_direct => |cd| {
                if (self.program) |prog| {
                    if (cd.function < prog.functions.len) {
                        const func_name = prog.functions[cd.function].name;
                        var args = std.ArrayListUnmanaged(u32).empty;
                        defer args.deinit(self.allocator);
                        for (cd.args) |arg| {
                            const ref = self.refForLocal(arg) catch continue;
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
                // Emit then-branch instructions
                for (ie.then_instrs) |ti| {
                    try self.emitInstruction(ti);
                }
                const then_ref = if (ie.then_result) |tr|
                    self.refForLocal(tr) catch return
                else
                    zir_builder_emit_void(self.handle);
                if (then_ref == error_ref) return error.EmitFailed;

                // Emit else-branch instructions
                for (ie.else_instrs) |ei| {
                    try self.emitInstruction(ei);
                }
                const else_ref = if (ie.else_result) |er|
                    self.refForLocal(er) catch return
                else
                    zir_builder_emit_void(self.handle);
                if (else_ref == error_ref) return error.EmitFailed;

                // Get condition ref and emit if_else
                const cond_ref = self.refForLocal(ie.condition) catch return;
                const ref = zir_builder_emit_if_else(self.handle, cond_ref, then_ref, else_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ie.dest, ref);
            },
            // TODO: case_block — needs ZIR block/condbr support for multi-arm matching
            .case_block => {},
            // TODO: switch_literal — needs ZIR switch support
            .switch_literal => {},
            // TODO: guard_block — needs ZIR block/condbr support for guard clauses
            .guard_block => {},
            // TODO: branch — needs ZIR block/br support
            .branch => {},
            // TODO: cond_branch — needs ZIR condbr support
            .cond_branch => {},
            // TODO: switch_tag — needs ZIR switch_block support
            .switch_tag => {},
            // TODO: switch_return — needs ZIR switch_block support
            .switch_return => {},
            // TODO: union_switch_return — needs ZIR switch_block support for tagged unions
            .union_switch_return => {},
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
            // TODO: case_break — needs ZIR block/break support
            .case_break => {},
            // TODO: jump — needs ZIR block/br support
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
                    const ref = self.refForLocal(elem) catch continue;
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
                    const ref = self.refForLocal(elem) catch continue;
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
            // TODO: map_init — needs C API for map/hash-map construction
            .map_init => {},
            .struct_init => |si| {
                // Named struct fields — use struct_init_anon with field names from IR
                var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens = std.ArrayListUnmanaged(u32).empty;
                defer names_lens.deinit(self.allocator);
                var values = std.ArrayListUnmanaged(u32).empty;
                defer values.deinit(self.allocator);

                for (si.fields) |field| {
                    const ref = self.refForLocal(field.value) catch continue;
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
            // TODO: field_set — needs C API for struct field mutation (store instruction)
            .field_set => {},
            .index_get => |ig| {
                // Tuple/list index access — use field_val with numeric field name
                const obj_ref = self.refForLocal(ig.object) catch return;
                const name = indexFieldName(ig.index);
                const ref = zir_builder_emit_field_val(self.handle, obj_ref, name.ptr, name.len);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ig.dest, ref);
            },
            // TODO: list_len_check — needs runtime length comparison support
            .list_len_check => {},
            .list_get => |lg| {
                // List element access — same as index_get, use field_val with numeric field name
                const list_ref = self.refForLocal(lg.list) catch return;
                const name = indexFieldName(lg.index);
                const ref = zir_builder_emit_field_val(self.handle, list_ref, name.ptr, name.len);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lg.dest, ref);
            },
            // TODO: union_init — needs C API for tagged union construction
            .union_init => {},

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
            // TODO: match_type — needs runtime type introspection (@TypeOf comparison)
            .match_type => {},
            // match_fail — emit void (pattern matching exhaustiveness is handled at Zap level)
            .match_fail => {},

            // TODO: closures — needs C API for closure capture/dispatch
            .call_dispatch => {},
            .call_closure => {},
            .make_closure => {},
            .capture_get => {},

            // TODO: optional_unwrap — needs C API for optional unwrap (.?)
            .optional_unwrap => {},

            // TODO: binary pattern matching — needs runtime binary introspection
            .bin_len_check => {},
            .bin_read_int => {},
            .bin_read_float => {},
            .bin_slice => {},
            .bin_read_utf8 => {},
            .bin_match_prefix => {},

            // TODO: memory / ARC — no-ops until ARC runtime is wired
            .alloc_owned => {},
            .retain => {},
            .release => {},

            // TODO: phi — needs ZIR block-param support for SSA phi nodes
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
