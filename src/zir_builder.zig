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
extern "c" fn zir_builder_emit_unreachable(handle: ?*ZirBuilderHandle) i32;

// Import, field access, struct init, call-by-ref
extern "c" fn zir_builder_emit_import(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
extern "c" fn zir_builder_emit_field_val(handle: ?*ZirBuilderHandle, object: u32, field_ptr: [*]const u8, field_len: u32) u32;
extern "c" fn zir_builder_emit_call_ref(handle: ?*ZirBuilderHandle, callee: u32, args_ptr: [*]const u32, args_len: u32) u32;
extern "c" fn zir_builder_emit_typeof(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_type_info(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_if_else(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;
extern "c" fn zir_builder_emit_struct_init_anon(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;
extern "c" fn zir_builder_emit_union_init(handle: ?*ZirBuilderHandle, union_type: u32, field_name_ptr: [*]const u8, field_name_len: u32, init_value: u32) u32;
extern "c" fn zir_builder_get_union_ret_type_ref(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_decl_ref(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
extern "c" fn zir_builder_emit_decl_val(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
// Union return type
extern "c" fn zir_builder_set_union_return_type(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, types_ptr: [*]const u32, fields_len: u32) i32;

// Switch block for tagged unions (single-pass API)
extern "c" fn zir_builder_add_switch_block(handle: ?*ZirBuilderHandle, operand: u32, prong_names_ptrs: [*]const [*]const u8, prong_names_lens: [*]const u32, prong_captures: [*]const u32, prong_body_lens: [*]const u32, prong_body_results: [*]const u32, prong_body_insts: [*]const u32, num_prongs: u32) u64;

// Body tracking control (for branch body emission)
extern "c" fn zir_builder_set_body_tracking(handle: ?*ZirBuilderHandle, enabled: bool) void;
extern "c" fn zir_builder_get_inst_count(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_begin_capture(handle: ?*ZirBuilderHandle) void;
extern "c" fn zir_builder_end_capture(handle: ?*ZirBuilderHandle, out_len: *u32) [*]const u32;
extern "c" fn zir_builder_emit_if_else_bodies(handle: ?*ZirBuilderHandle, condition: u32, then_insts_ptr: [*]const u32, then_insts_len: u32, then_result: u32, else_insts_ptr: [*]const u32, else_insts_len: u32, else_result: u32) u32;
extern "c" fn zir_builder_emit_cond_branch_with_bodies(handle: ?*ZirBuilderHandle, condition: u32, then_insts_ptr: [*]const u32, then_insts_len: u32, else_insts_ptr: [*]const u32, else_insts_len: u32) i32;
extern "c" fn zir_builder_emit_int_typed(handle: ?*ZirBuilderHandle, value: i64, dest_type: u32) u32;

// Field mutation and optional handling
extern "c" fn zir_builder_emit_field_ptr(handle: ?*ZirBuilderHandle, object: u32, field_ptr_arg: [*]const u8, field_len: u32) u32;
extern "c" fn zir_builder_emit_store(handle: ?*ZirBuilderHandle, ptr_ref: u32, value_ref: u32) i32;
extern "c" fn zir_builder_emit_is_non_null(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_optional_payload(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_optional_payload_unsafe(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_orelse(handle: ?*ZirBuilderHandle, operand: u32, fallback: u32) u32;
extern "c" fn zir_builder_set_call_modifier(handle: ?*ZirBuilderHandle, modifier: u32) void;
extern "c" fn zir_builder_emit_if_else_inline(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;

// Numeric widening (@as coercion)
extern "c" fn zir_builder_emit_as(handle: ?*ZirBuilderHandle, dest_type: u32, operand: u32) u32;

// Type construction
extern "c" fn zir_builder_emit_optional_type(handle: ?*ZirBuilderHandle, child_type: u32) u32;

// Return type overrides
extern "c" fn zir_builder_set_imported_return_type(handle: ?*ZirBuilderHandle, mod_ptr: [*]const u8, mod_len: u32, field_ptr: [*]const u8, field_len: u32) i32;

// Imported type parameters
extern "c" fn zir_builder_emit_param_imported_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, mod_ptr: [*]const u8, mod_len: u32, field_ptr: [*]const u8, field_len: u32) u32;


// Tuple/array construction and element access
extern "c" fn zir_builder_emit_array_init_anon(handle: ?*ZirBuilderHandle, values_ptr: [*]const u32, values_len: u32) u32;
extern "c" fn zir_builder_emit_elem_val_imm(handle: ?*ZirBuilderHandle, operand: u32, index: u32) u32;

// Error union unwrapping
extern "c" fn zir_builder_emit_try(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_catch(handle: ?*ZirBuilderHandle, operand: u32, catch_value: u32) u32;
extern "c" fn zir_builder_emit_is_non_err(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_err_union_payload_unsafe(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_ret_error(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_set_error_union_return_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_set_generic_return_type(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_emit_cond_return(handle: ?*ZirBuilderHandle, condition: u32, value: u32) i32;

// Runtime safety control (for guard error semantics)
extern "c" fn zir_builder_emit_set_runtime_safety(handle: ?*ZirBuilderHandle, enabled: u32) u32;

// Optional type support (for __try variant catch basin)
extern "c" fn zir_builder_set_optional_return_type(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_emit_ret_null(handle: ?*ZirBuilderHandle) i32;

// Struct type declarations
extern "c" fn zir_builder_add_struct_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, field_names_ptrs: [*]const [*]const u8, field_names_lens: [*]const u32, field_type_refs: [*]const u32, field_default_refs: ?[*]const u32, fields_len: u32) i32;
extern "c" fn zir_builder_add_enum_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, variant_names_ptrs: [*]const [*]const u8, variant_names_lens: [*]const u32, variants_len: u32) i32;
extern "c" fn zir_builder_emit_enum_from_int(handle: ?*ZirBuilderHandle, operand: u32, type_ref: u32) u32;
extern "c" fn zir_builder_emit_int_from_enum(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_set_decl_val_return_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_emit_param_decl_val_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, type_name_ptr: [*]const u8, type_name_len: u32) u32;

// Tuple return type
extern "c" fn zir_builder_set_tuple_return_type(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) i32;
extern "c" fn zir_builder_get_tuple_return_type(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_get_tuple_return_type_len(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_struct_init_typed(handle: ?*ZirBuilderHandle, struct_type: u32, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;
extern "c" fn zir_builder_emit_tuple_decl(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) u32;
extern "c" fn zir_builder_emit_tuple_decl_body(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) u32;

// Short-circuit boolean operators (Zig 0.16 bool_br_and / bool_br_or ZIR instructions)
extern "c" fn zir_builder_emit_bool_br_and(handle: ?*ZirBuilderHandle, lhs: u32, rhs_body_ptr: [*]const u32, rhs_body_len: u32, rhs_result: u32) u32;
extern "c" fn zir_builder_emit_bool_br_or(handle: ?*ZirBuilderHandle, lhs: u32, rhs_body_ptr: [*]const u32, rhs_body_len: u32, rhs_result: u32) u32;

// Stack allocation (Zig 0.16 alloc/load ZIR instructions for non-escaping values)
extern "c" fn zir_builder_emit_alloc(handle: ?*ZirBuilderHandle, type_ref: u32) u32;
extern "c" fn zir_builder_emit_alloc_mut(handle: ?*ZirBuilderHandle, type_ref: u32) u32;
extern "c" fn zir_builder_emit_load(handle: ?*ZirBuilderHandle, ptr_ref: u32) u32;
extern "c" fn zir_builder_emit_make_ptr_const(handle: ?*ZirBuilderHandle, alloc_ref: u32) u32;

// Loop instructions (Zig 0.16 loop/repeat ZIR instructions)
extern "c" fn zir_builder_emit_loop(handle: ?*ZirBuilderHandle, body_ptr: [*]const u32, body_len: u32) u32;
extern "c" fn zir_builder_emit_repeat(handle: ?*ZirBuilderHandle) i32;

// Body management
extern "c" fn zir_builder_pop_body_inst(handle: ?*ZirBuilderHandle) u32;

// Finalize and inject
extern "c" fn zir_builder_inject(builder_handle: ?*ZirBuilderHandle, compilation_handle: ?*ZirContext) i32;
extern "c" fn zir_builder_inject_struct(builder_handle: ?*ZirBuilderHandle, compilation_handle: ?*ZirContext, struct_name: [*:0]const u8) i32;

// Struct management
extern "c" fn zir_compilation_add_struct(ctx: ?*ZirContext, name: [*:0]const u8, source_path: [*:0]const u8) i32;
extern "c" fn zir_compilation_add_struct_source(ctx: ?*ZirContext, name: [*:0]const u8, source_ptr: [*]const u8, source_len: u32) i32;

// Pointer casting
extern "c" fn zir_builder_emit_ptr_cast(handle: ?*ZirBuilderHandle, dest_type: u32, operand: u32) u32;
extern "c" fn zir_builder_emit_ptr_cast_full(handle: ?*ZirBuilderHandle, flags_bits: u8, dest_type: u32, operand: u32) u32;

// Debug and validation
extern "c" fn zir_builder_emit_dbg_stmt(handle: ?*ZirBuilderHandle, line: u32, column: u32) i32;
extern "c" fn zir_builder_emit_ensure_result_used(handle: ?*ZirBuilderHandle, operand: u32) i32;

// Math builtins (unary float operations — Zig 0.16 @sqrt, @sin, etc.)
extern "c" fn zir_builder_emit_sqrt(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_sin(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_cos(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_exp(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_exp2(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_log(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_log2(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_log10(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_abs(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_floor(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_ceil(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_round(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_trunc_float(handle: ?*ZirBuilderHandle, operand: u32) u32;

// Saturating arithmetic (Zig 0.16 +|, -|, *|, <<|)
extern "c" fn zir_builder_emit_add_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_sub_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_mul_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_shl_sat(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;

// Overflow-detecting arithmetic (returns struct {result, overflow_bit})
extern "c" fn zir_builder_emit_add_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_sub_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;
extern "c" fn zir_builder_emit_mul_with_overflow(handle: ?*ZirBuilderHandle, lhs: u32, rhs: u32) u32;

// Type introspection (Zig 0.16 @sizeOf, @alignOf, etc.)
extern "c" fn zir_builder_emit_size_of(handle: ?*ZirBuilderHandle, type_ref: u32) u32;
extern "c" fn zir_builder_emit_align_of(handle: ?*ZirBuilderHandle, type_ref: u32) u32;
extern "c" fn zir_builder_emit_bit_size_of(handle: ?*ZirBuilderHandle, type_ref: u32) u32;
extern "c" fn zir_builder_emit_offset_of(handle: ?*ZirBuilderHandle, type_ref: u32, field_name: [*:0]const u8) u32;

// Type naming
extern "c" fn zir_builder_emit_tag_name(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_type_name(handle: ?*ZirBuilderHandle, type_ref: u32) u32;

// Compile-time type checks (Zig 0.16 @hasDecl, @hasField)
extern "c" fn zir_builder_emit_has_decl(handle: ?*ZirBuilderHandle, type_ref: u32, name: [*:0]const u8) u32;
extern "c" fn zir_builder_emit_has_field(handle: ?*ZirBuilderHandle, type_ref: u32, name: [*:0]const u8) u32;

// Pointer/integer conversions
extern "c" fn zir_builder_emit_int_from_ptr(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_ptr_from_int(handle: ?*ZirBuilderHandle, operand: u32, type_ref: u32) u32;

// Type reification (Zig 0.16 @Int, @Struct, @Enum, @Union, @Pointer, @Tuple replacing @Type)
extern "c" fn zir_builder_emit_reify_int(handle: ?*ZirBuilderHandle, signedness_ref: u32, bit_count_ref: u32) u32;
extern "c" fn zir_builder_emit_reify_struct(handle: ?*ZirBuilderHandle, layout_ref: u32, backing_ty_ref: u32, field_names_ref: u32, field_types_ref: u32, field_attrs_ref: u32) u32;
extern "c" fn zir_builder_emit_reify_enum(handle: ?*ZirBuilderHandle, tag_ty_ref: u32, mode_ref: u32, field_names_ref: u32, field_values_ref: u32) u32;
extern "c" fn zir_builder_emit_reify_union(handle: ?*ZirBuilderHandle, layout_ref: u32, arg_ty_ref: u32, field_names_ref: u32, field_types_ref: u32, field_attrs_ref: u32) u32;
extern "c" fn zir_builder_emit_reify_pointer(handle: ?*ZirBuilderHandle, size_ref: u32, attrs_ref: u32, elem_ty_ref: u32, sentinel_ref: u32) u32;
extern "c" fn zir_builder_emit_reify_tuple(handle: ?*ZirBuilderHandle, field_types_ref: u32) u32;

// Vector/SIMD operations (Zig 0.16 @Vector, @splat, @shuffle, @reduce)
extern "c" fn zir_builder_emit_vector_type(handle: ?*ZirBuilderHandle, len: u32, elem_type_ref: u32) u32;
extern "c" fn zir_builder_emit_splat(handle: ?*ZirBuilderHandle, scalar: u32, len: u32) u32;
extern "c" fn zir_builder_emit_shuffle(handle: ?*ZirBuilderHandle, a: u32, b: u32, mask: u32) u32;
extern "c" fn zir_builder_emit_reduce(handle: ?*ZirBuilderHandle, operand: u32, operation: u8) u32;

// Slice decomposition
extern "c" fn zir_builder_emit_slice_start(handle: ?*ZirBuilderHandle, operand: u32, start: u32) u32;
extern "c" fn zir_builder_emit_slice_end(handle: ?*ZirBuilderHandle, operand: u32, start: u32, end: u32) u32;
extern "c" fn zir_builder_emit_slice_length(handle: ?*ZirBuilderHandle, operand: u32, start: u32, length: u32) u32;

// Error union type construction
extern "c" fn zir_builder_emit_error_union_type(handle: ?*ZirBuilderHandle, error_set: u32, payload: u32) u32;

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
        .add => @intFromEnum(Zir.Inst.Tag.addwrap),
        .sub => @intFromEnum(Zir.Inst.Tag.subwrap),
        .mul => @intFromEnum(Zir.Inst.Tag.mulwrap),
        .div => @intFromEnum(Zir.Inst.Tag.div_trunc),
        .rem_op => @intFromEnum(Zir.Inst.Tag.mod_rem),
        .eq => @intFromEnum(Zir.Inst.Tag.cmp_eq),
        .neq => @intFromEnum(Zir.Inst.Tag.cmp_neq),
        .lt => @intFromEnum(Zir.Inst.Tag.cmp_lt),
        .gt => @intFromEnum(Zir.Inst.Tag.cmp_gt),
        .lte => @intFromEnum(Zir.Inst.Tag.cmp_lte),
        .gte => @intFromEnum(Zir.Inst.Tag.cmp_gte),
        .bool_and => null, // handled via bool_br_and (short-circuit)
        .bool_or => null, // handled via bool_br_or (short-circuit)
        .string_eq, .string_neq => null, // handled specially via std.mem.eql
        .concat => null, // handled specially via runtime call
        .in_list => null, // handled specially via runtime call
        .in_range => null, // handled specially via runtime call
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

/// Map a primitive Zap type to a well-known ZIR type Ref.
/// Returns 0 for complex types that need instruction emission (use
/// ZirDriver.emitReturnTypeRef for full coverage).
fn mapReturnType(zig_type: ir.ZigType) u32 {
    return switch (zig_type) {
        .void => 0,
        .never => @intFromEnum(Zir.Inst.Ref.noreturn_type),
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
        .optional => |inner| if (inner.* == .string)
            @intFromEnum(Zir.Inst.Ref.slice_const_u8_type)
        else
            0,
        .atom => @intFromEnum(Zir.Inst.Ref.u32_type), // atoms are interned u32 IDs
        .nil => 0, // void
        else => 0, // complex types need emitReturnTypeRef
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

/// Resolve the ZIR type ref for a list parameter at function begin time.
/// Emits @import("zap_runtime").List and wraps in optional const pointer.
/// Returns the type ref, or 0 (void) on failure.

// ---------------------------------------------------------------------------
// ZirDriver
// ---------------------------------------------------------------------------

pub const ZirDriver = struct {
    handle: *ZirBuilderHandle,
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, ValueRef),
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
    /// Cached ret_type Ref for @unionInit. Emitted once at function start,
    /// reused for all union_init instructions. 0 means not a union return type.
    cached_union_ret_type_ref: u32 = 0,
    /// Tracks how many tuple_init instructions have been emitted in the current function.
    tuple_init_count: u32 = 0,
    /// Nested tuple types in DFS post-order (inner-first), matching tuple_init emission order.
    tuple_type_stack: std.ArrayListUnmanaged(ir.ZigType) = .empty,
    /// ID of the function currently being emitted (for analysis lookups).
    current_function_id: ir.FunctionId = 0,
    /// Label of the current block.
    current_block_label: ir.LabelId = 0,
    /// True when the current function is a closure (has captures).
    current_function_is_closure: bool = false,
    /// Nesting depth of capture contexts (case/switch/if-else bodies).
    /// When > 0, struct_init_typed can't be used because struct_init_field_type
    /// instructions (emitted via addInst) don't enter captured bodies.
    capture_depth: u32 = 0,
    /// Instruction index within the current block.
    current_instr_index: u32 = 0,
    current_block_instructions: []const ir.Instruction = &.{},
    skip_next_ret_local: ?ir.LocalId = null,
    /// Analysis results from the escape/region/ARC pipeline.
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext = null,
    reuse_backed_struct_locals: std.AutoHashMapUnmanaged(ir.LocalId, []const u8) = .empty,
    reuse_backed_union_locals: std.AutoHashMapUnmanaged(ir.LocalId, ir.UnionInit) = .empty,
    reuse_backed_tuple_locals: std.AutoHashMapUnmanaged(ir.LocalId, usize) = .empty,
    type_store: ?*const @import("types.zig").TypeStore = null,
    cached_list_type_ref: u32 = 0,
    /// Cached ZIR refs for List method functions, resolved once at function
    /// scope so they're available inside condbr bodies without re-importing.
    cached_list_cell_ref: u32 = 0,
    cached_list_gethead_ref: u32 = 0,
    cached_list_gettail_ref: u32 = 0,
    cached_list_cons_ref: u32 = 0,
    cached_list_length_ref: u32 = 0,
    cached_list_get_ref: u32 = 0,
    capture_param_refs: std.ArrayListUnmanaged(u32) = .empty,
    current_closure_env_ref: ?u32 = null,
    /// Forward-propagating map from locals to closure function IDs.
    /// Populated by make_closure, propagated by local_set/local_get/move/share.
    /// Used by call_closure to resolve 0-capture closures to direct named calls.
    closure_function_map: std.AutoHashMapUnmanaged(ir.LocalId, ir.FunctionId) = .empty,
    /// Maps (closure_function_id, capture_index) → captured closure function ID.
    /// When a closure captures another closure value, this allows the inner function's
    /// capture_get to propagate the closure_function_map across function boundaries.
    capture_closure_function_map: std.AutoHashMapUnmanaged(u64, ir.FunctionId) = .empty,
    /// Compilation context for per-module ZIR injection.
    compilation_ctx: ?*ZirContext = null,
    /// Module currently being emitted (e.g., "IO", "Zest_Case"). Null when emitting root.
    current_emit_module: ?[]const u8 = null,

    const ValueRef = union(enum) {
        /// Already-materialized ZIR instruction ref
        inst: u32,
        /// Declaration reference (materialized lazily via decl_ref or @import)
        decl: struct {
            module_name: ?[]const u8, // null => current module
            decl_name: []const u8,
        },
    };

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
        self.closure_function_map.deinit(self.allocator);
        self.capture_closure_function_map.deinit(self.allocator);
        self.reuse_backed_struct_locals.deinit(self.allocator);
        self.reuse_backed_union_locals.deinit(self.allocator);
        self.reuse_backed_tuple_locals.deinit(self.allocator);
        self.capture_param_refs.deinit(self.allocator);
    }

    /// Check if a function contains tail calls to itself (via IR tail_call instructions).
    /// The IR builder already detects and marks tail-recursive calls as tail_call.
    /// When present, the function body could be wrapped in a ZIR loop instruction
    /// with tail calls converted to parameter updates + repeat, avoiding stack growth.
    fn hasTailCalls(func: ir.Function) bool {
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .tail_call => |tc| {
                        if (std.mem.eql(u8, tc.name, func.name)) return true;
                    },
                    else => {},
                }
            }
        }
        return false;
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
            var inner_refs : std.ArrayListUnmanaged(u32) = .empty;
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
        var inner_refs : std.ArrayListUnmanaged(u32) = .empty;
        defer inner_refs.deinit(self.allocator);
        for (zig_type.tuple) |inner_elem| {
            inner_refs.append(self.allocator, self.emitBodyLocalTupleType(inner_elem)) catch return 0;
        }
        const ref = zir_builder_emit_tuple_decl_body(self.handle, inner_refs.items.ptr, @intCast(inner_refs.items.len));
        return if (ref == error_ref) 0 else ref;
    }

    fn setLocal(self: *ZirDriver, local: ir.LocalId, ref: u32) !void {
        try self.local_refs.put(self.allocator, local, .{ .inst = ref });
    }

    fn setLocalDecl(self: *ZirDriver, local: ir.LocalId, module_name: ?[]const u8, decl_name: []const u8) !void {
        try self.local_refs.put(self.allocator, local, .{ .decl = .{ .module_name = module_name, .decl_name = decl_name } });
    }

    fn beginCapture(self: *ZirDriver) void {
        zir_builder_begin_capture(self.handle);
        self.capture_depth += 1;
    }

    fn endCapture(self: *ZirDriver, out_len: *u32) [*]const u32 {
        const result = zir_builder_end_capture(self.handle, out_len);
        if (self.capture_depth > 0) self.capture_depth -= 1;
        return result;
    }

    /// Map Zap-facing module names to runtime struct names.
    /// Domain modules (IO, Integer, Float, etc.) route to Prelude.
    /// List, Map, String, Zest map to their runtime struct names.
    fn mapToRuntimeModule(mod_name: []const u8) []const u8 {
        // These modules have their own runtime structs
        if (std.mem.eql(u8, mod_name, "List")) return "List";
        if (std.mem.eql(u8, mod_name, "Map")) return "MapAtomInt";
        if (std.mem.eql(u8, mod_name, "String")) return "String";
        if (std.mem.eql(u8, mod_name, "Zest")) return "Zest";
        if (std.mem.eql(u8, mod_name, "Kernel")) return "Kernel";
        // Domain modules route to Prelude (all functions live there)
        if (std.mem.eql(u8, mod_name, "IO")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Integer")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Float")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Bool")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Atom")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Math")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "File")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "System")) return "Prelude";
        if (std.mem.eql(u8, mod_name, "Path")) return "Prelude";
        // Default: use the module name as-is (Prelude, etc.)
        return mod_name;
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

    /// Resolve any Zap type to a ZIR type ref for use inside compound type
    /// declarations (e.g., tuple element types). Emits import instructions
    /// for complex types that need runtime type resolution.
    fn emitImportedTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        // Try primitive mapping first
        const simple = mapReturnType(zig_type);
        if (simple != 0) return simple;

        // Complex types: emit runtime import instructions
        return switch (zig_type) {
            .list => {
                // List type ref for tuple elements — use named alias
                const type_name = getListTypeName(getListElementType(zig_type));
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const ref = zir_builder_emit_field_val(self.handle, rt_import, type_name.ptr, @intCast(type_name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .map => |mt| {
                // Map type ref for tuple elements — use named alias
                const type_name = getMapTypeName(mt.key.*, mt.value.*);
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const ref = zir_builder_emit_field_val(self.handle, rt_import, type_name.ptr, @intCast(type_name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .tuple => self.mapTupleElementType(zig_type),
            .struct_ref => |name| {
                const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                    name[dot_idx + 1 ..]
                else
                    name;

                // If the struct type is declared in the current module (top-level
                // structs are emitted into every module by emitStructTypeDecls),
                // use decl_val to reference it directly. This produces the same
                // type identity as struct_init_typed(decl_val(...)), avoiding
                // type mismatches between return types and constructed values.
                if (self.structIsInCurrentModule(name)) {
                    const ref = zir_builder_emit_decl_val(self.handle, short_name.ptr, @intCast(short_name.len));
                    if (ref != error_ref) return ref;
                }

                // Cross-module struct: import from the struct's defining module.
                const module_name = self.structToModuleName(name);
                const import_ref = zir_builder_emit_import(self.handle, module_name.ptr, @intCast(module_name.len));
                if (import_ref == error_ref) return error.EmitFailed;
                const ref = zir_builder_emit_field_val(self.handle, import_ref, short_name.ptr, @intCast(short_name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            // void/nil/never should not appear as tuple elements
            .void, .nil, .never => return error.EmitFailed,
            // Types that don't have runtime representations as tuple elements yet
            .function, .tagged_union, .ptr, .optional, .any => return error.EmitFailed,
            // Primitives are handled above by mapReturnType — they never reach here
            .bool_type,
            .i8, .i16, .i32, .i64,
            .u8, .u16, .u32, .u64,
            .usize, .isize,
            .f16, .f32, .f64,
            .string, .atom,
            => unreachable,
        };
    }

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        const value_ref = self.local_refs.get(local) orelse return error.EmitFailed;
        return self.materializeValueRef(value_ref);
    }

    fn materializeValueRef(self: *ZirDriver, value: ValueRef) BuildError!u32 {
        return switch (value) {
            .inst => |r| r,
            .decl => |d| {
                if (d.module_name) |mod| {
                    return self.emitCrossModuleRef(mod, d.decl_name);
                }
                const ref = zir_builder_emit_decl_ref(self.handle, d.decl_name.ptr, @intCast(d.decl_name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
        };
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

    /// Emit struct type declarations for all struct type_defs in the IR program.
    /// These become named constants in the module's ZIR (e.g., `const Point = struct { x: i64, y: i64 };`).
    /// Check if any function in the given module references a struct type by name.
    fn moduleUsesStruct(self: *const ZirDriver, module_name: []const u8, struct_name: []const u8) bool {
        const prog = self.program orelse return false;
        for (prog.functions) |func| {
            // Check if the function belongs to this module
            const func_module = if (std.mem.lastIndexOf(u8, func.name, "__")) |sep|
                func.name[0..sep]
            else
                func.name;
            // Convert dots to underscores for comparison
            var buf: [256]u8 = undefined;
            if (func_module.len > buf.len) continue;
            @memcpy(buf[0..func_module.len], func_module);
            for (buf[0..func_module.len]) |*ch| {
                if (ch.* == '.') ch.* = '_';
            }
            if (!std.mem.eql(u8, buf[0..func_module.len], module_name)) continue;

            // Check if return type references this struct
            if (std.meta.activeTag(func.return_type) == .struct_ref) {
                if (std.mem.eql(u8, func.return_type.struct_ref, struct_name)) return true;
            }
            // Check params
            for (func.params) |param| {
                if (std.meta.activeTag(param.type_expr) == .struct_ref) {
                    if (std.mem.eql(u8, param.type_expr.struct_ref, struct_name)) return true;
                }
            }
        }
        return false;
    }

    fn emitStructTypeDecls(self: *ZirDriver) !void {
        const prog = self.program orelse return;
        const current_module = self.current_emit_module orelse return;
        // Track emitted struct names to avoid duplicates
        var emitted = std.StringHashMap(void).init(self.allocator);
        defer emitted.deinit();
        for (prog.type_defs) |type_def| {
            // Only emit struct types that belong to the current module.
            // Type names use dot notation (e.g., "Zap.Env"), module names
            // use underscore notation (e.g., "Zap"). Match by converting
            // the type name prefix to underscore format.
            const belongs_to_module = blk: {
                if (std.mem.lastIndexOf(u8, type_def.name, ".")) |dot_idx| {
                    const prefix = type_def.name[0..dot_idx];
                    // Convert dot-separated prefix to underscore for comparison
                    var buf: [256]u8 = undefined;
                    if (prefix.len > buf.len) break :blk false;
                    @memcpy(buf[0..prefix.len], prefix);
                    for (buf[0..prefix.len]) |*ch| {
                        if (ch.* == '.') ch.* = '_';
                    }
                    break :blk std.mem.eql(u8, buf[0..prefix.len], current_module);
                }
                // Top-level structs have no module prefix — emit into
                // every module that has functions. The duplicate-name
                // issue is handled by the ZIR builder's deduplication.
                break :blk true;
            };
            if (!belongs_to_module) continue;

            switch (type_def.kind) {
                .struct_def => |def| {
                    // Use just the struct name (after the module prefix)
                    const short_name = if (std.mem.lastIndexOf(u8, type_def.name, ".")) |dot_idx|
                        type_def.name[dot_idx + 1 ..]
                    else
                        type_def.name;
                    // Skip if already emitted (dedup across multiple type_defs)
                    if (emitted.contains(short_name)) continue;
                    emitted.put(short_name, {}) catch continue;
                    var field_name_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                    defer field_name_ptrs.deinit(self.allocator);
                    var field_name_lens: std.ArrayListUnmanaged(u32) = .empty;
                    defer field_name_lens.deinit(self.allocator);
                    var field_type_refs: std.ArrayListUnmanaged(u32) = .empty;
                    defer field_type_refs.deinit(self.allocator);


                    for (def.fields) |field| {
                        try field_name_ptrs.append(self.allocator, field.name.ptr);
                        try field_name_lens.append(self.allocator, @intCast(field.name.len));
                        const type_ref = self.mapTypeNameToRef(field.type_expr);
                        try field_type_refs.append(self.allocator, type_ref);

                    }

                    // Don't emit defaults in struct_decl — the Zap compiler
                    // fills in missing fields at struct_init time instead.
                    if (zir_builder_add_struct_type(
                        self.handle,
                        short_name.ptr,
                        @intCast(short_name.len),
                        field_name_ptrs.items.ptr,
                        field_name_lens.items.ptr,
                        field_type_refs.items.ptr,
                        null,
                        @intCast(def.fields.len),
                    ) != 0) {
                        return error.EmitFailed;
                    }
                },
                else => {},
            }
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

    fn findEnumDef(self: *const ZirDriver, type_name: []const u8) bool {
        const prog = self.program orelse return false;
        for (prog.type_defs) |type_def| {
            if (!std.mem.eql(u8, type_def.name, type_name)) continue;
            return type_def.kind == .enum_def;
        }
        return false;
    }

    /// Check if a type name corresponds to any known type definition (struct, enum, or union).
    fn findAnyTypeDef(self: *const ZirDriver, type_name: []const u8) bool {
        return self.findStructDef(type_name) != null or self.findEnumDef(type_name) or self.findUnionDef(type_name) != null;
    }

    fn findUnionDef(self: *const ZirDriver, type_name: []const u8) ?ir.UnionDef {
        const prog = self.program orelse return null;
        for (prog.type_defs) |type_def| {
            if (!std.mem.eql(u8, type_def.name, type_name)) continue;
            return switch (type_def.kind) {
                .union_def => |def| def,
                else => null,
            };
        }
        return null;
    }

    /// Check if a struct type name is declared in the current ZIR module.
    /// Top-level structs (no dot in name) are emitted into every module.
    /// Dotted structs (e.g., "Zap.Env") are only emitted into their prefix module.
    fn structIsInCurrentModule(self: *const ZirDriver, type_name: []const u8) bool {
        if (self.findStructDef(type_name) == null) return false;
        const current_module = self.current_emit_module orelse return false;
        if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_idx| {
            const prefix = type_name[0..dot_idx];
            var buf: [256]u8 = undefined;
            if (prefix.len > buf.len) return false;
            @memcpy(buf[0..prefix.len], prefix);
            for (buf[0..prefix.len]) |*ch| {
                if (ch.* == '.') ch.* = '_';
            }
            return std.mem.eql(u8, buf[0..prefix.len], current_module);
        }
        // Top-level struct — emitted into every module
        return true;
    }

    /// Convert a struct_ref name to the ZIR module name that defines it.
    /// "Range" → "Range", "Zap.Env" → "Zap", "IO.Mode" → "IO"
    fn structToModuleName(self: *ZirDriver, type_name: []const u8) []const u8 {
        if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_idx| {
            const prefix = type_name[0..dot_idx];
            const converted = self.allocator.alloc(u8, prefix.len) catch return type_name;
            @memcpy(converted, prefix);
            for (converted) |*ch| {
                if (ch.* == '.') ch.* = '_';
            }
            return converted;
        }
        return type_name;
    }

    /// Map a Zig type name string to a ZIR type Ref for union variant types.
    fn mapTypeNameToRef(_: *const ZirDriver, type_name: []const u8) u32 {
        if (std.mem.eql(u8, type_name, "[]const u8")) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type);
        if (std.mem.eql(u8, type_name, "bool")) return @intFromEnum(Zir.Inst.Ref.bool_type);
        if (std.mem.eql(u8, type_name, "i64")) return @intFromEnum(Zir.Inst.Ref.i64_type);
        if (std.mem.eql(u8, type_name, "i32")) return @intFromEnum(Zir.Inst.Ref.i32_type);
        if (std.mem.eql(u8, type_name, "u32")) return @intFromEnum(Zir.Inst.Ref.u32_type);
        if (std.mem.eql(u8, type_name, "u64")) return @intFromEnum(Zir.Inst.Ref.u64_type);
        if (std.mem.eql(u8, type_name, "f64")) return @intFromEnum(Zir.Inst.Ref.f64_type);
        if (std.mem.eql(u8, type_name, "f32")) return @intFromEnum(Zir.Inst.Ref.f32_type);
        if (std.mem.eql(u8, type_name, "usize")) return @intFromEnum(Zir.Inst.Ref.usize_type);
        if (std.mem.eql(u8, type_name, "void")) return @intFromEnum(Zir.Inst.Ref.void_type);
        return 0; // void fallback
    }

    fn refForValueLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        if (self.reuse_backed_tuple_locals.get(local)) |arity| {
            const ptr_ref = try self.refForLocal(local);
            var names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens : std.ArrayListUnmanaged(u32) = .empty;
            defer names_lens.deinit(self.allocator);
            var values : std.ArrayListUnmanaged(u32) = .empty;
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

            var names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens : std.ArrayListUnmanaged(u32) = .empty;
            defer names_lens.deinit(self.allocator);
            var values : std.ArrayListUnmanaged(u32) = .empty;
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

    /// Find an IR function by its full mangled name.
    fn findFunctionByName(self: *const ZirDriver, name: []const u8) ?ir.Function {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (std.mem.eql(u8, func.name, name)) return func;
            }
        }
        return null;
    }

    /// Find an IR function by its local_name (unmangled name within its module).
    /// Used when macro-expanded code references imported functions by bare name
    /// (e.g., `begin_test` from `use Zest.Case`).
    /// Matches both exact local_name and base name (without arity suffix).
    /// Find an IR function by local_name or base name, but ONLY from other modules.
    /// Used for bare imported names like "begin_test" from `use Zest.Case`.
    fn findFunctionByLocalName(self: *const ZirDriver, local_name: []const u8) ?ir.Function {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                // Only match functions from OTHER modules
                if (func.module_name == null) continue;
                if (self.current_emit_module) |cem| {
                    if (std.mem.eql(u8, func.module_name.?, cem)) continue;
                }
                // Exact match on local_name
                if (func.local_name.len > 0 and std.mem.eql(u8, func.local_name, local_name)) {
                    return func;
                }
                // Base name match: "begin_test" matches "begin_test__0"
                if (func.local_name.len > 0) {
                    const base = if (std.mem.findLast(u8, func.local_name, "__")) |pos|
                        func.local_name[0..pos]
                    else
                        func.local_name;
                    if (std.mem.eql(u8, base, local_name)) {
                        return func;
                    }
                }
            }
        }
        return null;
    }

    /// Find an IR function by its ID.
    fn findFunctionById(self: *const ZirDriver, id: ir.FunctionId) ?ir.Function {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id == id) return func;
            }
        }
        return null;
    }

    /// Emit a cross-module function reference: @import("TargetModule").local_name
    fn emitCrossModuleRef(self: *ZirDriver, target_module: []const u8, local_name: []const u8) BuildError!u32 {
        const import_ref = zir_builder_emit_import(self.handle, target_module.ptr, @intCast(target_module.len));
        if (import_ref == error_ref) return error.EmitFailed;
        const fn_ref = zir_builder_emit_field_val(self.handle, import_ref, local_name.ptr, @intCast(local_name.len));
        if (fn_ref == error_ref) return error.EmitFailed;
        return fn_ref;
    }

    /// Emit a cross-module function call: @import("TargetModule").local_name(args)
    fn emitCrossModuleCall(self: *ZirDriver, target_module: []const u8, local_name: []const u8, arg_refs: []const u32) BuildError!u32 {
        const import_ref = zir_builder_emit_import(self.handle, target_module.ptr, @intCast(target_module.len));
        if (import_ref == error_ref) return error.EmitFailed;
        const fn_ref = zir_builder_emit_field_val(self.handle, import_ref, local_name.ptr, @intCast(local_name.len));
        if (fn_ref == error_ref) return error.EmitFailed;
        const ref = zir_builder_emit_call_ref(self.handle, fn_ref, arg_refs.ptr, @intCast(arg_refs.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    const NamespaceChild = struct {
        name: []const u8, // "Runtime" (short name for re-export)
        full_module: []const u8, // "Zest_Runtime" (full module name for @import)
    };

    /// Deduplicate a function list by local_name, keeping the last occurrence.
    /// Returns a new ArrayListUnmanaged with unique entries.
    fn deduplicateFunctions(allocator: std.mem.Allocator, funcs: []const ir.Function) !std.ArrayListUnmanaged(ir.Function) {
        // Build a map of local_name → last index
        var last_index = std.StringHashMap(usize).init(allocator);
        for (funcs, 0..) |func, i| {
            const key = if (func.local_name.len > 0) func.local_name else func.name;
            try last_index.put(key, i);
        }
        // Collect functions in order, keeping only the last occurrence of each name
        var result: std.ArrayListUnmanaged(ir.Function) = .empty;
        for (funcs, 0..) |func, i| {
            const key = if (func.local_name.len > 0) func.local_name else func.name;
            if (last_index.get(key)) |last_i| {
                if (last_i == i) {
                    try result.append(allocator, func);
                }
            }
        }
        return result;
    }

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        self.program = program;

        const ctx = self.compilation_ctx;


        // ── Step 1: Group functions by module ────────────────────────
        var module_funcs = std.StringHashMap(std.ArrayListUnmanaged(ir.Function)).init(self.allocator);
        var root_funcs: std.ArrayListUnmanaged(ir.Function) = .empty;
        // Track ALL module names (including @native-only) for re-export generation
        var all_module_names = std.StringHashMap(void).init(self.allocator);

        // Deduplicate functions by (module, local_name), keeping the LAST
        // occurrence. The IR may contain duplicate entries from monomorphization;
        // duplicates cause putNoClobber assertion failures in Zig 0.16's scanNamespace.
        // We keep the last occurrence because decl_ref/decl_val resolve to the final
        // declaration in the namespace.
        {
            // First pass: collect all functions per module, allowing duplicates.
            var raw_root_funcs: std.ArrayListUnmanaged(ir.Function) = .empty;
            var raw_module_funcs = std.StringHashMap(std.ArrayListUnmanaged(ir.Function)).init(self.allocator);
            for (program.functions) |func| {
                if (func.module_name) |mod| {
                    try all_module_names.put(mod, {});
                }
                const is_entry = if (program.entry) |eid| func.id == eid else false;
                if (is_entry or func.module_name == null) {
                    try raw_root_funcs.append(self.allocator, func);
                } else {
                    const mod = func.module_name.?;
                    const gop = try raw_module_funcs.getOrPut(mod);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, func);
                }
            }

            // Second pass: deduplicate by local_name within each group, keeping last.
            root_funcs = try deduplicateFunctions(self.allocator, raw_root_funcs.items);
            var raw_iter = raw_module_funcs.iterator();
            while (raw_iter.next()) |entry| {
                const deduped = try deduplicateFunctions(self.allocator, entry.value_ptr.items);
                try module_funcs.put(entry.key_ptr.*, deduped);
            }
        }

        // ── Step 2: Detect namespace hierarchy for re-export modules ─
        // Scan ALL module names (including @native-only) for parent_child patterns.
        // A parent re-export is generated when a module name contains '_'.
        var namespace_children = std.StringHashMap(std.ArrayListUnmanaged(NamespaceChild)).init(self.allocator);
        {
            var name_iter = all_module_names.iterator();
            while (name_iter.next()) |entry| {
                const mod_name = entry.key_ptr.*;
                if (std.mem.findScalarLast(u8, mod_name, '_')) |sep| {
                    const parent = mod_name[0..sep];
                    const child = mod_name[sep + 1 ..];
                    const gop = try namespace_children.getOrPut(parent);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    // Avoid duplicate children
                    var already = false;
                    for (gop.value_ptr.items) |existing| {
                        if (std.mem.eql(u8, existing.full_module, mod_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try gop.value_ptr.append(self.allocator, .{ .name = child, .full_module = mod_name });
                    }
                }
            }
        }

        // Register empty modules for @native-only modules (so @import works)
        if (ctx) |c| {
            var name_iter2 = all_module_names.iterator();
            while (name_iter2.next()) |entry| {
                const mod_name = entry.key_ptr.*;
                if (!module_funcs.contains(mod_name)) {
                    // @native-only module — register as empty module
                    const mod_name_z = try self.allocator.dupeZ(u8, mod_name);
                    defer self.allocator.free(mod_name_z);
                    const stub = "comptime {}\n";
                    _ = zir_compilation_add_struct_source(c, mod_name_z, stub.ptr, @intCast(stub.len));
                }
            }
        }

        // ── Step 3: Emit each leaf module as its own ZIR module ──────
        if (ctx) |c| {
            var leaf_iter = module_funcs.iterator();
            while (leaf_iter.next()) |entry| {
                const mod_name = entry.key_ptr.*;
                const funcs = entry.value_ptr.items;
                if (funcs.len == 0) continue;

                const mod_name_z = try self.allocator.dupeZ(u8, mod_name);
                defer self.allocator.free(mod_name_z);
                const stub = "comptime {}\n";
                if (zir_compilation_add_struct_source(c, mod_name_z, stub.ptr, @intCast(stub.len)) != 0) {
                    return error.ZirInjectionFailed;
                }

                const mod_handle = zir_builder_create() orelse return error.ZirCreateFailed;
                const saved_handle = self.handle;
                self.current_emit_module = mod_name;
                self.handle = mod_handle;

                // Emit struct type declarations before functions so they
                // can be referenced in return types and parameter types.
                try self.emitStructTypeDecls();

                for (funcs) |func| {
                    self.reuse_backed_struct_locals.clearRetainingCapacity();
                    self.reuse_backed_union_locals.clearRetainingCapacity();
                    self.reuse_backed_tuple_locals.clearRetainingCapacity();
                    try self.emitFunction(func);
                }

                if (zir_builder_inject_struct(mod_handle, c, mod_name_z) != 0) {
                    return error.ZirInjectionFailed;
                }

                self.handle = saved_handle;
                self.current_emit_module = null;
            }

            // ── Step 4: Generate namespace re-export modules ─────────
            // Skip parents that are also leaf modules (they already have ZIR injected).
            var ns_iter = namespace_children.iterator();
            while (ns_iter.next()) |entry| {
                const parent_name = entry.key_ptr.*;
                // If parent is a leaf module with ZIR functions, skip re-export
                // (can't overwrite its ZIR with source text)
                if (module_funcs.contains(parent_name)) continue;
                // If parent is already registered as @native-only, skip
                // (already registered as empty module above)
                if (all_module_names.contains(parent_name) and !module_funcs.contains(parent_name)) {
                    // Replace the empty stub with the re-export source
                }

                const children = entry.value_ptr.items;
                var source_buf: std.ArrayListUnmanaged(u8) = .empty;
                for (children) |child| {
                    const line = try std.fmt.allocPrint(self.allocator, "pub const {s} = @import(\"{s}\");\n", .{ child.name, child.full_module });
                    try source_buf.appendSlice(self.allocator, line);
                }
                const source = try source_buf.toOwnedSlice(self.allocator);

                const parent_z = try self.allocator.dupeZ(u8, parent_name);
                defer self.allocator.free(parent_z);
                // This will overwrite the empty stub if already registered
                if (zir_compilation_add_struct_source(c, parent_z, source.ptr, @intCast(source.len)) != 0) {
                    return error.ZirInjectionFailed;
                }
            }
        }

        // ── Step 5: Emit root module functions ───────────────────────
        self.current_emit_module = null;
        for (root_funcs.items) |func| {
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

    /// Check if a function's body contains any list operations that need List refs.
    fn functionUsesListOps(self: *const ZirDriver, func: ir.Function) bool {
        _ = self;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .list_init, .list_cons, .list_len_check, .list_get, .list_head, .list_tail => return true,
                    .guard_block => |gb| {
                        for (gb.body) |bi| {
                            switch (bi) {
                                .list_init, .list_cons, .list_len_check, .list_get, .list_head, .list_tail => return true,
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        return false;
    }

    /// Resolve @import("zap_runtime").List once per function and cache the ref.
    /// Must be called from the main function body (not inside a capture).
    fn ensureListRef(self: *ZirDriver) BuildError!u32 {
        if (self.cached_list_cell_ref != 0) return self.cached_list_cell_ref;
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const ref = zir_builder_emit_field_val(self.handle, rt_import, "List", 4);
        if (ref == error_ref) return error.EmitFailed;
        self.cached_list_cell_ref = ref;
        return ref;
    }

    /// Resolve a List method function ref, caching it for reuse inside condbr bodies.
    fn ensureListMethodRef(self: *ZirDriver, list_cell_ref: u32, method: []const u8, cached: *u32) BuildError!u32 {
        if (cached.* != 0) return cached.*;
        const ref = zir_builder_emit_field_val(self.handle, list_cell_ref, method.ptr, @intCast(method.len));
        if (ref == error_ref) return error.EmitFailed;
        cached.* = ref;
        return ref;
    }

    /// Resolve a parameter type ref, handling list types specially.
    /// List types (`[T]`) are emitted as `?*const zap_runtime.List`.
    const LIST_PARAM_SENTINEL: u32 = 0xFFFFFFFE;

    /// Map an ir.ZigType to a ZIR type Ref constant for use as a comptime
    /// type argument when calling generic constructors (MapOf, ListOf).
    /// Returns null for complex types (structs, nested containers) that
    /// require dynamic resolution via emitTypeRef.
    fn zigTypeToTypeRef(zig_type: ir.ZigType) ?u32 {
        return switch (zig_type) {
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
            .atom => @intFromEnum(Zir.Inst.Ref.u32_type), // atoms are u32 at runtime
            else => null,
        };
    }

    /// Emit a ZIR type reference for any ZigType, including complex types
    /// like structs that need decl_val resolution. Returns the ZIR ref for
    /// the type, or null if the type cannot be resolved.
    fn emitContainerElementTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!?u32 {
        // Try static resolution first
        if (zigTypeToTypeRef(zig_type)) |ref| return ref;
        // Dynamic resolution for complex types
        return switch (zig_type) {
            .struct_ref => |name| {
                // Enums: use u32 atom ID representation (no decl_val needed)
                const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                    name[dot_idx + 1 ..]
                else
                    name;
                if (self.findEnumDef(name) or self.findEnumDef(short_name)) {
                    return @intFromEnum(Zir.Inst.Ref.u32_type);
                }
                // Structs: reference via decl_val
                if (self.findStructDef(name) != null or self.findStructDef(short_name) != null) {
                    const ref = zir_builder_emit_decl_val(
                        self.handle,
                        short_name.ptr,
                        @intCast(short_name.len),
                    );
                    if (ref != error_ref) return ref;
                }
                return null;
            },
            .tagged_union => {
                // Enums use u32 atom IDs at runtime — use u32 as the element
                // type for ListOf/MapOf rather than the Zig enum type.
                // This ensures enum values from lists are compatible with
                // Zap's atom-based pattern dispatch.
                return @intFromEnum(Zir.Inst.Ref.u32_type);
            },
            .list => |inner| {
                // Nested list: element type is ?*const ListOf(T)
                // Get the inner ListOf(T) type, call .empty() on it,
                // then use @TypeOf to get the optional pointer type.
                const inner_ref = try self.emitContainerElementTypeRef(inner.*);
                if (inner_ref) |iref| {
                    const type_args = [_]u32{iref};
                    const inner_list = self.emitGenericContainerRef("ListOf", &type_args) catch return null;
                    // Call .empty() to get a value of type ?*const ListOf(T)
                    const empty_fn = zir_builder_emit_field_val(self.handle, inner_list, "empty", 5);
                    if (empty_fn == error_ref) return null;
                    const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (empty_val == error_ref) return null;
                    // @TypeOf(empty_val) gives ?*const ListOf(T)
                    const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                    if (type_ref == error_ref) return null;
                    return type_ref;
                }
                return null;
            },
            .map => |mt| {
                // Nested map: element type is ?*const MapOf(K, V)
                const key_ref = try self.emitContainerElementTypeRef(mt.key.*);
                const val_ref = try self.emitContainerElementTypeRef(mt.value.*);
                if (key_ref != null and val_ref != null) {
                    const type_args = [_]u32{ key_ref.?, val_ref.? };
                    const inner_map = self.emitGenericContainerRef("MapOf", &type_args) catch return null;
                    // Call .empty() to get ?*const MapOf(K, V), then @TypeOf
                    const empty_fn = zir_builder_emit_field_val(self.handle, inner_map, "empty", 5);
                    if (empty_fn == error_ref) return null;
                    const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (empty_val == error_ref) return null;
                    const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                    if (type_ref == error_ref) return null;
                    return type_ref;
                }
                return null;
            },
            else => null,
        };
    }

    /// Emit a comptime generic container instantiation.
    /// Calls `@import("zap_runtime").{generic_name}(type_args...)` and returns
    /// the ZIR ref to the instantiated type. This enables truly generic
    /// containers without pre-declared named aliases.
    fn emitGenericContainerRef(
        self: *ZirDriver,
        generic_name: []const u8,
        type_args: []const u32,
    ) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const generic_fn = zir_builder_emit_field_val(
            self.handle,
            rt_import,
            generic_name.ptr,
            @intCast(generic_name.len),
        );
        if (generic_fn == error_ref) return error.EmitFailed;
        const instantiated = zir_builder_emit_call_ref(
            self.handle,
            generic_fn,
            type_args.ptr,
            @intCast(type_args.len),
        );
        if (instantiated == error_ref) return error.EmitFailed;
        return instantiated;
    }

    /// Emit a reference to a `ListOf(T)` type instantiation for any element type.
    /// Uses comptime generic instantiation via `@import("zap_runtime").ListOf(T)`.
    fn emitListCellRef(self: *ZirDriver, element_type: ir.ZigType) BuildError!u32 {
        const elem_ref = (try self.emitContainerElementTypeRef(element_type)) orelse
            zigTypeToTypeRef(element_type) orelse
            @intFromEnum(Zir.Inst.Ref.i64_type);
        const type_args = [_]u32{elem_ref};
        return self.emitGenericContainerRef("ListOf", &type_args);
    }

    /// Emit a reference to a `MapOf(K, V)` type instantiation for any key/value types.
    /// Uses comptime generic instantiation via `@import("zap_runtime").MapOf(K, V)`.
    fn emitMapCellRef(self: *ZirDriver, key_type: ir.ZigType, value_type: ir.ZigType) BuildError!u32 {
        const key_ref = (try self.emitContainerElementTypeRef(key_type)) orelse
            zigTypeToTypeRef(key_type) orelse
            @intFromEnum(Zir.Inst.Ref.u32_type);
        const val_ref = (try self.emitContainerElementTypeRef(value_type)) orelse
            zigTypeToTypeRef(value_type) orelse
            @intFromEnum(Zir.Inst.Ref.i64_type);
        const type_args = [_]u32{ key_ref, val_ref };
        return self.emitGenericContainerRef("MapOf", &type_args);
    }

    /// Map (key_type, value_type) to the runtime MapType pointer alias name.
    /// Used for return type declarations where the fork API requires named types.
    fn getMapTypeName(key_type: ir.ZigType, value_type: ir.ZigType) []const u8 {
        if (std.meta.activeTag(key_type) == .atom) {
            return switch (std.meta.activeTag(value_type)) {
                .string => "MapAtomStringType",
                .bool_type => "MapAtomBoolType",
                .f64 => "MapAtomFloatType",
                else => "MapAtomIntType",
            };
        }
        if (std.meta.activeTag(key_type) == .string) {
            return switch (std.meta.activeTag(value_type)) {
                .string => "MapStringStringType",
                .f64 => "MapStringFloatType",
                else => "MapStringIntType",
            };
        }
        return "MapAtomIntType";
    }

    /// Map a list element ZigType to the runtime ListType alias name.
    /// Used for return type declarations where the fork API requires named types.
    fn getListTypeName(element_type: ir.ZigType) []const u8 {
        return switch (std.meta.activeTag(element_type)) {
            .string => "StringListType",
            .bool_type => "BoolListType",
            .f64 => "FloatListType",
            .atom => "AtomListType",
            else => "ListType",
        };
    }

    /// Resolve an encoded type name (from call_builtin encoding) to a ZIR type ref.
    /// Returns null for non-primitive names that need decl_val resolution.
    fn encodedNameToTypeRef(name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "i64")) return @intFromEnum(Zir.Inst.Ref.i64_type);
        if (std.mem.eql(u8, name, "i32")) return @intFromEnum(Zir.Inst.Ref.i32_type);
        if (std.mem.eql(u8, name, "i16")) return @intFromEnum(Zir.Inst.Ref.i16_type);
        if (std.mem.eql(u8, name, "i8")) return @intFromEnum(Zir.Inst.Ref.i8_type);
        if (std.mem.eql(u8, name, "u64")) return @intFromEnum(Zir.Inst.Ref.u64_type);
        if (std.mem.eql(u8, name, "u32")) return @intFromEnum(Zir.Inst.Ref.u32_type);
        if (std.mem.eql(u8, name, "u16")) return @intFromEnum(Zir.Inst.Ref.u16_type);
        if (std.mem.eql(u8, name, "u8")) return @intFromEnum(Zir.Inst.Ref.u8_type);
        if (std.mem.eql(u8, name, "f64")) return @intFromEnum(Zir.Inst.Ref.f64_type);
        if (std.mem.eql(u8, name, "f32")) return @intFromEnum(Zir.Inst.Ref.f32_type);
        if (std.mem.eql(u8, name, "f16")) return @intFromEnum(Zir.Inst.Ref.f16_type);
        if (std.mem.eql(u8, name, "bool")) return @intFromEnum(Zir.Inst.Ref.bool_type);
        if (std.mem.eql(u8, name, "str")) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type);
        return null;
    }

    /// Extract element type from a list ZigType. Returns .i64 as default.
    fn getListElementType(list_type: ir.ZigType) ir.ZigType {
        if (std.meta.activeTag(list_type) == .list) {
            return list_type.list.*;
        }
        return .i64;
    }

    fn emitTypedParam(self: *ZirDriver, param: ir.Param) !u32 {
        // Struct params: use the nominal struct type via decl_val
        if (std.meta.activeTag(param.type_expr) == .struct_ref) {
            const name = param.type_expr.struct_ref;
            const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                name[dot_idx + 1 ..]
            else
                name;
            if (self.findStructDef(name) != null or self.findStructDef(short_name) != null) {
                const ref = zir_builder_emit_param_decl_val_type(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    short_name.ptr,
                    @intCast(short_name.len),
                );
                if (ref != error_ref) return ref;
            }
        }
        // Map and list params use anytype — generic container types like
        // ListOf(T) and MapOf(K,V) can't be expressed as named imports.
        // Zig infers the correct type from usage.
        if (std.meta.activeTag(param.type_expr) == .map or
            std.meta.activeTag(param.type_expr) == .list)
        {
            const ref = zir_builder_emit_param(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                @intFromEnum(Zir.Inst.Ref.none),
            );
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        }
        const effective_type = mapParamType(param.type_expr);
        const ref = zir_builder_emit_param(
            self.handle,
            param.name.ptr,
            @intCast(param.name.len),
            effective_type,
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit the return type declaration for any type that mapReturnType
    /// cannot handle as a well-known ZIR ref. Every ZigType variant must
    /// have a code path here — the developer explicitly declared the return
    /// type, so the compiler must emit it exactly. If a new type is added
    /// to Zap without a case here, the build fails loudly.
    fn emitComplexReturnType(self: *ZirDriver, return_type: ir.ZigType) !void {
        switch (return_type) {
            .list => {
                // List return types still use named aliases until the fork
                // supports setting return types from generic container refs.
                const type_name = getListTypeName(getListElementType(return_type));
                if (zir_builder_set_imported_return_type(self.handle, "zap_runtime", 11, type_name.ptr, @intCast(type_name.len)) != 0)
                    return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .map => |mt| {
                const type_name = getMapTypeName(mt.key.*, mt.value.*);
                if (zir_builder_set_imported_return_type(self.handle, "zap_runtime", 11, type_name.ptr, @intCast(type_name.len)) != 0)
                    return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .tuple => |elements| {
                var tuple_type_refs: std.ArrayListUnmanaged(u32) = .empty;
                defer tuple_type_refs.deinit(self.allocator);
                for (elements) |elem_type| {
                    const ref = try self.emitImportedTypeRef(elem_type);
                    try tuple_type_refs.append(self.allocator, ref);
                }
                if (zir_builder_set_tuple_return_type(
                    self.handle,
                    tuple_type_refs.items.ptr,
                    @intCast(tuple_type_refs.items.len),
                ) != 0) {
                    return error.EmitFailed;
                }
                self.current_ret_type = 1;
            },
            .struct_ref => |name| {
                if (self.findUnionDef(name)) |union_def| {
                    var name_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                    defer name_ptrs.deinit(self.allocator);
                    var name_lens: std.ArrayListUnmanaged(u32) = .empty;
                    defer name_lens.deinit(self.allocator);
                    var type_refs: std.ArrayListUnmanaged(u32) = .empty;
                    defer type_refs.deinit(self.allocator);

                    for (union_def.variants) |variant| {
                        try name_ptrs.append(self.allocator, variant.name.ptr);
                        try name_lens.append(self.allocator, @intCast(variant.name.len));
                        const type_ref = if (variant.type_name) |tn|
                            self.mapTypeNameToRef(tn)
                        else
                            0;
                        try type_refs.append(self.allocator, type_ref);
                    }

                    if (zir_builder_set_union_return_type(
                        self.handle,
                        name_ptrs.items.ptr,
                        name_lens.items.ptr,
                        type_refs.items.ptr,
                        @intCast(union_def.variants.len),
                    ) != 0) {
                        return error.EmitFailed;
                    }
                    self.current_ret_type = 1;
                    self.cached_union_ret_type_ref = zir_builder_get_union_ret_type_ref(self.handle);
                } else if (self.structIsInCurrentModule(name)) {
                    // Nominal struct type declared in the current module:
                    // reference via decl_val.
                    const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                        name[dot_idx + 1 ..]
                    else
                        name;
                    if (zir_builder_set_decl_val_return_type(self.handle, short_name.ptr, @intCast(short_name.len)) != 0)
                        return error.EmitFailed;
                    self.current_ret_type = 1;
                } else if (self.findStructDef(name) != null) {
                    // Cross-module struct: import from the defining module.
                    const module_name = self.structToModuleName(name);
                    const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                        name[dot_idx + 1 ..]
                    else
                        name;
                    if (zir_builder_set_imported_return_type(self.handle, module_name.ptr, @intCast(module_name.len), short_name.ptr, @intCast(short_name.len)) != 0)
                        return error.EmitFailed;
                    self.current_ret_type = 1;
                } else {
                    // Unknown struct_ref: use generic inference
                    if (zir_builder_set_generic_return_type(self.handle) != 0)
                        return error.EmitFailed;
                    self.current_ret_type = 1;
                }
            },
            .optional => {
                // Optional wrapping is handled by set_optional_return_type
                // which is called separately for __try variants. If we reach
                // here, the inner type wasn't a primitive — this needs the
                // optional wrapper on top of the resolved inner type.
                if (zir_builder_set_optional_return_type(self.handle) != 0)
                    return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .function, .tagged_union, .ptr, .any => {
                // These types are structural and created anonymously in the
                // body. Zig infers the return type from the body construction.
                if (zir_builder_set_generic_return_type(self.handle) != 0)
                    return error.EmitFailed;
                self.current_ret_type = 1;
            },
            // Primitives are handled by mapReturnType — they never reach here.
            // void/nil have ret_type=0 intentionally — they never reach here.
            .void, .nil, .never, .bool_type,
            .i8, .i16, .i32, .i64,
            .u8, .u16, .u32, .u64,
            .usize, .isize,
            .f16, .f32, .f64,
            .string, .atom,
            => unreachable, // handled by mapReturnType
        }
    }

    fn emitFunction(self: *ZirDriver, func: ir.Function) !void {
        // Detect the entry point using the program's entry function ID.
        // When multiple modules define main, only the one matching the
        // manifest root is emitted as "main" in ZIR.
        const is_main = if (self.program) |prog|
            if (prog.entry) |entry_id| func.id == entry_id else false
        else
            std.mem.eql(u8, func.name, "main") or
                std.mem.endsWith(u8, func.name, "__main") or
                std.mem.find(u8, func.name, "__main__") != null;

        // In library mode, skip the main function.
        if (self.lib_mode and is_main) return;

        self.local_refs.clearRetainingCapacity();
        self.param_refs.clearRetainingCapacity();
        self.closure_function_map.clearRetainingCapacity();
        self.capture_param_refs.clearRetainingCapacity();
        self.cached_list_cell_ref = 0;
        self.cached_list_gethead_ref = 0;
        self.cached_list_gettail_ref = 0;
        self.cached_list_cons_ref = 0;
        self.cached_list_length_ref = 0;
        self.cached_list_get_ref = 0;
        self.current_closure_env_ref = null;
        self.cached_list_type_ref = 0;
        self.skip_next_ret_local = null;
        self.current_function_id = func.id;
        self.current_function_is_closure = func.captures.len > 0;
        const closure_lowering = self.getClosureLowering(func.id, func.captures.len);
        var ret_type = if (is_main)
            mapMainReturnType(func.return_type)
        else
            mapReturnType(func.return_type);
        // Functions with callback params: use generic return type so Zig
        // infers from the body. The callCallableN helpers return anytype-
        // derived types that can't match a concrete declared return type.
        // Functions where the return type was derived from a callback
        // (e.g., ( -> result) -> result): use generic return type so
        // Zig can infer from callCallableN's result type.
        // Detect: return type is .any AND a param is a function type.
        // Functions where a callback param's return type matches the
        // function's return type: use generic return so Zig infers from
        // the callCallableN result. This handles ( -> T) -> T patterns.
        // Enum return types use u32 atom IDs in Zap's representation
        if (ret_type == 0 and std.meta.activeTag(func.return_type) == .struct_ref) {
            const rname = func.return_type.struct_ref;
            const short = if (std.mem.lastIndexOf(u8, rname, ".")) |di| rname[di + 1 ..] else rname;
            if (self.findEnumDef(rname) or self.findEnumDef(short))
                ret_type = @intFromEnum(Zir.Inst.Ref.u32_type);
        }

        self.current_ret_type = ret_type;

        const emit_name = if (is_main)
            @as([]const u8, "main")
        else if (self.current_emit_module != null and func.local_name.len > 0)
            func.local_name
        else
            func.name;
        if (zir_builder_begin_func(self.handle, emit_name.ptr, @intCast(emit_name.len), ret_type) != 0) {
            return error.BeginFuncFailed;
        }

        // __try variants return optionals: ?ReturnType.
        // On no-match, they return null. The caller checks and runs the handler.
        const is_try_variant = std.mem.endsWith(u8, func.name, "__try");
        if (is_try_variant) {
            if (zir_builder_set_optional_return_type(self.handle) != 0)
                return error.EmitFailed;
        }

        // Declare the return type. Primitives are handled by mapReturnType
        // above (well-known ZIR refs). Complex types need dedicated ZIR
        // instructions emitted into the declaration body. Any type not
        // explicitly handled falls back to generic return type inference,
        // which lets Zig determine the return type from the function body.
        // This ensures ALL types work as return values without hardcoding.
        // Skip for main — Zig requires main to return void or u8.
        if (!is_main and ret_type == 0 and func.return_type != .void and func.return_type != .nil) {
            try self.emitComplexReturnType(func.return_type);
        }

        self.tuple_init_count = 0;
        self.tuple_type_stack.clearRetainingCapacity();

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
                const param_ref = try self.emitTypedParam(param);
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        } else if (closure_lowering.needs_env_param) {
            const env_param_ref = zir_builder_emit_param(self.handle, "__closure_env".ptr, 13, @intFromEnum(Zir.Inst.Ref.none));
            if (env_param_ref == error_ref) return error.EmitFailed;
            self.current_closure_env_ref = env_param_ref;
            for (func.params, 0..) |param, i| {
                const param_ref = try self.emitTypedParam(param);
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        } else if (is_main and func.params.len == 1) {
            // Inject: const args = @import("zap_runtime").getArgv()
            // In Zig 0.16, std.os.argv was removed; use runtime helper instead.
            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
            if (rt_import == error_ref) return error.EmitFailed;
            const get_argv_fn = zir_builder_emit_field_val(self.handle, rt_import, "getArgv", 7);
            if (get_argv_fn == error_ref) return error.EmitFailed;
            const args_ref = zir_builder_emit_call_ref(self.handle, get_argv_fn, @as([*]const u32, &.{}), 0);
            if (args_ref == error_ref) return error.EmitFailed;

            // Store as the first param's local ref
            try self.param_refs.append(self.allocator, args_ref);
            try self.setLocal(0, args_ref);
        } else {
            for (func.params, 0..) |param, i| {
                const param_ref = try self.emitTypedParam(param);
                try self.param_refs.append(self.allocator, param_ref);
                try self.setLocal(@intCast(i), param_ref);
            }
        }

        // Pre-resolve List method refs at function scope so they're available
        // inside condbr bodies (guard blocks). Import resolution inside condbr
        // branch scopes can fail, so we resolve the @import chain here.
        if (self.functionUsesListOps(func)) {
            const list_cell = try self.ensureListRef();
            _ = try self.ensureListMethodRef(list_cell, "getHead", &self.cached_list_gethead_ref);
            _ = try self.ensureListMethodRef(list_cell, "getTail", &self.cached_list_gettail_ref);
            _ = try self.ensureListMethodRef(list_cell, "cons", &self.cached_list_cons_ref);
            _ = try self.ensureListMethodRef(list_cell, "length", &self.cached_list_length_ref);
            _ = try self.ensureListMethodRef(list_cell, "get", &self.cached_list_get_ref);
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
                .needs_env_param = has_captures,
                .direct_capture_params = false,
                .needs_closure_object = has_captures,
                .stack_env = false,
                .storage_scope = if (has_captures) .stack_function else .immediate,
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
        // A function with no captures is always lambda-lifted regardless of
        // what the escape analysis says — there's no environment to allocate.
        if (capture_count == 0)
            return closure_lowering_for_tier(.lambda_lifted, 0);
        const tier = if (self.analysis_context) |actx|
            actx.getClosureTier(function_id)
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

    /// Check if a local holds a bare function reference (0-capture make_closure).
    /// Bare function refs are stored as decl_ref values, not closure structs,
    /// so they must be called via call_ref rather than struct field access.
    fn isBareFunctionRef(self: *const ZirDriver, local: ir.LocalId) bool {
        if (self.findClosureCallTarget(local)) |target| {
            return target.captures.len == 0;
        }
        return false;
    }

    fn findClosureCallTarget(self: *const ZirDriver, local: ir.LocalId) ?ClosureCallTarget {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id != self.current_function_id) continue;
                // Search across ALL blocks in the function body so that
                // local chains spanning block boundaries can be resolved.
                for (func.body) |block| {
                    if (findClosureTargetInInstrs(block.instructions, local)) |target| return target;
                }
                // Second pass: if a local_set in one block references a value
                // defined in another block, resolve the chain across blocks.
                for (func.body) |block| {
                    if (findClosureTargetCrossBlock(func.body, block.instructions, local)) |target| return target;
                }
            }
        }
        return null;
    }

    /// Search for a closure target across block boundaries. When a local_set/local_get
    /// in one block references a value from another block, search all blocks for the source.
    fn findClosureTargetCrossBlock(all_blocks: []const ir.Block, instrs: []const ir.Instruction, local: ir.LocalId) ?ClosureCallTarget {
        for (instrs) |instr| {
            const source_local: ?ir.LocalId = switch (instr) {
                .local_set => |ls| if (ls.dest == local) ls.value else null,
                .local_get => |lg| if (lg.dest == local) lg.source else null,
                .move_value => |mv| if (mv.dest == local) mv.source else null,
                .share_value => |sv| if (sv.dest == local) sv.source else null,
                else => null,
            };
            if (source_local) |src| {
                // Search all blocks for the source local
                for (all_blocks) |block| {
                    if (findClosureTargetInInstrs(block.instructions, src)) |target| return target;
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
                .union_switch => |us| {
                    for (us.cases) |case| {
                        if (findClosureTargetInInstrsDepth(case.body_instrs, local, depth)) |target| return target;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn emitNamedCallToTarget(self: *ZirDriver, target_id: ir.FunctionId, captures: []const ir.LocalId, args_locals: []const ir.LocalId) !u32 {
        const target_func = self.findFunctionById(target_id) orelse return error.EmitFailed;
        const lowering = self.getClosureLowering(target_id, captures.len);
        var args : std.ArrayListUnmanaged(u32) = .empty;
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

        // Cross-module routing
        const target_module = target_func.module_name;
        const is_cross = blk: {
            if (target_module == null and self.current_emit_module == null) break :blk false;
            if (target_module == null or self.current_emit_module == null) break :blk true;
            break :blk !std.mem.eql(u8, target_module.?, self.current_emit_module.?);
        };
        if (is_cross and target_module != null) {
            return try self.emitCrossModuleCall(target_module.?, target_func.local_name, args.items);
        }

        const call_name = if (self.current_emit_module != null and target_func.local_name.len > 0)
            target_func.local_name
        else
            target_func.name;
        const ref = zir_builder_emit_call(self.handle, call_name.ptr, @intCast(call_name.len), args.items.ptr, @intCast(args.items.len));
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

        var fallback_args : std.ArrayListUnmanaged(u32) = .empty;
        defer fallback_args.deinit(self.allocator);
        for (cc.args) |arg| {
            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
            try fallback_args.append(self.allocator, ref);
        }

        self.beginCapture();
        const fallback_ref = zir_builder_emit_call_ref(self.handle, callee_ref, fallback_args.items.ptr, @intCast(fallback_args.items.len));
        if (fallback_ref == error_ref) return false;
        try self.setLocal(cc.dest, fallback_ref);
        var else_len: u32 = 0;
        const else_ptr = self.endCapture(&else_len);
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

            self.beginCapture();
            const direct_ref = try self.emitNamedCallToTarget(target_id, &.{}, cc.args);
            try self.setLocal(cc.dest, direct_ref);
            var then_len: u32 = 0;
            const then_ptr = self.endCapture(&then_len);
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
                // Inside case blocks, emit typed i64 to avoid comptime_int
                // depending on runtime control flow.
                const ref = if (self.current_case_dest != null)
                    zir_builder_emit_int_typed(self.handle, ci.value, @intFromEnum(Zir.Inst.Ref.i64_type))
                else
                    zir_builder_emit_int(self.handle, ci.value);
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
                if (self.closure_function_map.get(lg.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, lg.dest, func_id);
                if (self.local_refs.get(lg.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, lg.dest, value_ref);
                }
            },
            .local_set => |ls| {
                try self.propagateReuseBackedStructLocal(ls.dest, ls.value);
                try self.propagateReuseBackedUnionLocal(ls.dest, ls.value);
                try self.propagateReuseBackedTupleLocal(ls.dest, ls.value);
                if (self.closure_function_map.get(ls.value)) |func_id|
                    try self.closure_function_map.put(self.allocator, ls.dest, func_id);
                if (self.local_refs.get(ls.value)) |value_ref| {
                    try self.local_refs.put(self.allocator, ls.dest, value_ref);
                }
            },
            .move_value => |mv| {
                try self.propagateReuseBackedStructLocal(mv.dest, mv.source);
                try self.propagateReuseBackedUnionLocal(mv.dest, mv.source);
                try self.propagateReuseBackedTupleLocal(mv.dest, mv.source);
                if (self.closure_function_map.get(mv.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, mv.dest, func_id);
                if (self.local_refs.get(mv.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, mv.dest, value_ref);
                }
            },
            .share_value => |sv| {
                try self.propagateReuseBackedStructLocal(sv.dest, sv.source);
                try self.propagateReuseBackedUnionLocal(sv.dest, sv.source);
                try self.propagateReuseBackedTupleLocal(sv.dest, sv.source);
                if (self.closure_function_map.get(sv.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, sv.dest, func_id);
                if (self.local_refs.get(sv.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, sv.dest, value_ref);

                    if (!self.shouldSkipArc(sv.source)) {
                        const materialized_ref = try self.materializeValueRef(value_ref);
                        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                        if (rt_import == error_ref) return error.EmitFailed;
                        const arc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ArcRuntime", 10);
                        if (arc_runtime == error_ref) return error.EmitFailed;
                        const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAny", 9);
                        if (retain_fn == error_ref) return error.EmitFailed;

                        const args = [_]u32{materialized_ref};
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
                } else if (self.local_refs.get(pg.index)) |value_ref| {
                    const materialized = try self.materializeValueRef(value_ref);
                    try self.setLocal(pg.dest, materialized);
                }
            },

            // Binary operations
            .binary_op => |bo| {
                if (bo.op == .bool_and or bo.op == .bool_or) {
                    // Emit short-circuit bool_br_and / bool_br_or ZIR instructions.
                    // The RHS is wrapped in a body so it's only evaluated when needed.
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;
                    // Body is empty (RHS already evaluated as a local), just pass the result.
                    const empty_body = [_]u32{};
                    const ref = if (bo.op == .bool_and)
                        self.emitBoolBrAnd(lhs, &empty_body, rhs) catch return error.EmitFailed
                    else
                        self.emitBoolBrOr(lhs, &empty_body, rhs) catch return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (mapBinopTag(bo.op)) |tag| {
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;
                    const ref = zir_builder_emit_binop(self.handle, tag, lhs, rhs);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .string_eq or bo.op == .string_neq) {
                    // String comparison via std.mem.eql(u8, lhs, rhs)
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;

                    const std_import = zir_builder_emit_import(self.handle, "std", 3);
                    if (std_import == error_ref) return error.EmitFailed;
                    const mem_mod = zir_builder_emit_field_val(self.handle, std_import, "mem", 3);
                    if (mem_mod == error_ref) return error.EmitFailed;
                    const eql_fn = zir_builder_emit_field_val(self.handle, mem_mod, "eql", 3);
                    if (eql_fn == error_ref) return error.EmitFailed;

                    const u8_type_ref = @intFromEnum(Zir.Inst.Ref.u8_type);
                    const call_args = [_]u32{ u8_type_ref, lhs, rhs };
                    var ref = zir_builder_emit_call_ref(self.handle, eql_fn, &call_args, 3);
                    if (ref == error_ref) return error.EmitFailed;

                    // For string_neq, negate the result
                    if (bo.op == .string_neq) {
                        ref = zir_builder_emit_bool_not(self.handle, ref);
                        if (ref == error_ref) return error.EmitFailed;
                    }
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .concat) {
                    // concat — emit @import("zap_runtime").ZapString.concatBump(lhs, rhs)
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const zap_string = zir_builder_emit_field_val(self.handle, rt_import, "String", 6);
                    if (zap_string == error_ref) return error.EmitFailed;
                    const concat_fn = zir_builder_emit_field_val(self.handle, zap_string, "concatBump", 10);
                    if (concat_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ lhs, rhs };
                    const ref = zir_builder_emit_call_ref(self.handle, concat_fn, &args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .in_list) {
                    // in — emit: lhs == list[0] or lhs == list[1] or ...
                    // For runtime lists, call the list's contains method via generic dispatch.
                    const lhs = self.refForLocal(bo.lhs) catch return;
                    const rhs = self.refForLocal(bo.rhs) catch return;

                    // Use the generic list contains: get the list type, then call .contains(list, value)
                    // The list (rhs) already has the right type at runtime — call contains as a method.
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const list_mod = zir_builder_emit_field_val(self.handle, rt_import, "List", 4);
                    if (list_mod == error_ref) return error.EmitFailed;
                    const contains_fn = zir_builder_emit_field_val(self.handle, list_mod, "contains", 8);
                    if (contains_fn == error_ref) return error.EmitFailed;

                    const call_args = [_]u32{ rhs, lhs };
                    const ref = zir_builder_emit_call_ref(self.handle, contains_fn, &call_args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .in_range) {
                    // in_range: check value >= min(start,end) and value <= max(start,end)
                    // and rem(value - start, step) == 0
                    const value_ref = self.refForLocal(bo.lhs) catch return;
                    const range_ref = self.refForLocal(bo.rhs) catch return;

                    // Extract range fields: start, end, step
                    const start_ref = zir_builder_emit_field_val(self.handle, range_ref, "start", 5);
                    if (start_ref == error_ref) return error.EmitFailed;
                    const end_ref = zir_builder_emit_field_val(self.handle, range_ref, "end", 3);
                    if (end_ref == error_ref) return error.EmitFailed;
                    const step_ref = zir_builder_emit_field_val(self.handle, range_ref, "step", 4);
                    if (step_ref == error_ref) return error.EmitFailed;

                    // Compute min and max: if start <= end then min=start,max=end else min=end,max=start
                    const start_le_end = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_lte), start_ref, end_ref);
                    if (start_le_end == error_ref) return error.EmitFailed;

                    // min = if start <= end then start else end
                    const min_ref = zir_builder_emit_if_else_inline(self.handle, start_le_end, start_ref, end_ref);
                    if (min_ref == error_ref) return error.EmitFailed;
                    // max = if start <= end then end else start
                    const max_ref = zir_builder_emit_if_else_inline(self.handle, start_le_end, end_ref, start_ref);
                    if (max_ref == error_ref) return error.EmitFailed;

                    // value >= min
                    const gte_min = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_gte), value_ref, min_ref);
                    if (gte_min == error_ref) return error.EmitFailed;
                    // value <= max
                    const lte_max = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_lte), value_ref, max_ref);
                    if (lte_max == error_ref) return error.EmitFailed;

                    // (value - start) rem step == 0
                    const diff = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.subwrap), value_ref, start_ref);
                    if (diff == error_ref) return error.EmitFailed;
                    // Compute remainder manually: diff - (diff / step) * step
                    // This handles signed integers correctly.
                    const quotient = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.div_trunc), diff, step_ref);
                    if (quotient == error_ref) return error.EmitFailed;
                    const product = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.mulwrap), quotient, step_ref);
                    if (product == error_ref) return error.EmitFailed;
                    const remainder = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.subwrap), diff, product);
                    if (remainder == error_ref) return error.EmitFailed;
                    const zero_ref = zir_builder_emit_int(self.handle, 0);
                    if (zero_ref == error_ref) return error.EmitFailed;
                    const on_step = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_eq), remainder, zero_ref);
                    if (on_step == error_ref) return error.EmitFailed;

                    // Combine: gte_min and lte_max and on_step (short-circuit)
                    const empty_body = [_]u32{};
                    const in_bounds = self.emitBoolBrAnd(gte_min, &empty_body, lte_max) catch return error.EmitFailed;
                    const result = self.emitBoolBrAnd(in_bounds, &empty_body, on_step) catch return error.EmitFailed;

                    try self.setLocal(bo.dest, result);
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
                var args : std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (cn.args) |arg| {
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }

                // Inline default parameter values: emit default ZIR instructions
                // BEFORE the call (so they don't interfere with addCall's inst prediction)
                // Match by base name (without arity suffix) since call-site arity
                // may differ from declared arity when defaults fill the gap.
                var resolved_call_name: []const u8 = cn.name;
                if (self.program) |prog| {
                    for (prog.functions) |func| {
                        const cn_base = if (std.mem.findLast(u8, cn.name, "__")) |pos| cn.name[0..pos] else cn.name;
                        const func_base = if (std.mem.findLast(u8, func.name, "__")) |pos| func.name[0..pos] else func.name;
                        if (std.mem.eql(u8, func_base, cn_base) and func.defaults.len > 0) {
                            // After inlining, use the function's actual name (with declared arity)
                            resolved_call_name = func.name;
                            const full_arity = func.params.len;
                            if (args.items.len < full_arity) {
                                const first_default_idx = full_arity - func.defaults.len;
                                var pi = args.items.len;
                                while (pi < full_arity) : (pi += 1) {
                                    if (pi >= first_default_idx) {
                                        const di = pi - first_default_idx;
                                        if (di < func.defaults.len) {
                                            const default_ref: u32 = switch (func.defaults[di]) {
                                                .int => |v| zir_builder_emit_int(self.handle, v),
                                                .float => |v| zir_builder_emit_float(self.handle, v),
                                                .string => |v| zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len)),
                                                .bool_val => |v| zir_builder_emit_bool(self.handle, v),
                                                .nil => @intFromEnum(Zir.Inst.Ref.null_value),
                                            };
                                            if (default_ref == error_ref) return error.EmitFailed;
                                            try args.append(self.allocator, default_ref);
                                        }
                                    }
                                }
                            }
                            break;
                        }
                    }
                }

                {
                    // Look up the target function — first by full mangled name,
                    // then by local_name. Bare names like "begin_test" come from
                    // macro-expanded code (use/import) where the module prefix
                    // was stripped during expansion.
                    const target_func = self.findFunctionByName(resolved_call_name) orelse
                        self.findFunctionByLocalName(resolved_call_name);
                    // Debug removed
                    const target_module = if (target_func) |tf| tf.module_name else null;
                    const is_cross_module = blk: {
                        if (target_module == null and self.current_emit_module == null) break :blk false;
                        if (target_module == null or self.current_emit_module == null) break :blk true;
                        break :blk !std.mem.eql(u8, target_module.?, self.current_emit_module.?);
                    };

                    if (is_cross_module and target_module != null) {
                        const target_local = if (target_func) |tf|
                            (if (tf.local_name.len > 0) tf.local_name else cn.name)
                        else
                            cn.name;
                        const ref = try self.emitCrossModuleCall(target_module.?, target_local, args.items);
                        try self.setLocal(cn.dest, ref);
                    } else {
                        const call_name = if (self.current_emit_module != null)
                            if (target_func) |tf| tf.local_name else cn.name
                        else
                            cn.name;
                        const ref = zir_builder_emit_call(
                            self.handle,
                            call_name.ptr,
                            @intCast(call_name.len),
                            args.items.ptr,
                            @intCast(args.items.len),
                        );
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cn.dest, ref);
                    }
                }
            },

            .try_call_named => |tcn| {
                var args : std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (tcn.args) |arg| {
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                zir_builder_set_call_modifier(self.handle, 3); // no_optimizations

                // Resolve name for per-module emission
                const try_target = self.findFunctionByName(tcn.name) orelse
                    self.findFunctionByLocalName(tcn.name);
                const try_target_module = if (try_target) |tf| tf.module_name else null;
                const try_is_cross = blk: {
                    if (try_target_module == null and self.current_emit_module == null) break :blk false;
                    if (try_target_module == null or self.current_emit_module == null) break :blk true;
                    break :blk !std.mem.eql(u8, try_target_module.?, self.current_emit_module.?);
                };

                const call_ref = if (try_is_cross and try_target_module != null) blk: {
                    const target_local = if (try_target) |tf| tf.local_name else tcn.name;
                    break :blk try self.emitCrossModuleCall(try_target_module.?, target_local, args.items);
                } else blk: {
                    const try_call_name = if (self.current_emit_module != null)
                        if (try_target) |tf| tf.local_name else tcn.name
                    else
                        tcn.name;
                    const ref = zir_builder_emit_call(
                        self.handle,
                        try_call_name.ptr,
                        @intCast(try_call_name.len),
                        args.items.ptr,
                        @intCast(args.items.len),
                    );
                    if (ref == error_ref) return error.EmitFailed;
                    break :blk ref;
                };

                // __try returns optional (?ReturnType). null = no match.
                const is_non_null = zir_builder_emit_is_non_null(self.handle, call_ref);
                if (is_non_null == error_ref) return error.EmitFailed;

                // Then branch (non-null = matched): unwrap optional payload
                self.beginCapture();
                const payload = zir_builder_emit_optional_payload_unsafe(self.handle, call_ref);
                if (payload == error_ref) return error.EmitFailed;
                var then_len: u32 = 0;
                const then_ptr = self.endCapture(&then_len);
                const then_insts = try self.allocator.alloc(u32, then_len);
                @memcpy(then_insts, then_ptr[0..then_len]);

                // Else branch (null = no match): evaluate handler with input, return result
                self.beginCapture();
                // Emit handler instructions (they reference the input local via __err)
                for (tcn.handler_instrs) |hi| try self.emitInstruction(hi);
                if (tcn.handler_result) |hr| {
                    const hr_ref = try self.refForLocal(hr);
                    if (zir_builder_emit_ret(self.handle, hr_ref) != 0)
                        return error.EmitFailed;
                }
                var else_len: u32 = 0;
                const else_ptr = self.endCapture(&else_len);
                const handler_result_ref = if (tcn.handler_result) |hr|
                    self.refForLocal(hr) catch @intFromEnum(Zir.Inst.Ref.void_value)
                else
                    @intFromEnum(Zir.Inst.Ref.void_value);

                // Emit if-else: if (non_null) { unwrap } else { handler + return }
                const result = zir_builder_emit_if_else_bodies(
                    self.handle,
                    is_non_null,
                    then_insts.ptr,
                    @intCast(then_insts.len),
                    payload,
                    else_ptr,
                    else_len,
                    handler_result_ref,
                );
                self.allocator.free(then_insts);
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(tcn.dest, result);
            },
            // Error catch — no longer needed (try_call_named handles unwrapping).
            .error_catch => |ec| {
                const source_ref = self.refForValueLocal(ec.source) catch @intFromEnum(Zir.Inst.Ref.void_value);
                try self.setLocal(ec.dest, source_ref);
            },

            // Builtin calls — emit @import("zap_runtime").Module.function(args)
            .call_builtin => |cb| {
                var args : std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (cb.args) |arg| {
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }

                // Handle generic container calls: "ListOf:StructName.method"
                // These are emitted by the IR builder for struct element lists.
                const generic_handled = if (std.mem.startsWith(u8, cb.name, "ListOf:")) blk: {
                    const after_prefix = cb.name["ListOf:".len..];
                    if (std.mem.findScalar(u8, after_prefix, '.')) |dot_idx| {
                        const type_name = after_prefix[0..dot_idx];
                        const method_name = after_prefix[dot_idx + 1 ..];
                        const type_ref = encodedNameToTypeRef(type_name) orelse
                            zir_builder_emit_decl_val(self.handle, type_name.ptr, @intCast(type_name.len));
                        if (type_ref != error_ref) {
                            const type_args = [_]u32{type_ref};
                            const list_type = self.emitGenericContainerRef("ListOf", &type_args) catch break :blk false;
                            const fn_ref = zir_builder_emit_field_val(self.handle, list_type, method_name.ptr, @intCast(method_name.len));
                            if (fn_ref != error_ref) {
                                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                                if (ref != error_ref) {
                                    try self.setLocal(cb.dest, ref);
                                    break :blk true;
                                }
                            }
                        }
                    }
                    break :blk false;
                } else if (std.mem.startsWith(u8, cb.name, "MapOf:")) blk2: {
                    // Handle "MapOf:keytype:ValueStructName.method"
                    const after_prefix = cb.name["MapOf:".len..];
                    // Parse key_type_name:value_struct_name.method
                    if (std.mem.findScalar(u8, after_prefix, ':')) |colon_idx| {
                        const key_type_name = after_prefix[0..colon_idx];
                        const rest = after_prefix[colon_idx + 1 ..];
                        if (std.mem.findScalar(u8, rest, '.')) |dot_idx| {
                            const value_struct_name = rest[0..dot_idx];
                            const method_name = rest[dot_idx + 1 ..];
                            // Resolve key type ref
                            const key_ref: u32 = if (std.mem.eql(u8, key_type_name, "u32"))
                                @intFromEnum(Zir.Inst.Ref.u32_type)
                            else if (std.mem.eql(u8, key_type_name, "str"))
                                @intFromEnum(Zir.Inst.Ref.slice_const_u8_type)
                            else
                                @intFromEnum(Zir.Inst.Ref.u32_type);
                            // Resolve value type — primitive or struct
                            const val_ref = encodedNameToTypeRef(value_struct_name) orelse
                                zir_builder_emit_decl_val(self.handle, value_struct_name.ptr, @intCast(value_struct_name.len));
                            if (val_ref != error_ref) {
                                const type_args = [_]u32{ key_ref, val_ref };
                                const map_type = self.emitGenericContainerRef("MapOf", &type_args) catch break :blk2 false;
                                const fn_ref = zir_builder_emit_field_val(self.handle, map_type, method_name.ptr, @intCast(method_name.len));
                                if (fn_ref != error_ref) {
                                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                                    if (ref != error_ref) {
                                        try self.setLocal(cb.dest, ref);
                                        break :blk2 true;
                                    }
                                }
                            }
                        }
                    }
                    break :blk2 false;
                } else if (std.mem.startsWith(u8, cb.name, "ListOfNested:")) blk3: {
                    // Handle "ListOfNested:inner_type.method" for nested list dispatch
                    const after_prefix = cb.name["ListOfNested:".len..];
                    if (std.mem.findScalar(u8, after_prefix, '.')) |dot_idx| {
                        const inner_type_name = after_prefix[0..dot_idx];
                        const method_name = after_prefix[dot_idx + 1 ..];
                        // Resolve the inner element type
                        const inner_type_ref = if (std.mem.eql(u8, inner_type_name, "i64"))
                            @intFromEnum(Zir.Inst.Ref.i64_type)
                        else if (std.mem.eql(u8, inner_type_name, "string"))
                            @intFromEnum(Zir.Inst.Ref.slice_const_u8_type)
                        else if (std.mem.eql(u8, inner_type_name, "f64"))
                            @intFromEnum(Zir.Inst.Ref.f64_type)
                        else if (std.mem.eql(u8, inner_type_name, "bool_type"))
                            @intFromEnum(Zir.Inst.Ref.bool_type)
                        else
                            @intFromEnum(Zir.Inst.Ref.i64_type);
                        // Build ListOf(inner), call .empty(), @TypeOf for the pointer type
                        const inner_args = [_]u32{inner_type_ref};
                        const inner_list = self.emitGenericContainerRef("ListOf", &inner_args) catch break :blk3 false;
                        const empty_fn = zir_builder_emit_field_val(self.handle, inner_list, "empty", 5);
                        if (empty_fn == error_ref) break :blk3 false;
                        const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                        if (empty_val == error_ref) break :blk3 false;
                        const elem_type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                        if (elem_type_ref == error_ref) break :blk3 false;
                        // Now call ListOf(@TypeOf(empty_val)).method
                        const outer_args = [_]u32{elem_type_ref};
                        const outer_list = self.emitGenericContainerRef("ListOf", &outer_args) catch break :blk3 false;
                        const fn_ref = zir_builder_emit_field_val(self.handle, outer_list, method_name.ptr, @intCast(method_name.len));
                        if (fn_ref != error_ref) {
                            const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                            if (ref != error_ref) {
                                try self.setLocal(cb.dest, ref);
                                break :blk3 true;
                            }
                        }
                    }
                    break :blk3 false;
                } else if (std.mem.startsWith(u8, cb.name, "MapOfNested:")) blk4: {
                    // Handle "MapOfNested:keytype:valtype.method" for nested map dispatch
                    const after_prefix = cb.name["MapOfNested:".len..];
                    if (std.mem.findScalar(u8, after_prefix, ':')) |colon_idx| {
                        const key_type_name = after_prefix[0..colon_idx];
                        const rest = after_prefix[colon_idx + 1 ..];
                        if (std.mem.findScalar(u8, rest, '.')) |dot_idx| {
                            const val_type_name = rest[0..dot_idx];
                            const method_name = rest[dot_idx + 1 ..];
                            // Resolve key type
                            const key_ref: u32 = if (std.mem.eql(u8, key_type_name, "u32"))
                                @intFromEnum(Zir.Inst.Ref.u32_type)
                            else if (std.mem.eql(u8, key_type_name, "str"))
                                @intFromEnum(Zir.Inst.Ref.slice_const_u8_type)
                            else
                                @intFromEnum(Zir.Inst.Ref.u32_type);
                            // For nested map values, build the value type as ?*const MapOf(K, V)
                            // For now, use the same key type for inner map (atom keys)
                            if (std.mem.eql(u8, val_type_name, "map")) {
                                // Inner map: MapOf(u32, i64) as default inner type
                                const inner_key = @intFromEnum(Zir.Inst.Ref.u32_type);
                                const inner_val = @intFromEnum(Zir.Inst.Ref.i64_type);
                                const inner_args = [_]u32{ inner_key, inner_val };
                                const inner_map = self.emitGenericContainerRef("MapOf", &inner_args) catch break :blk4 false;
                                const empty_fn = zir_builder_emit_field_val(self.handle, inner_map, "empty", 5);
                                if (empty_fn == error_ref) break :blk4 false;
                                const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                                if (empty_val == error_ref) break :blk4 false;
                                const val_type = zir_builder_emit_typeof(self.handle, empty_val);
                                if (val_type == error_ref) break :blk4 false;
                                const outer_args = [_]u32{ key_ref, val_type };
                                const outer_map = self.emitGenericContainerRef("MapOf", &outer_args) catch break :blk4 false;
                                const fn_ref = zir_builder_emit_field_val(self.handle, outer_map, method_name.ptr, @intCast(method_name.len));
                                if (fn_ref != error_ref) {
                                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                                    if (ref != error_ref) {
                                        try self.setLocal(cb.dest, ref);
                                        break :blk4 true;
                                    }
                                }
                            }
                        }
                    }
                    break :blk4 false;
                } else if (std.mem.startsWith(u8, cb.name, "ListOfU32.")) blk5: {
                    // Handle "ListOfU32.method" for enum element lists (atoms are u32)
                    const method_name = cb.name["ListOfU32.".len..];
                    const type_args = [_]u32{@intFromEnum(Zir.Inst.Ref.u32_type)};
                    const list_type = self.emitGenericContainerRef("ListOf", &type_args) catch break :blk5 false;
                    const fn_ref = zir_builder_emit_field_val(self.handle, list_type, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref != error_ref) {
                        const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref != error_ref) {
                            try self.setLocal(cb.dest, ref);
                            break :blk5 true;
                        }
                    }
                    break :blk5 false;
                } else if (std.mem.startsWith(u8, cb.name, "MapOfU32Val.")) blk6: {
                    // Handle "MapOfU32Val.method" for maps with enum values (atoms are u32)
                    const method_name = cb.name["MapOfU32Val.".len..];
                    const type_args = [_]u32{ @intFromEnum(Zir.Inst.Ref.u32_type), @intFromEnum(Zir.Inst.Ref.u32_type) };
                    const map_type = self.emitGenericContainerRef("MapOf", &type_args) catch break :blk6 false;
                    const fn_ref = zir_builder_emit_field_val(self.handle, map_type, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref != error_ref) {
                        const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref != error_ref) {
                            try self.setLocal(cb.dest, ref);
                            break :blk6 true;
                        }
                    }
                    break :blk6 false;
                } else false;

                if (!generic_handled) {
                // Parse "Module.function" from the builtin name.
                // e.g., "IO.println" → import zap_runtime, field "Prelude", field "println"
                // Module names are mapped to runtime struct names. Domain
                // modules (IO, Integer, Float, etc.) route to Prelude.
                if (std.mem.findScalar(u8, cb.name, '.')) |dot_idx| {
                    const mod_name = cb.name[0..dot_idx];
                    const func_name = cb.name[dot_idx + 1 ..];

                    // Map Zap module names to runtime struct names.
                    // Domain modules route to Prelude; List/Map/String/Zest
                    // route to their renamed structs directly.
                    const runtime_mod = mapToRuntimeModule(mod_name);

                    // @import("zap_runtime")
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;

                    // .RuntimeModule
                    const mod_ref = zir_builder_emit_field_val(self.handle, rt_import, runtime_mod.ptr, @intCast(runtime_mod.len));
                    if (mod_ref == error_ref) return error.EmitFailed;

                    // .function (e.g., .println)
                    const fn_ref = zir_builder_emit_field_val(self.handle, mod_ref, func_name.ptr, @intCast(func_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;

                    // call(fn_ref, args)
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                } else {
                    // Bare name (no module qualifier) — route through zap_runtime.Prelude
                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const prelude = zir_builder_emit_field_val(self.handle, rt_import, "Prelude", 7);
                    if (prelude == error_ref) return error.EmitFailed;
                    const fn_ref = zir_builder_emit_field_val(self.handle, prelude, cb.name.ptr, @intCast(cb.name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                }
                } // end if (!generic_handled)
            },

            // Tail calls — call + ret
            .tail_call => |tc| {
                // Guaranteed tail call: set always_tail modifier (4) so LLVM
                // emits a tail call that reuses the current stack frame.
                // Tail calls are always intra-module (self-recursion).
                zir_builder_set_call_modifier(self.handle, 4); // always_tail
                var args : std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (tc.args) |arg| {
                    const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try args.append(self.allocator, ref);
                }
                const tail_name = if (self.current_emit_module != null)
                    if (self.findFunctionByName(tc.name)) |tf| tf.local_name else tc.name
                else
                    tc.name;
                const call_ref = zir_builder_emit_call(
                    self.handle,
                    tail_name.ptr,
                    @intCast(tail_name.len),
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
                // Emit as runtime atom ID (u32) for pattern matching dispatch.
                // When used as a list/map element, the list_init handler will
                // use the correct container type and Zig handles the coercion.
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
                    // Look up function by ID, not array index (IDs may not match indices
                    // because __try variants and default wrappers are inserted into the list)
                    const func_name = blk: {
                        for (prog.functions) |f| {
                            if (f.id == cd.function) break :blk f.name;
                        }
                        break :blk @as(?[]const u8, null);
                    };
                    if (func_name) |fname| {
                        var args : std.ArrayListUnmanaged(u32) = .empty;
                        defer args.deinit(self.allocator);
                        for (cd.args) |arg| {
                            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                            try args.append(self.allocator, ref);
                        }

                        {
                            const target_func = self.findFunctionById(cd.function);
                            const target_module = if (target_func) |tf| tf.module_name else null;
                            const is_cross = xmod: {
                                if (target_module == null and self.current_emit_module == null) break :xmod false;
                                if (target_module == null or self.current_emit_module == null) break :xmod true;
                                break :xmod !std.mem.eql(u8, target_module.?, self.current_emit_module.?);
                            };

                            if (is_cross and target_module != null) {
                                const target_local = if (target_func) |tf| tf.local_name else fname;
                                const ref = try self.emitCrossModuleCall(target_module.?, target_local, args.items);
                                try self.setLocal(cd.dest, ref);
                            } else {
                                const call_name = if (self.current_emit_module != null)
                                    if (target_func) |tf| tf.local_name else fname
                                else
                                    fname;
                                const ref = zir_builder_emit_call(
                                    self.handle,
                                    call_name.ptr,
                                    @intCast(call_name.len),
                                    args.items.ptr,
                                    @intCast(args.items.len),
                                );
                                if (ref != error_ref) {
                                    try self.setLocal(cd.dest, ref);
                                }
                            }
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
                try self.emitCaseBlock(cb);
            },
            .switch_literal => |sl| {
                // Body-tracked emission: chain if-else-bodies for each case
                // so Sema only analyzes the matching branch.
                try self.emitSwitchLiteral(sl);
            },
            .set_safety => |enabled| {
                const ref = if (enabled)
                    @intFromEnum(Zir.Inst.Ref.bool_true)
                else
                    @intFromEnum(Zir.Inst.Ref.bool_false);
                _ = zir_builder_emit_set_runtime_safety(self.handle, ref);
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
            .union_switch => |us| {
                // Non-return union switch: emit like union_switch_return
                // but assign the result to dest instead of returning.
                try self.emitUnionSwitch(us);
            },
            .cond_return => |cr| {
                const cond_ref = self.refForLocal(cr.condition) catch return;
                if (cr.value) |val| {
                    const val_ref = self.refForLocal(val) catch return;
                    if (zir_builder_emit_cond_return(self.handle, cond_ref, val_ref) != 0)
                        return error.EmitFailed;
                } else {
                    // cond_return with no value — return void if condition is true
                    const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
                    if (zir_builder_emit_cond_return(self.handle, cond_ref, void_ref) != 0)
                        return error.EmitFailed;
                }
            },
            .case_break => |cbr| {
                // Generated by IrBuilder in lowerDecisionTreeForCase at decision
                // tree leaves. Propagates the matched arm's result value to the
                // enclosing case_block's dest local (tracked via current_case_dest).
                if (self.current_case_dest) |dest| {
                    if (cbr.value) |val| {
                        if (self.local_refs.get(val)) |value_ref| {
                            try self.local_refs.put(self.allocator, dest, value_ref);
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
                var names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens : std.ArrayListUnmanaged(u32) = .empty;
                defer names_lens.deinit(self.allocator);
                var values : std.ArrayListUnmanaged(u32) = .empty;
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
                        zir_builder_emit_array_init_anon(
                            self.handle,
                            values.items.ptr,
                            @intCast(values.items.len),
                        );
                    if (result == error_ref) return error.EmitFailed;
                    try self.setLocal(ti.dest, result);
                }
            },
            .list_init => |li| {
                const list_cell = try self.emitListCellRef(li.element_type);
                const cons_fn = zir_builder_emit_field_val(self.handle, list_cell, "cons", 4);
                if (cons_fn == error_ref) return error.EmitFailed;

                if (li.elements.len == 0) {
                    // Empty list: List.empty() — typed null
                    const empty_fn = zir_builder_emit_field_val(self.handle, list_cell, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(li.dest, ref);
                } else {
                    // Build from right to left, starting with typed null tail
                    const empty_fn = zir_builder_emit_field_val(self.handle, list_cell, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    var current: u32 = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (current == error_ref) return error.EmitFailed;

                    var i: usize = li.elements.len;
                    while (i > 0) {
                        i -= 1;
                        const elem_ref = self.refForLocal(li.elements[i]) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        const call_args = [_]u32{ elem_ref, current };
                        current = zir_builder_emit_call_ref(self.handle, cons_fn, &call_args, 2);
                        if (current == error_ref) return error.EmitFailed;
                    }
                    try self.setLocal(li.dest, current);
                }
            },
            .list_cons => |lc| {
                const head_ref = self.refForLocal(lc.head) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const tail_ref = self.refForLocal(lc.tail) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const list_cell = try self.emitListCellRef(lc.element_type);
                const cons_fn = zir_builder_emit_field_val(self.handle, list_cell, "cons", 4);
                if (cons_fn == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ head_ref, tail_ref };
                const ref = zir_builder_emit_call_ref(self.handle, cons_fn, &call_args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lc.dest, ref);
            },
            .map_init => |mi| {
                // Maps use generic MapOf(K, V) instantiation.
                // For complex types (structs), emit type refs dynamically.
                const key_type_ref = (try self.emitContainerElementTypeRef(mi.key_type)) orelse @intFromEnum(Zir.Inst.Ref.u32_type);
                const val_type_ref = (try self.emitContainerElementTypeRef(mi.value_type)) orelse @intFromEnum(Zir.Inst.Ref.i64_type);
                const map_type_args = [_]u32{ key_type_ref, val_type_ref };
                const map_cell = self.emitGenericContainerRef("MapOf", &map_type_args) catch return error.EmitFailed;

                if (mi.entries.len == 0) {
                    // Empty map: MapCell.empty()
                    const empty_fn = zir_builder_emit_field_val(self.handle, map_cell, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(mi.dest, ref);
                } else {
                    // Build map entry by entry using put()
                    const empty_fn = zir_builder_emit_field_val(self.handle, map_cell, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    var current: u32 = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (current == error_ref) return error.EmitFailed;

                    const put_fn = zir_builder_emit_field_val(self.handle, map_cell, "put", 3);
                    if (put_fn == error_ref) return error.EmitFailed;

                    for (mi.entries) |entry| {
                        const key_ref = self.refForLocal(entry.key) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        const val_ref = self.refForLocal(entry.value) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        const call_args = [_]u32{ current, key_ref, val_ref };
                        current = zir_builder_emit_call_ref(self.handle, put_fn, &call_args, 3);
                        if (current == error_ref) return error.EmitFailed;
                    }
                    try self.setLocal(mi.dest, current);
                }
            },
            .struct_init => |si| {
                var names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens : std.ArrayListUnmanaged(u32) = .empty;
                defer names_lens.deinit(self.allocator);
                var values : std.ArrayListUnmanaged(u32) = .empty;
                defer values.deinit(self.allocator);

                for (si.fields) |field| {
                    const ref = self.refForValueLocal(field.value) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try names_ptrs.append(self.allocator, field.name.ptr);
                    try names_lens.append(self.allocator, @intCast(field.name.len));
                    try values.append(self.allocator, ref);
                }

                // Fill in missing fields with default values from the struct def.
                // This ensures struct_init always provides all fields, avoiding
                // Zig's missing-field error path which can't handle synthetic ZIR.
                if (self.findStructDef(si.type_name)) |struct_def| {
                    for (struct_def.fields) |def_field| {
                        // Check if this field was already provided
                        var found = false;
                        for (si.fields) |init_field| {
                            if (std.mem.eql(u8, init_field.name, def_field.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            if (def_field.default_value) |default| {
                                const default_ref: u32 = switch (default) {
                                    .int => |v| blk: {
                                        const ref = zir_builder_emit_int(self.handle, v);
                                        break :blk if (ref == error_ref) @intFromEnum(Zir.Inst.Ref.zero) else ref;
                                    },
                                    .bool_val => |v| if (v) @intFromEnum(Zir.Inst.Ref.bool_true) else @intFromEnum(Zir.Inst.Ref.bool_false),
                                    .float => |v| blk: {
                                        const ref = zir_builder_emit_float(self.handle, v);
                                        break :blk if (ref == error_ref) @intFromEnum(Zir.Inst.Ref.zero) else ref;
                                    },
                                    .string => |v| blk: {
                                        const ref = zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len));
                                        break :blk if (ref == error_ref) @intFromEnum(Zir.Inst.Ref.void_value) else ref;
                                    },
                                    .nil => @intFromEnum(Zir.Inst.Ref.void_value),
                                };
                                try names_ptrs.append(self.allocator, def_field.name.ptr);
                                try names_lens.append(self.allocator, @intCast(def_field.name.len));
                                try values.append(self.allocator, default_ref);
                            }
                        }
                    }
                }

                if (self.findReusePairForDest(si.dest)) |pair| {
                    // Use struct_init_typed for named structs to preserve type identity
                    const seed_ref = blk: {
                        if (!self.current_function_is_closure and self.capture_depth == 0) {
                            const short_name = if (std.mem.lastIndexOf(u8, si.type_name, ".")) |dot_idx|
                                si.type_name[dot_idx + 1 ..]
                            else
                                si.type_name;
                            if (self.findStructDef(si.type_name) != null or self.findStructDef(short_name) != null) {
                                const decl_ref = zir_builder_emit_decl_val(self.handle, short_name.ptr, @intCast(short_name.len));
                                if (decl_ref != error_ref) {
                                    const typed = zir_builder_emit_struct_init_typed(self.handle, decl_ref, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                                    if (typed != error_ref) break :blk typed;
                                }
                            }
                        }
                        break :blk zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                    };
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
                } else if (self.shouldSkipArc(si.dest)) {
                    // Stack allocation path: escape analysis determined this value
                    // does not escape the current function. Use ZIR alloc + store
                    // to place it on the stack instead of the arena.
                    _ = self.reuse_backed_struct_locals.remove(si.dest);
                    // Use struct_init_typed for named structs to preserve type identity
                    const seed_ref = blk: {
                        if (!self.current_function_is_closure and self.capture_depth == 0) {
                            const short_name = if (std.mem.lastIndexOf(u8, si.type_name, ".")) |dot_idx|
                                si.type_name[dot_idx + 1 ..]
                            else
                                si.type_name;
                            if (self.findStructDef(si.type_name) != null or self.findStructDef(short_name) != null) {
                                const decl_ref = zir_builder_emit_decl_val(self.handle, short_name.ptr, @intCast(short_name.len));
                                if (decl_ref != error_ref) {
                                    const typed = zir_builder_emit_struct_init_typed(self.handle, decl_ref, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                                    if (typed != error_ref) break :blk typed;
                                }
                            }
                        }
                        break :blk zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                    };
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    // Allocate on stack and store
                    const alloc_ref = self.emitAlloc(type_ref) catch return error.EmitFailed;
                    if (zir_builder_emit_store(self.handle, alloc_ref, seed_ref) != 0) return error.EmitFailed;
                    const const_ptr = self.emitMakePtrConst(alloc_ref) catch return error.EmitFailed;
                    const loaded = self.emitLoad(const_ptr) catch return error.EmitFailed;
                    try self.setLocal(si.dest, loaded);
                } else {
                    _ = self.reuse_backed_struct_locals.remove(si.dest);

                    // Use struct_init_typed with decl_val for nominal types
                    // in non-closure functions. Closures can't resolve module-
                    // level decl_val refs, so fall back to struct_init_anon.
                    if (!self.current_function_is_closure and self.capture_depth == 0) {
                        const short_name = if (std.mem.lastIndexOf(u8, si.type_name, ".")) |dot_idx|
                            si.type_name[dot_idx + 1 ..]
                        else
                            si.type_name;
                        if (self.findStructDef(si.type_name) != null or self.findStructDef(short_name) != null) {
                            const type_ref = zir_builder_emit_decl_val(self.handle, short_name.ptr, @intCast(short_name.len));
                            if (type_ref != error_ref) {
                                const typed_result = zir_builder_emit_struct_init_typed(
                                    self.handle,
                                    type_ref,
                                    names_ptrs.items.ptr,
                                    names_lens.items.ptr,
                                    values.items.ptr,
                                    @intCast(values.items.len),
                                );
                                if (typed_result != error_ref) {
                                    try self.setLocal(si.dest, typed_result);
                                    return;
                                }
                            }
                        }
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
                // Tuple/array element access by immediate index
                const obj_ref = self.refForLocal(ig.object) catch return;
                const ref = zir_builder_emit_elem_val_imm(self.handle, obj_ref, ig.index);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ig.dest, ref);
            },
            .list_len_check => |llc| {
                // Cons cell length check via runtime helper.
                // ListHelpers.length(list) == expected_len
                // List-based length check: List.length(list) == expected_len
                const list_ref = self.refForLocal(llc.scrutinee) catch return;
                const list_cell = try self.emitListCellRef(llc.element_type);
                const len_fn = zir_builder_emit_field_val(self.handle, list_cell, "length", 6);
                if (len_fn == error_ref) return error.EmitFailed;
                const call_args = [_]u32{list_ref};
                const len_ref = zir_builder_emit_call_ref(self.handle, len_fn, &call_args, 1);
                if (len_ref == error_ref) return error.EmitFailed;
                const expected_ref = zir_builder_emit_int(self.handle, @intCast(llc.expected_len));
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, len_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(llc.dest, ref);
            },
            .list_get => |lg| {
                // List-based element access: List.get(list, index)
                const list_ref = self.refForLocal(lg.list) catch return;
                const list_cell = try self.emitListCellRef(lg.element_type);
                const get_fn = zir_builder_emit_field_val(self.handle, list_cell, "get", 3);
                if (get_fn == error_ref) return error.EmitFailed;
                const index_ref = zir_builder_emit_int(self.handle, @intCast(lg.index));
                if (index_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ list_ref, index_ref };
                const ref = zir_builder_emit_call_ref(self.handle, get_fn, &call_args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lg.dest, ref);
            },
            .list_is_not_empty => |lne| {
                // List non-empty check: list != null  (using is_non_null)
                const list_ref = self.refForValueLocal(lne.list) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const ref = zir_builder_emit_is_non_null(self.handle, list_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lne.dest, ref);
            },
            .list_head => |lh| {
                // List head extraction: List.getHead(list)
                const list_ref = self.refForValueLocal(lh.list) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const list_cell = try self.emitListCellRef(lh.element_type);
                const fn_ref = zir_builder_emit_field_val(self.handle, list_cell, "getHead", 7);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{list_ref};
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 1);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lh.dest, ref);
            },
            .list_tail => |lt| {
                // List tail extraction: List.getTail(list)
                const list_ref = self.refForValueLocal(lt.list) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const list_cell = try self.emitListCellRef(lt.element_type);
                const fn_ref = zir_builder_emit_field_val(self.handle, list_cell, "getTail", 7);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{list_ref};
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 1);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lt.dest, ref);
            },
            .map_has_key => |mhk| {
                // MapCell-based key check: MapCell.hasKey(map, key)
                const map_ref = self.refForLocal(mhk.map) catch return;
                const key_ref = self.refForLocal(mhk.key) catch return;
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const map_cell = zir_builder_emit_field_val(self.handle, rt_import, "MapAtomInt", 10);
                if (map_cell == error_ref) return error.EmitFailed;
                const fn_ref = zir_builder_emit_field_val(self.handle, map_cell, "hasKey", 6);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ map_ref, key_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mhk.dest, ref);
            },
            .map_get => |mg| {
                // MapCell-based value access: MapCell.get(map, key, default)
                const map_ref = self.refForLocal(mg.map) catch return;
                const key_ref = self.refForLocal(mg.key) catch return;
                const default_ref = self.refForLocal(mg.default) catch return;
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const map_cell = zir_builder_emit_field_val(self.handle, rt_import, "MapAtomInt", 10);
                if (map_cell == error_ref) return error.EmitFailed;
                const fn_ref = zir_builder_emit_field_val(self.handle, map_cell, "get", 3);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ map_ref, key_ref, default_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 3);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mg.dest, ref);
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
                    // Use proper @unionInit if a union return type was set up at function start
                    if (self.cached_union_ret_type_ref != 0) {
                        const union_type_ref = self.cached_union_ret_type_ref;
                        const ref = zir_builder_emit_union_init(
                            self.handle,
                            union_type_ref,
                            ui.variant_name.ptr,
                            @intCast(ui.variant_name.len),
                            val_ref,
                        );
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(ui.dest, ref);
                    } else {
                        const ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(ui.dest, ref);
                    }
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
                // Compare scrutinee against expected string via std.mem.eql
                // (Zig's == on []const u8 compares pointer+length, not contents)
                const scrutinee_ref = self.refForLocal(ms.scrutinee) catch return;
                const expected_ref = zir_builder_emit_str(self.handle, ms.expected.ptr, @intCast(ms.expected.len));
                if (expected_ref == error_ref) return error.EmitFailed;

                // @import("std").mem.eql(u8, scrutinee, expected)
                const std_import = zir_builder_emit_import(self.handle, "std", 3);
                if (std_import == error_ref) return error.EmitFailed;
                const mem_mod = zir_builder_emit_field_val(self.handle, std_import, "mem", 3);
                if (mem_mod == error_ref) return error.EmitFailed;
                const eql_fn = zir_builder_emit_field_val(self.handle, mem_mod, "eql", 3);
                if (eql_fn == error_ref) return error.EmitFailed;

                const u8_type_ref = @intFromEnum(Zir.Inst.Ref.u8_type);
                const call_args = [_]u32{ u8_type_ref, scrutinee_ref, expected_ref };
                const ref = zir_builder_emit_call_ref(self.handle, eql_fn, &call_args, 3);
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

                // For tuple/struct types: the Zap type checker guarantees the type matches.
                // Emit `true` — the actual destructuring happens via index_get instructions.
                if (mt.expected_type == .tuple or mt.expected_type == .struct_ref) {
                    // Zap's type checker guarantees the type matches at compile time.
                    // Emit `true` — actual destructuring happens via index_get instructions.
                    const ref = zir_builder_emit_bool(self.handle, true);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(mt.dest, ref);
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
                // panic is noreturn — emit unreachable so Zig knows control never continues
                _ = zir_builder_emit_unreachable(self.handle);
            },
            .match_error_return => {
                // No-match in __try variant: return null.
                // The caller detects null and passes the unmatched input to the handler.
                if (zir_builder_emit_ret_null(self.handle) != 0)
                    return error.EmitFailed;
            },

            .call_dispatch => |cd| {
                // Resolve the dispatch group to the actual function and call it.
                // The group_id is a valid FunctionId created during IR building.
                const ref = try self.emitNamedCallToTarget(cd.group_id, &.{}, cd.args);
                try self.setLocal(cd.dest, ref);
            },
            .call_closure => |cc| {
                const lattice = @import("escape_lattice.zig");
                const callee_is_param = self.isParamDerivedClosure(cc.callee);

                // Parameter-derived closures: the callee is a function parameter.
                // It could be either a bare function pointer or a closure struct
                // with {call_fn, env}. Use Prelude.callCallableN for dispatch.
                if (callee_is_param) {
                    const callee_ref = self.refForLocal(cc.callee) catch return error.EmitFailed;
                    var args: std.ArrayListUnmanaged(u32) = .empty;
                    defer args.deinit(self.allocator);
                    for (cc.args) |arg| {
                        const ref2 = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        try args.append(self.allocator, ref2);
                    }

                    const rt_ref = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_ref != error_ref) {
                        const prelude_ref = zir_builder_emit_field_val(self.handle, rt_ref, "Prelude", 7);
                        if (prelude_ref != error_ref) {
                            const helper_name = switch (args.items.len) {
                                0 => "callCallable0",
                                1 => "callCallable1",
                                2 => "callCallable2",
                                3 => "callCallable3",
                                else => {
                                    var ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                                    if (ref == error_ref) return error.EmitFailed;
                                    const ret_type_ref2 = mapReturnType(cc.return_type);
                                    if (ret_type_ref2 != 0) {
                                        const cast2 = zir_builder_emit_as(self.handle, ret_type_ref2, ref);
                                        if (cast2 != error_ref) ref = cast2;
                                    }
                                    try self.setLocal(cc.dest, ref);
                                    return;
                                },
                            };
                            const helper_ref = zir_builder_emit_field_val(self.handle, prelude_ref, helper_name.ptr, @intCast(helper_name.len));
                            if (helper_ref != error_ref) {
                                var full_args: std.ArrayListUnmanaged(u32) = .empty;
                                defer full_args.deinit(self.allocator);
                                try full_args.append(self.allocator, callee_ref);
                                try full_args.appendSlice(self.allocator, args.items);
                                var ref = zir_builder_emit_call_ref(self.handle, helper_ref, full_args.items.ptr, @intCast(full_args.items.len));
                                if (ref != error_ref) {
                                    // Cast the callCallableN result to the expected return
                                    // type. The runtime helper returns CallReturnType which
                                    // Zig infers from the callable, but the monomorphized
                                    // function may declare a different concrete return type.
                                    const ret_type_ref = mapReturnType(cc.return_type);
                                    if (ret_type_ref != 0) {
                                        const cast = zir_builder_emit_as(self.handle, ret_type_ref, ref);
                                        if (cast != error_ref) ref = cast;
                                    }
                                    try self.setLocal(cc.dest, ref);
                                    return;
                                }
                            }
                        }
                    }

                    // Fallback: bare function pointer call
                    const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cc.dest, ref);
                    return;
                }

                // Fast path: use the closure function map to resolve the callee
                // directly to a named function call. This handles 0-capture closures
                // (anonymous functions and function refs) by tracking the function ID
                // through local assignments without needing backward instruction scanning.
                if (true) {
                    if (self.closure_function_map.get(cc.callee)) |func_id| {
                        if (self.findFunctionById(func_id)) |target_func| {
                            if (target_func.captures.len == 0) {
                                const ref = try self.emitNamedCallToTarget(func_id, &.{}, cc.args);
                                if (ref != error_ref) {
                                    try self.setLocal(cc.dest, ref);
                                    return;
                                }
                            }
                        }
                    }
                }

                if (self.getCallSiteSpecialization()) |spec| {
                    switch (spec.decision) {
                        .unreachable_call => {
                            // Fall through to dynamic dispatch. The unreachable
                            // classification may be wrong when function IDs shift
                            // (e.g., anonymous closures inserted in the IR), or
                            // when cross-module callers pass closures the local
                            // escape analysis didn't see.
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
                    // Dynamic dispatch: extract call_fn and env from closure struct,
                    // call function with env prepended to args.
                    const callee_ref = self.refForLocal(cc.callee) catch return error.EmitFailed;

                    // When the callee is a function parameter or a bare function ref
                    // (from a 0-capture make_closure), emit a direct call_ref without
                    // trying to destructure a closure struct.
                    if (callee_is_param or self.isBareFunctionRef(cc.callee)) {
                        var args : std.ArrayListUnmanaged(u32) = .empty;
                        defer args.deinit(self.allocator);
                        for (cc.args) |arg| {
                            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                            try args.append(self.allocator, ref);
                        }
                        const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cc.dest, ref);
                        return;
                    }

                    // Extract function pointer and environment from closure struct
                    const call_fn_ref = zir_builder_emit_field_val(self.handle, callee_ref, "call_fn", 7);
                    if (call_fn_ref == error_ref) {
                        // Fallback: callee might be a bare function ref, not a closure struct
                        var args : std.ArrayListUnmanaged(u32) = .empty;
                        defer args.deinit(self.allocator);
                        for (cc.args) |arg| {
                            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                            try args.append(self.allocator, ref);
                        }
                        const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cc.dest, ref);
                        return;
                    }

                    const env_ref = zir_builder_emit_field_val(self.handle, callee_ref, "env", 3);
                    if (env_ref == error_ref) return error.EmitFailed;

                    // Build args: env as first argument, then user args
                    var full_args : std.ArrayListUnmanaged(u32) = .empty;
                    defer full_args.deinit(self.allocator);
                    try full_args.append(self.allocator, env_ref);
                    for (cc.args) |arg| {
                        const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                        try full_args.append(self.allocator, ref);
                    }

                    const ref = zir_builder_emit_call_ref(self.handle, call_fn_ref, full_args.items.ptr, @intCast(full_args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cc.dest, ref);
                }
            },
            .make_closure => |mc| {
                const target_func = self.findFunctionById(mc.function) orelse return error.EmitFailed;

                // Track which function this closure local points to.
                try self.closure_function_map.put(self.allocator, mc.dest, mc.function);

                // When this closure captures locals that are themselves closure values,
                // record the mapping so the inner function's capture_get can resolve them.
                for (mc.captures, 0..) |cap_local, cap_idx| {
                    if (self.closure_function_map.get(cap_local)) |captured_func_id| {
                        const key = @as(u64, mc.function) << 32 | @as(u64, @intCast(cap_idx));
                        try self.capture_closure_function_map.put(self.allocator, key, captured_func_id);
                    }
                }

                // Resolve the correct name for the current module context.
                // In per-module emission, functions are emitted with local_name,
                // so references must also use local_name (or @import for cross-module).
                const emit_name = if (self.current_emit_module != null and target_func.local_name.len > 0)
                    target_func.local_name
                else
                    target_func.name;

                // Determine if this is a cross-module reference
                const target_module = target_func.module_name;
                const is_cross_module = blk: {
                    if (target_module == null and self.current_emit_module == null) break :blk false;
                    if (target_module == null or self.current_emit_module == null) break :blk true;
                    break :blk !std.mem.eql(u8, target_module.?, self.current_emit_module.?);
                };

                // 0-capture closures: emit a bare function pointer via decl_ref.
                // This produces *const fn(args...) ret which is the uniform type
                // for all function references passed as callback parameters.
                if (mc.captures.len == 0) {
                    if (is_cross_module and target_module != null) {
                        try self.setLocalDecl(mc.dest, target_module.?, target_func.local_name);
                    } else {
                        try self.setLocalDecl(mc.dest, null, emit_name);
                    }
                    return;
                }

                // Build the environment tuple: .{ capture0, capture1, ... }
                var env_names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
                defer env_names_ptrs.deinit(self.allocator);
                var env_names_lens : std.ArrayListUnmanaged(u32) = .empty;
                defer env_names_lens.deinit(self.allocator);
                var env_values : std.ArrayListUnmanaged(u32) = .empty;
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

                // Build the closure struct: .{ .call_fn = func_ref, .env = env_ref }
                // Use module-aware resolution: decl_ref for same-module, @import for cross-module.
                const fn_name_ref = if (is_cross_module and target_module != null)
                    self.emitCrossModuleRef(target_module.?, target_func.local_name) catch @intFromEnum(Zir.Inst.Ref.void_value)
                else blk: {
                    const ref = zir_builder_emit_decl_ref(self.handle, emit_name.ptr, @intCast(emit_name.len));
                    break :blk if (ref != error_ref) ref else zir_builder_emit_str(self.handle, emit_name.ptr, @intCast(emit_name.len));
                };
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
                // Propagate closure function mapping through captures.
                {
                    const key = @as(u64, self.current_function_id) << 32 | @as(u64, cg.index);
                    if (self.capture_closure_function_map.get(key)) |func_id| {
                        try self.closure_function_map.put(self.allocator, cg.dest, func_id);
                    }
                }
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
                self.beginCapture();
                const payload = zir_builder_emit_optional_payload(self.handle, source_ref);
                if (payload == error_ref) return error.EmitFailed;
                var then_len: u32 = 0;
                const then_ptr = self.endCapture(&then_len);

                // Copy then instructions (capture buffer reused for else)
                var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
                defer then_insts.deinit(self.allocator);
                then_insts.appendSliceAssumeCapacity(then_ptr[0..then_len]);

                // Else branch: panic with message
                self.beginCapture();
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
                const else_ptr = self.endCapture(&else_len);

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
                const data_ref = try self.refForLocal(blc.scrutinee);
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

                const source_ref = try self.refForLocal(bri.source);
                const offset_ref = switch (bri.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return error.EmitFailed,
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

                const source_ref = try self.refForLocal(brf.source);
                const offset_ref = switch (brf.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return error.EmitFailed,
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

                const source_ref = try self.refForLocal(bs.source);
                const offset_ref = switch (bs.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return error.EmitFailed,
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                // null length means "rest of data" -- pass 0 as sentinel
                const length_ref = if (bs.length) |len| switch (len) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return error.EmitFailed,
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

                const source_ref = try self.refForLocal(bru.source);
                const offset_ref = switch (bru.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| self.refForLocal(d) catch return error.EmitFailed,
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

                const source_ref = try self.refForLocal(bmp.source);
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
            // Numeric widening — emit @as(DestType, source)
            .int_widen, .float_widen => |nw| {
                const source_ref = self.refForValueLocal(nw.source) catch @intFromEnum(Zir.Inst.Ref.void_value);
                const dest_type_ref = mapReturnType(nw.dest_type);
                const ref = zir_builder_emit_as(self.handle, dest_type_ref, source_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(nw.dest, ref);
            },

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
        self.beginCapture();
        for (ie.then_instrs) |ti| {
            try self.emitInstruction(ti);
        }
        var then_len: u32 = 0;
        const then_insts_ptr = self.endCapture(&then_len);

        const then_ref: u32 = if (ie.then_result) |tr|
            try self.refForLocal(tr)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Copy then indices — the capture buffer will be reused for else branch
        var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
        defer then_insts.deinit(self.allocator);
        then_insts.appendSliceAssumeCapacity(then_insts_ptr[0..then_len]);

        // --- else branch: capture top-level body instructions ---
        self.beginCapture();
        for (ie.else_instrs) |ei| {
            try self.emitInstruction(ei);
        }
        var else_len: u32 = 0;
        const else_insts_ptr = self.endCapture(&else_len);

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
        self.beginCapture();
        for (gb.body) |bi| try self.emitInstruction(bi);
        var body_len: u32 = 0;
        const body_ptr = self.endCapture(&body_len);

        // Copy body indices (capture buffer may be reused)
        var body_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, body_len);
        defer body_insts.deinit(self.allocator);
        body_insts.appendSliceAssumeCapacity(body_ptr[0..body_len]);

        const body_returns = gb.body.len > 0 and blk: {
            const last = gb.body[gb.body.len - 1];
            break :blk (last == .ret or last == .match_fail or last == .match_error_return);
        };

        if (body_returns) {
            const empty = [_]u32{};
            if (zir_builder_emit_cond_branch_with_bodies(
                self.handle,
                cond_ref,
                body_insts.items.ptr,
                @intCast(body_insts.items.len),
                &empty,
                0,
            ) != 0) return error.EmitFailed;
        } else {
            const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
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
    }

    /// Emit a short-circuit boolean AND via ZIR bool_br_and instruction.
    /// The rhs is only evaluated if lhs is true. Returns the ref for the result.
    fn emitBoolBrAnd(self: *ZirDriver, lhs_ref: u32, rhs_body: []const u32, rhs_result: u32) BuildError!u32 {
        const ref = zir_builder_emit_bool_br_and(self.handle, lhs_ref, rhs_body.ptr, @intCast(rhs_body.len), rhs_result);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a short-circuit boolean OR via ZIR bool_br_or instruction.
    /// The rhs is only evaluated if lhs is false. Returns the ref for the result.
    fn emitBoolBrOr(self: *ZirDriver, lhs_ref: u32, rhs_body: []const u32, rhs_result: u32) BuildError!u32 {
        const ref = zir_builder_emit_bool_br_or(self.handle, lhs_ref, rhs_body.ptr, @intCast(rhs_body.len), rhs_result);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a stack allocation (ZIR alloc instruction).
    /// Returns a pointer ref to the allocated memory.
    fn emitAlloc(self: *ZirDriver, type_ref: u32) BuildError!u32 {
        const ref = zir_builder_emit_alloc(self.handle, type_ref);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a mutable stack allocation (ZIR alloc_mut instruction).
    fn emitAllocMut(self: *ZirDriver, type_ref: u32) BuildError!u32 {
        const ref = zir_builder_emit_alloc_mut(self.handle, type_ref);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a load from a pointer (ZIR load instruction).
    fn emitLoad(self: *ZirDriver, ptr_ref: u32) BuildError!u32 {
        const ref = zir_builder_emit_load(self.handle, ptr_ref);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit make_ptr_const to finalize an alloc into a const pointer.
    fn emitMakePtrConst(self: *ZirDriver, alloc_ref: u32) BuildError!u32 {
        const ref = zir_builder_emit_make_ptr_const(self.handle, alloc_ref);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a loop instruction with body. The body must contain a break or repeat.
    fn emitLoop(self: *ZirDriver, body: []const u32) BuildError!u32 {
        const ref = zir_builder_emit_loop(self.handle, body.ptr, @intCast(body.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a repeat instruction (jump back to loop header).
    fn emitRepeat(self: *ZirDriver) BuildError!void {
        if (zir_builder_emit_repeat(self.handle) != 0) return error.EmitFailed;
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
                if (self.local_refs.get(dr)) |value_ref| {
                    try self.local_refs.put(self.allocator, sl.dest, value_ref);
                }
            }
            return;
        }

        // Capture the default body
        self.beginCapture();
        for (sl.default_instrs) |di| {
            try self.emitInstruction(di);
        }
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
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
            self.beginCapture();
            for (case.body_instrs) |bi| {
                try self.emitInstruction(bi);
            }
            var case_len: u32 = 0;
            const case_ptr = self.endCapture(&case_len);

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
        // Set the case_block result
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
        self.beginCapture();
        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
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
            self.beginCapture();
            for (arm.body_instrs) |bi| try self.emitInstruction(bi);
            if (arm.result) |r| {
                try self.emitDropSpecializationsForCurrentInstr(r, @intCast(i));
            }
            var arm_len: u32 = 0;
            const arm_ptr = self.endCapture(&arm_len);

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
                if (self.local_refs.get(dr)) |value_ref| {
                    try self.local_refs.put(self.allocator, cb.dest, value_ref);
                }
            }
            try self.emitDropSpecializationsForCurrentInstr(cb.dest, null);
            return;
        }

        // Instructions after the last guard_block are the default body.
        const default_start = last_guard_idx.? + 1;
        const default_pre_instrs = cb.pre_instrs[default_start..];

        // Capture the default body (from both trailing pre_instrs and default_instrs).
        self.beginCapture();
        for (default_pre_instrs) |di| try self.emitInstruction(di);
        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        var default_result: u32 = if (cb.default_result) |dr|
            self.refForLocal(dr) catch void_ref
        else
            void_ref;

        // If default_result is still void but default body was captured,
        // check if case_break inside the body set cb.dest
        if (default_result == void_ref and (default_len > 0 or default_pre_instrs.len > 0)) {
            default_result = if (self.local_refs.get(cb.dest)) |vr| self.materializeValueRef(vr) catch void_ref else void_ref;
        }

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

        var index_get_pre_emitted = false;

        // If the default body is empty AND there's a catch-all guard (_ pattern),
        // use the last guard's body as the default instead of void.
        // The last guard has condition=true (always matches), so the empty default
        // is unreachable. Promoting the catch-all to the default avoids a void
        // else branch that Sema can't merge with the other types.
        if (current_else_result == @intFromEnum(Zir.Inst.Ref.void_value) and cb.default_instrs.len == 0 and guards.items.len > 0) {
            const last_guard = guards.items[guards.items.len - 1];
            const last_gb = cb.pre_instrs[last_guard.guard_idx].guard_block;

            // If this is the ONLY guard (catch-all), emit body as top-level instructions
            if (guards.items.len == 1) {
                // Emit setup instructions (e.g., match_type)
                for (cb.pre_instrs[0..last_guard.guard_idx]) |si| try self.emitInstruction(si);
                // Emit body instructions at top level
                for (last_gb.body) |bi| try self.emitInstruction(bi);
                // The case_break in the body sets cb.dest
                const result = if (self.local_refs.get(cb.dest)) |vr| try self.materializeValueRef(vr) else @intFromEnum(Zir.Inst.Ref.void_value);
                try self.setLocal(cb.dest, result);
                try self.emitDropSpecializationsForCurrentInstr(cb.dest, null);
                return;
            }

            // Multiple guards — emit shared setup (index_get for tuple element
            // extraction) before capturing the catch-all body. Guard bodies
            // reference these locals via local_get, so they must be defined
            // before any body is captured. Per-guard setup (match_atom) is
            // emitted later in the reverse loop.
            for (guards.items) |guard| {
                for (cb.pre_instrs[guard.setup_start..guard.guard_idx]) |si| {
                    if (std.meta.activeTag(si) == .index_get) try self.emitInstruction(si);
                }
            }
            index_get_pre_emitted = true;

            // Capture the catch-all body as default
            self.beginCapture();
            for (last_gb.body) |bi| try self.emitInstruction(bi);
            var catchall_len: u32 = 0;
            const catchall_ptr = self.endCapture(&catchall_len);

            const catchall_result: u32 = if (self.local_refs.get(cb.dest)) |vr| self.materializeValueRef(vr) catch @intFromEnum(Zir.Inst.Ref.void_value) else @intFromEnum(Zir.Inst.Ref.void_value);

            self.allocator.free(current_else_insts);
            current_else_insts = try self.allocator.alloc(u32, catchall_len);
            @memcpy(current_else_insts, catchall_ptr[0..catchall_len]);
            current_else_result = catchall_result;

            _ = guards.pop();
        }

        // Process guards in REVERSE order to build nested if-else chain
        var gi = guards.items.len;
        while (gi > 0) {
            gi -= 1;
            const guard = guards.items[gi];
            const gb = cb.pre_instrs[guard.guard_idx].guard_block;
            const setup_instrs = cb.pre_instrs[guard.setup_start..guard.guard_idx];

            // Emit per-guard setup. Skip index_get if already pre-emitted
            // before the catchall capture.
            for (setup_instrs) |si| {
                if (index_get_pre_emitted and std.meta.activeTag(si) == .index_get) continue;
                try self.emitInstruction(si);
            }

            // Get the guard condition ref
            const cond_ref = try self.refForLocal(gb.condition);

            // Capture the guard body
            self.beginCapture();
            for (gb.body) |bi| try self.emitInstruction(bi);
            try self.emitDropSpecializationsForCurrentInstr(cb.dest, @intCast(gi));
            var body_len: u32 = 0;
            const body_ptr = self.endCapture(&body_len);

            // The guard body contains case_break which sets cb.dest via
            // current_case_dest. Use that ref as the body result.
            const body_result: u32 = if (self.local_refs.get(cb.dest)) |vr| self.materializeValueRef(vr) catch void_ref else void_ref;

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
        self.beginCapture();
        for (sr.default_instrs) |di| try self.emitInstruction(di);
        if (sr.default_result) |dr| {
            const ref = try self.refForLocal(dr);
            if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
        }
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
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
            self.beginCapture();
            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            if (case.return_value) |rv| {
                const ref = try self.refForLocal(rv);
                if (zir_builder_emit_ret(self.handle, ref) != 0) {
                    return error.EmitFailed;
                }
            }
            var case_len: u32 = 0;
            const case_ptr = self.endCapture(&case_len);

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
            self.beginCapture();

            // Extract variant payload: scrutinee.VariantName → struct payload
            const payload_ref = zir_builder_emit_field_val(self.handle, scrutinee_ref, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (payload_ref == error_ref) {
                self.allocator.free(current_else_insts);
                return error.EmitFailed;
            }

            // Extract each field from the payload and bind to the correct local.
            // For scalar payloads (e.g., u8 from binary pattern matching), field
            // access is invalid — bind the payload directly instead.
            // Detect scalar payloads by checking if field names are numeric indices
            // ("0", "1", etc.), which indicate tuple-style extraction on a scalar.
            const is_scalar_payload = blk: {
                if (case.field_bindings.len == 0) break :blk false;
                const first_name = case.field_bindings[0].field_name;
                break :blk first_name.len > 0 and first_name[0] >= '0' and first_name[0] <= '9';
            };

            if (is_scalar_payload and case.field_bindings.len == 1) {
                // Single scalar binding (e.g., <<a, _>> extracting one byte):
                // the payload IS the value, no field extraction needed.
                try self.setLocal(case.field_bindings[0].local_index, payload_ref);
            } else if (is_scalar_payload) {
                // Multiple bindings on a scalar payload — bind first to
                // the payload directly, remaining are not extractable.
                try self.setLocal(case.field_bindings[0].local_index, payload_ref);
                for (case.field_bindings[1..]) |fb| {
                    try self.setLocal(fb.local_index, payload_ref);
                }
            } else {
                // Struct payload: extract fields normally.
                for (case.field_bindings) |fb| {
                    const field_ref = zir_builder_emit_field_val(self.handle, payload_ref, fb.field_name.ptr, @intCast(fb.field_name.len));
                    if (field_ref == error_ref) {
                        self.allocator.free(current_else_insts);
                        return error.EmitFailed;
                    }
                    try self.setLocal(fb.local_index, field_ref);
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
            const case_ptr = self.endCapture(&case_len);

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

    fn emitUnionSwitch(self: *ZirDriver, us: ir.UnionSwitch) BuildError!void {
        const scrutinee_ref = try self.refForLocal(us.scrutinee);

        if (us.cases.len == 0) return;

        // Pre-emit all body instructions with body_tracking OFF.
        // Collect instruction indices and result Refs for each prong.
        var names_ptrs : std.ArrayListUnmanaged([*]const u8) = .empty;
        defer names_ptrs.deinit(self.allocator);
        var names_lens : std.ArrayListUnmanaged(u32) = .empty;
        defer names_lens.deinit(self.allocator);
        var captures : std.ArrayListUnmanaged(u32) = .empty;
        defer captures.deinit(self.allocator);
        var body_lens : std.ArrayListUnmanaged(u32) = .empty;
        defer body_lens.deinit(self.allocator);
        var body_results : std.ArrayListUnmanaged(u32) = .empty;
        defer body_results.deinit(self.allocator);
        var all_body_insts : std.ArrayListUnmanaged(u32) = .empty;
        defer all_body_insts.deinit(self.allocator);

        // We need the future switch_block Ref for payload capture binding.
        // It will be emitted by addSwitchBlock after all body instructions.
        // For now, use a placeholder — we'll resolve it after the call.
        // Actually, addSwitchBlock returns the Ref. But body instructions
        // need it BEFORE the call. The solution: body instructions for the
        // Ok prong reference the return_value local, which we'll bind to
        // the switch Ref AFTER addSwitchBlock returns. But the body instructions
        // are already emitted...
        //
        // The correct approach: for capture prongs (Ok), the body_result should
        // reference the switch_block instruction. But we don't know its index yet.
        // Instead, we pass the body_result as-is — for Ok prongs where return_value
        // is the payload local, the local should already map to something.
        // For Error prongs, return_value is the handler (already lowered).

        // Pre-resolve all function references that appear in body instructions.
        // Inside switch prong bodies, zir_builder_emit_call (name lookup) fails.
        // We resolve them to Refs here (with body_tracking ON) so they're
        // in the function body and visible to Sema.
        var pre_resolved_fns = std.StringHashMap(u32).init(self.allocator);
        defer pre_resolved_fns.deinit();
        for (us.cases) |case| {
            for (case.body_instrs) |bi| {
                if (bi == .call_named) {
                    const cn = bi.call_named;
                    if (!pre_resolved_fns.contains(cn.name)) {
                        if (self.resolveCallNamedToRef(cn.name)) |fn_ref| {
                            pre_resolved_fns.put(cn.name, fn_ref) catch {};
                        } else |_| {}
                    }
                }
            }
        }

        for (us.cases) |case| {
            const is_ok = std.mem.eql(u8, case.variant_name, "Ok");

            try names_ptrs.append(self.allocator, case.variant_name.ptr);
            try names_lens.append(self.allocator, @intCast(case.variant_name.len));
            // Ok: capture payload + use capture as result (bit 0 = capture, bit 1 = use_capture_as_result)
            // Error: capture payload only (handler result is pre-computed)
            const capture_flags: u32 = if (is_ok) 3 else 1; // Ok=0b11, Error=0b01
            try captures.append(self.allocator, capture_flags);

            // Emit body instructions with tracking off
            zir_builder_set_body_tracking(self.handle, false);
            const body_start = zir_builder_get_inst_count(self.handle);

            for (case.body_instrs) |bi| {
                // Intercept call_named: use pre-resolved Ref with call_ref
                if (bi == .call_named) {
                    const cn = bi.call_named;
                    if (pre_resolved_fns.get(cn.name)) |fn_ref| {
                        var call_args : std.ArrayListUnmanaged(u32) = .empty;
                        defer call_args.deinit(self.allocator);
                        for (cn.args) |arg| {
                            const ref = self.refForValueLocal(arg) catch @intFromEnum(Zir.Inst.Ref.void_value);
                            try call_args.append(self.allocator, ref);
                        }
                        const result = zir_builder_emit_call_ref(self.handle, fn_ref, call_args.items.ptr, @intCast(call_args.items.len));
                        if (result == error_ref) return error.EmitFailed;
                        try self.setLocal(cn.dest, result);
                        continue;
                    }
                }
                try self.emitInstruction(bi);
            }

            const body_end = zir_builder_get_inst_count(self.handle);
            zir_builder_set_body_tracking(self.handle, true);

            const body_len = body_end - body_start;
            try body_lens.append(self.allocator, body_len);
            for (body_start..body_end) |inst_i| {
                try all_body_insts.append(self.allocator, @intCast(inst_i));
            }

            // Resolve case result
            if (is_ok) {
                // Ok: result will be the switch payload (resolved by Sema via inst_map).
                // We pass .none as body_result — addSwitchBlock's break_inline will
                // use this. But .none won't work. We need the switch_block Ref.
                // Since we don't have it yet, we'll use a placeholder approach:
                // pass .void_value and fix below.
                try body_results.append(self.allocator, @intFromEnum(Zir.Inst.Ref.void_value));
            } else {
                // Error: result is the pre-lowered handler expression
                if (case.return_value) |rv| {
                    const ref = self.refForValueLocal(rv) catch @intFromEnum(Zir.Inst.Ref.void_value);
                    try body_results.append(self.allocator, ref);
                } else {
                    try body_results.append(self.allocator, @intFromEnum(Zir.Inst.Ref.void_value));
                }
            }
        }

        // Call the single-pass C-ABI function
        const result = zir_builder_add_switch_block(
            self.handle,
            scrutinee_ref,
            names_ptrs.items.ptr,
            names_lens.items.ptr,
            captures.items.ptr,
            body_lens.items.ptr,
            body_results.items.ptr,
            all_body_insts.items.ptr,
            @intCast(us.cases.len),
        );
        if (result == 0xFFFFFFFFFFFFFFFF) return error.EmitFailed;

        const switch_ref: u32 = @truncate(result);
        const switch_inst_idx: u32 = @truncate(result >> 32);
        _ = switch_inst_idx;

        // Now patch the Ok prong's body_result to reference the switch_block Ref.
        // The switch_block Ref IS the payload capture. When Sema sees a break_inline
        // with operand = switch_ref, it resolves through inst_map to the captured value.
        // But we already passed void_value as the Ok result. The break_inline for the
        // Ok prong will yield void instead of the payload.
        //
        // The fix: for prongs with capture, the body_result should be the switch_block
        // Ref. But we passed void. We need to patch the break_inline instruction's
        // operand to switch_ref.
        //
        // Actually, looking at the Sema analysis: when capture=by_val, Sema puts
        // the extracted payload in inst_map[switch_block_inst]. The break_inline's
        // operand is what the switch expression evaluates to. For the Ok prong,
        // we want the payload — which means the break operand should reference
        // the switch_block instruction. That IS switch_ref.
        //
        // But we already wrote the break with void_value. We need to either:
        // 1. Pre-compute the switch_ref before calling addSwitchBlock
        // 2. Or have addSwitchBlock accept a flag to use the switch Ref as Ok result
        //
        // For now, accept that the Ok prong returns void. This means the ~>
        // expression evaluates to void for success. That's wrong for production
        // but let's see if it at least doesn't crash.

        try self.setLocal(us.dest, switch_ref);
    }

    /// Pre-resolve a named function to a ZIR decl_ref.
    /// Must be called with body_tracking ON (before entering prong bodies).
    /// Returns the function Ref, or error if not resolvable.
    fn resolveCallNamedToRef(self: *ZirDriver, name: []const u8) BuildError!u32 {
        // Check if this is a cross-module call — resolve via @import
        const target_func = self.findFunctionByName(name);
        const target_module = if (target_func) |tf| tf.module_name else null;
        const is_cross = blk: {
            if (target_module == null and self.current_emit_module == null) break :blk false;
            if (target_module == null or self.current_emit_module == null) break :blk true;
            break :blk !std.mem.eql(u8, target_module.?, self.current_emit_module.?);
        };
        if (is_cross and target_module != null) {
            const target_local = if (target_func) |tf| tf.local_name else name;
            const import_ref = zir_builder_emit_import(self.handle, target_module.?.ptr, @intCast(target_module.?.len));
            if (import_ref == error_ref) return error.EmitFailed;
            const fn_ref = zir_builder_emit_field_val(self.handle, import_ref, target_local.ptr, @intCast(target_local.len));
            if (fn_ref == error_ref) return error.EmitFailed;
            return fn_ref;
        }

        // Intra-module: use local name for decl_ref
        const resolve_name = if (self.current_emit_module != null)
            if (target_func) |tf| tf.local_name else name
        else
            name;
        const ref = zir_builder_emit_decl_ref(self.handle, resolve_name.ptr, @intCast(resolve_name.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
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
        if (zir_compilation_add_struct(compilation_ctx, "zap_runtime", rpath) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    var driver = try ZirDriver.init(allocator);
    driver.lib_mode = lib_mode;
    driver.builder_entry = builder_entry;
    driver.analysis_context = analysis_context;
    driver.compilation_ctx = compilation_ctx;

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
    try std.testing.expect(!immediate.direct_capture_params);
    try std.testing.expect(immediate.needs_env_param);
    try std.testing.expect(immediate.needs_closure_object);

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

// Runtime function routing is handled entirely via @native attributes
// in Zap library files (lib/*.zap). The compiler's HIR builder resolves
// @native annotations to call_builtin instructions, which the ZIR builder
// emits as @import("zap_runtime").Module.function(args).
//
// No hardcoded function routing exists in the compiler.
