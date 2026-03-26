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

// Field mutation and optional handling
extern "c" fn zir_builder_emit_field_ptr(handle: ?*ZirBuilderHandle, object: u32, field_ptr_arg: [*]const u8, field_len: u32) u32;
extern "c" fn zir_builder_emit_store(handle: ?*ZirBuilderHandle, ptr_ref: u32, value_ref: u32) i32;
extern "c" fn zir_builder_emit_is_non_null(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_optional_payload(handle: ?*ZirBuilderHandle, operand: u32) u32;

// Error union unwrapping
extern "c" fn zir_builder_emit_try(handle: ?*ZirBuilderHandle, operand: u32) u32;

// Tuple return type
extern "c" fn zir_builder_set_tuple_return_type(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) i32;
extern "c" fn zir_builder_get_tuple_return_type(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_get_tuple_return_type_len(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_struct_init_typed(handle: ?*ZirBuilderHandle, struct_type: u32, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;
extern "c" fn zir_builder_emit_tuple_decl(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) u32;
extern "c" fn zir_builder_emit_tuple_decl_body(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) u32;

// Body management
extern "c" fn zir_builder_pop_body_inst(handle: ?*ZirBuilderHandle) u32;

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
        else => @intFromEnum(Zir.Inst.Ref.none), // infer type
    };
}

/// Map a Zap type to a ZIR parameter type ref.
/// Unlike mapReturnType, unknown types map to anytype (.none) instead of void.
fn mapParamType(zig_type: ir.ZigType) u32 {
    return switch (zig_type) {
        .void => @intFromEnum(Zir.Inst.Ref.none),
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
        else => @intFromEnum(Zir.Inst.Ref.none), // anytype for unknown/struct types
    };
}

// ---------------------------------------------------------------------------
// ZirDriver
// ---------------------------------------------------------------------------

pub const ZirDriver = struct {
    handle: *ZirBuilderHandle,
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, u32),
    param_refs: std.ArrayListUnmanaged(u32),
    allocator: Allocator,
    program: ?ir.Program,
    lib_mode: bool = false,
    /// Builder entry point: when set, emits a `pub const zap_builder_entry`
    /// declaration pointing to this function. start.zig checks for this
    /// declaration to activate the builder runtime.
    builder_entry: ?[]const u8 = null,
    /// Tracks the dest local of the enclosing case_block so that case_break
    /// can propagate its result value to the correct destination.
    current_case_dest: ?ir.LocalId = null,
    /// The ZIR return type ref for the current function being emitted.
    /// 0 means void — used by the `.ret` handler to discard values from
    /// void functions instead of emitting a value return.
    current_ret_type: u32 = 0,
    /// Tracks how many tuple_init instructions have been emitted in the current function.
    tuple_init_count: u32 = 0,
    /// Nested tuple types in DFS post-order (inner-first), matching tuple_init emission order.
    tuple_type_stack: std.ArrayListUnmanaged(ir.ZigType) = .empty,
    /// ID of the function currently being emitted (for analysis lookups).
    current_function_id: ir.FunctionId = 0,
    /// Label of the current block.
    current_block_label: ir.LabelId = 0,
    /// Instruction index within the current block.
    current_instr_index: u32 = 0,
    current_block_instructions: []const ir.Instruction = &.{},
    skip_next_ret_local: ?ir.LocalId = null,
    /// Analysis results from the escape/region/ARC pipeline.
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext = null,
    reuse_backed_struct_locals: std.AutoHashMapUnmanaged(ir.LocalId, []const u8) = .empty,
    reuse_backed_union_locals: std.AutoHashMapUnmanaged(ir.LocalId, ir.UnionInit) = .empty,
    reuse_backed_tuple_locals: std.AutoHashMapUnmanaged(ir.LocalId, usize) = .empty,
    capture_param_refs: std.ArrayListUnmanaged(u32) = .empty,
    current_closure_env_ref: ?u32 = null,

    pub fn init(allocator: Allocator) !ZirDriver {
        const handle = zir_builder_create() orelse return error.ZirCreateFailed;
        return .{
            .handle = handle,
            .local_refs = .empty,
            .param_refs = .empty,
            .program = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZirDriver) void {
        zir_builder_destroy(self.handle);
        self.local_refs.deinit(self.allocator);
        self.param_refs.deinit(self.allocator);
        self.reuse_backed_struct_locals.deinit(self.allocator);
        self.reuse_backed_union_locals.deinit(self.allocator);
        self.reuse_backed_tuple_locals.deinit(self.allocator);
        self.capture_param_refs.deinit(self.allocator);
    }

    /// Check if ARC operations should be skipped for a value.
    /// Only skips when the value was explicitly analyzed and found stack-eligible.
    fn shouldSkipArc(self: *const ZirDriver, local: ir.LocalId) bool {
        const lattice = @import("escape_lattice.zig");
        if (self.analysis_context) |actx| {
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

    // -- Helpers --------------------------------------------------------------

    /// Map an IR ZigType to a ZIR Ref, recursively emitting tuple_decl for nested tuples.
    /// Used for declaration-body tuple_decl (param-like instructions).
    fn mapTupleElementType(self: *ZirDriver, zig_type: ir.ZigType) u32 {
        if (zig_type == .tuple) {
            var inner_refs = std.ArrayListUnmanaged(u32).empty;
            defer inner_refs.deinit(self.allocator);
            for (zig_type.tuple) |inner_elem| {
                inner_refs.append(self.allocator, self.mapTupleElementType(inner_elem)) catch return 0;
            }
            const ref = zir_builder_emit_tuple_decl(self.handle, inner_refs.items.ptr, @intCast(inner_refs.items.len));
            return if (ref == error_ref) 0 else ref;
        }
        return mapReturnType(zig_type);
    }

    /// Collect nested tuple types in DFS post-order (inner-first).
    /// This matches the order in which tuple_init IR instructions are emitted.
    fn collectNestedTupleTypes(self: *ZirDriver, zig_type: ir.ZigType) void {
        if (zig_type != .tuple) return;
        // Visit children first (inner tuples emitted before outer)
        for (zig_type.tuple) |elem| {
            self.collectNestedTupleTypes(elem);
        }
        // Then add this tuple type
        self.tuple_type_stack.append(self.allocator, zig_type) catch {};
    }

    /// Emit a body-local tuple_decl, recursively handling nested tuples.
    /// Returns the Ref to the emitted tuple_decl instruction.
    fn emitBodyLocalTupleType(self: *ZirDriver, zig_type: ir.ZigType) u32 {
        if (zig_type != .tuple) return mapReturnType(zig_type);
        var inner_refs = std.ArrayListUnmanaged(u32).empty;
        defer inner_refs.deinit(self.allocator);
        for (zig_type.tuple) |inner_elem| {
            inner_refs.append(self.allocator, self.emitBodyLocalTupleType(inner_elem)) catch return 0;
        }
        const ref = zir_builder_emit_tuple_decl_body(self.handle, inner_refs.items.ptr, @intCast(inner_refs.items.len));
        return if (ref == error_ref) 0 else ref;
    }

    fn setLocal(self: *ZirDriver, local: ir.LocalId, ref: u32) !void {
        try self.local_refs.put(self.allocator, local, ref);
    }

    fn emitAllocatorRef(self: *ZirDriver) BuildError!u32 {
        const std_import = zir_builder_emit_import(self.handle, "std", 3);
        if (std_import == error_ref) return error.EmitFailed;
        const heap_mod = zir_builder_emit_field_val(self.handle, std_import, "heap", 4);
        if (heap_mod == error_ref) return error.EmitFailed;
        const alloc_ref = zir_builder_emit_field_val(self.handle, heap_mod, "page_allocator", 14);
        if (alloc_ref == error_ref) return error.EmitFailed;
        return alloc_ref;
    }

    fn emitTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        return switch (zig_type) {
            .tuple => self.emitBodyLocalTupleType(zig_type),
            else => blk: {
                const ref = mapReturnType(zig_type);
                if (ref == @intFromEnum(Zir.Inst.Ref.none)) return error.EmitFailed;
                break :blk ref;
            },
        };
    }

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        return self.local_refs.get(local) orelse return error.EmitFailed;
    }

    fn markReuseBackedStructLocal(self: *ZirDriver, dest: ir.LocalId, type_name: []const u8) !void {
        try self.reuse_backed_struct_locals.put(self.allocator, dest, type_name);
    }

    fn propagateReuseBackedStructLocal(self: *ZirDriver, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_struct_locals.get(source)) |type_name| {
            try self.reuse_backed_struct_locals.put(self.allocator, dest, type_name);
        } else {
            _ = self.reuse_backed_struct_locals.remove(dest);
        }
    }

    fn markReuseBackedUnionLocal(self: *ZirDriver, union_init: ir.UnionInit) !void {
        try self.reuse_backed_union_locals.put(self.allocator, union_init.dest, union_init);
    }

    fn markReuseBackedTupleLocal(self: *ZirDriver, dest: ir.LocalId, arity: usize) !void {
        try self.reuse_backed_tuple_locals.put(self.allocator, dest, arity);
    }

    fn propagateReuseBackedUnionLocal(self: *ZirDriver, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_union_locals.get(source)) |union_init| {
            var copied = union_init;
            copied.dest = dest;
            try self.reuse_backed_union_locals.put(self.allocator, dest, copied);
        } else {
            _ = self.reuse_backed_union_locals.remove(dest);
        }
    }

    fn propagateReuseBackedTupleLocal(self: *ZirDriver, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.reuse_backed_tuple_locals.get(source)) |arity| {
            try self.reuse_backed_tuple_locals.put(self.allocator, dest, arity);
        } else {
            _ = self.reuse_backed_tuple_locals.remove(dest);
        }
    }

    fn findStructDef(self: *const ZirDriver, type_name: []const u8) ?ir.StructDef {
        const prog = self.program orelse return null;
        for (prog.type_defs) |type_def| {
            if (!std.mem.eql(u8, type_def.name, type_name)) continue;
            return switch (type_def.kind) {
                .struct_def => |def| def,
                else => null,
            };
        }
        return null;
    }

    fn refForValueLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        if (self.reuse_backed_tuple_locals.get(local)) |arity| {
            const ptr_ref = try self.refForLocal(local);
            var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens = std.ArrayListUnmanaged(u32).empty;
            defer names_lens.deinit(self.allocator);
            var values = std.ArrayListUnmanaged(u32).empty;
            defer values.deinit(self.allocator);
            for (0..arity) |i| {
                const name = indexFieldName(i);
                const field_ref = zir_builder_emit_field_val(self.handle, ptr_ref, name.ptr, name.len);
                if (field_ref == error_ref) return error.EmitFailed;
                try names_ptrs.append(self.allocator, name.ptr);
                try names_lens.append(self.allocator, name.len);
                try values.append(self.allocator, field_ref);
            }
            const value_ref = zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
            if (value_ref == error_ref) return error.EmitFailed;
            return value_ref;
        }
        if (self.reuse_backed_union_locals.get(local)) |union_init| {
            const ptr_ref = try self.refForLocal(local);
            const payload_ref = zir_builder_emit_field_val(self.handle, ptr_ref, union_init.variant_name.ptr, @intCast(union_init.variant_name.len));
            if (payload_ref == error_ref) return error.EmitFailed;
            const names = [_][*]const u8{union_init.variant_name.ptr};
            const lens = [_]u32{@intCast(union_init.variant_name.len)};
            const vals = [_]u32{payload_ref};
            const value_ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
            if (value_ref == error_ref) return error.EmitFailed;
            return value_ref;
        }
        if (self.reuse_backed_struct_locals.get(local)) |type_name| {
            const ptr_ref = try self.refForLocal(local);
            const struct_def = self.findStructDef(type_name) orelse return error.EmitFailed;

            var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens = std.ArrayListUnmanaged(u32).empty;
            defer names_lens.deinit(self.allocator);
            var values = std.ArrayListUnmanaged(u32).empty;
            defer values.deinit(self.allocator);

            for (struct_def.fields) |field| {
                const field_ref = zir_builder_emit_field_val(self.handle, ptr_ref, field.name.ptr, @intCast(field.name.len));
                if (field_ref == error_ref) return error.EmitFailed;
                try names_ptrs.append(self.allocator, field.name.ptr);
                try names_lens.append(self.allocator, @intCast(field.name.len));
                try values.append(self.allocator, field_ref);
            }

            const value_ref = zir_builder_emit_struct_init_anon(
                self.handle,
                names_ptrs.items.ptr,
                names_lens.items.ptr,
                values.items.ptr,
                @intCast(values.items.len),
            );
            if (value_ref == error_ref) return error.EmitFailed;
            return value_ref;
        }
        return self.refForLocal(local);
    }

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        self.program = program;
        for (program.functions) |func| {
            self.reuse_backed_struct_locals.clearRetainingCapacity();
            self.reuse_backed_union_locals.clearRetainingCapacity();
            self.reuse_backed_tuple_locals.clearRetainingCapacity();
            try self.emitFunction(func);
        }

        // In builder mode, emit a zap_builder_entry function that delegates
        // to the configured entry point. start.zig checks for this declaration
        // to activate the builder runtime.
        if (self.builder_entry) |entry_name| {
            // Emit zap_builder_entry() — detected by start.zig via @hasDecl.
            //
            // This function calls BuilderRuntime.buildAndSerialize which:
            // 1. Reads std.os.argv
            // 2. Constructs Zap.Env from argv
            // 3. Returns the env struct
            //
            // Then we call the manifest function with that env,
            // and pass the result to BuilderRuntime.serializeManifest.
            const marker_name = "zap_builder_entry";
            if (zir_builder_begin_func(self.handle, marker_name.ptr, @intCast(marker_name.len), 0) != 0) {
                return error.BeginFuncFailed;
            }

            // Get runtime: @import("zap_runtime")
            const rt = zir_builder_emit_import(self.handle, "zap_runtime", 11);
            if (rt == error_ref) return error.EmitFailed;

            // Call BuilderRuntime.buildEnvFromArgv() → returns env struct
            const builder_rt = zir_builder_emit_field_val(self.handle, rt, "BuilderRuntime", 14);
            if (builder_rt == error_ref) return error.EmitFailed;
            const build_env_fn = zir_builder_emit_field_val(self.handle, builder_rt, "buildEnvFromArgv", 16);
            if (build_env_fn == error_ref) return error.EmitFailed;
            const env = zir_builder_emit_call_ref(self.handle, build_env_fn, &.{}, 0);
            if (env == error_ref) return error.EmitFailed;

            // Call manifest(env) — the user's entry point
            const manifest_args = [_]u32{env};
            const manifest = zir_builder_emit_call(
                self.handle,
                entry_name.ptr,
                @intCast(entry_name.len),
                &manifest_args,
                1,
            );
            if (manifest == error_ref) return error.EmitFailed;

            // Call BuilderRuntime.serializeManifest(manifest)
            const serialize_fn = zir_builder_emit_field_val(self.handle, builder_rt, "serializeManifest", 17);
            if (serialize_fn == error_ref) return error.EmitFailed;
            const ser_args = [_]u32{manifest};
            _ = zir_builder_emit_call_ref(self.handle, serialize_fn, &ser_args, 1);

            if (zir_builder_emit_ret_void(self.handle) != 0) {
                return error.EmitFailed;
            }
            if (zir_builder_end_func(self.handle) != 0) {
                return error.EndFuncFailed;
            }
        }
    }

    fn emitFunction(self: *ZirDriver, func: ir.Function) !void {
        // Detect main function: bare "main" or module-prefixed "__main"
        const is_main = std.mem.eql(u8, func.name, "main") or
            std.mem.endsWith(u8, func.name, "__main");

        // In library mode, skip the main function.
        if (self.lib_mode and is_main) return;

        self.local_refs.clearRetainingCapacity();
        self.param_refs.clearRetainingCapacity();
        self.capture_param_refs.clearRetainingCapacity();
        self.current_closure_env_ref = null;
        self.current_function_id = func.id;
        const closure_lowering = self.getClosureLowering(func.id, func.captures.len);
        const ret_type = if (is_main)
            mapMainReturnType(func.return_type)
        else
            mapReturnType(func.return_type);

        self.current_ret_type = ret_type;

        // Emit entry point as "main" so Zig's std.start can find it
        const emit_name = if (is_main) "main" else func.name;
        if (zir_builder_begin_func(self.handle, emit_name.ptr, @intCast(emit_name.len), ret_type) != 0) {
            return error.BeginFuncFailed;
        }

        // Build the nested tuple type stack in DFS post-order (inner-first).
        self.tuple_init_count = 0;
        self.tuple_type_stack.clearRetainingCapacity();
        if (func.return_type == .tuple) {
            self.collectNestedTupleTypes(func.return_type);
        }

        // For tuple return types, set up the computed return type via tuple_decl.
        // Nested tuples are handled by recursively emitting tuple_decl instructions.
        if (func.return_type == .tuple) {
            var type_refs = std.ArrayListUnmanaged(u32).empty;
            defer type_refs.deinit(self.allocator);
            for (func.return_type.tuple) |elem_type| {
                try type_refs.append(self.allocator, self.mapTupleElementType(elem_type));
            }
            if (zir_builder_set_tuple_return_type(self.handle, type_refs.items.ptr, @intCast(type_refs.items.len)) != 0) {
                return error.EmitFailed;
            }
            self.current_ret_type = 1;
        }

        // Emit param instructions and register their Refs as locals.
        // Each .param instruction in ZIR declares a parameter with a name and type.
        // Sema reads these from the declaration value body to know the function's arity.
        //
        // Special case: main/1 — Zig's linker expects main to be void -> void,
        // so we don't emit a real parameter. Instead, we inject code at the
        // top of the body to get OS args via std.process.argsAlloc and store
        // the result as the first param's local ref.
        if (closure_lowering.direct_capture_params) {
            for (func.captures) |capture| {
                const capture_ref = zir_builder_emit_param(
                    self.handle,
                    capture.name.ptr,
                    @intCast(capture.name.len),
                    mapParamType(capture.type_expr),
                );
                if (capture_ref == error_ref) return error.EmitFailed;
                try self.capture_param_refs.append(self.allocator, capture_ref);
            }
            for (func.params, 0..) |param, i| {
                const effective_type: u32 = mapParamType(param.type_expr);
                const param_ref = zir_builder_emit_param(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    effective_type,
                );
                if (param_ref == error_ref) return error.EmitFailed;
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        } else if (closure_lowering.needs_env_param) {
            const env_param_ref = zir_builder_emit_param(self.handle, "__closure_env".ptr, 13, @intFromEnum(Zir.Inst.Ref.none));
            if (env_param_ref == error_ref) return error.EmitFailed;
            self.current_closure_env_ref = env_param_ref;
            for (func.params, 0..) |param, i| {
                const effective_type: u32 = mapParamType(param.type_expr);
                const param_ref = zir_builder_emit_param(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    effective_type,
                );
                if (param_ref == error_ref) return error.EmitFailed;
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        } else if (is_main and func.params.len == 1) {
            // Inject: const args = std.os.argv (no allocation needed)
            const std_import = zir_builder_emit_import(self.handle, "std", 3);
            if (std_import == error_ref) return error.EmitFailed;
            const os_mod = zir_builder_emit_field_val(self.handle, std_import, "os", 2);
            if (os_mod == error_ref) return error.EmitFailed;
            const args_ref = zir_builder_emit_field_val(self.handle, os_mod, "argv", 4);
            if (args_ref == error_ref) return error.EmitFailed;

            // Store as the first param's local ref
            try self.param_refs.append(self.allocator, args_ref);
            try self.setLocal(0, args_ref);
        } else {
            for (func.params, 0..) |param, i| {
                const effective_type: u32 = mapParamType(param.type_expr);
                const param_ref = zir_builder_emit_param(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    effective_type,
                );
                if (param_ref == error_ref) return error.EmitFailed;
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        }

        // Emit body blocks.
        for (func.body) |block| {
            self.current_block_label = block.label;
            self.current_block_instructions = block.instructions;
            for (block.instructions, 0..) |instr, instr_idx| {
                self.current_instr_index = @intCast(instr_idx);
                try self.emitAnalysisArcOps(true);
                try self.emitInstruction(instr);
                try self.emitAnalysisArcOps(false);
            }
        }

        if (zir_builder_end_func(self.handle) != 0) {
            return error.EndFuncFailed;
        }
    }

    // -- Instruction dispatch -------------------------------------------------

    fn getCallSiteSpecialization(self: *const ZirDriver) ?@import("escape_lattice.zig").CallSiteSpecialization {
        if (self.analysis_context) |actx| {
            return actx.getCallSiteSpecialization(.{
                .function = self.current_function_id,
                .block = self.current_block_label,
                .instr_index = self.current_instr_index,
            });
        }
        return null;
    }

    fn findReusePairForDest(self: *const ZirDriver, dest: ir.LocalId) ?@import("escape_lattice.zig").ReusePair {
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

    fn isParamDerivedClosure(self: *const ZirDriver, local: ir.LocalId) bool {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id != self.current_function_id) continue;
                for (func.body) |block| {
                    for (block.instructions) |instr| {
                        switch (instr) {
                            .param_get => |pg| if (pg.dest == local) return true,
                            else => {},
                        }
                    }
                }
            }
        }
        return false;
    }

    fn findClosureTarget(self: *const ZirDriver, local: ir.LocalId) ?ir.FunctionId {
        const target = self.findClosureCallTarget(local) orelse return null;
        return target.function_id;
    }

    const ClosureCallTarget = struct {
        function_id: ir.FunctionId,
        captures: []const ir.LocalId,
    };

    const ClosureLowering = struct {
        const StorageScope = enum {
            none,
            immediate,
            stack_block,
            stack_function,
            heap,
        };

        tier: @import("escape_lattice.zig").ClosureEnvTier,
        needs_env_param: bool,
        direct_capture_params: bool,
        needs_closure_object: bool,
        stack_env: bool,
        storage_scope: StorageScope,
    };

    fn closure_lowering_for_tier(tier: @import("escape_lattice.zig").ClosureEnvTier, capture_count: usize) ClosureLowering {
        const has_captures = capture_count != 0;
        return switch (tier) {
            .lambda_lifted => .{
                .tier = tier,
                .needs_env_param = false,
                .direct_capture_params = false,
                .needs_closure_object = true,
                .stack_env = false,
                .storage_scope = .none,
            },
            .immediate_invocation => .{
                .tier = tier,
                .needs_env_param = false,
                .direct_capture_params = has_captures,
                .needs_closure_object = false,
                .stack_env = false,
                .storage_scope = .immediate,
            },
            .block_local => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .direct_capture_params = false,
                .needs_closure_object = true,
                .stack_env = true,
                .storage_scope = .stack_block,
            },
            .function_local => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .direct_capture_params = false,
                .needs_closure_object = true,
                .stack_env = true,
                .storage_scope = .stack_function,
            },
            .escaping => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .direct_capture_params = false,
                .needs_closure_object = true,
                .stack_env = false,
                .storage_scope = .heap,
            },
        };
    }

    fn getClosureLowering(self: *const ZirDriver, function_id: ir.FunctionId, capture_count: usize) ClosureLowering {
        const lattice = @import("escape_lattice.zig");
        const tier = if (self.analysis_context) |actx|
            actx.getClosureTier(function_id)
        else if (capture_count == 0)
            lattice.ClosureEnvTier.lambda_lifted
        else
            lattice.ClosureEnvTier.escaping;
        return closure_lowering_for_tier(tier, capture_count);
    }

    fn currentClosureLowering(self: *const ZirDriver) ?ClosureLowering {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id != self.current_function_id) continue;
                if (!func.is_closure) return null;
                return self.getClosureLowering(func.id, func.captures.len);
            }
        }
        return null;
    }

    fn findClosureCallTarget(self: *const ZirDriver, local: ir.LocalId) ?ClosureCallTarget {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id != self.current_function_id) continue;
                for (func.body) |block| {
                    if (findClosureTargetInInstrs(block.instructions, local)) |target| return target;
                }
            }
        }
        return null;
    }

    fn findClosureTargetInInstrs(instrs: []const ir.Instruction, local: ir.LocalId) ?ClosureCallTarget {
        return findClosureTargetInInstrsDepth(instrs, local, 0);
    }

    fn findClosureTargetInInstrsDepth(instrs: []const ir.Instruction, local: ir.LocalId, depth: u8) ?ClosureCallTarget {
        if (depth > 32) return null;
        for (instrs) |instr| {
            switch (instr) {
                .make_closure => |mc| if (mc.dest == local) return .{ .function_id = mc.function, .captures = mc.captures },
                .local_get => |lg| if (lg.dest == local) {
                    if (findClosureTargetInInstrsDepth(instrs, lg.source, depth + 1)) |target| return target;
                },
                .local_set => |ls| if (ls.dest == local) {
                    if (findClosureTargetInInstrsDepth(instrs, ls.value, depth + 1)) |target| return target;
                },
                .move_value => |mv| if (mv.dest == local) {
                    if (findClosureTargetInInstrsDepth(instrs, mv.source, depth + 1)) |target| return target;
                },
                .share_value => |sv| if (sv.dest == local) {
                    if (findClosureTargetInInstrsDepth(instrs, sv.source, depth + 1)) |target| return target;
                },
                .if_expr => |ie| {
                    if (findClosureTargetInInstrsDepth(ie.then_instrs, local, depth)) |target| return target;
                    if (findClosureTargetInInstrsDepth(ie.else_instrs, local, depth)) |target| return target;
                },
                .case_block => |cb| {
                    if (findClosureTargetInInstrsDepth(cb.pre_instrs, local, depth)) |target| return target;
                    for (cb.arms) |arm| {
                        if (findClosureTargetInInstrsDepth(arm.cond_instrs, local, depth)) |target| return target;
                        if (findClosureTargetInInstrsDepth(arm.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInInstrsDepth(cb.default_instrs, local, depth)) |target| return target;
                },
                .guard_block => |gb| if (findClosureTargetInInstrsDepth(gb.body, local, depth)) |target| return target,
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        if (findClosureTargetInInstrsDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInInstrsDepth(sl.default_instrs, local, depth)) |target| return target;
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| {
                        if (findClosureTargetInInstrsDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                    if (findClosureTargetInInstrsDepth(sr.default_instrs, local, depth)) |target| return target;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| {
                        if (findClosureTargetInInstrsDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn emitNamedCallToTarget(self: *ZirDriver, target_id: ir.FunctionId, captures: []const ir.LocalId, args_locals: []const ir.LocalId) !u32 {
        const prog = self.program orelse return error.EmitFailed;
        if (target_id >= prog.functions.len) return error.EmitFailed;
        const target_name = prog.functions[target_id].name;
        const lowering = self.getClosureLowering(target_id, captures.len);
        var args = std.ArrayListUnmanaged(u32).empty;
        defer args.deinit(self.allocator);
        if (lowering.direct_capture_params) {
            for (captures) |capture| {
                const ref = self.refForValueLocal(capture) catch @intFromEnum(Zir.Inst.Ref.void_value);
                try args.append(self.allocator, ref);
            }
        }
        for (args_locals) |arg| {
            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
            try args.append(self.allocator, ref);
        }
        const ref = zir_builder_emit_call(self.handle, target_name.ptr, @intCast(target_name.len), args.items.ptr, @intCast(args.items.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn emitTailNamedCallToTarget(self: *ZirDriver, target_id: ir.FunctionId, captures: []const ir.LocalId, args_locals: []const ir.LocalId) !void {
        const ref = try self.emitNamedCallToTarget(target_id, captures, args_locals);
        if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
    }

    fn emitTailInvokeWrapperCall(self: *ZirDriver, callee: ir.LocalId, function_id: ir.FunctionId, args_locals: []const ir.LocalId) !bool {
        const prog = self.program orelse return false;
        if (function_id >= prog.functions.len) return false;

        const callee_ref = self.refForLocal(callee) catch return false;
        const env_ref = zir_builder_emit_field_val(self.handle, callee_ref, "env", 3);
        if (env_ref == error_ref) return false;

        const invoke_name = try std.fmt.allocPrint(self.allocator, "__closure_invoke_{d}", .{function_id});
        defer self.allocator.free(invoke_name);

        const func_def = prog.functions[function_id];
        var name_ptrs = try self.allocator.alloc([*]const u8, func_def.params.len);
        defer self.allocator.free(name_ptrs);
        var name_lens = try self.allocator.alloc(u32, func_def.params.len);
        defer self.allocator.free(name_lens);
        var values = try self.allocator.alloc(u32, func_def.params.len);
        defer self.allocator.free(values);
        for (func_def.params, 0..) |param, i| {
            name_ptrs[i] = param.name.ptr;
            name_lens[i] = @intCast(param.name.len);
            values[i] = if (i < args_locals.len)
                self.refForLocal(args_locals[i]) catch @intFromEnum(Zir.Inst.Ref.void_value)
            else
                @intFromEnum(Zir.Inst.Ref.void_value);
        }
        const arg_struct = zir_builder_emit_struct_init_anon(self.handle, name_ptrs.ptr, name_lens.ptr, values.ptr, @intCast(values.len));
        if (arg_struct == error_ref) return false;

        const call_args = [_]u32{ env_ref, arg_struct };
        const ref = zir_builder_emit_call(self.handle, invoke_name.ptr, @intCast(invoke_name.len), &call_args, 2);
        if (ref == error_ref) return false;
        if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
        return true;
    }

    fn isTailReturnOf(self: *const ZirDriver, local: ir.LocalId) bool {
        const next_idx = @as(usize, self.current_instr_index) + 1;
        if (next_idx >= self.current_block_instructions.len) return false;
        return switch (self.current_block_instructions[next_idx]) {
            .ret => |r| r.value != null and r.value.? == local,
            else => false,
        };
    }

    fn emitAnalysisArcOps(self: *ZirDriver, before: bool) !void {
        if (self.analysis_context) |actx| {
            for (actx.arc_ops.items) |op| {
                if (op.insertion_point.function != self.current_function_id) continue;
                if (op.insertion_point.block != self.current_block_label) continue;
                if (op.insertion_point.instr_index != self.current_instr_index) continue;
                if ((op.insertion_point.position == .before) != before) continue;
                switch (op.kind) {
                    .retain => {
                        if (!self.shouldSkipArc(op.value)) {
                            const val_ref = self.refForLocal(op.value) catch continue;
                            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                            if (rt_import == error_ref) return error.EmitFailed;
                            const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                            if (arc_runtime == error_ref) return error.EmitFailed;
                            const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAny", 9);
                            if (retain_fn == error_ref) return error.EmitFailed;
                            const args = [_]u32{val_ref};
                            _ = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
                        }
                    },
                    .release => {
                        if (op.reason == .perceus_drop) continue;
                        if (!self.shouldSkipArc(op.value)) {
                            const val_ref = self.refForLocal(op.value) catch continue;
                            const alloc_ref = try self.emitAllocatorRef();
                            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                            if (rt_import == error_ref) return error.EmitFailed;
                            const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                            if (arc_runtime == error_ref) return error.EmitFailed;
                            const release_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "releaseAny", 10);
                            if (release_fn == error_ref) return error.EmitFailed;
                            const args = [_]u32{ alloc_ref, val_ref };
                            _ = zir_builder_emit_call_ref(self.handle, release_fn, &args, 2);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn emitDropSpecializationsForCurrentInstr(self: *ZirDriver, value_local: ir.LocalId, constructor_tag: ?u32) !void {
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
                    const val_ref = self.refForLocal(drop_local) catch continue;
                    const alloc_ref = try self.emitAllocatorRef();
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const release_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "releaseAny", 10);
                    if (release_fn == error_ref) return error.EmitFailed;
                    const args = [_]u32{ alloc_ref, val_ref };
                    _ = zir_builder_emit_call_ref(self.handle, release_fn, &args, 2);
                }
            }
        }
    }

    fn emitPerceusResetForCase(self: *ZirDriver, cb: ir.CaseBlock) !void {
        if (self.analysis_context) |actx| {
            for (actx.reuse_pairs.items) |pair| {
                if (pair.reset.source == cb.dest) {
                    const source_ref = self.refForLocal(pair.reset.source) catch continue;
                    const alloc_ref = try self.emitAllocatorRef();
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const reset_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "resetAny", 8);
                    if (reset_fn == error_ref) return error.EmitFailed;
                    const args = [_]u32{ alloc_ref, source_ref };
                    const token_ref = zir_builder_emit_call_ref(self.handle, reset_fn, &args, 2);
                    if (token_ref == error_ref) return error.EmitFailed;
                    try self.setLocal(pair.reset.dest, token_ref);
                }
            }
        }
    }

    fn emitClosureSwitchDispatch(self: *ZirDriver, cc: ir.CallClosure, targets: []const ir.FunctionId) !bool {
        const prog = self.program orelse return false;
        const callee_ref = self.refForLocal(cc.callee) catch return false;
        const call_fn_ref = zir_builder_emit_field_val(self.handle, callee_ref, "call_fn", 7);
        if (call_fn_ref == error_ref) return false;

        var fallback_args = std.ArrayListUnmanaged(u32).empty;
        defer fallback_args.deinit(self.allocator);
        for (cc.args) |arg| {
            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
            try fallback_args.append(self.allocator, ref);
        }

        zir_builder_begin_capture(self.handle);
        const fallback_ref = zir_builder_emit_call_ref(self.handle, callee_ref, fallback_args.items.ptr, @intCast(fallback_args.items.len));
        if (fallback_ref == error_ref) return false;
        try self.setLocal(cc.dest, fallback_ref);
        var else_len: u32 = 0;
        const else_ptr = zir_builder_end_capture(self.handle, &else_len);
        var current_else_insts = try self.allocator.alloc(u32, else_len);
        @memcpy(current_else_insts, else_ptr[0..else_len]);
        var current_else_result = fallback_ref;

        var emitted = false;
        var i: usize = targets.len;
        while (i > 0) {
            i -= 1;
            const target_id = targets[i];
            if (target_id >= prog.functions.len) continue;
            if (prog.functions[target_id].captures.len != 0) continue;
            emitted = true;

            const target_name = prog.functions[target_id].name;
            const name_ref = zir_builder_emit_str(self.handle, target_name.ptr, @intCast(target_name.len));
            if (name_ref == error_ref) return error.EmitFailed;
            const cond_ref = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_eq), call_fn_ref, name_ref);
            if (cond_ref == error_ref) return error.EmitFailed;

            zir_builder_begin_capture(self.handle);
            const direct_ref = try self.emitNamedCallToTarget(target_id, &.{}, cc.args);
            try self.setLocal(cc.dest, direct_ref);
            var then_len: u32 = 0;
            const then_ptr = zir_builder_end_capture(self.handle, &then_len);
            const then_insts = try self.allocator.alloc(u32, then_len);
            @memcpy(then_insts, then_ptr[0..then_len]);

            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                then_insts.ptr,
                @intCast(then_insts.len),
                direct_ref,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(then_insts);
            self.allocator.free(current_else_insts);
            if (ref == error_ref) return error.EmitFailed;

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
        }

        defer self.allocator.free(current_else_insts);
        if (!emitted) return false;
        try self.setLocal(cc.dest, current_else_result);
        return true;
    }

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
                // Intern the atom string via the global atom table at runtime.
                // Emit: @import("zap_runtime").atomIntern("name", len)
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const intern_fn = zir_builder_emit_field_val(self.handle, rt_import, "atomIntern", 10);
                if (intern_fn == error_ref) return error.EmitFailed;
                const name_ref = zir_builder_emit_str(self.handle, ca.value.ptr, @intCast(ca.value.len));
                if (name_ref == error_ref) return error.EmitFailed;
                const len_ref = zir_builder_emit_int(self.handle, @intCast(ca.value.len));
                if (len_ref == error_ref) return error.EmitFailed;
                const args = [_]u32{ name_ref, len_ref };
                const ref = zir_builder_emit_call_ref(self.handle, intern_fn, &args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ca.dest, ref);
            },

            // Locals
            .local_get => |lg| {
                try self.propagateReuseBackedStructLocal(lg.dest, lg.source);
                try self.propagateReuseBackedUnionLocal(lg.dest, lg.source);
                try self.propagateReuseBackedTupleLocal(lg.dest, lg.source);
                if (self.local_refs.get(lg.source)) |ref| {
                    try self.setLocal(lg.dest, ref);
                }
            },
            .local_set => |ls| {
                try self.propagateReuseBackedStructLocal(ls.dest, ls.value);
                try self.propagateReuseBackedUnionLocal(ls.dest, ls.value);
                try self.propagateReuseBackedTupleLocal(ls.dest, ls.value);
                if (self.local_refs.get(ls.value)) |ref| {
                    try self.setLocal(ls.dest, ref);
                }
            },
            .move_value => |mv| {
                try self.propagateReuseBackedStructLocal(mv.dest, mv.source);
                try self.propagateReuseBackedUnionLocal(mv.dest, mv.source);
                try self.propagateReuseBackedTupleLocal(mv.dest, mv.source);
                if (self.local_refs.get(mv.source)) |ref| {
                    try self.setLocal(mv.dest, ref);
                }
            },
            .share_value => |sv| {
                try self.propagateReuseBackedStructLocal(sv.dest, sv.source);
                try self.propagateReuseBackedUnionLocal(sv.dest, sv.source);
                try self.propagateReuseBackedTupleLocal(sv.dest, sv.source);
                if (self.local_refs.get(sv.source)) |ref| {
                    try self.setLocal(sv.dest, ref);

                    if (!self.shouldSkipArc(sv.source)) {
                        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                        if (rt_import == error_ref) return error.EmitFailed;
                        const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                        if (arc_runtime == error_ref) return error.EmitFailed;
                        const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAny", 9);
                        if (retain_fn == error_ref) return error.EmitFailed;

                        const args = [_]u32{ref};
                        _ = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
                    }
                }
            },
            .param_get => |pg| {
                // Look up param ref from the dedicated param_refs array,
                // NOT from local_refs which may have been overwritten by
                // earlier param_get dest assignments.
                if (pg.index < self.param_refs.items.len) {
                    try self.setLocal(pg.dest, self.param_refs.items[pg.index]);
                } else if (self.local_refs.get(pg.index)) |ref| {
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
                    // concat — emit @import("zap_runtime").ZapString.concatBump(lhs, rhs)
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const zap_string = zir_builder_emit_field_val(self.handle, rt_import, "ZapString", 9);
                    if (zap_string == error_ref) return error.EmitFailed;
                    const concat_fn = zir_builder_emit_field_val(self.handle, zap_string, "concatBump", 10);
                    if (concat_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ lhs, rhs };
                    const ref = zir_builder_emit_call_ref(self.handle, concat_fn, &args, 2);
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
                if (self.skip_next_ret_local) |local| {
                    if (ret.value != null and ret.value.? == local) {
                        self.skip_next_ret_local = null;
                        return;
                    }
                }
                if (self.current_ret_type == 0) {
                    // Void function — always return void, discarding any value.
                    // In Zap, the last expression is the implicit return but
                    // void functions (including main) should not return it.
                    if (zir_builder_emit_ret_void(self.handle) != 0) {
                        return error.EmitFailed;
                    }
                } else if (ret.value) |val| {
                    const ref = try self.refForValueLocal(val);
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
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }

                // Route stdlib module calls through @import("zap_runtime")
                const is_kernel = std.mem.startsWith(u8, cn.name, "Kernel__");
                const is_io = std.mem.startsWith(u8, cn.name, "IO__");
                const is_string = std.mem.startsWith(u8, cn.name, "String__");
                const is_atom = std.mem.startsWith(u8, cn.name, "Atom__");
                const is_integer = std.mem.startsWith(u8, cn.name, "Integer__");
                const is_float = std.mem.startsWith(u8, cn.name, "Float__");
                const is_system = std.mem.startsWith(u8, cn.name, "System__");
                if (is_kernel or is_io or is_string or is_atom or is_integer or is_float or is_system) {
                    // Map function names to their runtime module.function equivalents
                    const func_name = if (is_kernel)
                        cn.name["Kernel__".len..]
                    else if (is_string)
                        cn.name["String__".len..]
                    else if (is_atom)
                        cn.name["Atom__".len..]
                    else if (is_integer)
                        cn.name["Integer__".len..]
                    else if (is_float)
                        cn.name["Float__".len..]
                    else if (is_system)
                        cn.name["System__".len..]
                    else if (std.mem.eql(u8, cn.name["IO__".len..], "puts"))
                        "println"
                    else
                        cn.name["IO__".len..];

                    // @import("zap_runtime")
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;

                    // Route to the correct runtime module
                    const mod_name: []const u8 = if (is_string) "ZapString" else "Prelude";
                    const mod_ref = zir_builder_emit_field_val(self.handle, rt_import, mod_name.ptr, @intCast(mod_name.len));
                    if (mod_ref == error_ref) return error.EmitFailed;

                    // .function_name
                    const fn_ref = zir_builder_emit_field_val(self.handle, mod_ref, func_name.ptr, @intCast(func_name.len));
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
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
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
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
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

            // Enum literal — intern as atom
            .enum_literal => |el| {
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const intern_fn = zir_builder_emit_field_val(self.handle, rt_import, "atomIntern", 10);
                if (intern_fn == error_ref) return error.EmitFailed;
                const name_ref = zir_builder_emit_str(self.handle, el.variant.ptr, @intCast(el.variant.len));
                if (name_ref == error_ref) return error.EmitFailed;
                const len_ref = zir_builder_emit_int(self.handle, @intCast(el.variant.len));
                if (len_ref == error_ref) return error.EmitFailed;
                const args = [_]u32{ name_ref, len_ref };
                const ref = zir_builder_emit_call_ref(self.handle, intern_fn, &args, 2);
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
                            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
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
            .jump => |j| {
                if (j.bind_dest) |dest| {
                    if (j.value) |value| {
                        const ref = try self.refForValueLocal(value);
                        try self.setLocal(dest, ref);
                    }
                }
            },

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
                    const name = indexFieldName(i);
                    try names_ptrs.append(self.allocator, name.ptr);
                    try names_lens.append(self.allocator, name.len);
                    try values.append(self.allocator, ref);
                }

                // Map each tuple_init to its nested type using the DFS post-order stack.
                const body_local_type = if (self.tuple_init_count < self.tuple_type_stack.items.len) blk: {
                    const tuple_type = self.tuple_type_stack.items[self.tuple_init_count];
                    self.tuple_init_count += 1;
                    break :blk self.emitBodyLocalTupleType(tuple_type);
                } else blk: {
                    self.tuple_init_count += 1;
                    break :blk @as(u32, 0);
                };
                if (self.findReusePairForDest(ti.dest)) |pair| {
                    const seed_ref = if (body_local_type != 0)
                        zir_builder_emit_struct_init_typed(
                            self.handle,
                            body_local_type,
                            names_ptrs.items.ptr,
                            names_lens.items.ptr,
                            values.items.ptr,
                            @intCast(values.items.len),
                        )
                    else
                        zir_builder_emit_struct_init_anon(
                            self.handle,
                            names_ptrs.items.ptr,
                            names_lens.items.ptr,
                            values.items.ptr,
                            @intCast(values.items.len),
                        );
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    const token_local = pair.reuse.token orelse return error.EmitFailed;
                    const token_ref = try self.refForLocal(token_local);
                    const alloc_ref = try self.emitAllocatorRef();
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const reuse_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "reuseAllocByType", 16);
                    if (reuse_fn == error_ref) return error.EmitFailed;
                    const args = [_]u32{ type_ref, alloc_ref, token_ref };
                    const ptr_ref = zir_builder_emit_call_ref(self.handle, reuse_fn, &args, 3);
                    if (ptr_ref == error_ref) return error.EmitFailed;
                    for (0..ti.elements.len) |i| {
                        const name = indexFieldName(i);
                        const ptr = zir_builder_emit_field_ptr(self.handle, ptr_ref, name.ptr, name.len);
                        if (ptr == error_ref) return error.EmitFailed;
                        if (zir_builder_emit_store(self.handle, ptr, values.items[i]) != 0) return error.EmitFailed;
                    }
                    try self.markReuseBackedTupleLocal(ti.dest, ti.elements.len);
                    try self.setLocal(ti.dest, ptr_ref);
                } else {
                    _ = self.reuse_backed_tuple_locals.remove(ti.dest);
                    const result = if (body_local_type != 0)
                        zir_builder_emit_struct_init_typed(
                            self.handle,
                            body_local_type,
                            names_ptrs.items.ptr,
                            names_lens.items.ptr,
                            values.items.ptr,
                            @intCast(values.items.len),
                        )
                    else
                        zir_builder_emit_struct_init_anon(
                            self.handle,
                            names_ptrs.items.ptr,
                            names_lens.items.ptr,
                            values.items.ptr,
                            @intCast(values.items.len),
                        );
                    if (result == error_ref) return error.EmitFailed;
                    try self.setLocal(ti.dest, result);
                }
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
                var names_ptrs = std.ArrayListUnmanaged([*]const u8).empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens = std.ArrayListUnmanaged(u32).empty;
                defer names_lens.deinit(self.allocator);
                var values = std.ArrayListUnmanaged(u32).empty;
                defer values.deinit(self.allocator);

                for (si.fields) |field| {
                    const ref = self.refForValueLocal(field.value) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try names_ptrs.append(self.allocator, field.name.ptr);
                    try names_lens.append(self.allocator, @intCast(field.name.len));
                    try values.append(self.allocator, ref);
                }

                if (self.findReusePairForDest(si.dest)) |pair| {
                    const seed_ref = zir_builder_emit_struct_init_anon(
                        self.handle,
                        names_ptrs.items.ptr,
                        names_lens.items.ptr,
                        values.items.ptr,
                        @intCast(values.items.len),
                    );
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    const token_local = pair.reuse.token orelse return error.EmitFailed;
                    const token_ref = try self.refForLocal(token_local);
                    const alloc_ref = try self.emitAllocatorRef();
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const reuse_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "reuseAllocByType", 16);
                    if (reuse_fn == error_ref) return error.EmitFailed;
                    const args = [_]u32{ type_ref, alloc_ref, token_ref };
                    const ptr_ref = zir_builder_emit_call_ref(self.handle, reuse_fn, &args, 3);
                    if (ptr_ref == error_ref) return error.EmitFailed;
                    for (si.fields) |field| {
                        const value_ref = self.refForValueLocal(field.value) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        const ptr = zir_builder_emit_field_ptr(self.handle, ptr_ref, field.name.ptr, @intCast(field.name.len));
                        if (ptr == error_ref) return error.EmitFailed;
                        if (zir_builder_emit_store(self.handle, ptr, value_ref) != 0) return error.EmitFailed;
                    }
                    try self.markReuseBackedStructLocal(si.dest, si.type_name);
                    try self.setLocal(si.dest, ptr_ref);
                } else {
                    _ = self.reuse_backed_struct_locals.remove(si.dest);
                    const result = zir_builder_emit_struct_init_anon(
                        self.handle,
                        names_ptrs.items.ptr,
                        names_lens.items.ptr,
                        values.items.ptr,
                        @intCast(values.items.len),
                    );
                    if (result == error_ref) return error.EmitFailed;
                    try self.setLocal(si.dest, result);
                }
            },
            .field_get => |fg| {
                const obj_ref = self.refForLocal(fg.object) catch return;
                const ref = zir_builder_emit_field_val(self.handle, obj_ref, fg.field.ptr, @intCast(fg.field.len));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(fg.dest, ref);
            },
            .field_set => |fs| {
                const obj_ref = self.refForLocal(fs.object) catch return;
                const val_ref = self.refForLocal(fs.value) catch return;
                const ptr = zir_builder_emit_field_ptr(self.handle, obj_ref, fs.field.ptr, @intCast(fs.field.len));
                if (ptr == error_ref) return error.EmitFailed;
                if (zir_builder_emit_store(self.handle, ptr, val_ref) != 0) return error.EmitFailed;
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
                const val_ref = self.refForValueLocal(ui.value) catch return;
                const names = [_][*]const u8{ui.variant_name.ptr};
                const lens = [_]u32{@intCast(ui.variant_name.len)};
                const vals = [_]u32{val_ref};
                if (self.findReusePairForDest(ui.dest)) |pair| {
                    const seed_ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    const token_local = pair.reuse.token orelse return error.EmitFailed;
                    const token_ref = try self.refForLocal(token_local);
                    const alloc_ref = try self.emitAllocatorRef();
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const reuse_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "reuseAllocByType", 16);
                    if (reuse_fn == error_ref) return error.EmitFailed;
                    const args = [_]u32{ type_ref, alloc_ref, token_ref };
                    const ptr_ref = zir_builder_emit_call_ref(self.handle, reuse_fn, &args, 3);
                    if (ptr_ref == error_ref) return error.EmitFailed;
                    const ptr = zir_builder_emit_field_ptr(self.handle, ptr_ref, ui.variant_name.ptr, @intCast(ui.variant_name.len));
                    if (ptr == error_ref) return error.EmitFailed;
                    if (zir_builder_emit_store(self.handle, ptr, val_ref) != 0) return error.EmitFailed;
                    try self.markReuseBackedUnionLocal(ui);
                    try self.setLocal(ui.dest, ptr_ref);
                } else {
                    _ = self.reuse_backed_union_locals.remove(ui.dest);
                    const ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(ui.dest, ref);
                }
            },

            // Pattern matching — compare atom IDs (u32)
            .match_atom => |ma| {
                // Scrutinee is already a u32 atom ID (from atomIntern).
                // Intern the expected atom and compare IDs.
                const scrutinee_ref = self.refForLocal(ma.scrutinee) catch return;

                // Intern the expected atom name
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const intern_fn = zir_builder_emit_field_val(self.handle, rt_import, "atomIntern", 10);
                if (intern_fn == error_ref) return error.EmitFailed;
                const name_ref = zir_builder_emit_str(self.handle, ma.atom_name.ptr, @intCast(ma.atom_name.len));
                if (name_ref == error_ref) return error.EmitFailed;
                const len_ref = zir_builder_emit_int(self.handle, @intCast(ma.atom_name.len));
                if (len_ref == error_ref) return error.EmitFailed;
                const intern_args = [_]u32{ name_ref, len_ref };
                const expected_ref = zir_builder_emit_call_ref(self.handle, intern_fn, &intern_args, 2);
                if (expected_ref == error_ref) return error.EmitFailed;

                // Compare u32 IDs via cmp_eq
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
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                const ref = zir_builder_emit_call(self.handle, name_slice.ptr, @intCast(name_slice.len), args.items.ptr, @intCast(args.items.len));
                if (ref != error_ref) try self.setLocal(cd.dest, ref);
            },
            .call_closure => |cc| {
                const lattice = @import("escape_lattice.zig");
                const callee_is_param = self.isParamDerivedClosure(cc.callee);
                if (self.getCallSiteSpecialization()) |spec| {
                    switch (spec.decision) {
                        .unreachable_call => {
                            return error.EmitFailed;
                        },
                        .direct_call, .contified => {
                            if (spec.decision == .contified and self.isTailReturnOf(cc.dest) and spec.lambda_set.isSingleton()) {
                                const target_id = spec.lambda_set.members[0];
                                if (self.program) |prog| {
                                    if (target_id < prog.functions.len) {
                                        const lowering = self.getClosureLowering(target_id, prog.functions[target_id].captures.len);
                                        if (lowering.direct_capture_params) {
                                            if (!callee_is_param) {
                                                if (self.findClosureCallTarget(cc.callee)) |target| {
                                                    try self.emitTailNamedCallToTarget(target.function_id, target.captures, cc.args);
                                                    self.skip_next_ret_local = cc.dest;
                                                    return;
                                                }
                                            }
                                        } else if (prog.functions[target_id].captures.len == 0) {
                                            try self.emitTailNamedCallToTarget(target_id, &.{}, cc.args);
                                            self.skip_next_ret_local = cc.dest;
                                            return;
                                        }
                                    }
                                }
                                if (try self.emitTailInvokeWrapperCall(cc.callee, target_id, cc.args)) {
                                    self.skip_next_ret_local = cc.dest;
                                    return;
                                }
                            }
                            if (spec.lambda_set.isSingleton()) {
                                if (self.program) |prog| {
                                    const target_id = spec.lambda_set.members[0];
                                    if (target_id < prog.functions.len) {
                                        const lowering = self.getClosureLowering(target_id, prog.functions[target_id].captures.len);
                                        if (lowering.direct_capture_params) {
                                            if (!callee_is_param) {
                                                if (self.findClosureCallTarget(cc.callee)) |target| {
                                                    const ref = try self.emitNamedCallToTarget(target.function_id, target.captures, cc.args);
                                                    if (ref != error_ref) {
                                                        try self.setLocal(cc.dest, ref);
                                                        return;
                                                    }
                                                }
                                            }
                                        } else if (prog.functions[target_id].captures.len == 0) {
                                            const ref = try self.emitNamedCallToTarget(target_id, &.{}, cc.args);
                                            if (ref != error_ref) {
                                                try self.setLocal(cc.dest, ref);
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        .switch_dispatch => {
                            if (try self.emitClosureSwitchDispatch(cc, spec.lambda_set.members)) {
                                return;
                            }
                        },
                        .dyn_closure_dispatch => {},
                    }
                }

                // Lambda set specialization: singleton non-capturing → direct call
                const direct_target: ?ClosureCallTarget = blk: {
                    if (!callee_is_param) {
                        if (self.findClosureCallTarget(cc.callee)) |target| {
                            const lowering = self.getClosureLowering(target.function_id, target.captures.len);
                            if (lowering.direct_capture_params) break :blk target;
                        }
                        if (self.analysis_context) |actx| {
                            const vkey = lattice.ValueKey{
                                .function = self.current_function_id,
                                .local = cc.callee,
                            };
                            if (actx.getLambdaSet(vkey)) |ls| {
                                if (ls.isSingleton()) {
                                    if (self.program) |prog| {
                                        if (ls.members.len > 0 and ls.members[0] < prog.functions.len) {
                                            const target_func = prog.functions[ls.members[0]];
                                            if (target_func.captures.len == 0) {
                                                break :blk .{ .function_id = ls.members[0], .captures = &.{} };
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    break :blk null;
                };

                if (direct_target) |target| {
                    const ref = try self.emitNamedCallToTarget(target.function_id, target.captures, cc.args);
                    if (ref != error_ref) try self.setLocal(cc.dest, ref);
                } else {
                    // Fallback: indirect call via closure ref
                    const callee_ref = self.refForLocal(cc.callee) catch return;
                    var args = std.ArrayListUnmanaged(u32).empty;
                    defer args.deinit(self.allocator);
                    for (cc.args) |arg| {
                        const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        try args.append(self.allocator, ref);
                    }
                    const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cc.dest, ref);
                }
            },
            .make_closure => |mc| {
                const func_name: []const u8 = if (self.program) |prog| blk: {
                    break :blk if (mc.function < prog.functions.len)
                        prog.functions[mc.function].name
                    else
                        "unknown_closure";
                } else "unknown_closure";

                const lowering = self.getClosureLowering(mc.function, mc.captures.len);

                if (!lowering.needs_closure_object) {
                    const fn_name_ref = zir_builder_emit_str(self.handle, func_name.ptr, @intCast(func_name.len));
                    if (fn_name_ref == error_ref) return error.EmitFailed;
                    try self.setLocal(mc.dest, fn_name_ref);
                    return;
                }

                // Tier 0: lambda-lifted closures with no captures need no env object.
                if (mc.captures.len == 0 and lowering.tier == .lambda_lifted) {
                    const fn_name_ref = zir_builder_emit_str(self.handle, func_name.ptr, @intCast(func_name.len));
                    if (fn_name_ref == error_ref) return error.EmitFailed;
                    const null_ref = @intFromEnum(Zir.Inst.Ref.null_value);
                    const closure_field_names = [_][*]const u8{ "call_fn", "env", "env_release" };
                    const closure_field_lens = [_]u32{ 7, 3, 11 };
                    const closure_field_vals = [_]u32{ fn_name_ref, null_ref, null_ref };
                    const closure_ref = zir_builder_emit_struct_init_anon(
                        self.handle,
                        &closure_field_names,
                        &closure_field_lens,
                        &closure_field_vals,
                        3,
                    );
                    if (closure_ref == error_ref) return error.EmitFailed;
                    try self.setLocal(mc.dest, closure_ref);
                    return;
                }

                // Build the environment tuple: .{ capture0, capture1, ... }
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
                const null_ref = @intFromEnum(Zir.Inst.Ref.null_value);

                const closure_field_names = [_][*]const u8{ "call_fn", "env", "env_release" };
                const closure_field_lens = [_]u32{ 7, 3, 11 };
                const closure_field_vals = [_]u32{ fn_name_ref, env_ref, null_ref };
                const closure_ref = zir_builder_emit_struct_init_anon(
                    self.handle,
                    &closure_field_names,
                    &closure_field_lens,
                    &closure_field_vals,
                    3,
                );
                if (closure_ref == error_ref) return error.EmitFailed;
                try self.setLocal(mc.dest, closure_ref);
            },
            .capture_get => |cg| {
                if (self.currentClosureLowering()) |lowering| {
                    if (lowering.direct_capture_params and cg.index < self.capture_param_refs.items.len) {
                        try self.setLocal(cg.dest, self.capture_param_refs.items[cg.index]);
                        return;
                    }
                    if (lowering.needs_env_param) {
                        const env_ref = self.current_closure_env_ref orelse {
                            const ref = zir_builder_emit_void(self.handle);
                            if (ref != error_ref) try self.setLocal(cg.dest, ref);
                            return;
                        };
                        const name = indexFieldName(cg.index);
                        const ref = zir_builder_emit_field_val(self.handle, env_ref, name.ptr, name.len);
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cg.dest, ref);
                        return;
                    }
                }

                const ref = zir_builder_emit_void(self.handle);
                if (ref != error_ref) try self.setLocal(cg.dest, ref);
            },

            .optional_unwrap => |ou| {
                const source_ref = self.refForLocal(ou.source) catch return;

                // Check if source is non-null
                const is_nonnull = zir_builder_emit_is_non_null(self.handle, source_ref);
                if (is_nonnull == error_ref) return error.EmitFailed;

                // Then branch: extract optional payload
                zir_builder_begin_capture(self.handle);
                const payload = zir_builder_emit_optional_payload(self.handle, source_ref);
                if (payload == error_ref) return error.EmitFailed;
                var then_len: u32 = 0;
                const then_ptr = zir_builder_end_capture(self.handle, &then_len);

                // Copy then instructions (capture buffer reused for else)
                var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
                defer then_insts.deinit(self.allocator);
                then_insts.appendSliceAssumeCapacity(then_ptr[0..then_len]);

                // Else branch: panic with message
                zir_builder_begin_capture(self.handle);
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
                var else_len: u32 = 0;
                const else_ptr = zir_builder_end_capture(self.handle, &else_len);

                // Emit if_else_bodies: if (is_nonnull) { payload } else { panic }
                const result = zir_builder_emit_if_else_bodies(
                    self.handle,
                    is_nonnull,
                    then_insts.items.ptr,
                    @intCast(then_insts.items.len),
                    payload,
                    else_ptr,
                    else_len,
                    panic_call,
                );
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
            .retain => |ret| {
                if (!self.shouldSkipArc(ret.value)) {
                    // Emit: @import("zap_runtime").ArcRuntime.retainAny(value)
                    const val_ref = self.refForLocal(ret.value) catch return;

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAny", 9);
                    if (retain_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{val_ref};
                    _ = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
                }
            },
            .release => |rel| {
                if (!self.shouldSkipArc(rel.value)) {
                    // Emit: @import("zap_runtime").ArcRuntime.releaseAny(allocator, value)
                    const val_ref = self.refForLocal(rel.value) catch return;

                    const alloc_ref = try self.emitAllocatorRef();

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const release_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "releaseAny", 10);
                    if (release_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ alloc_ref, val_ref };
                    _ = zir_builder_emit_call_ref(self.handle, release_fn, &args, 2);
                }
            },
            .reset => |r| {
                const val_ref = self.refForLocal(r.source) catch return;
                const alloc_ref = try self.emitAllocatorRef();

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                if (arc_runtime == error_ref) return error.EmitFailed;
                const reset_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "resetAny", 8);
                if (reset_fn == error_ref) return error.EmitFailed;

                const args = [_]u32{ alloc_ref, val_ref };
                const ref = zir_builder_emit_call_ref(self.handle, reset_fn, &args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(r.dest, ref);
            },
            .reuse_alloc => |ra| {
                const type_ref = try self.emitTypeRef(ra.dest_type);
                const alloc_ref = try self.emitAllocatorRef();
                const token_ref = if (ra.token) |token|
                    try self.refForLocal(token)
                else
                    zir_builder_emit_void(self.handle);
                if (token_ref == error_ref) return error.EmitFailed;

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                if (arc_runtime == error_ref) return error.EmitFailed;
                const reuse_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "reuseAllocByType", 16);
                if (reuse_fn == error_ref) return error.EmitFailed;

                const args = [_]u32{ type_ref, alloc_ref, token_ref };
                const ref = zir_builder_emit_call_ref(self.handle, reuse_fn, &args, 3);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ra.dest, ref);
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
        //
        // For inner iterations, the block_inline created by emit_if_else_bodies
        // must NOT be a function body instruction — it should only exist inside
        // the outer condbr's else branch. We pop it from body_inst_indices and
        // include it in current_else_insts for the next outer iteration.
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

            if (i > 0) {
                // Inner iteration: pop the block_inline from function body
                // and include it in the else branch for the next outer level.
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                // Outermost iteration — block_inline stays in function body.
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
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

        try self.emitPerceusResetForCase(cb);

        if (cb.arms.len == 0) {
            // The Zap frontend lowers atom/pattern case blocks to flat
            // pre_instrs containing match_atom + guard_block pairs, with
            // the default body as trailing instructions. We must restructure
            // this into nested if-else-bodies so branches don't fall through.
            try self.emitFlatCaseBlock(cb);
            return;
        }

        // Pre-instructions are setup (e.g., tuple arm guards) — emit normally
        for (cb.pre_instrs) |pi| try self.emitInstruction(pi);

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
            if (arm.result) |r| {
                try self.emitDropSpecializationsForCurrentInstr(r, @intCast(i));
            }
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

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
        }

        self.allocator.free(current_else_insts);

        // The last ref produced is the result of the entire case block
        try self.setLocal(cb.dest, current_else_result);
        try self.emitDropSpecializationsForCurrentInstr(cb.dest, null);
    }

    /// Handle a case_block where the frontend put all logic in pre_instrs
    /// as a flat sequence of guard_blocks (atom/pattern matching). We extract
    /// the guard_blocks as arms and restructure into nested if-else-bodies.
    fn emitFlatCaseBlock(self: *ZirDriver, cb: ir.CaseBlock) BuildError!void {
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
        try self.emitPerceusResetForCase(cb);

        // Split pre_instrs into: setup before each guard, guard_blocks, and
        // trailing default instructions after the last guard_block.
        // Find the index of the last guard_block to determine where default starts.
        var last_guard_idx: ?usize = null;
        for (cb.pre_instrs, 0..) |instr, idx| {
            if (instr == .guard_block) last_guard_idx = idx;
        }

        if (last_guard_idx == null) {
            // No guard_blocks — just emit everything as body instructions
            for (cb.pre_instrs) |pi| try self.emitInstruction(pi);
            for (cb.default_instrs) |di| try self.emitInstruction(di);
            if (cb.default_result) |dr| {
                if (self.local_refs.get(dr)) |ref| {
                    try self.setLocal(cb.dest, ref);
                }
            }
            try self.emitDropSpecializationsForCurrentInstr(cb.dest, null);
            return;
        }

        // Instructions after the last guard_block are the default body.
        const default_start = last_guard_idx.? + 1;
        const default_pre_instrs = cb.pre_instrs[default_start..];

        // Capture the default body (from both trailing pre_instrs and default_instrs).
        zir_builder_begin_capture(self.handle);
        for (default_pre_instrs) |di| try self.emitInstruction(di);
        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = zir_builder_end_capture(self.handle, &default_len);
        const default_result: u32 = if (cb.default_result) |dr|
            self.refForLocal(dr) catch void_ref
        else
            void_ref;

        var current_else_insts = try self.allocator.alloc(u32, default_len);
        @memcpy(current_else_insts, default_ptr[0..default_len]);
        var current_else_result: u32 = default_result;

        // Collect guard_blocks from pre_instrs (with their preceding setup).
        // We process them in REVERSE order for nested if-else construction.
        var guards = std.ArrayListUnmanaged(struct {
            setup_start: usize,
            guard_idx: usize,
        }).empty;
        defer guards.deinit(self.allocator);

        var prev_end: usize = 0;
        for (cb.pre_instrs, 0..) |instr, idx| {
            if (instr == .guard_block) {
                try guards.append(self.allocator, .{
                    .setup_start = prev_end,
                    .guard_idx = idx,
                });
                prev_end = idx + 1;
            }
        }

        // Process guards in REVERSE order
        var gi = guards.items.len;
        while (gi > 0) {
            gi -= 1;
            const guard = guards.items[gi];
            const gb = cb.pre_instrs[guard.guard_idx].guard_block;
            const setup_instrs = cb.pre_instrs[guard.setup_start..guard.guard_idx];

            // Emit setup instructions (match_atom comparisons etc.) as body instructions.
            // For inner guards, these are harmless (no side effects).
            for (setup_instrs) |si| try self.emitInstruction(si);

            // Get the guard condition ref
            const cond_ref = try self.refForLocal(gb.condition);

            // Capture the guard body
            zir_builder_begin_capture(self.handle);
            for (gb.body) |bi| try self.emitInstruction(bi);
            try self.emitDropSpecializationsForCurrentInstr(cb.dest, @intCast(gi));
            var body_len: u32 = 0;
            const body_ptr = zir_builder_end_capture(self.handle, &body_len);

            const body_result: u32 = void_ref;

            const body_insts = try self.allocator.alloc(u32, body_len);
            @memcpy(body_insts, body_ptr[0..body_len]);

            // Emit: if (guard_cond) { guard_body } else { current_else }
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                body_insts.ptr,
                @intCast(body_insts.len),
                body_result,
                current_else_insts.ptr,
                @intCast(current_else_insts.len),
                current_else_result,
            );

            self.allocator.free(body_insts);
            self.allocator.free(current_else_insts);

            if (ref == error_ref) return error.EmitFailed;

            if (gi > 0) {
                // Inner — pop block_inline from body for nesting
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                // Outermost — block_inline stays in function body
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
        }

        self.allocator.free(current_else_insts);

        // Set the case_block result
        try self.setLocal(cb.dest, current_else_result);
        try self.emitDropSpecializationsForCurrentInstr(cb.dest, null);
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

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
        }

        self.allocator.free(current_else_insts);
    }

    /// Emit a union_switch_return as a chain of if-else-bodies.
    /// Each case checks the active tag via std.meta.activeTag, extracts the
    /// variant payload, binds fields to locals, and returns the result.
    fn emitUnionSwitchReturn(self: *ZirDriver, usr: ir.UnionSwitchReturn) BuildError!void {
        const scrutinee_ref = try self.refForLocal(usr.scrutinee_param);
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

        if (usr.cases.len == 0) return;

        // Get the active tag: @import("std").meta.activeTag(scrutinee)
        const std_import = zir_builder_emit_import(self.handle, "std", 3);
        if (std_import == error_ref) return error.EmitFailed;
        const meta_mod = zir_builder_emit_field_val(self.handle, std_import, "meta", 4);
        if (meta_mod == error_ref) return error.EmitFailed;
        const active_tag_fn = zir_builder_emit_field_val(self.handle, meta_mod, "activeTag", 9);
        if (active_tag_fn == error_ref) return error.EmitFailed;
        const tag_args = [_]u32{scrutinee_ref};
        const tag_ref = zir_builder_emit_call_ref(self.handle, active_tag_fn, &tag_args, 1);
        if (tag_ref == error_ref) return error.EmitFailed;

        // Build from the last case backwards. The innermost else is unreachable.
        var current_else_insts = try self.allocator.alloc(u32, 0);
        var current_else_result: u32 = void_ref;

        var i = usr.cases.len;
        while (i > 0) {
            i -= 1;
            const case = usr.cases[i];

            // Emit: activeTag(scrutinee) == .variant_name
            const variant_ref = zir_builder_emit_enum_literal(self.handle, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (variant_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, tag_ref, variant_ref);
            if (cond_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Capture case body (payload extraction + field bindings + body + return)
            zir_builder_begin_capture(self.handle);

            // Extract variant payload: scrutinee.VariantName → struct payload
            const payload_ref = zir_builder_emit_field_val(self.handle, scrutinee_ref, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (payload_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Extract each field from the payload and bind to the correct local
            for (case.field_bindings) |fb| {
                const field_ref = zir_builder_emit_field_val(self.handle, payload_ref, fb.field_name.ptr, @intCast(fb.field_name.len));
                if (field_ref == error_ref) {
                    self.allocator.free(current_else_insts);
                    return error.EmitFailed;
                }
                try self.setLocal(fb.local_index, field_ref);
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

            // Emit: if (tag == .variant) { case_body_with_ret } else { current_else }
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

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                current_else_insts = try self.allocator.alloc(u32, 1);
                current_else_insts[0] = block_idx;
                current_else_result = ref;
            } else {
                current_else_insts = try self.allocator.alloc(u32, 0);
                current_else_result = ref;
            }
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
    lib_mode: bool,
    builder_entry: ?[]const u8,
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext,
) BuildError!void {
    // Register the runtime module if a path was provided.
    if (runtime_path) |rpath| {
        if (zir_compilation_add_module(compilation_ctx, "zap_runtime", rpath) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    var driver = try ZirDriver.init(allocator);
    driver.lib_mode = lib_mode;
    driver.builder_entry = builder_entry;
    driver.analysis_context = analysis_context;

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

test "ZirDriver.findReusePairForDest matches exact insertion point" {
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

    const driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = testing.allocator,
        .program = null,
        .current_function_id = 3,
        .current_block_label = 5,
        .current_instr_index = 7,
        .analysis_context = &analysis_context,
        .reuse_backed_struct_locals = .empty,
    };

    const pair = driver.findReusePairForDest(9) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(ir.LocalId, 10001), pair.reset.dest);
    try testing.expectEqual(@as(u32, 7), pair.reuse.insertion_point.instr_index);
}

test "ZirDriver.findReusePairForDest requires exact destination and site" {
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

    const wrong_instr_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = testing.allocator,
        .program = null,
        .current_function_id = 3,
        .current_block_label = 5,
        .current_instr_index = 6,
        .analysis_context = &analysis_context,
        .reuse_backed_struct_locals = .empty,
    };
    try testing.expect(wrong_instr_driver.findReusePairForDest(9) == null);

    const wrong_dest_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = testing.allocator,
        .program = null,
        .current_function_id = 3,
        .current_block_label = 5,
        .current_instr_index = 7,
        .analysis_context = &analysis_context,
        .reuse_backed_struct_locals = .empty,
    };
    try testing.expect(wrong_dest_driver.findReusePairForDest(10) == null);
}

test "closure lowering helper distinguishes immediate and stack tiers" {
    const lattice = @import("escape_lattice.zig");

    const immediate = ZirDriver.closure_lowering_for_tier(.immediate_invocation, 1);
    try std.testing.expectEqual(lattice.ClosureEnvTier.immediate_invocation, immediate.tier);
    try std.testing.expect(immediate.direct_capture_params);
    try std.testing.expect(!immediate.needs_env_param);
    try std.testing.expect(!immediate.needs_closure_object);

    const block_local = ZirDriver.closure_lowering_for_tier(.block_local, 1);
    try std.testing.expect(block_local.needs_env_param);
    try std.testing.expect(block_local.needs_closure_object);
    try std.testing.expect(block_local.stack_env);
    try std.testing.expectEqual(ZirDriver.ClosureLowering.StorageScope.stack_block, block_local.storage_scope);

    const function_local = ZirDriver.closure_lowering_for_tier(.function_local, 1);
    try std.testing.expect(function_local.needs_env_param);
    try std.testing.expect(function_local.needs_closure_object);
    try std.testing.expect(function_local.stack_env);
    try std.testing.expectEqual(ZirDriver.ClosureLowering.StorageScope.stack_function, function_local.storage_scope);

    const escaping = ZirDriver.closure_lowering_for_tier(.escaping, 1);
    try std.testing.expect(escaping.needs_env_param);
    try std.testing.expect(escaping.needs_closure_object);
    try std.testing.expect(!escaping.stack_env);
    try std.testing.expectEqual(ZirDriver.ClosureLowering.StorageScope.heap, escaping.storage_scope);
}

test "findClosureTargetInInstrs follows local aliases" {
    const captures = [_]ir.LocalId{7};
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 4, .function = 9, .captures = &captures } },
        .{ .local_set = .{ .dest = 5, .value = 4 } },
        .{ .share_value = .{ .dest = 6, .source = 5 } },
    };

    const target = ZirDriver.findClosureTargetInInstrs(&instrs, 6) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ir.FunctionId, 9), target.function_id);
    try std.testing.expectEqual(@as(usize, 1), target.captures.len);
    try std.testing.expectEqual(@as(ir.LocalId, 7), target.captures[0]);
}
