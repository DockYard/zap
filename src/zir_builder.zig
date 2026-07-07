//! ZIR Builder — thin driver that calls C-ABI builder functions.
//!
//! The actual ZIR encoding logic lives in the Zig fork (~/projects/zig).
//! This struct maps Zap IR instructions to C-ABI calls exported by
//! zir_api.zig in that fork.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const elision = @import("memory/elision.zig");
const progress_mod = @import("progress.zig");
const zap_symbol_table = @import("zap_symbol_table.zig");
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
/// Emit `?T` — wraps `child` in an optional type. Used by the
/// recursive-struct storage strategy plus any call-site that
/// needs to express optional types in a body context.
extern "c" fn zir_builder_emit_optional_type(handle: ?*ZirBuilderHandle, child: u32) u32;
/// Emit `*const T` — a single-element, immutable, default-
/// address-space pointer. The recursive-struct storage strategy
/// inserts this between a self-referential field's nominal type
/// and its enclosing optional, breaking what would otherwise be
/// an infinite-size value-typed cycle.
extern "c" fn zir_builder_emit_single_const_ptr_type(handle: ?*ZirBuilderHandle, pointee: u32) u32;
/// Emit `*const fn(P0, P1, ...) Ret` — a pointer to a bare function TYPE.
/// `param_type_refs` are the parameter type Refs (each a
/// `@intFromEnum(Zir.Inst.Ref)`); `ret_type` is the return type Ref. This is
/// the runtime representation of a non-capturing (0-capture) Zap closure
/// value, so the ZIR backend renders a closure type (`fn() -> i64`) through
/// this at every concrete-type position — struct field, function return
/// type, tuple element — where the param-position `anytype` lowering can't
/// be used. See `FuncBody.addFuncPtrType` in the fork.
extern "c" fn zir_builder_emit_func_ptr_type(handle: ?*ZirBuilderHandle, param_type_refs_ptr: [*]const u32, param_type_refs_len: u32, ret_type: u32) u32;
extern "c" fn zir_builder_emit_if_else(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;
extern "c" fn zir_builder_emit_struct_init_anon(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;
extern "c" fn zir_builder_emit_union_init(handle: ?*ZirBuilderHandle, union_type: u32, field_name_ptr: [*]const u8, field_name_len: u32, init_value: u32) u32;
extern "c" fn zir_builder_get_union_ret_type_ref(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_decl_ref(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
extern "c" fn zir_builder_emit_decl_val(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) u32;
// Union return type
extern "c" fn zir_builder_set_union_return_type(handle: ?*ZirBuilderHandle, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, types_ptr: [*]const u32, fields_len: u32) i32;

// Switch block for tagged unions (single-pass API)
extern "c" fn zir_builder_add_switch_block(handle: ?*ZirBuilderHandle, operand: u32, prong_names_ptrs: [*]const [*]const u8, prong_names_lens: [*]const u32, prong_captures: [*]const u32, prong_body_lens: [*]const u32, prong_body_results: [*]const u32, prong_body_insts: [*]const u32, num_prongs: u32, has_else: u32, else_body_len: u32, else_body_result: u32, payload_capture_placeholder: u32, prong_noreturn_flags: [*]const u32, else_is_noreturn: u32) u64;
extern "c" fn zir_builder_emit_value_placeholder(handle: ?*ZirBuilderHandle) u32;

// Body tracking control (for branch body emission)
extern "c" fn zir_builder_set_body_tracking(handle: ?*ZirBuilderHandle, enabled: bool) void;
extern "c" fn zir_builder_get_inst_count(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_begin_capture(handle: ?*ZirBuilderHandle) void;
extern "c" fn zir_builder_end_capture(handle: ?*ZirBuilderHandle, out_len: *u32) [*]const u32;
extern "c" fn zir_builder_emit_if_else_bodies(handle: ?*ZirBuilderHandle, condition: u32, then_insts_ptr: [*]const u32, then_insts_len: u32, then_result: u32, else_insts_ptr: [*]const u32, else_insts_len: u32, else_result: u32, then_is_noreturn: u32, else_is_noreturn: u32) u32;
extern "c" fn zir_builder_emit_cond_branch_with_bodies(handle: ?*ZirBuilderHandle, condition: u32, then_insts_ptr: [*]const u32, then_insts_len: u32, else_insts_ptr: [*]const u32, else_insts_len: u32) i32;
extern "c" fn zir_builder_emit_int_typed(handle: ?*ZirBuilderHandle, value: i64, dest_type: u32) u32;

// Field mutation and optional handling
extern "c" fn zir_builder_emit_field_ptr(handle: ?*ZirBuilderHandle, object: u32, field_ptr_arg: [*]const u8, field_len: u32) u32;
extern "c" fn zir_builder_emit_store(handle: ?*ZirBuilderHandle, ptr_ref: u32, value_ref: u32) i32;
extern "c" fn zir_builder_emit_is_non_null(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_optional_payload(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_optional_payload_unsafe(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_set_call_modifier(handle: ?*ZirBuilderHandle, modifier: u32) void;
extern "c" fn zir_builder_emit_if_else_inline(handle: ?*ZirBuilderHandle, condition: u32, then_value: u32, else_value: u32) u32;

// Numeric widening (@as coercion)
extern "c" fn zir_builder_emit_as(handle: ?*ZirBuilderHandle, dest_type: u32, operand: u32) u32;

// Return type overrides
extern "c" fn zir_builder_set_imported_return_type(handle: ?*ZirBuilderHandle, mod_ptr: [*]const u8, mod_len: u32, field_ptr: [*]const u8, field_len: u32) i32;
// File-IS-the-struct counterparts: return type is the imported file's
// root (`@import(name)`), or `@This()` for a self-return. Required so
// that the import / `@This()` instructions land inside the function's
// ret_ty body rather than in the outer scope.
extern "c" fn zir_builder_set_imported_root_return_type(handle: ?*ZirBuilderHandle, import_name_ptr: [*]const u8, import_name_len: u32) i32;
extern "c" fn zir_builder_set_this_return_type(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_set_custom_return_type(handle: ?*ZirBuilderHandle, inst_indices_ptr: [*]const u32, inst_indices_len: u32, result_inst: u32) i32;

// Tuple/array construction and element access
extern "c" fn zir_builder_emit_array_init_anon(handle: ?*ZirBuilderHandle, values_ptr: [*]const u32, values_len: u32) u32;
extern "c" fn zir_builder_emit_elem_val_imm(handle: ?*ZirBuilderHandle, operand: u32, index: u32) u32;

// Generic / conditional return composition
extern "c" fn zir_builder_set_generic_return_type(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_emit_cond_return(handle: ?*ZirBuilderHandle, condition: u32, value: u32) i32;
extern "c" fn zir_builder_emit_dbg_stmt(handle: ?*ZirBuilderHandle, line: u32, column: u32) i32;
// Phase 0 — DWARF foundation: dbg_var (named local variable) ABI.
// `name_ptr`/`name_len` are the Zap source identifier (not null-terminated;
// the fork interns its own copy). `operand` is the ZIR Ref of the local's
// value (for `_val`) or pointer (for `_ptr`). Returns 0 on success, -1 on
// error. Implemented in ~/projects/zig/src/zir_api.zig.
extern "c" fn zir_builder_emit_dbg_var_val(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, operand: u32) i32;
extern "c" fn zir_builder_emit_dbg_var_ptr(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, operand: u32) i32;

// Runtime safety control (for guard error semantics)
extern "c" fn zir_builder_emit_set_runtime_safety(handle: ?*ZirBuilderHandle, enabled: u32) bool;

// Optional type support (for __try variant catch basin)
extern "c" fn zir_builder_set_optional_return_type(handle: ?*ZirBuilderHandle) i32;
extern "c" fn zir_builder_emit_ret_null(handle: ?*ZirBuilderHandle) i32;

// Error-union support (Phase 3.b cross-function `raise` propagation).
// A function whose `raises` row is non-empty returns `error{...}!T`; a
// `raise` site emits `recoverable_raise(box)` (TLS stash) then
// `emit_ret_error` (the control signal). Call sites propagate the error
// union via `emit_try` (native `try` — builds the error return trace) or
// route it to a `try`/`rescue` landing pad via `emit_catch`.
extern "c" fn zir_builder_set_error_union_return_type(handle: ?*ZirBuilderHandle, error_name_ptr: [*]const u8, error_name_len: u32) i32;
// Phase 4 (effect by inference) — build a standalone `error_set!T` error-union
// TYPE expression from an error-set ref and a payload type ref, for the
// devirtualized bare-fn-ptr representation of a raising closure
// (`*const fn(...) anyerror!T`). Distinct from
// `set_error_union_return_type`, which wraps the enclosing function's own
// return; this composes a nested type used inside a func-ptr type. Pass the
// well-known `anyerror_type` ref as `error_set` to match every other
// recoverable-raise site.
extern "c" fn zir_builder_emit_error_union_type(handle: ?*ZirBuilderHandle, error_set: u32, payload: u32) u32;
extern "c" fn zir_builder_emit_ret_error(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_emit_try(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_catch(handle: ?*ZirBuilderHandle, operand: u32, catch_value: u32) u32;
// `operand catch <else-body>` — the catch-expression's instructions run ONLY
// on the error branch. Used by the `abort_unhandled` unwrap so a `noreturn`
// abort never fires on the success path (GAP-P3-01 / FU-33). `else_insts` are
// captured via begin_capture/end_capture; `else_is_noreturn` skips the
// synthesized trailing break for a self-terminating body.
extern "c" fn zir_builder_emit_catch_with_body(handle: ?*ZirBuilderHandle, operand: u32, else_insts_ptr: [*]const u32, else_insts_len: u32, else_result: u32, else_is_noreturn: u32) u32;
extern "c" fn zir_builder_emit_is_non_err(handle: ?*ZirBuilderHandle, operand: u32) u32;
extern "c" fn zir_builder_emit_err_union_payload_unsafe(handle: ?*ZirBuilderHandle, operand: u32) u32;

// Struct type declarations
extern "c" fn zir_builder_add_struct_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, field_names_ptrs: [*]const [*]const u8, field_names_lens: [*]const u32, field_type_refs: [*]const u32, field_default_refs: ?[*]const u32, fields_len: u32) i32;

// Set fields directly on the file's root struct_decl. Per emission, the root
// struct_decl is fixed at instruction 0 (`main_struct_inst`) and represents
// "this Zig file IS a struct". Calling this with the file's owning Zap
// struct's fields makes `@import("...")` from another emission yield that
// struct directly — same `InternPool.Index`, single canonical nominal
// identity. count == 0 clears any prior config (no-op fallback).
extern "c" fn zir_builder_set_root_fields(handle: ?*ZirBuilderHandle, name_ptrs: [*]const [*]const u8, name_lens: [*]const u32, type_refs: [*]const u32, count: u32) i32;
/// Streaming per-field-body API. Pair with `begin_root_field_body` /
/// `end_root_field_body` to emit fields whose type body is more than
/// a single static Ref (nominal struct types, generic containers,
/// lists, maps, tuples of nominal). Primitives use the
/// `set_root_field_static` fast path. Replacement for the
/// fundamentally-limited single-Ref-per-field shape.
extern "c" fn zir_builder_set_root_field_static(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, type_ref: u32) i32;
extern "c" fn zir_builder_begin_root_field_body(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_end_root_field_body(handle: ?*ZirBuilderHandle, final_ref: u32) i32;
// Streaming NAMED struct-decl API (the non-root analogue of the root-field-body
// API above). Emits `pub const <name> = struct { … };` whose fields may carry
// compound (multi-instruction) type bodies — used for `__ClosureEnv_N` env
// structs holding captured `ProtocolBox`/`List`/`Map`/struct/fn-ptr fields.
extern "c" fn zir_builder_begin_named_struct_decl(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_named_struct_field_static(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32, type_ref: u32) i32;
extern "c" fn zir_builder_begin_named_struct_field_body(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_end_named_struct_field_body(handle: ?*ZirBuilderHandle, final_ref: u32) i32;
extern "c" fn zir_builder_end_named_struct_decl(handle: ?*ZirBuilderHandle) i32;
/// Phase 2.b — record a `pub const <name> = <expr>;` namespace declaration
/// in the current struct scope. Between the begin/end pair, the usual
/// `zir_builder_emit_*` calls build the initializer expression; `end`
/// closes the declaration's value body with `break_inline value_ref` and
/// lists it under the struct_decl's `decls`.
extern "c" fn zir_builder_begin_const_decl(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_end_const_decl(handle: ?*ZirBuilderHandle, value_ref: u32) i32;
extern "c" fn zir_builder_set_decl_val_return_type(handle: ?*ZirBuilderHandle, name_ptr: [*]const u8, name_len: u32) i32;
extern "c" fn zir_builder_emit_param_decl_val_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, type_name_ptr: [*]const u8, type_name_len: u32) u32;
extern "c" fn zir_builder_emit_param_optional_decl_val_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, type_name_ptr: [*]const u8, type_name_len: u32) u32;
extern "c" fn zir_builder_emit_param_optional_this_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32) u32;

// Emit a parameter whose type is the root struct of an imported file:
// `param_name: @import(import_name)` — file-IS-the-struct flavor with no
// nested decl access. Required because the param's type body must contain
// the import instruction; emitting the import in outer scope and then
// passing the Ref to the bare `emit_param` puts the import in a different
// body than the break that would resolve it (Sema panics in
// `analyzeInlineBody` → `resolveInst` because the import inst isn't in
// the param body's `inst_map`). See fork's `addParamImportedRootType`.
extern "c" fn zir_builder_emit_param_imported_root_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, import_name_ptr: [*]const u8, import_name_len: u32) u32;
extern "c" fn zir_builder_emit_param_imported_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, struct_name_ptr: [*]const u8, struct_name_len: u32, field_name_ptr: [*]const u8, field_name_len: u32) u32;

// Emit a parameter whose type is `@This()` — a self-reference to the
// current file's root struct. Required for the `.primary` classification
// (the method's own enclosing Zap struct as a parameter type), since
// `@import(self_name)` is rejected by Zig's build struct system.
extern "c" fn zir_builder_emit_param_this_type(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32) u32;
extern "c" fn zir_builder_emit_param_type_body(handle: ?*ZirBuilderHandle, param_name_ptr: [*]const u8, param_name_len: u32, type_body_inst_indices_ptr: [*]const u32, type_body_inst_indices_len: u32, type_result: u32) u32;
extern "c" fn zir_builder_emit_this_type(handle: ?*ZirBuilderHandle) u32;

// Tuple return type
extern "c" fn zir_builder_set_tuple_return_type(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) i32;
extern "c" fn zir_builder_set_tuple_return_type_with_body(handle: ?*ZirBuilderHandle, inst_indices_ptr: [*]const u32, inst_indices_len: u32, types_ptr: [*]const u32, types_len: u32) i32;
extern "c" fn zir_builder_get_body_inst_count(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_tuple_decl_untracked(handle: ?*ZirBuilderHandle, types_ptr: [*]const u32, types_len: u32) u32;
extern "c" fn zir_builder_ref_to_inst_index(handle: ?*ZirBuilderHandle, ref: u32) u32;
extern "c" fn zir_builder_get_tuple_return_type(handle: ?*ZirBuilderHandle) u32;
extern "c" fn zir_builder_emit_struct_init_typed(handle: ?*ZirBuilderHandle, struct_type: u32, names_ptrs: [*]const [*]const u8, names_lens: [*]const u32, values_ptr: [*]const u32, fields_len: u32) u32;
extern "c" fn zir_builder_emit_struct_init_empty(handle: ?*ZirBuilderHandle, struct_type: u32) u32;
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

/// Optional debug-only dump of synthetic Zig source emitted via
/// `zir_compilation_add_struct_source`. Activated by setting
/// `ZAP_DUMP_SOURCES=1` (dump everything) or
/// `ZAP_DUMP_SOURCES=Option:MyError` (colon-separated name substrings).
/// Production builds never set the env var; the helper is a debug aid for
/// synthetic-source emission gaps.
fn dumpSyntheticSourceIfRequested(
    name: [*:0]const u8,
    source_ptr: [*]const u8,
    source_len: u32,
) void {
    const raw = std.c.getenv("ZAP_DUMP_SOURCES") orelse return;
    const filter_z: [*:0]const u8 = @ptrCast(raw);
    const filter = std.mem.span(filter_z);
    const name_slice = std.mem.span(name);
    const should_dump = std.mem.eql(u8, filter, "1") or blk: {
        var iter = std.mem.tokenizeScalar(u8, filter, ':');
        while (iter.next()) |needle| {
            if (std.mem.indexOf(u8, name_slice, needle) != null) break :blk true;
        }
        break :blk false;
    };
    if (should_dump) {
        const source_slice = source_ptr[0..source_len];
        std.debug.print("=== synthetic source: {s} (len={d}) ===\n{s}\n=== end ===\n", .{ name_slice, source_len, source_slice });
    }
}
extern "c" fn zir_compilation_set_root_debug_source(ctx: ?*ZirContext, source_path_ptr: [*]const u8, source_path_len: u32) i32;
extern "c" fn zir_compilation_set_struct_debug_source(ctx: ?*ZirContext, name_ptr: [*]const u8, name_len: u32, source_path_ptr: [*]const u8, source_path_len: u32) i32;

// Pointer casting
extern "c" fn zir_builder_emit_ptr_cast(handle: ?*ZirBuilderHandle, dest_type: u32, operand: u32) u32;

// ---------------------------------------------------------------------------
// Error sentinel
// ---------------------------------------------------------------------------

const error_ref: u32 = 0xFFFFFFFF;

// ---------------------------------------------------------------------------
// Binary op tag mapping (ZIR Inst.Tag u8 values)
// ---------------------------------------------------------------------------

const Zir = std.zig.Zir;

/// Map an IR binary op to its primitive ZIR `Inst.Tag`. Arithmetic tags
/// are type-sensitive AND optimize-mode-sensitive:
///
/// * Float arithmetic always uses Zig's ordinary float-capable operators
///   (`add`/`sub`/`mul`).
/// * Integer arithmetic follows the Phase 1.5 per-optimize-mode overflow
///   policy via `overflow_traps`:
///     - `overflow_traps == true` (Debug / ReleaseSafe) → the checked
///       tags (`add`/`sub`/`mul`). In safe modes Zig emits an overflow
///       safety check on these; the runtime's panic handler routes the
///       check to `** (arithmetic_error) ...`.
///     - `overflow_traps == false` (ReleaseFast / ReleaseSmall) → the
///       wrapping tags (`addwrap`/`subwrap`/`mulwrap`), so overflow wraps
///       two's-complement with no trap. This matches Zig's optimize-mode
///       model while guaranteeing *wrapping* (never UB) in fast modes.
///
/// Generic `List(f64)` element reads can bypass protocol dispatch and
/// reach this primitive fallback directly, so the IR carries the binary
/// result type for the float/int decision.
///
/// Returns null for operators handled outside of `emit_binop` —
/// short-circuit booleans, string compare, concat, and membership tests.
fn mapBinopTag(op: ir.BinaryOp.Op, result_type: ir.ZigType, overflow_traps: bool) ?u8 {
    const is_float = switch (result_type) {
        .f16, .f32, .f64, .f80, .f128 => true,
        else => false,
    };
    // Integer arithmetic uses the checked tag when overflow must trap,
    // the wrapping tag otherwise. Floats always use the plain tag.
    const int_checked = is_float or overflow_traps;
    return switch (op) {
        .add => @intFromEnum(if (int_checked) Zir.Inst.Tag.add else Zir.Inst.Tag.addwrap),
        .sub => @intFromEnum(if (int_checked) Zir.Inst.Tag.sub else Zir.Inst.Tag.subwrap),
        .mul => @intFromEnum(if (int_checked) Zir.Inst.Tag.mul else Zir.Inst.Tag.mulwrap),
        .div => @intFromEnum(if (is_float) Zir.Inst.Tag.div else Zir.Inst.Tag.div_trunc),
        .rem_op => @intFromEnum(if (is_float) Zir.Inst.Tag.rem else Zir.Inst.Tag.mod_rem),
        .eq => @intFromEnum(Zir.Inst.Tag.cmp_eq),
        .neq => @intFromEnum(Zir.Inst.Tag.cmp_neq),
        .lt => @intFromEnum(Zir.Inst.Tag.cmp_lt),
        .gt => @intFromEnum(Zir.Inst.Tag.cmp_gt),
        .lte => @intFromEnum(Zir.Inst.Tag.cmp_lte),
        .gte => @intFromEnum(Zir.Inst.Tag.cmp_gte),
        .bool_and, .bool_or => null,
        .string_eq, .string_neq => null,
        .concat => null,
        .in_list, .in_range => null,
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

const max_index_field_name_len = std.fmt.count("{d}", .{std.math.maxInt(u32)});

const IndexFieldName = struct {
    ptr: [*]const u8,
    len: u32,
};

/// Returns a field-name pointer for a numeric index. For indices 0-31 this
/// uses a comptime table. Larger indices are formatted into caller-owned
/// storage sized from maxInt(u32), so formatting cannot run out of space.
fn indexFieldName(index: anytype, buffer: *[max_index_field_name_len]u8) IndexFieldName {
    const idx: u32 = @intCast(index);
    if (idx < index_field_names.len) {
        const name = index_field_names[idx];
        return .{ .ptr = name.ptr, .len = @intCast(name.len) };
    }
    const slice = std.fmt.bufPrint(buffer, "{d}", .{idx}) catch unreachable;
    return .{ .ptr = slice.ptr, .len = @intCast(slice.len) };
}

const IndexFieldNameBatch = struct {
    allocator: Allocator,
    buffers: [][max_index_field_name_len]u8,
    next_buffer: usize = 0,

    fn init(allocator: Allocator, count: usize) BuildError!IndexFieldNameBatch {
        const dynamic_count = if (count > index_field_names.len)
            count - index_field_names.len
        else
            0;
        const buffers: [][max_index_field_name_len]u8 = if (dynamic_count == 0)
            &[_][max_index_field_name_len]u8{}
        else
            try allocator.alloc([max_index_field_name_len]u8, dynamic_count);
        return .{ .allocator = allocator, .buffers = buffers };
    }

    fn deinit(self: *IndexFieldNameBatch) void {
        self.allocator.free(self.buffers);
    }

    fn get(self: *IndexFieldNameBatch, index: anytype) IndexFieldName {
        const idx: u32 = @intCast(index);
        if (idx < index_field_names.len) {
            const name = index_field_names[idx];
            return .{ .ptr = name.ptr, .len = @intCast(name.len) };
        }
        std.debug.assert(self.next_buffer < self.buffers.len);
        const slice = std.fmt.bufPrint(&self.buffers[self.next_buffer], "{d}", .{idx}) catch unreachable;
        self.next_buffer += 1;
        return .{ .ptr = slice.ptr, .len = @intCast(slice.len) };
    }
};

const CurrentElseInsts = struct {
    allocator: Allocator,
    insts: ?[]u32 = null,

    fn init(allocator: Allocator) CurrentElseInsts {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CurrentElseInsts) void {
        self.clear();
    }

    fn hasOwnedBuffer(self: *const CurrentElseInsts) bool {
        return self.insts != null;
    }

    fn get(self: *const CurrentElseInsts) []const u32 {
        return self.insts orelse unreachable;
    }

    fn clear(self: *CurrentElseInsts) void {
        if (self.insts) |insts| {
            self.allocator.free(insts);
            self.insts = null;
        }
    }

    fn replaceWithCopy(self: *CurrentElseInsts, source: []const u32) BuildError!void {
        const next_insts = try self.allocator.alloc(u32, source.len);
        @memcpy(next_insts, source);
        self.clear();
        self.insts = next_insts;
    }

    fn replaceWithSingle(self: *CurrentElseInsts, inst: u32) BuildError!void {
        const next_insts = try self.allocator.alloc(u32, 1);
        next_insts[0] = inst;
        self.clear();
        self.insts = next_insts;
    }

    fn replaceWithEmpty(self: *CurrentElseInsts) BuildError!void {
        const next_insts = try self.allocator.alloc(u32, 0);
        self.clear();
        self.insts = next_insts;
    }
};

const DestroyStructBuilderHandleFn = *const fn (*ZirBuilderHandle) void;

fn destroyStructBuilderHandle(handle: *ZirBuilderHandle) void {
    zir_builder_destroy(handle);
}

const StructEmissionScope = struct {
    driver: *ZirDriver,
    saved_handle: *ZirBuilderHandle,
    saved_current_emit_struct: ?[]const u8,
    temporary_handle: ?*ZirBuilderHandle,
    destroy_temporary_handle: DestroyStructBuilderHandleFn,

    fn enter(
        driver: *ZirDriver,
        temporary_handle: *ZirBuilderHandle,
        struct_name: []const u8,
    ) StructEmissionScope {
        return enterWithDestroyFn(driver, temporary_handle, struct_name, destroyStructBuilderHandle);
    }

    fn enterWithDestroyFn(
        driver: *ZirDriver,
        temporary_handle: *ZirBuilderHandle,
        struct_name: []const u8,
        destroy_temporary_handle: DestroyStructBuilderHandleFn,
    ) StructEmissionScope {
        const scope = StructEmissionScope{
            .driver = driver,
            .saved_handle = driver.handle,
            .saved_current_emit_struct = driver.current_emit_struct,
            .temporary_handle = temporary_handle,
            .destroy_temporary_handle = destroy_temporary_handle,
        };
        driver.handle = temporary_handle;
        driver.current_emit_struct = struct_name;
        return scope;
    }

    fn handle(self: *const StructEmissionScope) *ZirBuilderHandle {
        return self.temporary_handle orelse unreachable;
    }

    fn markConsumedByInjection(self: *StructEmissionScope) void {
        self.temporary_handle = null;
    }

    fn deinit(self: *StructEmissionScope) void {
        const temporary_handle = self.temporary_handle;
        self.temporary_handle = null;
        self.driver.handle = self.saved_handle;
        self.driver.current_emit_struct = self.saved_current_emit_struct;
        if (temporary_handle) |unconsumed_handle| {
            self.destroy_temporary_handle(unconsumed_handle);
        }
    }
};

// ---------------------------------------------------------------------------
// Return type mapping (ir.ZigType -> ZIR Ref u32 value)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Runtime sub-namespace registry
//
// Single source of truth for the names of `zap_runtime`'s internal
// structs that the ZIR builder reaches into when lowering. Each entry
// pairs the name string with its byte length, since the C-ABI
// `zir_builder_emit_field_val` takes both. Use the `emitField`
// helper to fetch a field on the runtime import without per-call-site
// string literals — that way adding/renaming a runtime sub-struct
// touches one row here rather than 10+ call sites scattered through
// `lowerExpr`/`lowerInstruction`.
// ---------------------------------------------------------------------------

const RuntimeNamespace = struct {
    name: [:0]const u8,
    len: u32,

    fn make(comptime n: [:0]const u8) RuntimeNamespace {
        return .{ .name = n, .len = @intCast(n.len) };
    }
};

const runtime_ns = struct {
    const arc_runtime = RuntimeNamespace.make("ArcRuntime");
    const kernel = RuntimeNamespace.make("Kernel");
    const builder_runtime = RuntimeNamespace.make("BuilderRuntime");
    const binary_helpers = RuntimeNamespace.make("BinaryHelpers");
};

/// Emit `parent.<ns>` as a ZIR field-val instruction. Wraps the raw
/// C-ABI call so callers don't have to pass the name pointer/length
/// pair, and so renaming a runtime sub-namespace touches one place.
fn emitRuntimeNamespaceField(handle: *ZirBuilderHandle, parent: u32, comptime ns: RuntimeNamespace) u32 {
    return zir_builder_emit_field_val(handle, parent, ns.name.ptr, ns.len);
}

/// P2-J2 — the root-level decl name the user's entry function is
/// emitted under when the `runtime_concurrency` gate is ON (executable
/// outputs only). The synthetic `main` wrapper references it by name
/// (`zir_builder_emit_decl_val`) and hands it to
/// `zap_runtime.runRootProcessMain`, which spawns it as the root
/// process. Same compiler-internal naming convention as
/// `zap_builder_entry`; user Zap functions can never collide with it
/// (only the entry point is emitted at the root level, always as
/// `main` or this name).
const root_process_main_decl_name = "zap_root_process_main";

/// For main(), Zig requires void or u8 return type.
/// Zap executable entrypoints return exact `u8` process exit status.
/// A lower-level `.void` return is accepted only because Zig's entry
/// ABI permits it for generated declarations that do not carry a Zap
/// source-level value. Other Zap return types are invalid: silently
/// lowering them to void would discard user values.
fn mapMainReturnType(zig_type: ir.ZigType) BuildError!u32 {
    return switch (zig_type) {
        .void => 0,
        .u8 => @intFromEnum(Zir.Inst.Ref.u8_type),
        else => error.InvalidMainReturnType,
    };
}

/// ZIR type Ref for a concrete integer scalar Zap type, else 0.
/// Used to decide whether an otherwise-untyped integer literal should
/// be emitted typed to the enclosing function's integer return type.
/// Render the synthetic Zig source body for a `union_def` or
/// `enum_def` per-instantiation TypeDef. Extracted from
/// `ZirDriver.emitSpecializationSourceFile` so the formatting
/// invariants (most importantly: when to inject
/// `const zap_runtime = @import("zap_runtime");`) can be unit-
/// tested without spinning up a full ZIR builder context.
///
/// The caller-owned `buf` receives the complete source body. The
/// function is a no-op for type_def kinds outside the supported
/// `union_def`/`enum_def` set so callers can guard exhaustiveness
/// at their own level.
fn renderSpecializationSourceFileBody(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    type_def: ir.TypeDef,
) !void {
    switch (type_def.kind) {
        .union_def => |def| {
            // When any variant's payload type references the
            // `zap_runtime` namespace (e.g. a `protocol_box(P)`
            // payload renders as `zap_runtime.ProtocolBox` via
            // `ir.zigTypeToStr`), the synthetic file must bring
            // that namespace into scope so Sema can resolve the
            // identifier. Without this import the variant payload
            // type stays unresolved through to LLVM emission,
            // surfacing as an "attempt to use null value" panic
            // in `Builder.toBitcode` when an `Option(<Protocol>)`
            // value is constructed at a call site (see Phase
            // 1.2.5 Gap 1).
            //
            // We emit the import only when a variant actually
            // references `zap_runtime` so unparametrized
            // specializations like `Option_i64` stay free of
            // unused-namespace noise.
            var needs_runtime_import = false;
            for (def.variants) |variant| {
                if (variant.type_name) |tn| {
                    if (std.mem.indexOf(u8, tn, "zap_runtime") != null) {
                        needs_runtime_import = true;
                        break;
                    }
                }
            }
            if (needs_runtime_import) {
                try buf.appendSlice(
                    allocator,
                    "const zap_runtime = @import(\"zap_runtime\");\n\n",
                );
            }

            try buf.appendSlice(allocator, "pub const ");
            try buf.appendSlice(allocator, type_def.name);
            try buf.appendSlice(allocator, " = union(enum) {\n");
            for (def.variants) |variant| {
                try buf.appendSlice(allocator, "    ");
                try buf.appendSlice(allocator, variant.name);
                if (variant.type_name) |tn| {
                    if (std.mem.eql(u8, tn, "void")) {
                        try buf.appendSlice(allocator, ",\n");
                    } else {
                        try buf.appendSlice(allocator, ": ");
                        try buf.appendSlice(allocator, tn);
                        try buf.appendSlice(allocator, ",\n");
                    }
                } else {
                    try buf.appendSlice(allocator, ",\n");
                }
            }
            try buf.appendSlice(allocator, "};\n");
        },
        .enum_def => |def| {
            try buf.appendSlice(allocator, "pub const ");
            try buf.appendSlice(allocator, type_def.name);
            try buf.appendSlice(allocator, " = enum {\n");
            for (def.variants) |variant_name| {
                try buf.appendSlice(allocator, "    ");
                try buf.appendSlice(allocator, variant_name);
                try buf.appendSlice(allocator, ",\n");
            }
            try buf.appendSlice(allocator, "};\n");
        },
        else => {},
    }
}

/// Append a Zig identifier, quoting it with `@"..."` when the
/// raw text contains characters Zig's tokenizer would reject.
/// Used by the protocol-vtable synthetic-source emission to
/// produce field names that survive any unusual method names a
/// `pub protocol` declaration carries (e.g. operator-spelled
/// methods that the mangler hasn't yet had a chance to rewrite).
fn appendZigIdentifier(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) !void {
    // Conservative test: an identifier is "plain" if every char is
    // [A-Za-z0-9_] and the first char is not a digit. Anything else
    // gets `@"..."` quoting so the synthetic source stays valid
    // Zig regardless of source-level Zap method-name choices.
    var needs_quote: bool = text.len == 0 or std.ascii.isDigit(text[0]);
    if (!needs_quote) {
        for (text) |ch| {
            const is_ident_char = std.ascii.isAlphanumeric(ch) or ch == '_';
            if (!is_ident_char) {
                needs_quote = true;
                break;
            }
        }
    }
    if (!needs_quote) {
        try buf.appendSlice(allocator, text);
        return;
    }
    try buf.appendSlice(allocator, "@\"");
    try buf.appendSlice(allocator, text);
    try buf.appendSlice(allocator, "\"");
}

/// Emit the Zig source form of an IR `ZigType` for use inside a
/// vtable function-pointer signature. The set of supported shapes
/// matches Phase 1.2.5.a's resolver (`astTypeExprToZigTypeForProtocol`
/// in `src/ir.zig`): primitives lower to their canonical Zig
/// spelling (`i64`, `[]const u8`, `bool`, `void`); nominal struct
/// references emit an `@import("<Name>").<Name>` form so Sema
/// resolves the type to its file-IS-the-struct canonical identity;
/// anything else falls back to `anytype` (the dispatch site only
/// passes opaque pointers through here, so a partially-typed
/// signature still compiles).
fn appendZigTypeForVTable(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    zig_type: ir.ZigType,
) std.mem.Allocator.Error!void {
    switch (zig_type) {
        .void => try buf.appendSlice(allocator, "void"),
        .never => try buf.appendSlice(allocator, "noreturn"),
        .bool_type => try buf.appendSlice(allocator, "bool"),
        .i8 => try buf.appendSlice(allocator, "i8"),
        .i16 => try buf.appendSlice(allocator, "i16"),
        .i32 => try buf.appendSlice(allocator, "i32"),
        .i64 => try buf.appendSlice(allocator, "i64"),
        .i128 => try buf.appendSlice(allocator, "i128"),
        .u8 => try buf.appendSlice(allocator, "u8"),
        .u16 => try buf.appendSlice(allocator, "u16"),
        .u32 => try buf.appendSlice(allocator, "u32"),
        .u64 => try buf.appendSlice(allocator, "u64"),
        .u128 => try buf.appendSlice(allocator, "u128"),
        .f16 => try buf.appendSlice(allocator, "f16"),
        .f32 => try buf.appendSlice(allocator, "f32"),
        .f64 => try buf.appendSlice(allocator, "f64"),
        .f80 => try buf.appendSlice(allocator, "f80"),
        .f128 => try buf.appendSlice(allocator, "f128"),
        .usize => try buf.appendSlice(allocator, "usize"),
        .isize => try buf.appendSlice(allocator, "isize"),
        // `String` lowers to Zig's `[]const u8` slice. `Atom`, in
        // contrast, is an interned `u32` ID at runtime (see the `.atom`
        // arms in `mapParamType`/`mapReturnType`/`emitImportedTypeRef`
        // and the `const_atom` lowering). A vtable method slot whose
        // protocol return type is `Atom` (e.g. `Error.kind`) MUST render
        // as `u32` so it matches the impl method's actual `u32` return —
        // rendering it as `[]const u8` makes Sema reject the per-impl
        // adapter with `expected type '[]const u8', found 'u32'`.
        .string => try buf.appendSlice(allocator, "[]const u8"),
        .atom => try buf.appendSlice(allocator, "u32"),
        .nil => try buf.appendSlice(allocator, "?void"),
        .term => try buf.appendSlice(allocator, "zap_runtime.Term"),
        // Protocol existential — the runtime fat-pointer carrier.
        // Phase 1.2.5.b lowers every `protocol_constraint` TypeId
        // through `typeIdToZigTypeWithStore` to this `.protocol_box`
        // shape; the ZIR backend renders it as the runtime
        // `ProtocolBox` extern struct regardless of which protocol
        // the box is statically typed as (the dispatch-time cast to
        // a concrete `<Protocol>VTable` is the consumption-site
        // concern, handled by Phase 1.2.5.d).
        .protocol_box => try buf.appendSlice(allocator, "zap_runtime.ProtocolBox"),
        .struct_ref => |name| {
            // The file-IS-the-struct emission lets us reach a
            // nominal type by importing its name. Phase 1.2.5.a
            // does not yet need to disambiguate parametric
            // specializations because protocol signatures in
            // 1.2.5.a are limited to bare nominal names.
            try buf.appendSlice(allocator, "@import(\"");
            try buf.appendSlice(allocator, name);
            try buf.appendSlice(allocator, "\")");
        },
        .tagged_union => |name| {
            try buf.appendSlice(allocator, "@import(\"");
            try buf.appendSlice(allocator, name);
            try buf.appendSlice(allocator, "\").");
            try buf.appendSlice(allocator, name);
        },
        // A closure type renders as a Zig function-pointer type
        // `*const fn(P...) Ret` — the runtime representation of a
        // non-capturing closure value.
        .function => |fn_type| {
            try buf.appendSlice(allocator, "*const fn (");
            for (fn_type.params, 0..) |param_type, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try appendZigTypeForVTable(allocator, buf, param_type);
            }
            try buf.appendSlice(allocator, ") ");
            // Phase 4 — a raising devirtualized closure's bare-fn-ptr type
            // carries the recoverable-raise error union on its return.
            try appendVTableReturnType(allocator, buf, fn_type.return_type.*, fn_type.raises);
        },
        // A Zap tuple renders as a Zig anonymous tuple type
        // `struct { T0, T1, ... }`. This is the representation of a
        // `Callable` method's `args` parameter (arity-as-tuple): a
        // one-arg `{i64}` becomes `struct { i64 }`, a two-arg
        // `{i64, String}` becomes `struct { i64, []const u8 }`, etc.
        // Rendering it here lets a tuple-typed protocol method slot (the
        // `call` slot of `Callable`) type-check against the per-impl
        // adapter — a non-empty tuple value unifies with such a slot via
        // Zig's structural positional-tuple coercion.
        //
        // The ZERO-element tuple `{}` (a zero-argument closure's `args`)
        // is special: a separately written `struct {}` gets a distinct
        // nominal identity at every emission site and the empty literal
        // `.{}` will not coerce into it. Render it as the single canonical
        // `zap_runtime.EmptyTuple` named type so the vtable slot, the
        // dispatch helper, the per-impl adapter, the impl's `args :: {}`
        // parameter, and the construction-site value all reference one
        // shared nominal type and unify. (`zap_runtime` is imported at the
        // top of every synthetic vtable source file.)
        .tuple => |elements| {
            if (elements.len == 0) {
                try buf.appendSlice(allocator, "zap_runtime.EmptyTuple");
            } else {
                try buf.appendSlice(allocator, "struct { ");
                for (elements, 0..) |elem, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try appendZigTypeForVTable(allocator, buf, elem);
                }
                try buf.appendSlice(allocator, " }");
            }
        },
        else => try buf.appendSlice(allocator, "anytype"),
    }
}

/// Render a protocol-method vtable slot's RETURN type, surfacing the
/// recoverable-raise error union when the (joined) method effect is raising.
/// Phase 4 (effect by inference): a boxed `Callable` whose instantiation
/// ADMITS a raiser dispatches through a `call` slot typed
/// `error{ZapRaise}!T`. The recoverable-raise plumbing models that union as
/// `anyerror!T` everywhere else (the fork's `set_error_union_return_type`
/// builds `error_union_type{anyerror, payload}`; `unwrap_error_union` at the
/// dispatch site unwraps an `anyerror` payload), so the vtable slot, the
/// dispatch helper, and every per-impl adapter render `anyerror!` + the
/// payload to stay ABI-compatible with the impl method's actual return and
/// with the call-site unwrap. A pure (`raises == false`) slot renders the
/// payload type unchanged — no spurious error union.
fn appendVTableReturnType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    zig_type: ir.ZigType,
    raises: bool,
) std.mem.Allocator.Error!void {
    if (raises) try buf.appendSlice(allocator, "anyerror!");
    try appendZigTypeForVTable(allocator, buf, zig_type);
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
        .i128 => @intFromEnum(Zir.Inst.Ref.i128_type),
        .u8 => @intFromEnum(Zir.Inst.Ref.u8_type),
        .u16 => @intFromEnum(Zir.Inst.Ref.u16_type),
        .u32 => @intFromEnum(Zir.Inst.Ref.u32_type),
        .u64 => @intFromEnum(Zir.Inst.Ref.u64_type),
        .u128 => @intFromEnum(Zir.Inst.Ref.u128_type),
        .usize => @intFromEnum(Zir.Inst.Ref.usize_type),
        .isize => @intFromEnum(Zir.Inst.Ref.isize_type),
        .f16 => @intFromEnum(Zir.Inst.Ref.f16_type),
        .f32 => @intFromEnum(Zir.Inst.Ref.f32_type),
        .f64 => @intFromEnum(Zir.Inst.Ref.f64_type),
        .f80 => @intFromEnum(Zir.Inst.Ref.f80_type),
        .f128 => @intFromEnum(Zir.Inst.Ref.f128_type),
        .string => @intFromEnum(Zir.Inst.Ref.slice_const_u8_type),
        .optional => 0,
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
        .i128 => @intFromEnum(Zir.Inst.Ref.i128_type),
        .u8 => @intFromEnum(Zir.Inst.Ref.u8_type),
        .u16 => @intFromEnum(Zir.Inst.Ref.u16_type),
        .u32 => @intFromEnum(Zir.Inst.Ref.u32_type),
        .u64 => @intFromEnum(Zir.Inst.Ref.u64_type),
        .u128 => @intFromEnum(Zir.Inst.Ref.u128_type),
        .usize => @intFromEnum(Zir.Inst.Ref.usize_type),
        .isize => @intFromEnum(Zir.Inst.Ref.isize_type),
        .f16 => @intFromEnum(Zir.Inst.Ref.f16_type),
        .f32 => @intFromEnum(Zir.Inst.Ref.f32_type),
        .f64 => @intFromEnum(Zir.Inst.Ref.f64_type),
        .f80 => @intFromEnum(Zir.Inst.Ref.f80_type),
        .f128 => @intFromEnum(Zir.Inst.Ref.f128_type),
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

/// True when the IR `instructions` slice's last instruction lowers to
/// a ZIR-level noreturn terminator unconditionally. The ZIR backend
/// uses this to decide whether to mark a captured branch body's
/// result ref as `unreachable_value` (the body never produces a value
/// the merge can consume) instead of `void_value`.
///
/// `tail_call` is intentionally NOT in this list — its noreturn-ness
/// is loopify-state-dependent and must be checked through
/// `instructionsEndNoReturnFor` (a method on ZirDriver) which has
/// access to `loopify_slots`.
fn instructionsEndNoReturn(instructions: []const ir.Instruction) bool {
    if (instructions.len == 0) return false;
    return switch (instructions[instructions.len - 1]) {
        .match_fail, .match_error_return, .ret_raise, .ret => true,
        else => false,
    };
}

pub const ZirDriver = struct {
    handle: *ZirBuilderHandle,
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, ValueRef),
    param_refs: std.ArrayListUnmanaged(u32),
    allocator: Allocator,
    program: ?ir.Program,
    lib_mode: bool = false,
    /// Phase 2.b — set true once a root `main` entry point has been
    /// emitted (executable output). Gates the injection of the root
    /// `pub const panic = @import("zap_runtime").ZapPanic;` declaration so
    /// it is emitted exactly for executables (which own the program-wide
    /// panic handler), never for library/object outputs or struct-only
    /// emission. See `emitRootPanicNamespace`.
    emitted_main_entry: bool = false,
    /// Phase 1.5 — per-optimize-mode arithmetic-overflow policy. When
    /// true (Debug / ReleaseSafe), integer arithmetic lowers to Zig's
    /// safety-checked tags (`add`/`sub`/`mul`) so overflow traps and
    /// routes to the runtime's `** (arithmetic_error) ...` abort. When
    /// false (ReleaseFast / ReleaseSmall), integer arithmetic lowers to
    /// the wrapping tags (`addwrap`/`subwrap`/`mulwrap`) so overflow
    /// wraps two's-complement with no trap. The build pipeline sets this
    /// from `FrontendOptimizeMode.arithmeticOverflowTraps`. Defaults to
    /// `true` (the safe default) so synthetic / test drivers trap.
    arithmetic_overflow_traps: bool = true,
    /// Reversible mangled-name ↔ Zap-symbol table populated as each
    /// IR function is emitted (see Phase 0 of the error-system
    /// roadmap). Owned by the driver; flushed to a sidecar
    /// `<artifact>.zap-symbols` file by the build path after
    /// linking finishes (`flushSymbolTable`). Lazy-initialized on
    /// the first `recordSymbolMapping` call so library / synthetic
    /// builds that never emit a function pay no memory cost.
    symbol_table_builder: ?zap_symbol_table.Builder = null,
    /// Builder entry point: when set, emits a `pub const zap_builder_entry`
    /// declaration pointing to this function. start.zig checks for this
    /// declaration to activate the builder runtime.
    builder_entry: ?[]const u8 = null,
    /// P2-J2 — true when the build resolved the `runtime_concurrency`
    /// gate ON (mirrors `compiler.RuntimeSourceControls.runtime_concurrency`;
    /// the backend derives it from the presence of the linked kernel
    /// object). For executable outputs this reroutes the program entry
    /// through the root-process bootstrap: the user's entry function is
    /// emitted under `root_process_main_decl_name` (prologue-free) and a
    /// synthetic `main` wrapper is emitted that runs the memory-startup
    /// prologue and then `zap_runtime.runRootProcessMain(<user entry>)`
    /// — user main becomes the ROOT PROCESS of the concurrency runtime
    /// (plan §2, P2-J1's "entry-process design" seam). OFF (the default)
    /// leaves entry emission byte-identical to the non-concurrent world.
    runtime_concurrency: bool = false,
    /// Set when the user's entry function was emitted under
    /// `root_process_main_decl_name` (see `runtime_concurrency`): carries
    /// the entry's mapped ZIR return type (0 = void, else the `u8` type
    /// ref) so `buildProgram`'s post-function pass can emit the matching
    /// synthetic `main` wrapper. Null when no wrapper is pending.
    pending_root_main_return_type: ?u32 = null,
    /// Optional incremental emission filter. When set, only these Zap struct
    /// modules are emitted; the synthetic root is emitted separately according
    /// to `selected_emit_root`.
    selected_structs: ?[]const []const u8 = null,
    selected_emit_root: bool = false,
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
    /// Arena for synthetic `ZigType` wrapper nodes created while rewriting
    /// recursive structs into pointer-backed storage/call-boundary shapes.
    /// The nodes are tiny, emission-scoped, and can all be released together
    /// when the driver is destroyed.
    type_rewrite_arena: ?std.heap.ArenaAllocator = null,
    /// ID of the function currently being emitted (for analysis lookups).
    current_function_id: ir.FunctionId = 0,
    /// Parameter ownership conventions for the function currently being emitted.
    current_function_param_conventions: []const ir.ParamConvention = &.{},
    /// Local ownership classes for the function currently being emitted.
    /// Release lowering uses this as the final type-blind guard against
    /// scheduling ARC runtime calls for locals that the IR classifies as
    /// trivial values.
    current_function_local_ownership: []const ir.OwnershipClass = &.{},
    /// Static Zig-level return type of the function currently being emitted.
    /// Used for generic constructors whose type variable appears only in
    /// the return position, so the call instruction itself may not carry
    /// enough information to recover `List(T)`.
    current_function_return_type: ir.ZigType = .void,
    /// True when the current function is a closure (has captures).
    current_function_is_closure: bool = false,
    /// When the function being emitted is a loopification candidate
    /// (`Function.loopify == true`), this holds one mutable-stack-slot
    /// pointer Ref per parameter. The function body is wrapped in a
    /// `loop` block: `param_get(i)` loads from `loopify_slots[i]`, and
    /// `tail_call` to self stores the new args back into the same
    /// slots and emits `repeat`. `null` outside loopification.
    loopify_slots: ?[]u32 = null,
    /// Nesting depth of capture contexts (case/switch/if-else bodies).
    /// When > 0, struct_init_typed can't be used because struct_init_field_type
    /// instructions (emitted via addInst) don't enter captured bodies.
    capture_depth: u32 = 0,
    /// Raw instruction indices of nested tuple_decls emitted untracked
    /// while constructing a tuple return type's element types. The outer
    /// `emitComplexReturnType` `.tuple` branch drains this list into the
    /// `support_inst_indices` it forwards to
    /// `set_tuple_return_type_with_body`. Without this, inner tuple_decls
    /// are emitted with no body membership and Sema can't find them when
    /// resolving the outer tuple_decl's operand refs.
    pending_ret_ty_untracked: std.ArrayListUnmanaged(u32) = .empty,
    /// Instruction index within the current block.
    current_instr_index: u32 = 0,
    current_block_instructions: []const ir.Instruction = &.{},
    skip_next_ret_local: ?ir.LocalId = null,
    /// Analysis results from the escape/region/ARC pipeline.
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext = null,
    /// Per-function ARC ownership tables produced by Phase 4 of the
    /// k-nucleotide RSS gap implementation plan. Each entry maps a
    /// `FunctionId` to the function's `ArcOwnership` table; lookup
    /// happens during `begin_function` so that the function's
    /// `return_source_locals` can be replayed into
    /// `arc_returned_locals`. The table itself is owned by the caller
    /// of `buildAndInject` (the compiler pipeline) — the driver only
    /// borrows it.
    arc_ownership: ?*const @import("arc_liveness.zig").ProgramArcOwnership = null,
    /// Memory Manager ABI v1.0 capability bitmask declared by the
    /// active manager (see `docs/memory-manager-abi.md` section 7).
    /// Set from `CompileOptions.declared_caps` so downstream codegen
    /// passes (Phase 6's retain/release elision, Phase 4's layout
    /// branch) can decide whether to emit refcount-aware instructions.
    /// Phase 3 wires the value through end-to-end without branching
    /// on it — the bit is present so later phases are purely additive.
    /// `0` means "no capabilities" (the default, e.g.
    /// `Memory.NoOp`); `1` (`REFCOUNT_V1_BIT`) means the manager
    /// supports the ARC retain/release contract.
    declared_caps: u64 = 0,
    reuse_backed_struct_locals: std.AutoHashMapUnmanaged(ir.LocalId, []const u8) = .empty,
    reuse_backed_union_locals: std.AutoHashMapUnmanaged(ir.LocalId, ir.UnionInit) = .empty,
    reuse_backed_tuple_locals: std.AutoHashMapUnmanaged(ir.LocalId, usize) = .empty,
    /// Locals whose ZIR ref holds a `runtime.Term` value. When a
    /// Term-typed local is used as an argument or assignment source
    /// for a concrete-typed slot, the materialiser inserts a
    /// `Term.to(T, term, default)` unwrap. Populated by call sites
    /// that resolve to `Map(K, Term).{get,...}` and other Term-
    /// returning runtime functions.
    term_typed_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    /// Locals known to alias the scrutinee parameter of a destructive
    /// optional-dispatch (per `AnalysisContext.destructive_optional_dispatch`).
    /// Tracked per-function: when `param_get`'s `index` matches the
    /// destructive scrutinee param, its `dest` local goes into this
    /// set. `field_get` reads of those locals on indirect-storage
    /// recursive fields skip the `retainAnyOpt` retain — under the
    /// destructive shape there's no second owner to balance against.
    destructive_scrutinee_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    type_store: ?*const @import("types.zig").TypeStore = null,
    /// Cached ZIR refs for List method functions, resolved once at function
    /// scope so they're available inside condbr bodies without re-importing.
    cached_list_cell_ref: u32 = 0,
    cached_list_gethead_ref: u32 = 0,
    cached_list_gettail_ref: u32 = 0,
    cached_list_slicefrom_ref: u32 = 0,
    cached_list_cons_ref: u32 = 0,
    cached_list_length_ref: u32 = 0,
    cached_list_get_ref: u32 = 0,
    capture_param_refs: std.ArrayListUnmanaged(u32) = .empty,
    current_closure_env_ref: ?u32 = null,
    /// Forward-propagating map from locals to closure function IDs.
    /// Populated by make_closure, propagated by local_set/local_get/move/share.
    /// Used by call_closure to resolve 0-capture closures to direct named calls.
    closure_function_map: std.AutoHashMapUnmanaged(ir.LocalId, ir.FunctionId) = .empty,
    /// Locals whose `share_value` retain was skipped (because the source
    /// was stack-eligible per escape analysis or otherwise didn't need
    /// reference-count tracking). The matching `.release` IR instruction
    /// must skip its decrement too — emitting an unpaired release would
    /// destroy a refcount that was never bumped, causing double-free.
    arc_share_skipped: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    /// Locals that are the source of a `ret` instruction; ownership
    /// flows to the caller's return slot, so the callee's scope-exit
    /// release is suppressed. Populated by phase 5.
    arc_returned_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    /// Set of every ARC-managed local in the currently-emitting
    /// function. Mirrored from `ArcOwnership.arc_managed_locals` at
    /// `emitFunction` start. Consulted by `shouldSkipArc` to enforce
    /// the invariant "ARC-managed locals are never stack-eligible
    /// regardless of escape state" — their cells are heap-pool
    /// allocated, so suppressing retain/release on the basis of
    /// `.no_escape` / `.function_local` would leak (or, with
    /// path-copy structures whose cells get recycled, cause UAF).
    arc_managed_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    /// Original ZIR refs captured immediately before a persistent retain
    /// rebinds a local to its independent owner. Aggregate-component releases
    /// must drop that original component owner, while later scope releases drop
    /// the current local binding.
    aggregate_component_original_refs: std.AutoHashMapUnmanaged(ir.LocalId, u32) = .empty,
    /// Forward-propagating set of locals whose value originated from a
    /// function parameter. When such a local is used as a call_closure callee,
    /// the runtime value may be either a bare function pointer or a closure
    /// struct; callCallableN handles both shapes.
    param_derived_closure_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,
    /// Maps (closure_function_id, capture_index) → captured closure function ID.
    /// When a closure captures another closure value, this allows the inner function's
    /// capture_get to propagate the closure_function_map across function boundaries.
    capture_closure_function_map: std.AutoHashMapUnmanaged(u64, ir.FunctionId) = .empty,
    /// Maps (closure_function_id, capture_index) for captured callable values
    /// whose runtime representation originated from a function parameter.
    capture_param_derived_closure_map: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Maps a devirtualized closure's `FunctionId` → the CONSTRUCTION-SITE
    /// `ZigType` of each of its captures (the actual representation of the
    /// value flowing into the env at the `make_closure` site), populated by a
    /// pre-pass over the whole IR program in `buildProgram`. The env-struct
    /// field types (`emitClosureEnvTypeDecls`) MUST match the env VALUE the
    /// `make_closure` lowering builds — but a capture's declared
    /// `Capture.type_expr` (the closure's SURFACE param type) does not always
    /// reflect boxing: a `fn(P) -> R`-typed binding whose runtime value is a
    /// boxed `Callable` carries a `.function` `type_expr` even though the value
    /// is a `ProtocolBox`. The construction site is authoritative — a capture
    /// local recorded in the OWNING function's `protocol_box_locals` is boxed
    /// (`.protocol_box`), regardless of its surface type. Keyed per closure;
    /// absent → fall back to the declared `Capture.type_expr`. Owned slices
    /// freed in `deinit`.
    closure_construction_capture_types: std.AutoHashMapUnmanaged(ir.FunctionId, []ir.ZigType) = .empty,
    /// Compilation context for per-struct ZIR injection.
    compilation_ctx: ?*ZirContext = null,
    /// Shared CLI progress reporter, owned by the command driver.
    progress: ?*progress_mod.Reporter = null,
    /// Struct currently being emitted (e.g., "IO", "Zest_Case"). Null when emitting root.
    current_emit_struct: ?[]const u8 = null,

    const ValueRef = union(enum) {
        /// Already-materialized ZIR instruction ref
        inst: u32,
        /// Declaration reference (materialized lazily via decl_ref or @import)
        decl: struct {
            struct_name: ?[]const u8, // null => current struct
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
        self.deinitOwnedState();
    }

    fn deinitAfterHandleConsumed(self: *ZirDriver) void {
        self.deinitOwnedState();
    }

    fn deinitOwnedState(self: *ZirDriver) void {
        self.local_refs.deinit(self.allocator);
        self.param_refs.deinit(self.allocator);
        self.closure_function_map.deinit(self.allocator);
        self.arc_share_skipped.deinit(self.allocator);
        self.arc_returned_locals.deinit(self.allocator);
        self.arc_managed_locals.deinit(self.allocator);
        self.aggregate_component_original_refs.deinit(self.allocator);
        self.param_derived_closure_locals.deinit(self.allocator);
        self.capture_closure_function_map.deinit(self.allocator);
        self.capture_param_derived_closure_map.deinit(self.allocator);
        {
            var cct_iter = self.closure_construction_capture_types.valueIterator();
            while (cct_iter.next()) |slice_ptr| self.allocator.free(slice_ptr.*);
            self.closure_construction_capture_types.deinit(self.allocator);
        }
        self.reuse_backed_struct_locals.deinit(self.allocator);
        self.term_typed_locals.deinit(self.allocator);
        self.destructive_scrutinee_locals.deinit(self.allocator);
        self.reuse_backed_union_locals.deinit(self.allocator);
        self.reuse_backed_tuple_locals.deinit(self.allocator);
        self.capture_param_refs.deinit(self.allocator);
        self.pending_ret_ty_untracked.deinit(self.allocator);
        if (self.type_rewrite_arena) |*arena| arena.deinit();
        if (self.symbol_table_builder) |*sym| sym.deinit();
    }

    /// Record one Zap → Zig mangled-name mapping in the side table.
    /// Called from `emitFunction` for every Zap function the ZIR
    /// driver hands to the fork. Lazy-initializes the underlying
    /// builder on first use so library builds without functions pay
    /// no cost.
    ///
    /// `mangled` is the Zig declaration name the linker will see
    /// (typically `<struct_path>.<local_name>`); for the entry-point
    /// rewrite to `main` we record both that the Zap function is
    /// owned by some struct (`zap_struct`) *and* that the linker
    /// will publish the symbol as `main` — the reverse lookup from
    /// `main` then resolves to the original Zap function.
    fn recordSymbolMapping(
        self: *ZirDriver,
        mangled: []const u8,
        func: ir.Function,
    ) !void {
        if (self.symbol_table_builder == null) {
            self.symbol_table_builder = zap_symbol_table.Builder.init(self.allocator);
        }
        const local = if (func.local_name.len > 0) func.local_name else func.name;
        const stripped = zap_symbol_table.Builder.stripAritySuffix(local);
        const arity: u32 = stripped.arity orelse func.arity;
        try self.symbol_table_builder.?.record(mangled, func.struct_name, stripped.base, arity);
    }

    /// Encode the accumulated symbol table to its canonical binary
    /// form. Returns an owned `[]u8` (caller must free). Returns
    /// `null` when no mappings were recorded — a library build, an
    /// entry-only stub, or a misuse like calling this before any
    /// `emitFunction`. Callers that want a deterministic empty blob
    /// can synthesize one via `zap_symbol_table.Builder.init` +
    /// `encode`.
    pub fn encodeSymbolTable(self: *ZirDriver) !?[]u8 {
        const builder = if (self.symbol_table_builder) |*b| b else return null;
        if (builder.entries.items.len == 0) return null;
        return try builder.encode();
    }

    /// Mark a local whose ownership was transferred into the function's
    /// return slot. The matching scope-exit release for this local
    /// must be suppressed because the caller now owns the value.
    /// Phase 5 wires the call site that populates this set; phase 3
    /// introduces the marker so the release filter is symmetric and
    /// downstream phases only have to add the producer, not the seam.
    pub fn markReturned(self: *ZirDriver, local: ir.LocalId) !void {
        try self.arc_returned_locals.put(self.allocator, local, {});
    }

    /// True when a `.release` IR instruction targeting `local` should
    /// be suppressed by the lowering. Two causes, both of which leave
    /// the value's refcount unchanged from the caller's perspective:
    ///   1. Escape analysis decided the matching `share_value` retain
    ///      was unnecessary — `arc_share_skipped`.
    ///   2. The local is the source of the function's `ret`, so
    ///      ownership flows to the caller — `arc_returned_locals`.
    ///
    /// Note: `share_value(.consume)` is NOT a release-suppression
    /// cause. Consume mode is purely an "elide the retain" optimization
    /// for the caller-side share — it relies on the source local being
    /// at its last use so no extra refcount bump is needed. The
    /// post-call `.release` IR instruction targeting the per-call
    /// shared dest local must still fire so that the cell's refcount
    /// is decremented; the callee borrows the value but does not
    /// consume it. Suppressing the post-call release here would leak
    /// the cell on every consume-mode share. (See the consume-mode
    /// branch in the share_value lowering for the full reasoning.)
    pub fn isReleaseSuppressed(self: *const ZirDriver, local: ir.LocalId) bool {
        return self.arc_share_skipped.contains(local) or
            self.arc_returned_locals.contains(local);
    }

    /// Cancel the provisional `arc_share_skipped` release-suppression for a
    /// local that a `.persistent` retain just cloned into an independent owner
    /// via `shareAnyPersistent`. ONLY meaningful under `clone_on_share_active`:
    /// there `shouldSkipArc` is unconditionally true, so the `copy_value`
    /// handler provisionally suppresses every dest's release; a dest that
    /// actually CLONES is a genuine new owner whose release must fire (else the
    /// clone leaks), so it is removed here. A no-op under every other model —
    /// under REFCOUNTED an entry in `arc_share_skipped` marks a genuinely
    /// escape-elided retain whose release MUST stay suppressed, so this must
    /// NOT touch it; the `clone_on_share_active` guard guarantees that.
    fn unmarkShareSkippedForClone(self: *ZirDriver, local: ir.LocalId) void {
        if (!self.cloneOnShareActive()) return;
        _ = self.arc_share_skipped.remove(local);
    }

    /// Check if a function contains tail calls to itself (via IR tail_call instructions).
    /// The IR builder already detects and marks tail-recursive calls as tail_call.
    /// Check if ARC operations should be skipped for a value.
    /// Only skips when the value was explicitly analyzed and found stack-eligible.
    /// Tag `pg.dest` as a destructive-scrutinee local when the function
    /// is in the destructive-optional-dispatch set and `pg.index` matches
    /// its scrutinee param. The `field_get` retain emitter consults this
    /// set to decide whether to skip `retainAnyOpt` on indirect-storage
    /// recursive field reads of this local.
    fn markDestructiveScrutineeIfApplicable(self: *ZirDriver, pg: ir.ParamGet) !void {
        const actx = self.analysis_context orelse return;
        const dscrut = actx.destructive_optional_dispatch.get(self.current_function_id) orelse return;
        if (pg.index != dscrut) return;
        if (self.currentParamConvention(pg.index) != .owned) return;
        try self.destructive_scrutinee_locals.put(self.allocator, pg.dest, {});
    }

    fn currentParamConvention(self: *const ZirDriver, param_index: u32) ir.ParamConvention {
        if (param_index >= self.current_function_param_conventions.len) return .trivial;
        return self.current_function_param_conventions[param_index];
    }

    fn shouldSkipArc(self: *const ZirDriver, local: ir.LocalId) bool {
        // Phase 6: when the active manager does not declare REFCOUNT_V1
        // the compiler statically elides every retain/release call
        // (spec §8.5). The skip is unconditional in that mode — escape
        // analysis and the ARC-managed-locals invariant only matter
        // when refcount ops are being emitted in the first place.
        //
        // Phase 4.c box-in-struct fix: the `.release` ZIR handler makes a
        // SEPARATE, type-aware decision for the no-REFCOUNT_V1 deep-walk
        // case (via `ir.Release.deep_walk_owned_heap_child`); see the
        // handler. This predicate stays unconditional so retain sites and
        // the rest of the elision logic are unaffected.
        if (!elision.shouldEmitRefcountOps(self.declared_caps)) return true;

        // ARC-managed types live on heap pools and must always
        // participate in retain/release. The escape lattice's
        // `.no_escape` / `.function_local` classifications describe
        // pointer flow, not allocation-site placement — for these
        // types, the cell is heap-allocated regardless. Skipping
        // ARC operations here would (a) leak the pool cell when the
        // function exits, and (b) for path-copy mutable structures
        // whose pool cells get recycled, cause use-after-free when a
        // reused cell is observed by another spine that still holds
        // a stale alias. Refuse the skip at the source.
        if (self.arc_managed_locals.contains(local)) return false;

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

    /// Phase 6 codegen-elision predicate (see `src/memory/elision.zig`).
    /// Returns `true` when the active manager declares `REFCOUNT_V1`
    /// and refcount-aware instructions should be emitted at retain /
    /// release / freeAny / prepareReleaseAny / destroyPreparedAny /
    /// resetAny / reuseAllocByType / noteConsume / noteReturnElision
    /// call sites.
    ///
    /// Call this from emission sites that aren't already routed through
    /// `shouldSkipArc` (which folds the elision check into the local-
    /// keyed skip decision). Sites that emit a ZIR call to one of the
    /// `ArcRuntime` helpers must check this — under a manager that does
    /// not declare REFCOUNT_V1 the call's target (`ArcRuntime.retainAny`
    /// etc.) would `@panic` at runtime per the spec's capability-
    /// missing panic contract.
    fn shouldEmitRefcountOps(self: *const ZirDriver) bool {
        return elision.shouldEmitRefcountOps(self.declared_caps);
    }

    /// The active manager's reclamation model (Axis A), decoded from
    /// `declared_caps` via the single source of truth in
    /// `src/memory/elision.zig`. Codegen sites on the no-refcount path use
    /// this to split three-way — `.bulk_or_never` (and `.traced`) elide every
    /// individual free / deep-walk, `.individual_no_refcount` (Tracking) keeps
    /// the individual-free + deep-walk emission — never keying off a manager
    /// name.
    fn reclamationModel(self: *const ZirDriver) elision.ReclamationModel {
        return elision.reclamationModel(self.declared_caps);
    }

    /// The active manager's sharing strategy (Axis B), decoded via the single
    /// source of truth in `src/memory/elision.zig`. Only consulted when
    /// `reclamationModel() == .individual_no_refcount`; codegen uses it to
    /// decide whether a persistent share clones (`clone_on_share`) or is a
    /// move-only compile error upstream (`move_only`) — never keying off a
    /// manager name.
    fn sharingStrategy(self: *const ZirDriver) elision.SharingStrategy {
        return elision.sharingStrategy(self.declared_caps);
    }

    /// Comptime-equivalent of the runtime `clone_on_share_active`: true when a
    /// persistent second owner must receive an independent deep CLONE rather
    /// than an aliasing (elided) retain — ONLY under `individual_no_refcount`
    /// with the `clone_on_share` sharing strategy. The single gate the
    /// value-level clone-on-share emission (`emit_share_under_clone_on_share`
    /// in the `.retain` handler) keys off, mirroring the runtime
    /// `shareAnyPersistent` comptime gate so the ZIR emission and the runtime
    /// helper agree on exactly when a share clones.
    fn cloneOnShareActive(self: *const ZirDriver) bool {
        return self.reclamationModel() == .individual_no_refcount and
            self.sharingStrategy() == .clone_on_share;
    }

    // -- Helpers --------------------------------------------------------------

    /// Map an IR ZigType to a ZIR Ref, recursively emitting tuple_decl for nested tuples.
    /// Used for declaration-body tuple_decl (param-like instructions). Falls
    /// back to the full `emitImportedTypeRef` path for complex non-tuple
    /// types (lists, maps, struct_ref, etc.) — without that fallback,
    /// `mapReturnType` returns 0 for complex types, leaving the outer
    /// tuple_decl with a null operand that crashes Sema's `resolveInst`.
    fn mapTupleElementType(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        if (zig_type == .tuple) {
            // The zero-element tuple resolves to the canonical
            // `zap_runtime.EmptyTuple` named type (one shared nominal
            // identity), not a fresh 0-field `tuple_decl`. Track the
            // import-field's inst index so the caller hoists it into the
            // surrounding ret_ty/param support body, mirroring the
            // non-empty tuple_decl tracking below.
            if (zig_type.tuple.len == 0) {
                const empty_ref = try self.emitEmptyTupleTypeRef();
                const idx = zir_builder_ref_to_inst_index(self.handle, empty_ref);
                if (idx != 0xFFFFFFFF) {
                    try self.pending_ret_ty_untracked.append(self.allocator, idx);
                }
                return empty_ref;
            }
            var inner_refs: std.ArrayListUnmanaged(u32) = .empty;
            defer inner_refs.deinit(self.allocator);
            for (zig_type.tuple) |inner_elem| {
                try inner_refs.append(self.allocator, try self.mapTupleElementType(inner_elem));
            }
            // Emit *untracked* — `zir_builder_emit_tuple_decl` would
            // append to `param_inst_indices`, which then makes Sema's
            // generic-call param resolver hit `unreachable` because the
            // param body now has a `.extended` instruction where it
            // expects `.param*` tags. The outer call routes the resulting
            // tuple_decl Ref into the ret_ty body via
            // `set_tuple_return_type_with_body`. Track the raw inst index
            // so the caller can include it in support_inst_indices.
            const ref = zir_builder_emit_tuple_decl_untracked(self.handle, inner_refs.items.ptr, @intCast(inner_refs.items.len));
            if (ref == error_ref) return error.EmitFailed;
            const idx = zir_builder_ref_to_inst_index(self.handle, ref);
            if (idx != 0xFFFFFFFF) {
                try self.pending_ret_ty_untracked.append(self.allocator, idx);
            }
            return ref;
        }
        const simple = mapReturnType(zig_type);
        if (simple != 0) return simple;
        return try self.emitImportedTypeRef(zig_type);
    }

    /// Collect nested tuple types in DFS post-order (inner-first).
    /// This matches the order in which tuple_init IR instructions are emitted.
    fn collectNestedTupleTypes(self: *ZirDriver, zig_type: ir.ZigType) BuildError!void {
        if (zig_type != .tuple) return;
        // Visit children first (inner tuples emitted before outer)
        for (zig_type.tuple) |elem| {
            try self.collectNestedTupleTypes(elem);
        }
        // Then add this tuple type
        try self.tuple_type_stack.append(self.allocator, zig_type);
    }

    /// Emit a body-local tuple_decl, recursively handling nested tuples.
    /// Returns the Ref to the emitted tuple_decl instruction. Falls back to
    /// `emitImportedTypeRef` for complex non-tuple types so list/map/struct_ref
    /// elements get a real ZIR ref instead of `mapReturnType`'s 0 fallback.
    fn emitBodyLocalTupleType(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        if (zig_type != .tuple) {
            const simple = mapReturnType(zig_type);
            if (simple != 0) return simple;
            return try self.emitImportedTypeRef(zig_type);
        }
        // The zero-element tuple resolves to the canonical
        // `zap_runtime.EmptyTuple` named type so a body-local empty tuple
        // shares the same nominal identity as the param/return/vtable
        // positions.
        if (zig_type.tuple.len == 0) {
            return try self.emitEmptyTupleTypeRef();
        }
        var inner_refs: std.ArrayListUnmanaged(u32) = .empty;
        defer inner_refs.deinit(self.allocator);
        for (zig_type.tuple) |inner_elem| {
            try inner_refs.append(self.allocator, try self.emitBodyLocalTupleType(inner_elem));
        }
        const ref = zir_builder_emit_tuple_decl_body(self.handle, inner_refs.items.ptr, @intCast(inner_refs.items.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn setLocal(self: *ZirDriver, local: ir.LocalId, ref: u32) !void {
        try self.local_refs.put(self.allocator, local, .{ .inst = ref });
    }

    fn setLocalDecl(self: *ZirDriver, local: ir.LocalId, struct_name: ?[]const u8, decl_name: []const u8) !void {
        try self.local_refs.put(self.allocator, local, .{ .decl = .{ .struct_name = struct_name, .decl_name = decl_name } });
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

    fn discardCapture(self: *ZirDriver) void {
        var discard_len: u32 = 0;
        _ = self.endCapture(&discard_len);
    }

    /// Phase E.7: classify whether `instructions` ends in a ZIR-level
    /// noreturn terminator, accounting for loopify state.
    ///
    /// In addition to the unconditional noreturn shapes captured by
    /// `instructionsEndNoReturn` (`.match_fail`, `.match_error_return`,
    /// `.ret`), a trailing `.tail_call` is noreturn ONLY when the
    /// musttail lowering path is in effect — that path emits `musttail
    /// call + ret` for the tail call, so the captured ZIR body ends
    /// with a `ret`. In the loopify path the same `.tail_call` IR
    /// emits stores to mutable parameter slots and falls through; the
    /// captured body is NOT noreturn at the ZIR level (the wrapping
    /// `loop` block's trailing `repeat` carries control back).
    ///
    /// Used by `emitIfExpr` and `emitSwitchLiteral` to pick the
    /// correct branch-result ref when the IR sets `result = null` for
    /// a tail-call-rewritten arm. Sema accepts `unreachable_value`
    /// from a body that genuinely never produces a value, but
    /// disagrees with `void_value` when the body actually ends in
    /// `ret` (it sees the `ret` as a hard exit and the void claim as
    /// dead code).
    fn instructionsEndNoReturnFor(self: *const ZirDriver, instructions: []const ir.Instruction) bool {
        if (instructions.len == 0) return false;
        return switch (instructions[instructions.len - 1]) {
            .match_fail, .match_error_return, .ret_raise, .ret => true,
            .tail_call => self.loopify_slots == null,
            else => false,
        };
    }

    /// Map Zap-facing struct names to runtime struct names. Each Zap
    /// struct (IO, Integer, Float, etc.) maps 1:1 to the runtime
    /// struct of the same name — the call site can pass `mod_name`
    /// straight through to `field_val`.
    /// Emit a `zap_runtime.ArcRuntime.reuseAllocByType(type_ref,
    /// alloc_ref, token_ref)` runtime call. Single source for every
    /// `reuseAllocByType` ZIR emission in the driver — the
    /// canonical `.reuse_alloc` IR handler and the construction-
    /// instruction reuse paths (`tuple_init` / `struct_init` /
    /// `union_init` with `reuse_token` set) all route through this
    /// helper so the V10 audit catalogues a single emission site
    /// instead of one per consumer.
    fn emitReuseAllocCall(self: *ZirDriver, type_ref: u32, token_ref: u32) BuildError!u32 {
        const alloc_ref = try self.emitAllocatorRef();
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
        if (arc_runtime == error_ref) return error.EmitFailed;
        const reuse_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "reuseAllocByType", 16);
        if (reuse_fn == error_ref) return error.EmitFailed;
        const args = [_]u32{ type_ref, alloc_ref, token_ref };
        const ref = zir_builder_emit_call_ref(self.handle, reuse_fn, &args, 3);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a reference to `zap_runtime.ArcRuntime.ReuseToken.none` — the
    /// null reuse token. `reuseAllocByType` now takes a sized
    /// `ReuseToken` (carrying the reset cell's byte footprint so it can
    /// refuse to overflow a too-small cell), so the no-token construction
    /// path must hand it the canonical empty token rather than `void`.
    fn emitReuseTokenNone(self: *ZirDriver) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
        if (arc_runtime == error_ref) return error.EmitFailed;
        const token_ty = zir_builder_emit_field_val(self.handle, arc_runtime, "ReuseToken", 10);
        if (token_ty == error_ref) return error.EmitFailed;
        const none_ref = zir_builder_emit_field_val(self.handle, token_ty, "none", 4);
        if (none_ref == error_ref) return error.EmitFailed;
        return none_ref;
    }

    fn emitMemoryStartupForEntryFromRuntime(self: *ZirDriver, rt_import: u32) BuildError!void {
        const startup_fn = zir_builder_emit_field_val(self.handle, rt_import, "memoryStartupForEntry", 21);
        if (startup_fn == error_ref) return error.EmitFailed;
        const empty_args: [0]u32 = .{};
        const startup_call = zir_builder_emit_call_ref(self.handle, startup_fn, &empty_args, 0);
        if (startup_call == error_ref) return error.EmitFailed;
    }

    fn emitMemoryStartupForEntry(self: *ZirDriver) BuildError!void {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        try self.emitMemoryStartupForEntryFromRuntime(rt_import);
    }

    /// P2-J2 — emit the synthetic `main` of a gated-on executable:
    ///
    ///   fn main() <ret> {
    ///       zap_runtime.memoryStartupForEntry();
    ///       return zap_runtime.runRootProcessMain(zap_root_process_main);
    ///   }
    ///
    /// The prologue runs on the driver thread's OS stack (memory manager
    /// bind + concurrency runtime init, LIFO atexit registration), then
    /// `runRootProcessMain` spawns the user entry as the ROOT PROCESS and
    /// drives the scheduler until it exits (`src/runtime.zig` documents
    /// the Erlang halt semantics). `root_main_return_type` is the mapped
    /// return type of the user entry (0 = void, else `u8`), which the
    /// wrapper mirrors — `runRootProcessMain` is comptime-generic over
    /// exactly those two shapes.
    fn emitRootProcessMainWrapper(self: *ZirDriver, root_main_return_type: u32) BuildError!void {
        const wrapper_name = "main";
        if (zir_builder_begin_func(self.handle, wrapper_name.ptr, @intCast(wrapper_name.len), root_main_return_type) != 0) {
            return error.BeginFuncFailed;
        }

        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        try self.emitMemoryStartupForEntryFromRuntime(rt_import);

        const run_root_fn = zir_builder_emit_field_val(self.handle, rt_import, "runRootProcessMain", 18);
        if (run_root_fn == error_ref) return error.EmitFailed;
        const user_entry_ref = zir_builder_emit_decl_val(
            self.handle,
            root_process_main_decl_name.ptr,
            @intCast(root_process_main_decl_name.len),
        );
        if (user_entry_ref == error_ref) return error.EmitFailed;
        const run_args = [_]u32{user_entry_ref};
        const run_result = zir_builder_emit_call_ref(self.handle, run_root_fn, &run_args, 1);
        if (run_result == error_ref) return error.EmitFailed;

        if (root_main_return_type == 0) {
            if (zir_builder_emit_ret_void(self.handle) != 0) return error.EmitFailed;
        } else {
            if (zir_builder_emit_ret(self.handle, run_result) != 0) return error.EmitFailed;
        }
        if (zir_builder_end_func(self.handle) != 0) return error.EndFuncFailed;
    }

    /// Phase 2.b — inject `pub const panic = @import("zap_runtime").ZapPanic;`
    /// into the root struct's namespace.
    ///
    /// Zig's panic interface is `std.builtin.panic = if (@hasDecl(root,
    /// "panic")) root.panic else FullPanic(defaultPanic)`, and `@hasDecl`
    /// resolves against the *injected* root ZIR's struct namespace (the
    /// on-disk stub source's ZIR is discarded). Without this declaration the
    /// root carries no `panic`, so every Zig-level safety check (integer
    /// divide-by-zero, `unreachable`, null-unwrap, non-Zap slice bounds,
    /// `@panic`, …) falls through to Zig's default panic handler — printing
    /// Zig's text and a Zig stdlib backtrace instead of the unified Zap
    /// crash report.
    ///
    /// `runtime.ZapPanic` is a `FullPanic`-shaped namespace whose handlers
    /// route to `Runtime.crashReport`, mapping each cause to a Zap error
    /// kind (`arithmetic_error` / `index_error` / `runtime_error`). The
    /// declaration's value body is `@import("zap_runtime").ZapPanic`,
    /// recorded between `begin_const_decl` / `end_const_decl` so it lands in
    /// the root struct_decl's `decls`.
    ///
    /// Only meaningful for executable outputs: the panic namespace governs
    /// the program-wide panic handler, which a library/object output does
    /// not own. `emitFunction` always closes its function body, so
    /// `active_body` is null here (the const-decl recorder requires that).
    fn emitRootPanicNamespace(self: *ZirDriver) BuildError!void {
        const decl_name = "panic";
        if (zir_builder_begin_const_decl(self.handle, decl_name.ptr, @intCast(decl_name.len)) != 0) {
            return error.EmitFailed;
        }

        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;

        const zap_panic_field = "ZapPanic";
        const zap_panic_ref = zir_builder_emit_field_val(
            self.handle,
            rt_import,
            zap_panic_field.ptr,
            @intCast(zap_panic_field.len),
        );
        if (zap_panic_ref == error_ref) return error.EmitFailed;

        if (zir_builder_end_const_decl(self.handle, zap_panic_ref) != 0) {
            return error.EmitFailed;
        }
    }

    fn emitAllocatorRef(self: *ZirDriver) BuildError!u32 {
        // `std.heap.c_allocator` is malloc-backed: ~32 byte per-allocation
        // overhead, vs. `std.heap.page_allocator`'s full OS-page rounding
        // (16 KB on Apple Silicon, 4 KB on x86_64). Each Arc node is ~24
        // bytes; routing through `page_allocator` made every recursive-
        // struct allocation effectively cost a page, so `binarytrees N=21`
        // (≈ 600 M transient nodes peak) couldn't fit in any reasonable
        // RAM budget regardless of how perfectly the deep-release pass
        // reclaimed memory. Zap binaries already link libc unconditionally
        // (`main.zig` builds with `link_libc = true`), so `c_allocator` is
        // always available.
        const std_import = zir_builder_emit_import(self.handle, "std", 3);
        if (std_import == error_ref) return error.EmitFailed;
        const heap_mod = zir_builder_emit_field_val(self.handle, std_import, "heap", 4);
        if (heap_mod == error_ref) return error.EmitFailed;
        const alloc_ref = zir_builder_emit_field_val(self.handle, heap_mod, "c_allocator", 11);
        if (alloc_ref == error_ref) return error.EmitFailed;
        return alloc_ref;
    }

    fn emitTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        return switch (zig_type) {
            .tuple => try self.emitBodyLocalTupleType(zig_type),
            // A closure type lowers to `*const fn(P...) Ret` — the
            // runtime representation of a non-capturing closure value.
            .function => |fn_type| try self.emitFuncPtrTypeRef(fn_type),
            else => blk: {
                const ref = mapReturnType(zig_type);
                if (ref == @intFromEnum(Zir.Inst.Ref.none)) return error.EmitFailed;
                break :blk ref;
            },
        };
    }

    /// Resolve a closure type `fn() -> Ret` / `fn(P...) -> Ret` to a ZIR
    /// `*const fn(P...) Ret` type ref. This is the runtime representation
    /// of a NON-capturing (0-capture) Zap closure value (a bare function
    /// pointer); the ZIR backend uses it at every concrete-type position
    /// (struct field, function return type, tuple element) where the
    /// param-position `anytype` lowering can't be used. The param and
    /// return type Refs must be resolved into the SAME body the func-ptr
    /// type is emitted into (the fork's `addFuncPtrType` nests its
    /// `param`/`func`/`break_inline` instructions inside the type's
    /// `block_inline`), so primitive Refs (well-known, body-independent)
    /// are used directly and complex element types are emitted inline via
    /// `emitImportedTypeRef`.
    fn emitFuncPtrTypeRef(self: *ZirDriver, fn_type: ir.ZigType.FnType) BuildError!u32 {
        var param_refs: std.ArrayListUnmanaged(u32) = .empty;
        defer param_refs.deinit(self.allocator);
        for (fn_type.params) |param_type| {
            try param_refs.append(self.allocator, try self.emitClosureSignatureTypeRef(param_type));
        }
        const payload_ret_ref = try self.emitClosureSignatureTypeRef(fn_type.return_type.*);
        // Phase 4 — a RAISING devirtualized closure's bare-fn-ptr type renders
        // `*const fn(P...) anyerror!T`: wrap the payload return in the
        // recoverable-raise error union so the lifted `call` method's actual
        // `anyerror!T` return matches the slot and the call site unwraps. A
        // pure closure (`raises == false`) keeps the plain payload return — no
        // spurious error union, the zero-overhead devirtualized shape is
        // unchanged.
        const ret_ref = if (fn_type.raises) blk: {
            const eu = zir_builder_emit_error_union_type(
                self.handle,
                @intFromEnum(Zir.Inst.Ref.anyerror_type),
                payload_ret_ref,
            );
            if (eu == error_ref) return error.EmitFailed;
            break :blk eu;
        } else payload_ret_ref;
        const ref = zir_builder_emit_func_ptr_type(
            self.handle,
            param_refs.items.ptr,
            @intCast(param_refs.items.len),
            ret_ref,
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Resolve a single closure-signature component (a parameter type or
    /// the return type) to a ZIR type Ref. Primitives map to well-known
    /// Refs; a bare `void` return maps to the well-known `void_type` Ref
    /// (a `fn() -> i64`-style closure always has a concrete return, but a
    /// nested `void` element must still resolve); everything else is
    /// emitted inline via `emitImportedTypeRef` so its support
    /// instructions land in the func-ptr type's body.
    fn emitClosureSignatureTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        if (zig_type == .void) return @intFromEnum(Zir.Inst.Ref.void_type);
        const simple = mapReturnType(zig_type);
        if (simple != 0) return simple;
        return try self.emitImportedTypeRef(zig_type);
    }

    fn emitClosureEnvParam(self: *ZirDriver, captures: []const ir.Capture) BuildError!u32 {
        if (captures.len == 0) {
            const ref = zir_builder_emit_param(self.handle, "__closure_env".ptr, 13, @intFromEnum(Zir.Inst.Ref.none));
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        }

        var env_name_buf: [64]u8 = undefined;
        const env_name = try self.closureEnvTypeName(self.current_function_id, &env_name_buf);
        const ref = zir_builder_emit_param_decl_val_type(
            self.handle,
            "__closure_env".ptr,
            13,
            env_name.ptr,
            @intCast(env_name.len),
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn emitClosureEnvTypeRefForTarget(self: *ZirDriver, target_func: ir.Function) BuildError!u32 {
        var env_name_buf: [64]u8 = undefined;
        const env_name = try self.closureEnvTypeName(target_func.id, &env_name_buf);
        const target_struct = target_func.struct_name;
        const is_cross = blk: {
            if (target_struct == null and self.current_emit_struct == null) break :blk false;
            if (target_struct == null or self.current_emit_struct == null) break :blk true;
            break :blk !self.currentStructMatches(target_struct.?);
        };
        if (is_cross and target_struct != null) {
            return try self.emitCrossStructRef(target_struct.?, env_name);
        }
        const ref = zir_builder_emit_decl_val(self.handle, env_name.ptr, @intCast(env_name.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Resolve any Zap type to a ZIR type ref for use inside compound type
    /// declarations (e.g., tuple element types). Emits import instructions
    /// for complex types that need runtime type resolution.
    /// Phase 3.b — emit `@as(T, undefined)` and return its Ref. Used as the
    /// never-read catch value on the dead error edge of a `route_to_handler`
    /// error-union unwrap (the enclosing `try` landing pad takes the error
    /// path; this value only gives the `catch` block a clean peer type).
    fn emitTypedUndefRef(self: *ZirDriver, payload_type: ir.ZigType) BuildError!u32 {
        const ty_ref = try self.emitImportedTypeRef(payload_type);
        const ref = zir_builder_emit_as(self.handle, ty_ref, @intFromEnum(Zir.Inst.Ref.undef));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit the catch value for a `route_to_handler` error-union unwrap.
    ///
    /// On the error edge the unwrapped payload is NEVER read — the boxed error
    /// is in the TLS side-channel and the enclosing `try`'s landing pad takes
    /// over via the following `raise_occurred()` check. The straight-line try-
    /// body remainder (a `local_set` of this dest, then the dispatch `if`) still
    /// EXECUTES on the error path before the landing pad fires, and a dead
    /// ARC-managed local bound to this value gets a scope-exit release. So the
    /// catch value MUST be release-safe — `@as(T, undefined)` is a garbage
    /// non-null pointer whose `release` dereferences a bogus ArcHeader (observed
    /// as a bus_error in `List(T).release` when a `for`-comprehension list in a
    /// `try` body is released on the raise path). For ARC-managed payloads we
    /// therefore emit a canonical EMPTY value whose release is a no-op:
    ///   * `List(T)` / `Map(K,V)` → `.empty()` (the null cell pointer; the
    ///     runtime `release(null)` returns early).
    ///   * `?T` / `*const T` (recursive-struct storage) → `null`.
    ///   * `ProtocolBox` → a zeroed box (`data_ptr`/`vtable` both null; the
    ///     runtime `releaseProtocolBoxValue` no-ops on a null `data_ptr`).
    /// Non-ARC scalar payloads are never released, so `@as(T, undefined)` is
    /// still correct (and avoids needless instructions) for them.
    fn emitReleaseSafeCatchValue(self: *ZirDriver, payload_type: ir.ZigType) BuildError!u32 {
        switch (payload_type) {
            .list => {
                const list_cell = try self.emitListCellRef(getListElementType(payload_type));
                const empty_fn = zir_builder_emit_field_val(self.handle, list_cell, "empty", 5);
                if (empty_fn == error_ref) return error.EmitFailed;
                const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                if (empty_val == error_ref) return error.EmitFailed;
                return empty_val;
            },
            .map => |mt| {
                const map_cell = try self.emitMapCellRef(mt.key.*, mt.value.*);
                const empty_fn = zir_builder_emit_field_val(self.handle, map_cell, "empty", 5);
                if (empty_fn == error_ref) return error.EmitFailed;
                const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                if (empty_val == error_ref) return error.EmitFailed;
                return empty_val;
            },
            .optional, .ptr => {
                // A nullable pointer slot: `@as(?T, null)` / a recursive-struct
                // `?*const T` storage slot. `null` releases as a no-op.
                const ty_ref = try self.emitImportedTypeRef(payload_type);
                const ref = zir_builder_emit_as(self.handle, ty_ref, @intFromEnum(Zir.Inst.Ref.null_value));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .protocol_box => {
                // A zeroed `ProtocolBox` ({data_ptr: null, vtable: null}); the
                // runtime's box release no-ops on a null inner data pointer.
                return try self.emitZeroedProtocolBox();
            },
            else => return try self.emitTypedUndefRef(payload_type),
        }
    }

    /// Emit a zeroed `runtime.ProtocolBox` value —
    /// `ProtocolBox{ .data_ptr = null, .vtable = null }`. Used as the
    /// release-safe catch value on a `route_to_handler` unwrap whose payload is
    /// a protocol existential (see `emitReleaseSafeCatchValue`); the runtime's
    /// box release is null-guarded on `data_ptr`, so a null-fields box releases
    /// as a no-op (where `@as(ProtocolBox, undefined)` would deref a garbage
    /// inner pointer).
    fn emitZeroedProtocolBox(self: *ZirDriver) BuildError!u32 {
        const box_ty = try self.emitProtocolBoxTypeRef();
        const field_names = [_][*]const u8{ "data_ptr".ptr, "vtable".ptr };
        const field_lens = [_]u32{ "data_ptr".len, "vtable".len };
        const field_values = [_]u32{
            @intFromEnum(Zir.Inst.Ref.null_value),
            @intFromEnum(Zir.Inst.Ref.null_value),
        };
        const ref = zir_builder_emit_struct_init_typed(
            self.handle,
            box_ty,
            &field_names,
            &field_lens,
            &field_values,
            field_values.len,
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Phase 3.b — emit a call to `Kernel.abort_recoverable_raise()` and
    /// return its Ref. The unhandled-raise terminus: recovers the boxed
    /// `Error` stashed in the thread-local side-channel and aborts through
    /// the Phase 2 crash report (`** (kind) message` + backtrace). The
    /// function is `noreturn`, so Zig accepts its result as the catch value
    /// of any payload type. `payload_type` is currently unused (the call
    /// diverges) but kept for symmetry with `emitTypedUndefRef`.
    fn emitAbortRecoverableRaise(self: *ZirDriver, payload_type: ir.ZigType) BuildError!u32 {
        _ = payload_type;
        // `Kernel.abort_recoverable_raise/0` is a Zap stdlib function (it
        // extracts the boxed error's kind/message through the `Error`
        // protocol, a Zap-level concern, then aborts via `do_raise`). Emit a
        // cross-struct call to its monomorphized symbol rather than a Zig
        // runtime sink, so the protocol dispatch stays in Zap.
        return try self.emitCrossStructCall("Kernel", "abort_recoverable_raise__0", &[_]u32{});
    }

    fn emitImportedTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        // Try primitive mapping first
        const simple = mapReturnType(zig_type);
        if (simple != 0) return simple;

        // Complex types: emit runtime import instructions
        return switch (zig_type) {
            .list => {
                // Generic container type ref: List(T).empty() -> @TypeOf
                const list_cell = try self.emitListCellRef(getListElementType(zig_type));
                const empty_fn = zir_builder_emit_field_val(self.handle, list_cell, "empty", 5);
                if (empty_fn == error_ref) return error.EmitFailed;
                const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                if (empty_val == error_ref) return error.EmitFailed;
                const ref = zir_builder_emit_typeof(self.handle, empty_val);
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .map => |mt| {
                // Generic container type ref: Map(K, V).empty() -> @TypeOf
                const map_cell = try self.emitMapCellRef(mt.key.*, mt.value.*);
                const empty_fn = zir_builder_emit_field_val(self.handle, map_cell, "empty", 5);
                if (empty_fn == error_ref) return error.EmitFailed;
                const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                if (empty_val == error_ref) return error.EmitFailed;
                const ref = zir_builder_emit_typeof(self.handle, empty_val);
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .tuple => return try self.mapTupleElementType(zig_type),
            .struct_ref => |name| return try self.emitStructTypeRef(name),
            .term => return try self.emitTermTypeRef(),
            .protocol_box => return try self.emitProtocolBoxTypeRef(),
            .optional => |inner| {
                // `?T` — emit T's ref, then wrap in optional. Used by
                // the recursive-struct storage strategy to lower a
                // source `?Tree` field as `?*const Tree` once the
                // pointer indirection has been synthesized below.
                const inner_ref = try self.emitImportedTypeRef(inner.*);
                const ref = zir_builder_emit_optional_type(self.handle, inner_ref);
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .ptr => |pointee| {
                // `*const T` — emit T's ref, then wrap in single-
                // const pointer. The recursive-storage path inserts
                // this between an `optional` and a `struct_ref` to
                // break what would otherwise be an infinite-size
                // value-typed cycle.
                const pointee_ref = try self.emitImportedTypeRef(pointee.*);
                const ref = zir_builder_emit_single_const_ptr_type(self.handle, pointee_ref);
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            // A closure type lowers to `*const fn(P...) Ret` — the runtime
            // representation of a non-capturing closure value. Reachable
            // when a closure type appears nested inside an optional/ptr/
            // tuple, or as a struct field type emitted through this path.
            .function => |fn_type| return try self.emitFuncPtrTypeRef(fn_type),
            // void/nil/never should not appear as tuple elements
            .void, .nil, .never => return error.EmitFailed,
            // Types that don't have runtime representations as tuple elements yet
            .tagged_union, .any => return error.EmitFailed,
            // Primitives are handled above by mapReturnType — they never reach here
            .bool_type,
            .i8,
            .i16,
            .i32,
            .i64,
            .i128,
            .u8,
            .u16,
            .u32,
            .u64,
            .u128,
            .usize,
            .isize,
            .f16,
            .f32,
            .f64,
            .f80,
            .f128,
            .string,
            .atom,
            => unreachable,
        };
    }

    fn refForLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        const value_ref = self.local_refs.get(local) orelse return error.EmitFailed;
        return self.materializeValueRef(value_ref);
    }

    fn localOwnershipClass(self: *const ZirDriver, local: ir.LocalId) ir.OwnershipClass {
        if (local >= self.current_function_local_ownership.len) return .trivial;
        return self.current_function_local_ownership[local];
    }

    /// Returns the stored value ref for an ARC release target, or null when the
    /// local is statically trivial and absent from the post-drop ARC-managed
    /// set. A non-trivial/ARC-managed local that materializes as Zig `void`
    /// violates the IR ownership invariant and must fail emission rather than
    /// silently dropping the release.
    fn arcReleaseValueRefForLocal(self: *const ZirDriver, local: ir.LocalId) BuildError!?ValueRef {
        if (self.localOwnershipClass(local) == .trivial and !self.arc_managed_locals.contains(local)) return null;

        const value_ref = self.local_refs.get(local) orelse return error.EmitFailed;
        switch (value_ref) {
            .inst => |ref| if (ref == @intFromEnum(Zir.Inst.Ref.void_value)) return error.EmitFailed,
            .decl => {},
        }
        return value_ref;
    }

    fn arcReleaseRefForLocal(self: *ZirDriver, local: ir.LocalId) BuildError!?u32 {
        const value_ref = (try self.arcReleaseValueRefForLocal(local)) orelse return null;
        return try self.materializeValueRef(value_ref);
    }

    fn aggregateComponentOriginalRefForLocal(self: *const ZirDriver, local: ir.LocalId) ?u32 {
        return self.aggregate_component_original_refs.get(local);
    }

    fn refForParamIndex(self: *ZirDriver, param_index: u32) BuildError!u32 {
        if (self.loopify_slots != null and param_index < self.param_refs.items.len) {
            return try self.loopifyLoadParam(param_index);
        }
        if (param_index >= self.param_refs.items.len) return error.EmitFailed;
        return self.param_refs.items[param_index];
    }

    fn materializeValueRef(self: *ZirDriver, value: ValueRef) BuildError!u32 {
        return switch (value) {
            .inst => |r| r,
            .decl => |d| {
                if (d.struct_name) |mod| {
                    return self.emitCrossStructRef(mod, d.decl_name);
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

    fn markParamDerivedClosureLocal(self: *ZirDriver, local: ir.LocalId) !void {
        try self.param_derived_closure_locals.put(self.allocator, local, {});
    }

    fn unmarkParamDerivedClosureLocal(self: *ZirDriver, local: ir.LocalId) void {
        _ = self.param_derived_closure_locals.remove(local);
    }

    fn propagateParamDerivedClosureLocal(self: *ZirDriver, dest: ir.LocalId, source: ir.LocalId) !void {
        if (self.param_derived_closure_locals.contains(source)) {
            try self.markParamDerivedClosureLocal(dest);
        } else {
            self.unmarkParamDerivedClosureLocal(dest);
        }
    }

    /// Emit struct type declarations for all struct type_defs in the IR program.
    /// These become named constants in the struct's ZIR (e.g., `const Point = struct { x: i64, y: i64 };`).
    /// Check if any function in the given struct references a struct type by name.
    fn structUsesStruct(self: *const ZirDriver, owner_struct: []const u8, struct_name: []const u8) bool {
        const prog = self.program orelse return false;
        for (prog.functions) |func| {
            // Check if the function belongs to this struct
            const func_struct = if (std.mem.lastIndexOf(u8, func.name, "__")) |sep|
                func.name[0..sep]
            else
                func.name;
            // Convert dots to underscores for comparison
            var buf: [256]u8 = undefined;
            if (func_struct.len > buf.len) continue;
            @memcpy(buf[0..func_struct.len], func_struct);
            for (buf[0..func_struct.len]) |*ch| {
                if (ch.* == '.') ch.* = '_';
            }
            if (!std.mem.eql(u8, buf[0..func_struct.len], owner_struct)) continue;

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
        const current_struct = self.current_emit_struct orelse return;
        // Track emitted struct names to avoid duplicates
        var emitted = std.StringHashMap(void).init(self.allocator);
        defer emitted.deinit();

        // The primary struct of this emission — the Zap struct whose
        // source produced this Zig file. Its fields go on the file's
        // root struct_decl via `zir_builder_set_root_fields`, so
        // `@import("X")` from another emission yields THIS canonical
        // type with single nominal identity. Other Zap structs that
        // happen to be in `prog.type_defs` (peer top-level structs,
        // structs defined in other emissions) are NOT duplicated here
        // — consumers reach them via `@import("...")` which resolves
        // to their own canonical emission's root type.
        var primary_def: ?ir.TypeDef = null;

        for (prog.type_defs) |type_def| {
            var buf: [256]u8 = undefined;
            const cls = classifyTypeDef(type_def.name, current_struct, &buf);
            switch (cls) {
                .primary => {
                    if (primary_def != null) continue; // two claims; first wins
                    primary_def = type_def;
                },
                .nested => {
                    // Struct/enum/union nested inside the primary —
                    // keep emitting as a `pub const X = struct {...}`
                    // decl inside this file's struct_decl.
                    try self.emitNestedTypeDecl(type_def, &emitted);
                },
                .foreign => continue, // reached via @import elsewhere
            }
        }

        try self.emitClosureEnvTypeDecls();

        // Emit the primary struct's fields at the file's root
        // struct_decl (instruction 0 / `main_struct_inst`). When the
        // primary has no `struct_def` entry — e.g. a top-level Zap
        // struct that holds only functions — we emit nothing here and
        // the file's root remains a fields-less struct, which is
        // exactly what we want.
        if (primary_def) |td| switch (td.kind) {
            .struct_def => |def| try self.emitRootFields(def),
            else => {},
        };
    }

    fn currentStructMatches(self: *const ZirDriver, struct_name: []const u8) bool {
        const current_struct = self.current_emit_struct orelse return false;
        var buf: [256]u8 = undefined;
        const normalized = dottedPrefixToImportName(struct_name, &buf) orelse return false;
        return std.mem.eql(u8, normalized, current_struct);
    }

    fn closureEnvTypeName(self: *const ZirDriver, function_id: ir.FunctionId, buf: []u8) BuildError![]const u8 {
        _ = self;
        return std.fmt.bufPrint(buf, "__ClosureEnv_{d}", .{function_id}) catch error.EmitFailed;
    }

    /// Pre-pass: walk every function's body for `make_closure` and record, per
    /// captured closure `FunctionId`, the CONSTRUCTION-SITE `ZigType` of each
    /// capture. The env-struct field types and the env VALUE the `make_closure`
    /// builds must agree; a capture's declared `Capture.type_expr` (the surface
    /// param type) does NOT reflect boxing — a `fn(P) -> R` binding whose
    /// runtime value is a boxed `Callable` carries a `.function` `type_expr`
    /// while its value is a `ProtocolBox`. The construction site is
    /// authoritative: a capture local in the OWNING function's
    /// `protocol_box_locals` is genuinely boxed, so its env field is
    /// `.protocol_box(<vtable-family>)` regardless of the surface type. All
    /// other capture types already match their declared `type_expr`
    /// (primitives, `List`/`Map`, nominal structs, non-capturing fn-ptrs).
    fn collectClosureConstructionCaptureTypes(self: *ZirDriver, program: ir.Program) !void {
        var iter = self.closure_construction_capture_types.valueIterator();
        while (iter.next()) |slice_ptr| self.allocator.free(slice_ptr.*);
        self.closure_construction_capture_types.clearRetainingCapacity();

        for (program.functions) |owner| {
            // Resolve which of the owning function's locals carry a genuinely
            // BOXED `Callable` (`.protocol_box`) at runtime, so a capture of one
            // gets a `.protocol_box` env field even when its surface type is
            // `.function`. Two boxed-value sources:
            //   * `protocol_box_locals` — a `box_as_protocol` dest / its alias /
            //     a box-returning call's result (snapshotted on the function).
            //   * a `param_get` of a `.protocol_box`-typed parameter (a boxed
            //     `Callable` arg — e.g. a `fn(P) -> R` param the monomorphizer
            //     boxed; NOT recorded in `protocol_box_locals`), propagated
            //     across `local_set`/`local_get`/`move`/`share` aliases.
            var boxed_locals: std.AutoHashMapUnmanaged(ir.LocalId, []const u8) = .empty;
            defer boxed_locals.deinit(self.allocator);
            {
                var pb_iter = owner.protocol_box_locals.iterator();
                while (pb_iter.next()) |e| {
                    try boxed_locals.put(self.allocator, e.key_ptr.*, e.value_ptr.*);
                }
            }
            for (owner.body) |block| {
                for (block.instructions) |instr| {
                    switch (instr) {
                        .param_get => |pg| {
                            if (pg.index < owner.params.len) {
                                const pt = owner.params[pg.index].type_expr;
                                if (pt == .protocol_box) {
                                    try boxed_locals.put(self.allocator, pg.dest, pt.protocol_box);
                                }
                            }
                        },
                        .local_set => |ls| {
                            if (boxed_locals.get(ls.value)) |name|
                                try boxed_locals.put(self.allocator, ls.dest, name);
                        },
                        .local_get => |lg| {
                            if (boxed_locals.get(lg.source)) |name|
                                try boxed_locals.put(self.allocator, lg.dest, name);
                        },
                        else => {},
                    }
                }
            }

            for (owner.body) |block| {
                for (block.instructions) |instr| {
                    const mc = switch (instr) {
                        .make_closure => |m| m,
                        else => continue,
                    };
                    if (mc.captures.len == 0) continue;
                    const target = self.findFunctionById(mc.function) orelse continue;
                    if (target.captures.len != mc.captures.len) continue;

                    const types = try self.allocator.alloc(ir.ZigType, mc.captures.len);
                    errdefer self.allocator.free(types);
                    for (mc.captures, 0..) |cap_local, i| {
                        // A boxed-`Callable` capture is a `ProtocolBox` at
                        // runtime — override the (possibly `.function`) declared
                        // capture type so the env field matches the env value.
                        if (boxed_locals.get(cap_local)) |protocol_name| {
                            types[i] = .{ .protocol_box = protocol_name };
                        } else {
                            types[i] = target.captures[i].type_expr;
                        }
                    }
                    // A closure has a single construction site; last write wins
                    // (idempotent — identical types across duplicate monomorph
                    // copies). Free any prior slice for this id first.
                    if (self.closure_construction_capture_types.fetchRemove(mc.function)) |old| {
                        self.allocator.free(old.value);
                    }
                    try self.closure_construction_capture_types.put(self.allocator, mc.function, types);
                }
            }
        }
    }

    /// The CONSTRUCTION-SITE `ZigType` for capture `index` of closure
    /// `function_id`, or the declared `Capture.type_expr` fallback. See
    /// `collectClosureConstructionCaptureTypes`.
    fn closureCaptureFieldType(
        self: *const ZirDriver,
        function_id: ir.FunctionId,
        index: usize,
        declared: ir.ZigType,
    ) ir.ZigType {
        if (self.closure_construction_capture_types.get(function_id)) |types| {
            if (index < types.len) return types[index];
        }
        return declared;
    }

    fn emitClosureEnvTypeDecls(self: *ZirDriver) !void {
        const prog = self.program orelse return;

        // Dedup by function id directly. The earlier StringHashMap-based
        // dedup keyed on a stack-allocated `env_name_buf` slice — the
        // hashmap stored those slices by reference, so each iteration's
        // `bufPrint` overwrote the bytes of every prior key, yielding
        // spurious `contains` hits and silently skipping legitimate env
        // decls. Function ids are unique and stable, so a u32 set is
        // both correct and cheaper.
        var emitted_ids: std.AutoHashMap(ir.FunctionId, void) = .init(self.allocator);
        defer emitted_ids.deinit();

        for (prog.functions) |func| {
            if (!func.is_closure or func.captures.len == 0) continue;
            if (func.struct_name) |owner| {
                if (!self.currentStructMatches(owner)) continue;
            } else if (self.current_emit_struct != null) {
                continue;
            }

            const lowering = self.getClosureLowering(func.id, func.captures.len);
            if (!lowering.needs_env_param) continue;

            if (emitted_ids.contains(func.id)) continue;
            try emitted_ids.put(func.id, {});

            var env_name_buf: [64]u8 = undefined;
            const env_name = try self.closureEnvTypeName(func.id, &env_name_buf);

            // Emit the env struct via the streaming NAMED struct-decl API so
            // each capture field's type can be a COMPOUND type body, not just
            // a primitive static Ref. A captured boxed `Callable` (lowering to
            // `ProtocolBox`), `List`/`Map`, nominal struct, or non-capturing
            // closure (`fn`-ptr) needs `emitImportedTypeRef`'s multi-instruction
            // body — the bulk `add_struct_type` (primitives + enums only via
            // the removed `mapClosureEnvFieldTypeRef`) could not express it and
            // raised `EmitFailed`, so a closure capturing such a value and
            // bound-then-invoked INLINE (devirtualized, no box) failed to
            // compile.
            if (zir_builder_begin_named_struct_decl(
                self.handle,
                env_name.ptr,
                @intCast(env_name.len),
            ) != 0) {
                return error.EmitFailed;
            }

            var index_field_name_batch = try IndexFieldNameBatch.init(self.allocator, func.captures.len);
            defer index_field_name_batch.deinit();

            for (func.captures, 0..) |capture, capture_index| {
                const field_name = index_field_name_batch.get(capture_index);
                const field_type = self.closureCaptureFieldType(func.id, capture_index, capture.type_expr);
                const simple = mapReturnType(field_type);
                if (simple != 0) {
                    if (zir_builder_named_struct_field_static(
                        self.handle,
                        field_name.ptr,
                        @intCast(field_name.len),
                        simple,
                    ) != 0) {
                        return error.EmitFailed;
                    }
                    continue;
                }
                // Compound capture type — record its type-expression body.
                if (zir_builder_begin_named_struct_field_body(
                    self.handle,
                    field_name.ptr,
                    @intCast(field_name.len),
                ) != 0) {
                    return error.EmitFailed;
                }
                const final_ref = self.emitImportedTypeRef(field_type) catch |err| {
                    // Best-effort: close the field body so the builder is not
                    // left mid-recording; propagate the original error.
                    _ = zir_builder_end_named_struct_field_body(
                        self.handle,
                        @intFromEnum(Zir.Inst.Ref.void_value),
                    );
                    return err;
                };
                if (zir_builder_end_named_struct_field_body(self.handle, final_ref) != 0) {
                    return error.EmitFailed;
                }
            }

            if (zir_builder_end_named_struct_decl(self.handle) != 0) {
                return error.EmitFailed;
            }
        }
    }

    /// Whether a type_def belongs to the current emission, and how:
    /// - `primary`  — the Zap struct that owns this emission (file IS this struct)
    /// - `nested`   — a struct/enum/union declared *inside* the primary
    /// - `foreign`  — owned by another emission; reached via `@import`
    const TypeDefClass = enum { primary, nested, foreign };

    /// Convert a type_def name to its emission-namespace form (dots →
    /// underscores) and classify against the current emission. Writes
    /// into `scratch` to avoid a heap allocation on the hot path.
    fn classifyTypeDef(name: []const u8, current_struct: []const u8, scratch: []u8) TypeDefClass {
        if (name.len > scratch.len) return .foreign;
        @memcpy(scratch[0..name.len], name);
        for (scratch[0..name.len]) |*ch| {
            if (ch.* == '.') ch.* = '_';
        }
        const underscore = scratch[0..name.len];
        if (std.mem.eql(u8, underscore, current_struct)) return .primary;
        if (underscore.len > current_struct.len + 1 and
            std.mem.startsWith(u8, underscore, current_struct) and
            underscore[current_struct.len] == '_')
        {
            return .nested;
        }
        return .foreign;
    }

    /// Emit a synthetic top-level Zig source file for a per-instantiation
    /// `union_def` or `enum_def` TypeDef whose name is a top-level
    /// mangled form (e.g. `Option_i64`, `Color_Foo`). The file content
    /// is a single `pub const <Name> = union(enum) { ... };` or
    /// `pub const <Name> = enum { ... };` declaration so consumers can
    /// reach the type via `@import("<Name>").<Name>`.
    ///
    /// This complements Step 3.5 (`struct_def` synthetic files) — the
    /// IR layer already emits `union_def`/`enum_def` TypeDefs for every
    /// `.applied { base, args }` parametric specialization in
    /// `populateAppliedSpecializations`, but the ZIR layer would
    /// otherwise drop them. With this step in place, the consistent
    /// threading rule for `union_init` becomes "always use
    /// `emitStructTypeRef(ui.union_type)` — the type exists at ZIR".
    fn emitSpecializationSourceFile(
        self: *ZirDriver,
        c: *ZirContext,
        type_def: ir.TypeDef,
    ) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        try renderSpecializationSourceFileBody(self.allocator, &buf, type_def);
        if (buf.items.len == 0) return; // type_def kind not handled

        const name_z = try self.allocator.dupeZ(u8, type_def.name);
        defer self.allocator.free(name_z);

        dumpSyntheticSourceIfRequested(name_z, buf.items.ptr, @intCast(buf.items.len));
        if (zir_compilation_add_struct_source(
            c,
            name_z,
            buf.items.ptr,
            @intCast(buf.items.len),
        ) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    /// Emit a synthetic top-level Zig source file for a
    /// `protocol_vtable_def` TypeDef. The file declares the
    /// per-protocol vtable struct type as the file's main
    /// (root-named) constant, so consumers reach it via
    /// `@import("<Protocol>VTable").<Protocol>VTable`. The
    /// receiver is type-erased to `?*anyopaque`; other params
    /// and return types use the IR-side ZigType-to-string
    /// lowering so primitives like `String`/`i64`/`Atom` round-
    /// trip to their canonical Zig forms (`[]const u8`,
    /// `i64`, `[]const u8`).
    ///
    /// Phase 1.2.5.a emits only the type — Phase 1.2.5.d will
    /// teach the consumption-site lowering to cast
    /// `ProtocolBox.vtable` back to `*const <Protocol>VTable`
    /// and dispatch through the named slots.
    fn emitProtocolVTableSourceFile(
        self: *ZirDriver,
        c: *ZirContext,
        type_def: ir.TypeDef,
    ) !void {
        const vt_def = switch (type_def.kind) {
            .protocol_vtable_def => |def| def,
            else => return, // guarded by caller
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        // The synthetic source declares one `extern struct` whose
        // fields are method-slot function pointers. The fields'
        // signatures bake in the protocol's declared param/return
        // types but erase the receiver — the dispatch site at the
        // ProtocolBox always carries the inner value as
        // `?*anyopaque`.
        // A PLAIN Zig `struct`, NOT `extern struct`. The vtable is never
        // passed across a C-ABI boundary — `ProtocolBox.vtable` is a
        // type-erased `?*const anyopaque` recovered via
        // `@ptrCast(@alignCast(...))` back to this synthetic struct type
        // and accessed only by named field, so its in-memory layout is a
        // private contract between the synthetic emissions. Using a plain
        // struct (default `.auto` calling convention for the fn-pointer
        // fields) is required: an `extern struct` forces every fn-pointer
        // field to specify a calling convention, and a C-ABI convention
        // cannot return a slice (`[]const u8` for `message`/`kind`) or a
        // bare Zig union (`Option_Error`/`Option_Atom` for
        // `source`/`code`) — "return type not allowed in function with
        // calling convention 'aarch64_aapcs_darwin'". The default
        // convention has no such restriction.
        try buf.appendSlice(self.allocator, "const zap_runtime = @import(\"zap_runtime\");\n");
        try buf.appendSlice(self.allocator, "pub const ");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, " = struct {\n");
        // G-box ABI (round 2): the fixed `ProtocolBoxVTableHeader` is the
        // FIRST field of every vtable, so its `retain`/`drop` fn-pointers
        // sit at vtable offset 0 and `@sizeOf(*anyopaque)`. The runtime's
        // generic ARC deep-walk (`releaseProtocolBoxValue` /
        // `retainProtocolBoxValue`) recovers a box's type-erased vtable by
        // casting `box.vtable` to `*const ProtocolBoxVTableHeader` and
        // invoking these slots — it cannot read the per-protocol method
        // slots (each protocol's layout differs), but the header is a
        // shared, fixed `extern struct` contract. The header is embedded
        // BY VALUE (not as two bare fn-pointer fields) so the whole header
        // is a contiguous offset-0 block; a `comptime` assertion below
        // fails the build loudly if a future Zig reorders `.auto` fields.
        try buf.appendSlice(self.allocator, "    __box_header__: zap_runtime.ProtocolBoxVTableHeader,\n");
        for (vt_def.methods) |method| {
            try buf.appendSlice(self.allocator, "    ");
            try appendZigIdentifier(self.allocator, &buf, method.name);
            try buf.appendSlice(self.allocator, ": *const fn (data_ptr: ?*anyopaque");
            for (method.extra_param_types, 0..) |param_zt, param_index| {
                try buf.appendSlice(self.allocator, ", ");
                const arg_prefix = try std.fmt.allocPrint(self.allocator, "arg{d}: ", .{param_index});
                defer self.allocator.free(arg_prefix);
                try buf.appendSlice(self.allocator, arg_prefix);
                try appendZigTypeForVTable(self.allocator, &buf, param_zt);
            }
            try buf.appendSlice(self.allocator, ") ");
            try appendVTableReturnType(self.allocator, &buf, method.return_type, method.raises);
            try buf.appendSlice(self.allocator, ",\n");
        }
        try buf.appendSlice(self.allocator, "};\n\n");

        // Layout guard: a plain (`.auto`) struct gives no field-order
        // guarantee, but the runtime deep-walk's `@ptrCast` of the box's
        // vtable to `*const ProtocolBoxVTableHeader` reads from offset 0.
        // Bake the invariant into the synthetic source so a reordering
        // Zig (or an accidental edit that moves `__box_header__` off the
        // front) fails the per-vtable build rather than miscompiling every
        // box-in-container retain/drop.
        try buf.appendSlice(self.allocator, "comptime {\n");
        try buf.appendSlice(self.allocator, "    const std = @import(\"std\");\n");
        try buf.appendSlice(self.allocator, "    std.debug.assert(@offsetOf(");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, ", \"__box_header__\") == 0);\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // Phase 1.2.5.d consumption-site helpers.
        //
        // `drop(box)` — type-erased release of the box's inner value.
        // The IR-level scope-exit drop pass calls this whenever a
        // `.protocol_box(<Protocol>)` local goes out of scope (or any
        // other release point). The helper recovers the vtable cast
        // and invokes the synthetic `__drop__` slot. `None` boxes
        // (data_ptr=null,vtable=null) are no-ops — the IR avoids
        // emitting a drop for proven-none boxes but the runtime guard
        // here keeps the contract honest if the optimizer changes
        // its mind later.
        //
        // `dispatch_<method>(box, args...)` — one helper per protocol
        // method, performs the vtable cast and invokes the indirect
        // function pointer with `box.data_ptr` as the implicit
        // receiver. The IR's `protocol_dispatch` lowering reaches
        // these helpers by name.
        //
        // Keeping the dispatch/drop logic in the synthetic Zig source
        // — rather than encoded directly through low-level ZIR
        // primitives — lets every consumption site round-trip through
        // ordinary `call_ref` shape, matches `boxAsProtocol`'s
        // construction pattern, and centralises the
        // `@ptrCast(@alignCast(...))` recovery in one inspectable
        // place per protocol. (`zap_runtime` is already imported at the
        // top of this synthetic file for the `__box_header__` field type.)

        // `drop(box) void`
        try buf.appendSlice(self.allocator, "pub fn drop(box: zap_runtime.ProtocolBox) void {\n");
        try buf.appendSlice(self.allocator, "    if (box.vtable) |vt_erased| {\n");
        try buf.appendSlice(self.allocator, "        const vt: *const ");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(vt_erased));\n");
        try buf.appendSlice(self.allocator, "        vt.__box_header__.drop(box.data_ptr);\n");
        try buf.appendSlice(self.allocator, "    }\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // `retain(box) void` — type-erased retain of the box's inner
        // value, the share/borrow counterpart of `drop`. The IR-level
        // `.retain { kind = .protocol_box_retain }` (stamped by
        // `rewriteProtocolBoxRetains`) lowers to this helper whenever a
        // `.protocol_box(<Protocol>)` local is shared. It recovers the
        // vtable cast and invokes the synthetic `__retain__` slot. `None`
        // boxes (data_ptr=null, vtable=null) are no-ops.
        try buf.appendSlice(self.allocator, "pub fn retain(box: zap_runtime.ProtocolBox) void {\n");
        try buf.appendSlice(self.allocator, "    if (box.vtable) |vt_erased| {\n");
        try buf.appendSlice(self.allocator, "        const vt: *const ");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(vt_erased));\n");
        try buf.appendSlice(self.allocator, "        vt.__box_header__.retain(box.data_ptr);\n");
        try buf.appendSlice(self.allocator, "    }\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // `clone(box) zap_runtime.ProtocolBox` — FCC Phase 2 clone-on-share.
        // Deep-clones the box's inner value and returns a NEW box that owns
        // the independent inner and reuses the SAME (static `.rodata`) vtable
        // pointer. Recovers the vtable cast and invokes the synthetic
        // `__clone__` slot. `None` boxes clone to themselves.
        try buf.appendSlice(self.allocator, "pub fn clone(box: zap_runtime.ProtocolBox) zap_runtime.ProtocolBox {\n");
        try buf.appendSlice(self.allocator, "    if (box.data_ptr == null) return box;\n");
        try buf.appendSlice(self.allocator, "    if (box.vtable) |vt_erased| {\n");
        try buf.appendSlice(self.allocator, "        const vt: *const ");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(vt_erased));\n");
        try buf.appendSlice(self.allocator, "        return .{ .data_ptr = vt.__box_header__.clone(box.data_ptr), .vtable = box.vtable };\n");
        try buf.appendSlice(self.allocator, "    }\n");
        try buf.appendSlice(self.allocator, "    return box;\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // `share(box) zap_runtime.ProtocolBox` — the single chokepoint the
        // box-local `.protocol_box_share` share lowering calls when a box
        // gains a second owner. Comptime-specialized on the active manager's
        // reclamation model (three-way, capability-driven — never a manager
        // name):
        //   * REFCOUNTED — bump the inner's refcount and return the SAME box;
        //     the two owners share one refcounted inner that the last drop
        //     frees. (Identity rebind at the call site.)
        //   * INDIVIDUAL_NO_REFCOUNT (`Memory.Tracking`, CLONE_ON_SHARE) —
        //     there is no refcount, so a second owner of the same inner would
        //     double-free at its individual scope-exit free. Return an
        //     independent CLONE so each owner frees its own inner exactly once
        //     (no double-free, no leak).
        //   * BULK_OR_NEVER / TRACED (Arena/NoOp/Leak/GC) — there is no
        //     individual free at all (the manager reclaims in bulk at exit,
        //     never, or via tracing), so a second owner aliasing the same
        //     inner is SAFE and cloning would be a pointless allocation.
        //     Return the SAME box — pure elision, zero overhead.
        // Keeping the policy inside this comptime-specialized helper lets the
        // `.protocol_box_share` ZIR handler stay uniform: it always rebinds
        // the new owner local to `share(box)`.
        try buf.appendSlice(self.allocator, "pub fn share(box: zap_runtime.ProtocolBox) zap_runtime.ProtocolBox {\n");
        try buf.appendSlice(self.allocator, "    if (comptime zap_runtime.refcount_v1_active) {\n");
        try buf.appendSlice(self.allocator, "        retain(box);\n");
        try buf.appendSlice(self.allocator, "        return box;\n");
        try buf.appendSlice(self.allocator, "    } else if (comptime zap_runtime.eager_individual_free) {\n");
        try buf.appendSlice(self.allocator, "        return clone(box);\n");
        try buf.appendSlice(self.allocator, "    } else {\n");
        try buf.appendSlice(self.allocator, "        return box;\n");
        try buf.appendSlice(self.allocator, "    }\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // `dispatch_<method>(box, args...) RT`
        for (vt_def.methods) |method| {
            try buf.appendSlice(self.allocator, "pub fn dispatch_");
            try appendZigIdentifier(self.allocator, &buf, method.name);
            try buf.appendSlice(self.allocator, "(box: zap_runtime.ProtocolBox");
            for (method.extra_param_types, 0..) |param_zt, param_index| {
                try buf.appendSlice(self.allocator, ", ");
                const arg_prefix = try std.fmt.allocPrint(self.allocator, "arg{d}: ", .{param_index});
                defer self.allocator.free(arg_prefix);
                try buf.appendSlice(self.allocator, arg_prefix);
                try appendZigTypeForVTable(self.allocator, &buf, param_zt);
            }
            try buf.appendSlice(self.allocator, ") ");
            try appendVTableReturnType(self.allocator, &buf, method.return_type, method.raises);
            try buf.appendSlice(self.allocator, " {\n");
            try buf.appendSlice(self.allocator, "    const vt: *const ");
            try buf.appendSlice(self.allocator, type_def.name);
            try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(box.vtable.?));\n");
            try buf.appendSlice(self.allocator, "    return vt.");
            try appendZigIdentifier(self.allocator, &buf, method.name);
            try buf.appendSlice(self.allocator, "(box.data_ptr");
            for (method.extra_param_types, 0..) |_, param_index| {
                try buf.appendSlice(self.allocator, ", ");
                const arg_ref = try std.fmt.allocPrint(self.allocator, "arg{d}", .{param_index});
                defer self.allocator.free(arg_ref);
                try buf.appendSlice(self.allocator, arg_ref);
            }
            try buf.appendSlice(self.allocator, ");\n}\n\n");
        }

        const name_z = try self.allocator.dupeZ(u8, type_def.name);
        defer self.allocator.free(name_z);

        dumpSyntheticSourceIfRequested(name_z, buf.items.ptr, @intCast(buf.items.len));
        if (zir_compilation_add_struct_source(
            c,
            name_z,
            buf.items.ptr,
            @intCast(buf.items.len),
        ) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    /// Emit a synthetic top-level Zig source file for a
    /// `protocol_vtable_instance_def` TypeDef. The file declares
    /// a constant of the corresponding vtable struct type whose
    /// method-pointer slots are left as `undefined` — Phase
    /// 1.2.5.c populates the slots with ABI-bridge adapter
    /// functions once construction-site lowering knows how to
    /// reach the inner type's monomorphized impl method symbols.
    ///
    /// The constant is named `<Protocol>VTable_for_<Target>`
    /// (matching the TypeDef name); construction-site lowering
    /// (Phase 1.2.5.c) takes the address of this constant and
    /// writes it into `ProtocolBox.vtable` at every site where a
    /// concrete `<Target>` value is auto-boxed as the protocol.
    /// The `undefined` slot population is intentional in 1.2.5.a:
    /// the construction-site lowering will own the adapter-
    /// generation so the impl-symbol references resolve through
    /// the same import path the construction site already uses.
    fn emitProtocolVTableInstanceSourceFile(
        self: *ZirDriver,
        c: *ZirContext,
        type_def: ir.TypeDef,
    ) !void {
        const inst_def = switch (type_def.kind) {
            .protocol_vtable_instance_def => |def| def,
            else => return, // guarded by caller
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);

        // Bring the vtable type into scope under a stable local
        // name. The `.<Protocol>VTable` field on the imported
        // namespace resolves to the canonical InternPool.Index for
        // the protocol's vtable type (the file-IS-the-struct
        // emission guarantees one nominal identity per Zap struct,
        // see `File-IS-Struct Emission Model` engram).
        const import_line = try std.fmt.allocPrint(
            self.allocator,
            "const VTableMod = @import(\"{s}VTable\");\n",
            .{inst_def.protocol_name},
        );
        defer self.allocator.free(import_line);
        try buf.appendSlice(self.allocator, import_line);

        // Phase 1.2.5.c: bring the impl target's namespace and the
        // Zap runtime into scope so the adapter functions can call
        // through to the monomorphized impl methods and to
        // `releaseProtocolBoxInner` for the `__drop__` adapter.
        // `@import("<Target>")` resolves to the target's file-IS-the-
        // struct emission (concrete `MyError` -> `MyError`'s source
        // file; parametric specialization `Box_i64` -> the per-
        // instantiation TypeDef synthetic source file).
        const target_import_line = try std.fmt.allocPrint(
            self.allocator,
            "const TargetMod = @import(\"{s}\");\n",
            .{inst_def.target_type_name},
        );
        defer self.allocator.free(target_import_line);
        try buf.appendSlice(self.allocator, target_import_line);
        try buf.appendSlice(self.allocator, "const zap_runtime = @import(\"zap_runtime\");\n");
        try buf.appendSlice(self.allocator, "const std = @import(\"std\");\n");
        try buf.appendSlice(self.allocator, "\n");

        // How to refer to the target's CONCRETE TYPE from this adapter
        // file. Every Zap struct emits file-IS-the-struct (its fields
        // live at the imported file's root struct_decl — see
        // `emitStructTypeDecls`/`emitRootFields`), so for a top-level
        // target `@import("Outer")` IS the `Outer` type: the reference is
        // `TargetMod`, NOT `TargetMod.Outer` (the file has no nested
        // member named `Outer`). A NESTED target (dotted name) lives as a
        // `pub const <leaf> = struct {...}` inside its parent's emission,
        // reached as `TargetMod.<leaf>`. The target's METHODS are always
        // published at the target file's root (`emitFunction` selects
        // `func.local_name` under `current_emit_struct`), so method calls
        // stay `TargetMod.<method>` in both cases.
        const target_type_ref = if (std.mem.lastIndexOfScalar(u8, inst_def.target_type_name, '.')) |dot_idx| blk: {
            const leaf = inst_def.target_type_name[dot_idx + 1 ..];
            break :blk try std.fmt.allocPrint(self.allocator, "TargetMod.{s}", .{leaf});
        } else try self.allocator.dupe(u8, "TargetMod");
        defer self.allocator.free(target_type_ref);

        // Phase 1.2.5.c: per-impl ABI-bridge adapter functions.
        // Each adapter recovers the inner value from the box's
        // erased `data_ptr` via `@ptrCast(@alignCast(data_ptr.?))`
        // and dispatches to the monomorphized impl function. The
        // user-declared methods take the inner BY VALUE (the impl
        // method's receiver is a value param, not a pointer); the
        // `__drop__` adapter takes a mutable pointer because
        // `releaseProtocolBoxInner` needs to free the heap cell.
        //
        // The adapter naming `__vtable_adapter__<Target>__<method>__<arity>`
        // is unique per (impl, method, arity) tuple — parametric
        // specializations (e.g. `Box_i64__label__1`) embed the
        // mangled target so each instantiation has distinct
        // adapters without collisions.
        for (inst_def.methods) |method| {
            // `fn __vtable_adapter__<Target>__<method>__<arity>(`
            try buf.appendSlice(self.allocator, "fn __vtable_adapter__");
            try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
            try buf.appendSlice(self.allocator, "__");
            try appendZigIdentifier(self.allocator, &buf, method.method_name);
            const arity_str = try std.fmt.allocPrint(self.allocator, "__{d}", .{method.arity});
            defer self.allocator.free(arity_str);
            try buf.appendSlice(self.allocator, arity_str);
            try buf.appendSlice(self.allocator, "(data_ptr: ?*anyopaque");
            for (method.extra_param_types, 0..) |param_zt, param_index| {
                try buf.appendSlice(self.allocator, ", ");
                const arg_prefix = try std.fmt.allocPrint(self.allocator, "arg{d}: ", .{param_index});
                defer self.allocator.free(arg_prefix);
                try buf.appendSlice(self.allocator, arg_prefix);
                try appendZigTypeForVTable(self.allocator, &buf, param_zt);
            }
            try buf.appendSlice(self.allocator, ") ");
            try appendVTableReturnType(self.allocator, &buf, method.return_type, method.raises);
            try buf.appendSlice(self.allocator, " {\n");
            // `    const inner: *const <target_type_ref> = @ptrCast(@alignCast(data_ptr.?));`
            try buf.appendSlice(self.allocator, "    const inner: *const ");
            try buf.appendSlice(self.allocator, target_type_ref);
            try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(data_ptr.?));\n");
            // `    return TargetMod.<method_name>(inner.*[, arg0, ...]);`
            //
            // The target struct's file (file-IS-the-struct emission)
            // publishes the impl method under its *local* name (just
            // `message`, not `MyError__message__1`) because
            // `emitFunction` selects `func.local_name` when
            // `current_emit_struct != null`. Cross-struct references
            // elsewhere in the compiler (see `emitCrossStructCall`)
            // follow the same convention. The IR's
            // `impl_function_name = "<Target>__<method>__<arity>"`
            // is the GLOBAL qualified name used by call-site
            // resolution against top-level functions, but inside a
            // struct file the symbol is published unqualified — so
            // the vtable adapter must call `TargetMod.<method_name>`,
            // not `TargetMod.<impl_function_name>`.
            // The impl method is published inside the target struct's
            // ZIR file under its `func.local_name`, which carries the
            // arity suffix (`message__1`, not `message`) — see
            // `emitFunction`'s `emit_name = func.local_name` selection
            // when `current_emit_struct != null`. The adapter therefore
            // calls `TargetMod.<method>__<arity>`, matching the published
            // declaration name. (The earlier assumption that methods were
            // published bare was wrong; `@import("Target").message` has
            // no such member — only `message__1`.)
            try buf.appendSlice(self.allocator, "    return TargetMod.");
            try appendZigIdentifier(self.allocator, &buf, method.method_name);
            const method_arity_suffix = try std.fmt.allocPrint(self.allocator, "__{d}", .{method.arity});
            defer self.allocator.free(method_arity_suffix);
            try buf.appendSlice(self.allocator, method_arity_suffix);
            try buf.appendSlice(self.allocator, "(inner.*");
            for (method.extra_param_types, 0..) |_, param_index| {
                try buf.appendSlice(self.allocator, ", ");
                const arg_ref = try std.fmt.allocPrint(self.allocator, "arg{d}", .{param_index});
                defer self.allocator.free(arg_ref);
                try buf.appendSlice(self.allocator, arg_ref);
            }
            try buf.appendSlice(self.allocator, ");\n}\n\n");
        }

        // Synthetic `__drop__` adapter. Casts the box's erased
        // `data_ptr` back to a mutable `*<Target>` and routes
        // through `zap_runtime.ArcRuntime.releaseProtocolBoxInner`,
        // which runs the inner's full ARC deep-walk + slab return.
        // `std.heap.page_allocator` is the canonical default here
        // because the inner was allocated through `allocAny`'s
        // active memory-manager dispatcher (the allocator argument
        // is vestigial in the manager-routed path — see the
        // `allocAny` header — and `releaseAny` ignores it
        // symmetrically).
        // `callconv(.c)`: the `__box_header__` slots have type
        // `*const fn (?*anyopaque) callconv(.c) void` (an `extern struct`
        // field cannot hold a default-convention fn-pointer), so the
        // adapter assigned to the slot must match.
        try buf.appendSlice(self.allocator, "fn __vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____drop__(data_ptr: ?*anyopaque) callconv(.c) void {\n");
        try buf.appendSlice(self.allocator, "    const inner: *");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(data_ptr.?));\n");
        try buf.appendSlice(self.allocator, "    zap_runtime.ArcRuntime.releaseProtocolBoxInner(");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, ", std.heap.page_allocator, inner);\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // Synthetic `__retain__` adapter — the share/borrow counterpart
        // of `__drop__`. Casts the box's erased `data_ptr` back to a
        // mutable `*<Target>` and routes through
        // `zap_runtime.ArcRuntime.retainProtocolBoxInner`, which bumps
        // the inner's refcount via the standard `retainAny` path. Keeps
        // box construction/share/drop refcount-balanced.
        try buf.appendSlice(self.allocator, "fn __vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____retain__(data_ptr: ?*anyopaque) callconv(.c) void {\n");
        try buf.appendSlice(self.allocator, "    const inner: *");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(data_ptr.?));\n");
        try buf.appendSlice(self.allocator, "    zap_runtime.ArcRuntime.retainProtocolBoxInner(");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, ", inner);\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // Synthetic `__clone__` adapter — FCC Phase 2 clone-on-share. Casts
        // the box's erased `data_ptr` back to a mutable `*<Target>` and
        // routes through `zap_runtime.ArcRuntime.cloneProtocolBoxInner`,
        // which allocates an independent inner cell and deep-clones its ARC
        // children. Returns the fresh inner as an erased pointer; the box's
        // `clone`/`share` helper wraps it with the same vtable. The
        // `std.heap.page_allocator` argument is vestigial in the
        // manager-routed `allocAny` path (see the `allocAny` header), exactly
        // as for `__drop__`'s `releaseProtocolBoxInner` call.
        try buf.appendSlice(self.allocator, "fn __vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____clone__(data_ptr: ?*anyopaque) callconv(.c) ?*anyopaque {\n");
        try buf.appendSlice(self.allocator, "    const inner: *");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(data_ptr.?));\n");
        try buf.appendSlice(self.allocator, "    const cloned = zap_runtime.ArcRuntime.cloneProtocolBoxInner(");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, ", std.heap.page_allocator, inner);\n");
        try buf.appendSlice(self.allocator, "    return @ptrCast(cloned);\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // Declare the per-impl vtable instance constant. Phase
        // 1.2.5.c populates each slot with the address of the
        // corresponding adapter function so the box's runtime
        // dispatch finds a valid pointer at every slot. The
        // synthetic `__drop__` slot enables the box's release path
        // to run the inner's drop glue without statically knowing
        // the concrete type.
        try buf.appendSlice(self.allocator, "pub const ");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, ": VTableMod.");
        try buf.appendSlice(self.allocator, inst_def.protocol_name);
        try buf.appendSlice(self.allocator, "VTable = .{\n");
        for (inst_def.methods) |method| {
            try buf.appendSlice(self.allocator, "    .");
            try appendZigIdentifier(self.allocator, &buf, method.method_name);
            try buf.appendSlice(self.allocator, " = &__vtable_adapter__");
            try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
            try buf.appendSlice(self.allocator, "__");
            try appendZigIdentifier(self.allocator, &buf, method.method_name);
            const slot_arity = try std.fmt.allocPrint(self.allocator, "__{d}", .{method.arity});
            defer self.allocator.free(slot_arity);
            try buf.appendSlice(self.allocator, slot_arity);
            try buf.appendSlice(self.allocator, ",\n");
        }
        // Fixed `ProtocolBoxVTableHeader` (G-box ABI): the box's runtime
        // deep-walk recovers `retain`/`drop` from the FIRST vtable field
        // by casting `box.vtable` to `*const ProtocolBoxVTableHeader`.
        // Initialise the embedded header struct with the per-impl
        // retain/drop adapter addresses.
        try buf.appendSlice(self.allocator, "    .__box_header__ = .{\n");
        try buf.appendSlice(self.allocator, "        .retain = &__vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____retain__,\n");
        try buf.appendSlice(self.allocator, "        .drop = &__vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____drop__,\n");
        try buf.appendSlice(self.allocator, "        .clone = &__vtable_adapter__");
        try appendZigIdentifier(self.allocator, &buf, inst_def.target_type_name);
        try buf.appendSlice(self.allocator, "____clone__,\n");
        try buf.appendSlice(self.allocator, "    },\n");
        try buf.appendSlice(self.allocator, "};\n\n");

        // Phase 1.2.5.d consumption-site helpers.
        //
        // `vtable_eq(box) bool` — pointer-compare the box's vtable
        // slot against the address of this per-impl instance
        // constant. The IR's pattern-match downcast emits a
        // `guard_block` whose condition routes through this helper;
        // when true, control flow falls into the arm body and the
        // `protocol_box_unbox` lowering recovers the typed concrete
        // value through `unbox(box)`.
        //
        // `unbox(box) TargetMod.<Target>` — recover the concrete
        // inner value from a box whose vtable already matches this
        // impl. The helper does the `@ptrCast(@alignCast(...)).*`
        // recovery; the caller is responsible for having gated the
        // call through `vtable_eq(box)` first (otherwise the cast
        // would interpret the wrong concrete type as the named
        // target — Undefined Behavior).
        //
        // Both helpers reach the vtable instance constant by name —
        // it is declared in the same synthetic source file above —
        // so they share its `.rodata` address. The IR pattern-match
        // arm compilation guarantees `vtable_eq` is the guard for
        // every `unbox` call.
        try buf.appendSlice(self.allocator, "pub fn vtable_eq(box: zap_runtime.ProtocolBox) bool {\n");
        try buf.appendSlice(self.allocator, "    return box.vtable == @as(?*const anyopaque, @ptrCast(&");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, "));\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        try buf.appendSlice(self.allocator, "pub fn unbox(box: zap_runtime.ProtocolBox) ");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, " {\n");
        try buf.appendSlice(self.allocator, "    const inner: *const ");
        try buf.appendSlice(self.allocator, target_type_ref);
        try buf.appendSlice(self.allocator, " = @ptrCast(@alignCast(box.data_ptr.?));\n");
        try buf.appendSlice(self.allocator, "    return inner.*;\n");
        try buf.appendSlice(self.allocator, "}\n\n");

        // `vtable_addr() ?*const anyopaque` — the canonical way for the
        // construction-site lowering (`box_as_protocol`) to obtain the
        // `.rodata` address of this per-impl vtable instance constant.
        //
        // Taking `&<InstanceConst>` MUST happen inside this synthetic Zig
        // source (where the constant is a value in scope), not from the
        // root module via a `field_ptr` ZIR primitive: the ZIR `field_ptr`
        // op expects a *pointer* object operand, but `@import("<file>")`
        // yields a `type` (the file's namespace). Emitting
        // `field_ptr(@import(...), <const>)` therefore makes Sema reject
        // the construction site with `expected pointer, found 'type'`. By
        // returning the erased pointer from a helper here, the call site
        // round-trips through an ordinary `call_ref` — the same pattern
        // `drop`/`dispatch_*`/`unbox` already use — and the address-of is
        // resolved in real Zig source where it is well-formed.
        try buf.appendSlice(self.allocator, "pub fn vtable_addr() ?*const anyopaque {\n");
        try buf.appendSlice(self.allocator, "    return @ptrCast(&");
        try buf.appendSlice(self.allocator, type_def.name);
        try buf.appendSlice(self.allocator, ");\n");
        try buf.appendSlice(self.allocator, "}\n");

        const name_z = try self.allocator.dupeZ(u8, type_def.name);
        defer self.allocator.free(name_z);

        dumpSyntheticSourceIfRequested(name_z, buf.items.ptr, @intCast(buf.items.len));
        if (zir_compilation_add_struct_source(
            c,
            name_z,
            buf.items.ptr,
            @intCast(buf.items.len),
        ) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    /// Emit one nested type-decl inside the primary struct. Mirrors
    /// the original loop body — preserved verbatim for nested decls
    /// only; the primary struct path goes through `emitRootFields`
    /// instead.
    fn emitNestedTypeDecl(self: *ZirDriver, type_def: ir.TypeDef, emitted: *std.StringHashMap(void)) !void {
        switch (type_def.kind) {
            .struct_def => |def| {
                const short_name = if (std.mem.lastIndexOf(u8, type_def.name, ".")) |dot_idx|
                    type_def.name[dot_idx + 1 ..]
                else
                    type_def.name;
                if (emitted.contains(short_name)) return;
                try emitted.put(short_name, {});

                var field_name_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                defer field_name_ptrs.deinit(self.allocator);
                var field_name_lens: std.ArrayListUnmanaged(u32) = .empty;
                defer field_name_lens.deinit(self.allocator);
                var field_type_refs: std.ArrayListUnmanaged(u32) = .empty;
                defer field_type_refs.deinit(self.allocator);

                for (def.fields) |field| {
                    try field_name_ptrs.append(self.allocator, field.name.ptr);
                    try field_name_lens.append(self.allocator, @intCast(field.name.len));
                    // Nested struct decls go through the older
                    // `add_struct_type` C-ABI which only takes static
                    // type Refs — primitives work, complex field
                    // types still degrade. Lifting nested struct
                    // emission onto the streaming root-field-body
                    // API would require an analogous fork-side
                    // change to `add_struct_type` (a separate
                    // mini-feature; out of scope here). The dominant
                    // case for non-primitive fields is the file's
                    // root struct, which goes through
                    // `emitRootFields` above.
                    const simple = mapReturnType(field.type_expr);
                    try field_type_refs.append(
                        self.allocator,
                        if (simple != 0) simple else 0,
                    );
                }

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

    /// Emit the primary struct's fields onto the file's root
    /// `struct_decl` via the fork's streaming root-field-body API.
    /// The Zig fork hard-pins this struct_decl at instruction 0, so
    /// every `@import("...")` of this emission's file yields the same
    /// `InternPool.Index` — a single canonical nominal identity for
    /// the Zap struct, regardless of how many other emissions
    /// reference it.
    ///
    /// Each field is dispatched on its `ZigType` shape:
    ///
    /// - Primitives (`i64`, `f64`, `bool`, …, `string`/`atom`/`nil`)
    ///   → `set_root_field_static` with the primitive's named ZIR Ref.
    ///
    /// - Nominal struct refs, lists, maps, tuples, or other types
    ///   that need a multi-instruction type body → bracket the
    ///   emission with `begin_root_field_body` / `end_root_field_body`
    ///   and reuse `emitImportedTypeRef`, the same helper that
    ///   already handles every `ZigType` shape in body context for
    ///   parameter and capture types.
    fn emitRootFields(self: *ZirDriver, def: ir.StructDef) !void {
        if (def.fields.len == 0) return;
        for (def.fields) |field| try self.emitRootFieldType(field);
    }

    /// Emit one root field's name + type body via the streaming API.
    /// Picks the static-ref fast path for primitives, the recorded
    /// body path otherwise.
    ///
    /// For fields marked `FieldStorage.indirect` (self-referential
    /// fields, detected by `analyzeStructFieldStorage`), the source-
    /// level `ZigType` is rewritten into the matching pointer-
    /// indirected shape before being lowered. The two cases that
    /// matter:
    ///
    /// - source `?T` where T transitively includes the owner
    ///   → lower as `?*const T` (the natural binary-tree shape)
    /// - source `T` where T transitively includes the owner
    ///   → lower as `*const T` (uninhabited at the source level —
    ///     value-typed self-recursion has no terminator. Compiles,
    ///     but cannot be constructed, exactly as if the user had
    ///     declared a struct with no nullable child)
    ///
    /// Only the field's storage shape is rewritten — pattern
    /// matching, field access, and construction all observe the
    /// source-level type. The codegen plumbing for those (auto-deref
    /// on access, heap-allocate on construction) is the next
    /// portion of the recursive-storage work.
    fn emitRootFieldType(self: *ZirDriver, field: ir.StructFieldDef) !void {
        const lowered_type = if (field.storage == .indirect)
            try self.indirectFieldType(field.type_expr)
        else
            field.type_expr;

        const simple = mapReturnType(lowered_type);
        if (simple != 0) {
            if (zir_builder_set_root_field_static(
                self.handle,
                field.name.ptr,
                @intCast(field.name.len),
                simple,
            ) != 0) return error.EmitFailed;
            return;
        }

        // Non-primitive: open a transient body, emit the type
        // expression's instructions into it, close with the result Ref.
        if (zir_builder_begin_root_field_body(
            self.handle,
            field.name.ptr,
            @intCast(field.name.len),
        ) != 0) return error.EmitFailed;

        const final_ref = self.emitImportedTypeRef(lowered_type) catch |err| {
            // Best-effort cleanup: end the body with `void_value` so
            // the field at least exists in the struct decl rather
            // than the builder being left in an inconsistent state.
            // The original error is propagated; this just keeps
            // subsequent fields emittable.
            _ = zir_builder_end_root_field_body(
                self.handle,
                @intFromEnum(Zir.Inst.Ref.void_value),
            );
            return err;
        };

        if (zir_builder_end_root_field_body(self.handle, final_ref) != 0) {
            return error.EmitFailed;
        }
    }

    /// Rewrite a source-level field type into its
    /// indirect-storage shape: insert a `*const T` between the
    /// outer optional (if any) and the recursive nominal target.
    ///
    /// `?T`     → `?*const T`
    /// `T`      → `*const T` (uninhabited at the source level, but
    ///            we still synthesize a valid type so the struct
    ///            compiles — Sema rejects construction at the leaf)
    /// other shapes (list/map/tuple containing self) fall through
    /// unchanged today; future work could extend the rewrite to
    /// indirect through container element positions, but the common
    /// recursive-tree pattern uses optional or bare struct refs.
    fn typeRewriteAllocator(self: *ZirDriver) Allocator {
        if (self.type_rewrite_arena) |*arena| return arena.allocator();

        self.type_rewrite_arena = std.heap.ArenaAllocator.init(self.allocator);
        return self.type_rewrite_arena.?.allocator();
    }

    fn createTypeRewriteNode(self: *ZirDriver, zig_type: ir.ZigType) BuildError!*ir.ZigType {
        const node = try self.typeRewriteAllocator().create(ir.ZigType);
        node.* = zig_type;
        return node;
    }

    fn indirectFieldType(self: *ZirDriver, t: ir.ZigType) BuildError!ir.ZigType {
        return switch (t) {
            .optional => |inner| blk: {
                const ptr_inner_box = try self.createTypeRewriteNode(inner.*);
                const ptr_box = try self.createTypeRewriteNode(.{ .ptr = ptr_inner_box });
                break :blk .{ .optional = ptr_box };
            },
            .struct_ref => blk: {
                const inner_box = try self.createTypeRewriteNode(t);
                break :blk .{ .ptr = inner_box };
            },
            else => t,
        };
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

    /// A struct is "recursive" iff at least one of its fields was assigned
    /// `FieldStorage.indirect` by the IR builder's SCC walk
    /// (`analyzeStructFieldStorage` / `zigTypeReachesStructInCycle`). That's
    /// the same condition that already breaks the layout cycle with a
    /// pointer at the field level.
    ///
    /// The ZIR backend uses this predicate to decide whether to box
    /// values of the struct uniformly: parameters lower to `?*const T` /
    /// `*const T` instead of `?T` / `T`, returns lower to `*const T`,
    /// and construction sites heap-promote the outer aggregate so the
    /// dest local holds `*const T`. Indirect-storage field reads then
    /// stop auto-dereffing, since the consumer's storage already matches
    /// the field's `?*const T` representation. With the source Arc
    /// preserved through every call, `releaseAny(T, alloc, ptr)` at the
    /// end of an owning function deep-releases the entire substructure.
    fn isRecursiveStruct(self: *const ZirDriver, type_name: []const u8) bool {
        const def = self.findStructDef(type_name) orelse return false;
        for (def.fields) |field| {
            if (field.storage == .indirect) return true;
        }
        return false;
    }

    /// `isRecursiveStruct` accepting a `ZigType`: returns true when the
    /// type names a recursive struct (directly or as an optional/pointer
    /// over one), false for primitives, lists, maps, tuples, etc. Used
    /// at parameter/return emission to decide whether to lower to a
    /// boxed pointer representation.
    fn zigTypeIsRecursiveStruct(self: *const ZirDriver, t: ir.ZigType) bool {
        return switch (t) {
            .struct_ref => |name| self.isRecursiveStruct(name),
            .optional => |inner| self.zigTypeIsRecursiveStruct(inner.*),
            else => false,
        };
    }

    /// Box recursive struct types in a `ZigType`: `Tree` becomes `*const Tree`,
    /// `?Tree` becomes `?*const Tree`. Non-recursive types pass through. The
    /// transformation matches `indirectFieldType` (same `*const` indirection
    /// already used to break the layout cycle at struct fields), but here it
    /// is applied at parameter / return / construction-result positions so
    /// recursive values are uniformly represented as pointers across the
    /// whole call boundary, not just inside containing structs. The boxed
    /// representation preserves the source-Arc pointer through every call,
    /// which is what makes `releaseAny(T, alloc, ptr)` deep-release the
    /// entire substructure correctly at end-of-life points (Perceus drops,
    /// optional_dispatch struct-branch exits).
    ///
    /// Allocates child `ZigType` nodes from the driver-owned type rewrite
    /// arena to mirror `indirectFieldType`'s strategy. The nodes live for the
    /// emission lifetime and are released with the driver.
    fn boxRecursiveZigType(self: *ZirDriver, t: ir.ZigType) BuildError!ir.ZigType {
        return switch (t) {
            .struct_ref => |name| blk: {
                if (!self.isRecursiveStruct(name)) break :blk t;
                const inner_box = try self.createTypeRewriteNode(t);
                break :blk .{ .ptr = inner_box };
            },
            .optional => |inner_ptr| blk: {
                if (!self.zigTypeIsRecursiveStruct(inner_ptr.*)) break :blk t;
                const ptr_inner = try self.createTypeRewriteNode(inner_ptr.*);
                const ptr_box = try self.createTypeRewriteNode(.{ .ptr = ptr_inner });
                break :blk .{ .optional = ptr_box };
            },
            else => t,
        };
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

    /// Convert a dotted struct prefix (e.g. "Zap.Env" → "Zap_Env",
    /// "IO.Mode" → "IO") into the underscore-separated ZIR struct name,
    /// writing the result into the caller-provided buffer. Returns the
    /// borrowed slice into the buffer, or null when the prefix is too
    /// long for the buffer.
    fn dottedPrefixToImportName(prefix: []const u8, buf: []u8) ?[]const u8 {
        if (prefix.len > buf.len) return null;
        @memcpy(buf[0..prefix.len], prefix);
        for (buf[0..prefix.len]) |*ch| {
            if (ch.* == '.') ch.* = '_';
        }
        return buf[0..prefix.len];
    }

    /// Emit a ZIR ref to a struct type by name. Dispatches on whether
    /// the struct is the primary of the current emission, nested
    /// inside the primary, foreign top-level (own emission's root),
    /// or foreign nested-in-other-emission. Each case maps to a
    /// specific ZIR sequence:
    ///
    /// - **Primary** (the file IS this struct): `@This()` — self
    ///   imports are rejected by Zig's module system, and `@This()`
    ///   is the canonical root struct type inside the current
    ///   emission.
    /// - **Nested in primary**: `decl_val(short_name)` — the struct
    ///   is emitted as a nested `pub const` decl by
    ///   `emitNestedTypeDecl`.
    /// - **Foreign top-level** (no dot): `@import(name)` — the
    ///   foreign emission's file IS that struct, so its import is
    ///   directly the type.
    /// - **Foreign nested**: `@import(prefix_struct).short_name` —
    ///   the foreign emission's file is the prefix struct, and the
    ///   nested decl is reached as a field on it.
    fn emitStructTypeRef(self: *const ZirDriver, name: []const u8) BuildError!u32 {
        const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
            name[dot_idx + 1 ..]
        else
            name;

        // Parametric union/enum specializations (Step 3.6) live as
        // `pub const <Name> = union(enum) {...};` inside a synthetic
        // top-level Zig source file. The file IS a struct (file-IS-
        // struct convention), so `@import(name)` yields the struct
        // and the actual union/enum type lives one field-access
        // deeper. Detect this case once and reuse it across both the
        // "no current emission" early return and the explicit
        // foreign-top-level branch below — a parametric union must
        // emit `@import(name).<name>` regardless of which path
        // resolves the type ref.
        const is_specialization_decl = std.mem.indexOf(u8, name, ".") == null and
            (self.findUnionDef(name) != null or self.findEnumDef(name));

        const current_struct = self.current_emit_struct orelse {
            // No current emission context (e.g. top-level program
            // header) — fall back to import-by-name. Same behavior
            // as a foreign top-level reference.
            const import_ref = zir_builder_emit_import(self.handle, name.ptr, @intCast(name.len));
            if (import_ref == error_ref) return error.EmitFailed;
            if (is_specialization_decl) {
                const ref = zir_builder_emit_field_val(self.handle, import_ref, name.ptr, @intCast(name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            }
            return import_ref;
        };

        var buf: [256]u8 = undefined;
        switch (classifyTypeDef(name, current_struct, &buf)) {
            .primary => {
                const ref = zir_builder_emit_this_type(self.handle);
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .nested => {
                const ref = zir_builder_emit_decl_val(self.handle, short_name.ptr, @intCast(short_name.len));
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .foreign => {
                if (std.mem.lastIndexOf(u8, name, ".")) |_| {
                    // Foreign nested: `@import(prefix).short_name`
                    var struct_name_buf: [256]u8 = undefined;
                    const struct_name = structToImportName(name, &struct_name_buf);
                    const import_ref = zir_builder_emit_import(self.handle, struct_name.ptr, @intCast(struct_name.len));
                    if (import_ref == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_field_val(self.handle, import_ref, short_name.ptr, @intCast(short_name.len));
                    if (ref == error_ref) return error.EmitFailed;
                    return ref;
                }
                // Foreign top-level: `@import(name)`. For a plain
                // struct emission the file IS the struct (Step 3 /
                // Step 3.5), so the import directly yields the type.
                // For a parametric union/enum specialization (Step 3.6)
                // the file is the struct but the type is a `pub const`
                // *inside* that file — reach it via
                // `@import(name).<name>` (see `is_specialization_decl`
                // computed above the dispatch).
                const import_ref = zir_builder_emit_import(self.handle, name.ptr, @intCast(name.len));
                if (import_ref == error_ref) return error.EmitFailed;
                if (is_specialization_decl) {
                    const ref = zir_builder_emit_field_val(self.handle, import_ref, name.ptr, @intCast(name.len));
                    if (ref == error_ref) return error.EmitFailed;
                    return ref;
                }
                return import_ref;
            },
        }
    }

    /// Convert a struct_ref name to the ZIR struct name that defines it,
    /// writing the result into the caller-provided buffer.
    /// "Range" → "Range", "Zap.Env" → "Zap_Env", "IO.Mode" → "IO".
    /// Returns the borrowed slice into the buffer (or `type_name` itself
    /// when the name is already a single segment).
    fn structToImportName(type_name: []const u8, buf: []u8) []const u8 {
        if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_idx| {
            return dottedPrefixToImportName(type_name[0..dot_idx], buf) orelse type_name;
        }
        return type_name;
    }

    /// Map a Zig type name string to a ZIR type Ref for union variant types.
    fn mapTypeNameToRef(_: *const ZirDriver, type_name: []const u8) u32 {
        if (std.mem.eql(u8, type_name, "[]const u8")) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type);
        if (std.mem.eql(u8, type_name, "bool")) return @intFromEnum(Zir.Inst.Ref.bool_type);
        if (std.mem.eql(u8, type_name, "i128")) return @intFromEnum(Zir.Inst.Ref.i128_type);
        if (std.mem.eql(u8, type_name, "i64")) return @intFromEnum(Zir.Inst.Ref.i64_type);
        if (std.mem.eql(u8, type_name, "i32")) return @intFromEnum(Zir.Inst.Ref.i32_type);
        if (std.mem.eql(u8, type_name, "i16")) return @intFromEnum(Zir.Inst.Ref.i16_type);
        if (std.mem.eql(u8, type_name, "i8")) return @intFromEnum(Zir.Inst.Ref.i8_type);
        if (std.mem.eql(u8, type_name, "u128")) return @intFromEnum(Zir.Inst.Ref.u128_type);
        if (std.mem.eql(u8, type_name, "u64")) return @intFromEnum(Zir.Inst.Ref.u64_type);
        if (std.mem.eql(u8, type_name, "u32")) return @intFromEnum(Zir.Inst.Ref.u32_type);
        if (std.mem.eql(u8, type_name, "u16")) return @intFromEnum(Zir.Inst.Ref.u16_type);
        if (std.mem.eql(u8, type_name, "u8")) return @intFromEnum(Zir.Inst.Ref.u8_type);
        if (std.mem.eql(u8, type_name, "f128")) return @intFromEnum(Zir.Inst.Ref.f128_type);
        if (std.mem.eql(u8, type_name, "f80")) return @intFromEnum(Zir.Inst.Ref.f80_type);
        if (std.mem.eql(u8, type_name, "f64")) return @intFromEnum(Zir.Inst.Ref.f64_type);
        if (std.mem.eql(u8, type_name, "f32")) return @intFromEnum(Zir.Inst.Ref.f32_type);
        if (std.mem.eql(u8, type_name, "f16")) return @intFromEnum(Zir.Inst.Ref.f16_type);
        if (std.mem.eql(u8, type_name, "usize")) return @intFromEnum(Zir.Inst.Ref.usize_type);
        if (std.mem.eql(u8, type_name, "void")) return @intFromEnum(Zir.Inst.Ref.void_type);
        return 0; // void fallback
    }

    fn refForValueLocal(self: *ZirDriver, local: ir.LocalId) BuildError!u32 {
        if (self.reuse_backed_tuple_locals.get(local)) |arity| {
            const ptr_ref = try self.refForLocal(local);
            var names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens: std.ArrayListUnmanaged(u32) = .empty;
            defer names_lens.deinit(self.allocator);
            var values: std.ArrayListUnmanaged(u32) = .empty;
            defer values.deinit(self.allocator);
            var index_field_name_batch = try IndexFieldNameBatch.init(self.allocator, arity);
            defer index_field_name_batch.deinit();
            for (0..arity) |i| {
                const name = index_field_name_batch.get(i);
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

            var names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
            defer names_ptrs.deinit(self.allocator);
            var names_lens: std.ArrayListUnmanaged(u32) = .empty;
            defer names_lens.deinit(self.allocator);
            var values: std.ArrayListUnmanaged(u32) = .empty;
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

    /// Find an IR function by its local_name (unmangled name within its
    /// struct). Matches both the exact arity-suffixed form and the bare
    /// base form. Restricted to functions whose struct is *not* the
    /// current emit struct so a bare reference resolves only against
    /// imported names. Used by macro-expanded code that emits a bare
    /// call to a function brought into scope by `use SomeStruct`.
    fn findFunctionByLocalName(self: *const ZirDriver, local_name: []const u8) ?ir.Function {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                // Only match functions from OTHER structs
                if (func.struct_name == null) continue;
                if (self.current_emit_struct) |cem| {
                    if (std.mem.eql(u8, func.struct_name.?, cem)) continue;
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

    /// Find a compiler-generated typed-clause entrypoint for a source
    /// function group and clause index.
    fn findFunctionBySourceClause(self: *const ZirDriver, group_id: ir.FunctionId, clause_index: u32) ?ir.Function {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.source_group_id == group_id and func.source_clause_index == clause_index) return func;
            }
        }
        return null;
    }

    /// Locate a monomorphized impl function compiled into the caller
    /// struct's emitted Zig namespace. The IR call name has the shape
    /// `<TargetStruct>__<func>__<arity>` (e.g. `List__member?__2`); the
    /// monomorphizer emits the specialized copy with a `local_name` of
    /// `<TargetStruct>_<func>__<typeArg>__<arity>` (one underscore
    /// between the target struct and the function name, two as the
    /// outer separators). We rebuild the prefix `<TargetStruct>_<func>__`
    /// and the suffix `__<arity>` from the call name and scan the
    /// program for a matching `local_name` whose `struct_name` (the
    /// emitted Zig namespace, which the IR field still calls a
    /// "struct") is the caller struct.
    fn findMonomorphizedImplFor(self: *const ZirDriver, caller_struct: []const u8, call_name: []const u8) BuildError!?ir.Function {
        const sep = std.mem.indexOf(u8, call_name, "__") orelse return null;
        const target_struct = call_name[0..sep];
        const rest = call_name[sep + 2 ..];
        const arity_sep = std.mem.lastIndexOf(u8, rest, "__") orelse return null;
        const func_base = rest[0..arity_sep];
        const arity_suffix = rest[arity_sep..];
        const prog = self.program orelse return null;
        var expected_prefix_buf: ?[]u8 = null;
        defer if (expected_prefix_buf) |buf| self.allocator.free(buf);

        for (prog.functions) |func| {
            const emit_ns = func.struct_name orelse continue;
            if (!std.mem.eql(u8, emit_ns, caller_struct)) continue;
            const expected_prefix = expected_prefix_buf orelse blk: {
                const buf = try std.fmt.allocPrint(self.allocator, "{s}_{s}__", .{ target_struct, func_base });
                expected_prefix_buf = buf;
                break :blk buf;
            };
            if (!std.mem.startsWith(u8, func.local_name, expected_prefix)) continue;
            if (!std.mem.endsWith(u8, func.local_name, arity_suffix)) continue;
            return func;
        }
        return null;
    }

    /// Emit a cross-struct function reference: @import("TargetStruct").local_name
    fn emitCrossStructRef(self: *ZirDriver, target_struct: []const u8, local_name: []const u8) BuildError!u32 {
        const import_ref = zir_builder_emit_import(self.handle, target_struct.ptr, @intCast(target_struct.len));
        if (import_ref == error_ref) return error.EmitFailed;
        const fn_ref = zir_builder_emit_field_val(self.handle, import_ref, local_name.ptr, @intCast(local_name.len));
        if (fn_ref == error_ref) return error.EmitFailed;
        return fn_ref;
    }

    /// Emit a cross-struct function call: @import("TargetStruct").local_name(args)
    fn emitCrossStructCall(self: *ZirDriver, target_struct: []const u8, local_name: []const u8, arg_refs: []const u32) BuildError!u32 {
        const import_ref = zir_builder_emit_import(self.handle, target_struct.ptr, @intCast(target_struct.len));
        if (import_ref == error_ref) return error.EmitFailed;
        const fn_ref = zir_builder_emit_field_val(self.handle, import_ref, local_name.ptr, @intCast(local_name.len));
        if (fn_ref == error_ref) return error.EmitFailed;
        const ref = zir_builder_emit_call_ref(self.handle, fn_ref, arg_refs.ptr, @intCast(arg_refs.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    const NamespaceChild = struct {
        name: []const u8, // "Runtime" (short name for re-export)
        full_struct: []const u8, // "Zest_Runtime" (full struct name for @import)
    };

    /// Deduplicate a function list by local_name, keeping the last occurrence.
    /// Returns a new ArrayListUnmanaged with unique entries.
    fn deduplicateFunctions(allocator: std.mem.Allocator, funcs: []const ir.Function) !std.ArrayListUnmanaged(ir.Function) {
        // Build a map of local_name → last index
        var last_index = std.StringHashMap(usize).init(allocator);
        defer last_index.deinit();
        try last_index.ensureTotalCapacity(@intCast(funcs.len));
        for (funcs, 0..) |func, i| {
            const key = if (func.local_name.len > 0) func.local_name else func.name;
            try last_index.put(key, i);
        }
        // Collect functions in order, keeping only the last occurrence of each name
        var result: std.ArrayListUnmanaged(ir.Function) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, @intCast(last_index.count()));
        for (funcs, 0..) |func, i| {
            const key = if (func.local_name.len > 0) func.local_name else func.name;
            if (last_index.get(key)) |last_i| {
                if (last_i == i) {
                    result.appendAssumeCapacity(func);
                }
            }
        }
        return result;
    }

    fn deinitArrayListMap(comptime T: type, allocator: Allocator, map: *std.StringHashMap(std.ArrayListUnmanaged(T))) void {
        var value_iter = map.valueIterator();
        while (value_iter.next()) |list| {
            list.deinit(allocator);
        }
        map.deinit();
    }

    const ProgramFunctionGroups = struct {
        root_funcs: std.ArrayListUnmanaged(ir.Function) = .empty,
        struct_funcs: std.StringHashMap(std.ArrayListUnmanaged(ir.Function)),
        all_struct_names: std.StringHashMap(void),

        fn init(allocator: Allocator) ProgramFunctionGroups {
            return .{
                .struct_funcs = std.StringHashMap(std.ArrayListUnmanaged(ir.Function)).init(allocator),
                .all_struct_names = std.StringHashMap(void).init(allocator),
            };
        }

        fn deinit(self: *ProgramFunctionGroups, allocator: Allocator) void {
            self.root_funcs.deinit(allocator);
            deinitArrayListMap(ir.Function, allocator, &self.struct_funcs);
            self.all_struct_names.deinit();
        }
    };

    fn buildProgramFunctionGroups(allocator: Allocator, program: ir.Program) !ProgramFunctionGroups {
        var groups = ProgramFunctionGroups.init(allocator);
        errdefer groups.deinit(allocator);

        // First pass: collect all functions per struct, allowing duplicates.
        var raw_root_funcs: std.ArrayListUnmanaged(ir.Function) = .empty;
        defer raw_root_funcs.deinit(allocator);

        var raw_struct_funcs = std.StringHashMap(std.ArrayListUnmanaged(ir.Function)).init(allocator);
        defer deinitArrayListMap(ir.Function, allocator, &raw_struct_funcs);

        try groups.all_struct_names.ensureTotalCapacity(@intCast(program.functions.len));
        try raw_struct_funcs.ensureTotalCapacity(@intCast(program.functions.len));

        for (program.functions) |func| {
            if (func.struct_name) |mod| {
                try groups.all_struct_names.put(mod, {});
            }
            const is_entry = if (program.entry) |eid| func.id == eid else false;
            if (is_entry or func.struct_name == null) {
                try raw_root_funcs.append(allocator, func);
            } else {
                const mod = func.struct_name.?;
                const gop = try raw_struct_funcs.getOrPut(mod);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, func);
            }
        }

        // Second pass: deduplicate by local_name within each group, keeping last.
        groups.root_funcs = try deduplicateFunctions(allocator, raw_root_funcs.items);
        try groups.struct_funcs.ensureTotalCapacity(raw_struct_funcs.count());
        var raw_iter = raw_struct_funcs.iterator();
        while (raw_iter.next()) |entry| {
            var deduped = try deduplicateFunctions(allocator, entry.value_ptr.items);
            errdefer deduped.deinit(allocator);
            try groups.struct_funcs.put(entry.key_ptr.*, deduped);
        }

        return groups;
    }

    // -- Program emission -----------------------------------------------------

    fn debugSourcePathForFunctions(functions: []const ir.Function) ?[]const u8 {
        for (functions) |func| {
            if (func.debug_source_path) |path| {
                if (path.len > 0) return path;
            }
        }
        return null;
    }

    fn selectiveEmissionEnabled(self: *const ZirDriver) bool {
        return self.selected_structs != null;
    }

    fn shouldEmitStruct(self: *const ZirDriver, struct_name: []const u8) bool {
        const selected = self.selected_structs orelse return true;
        // A synthesized closure struct (`__closure_N`) is freshly produced
        // by the desugar on EVERY compile (program-wide unique counter) and
        // is never adopted from a prior sidecar — so it can never be an
        // "unchanged" struct the selective filter may skip. It must always
        // be emitted alongside the selection, or its `impl Callable.call`
        // body + per-instantiation vtable would reference an un-emitted
        // symbol (EmitFailed). This is the seam that made a boxed closure
        // constructed INLINE in a selected struct (e.g. the script `main`
        // body) emit an empty `comptime {}` module while the SAME closure
        // built inside a separately-selected method emitted correctly.
        if (std.mem.startsWith(u8, struct_name, "__closure_")) return true;
        for (selected) |selected_name| {
            if (std.mem.eql(u8, selected_name, struct_name)) return true;
        }
        return false;
    }

    fn shouldEmitRoot(self: *const ZirDriver) bool {
        return if (self.selected_structs == null) true else self.selected_emit_root;
    }

    fn emitDebugStatement(self: *ZirDriver, func: ir.Function) !void {
        if (zir_builder_emit_dbg_stmt(self.handle, func.debug_line, func.debug_column) != 0) {
            return error.EmitFailed;
        }
    }

    pub fn buildProgram(self: *ZirDriver, program: ir.Program) !void {
        self.program = program;
        self.capture_closure_function_map.clearRetainingCapacity();
        self.capture_param_derived_closure_map.clearRetainingCapacity();
        try self.collectClosureConstructionCaptureTypes(program);

        const ctx = self.compilation_ctx;

        // ── Step 1: Group functions by struct ────────────────────────
        if (self.progress) |progress| progress.stage("ZIR: grouping functions", .{});
        var function_groups = try buildProgramFunctionGroups(self.allocator, program);
        defer function_groups.deinit(self.allocator);
        const struct_funcs = &function_groups.struct_funcs;
        const root_funcs = &function_groups.root_funcs;
        // Track every struct name we see (including namespace-only structs
        // with no functions of their own) so re-export emission below can
        // generate parent shells for nested namespaces.
        const all_struct_names = &function_groups.all_struct_names;

        // ── Step 2: Detect namespace hierarchy for re-export structs ─
        // Scan every struct name (function-bearing and namespace-only) for
        // parent_child patterns. A parent re-export is generated when a struct
        // name contains '_'.
        var namespace_children = std.StringHashMap(std.ArrayListUnmanaged(NamespaceChild)).init(self.allocator);
        defer deinitArrayListMap(NamespaceChild, self.allocator, &namespace_children);
        try namespace_children.ensureTotalCapacity(all_struct_names.count());
        {
            var name_iter = all_struct_names.iterator();
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
                        if (std.mem.eql(u8, existing.full_struct, mod_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try gop.value_ptr.append(self.allocator, .{ .name = child, .full_struct = mod_name });
                    }
                }
            }
        }

        // Register empty stub structs for any namespace name we've seen but
        // that has no functions in this program (typically namespace parents
        // whose only purpose is to host children via re-export). This lets
        // `@import("...")` resolve them later.
        if (self.progress) |progress| progress.stage("ZIR: registering modules", .{});
        if (!self.selectiveEmissionEnabled()) {
            if (ctx) |c| {
                var name_iter2 = all_struct_names.iterator();
                while (name_iter2.next()) |entry| {
                    const mod_name = entry.key_ptr.*;
                    if (!struct_funcs.contains(mod_name)) {
                        const mod_name_z = try self.allocator.dupeZ(u8, mod_name);
                        defer self.allocator.free(mod_name_z);
                        const stub = "comptime {}\n";
                        dumpSyntheticSourceIfRequested(mod_name_z, stub.ptr, @intCast(stub.len));
                        if (zir_compilation_add_struct_source(c, mod_name_z, stub.ptr, @intCast(stub.len)) != 0) {
                            return error.EmitFailed;
                        }
                    }
                }
            }
        }

        // ── Step 3: Emit each leaf struct as its own ZIR struct ──────
        const struct_total = struct_funcs.count();
        var struct_index: usize = 0;
        if (ctx) |c| {
            var leaf_iter = struct_funcs.iterator();
            while (leaf_iter.next()) |entry| {
                const mod_name = entry.key_ptr.*;
                const funcs = entry.value_ptr.items;
                if (funcs.len == 0) continue;
                if (!self.shouldEmitStruct(mod_name)) continue;
                struct_index += 1;
                if (self.progress) |progress| progress.stage("ZIR: emitting struct {d}/{d} {s}", .{ struct_index, struct_total, mod_name });

                const mod_name_z = try self.allocator.dupeZ(u8, mod_name);
                defer self.allocator.free(mod_name_z);
                const stub = "comptime {}\n";
                dumpSyntheticSourceIfRequested(mod_name_z, stub.ptr, @intCast(stub.len));
                if (zir_compilation_add_struct_source(c, mod_name_z, stub.ptr, @intCast(stub.len)) != 0) {
                    return error.ZirInjectionFailed;
                }
                if (debugSourcePathForFunctions(funcs)) |debug_source_path| {
                    if (zir_compilation_set_struct_debug_source(c, mod_name.ptr, @intCast(mod_name.len), debug_source_path.ptr, @intCast(debug_source_path.len)) != 0) {
                        return error.ZirInjectionFailed;
                    }
                }

                const mod_handle = zir_builder_create() orelse return error.ZirCreateFailed;
                {
                    var struct_scope = StructEmissionScope.enter(self, mod_handle, mod_name);
                    defer struct_scope.deinit();

                    // Emit struct type declarations before functions so they
                    // can be referenced in return types and parameter types.
                    try self.emitStructTypeDecls();

                    for (funcs) |func| {
                        self.reuse_backed_struct_locals.clearRetainingCapacity();
                        self.reuse_backed_union_locals.clearRetainingCapacity();
                        self.reuse_backed_tuple_locals.clearRetainingCapacity();
                        self.emitFunction(func) catch |err| {
                            std.log.err("ZIR emit failed for function {s}: {s}", .{ func.name, @errorName(err) });
                            return err;
                        };
                    }

                    if (zir_builder_inject_struct(struct_scope.handle(), c, mod_name_z) != 0) {
                        return error.ZirInjectionFailed;
                    }
                    struct_scope.markConsumedByInjection();
                }
            }

            // ── Step 3.5: Emit fields-only top-level structs ─────────
            // The file-IS-the-struct architecture requires every
            // Zap struct that consumers reference via `@import("X")`
            // to have a registered ZIR file. Step 3 covers structs
            // with at least one function (`struct_funcs.contains`),
            // but top-level data structs (e.g. `pub struct Point {
            // x, y }` with no methods) have empty function lists and
            // are skipped there. Emit a fields-only ZIR file for
            // each such struct so its `@import` resolves to a
            // canonical type with this emission's `InternPool.Index`.
            if (self.progress) |progress| progress.stage("ZIR: emitting field-only structs", .{});
            for (self.program.?.type_defs) |type_def| {
                if (type_def.kind != .struct_def) continue;
                const def = type_def.kind.struct_def;
                if (def.fields.len == 0) continue;
                // Skip nested types (dotted names) — they're emitted
                // inside their parent's ZIR by `emitNestedTypeDecl`.
                if (std.mem.indexOf(u8, type_def.name, ".") != null) continue;
                // Skip any struct already covered by Step 3.
                if (struct_funcs.contains(type_def.name)) continue;
                if (!self.shouldEmitStruct(type_def.name)) continue;

                const struct_name_z = try self.allocator.dupeZ(u8, type_def.name);
                defer self.allocator.free(struct_name_z);
                const stub = "comptime {}\n";
                dumpSyntheticSourceIfRequested(struct_name_z, stub.ptr, @intCast(stub.len));
                if (zir_compilation_add_struct_source(c, struct_name_z, stub.ptr, @intCast(stub.len)) != 0) {
                    return error.ZirInjectionFailed;
                }

                const struct_handle = zir_builder_create() orelse return error.ZirCreateFailed;
                {
                    var struct_scope = StructEmissionScope.enter(self, struct_handle, type_def.name);
                    defer struct_scope.deinit();

                    try self.emitStructTypeDecls();

                    if (zir_builder_inject_struct(struct_scope.handle(), c, struct_name_z) != 0) {
                        return error.ZirInjectionFailed;
                    }
                    struct_scope.markConsumedByInjection();
                }
            }

            // ── Step 3.6: Emit per-instantiation union/enum specializations ───
            // The IR layer emits one `union_def` / `enum_def` TypeDef per
            // parametric specialization (`Option_i64`, `Result_i64_String`,
            // etc.). These have no Zap struct ownership — they're derived
            // names produced by `populateAppliedSpecializations`. The
            // file-IS-the-struct architecture means a Zig file is always a
            // struct, so we can't make `@import("Option_i64")` *be* the
            // union directly; instead we inject a stub source file
            // `Option_i64.zig` containing
            //
            //     pub const Option_i64 = union(enum) { Some: i64, None };
            //
            // and the consumer resolves `@import("Option_i64").Option_i64`
            // to the union type. The same shape works for unit-only
            // tagged unions (enum_def): `pub const Color = enum { Red, Blue };`.
            //
            // This is the construction-side complement to the per-
            // instantiation `union_def`/`enum_def` TypeDefs the IR already
            // builds — Round 1 emitted them but the ZIR layer silently
            // dropped them (only `struct_def` flowed through Step 3.5).
            // With Step 3.6 in place, `union_init`'s ZIR handler can
            // always go through `emitStructTypeRef` regardless of
            // return-position context, removing the previous
            // `cached_union_ret_type_ref` fallback to `struct_init_anon`.
            //
            // Concrete non-parametric tagged unions (`Color { Red, Blue }`)
            // also land in `prog.type_defs` as `union_def`/`enum_def`, but
            // their TypeDef name carries a dot (`Color` lives inside its
            // owner struct, e.g. `MyMod.Color`) — those are emitted as
            // nested decls inside the owner's primary emission and we
            // skip them here.
            if (self.progress) |progress| progress.stage("ZIR: emitting parametric union/enum specializations", .{});
            for (self.program.?.type_defs) |type_def| {
                switch (type_def.kind) {
                    .union_def, .enum_def => {},
                    else => continue,
                }
                // Nested decls (`Owner.Color`) are emitted inside the
                // owner's primary emission via `emitNestedTypeDecl` — skip.
                if (std.mem.indexOf(u8, type_def.name, ".") != null) continue;
                // A non-parametric top-level tagged-union doesn't need
                // a synthetic file when it shares a name with a struct
                // emission that already exists (e.g. a user `pub union
                // Top {…}` registered alongside `pub struct Top {…}` —
                // Blocker B's namespace merge handles this case at the
                // resolution layer).
                if (struct_funcs.contains(type_def.name)) continue;
                if (!self.shouldEmitStruct(type_def.name)) continue;
                try self.emitSpecializationSourceFile(c, type_def);
            }

            // ── Step 3.7: Emit per-protocol vtable types ──────────────
            // The IR layer emits one `protocol_vtable_def` TypeDef per
            // `pub protocol` reachable from the program (named
            // `<Protocol>VTable`). The construction-site lowering
            // (Phase 1.2.5.c) and consumption-site lowering (Phase
            // 1.2.5.d) reach the type via `@import("<Protocol>VTable")
            // .<Protocol>VTable`, so step 3.7 must register a
            // synthetic source file under each name.
            //
            // The source we emit is a `pub const <Protocol>VTable =
            // extern struct { method_a: *const fn(...) ..., ... };`
            // declaration whose method fields are function pointers
            // with the receiver type-erased to `?*anyopaque`. Other
            // params and the return type retain their declared
            // shape, lowered through `mapReturnType` for primitives
            // and through `struct_ref`/`@import` for nominals.
            if (self.progress) |progress| progress.stage("ZIR: emitting per-protocol vtable types", .{});
            for (self.program.?.type_defs) |type_def| {
                if (type_def.kind != .protocol_vtable_def) continue;
                if (!self.shouldEmitStruct(type_def.name)) continue;
                try self.emitProtocolVTableSourceFile(c, type_def);
            }

            // ── Step 3.7 continued: per-impl vtable instance constants ──
            // The IR layer emits one `protocol_vtable_instance_def`
            // TypeDef per `pub impl <Protocol> for <Target>` reachable
            // from the program (named `<Protocol>VTable_for_<Target>`).
            // The construction-site lowering (Phase 1.2.5.c) takes the
            // address of this constant and writes it into the
            // `ProtocolBox.vtable` field at every site where a
            // concrete `<Target>` value is auto-boxed as the protocol.
            //
            // The source we emit is a `pub const
            // <Protocol>VTable_for_<Target>: <Protocol>VTable = .{
            // .method_a = ..., ... };` declaration whose method-pointer
            // entries are `@ptrCast`s onto the impl's monomorphized
            // function symbol. The import line at the top of the
            // synthetic file pulls in `<Protocol>VTable`'s nominal
            // identity so Sema knows the declared type.
            if (self.progress) |progress| progress.stage("ZIR: emitting per-impl vtable instance constants", .{});
            for (self.program.?.type_defs) |type_def| {
                if (type_def.kind != .protocol_vtable_instance_def) continue;
                if (!self.shouldEmitStruct(type_def.name)) continue;
                try self.emitProtocolVTableInstanceSourceFile(c, type_def);
            }

            // ── Step 4: Generate namespace re-export structs ─────────
            // Skip parents that are also leaf structs (they already have ZIR injected).
            if (!self.selectiveEmissionEnabled()) {
                if (self.progress) |progress| progress.stage("ZIR: emitting namespace re-exports", .{});
                var ns_iter = namespace_children.iterator();
                while (ns_iter.next()) |entry| {
                    const parent_name = entry.key_ptr.*;
                    // If parent is a leaf struct with ZIR functions, skip re-export
                    // (can't overwrite its ZIR with source text)
                    if (struct_funcs.contains(parent_name)) continue;
                    // If parent is a namespace-only struct already registered as
                    // an empty stub above, the re-export source below will replace
                    // it — no extra work needed here.
                    if (all_struct_names.contains(parent_name) and !struct_funcs.contains(parent_name)) {
                        // Replace the empty stub with the re-export source
                    }

                    const children = entry.value_ptr.items;
                    var source_buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer source_buf.deinit(self.allocator);
                    for (children) |child| {
                        const line = try std.fmt.allocPrint(self.allocator, "pub const {s} = @import(\"{s}\");\n", .{ child.name, child.full_struct });
                        defer self.allocator.free(line);
                        try source_buf.appendSlice(self.allocator, line);
                    }
                    const source = try source_buf.toOwnedSlice(self.allocator);
                    defer self.allocator.free(source);

                    const parent_z = try self.allocator.dupeZ(u8, parent_name);
                    defer self.allocator.free(parent_z);
                    // This will overwrite the empty stub if already registered
                    dumpSyntheticSourceIfRequested(parent_z, source.ptr, @intCast(source.len));
                    // The Zig fork copies the bytes synchronously by writing
                    // them to the compilation cache before returning.
                    const registration_status = zir_compilation_add_struct_source(c, parent_z, source.ptr, @intCast(source.len));
                    if (registration_status != 0) {
                        return error.EmitFailed;
                    }
                }
            }
        }

        // ── Step 5: Emit root struct functions ───────────────────────
        if (self.shouldEmitRoot()) {
            if (self.progress) |progress| progress.stage("ZIR: emitting root functions", .{});
            self.current_emit_struct = null;
            if (ctx) |c| {
                if (debugSourcePathForFunctions(root_funcs.items)) |debug_source_path| {
                    if (zir_compilation_set_root_debug_source(c, debug_source_path.ptr, @intCast(debug_source_path.len)) != 0) {
                        return error.ZirInjectionFailed;
                    }
                }
            }
            for (root_funcs.items) |func| {
                self.reuse_backed_struct_locals.clearRetainingCapacity();
                self.reuse_backed_union_locals.clearRetainingCapacity();
                self.reuse_backed_tuple_locals.clearRetainingCapacity();
                self.emitFunction(func) catch |err| {
                    std.log.err("ZIR emit failed for function {s}: {s}", .{ func.name, @errorName(err) });
                    return err;
                };
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

                // Generated builder binaries use the rewritten runtime
                // source whose dispatchers compile away lazy startup.
                // Emit the explicit prologue before any BuilderRuntime
                // helper can touch runtime-managed memory.
                try self.emitMemoryStartupForEntryFromRuntime(rt);

                // Call BuilderRuntime.buildEnvFromArgv() → returns env struct
                const builder_rt = emitRuntimeNamespaceField(self.handle, rt, runtime_ns.builder_runtime);
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
                const serialize_ref = zir_builder_emit_call_ref(self.handle, serialize_fn, &ser_args, 1);
                if (serialize_ref == error_ref) return error.EmitFailed;

                if (zir_builder_emit_ret_void(self.handle) != 0) {
                    return error.EmitFailed;
                }
                if (zir_builder_end_func(self.handle) != 0) {
                    return error.EndFuncFailed;
                }
            }

            // P2-J2 — with the concurrency gate ON, emit the synthetic
            // `main` that runs the startup prologue on the OS stack and
            // then hands the user entry (emitted above under
            // `root_process_main_decl_name`) to the runtime's
            // root-process bootstrap.
            if (self.pending_root_main_return_type) |root_main_return_type| {
                try self.emitRootProcessMainWrapper(root_main_return_type);
            }

            // Phase 2.b — inject the root `pub const panic` namespace so
            // Zig's panic interface routes Zig-level safety panics (integer
            // divide-by-zero, `unreachable`, null-unwrap, non-Zap slice
            // bounds, `@panic`, …) through the Zap crash printer. Emitted
            // only when this compilation produced a real program entry (a
            // root `main`, or builder-mode `manifest`): an executable owns
            // the program-wide panic handler, whereas a library/object
            // output must not impose one on its consumer. Emitted after all
            // root functions so no function body is active (the const-decl
            // recorder requires `active_body == null`).
            if (!self.lib_mode and (self.emitted_main_entry or self.builder_entry != null)) {
                try self.emitRootPanicNamespace();
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
        const ref = try self.emitListCellRef(.i64);
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
    /// type argument when calling generic constructors (Map, List).
    /// Returns null for complex types (structs, nested containers) that
    /// require dynamic resolution via emitTypeRef.
    fn zigTypeToTypeRef(zig_type: ir.ZigType) ?u32 {
        return switch (zig_type) {
            .bool_type => @intFromEnum(Zir.Inst.Ref.bool_type),
            .i8 => @intFromEnum(Zir.Inst.Ref.i8_type),
            .i16 => @intFromEnum(Zir.Inst.Ref.i16_type),
            .i32 => @intFromEnum(Zir.Inst.Ref.i32_type),
            .i64 => @intFromEnum(Zir.Inst.Ref.i64_type),
            .i128 => @intFromEnum(Zir.Inst.Ref.i128_type),
            .u8 => @intFromEnum(Zir.Inst.Ref.u8_type),
            .u16 => @intFromEnum(Zir.Inst.Ref.u16_type),
            .u32 => @intFromEnum(Zir.Inst.Ref.u32_type),
            .u64 => @intFromEnum(Zir.Inst.Ref.u64_type),
            .u128 => @intFromEnum(Zir.Inst.Ref.u128_type),
            .usize => @intFromEnum(Zir.Inst.Ref.usize_type),
            .isize => @intFromEnum(Zir.Inst.Ref.isize_type),
            .f16 => @intFromEnum(Zir.Inst.Ref.f16_type),
            .f32 => @intFromEnum(Zir.Inst.Ref.f32_type),
            .f64 => @intFromEnum(Zir.Inst.Ref.f64_type),
            .f80 => @intFromEnum(Zir.Inst.Ref.f80_type),
            .f128 => @intFromEnum(Zir.Inst.Ref.f128_type),
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
                if (self.findStructDef(name) != null or self.findStructDef(short_name) != null) {
                    return try self.emitStructTypeRef(name);
                }
                return null;
            },
            .tagged_union => {
                // Enums use u32 atom IDs at runtime; use u32 as the element
                // type for List/Map rather than the Zig enum type.
                // This ensures enum values from lists are compatible with
                // Zap's atom-based pattern dispatch.
                return @intFromEnum(Zir.Inst.Ref.u32_type);
            },
            .list => |inner| {
                // Nested list: element type is ?*const List(T)
                // Get the inner List(T) type, call .empty() on it,
                // then use @TypeOf to get the optional pointer type.
                const inner_ref = try self.emitContainerElementTypeRef(inner.*);
                if (inner_ref) |iref| {
                    const type_args = [_]u32{iref};
                    const inner_list = try self.emitGenericContainerRef("List", &type_args);
                    // Call .empty() to get a value of type ?*const List(T)
                    const empty_fn = zir_builder_emit_field_val(self.handle, inner_list, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (empty_val == error_ref) return error.EmitFailed;
                    // @TypeOf(empty_val) gives ?*const List(T)
                    const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                    if (type_ref == error_ref) return error.EmitFailed;
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
                    const inner_map = try self.emitGenericContainerRef("Map", &type_args);
                    // Call .empty() to get ?*const MapOf(K, V), then @TypeOf
                    const empty_fn = zir_builder_emit_field_val(self.handle, inner_map, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (empty_val == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                    if (type_ref == error_ref) return error.EmitFailed;
                    return type_ref;
                }
                return null;
            },
            .term => return try self.emitTermTypeRef(),
            // A `[fn(i64) -> i64]` list (or map value) of boxed closures
            // lowers to a `List(ProtocolBox)` — the element is the runtime
            // fat-pointer carrier. Without this arm `emitListCellRef`
            // returns null and the list literal fails to emit.
            .protocol_box => return try self.emitProtocolBoxTypeRef(),
            .tuple => {
                // Tuple element types (e.g. keyword lists `[{Atom, String}]`):
                // emit the tuple type body inline so the runtime container
                // generic uses it verbatim. `emitBodyLocalTupleType` recurses
                // for nested tuples and falls back to `emitImportedTypeRef`
                // for each component type — so `[{Atom, String}]` resolves
                // to a proper `tuple{u32, []const u8}`-keyed `List`.
                const ref = try self.emitBodyLocalTupleType(zig_type);
                return ref;
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

    /// Emit a reference to the runtime `Term` tagged union type.
    /// Resolves to `@import("zap_runtime").Term` so heterogeneous
    /// containers can declare their element type as `Term`.
    fn emitTermTypeRef(self: *ZirDriver) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const term_ref = zir_builder_emit_field_val(self.handle, rt_import, "Term", 4);
        if (term_ref == error_ref) return error.EmitFailed;
        return term_ref;
    }

    /// Emit a reference to the runtime `ProtocolBox` fat-pointer
    /// carrier (defined in `src/runtime.zig`). Resolves to
    /// `@import("zap_runtime").ProtocolBox`. Phase 1.2.5.b lowers
    /// every `ZigType.protocol_box` shape — struct fields, union
    /// variant payloads, function parameters, return types — through
    /// this helper so the underlying ZIR carries the right concrete
    /// type identity regardless of which protocol's existential is
    /// being typed. The dispatch-time vtable cast belongs to Phase
    /// 1.2.5.d's consumption-site lowering, not the type plumbing.
    fn emitProtocolBoxTypeRef(self: *ZirDriver) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const box_ref = zir_builder_emit_field_val(self.handle, rt_import, "ProtocolBox", 11);
        if (box_ref == error_ref) return error.EmitFailed;
        return box_ref;
    }

    /// Emit a reference to the canonical zero-element tuple type
    /// (`@import("zap_runtime").EmptyTuple`). The empty Zap tuple `{}`
    /// (a zero-argument closure's `Callable` `args`) lowers through this
    /// ONE named nominal type at every position — param, return, nested
    /// element, and construction value — so a `fn() -> R` boxed closure's
    /// `call` slot, dispatch helper, per-impl adapter, impl `args :: {}`
    /// parameter, and call-site argument all reference the same
    /// InternPool type and unify. (A separately written `struct {}` gets a
    /// distinct identity per site and the empty literal `.{}` will not
    /// coerce into it — see `zap_runtime.EmptyTuple`.)
    fn emitEmptyTupleTypeRef(self: *ZirDriver) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const empty_ref = zir_builder_emit_field_val(self.handle, rt_import, "EmptyTuple", 10);
        if (empty_ref == error_ref) return error.EmitFailed;
        return empty_ref;
    }

    /// Emit `runtime.Term.from(value_ref)` — wraps a concrete value as
    /// a `Term`. Used by collection construction sites whose element
    /// type was promoted to `Term` because the static element types
    /// disagreed.
    fn emitTermWrap(self: *ZirDriver, value_ref: u32) BuildError!u32 {
        const term_ref = try self.emitTermTypeRef();
        const from_fn = zir_builder_emit_field_val(self.handle, term_ref, "from", 4);
        if (from_fn == error_ref) return error.EmitFailed;
        const args = [_]u32{value_ref};
        const ref = zir_builder_emit_call_ref(self.handle, from_fn, &args, 1);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a reference to a `zap_runtime.<helper_name>` function.
    /// Used by list/map operations to dispatch through type-derived
    /// `anytype` helpers (`listGet`, `listLength`, ...) when the
    /// declared collection element type may differ from the runtime
    /// element type (e.g. param-backed locals carrying heterogeneous
    /// keyword lists).
    fn emitRuntimeHelper(self: *ZirDriver, helper_name: []const u8) BuildError!u32 {
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const fn_ref = zir_builder_emit_field_val(self.handle, rt_import, helper_name.ptr, @intCast(helper_name.len));
        if (fn_ref == error_ref) return error.EmitFailed;
        return fn_ref;
    }

    /// Emit a zero/default value of a static type, used as the default
    /// argument for `coerceFromMaybeTerm` so the unwrap returns the
    /// declared concrete type. Numeric defaults use typed-int/typed-float
    /// emission so the helper's `@TypeOf(default)` becomes a concrete
    /// runtime type (e.g. `i64`) instead of `comptime_int` — otherwise
    /// Sema demotes the helper call to comptime and rejects it because
    /// the input value is runtime-known.
    fn emitZeroDefaultForType(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32 {
        return switch (zig_type) {
            .i64 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.i64_type)),
            .i128 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.i128_type)),
            .i32 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.i32_type)),
            .i16 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.i16_type)),
            .i8 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.i8_type)),
            .u64 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u64_type)),
            .u128 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u128_type)),
            .u32 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u32_type)),
            .u16 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u16_type)),
            .u8 => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u8_type)),
            .usize => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.usize_type)),
            .isize => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.isize_type)),
            .f64, .f32, .f16, .f80, .f128 => zir_builder_emit_float(self.handle, 0.0),
            .bool_type => @intFromEnum(Zir.Inst.Ref.bool_false),
            .string => zir_builder_emit_str(self.handle, "".ptr, 0),
            .atom => zir_builder_emit_int_typed(self.handle, 0, @intFromEnum(Zir.Inst.Ref.u32_type)),
            else => @intFromEnum(Zir.Inst.Ref.void_value),
        };
    }

    /// Emit `runtime.Term.toCoerced(term_ref, default_ref)` — unwraps a
    /// `Term` back to a concrete value compatible with `default_ref`'s
    /// static Zig type. The runtime helper folds `*const [N:0]u8` ⇒
    /// `[]const u8` so string-literal defaults work without an explicit
    /// slice coercion at the ZIR level.
    fn emitTermUnwrapWithDefault(self: *ZirDriver, term_ref: u32, default_ref: u32) BuildError!u32 {
        const term_type_ref = try self.emitTermTypeRef();
        const to_fn = zir_builder_emit_field_val(self.handle, term_type_ref, "toCoerced", 9);
        if (to_fn == error_ref) return error.EmitFailed;
        const args = [_]u32{ term_ref, default_ref };
        const ref = zir_builder_emit_call_ref(self.handle, to_fn, &args, 2);
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a reference to a `List(T)` type instantiation for any element type.
    /// Uses comptime generic instantiation via `@import("zap_runtime").List(T)`.
    fn emitListCellRef(self: *ZirDriver, element_type: ir.ZigType) BuildError!u32 {
        const elem_ref = (try self.emitContainerElementTypeRef(element_type)) orelse
            zigTypeToTypeRef(element_type) orelse
            return error.EmitFailed;
        const type_args = [_]u32{elem_ref};
        return self.emitGenericContainerRef("List", &type_args);
    }

    /// Emit a reference to a `MapOf(K, V)` type instantiation for any key/value types.
    /// Uses comptime generic instantiation via `@import("zap_runtime").MapOf(K, V)`.
    fn emitMapCellRef(self: *ZirDriver, key_type: ir.ZigType, value_type: ir.ZigType) BuildError!u32 {
        const key_ref = (try self.emitContainerElementTypeRef(key_type)) orelse return error.EmitFailed;
        const val_ref = (try self.emitContainerElementTypeRef(value_type)) orelse return error.EmitFailed;
        const type_args = [_]u32{ key_ref, val_ref };
        return self.emitGenericContainerRef("Map", &type_args);
    }

    /// Set the return type to a generic container type.
    /// Emits instructions for the container instantiation and records them
    /// as the return type body via the fork's custom return type API.
    /// Pop every body instruction emitted since `before_count`, then push
    /// their indices into `support` in EMISSION order. Used to capture the
    /// instructions that materialise complex element/key/value type refs
    /// (e.g. `@import("zap_runtime")` + `field_val Term`) so they can be
    /// embedded into the ret_ty body instead of being orphaned in the
    /// function body where Sema can't resolve them.
    fn captureBodyInsts(self: *ZirDriver, before_count: u32, support: *std.ArrayListUnmanaged(u32)) BuildError!void {
        const after = zir_builder_get_body_inst_count(self.handle);
        if (after <= before_count) return;
        const num_added = after - before_count;
        var captured: std.ArrayListUnmanaged(u32) = .empty;
        defer captured.deinit(self.allocator);
        var pop_remaining = num_added;
        while (pop_remaining > 0) : (pop_remaining -= 1) {
            const idx = zir_builder_pop_body_inst(self.handle);
            try captured.append(self.allocator, idx);
        }
        // captured is reverse-emission order; reverse to restore emission order
        var rev_i: usize = captured.items.len;
        while (rev_i > 0) {
            rev_i -= 1;
            try support.append(self.allocator, captured.items[rev_i]);
        }
    }

    /// Emit a param with declared type `?Inner` via a fork helper that
    /// emits decl_val/@This + optional_type + break_inline directly
    /// inside the param's type body. This sidesteps the body-tracking
    /// dance `emitImportedTypeRef` would otherwise force on us — the
    /// fork's `addParamOptionalDeclValType` mirrors the pattern the
    /// non-optional `addParamDeclValType` already uses for sibling
    /// nominal types.
    fn emitOptionalParam(self: *ZirDriver, param: ir.Param, inner_type: ir.ZigType) !u32 {
        if (inner_type != .struct_ref) {
            // Non-struct optional inner types are out of scope for the
            // dispatch shape this helper exists for. Fall back to
            // anytype rather than emit malformed ZIR.
            const ref = zir_builder_emit_param(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                @intFromEnum(Zir.Inst.Ref.none),
            );
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        }

        const sname = inner_type.struct_ref;
        const current_struct = self.current_emit_struct orelse {
            // No emission context: emit as anytype (caller's burden).
            const ref = zir_builder_emit_param(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                @intFromEnum(Zir.Inst.Ref.none),
            );
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        };

        var buf: [256]u8 = undefined;
        const cls = classifyTypeDef(sname, current_struct, &buf);
        const short_name = if (std.mem.lastIndexOf(u8, sname, ".")) |dot_idx|
            sname[dot_idx + 1 ..]
        else
            sname;

        switch (cls) {
            .primary => {
                const ref = zir_builder_emit_param_optional_this_type(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                );
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .nested => {
                const ref = zir_builder_emit_param_optional_decl_val_type(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    short_name.ptr,
                    @intCast(short_name.len),
                );
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
            .foreign => {
                // Foreign optional struct: `?@import(struct_name).short`
                // (or `?@import(name)` for foreign root structs).
                // Fall through to the streaming `param_type_body` API
                // since the fork doesn't have a one-shot helper for
                // every shape — emit the body insts via the existing
                // `emitImportedTypeRef` helper, which already handles
                // foreign import + field_val and optional wrapping.
                const optional_zig_type: ir.ZigType = blk: {
                    const inner_ptr = try self.allocator.create(ir.ZigType);
                    inner_ptr.* = inner_type;
                    break :blk .{ .optional = inner_ptr };
                };
                var support_inst_indices: std.ArrayListUnmanaged(u32) = .empty;
                defer support_inst_indices.deinit(self.allocator);
                const before = zir_builder_get_body_inst_count(self.handle);
                const opt_ref = try self.emitImportedTypeRef(optional_zig_type);
                try self.captureBodyInsts(before, &support_inst_indices);

                const ref = zir_builder_emit_param_type_body(
                    self.handle,
                    param.name.ptr,
                    @intCast(param.name.len),
                    support_inst_indices.items.ptr,
                    @intCast(support_inst_indices.items.len),
                    opt_ref,
                );
                if (ref == error_ref) return error.EmitFailed;
                return ref;
            },
        }
    }

    fn emitTupleParam(self: *ZirDriver, param: ir.Param, elements: []const ir.ZigType) !u32 {
        // The zero-element tuple `{}` (a zero-argument closure's `args`)
        // is the single canonical `zap_runtime.EmptyTuple` named type, not
        // a fresh anonymous 0-field `tuple_decl` (which would get a
        // distinct nominal identity per emission and never unify with the
        // vtable slot / call-site value). Hoist the import-field's support
        // instructions into the param's type body, exactly like
        // `emitProtocolBoxParam`.
        if (elements.len == 0) {
            var support_inst_indices: std.ArrayListUnmanaged(u32) = .empty;
            defer support_inst_indices.deinit(self.allocator);
            const before = zir_builder_get_body_inst_count(self.handle);
            const empty_ref = try self.emitEmptyTupleTypeRef();
            try self.captureBodyInsts(before, &support_inst_indices);
            const ref = zir_builder_emit_param_type_body(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                support_inst_indices.items.ptr,
                @intCast(support_inst_indices.items.len),
                empty_ref,
            );
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        }

        var support_inst_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer support_inst_indices.deinit(self.allocator);
        var tuple_type_refs: std.ArrayListUnmanaged(u32) = .empty;
        defer tuple_type_refs.deinit(self.allocator);

        self.pending_ret_ty_untracked.clearRetainingCapacity();
        for (elements) |element_type| {
            const before = zir_builder_get_body_inst_count(self.handle);
            const untracked_before = self.pending_ret_ty_untracked.items.len;
            const ref = try self.mapTupleElementType(element_type);
            try self.captureBodyInsts(before, &support_inst_indices);
            if (self.pending_ret_ty_untracked.items.len > untracked_before) {
                for (self.pending_ret_ty_untracked.items[untracked_before..]) |idx| {
                    try support_inst_indices.append(self.allocator, idx);
                }
            }
            try tuple_type_refs.append(self.allocator, ref);
        }

        const tuple_ref = zir_builder_emit_tuple_decl_untracked(
            self.handle,
            tuple_type_refs.items.ptr,
            @intCast(tuple_type_refs.items.len),
        );
        if (tuple_ref == error_ref) return error.EmitFailed;
        const tuple_idx = zir_builder_ref_to_inst_index(self.handle, tuple_ref);
        if (tuple_idx == 0xFFFFFFFF) return error.EmitFailed;
        try support_inst_indices.append(self.allocator, tuple_idx);

        const ref = zir_builder_emit_param_type_body(
            self.handle,
            param.name.ptr,
            @intCast(param.name.len),
            support_inst_indices.items.ptr,
            @intCast(support_inst_indices.items.len),
            tuple_ref,
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    /// Emit a parameter typed `zap_runtime.ProtocolBox` for a
    /// `protocol_constraint(P)` (existential) parameter. The box type is
    /// produced by `emitProtocolBoxTypeRef` (an `@import("zap_runtime")`
    /// + `.ProtocolBox` field access), whose support instructions must be
    /// hoisted into the param's type body so the streaming
    /// `param_type_body` API can replay them when materializing the
    /// parameter type. Modeled on `emitTupleParam`.
    fn emitProtocolBoxParam(self: *ZirDriver, param: ir.Param) BuildError!u32 {
        var support_inst_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer support_inst_indices.deinit(self.allocator);

        const before = zir_builder_get_body_inst_count(self.handle);
        const box_ref = try self.emitProtocolBoxTypeRef();
        try self.captureBodyInsts(before, &support_inst_indices);

        const ref = zir_builder_emit_param_type_body(
            self.handle,
            param.name.ptr,
            @intCast(param.name.len),
            support_inst_indices.items.ptr,
            @intCast(support_inst_indices.items.len),
            box_ref,
        );
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn setContainerReturnTypeWithSupport(
        self: *ZirDriver,
        generic_name: []const u8,
        type_args: []const u32,
        support: []const u32,
    ) BuildError!void {
        var inst_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer inst_indices.deinit(self.allocator);
        // Prepend any support instructions captured by the caller (e.g.
        // body insts produced while building Term/struct type refs) so
        // they live inside the ret_ty body alongside the container-type
        // instructions emitted below.
        for (support) |idx| try inst_indices.append(self.allocator, idx);

        // 1. @import("zap_runtime")
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 2. field_val for generic constructor (List or Map)
        const generic_fn = zir_builder_emit_field_val(self.handle, rt_import, generic_name.ptr, @intCast(generic_name.len));
        if (generic_fn == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 3. call_ref to instantiate: List(T) or Map(K, V)
        const instantiated = zir_builder_emit_call_ref(self.handle, generic_fn, type_args.ptr, @intCast(type_args.len));
        if (instantiated == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 4. field_val for .empty
        const empty_fn = zir_builder_emit_field_val(self.handle, instantiated, "empty", 5);
        if (empty_fn == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 5. call_ref empty() to get a typed null value
        const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
        if (empty_val == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 6. @TypeOf(empty_val) to get the optional pointer type
        const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
        if (type_ref == error_ref) return error.EmitFailed;
        const typeof_inst = zir_builder_pop_body_inst(self.handle);
        try inst_indices.append(self.allocator, typeof_inst);

        if (zir_builder_set_custom_return_type(self.handle, inst_indices.items.ptr, @intCast(inst_indices.items.len), typeof_inst) != 0)
            return error.EmitFailed;
        self.current_ret_type = 1;
    }

    fn setContainerReturnType(self: *ZirDriver, generic_name: []const u8, type_args: []const u32) BuildError!void {
        var inst_indices: std.ArrayListUnmanaged(u32) = .empty;
        defer inst_indices.deinit(self.allocator);

        // 1. @import("zap_runtime")
        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 2. field_val for generic constructor (List or Map)
        const generic_fn = zir_builder_emit_field_val(self.handle, rt_import, generic_name.ptr, @intCast(generic_name.len));
        if (generic_fn == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 3. call_ref to instantiate: List(T) or Map(K, V)
        const instantiated = zir_builder_emit_call_ref(self.handle, generic_fn, type_args.ptr, @intCast(type_args.len));
        if (instantiated == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 4. field_val for .empty
        const empty_fn = zir_builder_emit_field_val(self.handle, instantiated, "empty", 5);
        if (empty_fn == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 5. call_ref empty() to get a typed null value
        const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
        if (empty_val == error_ref) return error.EmitFailed;
        try inst_indices.append(self.allocator, zir_builder_pop_body_inst(self.handle));

        // 6. @TypeOf(empty_val) to get the optional pointer type
        const type_ref = zir_builder_emit_typeof(self.handle, empty_val);
        if (type_ref == error_ref) return error.EmitFailed;
        const typeof_inst = zir_builder_pop_body_inst(self.handle);
        try inst_indices.append(self.allocator, typeof_inst);

        // Set as custom return type
        if (zir_builder_set_custom_return_type(self.handle, inst_indices.items.ptr, @intCast(inst_indices.items.len), typeof_inst) != 0)
            return error.EmitFailed;
        self.current_ret_type = 1;
    }

    /// Resolve an encoded type name (from call_builtin encoding) to a ZIR type ref.
    /// Returns null for non-primitive names that need decl_val resolution.
    /// Map a bridge call (`:zig.Map.<method>` or `:zig.List.<method>`)
    /// to the type-derived runtime helper that accepts `anytype` for
    /// the collection. Returns null if no helper exists — this signals
    /// the call_builtin path to surface a build error rather than fall
    /// back to a hard-coded `Map(atom, i64)` / `List(i64)` monomorph
    /// (which silently miscompiles for any other element type).
    fn mapBridgeMethodToHelper(mod_name: []const u8, func_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, mod_name, "Map")) {
            if (std.mem.eql(u8, func_name, "get")) return "mapGet";
            if (std.mem.eql(u8, func_name, "hasKey")) return "mapHasKey";
            if (std.mem.eql(u8, func_name, "put")) return "mapPut";
            if (std.mem.eql(u8, func_name, "delete")) return "mapDelete";
            if (std.mem.eql(u8, func_name, "merge")) return "mapMerge";
            // Phase H/uniqueness codegen: unchecked variants share the same
            // Zig signature as the checked peers. The runtime exposes
            // `mapPutOwnedUnchecked`/`mapDeleteOwnedUnchecked`/
            // `mapMergeOwnedUnchecked` helpers that route through
            // `Map(K, V).put_owned_unchecked` etc. via `anytype`.
            if (std.mem.eql(u8, func_name, "put_owned_unchecked")) return "mapPutOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "delete_owned_unchecked")) return "mapDeleteOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "merge_owned_unchecked")) return "mapMergeOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "size")) return "mapSize";
            if (std.mem.eql(u8, func_name, "isEmpty")) return "mapIsEmpty";
            if (std.mem.eql(u8, func_name, "release")) return "mapRelease";
            if (std.mem.eql(u8, func_name, "next")) return "mapNext";
            if (std.mem.eql(u8, func_name, "keys")) return "mapKeys";
            if (std.mem.eql(u8, func_name, "values")) return "mapValues";
            if (std.mem.eql(u8, func_name, "enumReduceValues")) return "mapEnumReduceValues";
            return null;
        }
        if (std.mem.eql(u8, mod_name, "List")) {
            if (std.mem.eql(u8, func_name, "getHead")) return "listGetHead";
            if (std.mem.eql(u8, func_name, "getTail")) return "listGetTail";
            if (std.mem.eql(u8, func_name, "isEmpty")) return "listIsEmpty";
            if (std.mem.eql(u8, func_name, "length")) return "listLength";
            if (std.mem.eql(u8, func_name, "sliceFrom")) return "listSliceFrom";
            if (std.mem.eql(u8, func_name, "slice_owned_unchecked")) return "listSliceOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "capacity")) return "listCapacity";
            if (std.mem.eql(u8, func_name, "get")) return "listGet";
            if (std.mem.eql(u8, func_name, "last")) return "listLast";
            if (std.mem.eql(u8, func_name, "reverse")) return "listReverse";
            if (std.mem.eql(u8, func_name, "concat")) return "listConcat";
            if (std.mem.eql(u8, func_name, "set")) return "listSet";
            if (std.mem.eql(u8, func_name, "push")) return "listPush";
            if (std.mem.eql(u8, func_name, "pop")) return "listPop";
            if (std.mem.eql(u8, func_name, "append")) return "listAppend";
            if (std.mem.eql(u8, func_name, "set_owned_unchecked")) return "listSetOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "push_owned_unchecked")) return "listPushOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "pop_owned_unchecked")) return "listPopOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "append_owned_unchecked")) return "listAppendOwnedUnchecked";
            if (std.mem.eql(u8, func_name, "contains")) return "listContains";
            if (std.mem.eql(u8, func_name, "take")) return "listTake";
            if (std.mem.eql(u8, func_name, "release")) return "listRelease";
            if (std.mem.eql(u8, func_name, "next")) return "listNext";
            if (std.mem.eql(u8, func_name, "cons")) return "listCons";
            if (std.mem.eql(u8, func_name, "drop")) return "listDrop";
            if (std.mem.eql(u8, func_name, "uniq")) return "listUniq";
            if (std.mem.eql(u8, func_name, "mapFn")) return "listMapFn";
            if (std.mem.eql(u8, func_name, "filterFn")) return "listFilterFn";
            if (std.mem.eql(u8, func_name, "rejectFn")) return "listRejectFn";
            if (std.mem.eql(u8, func_name, "enumReduceSimple")) return "listEnumReduceSimple";
            if (std.mem.eql(u8, func_name, "eachFn")) return "listEachFn";
            if (std.mem.eql(u8, func_name, "findFn")) return "listFindFn";
            if (std.mem.eql(u8, func_name, "anyFn")) return "listAnyFn";
            if (std.mem.eql(u8, func_name, "allFn")) return "listAllFn";
            if (std.mem.eql(u8, func_name, "countFn")) return "listCountFn";
            if (std.mem.eql(u8, func_name, "sortFn")) return "listSortFn";
            if (std.mem.eql(u8, func_name, "flatMapFn")) return "listFlatMapFn";
            if (std.mem.eql(u8, func_name, "maxVal")) return "listMaxVal";
            if (std.mem.eql(u8, func_name, "minVal")) return "listMinVal";
            if (std.mem.eql(u8, func_name, "sum")) return "listSum";
            return null;
        }
        return null;
    }

    fn encodedNameToTypeRef(name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "i128")) return @intFromEnum(Zir.Inst.Ref.i128_type);
        if (std.mem.eql(u8, name, "i64")) return @intFromEnum(Zir.Inst.Ref.i64_type);
        if (std.mem.eql(u8, name, "i32")) return @intFromEnum(Zir.Inst.Ref.i32_type);
        if (std.mem.eql(u8, name, "i16")) return @intFromEnum(Zir.Inst.Ref.i16_type);
        if (std.mem.eql(u8, name, "i8")) return @intFromEnum(Zir.Inst.Ref.i8_type);
        if (std.mem.eql(u8, name, "u128")) return @intFromEnum(Zir.Inst.Ref.u128_type);
        if (std.mem.eql(u8, name, "u64")) return @intFromEnum(Zir.Inst.Ref.u64_type);
        if (std.mem.eql(u8, name, "u32")) return @intFromEnum(Zir.Inst.Ref.u32_type);
        if (std.mem.eql(u8, name, "u16")) return @intFromEnum(Zir.Inst.Ref.u16_type);
        if (std.mem.eql(u8, name, "u8")) return @intFromEnum(Zir.Inst.Ref.u8_type);
        if (std.mem.eql(u8, name, "f128")) return @intFromEnum(Zir.Inst.Ref.f128_type);
        if (std.mem.eql(u8, name, "f80")) return @intFromEnum(Zir.Inst.Ref.f80_type);
        if (std.mem.eql(u8, name, "f64")) return @intFromEnum(Zir.Inst.Ref.f64_type);
        if (std.mem.eql(u8, name, "f32")) return @intFromEnum(Zir.Inst.Ref.f32_type);
        if (std.mem.eql(u8, name, "f16")) return @intFromEnum(Zir.Inst.Ref.f16_type);
        if (std.mem.eql(u8, name, "bool")) return @intFromEnum(Zir.Inst.Ref.bool_type);
        if (std.mem.eql(u8, name, "str")) return @intFromEnum(Zir.Inst.Ref.slice_const_u8_type);
        return null;
    }

    fn emitEncodedContainerElementTypeRef(self: *ZirDriver, name: []const u8) BuildError!?u32 {
        if (encodedNameToTypeRef(name)) |ref| return ref;
        if (std.mem.eql(u8, name, "Term")) return try self.emitTermTypeRef();
        if (!self.findAnyTypeDef(name)) return null;
        return try self.emitStructTypeRef(name);
    }

    fn emitRequiredEncodedContainerElementTypeRef(self: *ZirDriver, name: []const u8) BuildError!u32 {
        return (try self.emitEncodedContainerElementTypeRef(name)) orelse error.EmitFailed;
    }

    fn encodedContainerElementNameIsKnown(self: *const ZirDriver, name: []const u8) bool {
        return encodedNameToTypeRef(name) != null or
            std.mem.eql(u8, name, "Term") or
            self.findAnyTypeDef(name);
    }

    /// Extract element type from a list ZigType. Callers validate the outer
    /// shape before invoking this helper; a non-list here is a lowering bug.
    fn getListElementType(list_type: ir.ZigType) ir.ZigType {
        if (std.meta.activeTag(list_type) == .list) {
            return list_type.list.*;
        }
        return .any;
    }

    fn emitTypedParam(self: *ZirDriver, param: ir.Param) !u32 {
        // Recursive struct types are uniformly boxed at parameter
        // boundaries: `Tree` becomes `*const Tree`, `?Tree` becomes
        // `?*const Tree`. Routing through the streaming body API lets
        // `emitImportedTypeRef` emit the `optional + single_const_ptr +
        // struct_ref` chain inside the param's type body, so Sema sees
        // every operand without falling out of the body slice. See
        // `boxRecursiveZigType` for why this is correct (preserves the
        // source-Arc pointer through every call so deep release
        // observes a real allocation).
        if (self.zigTypeIsRecursiveStruct(param.type_expr)) {
            const boxed = try self.boxRecursiveZigType(param.type_expr);
            var support: std.ArrayListUnmanaged(u32) = .empty;
            defer support.deinit(self.allocator);
            const before = zir_builder_get_body_inst_count(self.handle);
            const type_ref = try self.emitImportedTypeRef(boxed);
            try self.captureBodyInsts(before, &support);
            const ref = zir_builder_emit_param_type_body(
                self.handle,
                param.name.ptr,
                @intCast(param.name.len),
                support.items.ptr,
                @intCast(support.items.len),
                type_ref,
            );
            if (ref == error_ref) return error.EmitFailed;
            return ref;
        }
        // Struct params: dispatch to the right param-emission API
        // based on where the type lives. The CRITICAL constraint is
        // that any non-primitive operand the param's type body uses
        // must be ITSELF emitted inside the param body — Sema's
        // `analyzeInlineBody` walks only the body slice, so any Ref
        // pointing at an instruction outside that body fails to
        // resolve in `inst_map` and panics in `resolveInst`.
        if (std.meta.activeTag(param.type_expr) == .struct_ref) {
            const name = param.type_expr.struct_ref;
            if (self.findStructDef(name) != null) {
                if (self.current_emit_struct) |current| {
                    var buf: [256]u8 = undefined;
                    const cls = classifyTypeDef(name, current, &buf);
                    const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                        name[dot_idx + 1 ..]
                    else
                        name;
                    switch (cls) {
                        .primary => {
                            // The file IS this struct — emit
                            // `param: @This()`. `@import(self)` is
                            // rejected by Zig's build struct system
                            // ("no struct named X available within
                            // struct X"); `@This()` is the canonical
                            // self-reference, and the resulting type
                            // identity matches `Zcu.fileRootType` so
                            // foreign emissions that import this
                            // file get the same nominal type.
                            const ref = zir_builder_emit_param_this_type(
                                self.handle,
                                param.name.ptr,
                                @intCast(param.name.len),
                            );
                            if (ref == error_ref) return error.EmitFailed;
                            return ref;
                        },
                        .nested => {
                            // Nested inside the primary — reachable
                            // by name in the current emission via
                            // decl_val. The fork's
                            // `addParamDeclValType` emits the
                            // decl_val + break inside the param body.
                            const ref = zir_builder_emit_param_decl_val_type(
                                self.handle,
                                param.name.ptr,
                                @intCast(param.name.len),
                                short_name.ptr,
                                @intCast(short_name.len),
                            );
                            if (ref == error_ref) return error.EmitFailed;
                            return ref;
                        },
                        .foreign => {
                            if (std.mem.lastIndexOf(u8, name, ".")) |_| {
                                // Foreign nested:
                                // `@import(prefix).short_name`.
                                var struct_name_buf: [256]u8 = undefined;
                                const struct_name = structToImportName(name, &struct_name_buf);
                                const ref = zir_builder_emit_param_imported_type(
                                    self.handle,
                                    param.name.ptr,
                                    @intCast(param.name.len),
                                    struct_name.ptr,
                                    @intCast(struct_name.len),
                                    short_name.ptr,
                                    @intCast(short_name.len),
                                );
                                if (ref == error_ref) return error.EmitFailed;
                                return ref;
                            } else {
                                // Foreign top-level — file IS the
                                // struct: `@import(name)`.
                                const ref = zir_builder_emit_param_imported_root_type(
                                    self.handle,
                                    param.name.ptr,
                                    @intCast(param.name.len),
                                    name.ptr,
                                    @intCast(name.len),
                                );
                                if (ref == error_ref) return error.EmitFailed;
                                return ref;
                            }
                        },
                    }
                }
            }
        }
        if (std.meta.activeTag(param.type_expr) == .tuple) {
            return try self.emitTupleParam(param, param.type_expr.tuple);
        }
        // Optional params (`?T`) need an explicit type body so the
        // dispatcher (and any downstream null-check) sees the param as
        // `?T`, not `anytype`. Emit
        //   param body { inner_ref = T-type-ref ; opt_ref = optional_type(inner_ref) ; break opt_ref }
        // and pass the body to `zir_builder_emit_param_type_body`.
        if (std.meta.activeTag(param.type_expr) == .optional) {
            return try self.emitOptionalParam(param, param.type_expr.optional.*);
        }
        // Map and list params use anytype. Generic container types like
        // List(T) and Map(K, V) can't be expressed as named imports.
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
        // A `protocol_constraint(P)` parameter (e.g. `e :: Error`) lowers
        // to a concrete `zap_runtime.ProtocolBox` value, NOT `anytype`.
        // Emitting it as `anytype` (the `mapParamType` fallback below)
        // leaves the parameter unconstrained: a cross-struct caller's
        // foreign emission of `@import("M").f(box)` then cannot resolve a
        // monomorphic signature, and the `protocol_dispatch` body's
        // vtable recovery (`@ptrCast(@alignCast(box.vtable.?))`) sees the
        // erased type `type` rather than a ProtocolBox value
        // (`expected pointer, found 'type'`). The box carrier is a fixed
        // 16-byte runtime type, so we emit an explicit param type body
        // referencing `zap_runtime.ProtocolBox`.
        if (std.meta.activeTag(param.type_expr) == .protocol_box) {
            return try self.emitProtocolBoxParam(param);
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
        // Recursive struct return types are uniformly boxed: a function
        // declared `-> Tree` returns `*const Tree`, `-> ?Tree` returns
        // `?*const Tree`. The pointer carries the source-Arc identity
        // through the return so callers can deep-release the
        // substructure without aliasing concerns. See
        // `boxRecursiveZigType` for the full rationale.
        //
        // `set_custom_return_type` takes the *instruction index* of the
        // body's final result, not the ZIR Ref the emit helpers return,
        // so convert via `ref_to_inst_index` after capturing the body.
        if (self.zigTypeIsRecursiveStruct(return_type)) {
            const boxed = try self.boxRecursiveZigType(return_type);
            var support: std.ArrayListUnmanaged(u32) = .empty;
            defer support.deinit(self.allocator);
            const before = zir_builder_get_body_inst_count(self.handle);
            const type_ref = try self.emitImportedTypeRef(boxed);
            try self.captureBodyInsts(before, &support);
            const result_inst = zir_builder_ref_to_inst_index(self.handle, type_ref);
            if (result_inst == 0xFFFFFFFF) return error.EmitFailed;
            if (zir_builder_set_custom_return_type(
                self.handle,
                support.items.ptr,
                @intCast(support.items.len),
                result_inst,
            ) != 0) return error.EmitFailed;
            self.current_ret_type = 1;
            return;
        }
        switch (return_type) {
            .function => |fn_type| {
                // A function declared to RETURN a closure type `fn() -> Ret`
                // returns `*const fn(P...) Ret` — the runtime representation
                // of the non-capturing closure value it produces. The
                // func-ptr type's support instructions (the param/func/
                // break_inline nested inside its block_inline) must live
                // INSIDE the ret_ty body, so capture them and route through
                // `set_custom_return_type` (the same mechanism the
                // recursive-struct return path above uses).
                var support: std.ArrayListUnmanaged(u32) = .empty;
                defer support.deinit(self.allocator);
                const before = zir_builder_get_body_inst_count(self.handle);
                const type_ref = try self.emitFuncPtrTypeRef(fn_type);
                try self.captureBodyInsts(before, &support);
                const result_inst = zir_builder_ref_to_inst_index(self.handle, type_ref);
                if (result_inst == 0xFFFFFFFF) return error.EmitFailed;
                if (zir_builder_set_custom_return_type(
                    self.handle,
                    support.items.ptr,
                    @intCast(support.items.len),
                    result_inst,
                ) != 0) return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .list => {
                // emitContainerElementTypeRef may emit support instructions
                // (e.g. `@import("zap_runtime")`, `field_val Term`) into the
                // function body. These references must live INSIDE the
                // ret_ty body alongside `setContainerReturnType`'s own
                // instructions — otherwise Sema's `inst_map.get(i).?` fails
                // when resolving the typeof break in the ret_ty body.
                var support: std.ArrayListUnmanaged(u32) = .empty;
                defer support.deinit(self.allocator);
                const before = zir_builder_get_body_inst_count(self.handle);
                const elem_ref = (try self.emitContainerElementTypeRef(getListElementType(return_type))) orelse
                    return error.EmitFailed;
                try self.captureBodyInsts(before, &support);
                const type_args = [_]u32{elem_ref};
                try self.setContainerReturnTypeWithSupport("List", &type_args, support.items);
            },
            .map => |mt| {
                var support: std.ArrayListUnmanaged(u32) = .empty;
                defer support.deinit(self.allocator);
                const before_key = zir_builder_get_body_inst_count(self.handle);
                const key_ref = (try self.emitContainerElementTypeRef(mt.key.*)) orelse
                    return error.EmitFailed;
                try self.captureBodyInsts(before_key, &support);
                const before_val = zir_builder_get_body_inst_count(self.handle);
                const val_ref = (try self.emitContainerElementTypeRef(mt.value.*)) orelse
                    return error.EmitFailed;
                try self.captureBodyInsts(before_val, &support);
                const type_args = [_]u32{ key_ref, val_ref };
                try self.setContainerReturnTypeWithSupport("Map", &type_args, support.items);
            },
            .tuple => |elements| {
                // Capture every body instruction emitted while constructing
                // each tuple element's type ref. Complex elements (struct_ref,
                // map, list, nested tuple) emit `import` / `field_val` /
                // `call_ref` / `typeof` instructions that, if left in the
                // declaration body, are invisible to Sema when it resolves
                // the tuple_decl's operands inside the ret_ty body — that's
                // the root cause of the `inst_map.get(i).?` panic for
                // tuple-returning functions like `Map.next`.
                var tuple_type_refs: std.ArrayListUnmanaged(u32) = .empty;
                defer tuple_type_refs.deinit(self.allocator);
                var support_inst_indices: std.ArrayListUnmanaged(u32) = .empty;
                defer support_inst_indices.deinit(self.allocator);
                // Reset the untracked-tuple-decls collector for this scope.
                self.pending_ret_ty_untracked.clearRetainingCapacity();

                for (elements) |elem_type| {
                    const before = zir_builder_get_body_inst_count(self.handle);
                    // Snapshot the untracked list before so nested tuple
                    // decls collected by mapTupleElementType land in
                    // `support_inst_indices` in emission order.
                    const untracked_before = self.pending_ret_ty_untracked.items.len;
                    const ref = try self.emitImportedTypeRef(elem_type);
                    if (self.pending_ret_ty_untracked.items.len > untracked_before) {
                        for (self.pending_ret_ty_untracked.items[untracked_before..]) |idx| {
                            try support_inst_indices.append(self.allocator, idx);
                        }
                    }
                    const after = zir_builder_get_body_inst_count(self.handle);
                    if (after > before) {
                        const num_added = after - before;
                        var captured: std.ArrayListUnmanaged(u32) = .empty;
                        defer captured.deinit(self.allocator);
                        var pop_remaining = num_added;
                        while (pop_remaining > 0) : (pop_remaining -= 1) {
                            const idx = zir_builder_pop_body_inst(self.handle);
                            try captured.append(self.allocator, idx);
                        }
                        var rev_i: usize = captured.items.len;
                        while (rev_i > 0) {
                            rev_i -= 1;
                            try support_inst_indices.append(self.allocator, captured.items[rev_i]);
                        }
                    }
                    try tuple_type_refs.append(self.allocator, ref);
                }

                if (zir_builder_set_tuple_return_type_with_body(
                    self.handle,
                    support_inst_indices.items.ptr,
                    @intCast(support_inst_indices.items.len),
                    tuple_type_refs.items.ptr,
                    @intCast(tuple_type_refs.items.len),
                ) != 0) {
                    return error.EmitFailed;
                }
                self.current_ret_type = 1;
            },
            .struct_ref => |name| {
                if (self.findUnionDef(name)) |union_def| {
                    // Per-instantiation parametric union specializations
                    // (`Option_i64`, `Result_i64_String`) live as
                    // `pub const <Name> = union(enum) {...};` inside a
                    // synthetic top-level Zig file emitted by Step 3.6.
                    // Callers reach them via `@import(name).<name>`. A
                    // function `pub fn maybe() -> Option(i64)` MUST
                    // declare its return type as exactly that imported
                    // nominal type — re-declaring the union inline via
                    // `set_union_return_type` creates a structurally
                    // identical but nominally distinct anonymous union
                    // per call site, which Sema flags ("expected
                    // 'Option_i64.Option_i64', found ...") as a type
                    // mismatch the first time anyone tries to USE the
                    // function's return value as the synthetic-file
                    // union.
                    //
                    // The rule for distinguishing the two shapes is the
                    // exact same `is_specialization_decl` predicate
                    // `emitStructTypeRef` uses: no dot in the name AND
                    // the name resolves to a `union_def`/`enum_def`.
                    // Concrete dotted unions (`IO.Mode`, `Color`) stay
                    // on the legacy `set_union_return_type` path —
                    // their declaration lives in the owning struct's
                    // emission, not as a separate top-level synthetic
                    // file, so an inline `union(enum)` decl is the
                    // only way to surface the type at the function's
                    // return position.
                    const is_specialization_decl = std.mem.indexOf(u8, name, ".") == null;
                    if (is_specialization_decl) {
                        var support: std.ArrayListUnmanaged(u32) = .empty;
                        defer support.deinit(self.allocator);
                        const before = zir_builder_get_body_inst_count(self.handle);
                        const type_ref = try self.emitStructTypeRef(name);
                        try self.captureBodyInsts(before, &support);
                        const result_inst = zir_builder_ref_to_inst_index(self.handle, type_ref);
                        if (result_inst == 0xFFFFFFFF) return error.EmitFailed;
                        if (zir_builder_set_custom_return_type(
                            self.handle,
                            support.items.ptr,
                            @intCast(support.items.len),
                            result_inst,
                        ) != 0) return error.EmitFailed;
                        self.current_ret_type = 1;
                        // `cached_union_ret_type_ref` is the
                        // construction-side cache used by `union_init`
                        // to materialise return-position literals
                        // against the inline anonymous union. Since
                        // we're returning the imported nominal type
                        // now, leave it at its sentinel zero — the
                        // construction path always calls
                        // `emitStructTypeRef(name)` from
                        // `union_init`'s ZIR handler regardless, which
                        // is the right ref for `@unionInit`.
                        return;
                    }

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
                } else if (self.findStructDef(name) != null) {
                    // Struct return type. Dispatch by classification
                    // against the current emission so the matching
                    // ZIR primitive lands inside the ret_ty body:
                    //
                    //   .primary  →  @This()       (self-typed return)
                    //   .nested   →  decl_val(X)   (inner struct of the primary)
                    //   .foreign  →  @import(...)  (peer / cross-emission)
                    //
                    // A single switch keeps the param-side
                    // (`emitTypedParam`) and return-side resolution
                    // logic in lockstep — historically a separate
                    // `structIsInCurrentEmitStruct` pre-check
                    // shadowed `.primary` by emitting `decl_val(X)`,
                    // producing "use of undeclared identifier 'X'"
                    // for any `pub fn ... -> Self` declared in the
                    // primary struct's own body. Generic across
                    // every struct (native or user-defined).
                    if (self.current_emit_struct) |current| {
                        var buf: [256]u8 = undefined;
                        const cls = classifyTypeDef(name, current, &buf);
                        const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                            name[dot_idx + 1 ..]
                        else
                            name;
                        switch (cls) {
                            .primary => {
                                if (zir_builder_set_this_return_type(self.handle) != 0)
                                    return error.EmitFailed;
                            },
                            .nested => {
                                if (zir_builder_set_decl_val_return_type(self.handle, short_name.ptr, @intCast(short_name.len)) != 0)
                                    return error.EmitFailed;
                            },
                            .foreign => {
                                if (std.mem.lastIndexOf(u8, name, ".")) |_| {
                                    var struct_name_buf: [256]u8 = undefined;
                                    const struct_name = structToImportName(name, &struct_name_buf);
                                    if (zir_builder_set_imported_return_type(self.handle, struct_name.ptr, @intCast(struct_name.len), short_name.ptr, @intCast(short_name.len)) != 0)
                                        return error.EmitFailed;
                                } else {
                                    if (zir_builder_set_imported_root_return_type(self.handle, name.ptr, @intCast(name.len)) != 0)
                                        return error.EmitFailed;
                                }
                            },
                        }
                        self.current_ret_type = 1;
                    } else {
                        // No current emission — top-level / root-program
                        // function. Fall back to the legacy path.
                        var struct_name_buf: [256]u8 = undefined;
                        const struct_name = structToImportName(name, &struct_name_buf);
                        const short_name = if (std.mem.lastIndexOf(u8, name, ".")) |dot_idx|
                            name[dot_idx + 1 ..]
                        else
                            name;
                        if (zir_builder_set_imported_return_type(self.handle, struct_name.ptr, @intCast(struct_name.len), short_name.ptr, @intCast(short_name.len)) != 0)
                            return error.EmitFailed;
                        self.current_ret_type = 1;
                    }
                } else {
                    // Unknown struct_ref: use generic inference
                    if (zir_builder_set_generic_return_type(self.handle) != 0)
                        return error.EmitFailed;
                    self.current_ret_type = 1;
                }
            },
            .optional => {
                // Source optional returns (`T | nil`) must name the child
                // type before wrapping it as `?T`. `set_optional_return_type`
                // wraps the current function return type, so using it here
                // before a child type exists collapses primitive optionals to
                // `?void`. Build the optional type in the ret_ty body instead.
                var support: std.ArrayListUnmanaged(u32) = .empty;
                defer support.deinit(self.allocator);
                const before = zir_builder_get_body_inst_count(self.handle);
                const type_ref = try self.emitImportedTypeRef(return_type);
                try self.captureBodyInsts(before, &support);
                const result_inst = zir_builder_ref_to_inst_index(self.handle, type_ref);
                if (result_inst == 0xFFFFFFFF) return error.EmitFailed;
                if (zir_builder_set_custom_return_type(
                    self.handle,
                    support.items.ptr,
                    @intCast(support.items.len),
                    result_inst,
                ) != 0) return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .protocol_box => {
                // A function declared `-> <Protocol>` (a protocol
                // existential) returns the runtime fat-pointer carrier
                // `zap_runtime.ProtocolBox`. Emit the return type
                // EXPLICITLY rather than relying on body inference
                // (`set_generic_return_type`).
                //
                // Body inference is only sound when the body literally
                // constructs the box in a Sema-visible way (the Phase
                // 1.2.5.c construction-site `box_as_protocol` lowering).
                // A function whose body is a direct `:zig.*` bridge call
                // returning `ProtocolBox` — e.g. `Kernel.take_recoverable_raise`
                // (Phase 3.a), whose body is `:zig.Kernel.take_recoverable_raise()`
                // — provides no such anonymous construction, so an
                // inferred/generic return type resolves to `void` and
                // clashes with the `ProtocolBox` the body actually yields
                // (`expected 'void', found 'zap_runtime.ProtocolBox'`).
                // Declaring `-> zap_runtime.ProtocolBox` up front, exactly
                // as the `.struct_ref` imported-type arm does, makes the
                // declared and produced types agree for every
                // protocol-existential-returning function regardless of how
                // the box is produced.
                if (zir_builder_set_imported_return_type(
                    self.handle,
                    "zap_runtime",
                    11,
                    "ProtocolBox",
                    11,
                ) != 0) return error.EmitFailed;
                self.current_ret_type = 1;
            },
            .tagged_union, .ptr, .any, .term => {
                // These types are structural and created anonymously in the
                // body. Zig infers the return type from the body construction.
                // `.term` falls into this bucket because the runtime type
                // (`zap_runtime.Term`) is resolved by the body — declaring
                // it explicitly here would require eagerly emitting the
                // import path, which is unnecessary for inference.
                //
                // `.function` is NOT in this bucket: a closure return type
                // is declared EXPLICITLY as `*const fn(P...) Ret` by the
                // `.function` arm at the top of this switch. Relying on
                // generic inference for a closure return silently resolved
                // to `void` (the body's `*const fn() i64` value then tripped
                // `expected type 'void', found '*const fn () i64'`), which
                // was Gap E symptom 1.
                if (zir_builder_set_generic_return_type(self.handle) != 0)
                    return error.EmitFailed;
                self.current_ret_type = 1;
            },
            // Primitives are handled by mapReturnType — they never reach here.
            // void/nil have ret_type=0 intentionally — they never reach here.
            .void,
            .nil,
            .never,
            .bool_type,
            .i8,
            .i16,
            .i32,
            .i64,
            .i128,
            .u8,
            .u16,
            .u32,
            .u64,
            .u128,
            .usize,
            .isize,
            .f16,
            .f32,
            .f64,
            .f80,
            .f128,
            .string,
            .atom,
            => unreachable, // handled by mapReturnType
        }
    }

    fn emitFunction(self: *ZirDriver, func: ir.Function) !void {
        // Detect the entry point using the program's entry function ID.
        // When multiple structs define main, only the one matching the
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
        self.param_derived_closure_locals.clearRetainingCapacity();
        self.capture_param_refs.clearRetainingCapacity();
        self.destructive_scrutinee_locals.clearRetainingCapacity();
        // ARC-bookkeeping sets are keyed by per-function LocalId; clear
        // them here so a previous function's local id can never alias
        // into this function's release-emission filter.
        self.arc_share_skipped.clearRetainingCapacity();
        self.arc_returned_locals.clearRetainingCapacity();
        self.arc_managed_locals.clearRetainingCapacity();
        self.aggregate_component_original_refs.clearRetainingCapacity();
        // Phase 4 of the k-nucleotide RSS gap implementation plan:
        // when the IR-lowering phase produced an ARC ownership table
        // for this function, replay its `return_source_locals` into
        // `arc_returned_locals` here so the existing
        // `isReleaseSuppressed` filter elides the scope-exit release
        // for any local whose ownership flowed into the function's
        // return slot. The set is part of the per-function arc
        // bookkeeping cleared immediately above, so there is no
        // chance of cross-function bleed.
        //
        // The same fan-out also seeds `arc_managed_locals` from the
        // ownership table's `arc_managed_locals` field so
        // `shouldSkipArc` can enforce the soundness invariant that
        // ARC-managed locals are never stack-eligible — see the
        // field doc on `arc_managed_locals` for the full reasoning.
        if (self.arc_ownership) |ownership| {
            if (ownership.get(func.id)) |fn_ownership| {
                var ret_it = fn_ownership.return_source_locals.keyIterator();
                while (ret_it.next()) |local_id_ptr| {
                    try self.markReturned(local_id_ptr.*);
                }
                var arc_it = fn_ownership.arc_managed_locals.keyIterator();
                while (arc_it.next()) |local_id_ptr| {
                    try self.arc_managed_locals.put(self.allocator, local_id_ptr.*, {});
                }
            }
        }
        self.cached_list_cell_ref = 0;
        self.cached_list_gethead_ref = 0;
        self.cached_list_gettail_ref = 0;
        self.cached_list_slicefrom_ref = 0;
        self.cached_list_cons_ref = 0;
        self.cached_list_length_ref = 0;
        self.cached_list_get_ref = 0;
        self.current_closure_env_ref = null;
        self.skip_next_ret_local = null;
        self.current_function_id = func.id;
        self.current_function_param_conventions = func.param_conventions;
        self.current_function_local_ownership = func.local_ownership;
        self.current_function_return_type = func.return_type;
        self.current_function_is_closure = func.captures.len > 0;
        const closure_lowering = self.getClosureLowering(func.id, func.captures.len);
        var ret_type = if (is_main)
            try mapMainReturnType(func.return_type)
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

        // P2-J2: with the concurrency gate ON, the user's entry function
        // is emitted under the internal root-process name and a synthetic
        // `main` wrapper (emitted after all functions — see
        // `emitRootProcessMainWrapper`) routes it through the runtime's
        // root-process bootstrap. Everything else about entry emission
        // (return-type mapping, argv materialization, raises exclusion)
        // stays exactly the `is_main` shape.
        const emit_as_root_process_entry = is_main and self.runtime_concurrency and !self.lib_mode;
        const emit_name = if (emit_as_root_process_entry)
            @as([]const u8, root_process_main_decl_name)
        else if (is_main)
            @as([]const u8, "main")
        else if (self.current_emit_struct != null and func.local_name.len > 0)
            func.local_name
        else
            func.name;
        if (zir_builder_begin_func(self.handle, emit_name.ptr, @intCast(emit_name.len), ret_type) != 0) {
            return error.BeginFuncFailed;
        }
        // Phase 0 — DWARF foundation: record the mangled-symbol ↔
        // Zap-symbol mapping for the side table that ships alongside
        // the binary. Skip when the function has no Zap source
        // identity (synthetic helpers may have a blank `func.name`).
        if (func.local_name.len > 0 or func.name.len > 0) {
            const mangled = if (self.current_emit_struct) |s|
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ s, emit_name })
            else
                try self.allocator.dupe(u8, emit_name);
            defer self.allocator.free(mangled);
            try self.recordSymbolMapping(mangled, func);
        }

        if (is_main) {
            if (emit_as_root_process_entry) {
                // P2-J2: the startup prologue moves into the synthetic
                // `main` wrapper (it must run on the driver thread's OS
                // stack BEFORE the concurrency runtime spawns the root
                // process); record the mapped return type so the
                // post-function pass emits the matching wrapper.
                self.pending_root_main_return_type = ret_type;
            } else {
                // Executable binary builds pair this emitted entry call
                // with a runtime-source rewrite that sets
                // `MEMORY_STARTUP_PROLOGUE_EMITTED == true`, allowing
                // dispatchers to compile away lazy startup. Object outputs
                // may still contain this generated function, but they have
                // no guaranteed executable artifact entry boundary, so
                // their runtime source keeps the marker false.
                try self.emitMemoryStartupForEntry();
            }

            // Phase 2.b: record that this compilation produced a real
            // program entry, so `buildProgram` injects the root `panic`
            // namespace (the program-wide panic handler) for it.
            self.emitted_main_entry = true;
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

        // Phase 3.b: a function carrying the `raises` effect returns a Zig
        // error union `error{ZapRaise}!T` (inferred error set, `anyerror!T`
        // at the ZIR level). The `error.ZapRaise` tag is the cross-function
        // control signal; the boxed `Error` existential payload rides the
        // thread-local side-channel. `main` is excluded — Zig's entry point
        // must return `void`/`u8`, and a top-level `raise` is the unhandled
        // case that aborts via `crashReport` rather than propagating.
        //
        // This wrap runs AFTER the payload return type is fully established
        // (scalar via `mapReturnType`/`begin_func`, or complex via the
        // `emitComplexReturnType` immediately above), because the fork's
        // `setErrorUnionReturnType` now composes `error{ZapRaise}!<payload>`
        // from the resolved payload return-type instruction. Wrapping BEFORE
        // a complex payload was set previously yielded
        // `error{ZapRaise}!<default>` and silently dropped a `[T]`/`Map`/
        // struct payload — the bug that blocked effect-polymorphism through
        // for-comprehensions (`__for_N -> [mapped]`) and combinators whose
        // result type is a container.
        const emits_error_union = func.raises and !is_main and !is_try_variant;
        if (emits_error_union) {
            const err_name = "ZapRaise";
            if (zir_builder_set_error_union_return_type(self.handle, err_name.ptr, @intCast(err_name.len)) != 0)
                return error.EmitFailed;
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
        if (closure_lowering.needs_env_param) {
            const env_param_ref = try self.emitClosureEnvParam(func.captures);
            self.current_closure_env_ref = env_param_ref;
            for (func.params, 0..) |param, i| {
                _ = i;
                const param_ref = try self.emitTypedParam(param);
                try self.param_refs.append(self.allocator, param_ref);
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

            // Store as the first param ref. The `param_get` lowering
            // materializes it into real IR locals as needed.
            try self.param_refs.append(self.allocator, args_ref);
        } else {
            // Lambda-lifted closures: captures are passed as prepended
            // ordinary parameters at every call site (see HIR direct-call
            // lowering and analysis_pipeline `hasMakeClosureForFunction`).
            // Emit one ZIR param per capture before the declared params so
            // the function's signature matches the call_direct argument
            // shape, then resolve `capture_get` against `capture_param_refs`.
            for (func.captures) |cap| {
                const cap_param: ir.Param = .{
                    .name = cap.name,
                    .type_expr = cap.type_expr,
                    .type_id = null,
                };
                const cap_ref = try self.emitTypedParam(cap_param);
                try self.capture_param_refs.append(self.allocator, cap_ref);
            }
            for (func.params, 0..) |param, i| {
                _ = i;
                const param_ref = try self.emitTypedParam(param);
                try self.param_refs.append(self.allocator, param_ref);
            }
        }

        // Pre-resolve List method refs at function scope so they're available
        // inside condbr bodies (guard blocks). Import resolution inside condbr
        // branch scopes can fail, so we resolve the @import chain here.
        if (self.functionUsesListOps(func)) {
            const list_cell = try self.ensureListRef();
            _ = try self.ensureListMethodRef(list_cell, "getHead", &self.cached_list_gethead_ref);
            _ = try self.ensureListMethodRef(list_cell, "getTail", &self.cached_list_gettail_ref);
            _ = try self.ensureListMethodRef(list_cell, "sliceFrom", &self.cached_list_slicefrom_ref);
            _ = try self.ensureListMethodRef(list_cell, "cons", &self.cached_list_cons_ref);
            _ = try self.ensureListMethodRef(list_cell, "length", &self.cached_list_length_ref);
            _ = try self.ensureListMethodRef(list_cell, "get", &self.cached_list_get_ref);
        }

        try self.emitDebugStatement(func);

        // Loopification prologue: when the function has by-ref params
        // and self-tail-calls, wrap the body in a `loop` block and
        // route every `param_get(i)` through a per-param mutable
        // stack slot. Tail calls store the new args back into the
        // slots and `repeat` the loop instead of musttail-ing — see
        // `Function.loopify` and the `tail_call` lowering for the
        // dispatch.
        var loopify_capture_open = false;
        if (func.loopify) {
            try self.beginLoopification(func);
            self.beginCapture();
            loopify_capture_open = true;
        }
        errdefer if (loopify_capture_open) self.discardCapture();

        // Emit body blocks.
        for (func.body) |block| {
            self.current_block_instructions = block.instructions;

            for (block.instructions, 0..) |instr, instr_idx| {
                self.current_instr_index = @intCast(instr_idx);
                self.emitInstruction(instr) catch |err| {
                    std.log.err(
                        "ZIR emit failed in function {s} at instruction {d} ({s}): {s}",
                        .{ func.name, instr_idx, @tagName(instr), @errorName(err) },
                    );
                    return err;
                };
            }
        }

        if (func.loopify) {
            // The loop body must end on a noreturn instruction or
            // Sema's `analyzeBodyInner` walks past the end. The
            // dispatcher's value-producing `block` (from
            // `if_else_bodies`) ISN'T noreturn — its branches break
            // out with `void` — so we append an explicit `repeat`
            // here. Iterations that ret-from-the-function (matched
            // base cases) never reach it; iterations that committed
            // new args into the slots fall through the dispatcher's
            // block and hit this `repeat`, jumping back to the loop
            // header.
            try self.emitRepeat();
            var body_len: u32 = 0;
            const body_ptr = self.endCapture(&body_len);
            loopify_capture_open = false;
            const body_insts = try self.allocator.alloc(u32, body_len);
            defer self.allocator.free(body_insts);
            @memcpy(body_insts, body_ptr[0..body_len]);
            _ = try self.emitLoop(body_insts);
            self.endLoopification();
        }

        if (zir_builder_end_func(self.handle) != 0) {
            return error.EndFuncFailed;
        }
    }

    /// Allocate one mutable stack slot per parameter and seed each
    /// slot with the corresponding entry-param value. Stores the slot
    /// pointer Refs in `loopify_slots` so the body's `param_get` and
    /// `tail_call` lowerings can read/write them. Slot type comes from
    /// `@TypeOf(param_ref)` rather than `func.params[i].type_expr` so
    /// captures-prepended layouts (where `param_refs` is wider than
    /// `func.params`) still get a slot per ZIR param.
    fn beginLoopification(self: *ZirDriver, func: ir.Function) !void {
        _ = func;
        const num_params = self.param_refs.items.len;
        if (num_params == 0) return;

        var slots = try self.allocator.alloc(u32, num_params);
        errdefer self.allocator.free(slots);

        for (self.param_refs.items, 0..) |param_ref, i| {
            const type_ref = zir_builder_emit_typeof(self.handle, param_ref);
            if (type_ref == error_ref) return error.EmitFailed;
            const slot_ref = try self.emitAllocMut(type_ref);
            if (zir_builder_emit_store(self.handle, slot_ref, param_ref) != 0)
                return error.EmitFailed;
            slots[i] = slot_ref;
        }
        self.loopify_slots = slots;
    }

    fn endLoopification(self: *ZirDriver) void {
        if (self.loopify_slots) |slots| self.allocator.free(slots);
        self.loopify_slots = null;
    }

    /// Resolve the per-iteration value of param `index` when emitting
    /// the body of a loopified function. Returns a fresh `load` from
    /// the param's mutable stack slot — never the entry-scope param
    /// ref. Used by IR forms that consult the param-INDEX slot
    /// directly (e.g. `switch_return.scrutinee_param`,
    /// `optional_dispatch.scrutinee_param`); without this, those
    /// reads would observe the entry value and the loop would never
    /// converge.
    fn loopifyLoadParam(self: *ZirDriver, index: u32) BuildError!u32 {
        const slots = self.loopify_slots orelse return error.EmitFailed;
        if (index >= slots.len) return error.EmitFailed;
        return try self.emitLoad(slots[index]);
    }

    // -- Instruction dispatch -------------------------------------------------

    /// Look up the lambda-set specialization for a `call_closure` whose callee
    /// closure is held in `callee_local`. The call site is identified by its
    /// STABLE `(function, callee_local)` identity — NOT by a positional
    /// `(block, instr_index)` coordinate (audit escape--03 / zirb-1--01). The
    /// old positional key was never updated during nested-stream emission
    /// (`current_instr_index` is only assigned in the top-level block loop), so
    /// nested closure calls consulted the table with the OUTER instruction's
    /// index and bound to the WRONG target. Reading the callee local directly
    /// off the instruction makes this consumer key on the same field the
    /// producer (`lambda_sets.populateContext`) keyed on, so they cannot
    /// disagree across nested streams or instruction-position shifts.
    fn getCallSiteSpecialization(self: *const ZirDriver, callee_local: ir.LocalId) ?@import("escape_lattice.zig").CallSiteSpecialization {
        if (self.analysis_context) |actx| {
            return actx.getCallSiteSpecialization(.{
                .function = self.current_function_id,
                .callee = callee_local,
            });
        }
        return null;
    }

    fn isParamDerivedClosure(self: *const ZirDriver, local: ir.LocalId) bool {
        return self.param_derived_closure_locals.contains(local);
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
                .needs_closure_object = true,
                .stack_env = false,
                .storage_scope = .none,
            },
            .immediate_invocation => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .needs_closure_object = has_captures,
                .stack_env = false,
                .storage_scope = if (has_captures) .stack_function else .immediate,
            },
            .block_local => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .needs_closure_object = true,
                .stack_env = true,
                .storage_scope = .stack_block,
            },
            .function_local => .{
                .tier = tier,
                .needs_env_param = has_captures,
                .needs_closure_object = true,
                .stack_env = true,
                .storage_scope = .stack_function,
            },
            .escaping => .{
                .tier = tier,
                .needs_env_param = has_captures,
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
    fn isBareFunctionRef(self: *const ZirDriver, local: ir.LocalId) BuildError!bool {
        if (try self.findClosureCallTarget(local)) |target| {
            return target.captures.len == 0;
        }
        return false;
    }

    fn findClosureCallTarget(self: *const ZirDriver, local: ir.LocalId) BuildError!?ClosureCallTarget {
        if (self.program) |prog| {
            for (prog.functions) |func| {
                if (func.id != self.current_function_id) continue;
                // Search across ALL blocks in the function body so that
                // local chains spanning block boundaries can be resolved.
                for (func.body) |block| {
                    if (try findClosureTargetInInstrs(self.allocator, block.instructions, local)) |target| return target;
                }
                // Second pass: if a local_set in one block references a value
                // defined in another block, resolve the chain across blocks.
                for (func.body) |block| {
                    if (try findClosureTargetCrossBlock(self.allocator, func.body, block.instructions, local)) |target| return target;
                }
            }
        }
        return null;
    }

    /// Search for a closure target across block boundaries. When a local_set/local_get
    /// in one block references a value from another block, search all blocks for the source.
    fn findClosureTargetCrossBlock(allocator: Allocator, all_blocks: []const ir.Block, instrs: []const ir.Instruction, local: ir.LocalId) BuildError!?ClosureCallTarget {
        for (instrs) |instr| {
            const source_local: ?ir.LocalId = switch (instr) {
                .local_set => |ls| if (ls.dest == local) ls.value else null,
                .local_get => |lg| if (lg.dest == local) lg.source else null,
                .borrow_value => |bv| if (bv.dest == local) bv.source else null,
                .copy_value => |cv| if (cv.dest == local) cv.source else null,
                .move_value => |mv| if (mv.dest == local) mv.source else null,
                .share_value => |sv| if (sv.dest == local) sv.source else null,
                else => null,
            };
            if (source_local) |src| {
                // Search all blocks for the source local
                for (all_blocks) |block| {
                    if (try findClosureTargetInInstrs(allocator, block.instructions, src)) |target| return target;
                }
            }
        }
        return null;
    }

    /// Walk aliases backwards from `local` to find the originating `make_closure`.
    /// Cycle protection uses a visited set rather than a depth cap so deeply-
    /// aliased code (long pipeline chains, decision-tree fan-out) still resolves
    /// to a direct call instead of silently degrading to dynamic dispatch.
    fn findClosureTargetInInstrs(allocator: Allocator, instrs: []const ir.Instruction, local: ir.LocalId) BuildError!?ClosureCallTarget {
        var visited: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        defer visited.deinit(allocator);
        return try findClosureTargetInInstrsRec(allocator, instrs, local, &visited);
    }

    fn findClosureTargetInInstrsRec(
        allocator: Allocator,
        instrs: []const ir.Instruction,
        local: ir.LocalId,
        visited: *std.AutoHashMapUnmanaged(ir.LocalId, void),
    ) BuildError!?ClosureCallTarget {
        const visited_entry = try visited.getOrPut(allocator, local);
        if (visited_entry.found_existing) return null;
        for (instrs) |instr| {
            switch (instr) {
                .make_closure => |mc| if (mc.dest == local) return .{ .function_id = mc.function, .captures = mc.captures },
                .local_get => |lg| if (lg.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, lg.source, visited)) |target| return target;
                },
                .borrow_value => |bv| if (bv.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, bv.source, visited)) |target| return target;
                },
                .copy_value => |cv| if (cv.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, cv.source, visited)) |target| return target;
                },
                .local_set => |ls| if (ls.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, ls.value, visited)) |target| return target;
                },
                .move_value => |mv| if (mv.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, mv.source, visited)) |target| return target;
                },
                .share_value => |sv| if (sv.dest == local) {
                    if (try findClosureTargetInInstrsRec(allocator, instrs, sv.source, visited)) |target| return target;
                },
                .if_expr => |ie| {
                    if (try findClosureTargetInInstrsRec(allocator, ie.then_instrs, local, visited)) |target| return target;
                    if (try findClosureTargetInInstrsRec(allocator, ie.else_instrs, local, visited)) |target| return target;
                },
                .case_block => |cb| {
                    if (try findClosureTargetInInstrsRec(allocator, cb.pre_instrs, local, visited)) |target| return target;
                    for (cb.arms) |arm| {
                        if (try findClosureTargetInInstrsRec(allocator, arm.cond_instrs, local, visited)) |target| return target;
                        if (try findClosureTargetInInstrsRec(allocator, arm.body_instrs, local, visited)) |target| return target;
                    }
                    if (try findClosureTargetInInstrsRec(allocator, cb.default_instrs, local, visited)) |target| return target;
                },
                .guard_block => |gb| if (try findClosureTargetInInstrsRec(allocator, gb.body, local, visited)) |target| return target,
                .switch_literal => |sl| {
                    for (sl.cases) |case| {
                        if (try findClosureTargetInInstrsRec(allocator, case.body_instrs, local, visited)) |target| return target;
                    }
                    if (try findClosureTargetInInstrsRec(allocator, sl.default_instrs, local, visited)) |target| return target;
                },
                .switch_return => |sr| {
                    for (sr.cases) |case| {
                        if (try findClosureTargetInInstrsRec(allocator, case.body_instrs, local, visited)) |target| return target;
                    }
                    if (try findClosureTargetInInstrsRec(allocator, sr.default_instrs, local, visited)) |target| return target;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |case| {
                        if (try findClosureTargetInInstrsRec(allocator, case.body_instrs, local, visited)) |target| return target;
                    }
                },
                .union_switch => |us| {
                    for (us.cases) |case| {
                        if (try findClosureTargetInInstrsRec(allocator, case.body_instrs, local, visited)) |target| return target;
                    }
                    if (us.has_else) {
                        if (try findClosureTargetInInstrsRec(allocator, us.else_instrs, local, visited)) |target| return target;
                    }
                },
                .try_call_named => |tcn| {
                    if (try findClosureTargetInInstrsRec(allocator, tcn.handler_instrs, local, visited)) |target| return target;
                    if (try findClosureTargetInInstrsRec(allocator, tcn.success_instrs, local, visited)) |target| return target;
                },
                .optional_dispatch => |od| {
                    if (try findClosureTargetInInstrsRec(allocator, od.nil_instrs, local, visited)) |target| return target;
                    if (try findClosureTargetInInstrsRec(allocator, od.struct_instrs, local, visited)) |target| return target;
                },
                else => {},
            }
        }
        return null;
    }

    fn emitNamedCallToTarget(self: *ZirDriver, target_id: ir.FunctionId, args_locals: []const ir.LocalId) !u32 {
        const target_func = self.findFunctionById(target_id) orelse return error.EmitFailed;
        var args: std.ArrayListUnmanaged(u32) = .empty;
        defer args.deinit(self.allocator);
        for (args_locals) |arg| {
            const ref = try self.refForValueLocal(arg);
            try args.append(self.allocator, ref);
        }

        // Cross-struct routing
        const target_struct = target_func.struct_name;
        const is_cross = blk: {
            if (target_struct == null and self.current_emit_struct == null) break :blk false;
            if (target_struct == null or self.current_emit_struct == null) break :blk true;
            break :blk !std.mem.eql(u8, target_struct.?, self.current_emit_struct.?);
        };
        if (is_cross and target_struct != null) {
            return try self.emitCrossStructCall(target_struct.?, target_func.local_name, args.items);
        }

        const call_name = if (self.current_emit_struct != null and target_func.local_name.len > 0)
            target_func.local_name
        else
            target_func.name;
        const ref = zir_builder_emit_call(self.handle, call_name.ptr, @intCast(call_name.len), args.items.ptr, @intCast(args.items.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn emitFunctionRefForTarget(self: *ZirDriver, target_func: ir.Function) BuildError!u32 {
        const target_struct = target_func.struct_name;
        const is_cross = blk: {
            if (target_struct == null and self.current_emit_struct == null) break :blk false;
            if (target_struct == null or self.current_emit_struct == null) break :blk true;
            break :blk !self.currentStructMatches(target_struct.?);
        };
        if (is_cross and target_struct != null) {
            return try self.emitCrossStructRef(target_struct.?, target_func.local_name);
        }
        const call_name = if (self.current_emit_struct != null and target_func.local_name.len > 0)
            target_func.local_name
        else
            target_func.name;
        const ref = zir_builder_emit_decl_ref(self.handle, call_name.ptr, @intCast(call_name.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn emitCapturedClosureTargetCall(self: *ZirDriver, callee: ir.LocalId, target_id: ir.FunctionId, args_locals: []const ir.LocalId) !u32 {
        const target_func = self.findFunctionById(target_id) orelse return error.EmitFailed;
        const callee_ref = try self.refForLocal(callee);
        const env_ref = zir_builder_emit_field_val(self.handle, callee_ref, "env", 3);
        if (env_ref == error_ref) return error.EmitFailed;

        var args: std.ArrayListUnmanaged(u32) = .empty;
        defer args.deinit(self.allocator);
        try args.append(self.allocator, env_ref);
        for (args_locals) |arg| {
            const ref_arg = try self.refForValueLocal(arg);
            try args.append(self.allocator, ref_arg);
        }

        const target_struct = target_func.struct_name;
        const is_cross = blk: {
            if (target_struct == null and self.current_emit_struct == null) break :blk false;
            if (target_struct == null or self.current_emit_struct == null) break :blk true;
            break :blk !self.currentStructMatches(target_struct.?);
        };
        if (is_cross and target_struct != null) {
            return try self.emitCrossStructCall(target_struct.?, target_func.local_name, args.items);
        }

        const call_name = if (self.current_emit_struct != null and target_func.local_name.len > 0)
            target_func.local_name
        else
            target_func.name;
        const ref = zir_builder_emit_call(self.handle, call_name.ptr, @intCast(call_name.len), args.items.ptr, @intCast(args.items.len));
        if (ref == error_ref) return error.EmitFailed;
        return ref;
    }

    fn emitTailNamedCallToTarget(self: *ZirDriver, target_id: ir.FunctionId, args_locals: []const ir.LocalId) !void {
        const ref = try self.emitNamedCallToTarget(target_id, args_locals);
        if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
    }

    fn emitTailInvokeWrapperCall(self: *ZirDriver, callee: ir.LocalId, function_id: ir.FunctionId, args_locals: []const ir.LocalId) !bool {
        const func_def = self.findFunctionById(function_id) orelse return false;

        const callee_ref = try self.refForLocal(callee);
        const env_ref = zir_builder_emit_field_val(self.handle, callee_ref, "env", 3);
        if (env_ref == error_ref) return error.EmitFailed;

        const invoke_name = try std.fmt.allocPrint(self.allocator, "__closure_invoke_{d}", .{function_id});
        defer self.allocator.free(invoke_name);

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
                try self.refForLocal(args_locals[i])
            else
                @intFromEnum(Zir.Inst.Ref.void_value);
        }
        const arg_struct = zir_builder_emit_struct_init_anon(self.handle, name_ptrs.ptr, name_lens.ptr, values.ptr, @intCast(values.len));
        if (arg_struct == error_ref) return error.EmitFailed;

        const call_args = [_]u32{ env_ref, arg_struct };
        const ref = zir_builder_emit_call(self.handle, invoke_name.ptr, @intCast(invoke_name.len), &call_args, 2);
        if (ref == error_ref) return error.EmitFailed;
        if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
        return true;
    }

    /// True when the `call_closure` defining `local` is a TOP-LEVEL
    /// instruction immediately followed by `ret local` — the shape that lets
    /// the contified-singleton path emit a musttail call and skip the
    /// following `ret`. `current_instr_index` / `current_block_instructions`
    /// track only the TOP-LEVEL block walk, so for a NESTED `call_closure`
    /// (inside an if/case/guard arm) this check would read an unrelated
    /// top-level instruction (audit zirb-1--01, the secondary `isTailReturnOf`
    /// hazard). Guard by confirming the top-level instruction at
    /// `current_instr_index` is itself the `call_closure` defining `local`; a
    /// nested call fails that check and is never treated as a tail return (its
    /// branch yields through the if-else merge, not a function `ret`, so the
    /// musttail rewrite would be unsound there anyway).
    fn isTailReturnOf(self: *const ZirDriver, local: ir.LocalId) bool {
        const cur_idx = @as(usize, self.current_instr_index);
        if (cur_idx >= self.current_block_instructions.len) return false;
        const here = self.current_block_instructions[cur_idx];
        if (here != .call_closure or here.call_closure.dest != local) return false;
        const next_idx = cur_idx + 1;
        if (next_idx >= self.current_block_instructions.len) return false;
        return switch (self.current_block_instructions[next_idx]) {
            .ret => |r| r.value != null and r.value.? == local,
            else => false,
        };
    }

    fn emitClosureSwitchDispatch(self: *ZirDriver, cc: ir.CallClosure, targets: []const ir.FunctionId) !bool {
        const callee_ref = try self.refForLocal(cc.callee);
        const call_fn_ref = zir_builder_emit_field_val(self.handle, callee_ref, "call_fn", 7);
        if (call_fn_ref == error_ref) return error.EmitFailed;

        var fallback_args: std.ArrayListUnmanaged(u32) = .empty;
        defer fallback_args.deinit(self.allocator);
        for (cc.args) |arg| {
            const ref = try self.refForValueLocal(arg);
            try fallback_args.append(self.allocator, ref);
        }

        var fallback_ref: u32 = undefined;
        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();

        self.beginCapture();
        var fallback_capture_open = true;
        errdefer if (fallback_capture_open) self.discardCapture();

        fallback_ref = zir_builder_emit_call_ref(self.handle, callee_ref, fallback_args.items.ptr, @intCast(fallback_args.items.len));
        if (fallback_ref == error_ref) return error.EmitFailed;
        try self.setLocal(cc.dest, fallback_ref);
        var else_len: u32 = 0;
        const else_ptr = self.endCapture(&else_len);
        fallback_capture_open = false;
        try current_else_insts.replaceWithCopy(else_ptr[0..else_len]);
        var current_else_result = fallback_ref;

        var emitted = false;
        var i: usize = targets.len;
        while (i > 0) {
            i -= 1;
            const target_id = targets[i];
            const target_func = self.findFunctionById(target_id) orelse continue;
            if (target_func.captures.len != 0) continue;
            emitted = true;

            const target_name = target_func.name;
            const name_ref = zir_builder_emit_str(self.handle, target_name.ptr, @intCast(target_name.len));
            if (name_ref == error_ref) return error.EmitFailed;
            const cond_ref = zir_builder_emit_binop(self.handle, @intFromEnum(Zir.Inst.Tag.cmp_eq), call_fn_ref, name_ref);
            if (cond_ref == error_ref) return error.EmitFailed;

            const then_body = blk: {
                self.beginCapture();
                var capture_open = true;
                errdefer if (capture_open) self.discardCapture();

                const direct_ref = try self.emitNamedCallToTarget(target_id, cc.args);
                try self.setLocal(cc.dest, direct_ref);
                var then_len: u32 = 0;
                const then_ptr = self.endCapture(&then_len);
                capture_open = false;
                const then_insts = try self.allocator.alloc(u32, then_len);
                @memcpy(then_insts, then_ptr[0..then_len]);
                break :blk .{ .result = direct_ref, .insts = then_insts };
            };
            defer self.allocator.free(then_body.insts);

            const else_insts = current_else_insts.get();

            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                then_body.insts.ptr,
                @intCast(then_body.insts.len),
                then_body.result,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            current_else_insts.clear();
            if (ref == error_ref) return error.EmitFailed;

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                current_else_result = ref;
            }
        }

        if (!emitted) return false;
        try self.setLocal(cc.dest, current_else_result);
        return true;
    }

    fn emitInstruction(self: *ZirDriver, instr: ir.Instruction) BuildError!void {
        switch (instr) {
            // Constants
            .const_int => |ci| {
                // Integer-literal typing priority:
                //  1. Explicit IR hint. The IR layer (`lowerExpr`'s
                //     `int_lit` arm) resolves the literal's concrete
                //     integer type from the type-checker's concretization
                //     OR — for a still-default `I64` literal — from the
                //     surrounding *expected type* (`current_expected_type`):
                //     a callee's parameter type for a call argument, or the
                //     enclosing block's result type for a tail/return-
                //     position literal. That context is authoritative, so
                //     a present `type_hint` always wins. Critically, the
                //     hint is computed where the call-arg vs return-position
                //     distinction is known; the ZIR layer must NOT second-
                //     guess it from the enclosing function return type,
                //     which would mis-narrow call-argument literals such as
                //     `D.f(-5)` inside a `-> u8` caller.
                //  2. Inside a case block: typed `i64` so a literal that
                //     becomes the case result does not flow out of
                //     runtime control flow as a bare `comptime_int`.
                //  3. Else a bare integer (Zig infers `comptime_int`),
                //     unchanged for every straight-line use.
                const type_hint_ref: u32 = if (ci.type_hint) |type_hint| mapReturnType(type_hint) else 0;
                const ref = if (type_hint_ref != 0)
                    zir_builder_emit_int_typed(self.handle, ci.value, type_hint_ref)
                else if (self.current_case_dest != null)
                    zir_builder_emit_int_typed(self.handle, ci.value, @intFromEnum(Zir.Inst.Ref.i64_type))
                else
                    zir_builder_emit_int(self.handle, ci.value);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(ci.dest, ref);
            },
            .const_float => |cf| {
                // Float-literal typing priority mirrors `const_int`:
                //  1. Explicit IR hint (the literal's concretized/adopted
                //     float width) — coerce the bare float to it.
                //  2. Inside a case/branch result block: typed `f64` so a
                //     literal that becomes the control-flow result does not
                //     flow out as a bare `comptime_float` (Zig rejects a
                //     comptime-only value depending on runtime control flow —
                //     the float analog of the `comptime_int` case-result fix).
                //  3. Else a bare float (Zig infers `comptime_float`),
                //     unchanged for every straight-line use.
                const raw_ref = zir_builder_emit_float(self.handle, cf.value);
                if (raw_ref == error_ref) return error.EmitFailed;
                const type_hint_ref: u32 = if (cf.type_hint) |type_hint| mapReturnType(type_hint) else 0;
                const ref = if (type_hint_ref != 0)
                    zir_builder_emit_as(self.handle, type_hint_ref, raw_ref)
                else if (self.current_case_dest != null)
                    zir_builder_emit_as(self.handle, @intFromEnum(Zir.Inst.Ref.f64_type), raw_ref)
                else
                    raw_ref;
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
                try self.propagateParamDerivedClosureLocal(lg.dest, lg.source);
                if (self.closure_function_map.get(lg.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, lg.dest, func_id);
                if (self.local_refs.get(lg.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, lg.dest, value_ref);
                }
            },
            // Phase C: borrow_value lowers to a plain value-alias —
            // identical propagation to local_get, with NO runtime
            // retain. The borrow scope owner (the source) keeps its
            // refcount; dest is never destroyed at scope exit (drop
            // insertion skips borrowed locals; verifier will enforce
            // this in Phase E).
            .borrow_value => |bv| {
                try self.propagateReuseBackedStructLocal(bv.dest, bv.source);
                try self.propagateReuseBackedUnionLocal(bv.dest, bv.source);
                try self.propagateReuseBackedTupleLocal(bv.dest, bv.source);
                try self.propagateParamDerivedClosureLocal(bv.dest, bv.source);
                if (self.closure_function_map.get(bv.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, bv.dest, func_id);
                if (self.local_refs.get(bv.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, bv.dest, value_ref);
                }
            },
            // Phase C: copy_value lowers to value-alias plus a runtime
            // retain on the source's cell, producing an independent
            // owner. The matching scope-exit destroy is emitted by the
            // arc_drop_insertion pass (today: a `.release` IR
            // instruction lowered to a `releaseAny` runtime call).
            // Follows the post-Phase-6.8 lowering for `.local_get` of
            // ARC sources, but is now produced explicitly by the
            // arc_ownership classifier rather than emitted at every
            // `.local_get` site.
            //
            // Use `retainAnyPersistent` (not `retainAny`): the new
            // local is a *persistent* second owner of the source's
            // cell that lives until its own scope-exit release, not a
            // transient borrow paired with an immediate release. The
            // Map workload classifier treats this retain as a
            // genuine sharing event because the source's cell is
            // observably held by two long-lived owners simultaneously.
            .copy_value => |cv| {
                // Phase 1 Class A: `.copy_value` is now pure dataflow.
                // The persistent retain that previously fired here is
                // emitted as an explicit `.retain { kind: .persistent }`
                // IR instruction immediately after the `.copy_value`
                // by `arc_ownership.zig`. The IR-level retain is
                // visible to every analysis pass, replacing the
                // implicit-retain coordination that the V10 audit
                // flagged. The ZIR-level `.retain` handler dispatches
                // on the kind enum to pick the right runtime helper
                // (`retainAny` vs `retainAnyPersistent`).
                try self.propagateReuseBackedStructLocal(cv.dest, cv.source);
                try self.propagateReuseBackedUnionLocal(cv.dest, cv.source);
                try self.propagateReuseBackedTupleLocal(cv.dest, cv.source);
                try self.propagateParamDerivedClosureLocal(cv.dest, cv.source);
                if (self.closure_function_map.get(cv.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, cv.dest, func_id);
                if (self.local_refs.get(cv.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, cv.dest, value_ref);

                    if (self.shouldSkipArc(cv.source)) {
                        // Pair the suppression with the eventual
                        // scope-exit `.release` so we don't release a
                        // cell that was never retained. The arc_ownership
                        // pass still emits an explicit `.retain` IR
                        // alongside the `.copy_value`; this set tracks
                        // dests whose retain emission must also be
                        // skipped at ZIR-time via `shouldSkipArc`. The
                        // matching `.release` is suppressed by
                        // `isReleaseSuppressed`.
                        //
                        // Under `clone_on_share_active` (Tracking) `shouldSkipArc`
                        // is unconditionally true, so EVERY copy_value dest lands
                        // here provisionally. That is correct for a TRANSIENT
                        // borrow (a `.normal` / `protocol_box_retain` retain that
                        // does NOT clone — the dest aliases the source's cell and
                        // its scope-exit release/drop must be suppressed to avoid
                        // a double-free). But a PERSISTENT share clones via
                        // `shareAnyPersistent` into a genuine independent owner
                        // whose release MUST fire; the `.persistent` branch of the
                        // `.retain` handler REMOVES such a dest from this set
                        // (`unmarkShareSkippedForClone`). The copy_value site
                        // cannot see the paired retain kind, so it provisionally
                        // suppresses and the retain handler is the authority.
                        try self.arc_share_skipped.put(self.allocator, cv.dest, {});
                    }
                }
            },
            .local_set => |ls| {
                try self.propagateReuseBackedStructLocal(ls.dest, ls.value);
                try self.propagateReuseBackedUnionLocal(ls.dest, ls.value);
                try self.propagateReuseBackedTupleLocal(ls.dest, ls.value);
                try self.propagateParamDerivedClosureLocal(ls.dest, ls.value);
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
                try self.propagateParamDerivedClosureLocal(mv.dest, mv.source);
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
                try self.propagateParamDerivedClosureLocal(sv.dest, sv.source);
                if (self.closure_function_map.get(sv.source)) |func_id|
                    try self.closure_function_map.put(self.allocator, sv.dest, func_id);
                if (self.local_refs.get(sv.source)) |value_ref| {
                    try self.local_refs.put(self.allocator, sv.dest, value_ref);

                    switch (sv.mode) {
                        .consume => {
                            // Perceus-style ownership-transfer optimization:
                            // the source local is at its last use, so the
                            // caller has no further need to bump the refcount
                            // before passing the value into the callee. The
                            // assign has already happened above (via
                            // `local_refs.put`); skip the retain.
                            //
                            // CRITICAL: this share mode skips only the
                            // retain emitted by share lowering. It is not
                            // a release-suppression reason; the matching
                            // post-call `.release{value=sv.dest}` remains
                            // unless a separate symmetric retain-elision
                            // path records the share in `arc_share_skipped`
                            // (escape analysis or return-source elision).
                            //
                            // Net effect of consume mode in the steady
                            // state: -1 retain. Net refcount delta of
                            // the (consume share + post-call release)
                            // pair is -1, which exactly cancels the +1
                            // imbalance the source local would otherwise
                            // accumulate from the still-emitted scope-
                            // exit release inserted by the drop-insertion
                            // pass on its source. (Without consume, the
                            // share-emitted retain would have produced
                            // +1; with consume, no retain is emitted and
                            // ownership transfers naturally.)
                            //
                            // Emit a ZIR call to bump the runtime
                            // `arc_consumes_total` counter. Observed at
                            // runtime via `ZAP_ARC_STATS=1`; this is the
                            // load-bearing signal that proves consume
                            // sites fired during program execution.
                            //
                            // Phase 6 elision: the consume counter is
                            // part of the refcount instrumentation; an
                            // arena/no-op manager neither emits retains
                            // to elide nor maintains the counter.
                            if (self.shouldEmitRefcountOps()) {
                                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                                if (rt_import == error_ref) return error.EmitFailed;
                                const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                                if (arc_runtime == error_ref) return error.EmitFailed;
                                const note_consume_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "noteConsume", 11);
                                if (note_consume_fn == error_ref) return error.EmitFailed;
                                const args = [_]u32{};
                                const note_consume_ref = zir_builder_emit_call_ref(self.handle, note_consume_fn, &args, 0);
                                if (note_consume_ref == error_ref) return error.EmitFailed;
                            }
                        },
                        .retain => {
                            // Phase 1 Class A item 2: the retain that
                            // previously fired here as a direct
                            // `retainAny` ZIR call is now an explicit
                            // `.retain { kind: .normal }` IR
                            // instruction emitted alongside the
                            // `.share_value` by the IR builder. The
                            // `.share_value` lowering is pure dataflow
                            // alias; the retain is the IR-level signal
                            // visible to every analysis pass.
                            //
                            // The skip-arc bookkeeping still fires
                            // here so the matching post-call `.release`
                            // is suppressed when the source is stack-
                            // eligible (e.g., a Map literal that
                            // doesn't escape). Without this, the
                            // explicit `.retain` would also be elided
                            // (via `shouldSkipArc` check in the
                            // `.retain` handler) but the post-call
                            // `.release` would still fire,
                            // double-releasing the cell. The
                            // `arc_share_skipped` set is consulted by
                            // `isReleaseSuppressed`.
                            if (self.shouldSkipArc(sv.source)) {
                                try self.arc_share_skipped.put(self.allocator, sv.dest, {});
                            }
                        },
                    }
                }
            },
            .param_get => |pg| {
                // Loopification: load the param's per-iteration value
                // from its stack slot. Each `param_get` emits a fresh
                // `load`; LLVM's mem2reg merges them into a single
                // phi at the loop header.
                if (self.loopify_slots) |slots| {
                    if (pg.index < slots.len) {
                        const loaded = try self.emitLoad(slots[pg.index]);
                        try self.setLocal(pg.dest, loaded);
                        try self.markParamDerivedClosureLocal(pg.dest);
                        try self.markDestructiveScrutineeIfApplicable(pg);
                        return;
                    }
                }
                // Look up param ref from the dedicated param_refs array,
                // NOT from local_refs which may have been overwritten by
                // earlier param_get dest assignments.
                if (pg.index < self.param_refs.items.len) {
                    try self.setLocal(pg.dest, self.param_refs.items[pg.index]);
                    try self.markParamDerivedClosureLocal(pg.dest);
                    try self.markDestructiveScrutineeIfApplicable(pg);
                } else if (self.local_refs.get(pg.index)) |value_ref| {
                    const materialized = try self.materializeValueRef(value_ref);
                    try self.setLocal(pg.dest, materialized);
                    try self.propagateParamDerivedClosureLocal(pg.dest, pg.index);
                }
            },

            // Binary operations
            .binary_op => |bo| {
                if (bo.op == .bool_and or bo.op == .bool_or) {
                    // Emit short-circuit bool_br_and / bool_br_or ZIR instructions.
                    // The RHS is wrapped in a body so it's only evaluated when needed.
                    const lhs = try self.refForLocal(bo.lhs);
                    const rhs = try self.refForLocal(bo.rhs);
                    // Body is empty (RHS already evaluated as a local), just pass the result.
                    const empty_body = [_]u32{};
                    const ref = if (bo.op == .bool_and)
                        try self.emitBoolBrAnd(lhs, &empty_body, rhs)
                    else
                        try self.emitBoolBrOr(lhs, &empty_body, rhs);
                    try self.setLocal(bo.dest, ref);
                } else if (mapBinopTag(bo.op, bo.result_type, self.arithmetic_overflow_traps)) |tag| {
                    const lhs = try self.refForLocal(bo.lhs);
                    const rhs = try self.refForLocal(bo.rhs);
                    const ref = zir_builder_emit_binop(self.handle, tag, lhs, rhs);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .string_eq or bo.op == .string_neq) {
                    // String comparison via std.mem.eql(u8, lhs, rhs)
                    const lhs = try self.refForLocal(bo.lhs);
                    const rhs = try self.refForLocal(bo.rhs);

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
                    // concat — emit @import("zap_runtime").String.concat(lhs, rhs)
                    const lhs = try self.refForLocal(bo.lhs);
                    const rhs = try self.refForLocal(bo.rhs);

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const zap_string = zir_builder_emit_field_val(self.handle, rt_import, "String", 6);
                    if (zap_string == error_ref) return error.EmitFailed;
                    const concat_fn = zir_builder_emit_field_val(self.handle, zap_string, "concat", 6);
                    if (concat_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ lhs, rhs };
                    const ref = zir_builder_emit_call_ref(self.handle, concat_fn, &args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .in_list) {
                    // in — emit: lhs == list[0] or lhs == list[1] or ...
                    // For runtime lists, call the list's contains method via generic dispatch.
                    const lhs = try self.refForLocal(bo.lhs);
                    const rhs = try self.refForLocal(bo.rhs);

                    // Use the generic list contains: get the list type, then call .contains(list, value)
                    // The list (rhs) already has the right type at runtime — call contains as a method.
                    const list_mod = try self.emitListCellRef(.i64);
                    const contains_fn = zir_builder_emit_field_val(self.handle, list_mod, "contains", 8);
                    if (contains_fn == error_ref) return error.EmitFailed;

                    const call_args = [_]u32{ rhs, lhs };
                    const ref = zir_builder_emit_call_ref(self.handle, contains_fn, &call_args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bo.dest, ref);
                } else if (bo.op == .in_range) {
                    // in_range: check value >= min(start,end) and value <= max(start,end)
                    // and rem(value - start, step) == 0
                    const value_ref = try self.refForLocal(bo.lhs);
                    const range_ref = try self.refForLocal(bo.rhs);

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
                    const in_bounds = try self.emitBoolBrAnd(gte_min, &empty_body, lte_max);
                    const result = try self.emitBoolBrAnd(in_bounds, &empty_body, on_step);

                    try self.setLocal(bo.dest, result);
                }
            },

            // Unary operations
            .unary_op => |uo| {
                const operand = try self.refForLocal(uo.operand);
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
                var args: std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (cn.args) |arg| {
                    const ref = try self.refForValueLocal(arg);
                    try args.append(self.allocator, ref);
                }

                // Inline default parameter values: emit default ZIR instructions
                // BEFORE the call (so they don't interfere with addCall's inst
                // prediction).
                //
                // audit zirb-2--02: this previously matched candidates by the
                // arity-STRIPPED base name and filled defaults for the FIRST
                // defaults-bearing function with that base — with no preference
                // for the exact resolved name. When an overload family mixes a
                // no-default `f/1` with a defaults-bearing `f/3`, a cross-struct
                // call the type checker resolved to `f/1` (arriving here as
                // `call_named` with `cn.name == "S__f__1"`) was silently
                // rewritten to call `S__f__3` with defaults appended — running
                // the wrong overload. `cn.name` already encodes the type
                // checker's + IR mangler's resolved (name, declared-arity)
                // decision, so key the fill on the EXACT name: only fill for the
                // function whose mangled name IS `cn.name`. That honors the
                // resolved overload (the no-default `f/1` is never rewritten to
                // `f/3`) while still filling the gap for a genuinely-defaulted
                // resolved target (e.g. `add(5)` -> `S__add__2`).
                const resolved_call_name: []const u8 = cn.name;
                if (self.program) |prog| {
                    for (prog.functions) |func| {
                        if (func.defaults.len == 0) continue;
                        if (!std.mem.eql(u8, func.name, cn.name)) continue;
                        const full_arity = func.params.len;
                        if (args.items.len >= full_arity) break;
                        const first_default_idx = full_arity - func.defaults.len;
                        // Every non-default parameter must be supplied; a call
                        // arriving with fewer args than the first defaulted
                        // position is an under-supply the front end should never
                        // produce. Surface it rather than left-shifting the
                        // defaults into the wrong parameter slots.
                        if (args.items.len < first_default_idx) return error.EmitFailed;
                        var pi = args.items.len;
                        while (pi < full_arity) : (pi += 1) {
                            const di = pi - first_default_idx;
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
                        break;
                    }
                }

                {
                    // Look up the target function — first by full mangled
                    // name, then by local_name. Bare-name calls produced by
                    // macro-expanded code (e.g. functions imported via
                    // `use SomeStruct`) only carry the unmangled identifier;
                    // the local_name lookup recovers the right target.
                    var target_func = self.findFunctionByName(resolved_call_name) orelse
                        self.findFunctionByLocalName(resolved_call_name);
                    // Try stripping struct prefix for impl functions compiled
                    // as root-level functions (e.g., "List__next__1" → "next__1")
                    if (target_func == null) {
                        if (std.mem.indexOf(u8, resolved_call_name, "__")) |sep| {
                            const stripped = resolved_call_name[sep + 2 ..];
                            target_func = self.findFunctionByName(stripped);
                        }
                    }
                    // Generic-impl monomorphization places the specialized
                    // copy in the caller struct's emitted Zig namespace and
                    // names it `<TargetStruct>_<func>__<type>__<arity>`
                    // (one underscore between target struct and func, two
                    // as the outer separators). Recover those entries by
                    // scanning the caller's namespace for a `local_name`
                    // whose `<TargetStruct>_<func>__` prefix matches the
                    // call's `<TargetStruct>__<func>__` prefix and whose
                    // `__<arity>` suffix matches.
                    if (target_func == null) {
                        if (self.current_emit_struct) |caller_struct| {
                            target_func = try self.findMonomorphizedImplFor(caller_struct, resolved_call_name);
                        }
                    }
                    const target_struct = if (target_func) |tf| tf.struct_name else null;
                    const is_cross_struct = blk: {
                        if (target_struct == null and self.current_emit_struct == null) break :blk false;
                        if (target_struct == null or self.current_emit_struct == null) break :blk true;
                        break :blk !std.mem.eql(u8, target_struct.?, self.current_emit_struct.?);
                    };

                    if (is_cross_struct and target_struct != null) {
                        const target_local = if (target_func) |tf|
                            (if (tf.local_name.len > 0) tf.local_name else cn.name)
                        else
                            cn.name;
                        const ref = try self.emitCrossStructCall(target_struct.?, target_local, args.items);
                        try self.setLocal(cn.dest, ref);
                    } else if (is_cross_struct and target_struct == null) {
                        // Root-level impl function called from a struct.
                        // Convert the struct-prefixed name to call_builtin format
                        // and emit through the standard call_builtin handler.
                        // "List__next__1" → "List.next" (call_builtin format)
                        if (std.mem.indexOf(u8, resolved_call_name, "__")) |mod_sep| {
                            const mod_prefix = resolved_call_name[0..mod_sep];
                            const rest = resolved_call_name[mod_sep + 2 ..];
                            const func_base = if (std.mem.lastIndexOf(u8, rest, "__")) |arity_sep|
                                rest[0..arity_sep]
                            else
                                rest;
                            const builtin_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod_prefix, func_base });
                            try self.emitInstruction(.{
                                .call_builtin = .{ .dest = cn.dest, .name = builtin_name, .args = cn.args, .arg_modes = cn.arg_modes },
                            });
                            return;
                        }
                        // Fallback: emit as regular call
                        const call_name = if (target_func) |tf| tf.name else resolved_call_name;
                        const ref = zir_builder_emit_call(self.handle, call_name.ptr, @intCast(call_name.len), args.items.ptr, @intCast(args.items.len));
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cn.dest, ref);
                    } else {
                        const call_name = if (self.current_emit_struct != null)
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
                var args: std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (tcn.args) |arg| {
                    const ref = try self.refForValueLocal(arg);
                    try args.append(self.allocator, ref);
                }
                zir_builder_set_call_modifier(self.handle, 3); // no_optimizations

                // Resolve name for per-struct emission
                const try_target = self.findFunctionByName(tcn.name) orelse
                    self.findFunctionByLocalName(tcn.name);
                const try_target_struct = if (try_target) |tf| tf.struct_name else null;
                const try_is_cross = blk: {
                    if (try_target_struct == null and self.current_emit_struct == null) break :blk false;
                    if (try_target_struct == null or self.current_emit_struct == null) break :blk true;
                    break :blk !std.mem.eql(u8, try_target_struct.?, self.current_emit_struct.?);
                };

                const call_ref = if (try_is_cross and try_target_struct != null) blk: {
                    const target_local = if (try_target) |tf| tf.local_name else tcn.name;
                    break :blk try self.emitCrossStructCall(try_target_struct.?, target_local, args.items);
                } else blk: {
                    const try_call_name = if (self.current_emit_struct != null)
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
                // and, if this step has follow-on pipe steps, run those
                // inline so a failure in any earlier step short-circuits
                // them. The catch-basin expression value is then the
                // result of the deepest success path (or the handler).
                const then_body = blk: {
                    self.beginCapture();
                    var capture_open = true;
                    errdefer if (capture_open) self.discardCapture();

                    const payload = zir_builder_emit_optional_payload_unsafe(self.handle, call_ref);
                    if (payload == error_ref) return error.EmitFailed;
                    if (tcn.payload_local) |pl| {
                        try self.setLocal(pl, payload);
                    }
                    for (tcn.success_instrs) |si| try self.emitInstruction(si);
                    const success_value_ref = if (tcn.success_result) |sr|
                        try self.refForLocal(sr)
                    else
                        payload;
                    var then_len: u32 = 0;
                    const then_ptr = self.endCapture(&then_len);
                    capture_open = false;
                    const then_insts = try self.allocator.alloc(u32, then_len);
                    @memcpy(then_insts, then_ptr[0..then_len]);
                    break :blk .{ .insts = then_insts, .result = success_value_ref };
                };
                defer self.allocator.free(then_body.insts);

                // Else branch (null = no match): evaluate handler with input.
                // The handler's result becomes the value of the if-else block (and
                // therefore the value of the catch basin expression). DO NOT emit
                // a `ret` here: the catch basin is an expression that produces a
                // value, not a control-flow exit from the enclosing function.
                // Emitting `ret` from here breaks any function whose ZIR-level
                // return type differs from the handler's value type — most
                // notably `main`, which Zap lowers as `void`/`u8` to satisfy
                // Zig's entry-point ABI even when the user wrote `-> String`.
                const else_body = blk: {
                    self.beginCapture();
                    var capture_open = true;
                    errdefer if (capture_open) self.discardCapture();

                    // Emit handler instructions (they reference the input local via __err)
                    for (tcn.handler_instrs) |hi| try self.emitInstruction(hi);
                    const handler_result_ref = if (tcn.handler_result) |hr|
                        try self.refForLocal(hr)
                    else
                        @intFromEnum(Zir.Inst.Ref.void_value);
                    var else_len: u32 = 0;
                    const else_ptr = self.endCapture(&else_len);
                    capture_open = false;
                    break :blk .{ .ptr = else_ptr, .len = else_len, .result = handler_result_ref };
                };

                // Emit if-else: if (non_null) { unwrap; ...rest_of_pipe } else { handler_instrs }
                // Both branches break with their respective values; the block's
                // peer-resolved result is the catch-basin expression value.
                const result = zir_builder_emit_if_else_bodies(
                    self.handle,
                    is_non_null,
                    then_body.insts.ptr,
                    @intCast(then_body.insts.len),
                    then_body.result,
                    else_body.ptr,
                    else_body.len,
                    else_body.result,
                    0,
                    0,
                );
                if (result == error_ref) return error.EmitFailed;
                try self.setLocal(tcn.dest, result);
            },
            // Error catch — no longer needed (try_call_named handles unwrapping).
            .error_catch => |ec| {
                const source_ref = try self.refForValueLocal(ec.source);
                try self.setLocal(ec.dest, source_ref);
            },
            .unwrap_error_union => |ueu| {
                // Phase 3.b: the source local holds a raising callee's
                // `error{ZapRaise}!T`. Unwrap it to the payload `T`, rebinding
                // the dest local's ref; the error case is dispatched by mode.
                const source_ref = try self.refForValueLocal(ueu.source);
                switch (ueu.mode) {
                    .propagate => {
                        // `try source` — propagate `error.ZapRaise` out of the
                        // enclosing error-union function; Zig records the ERT.
                        const unwrapped = zir_builder_emit_try(self.handle, source_ref);
                        if (unwrapped == error_ref) return error.EmitFailed;
                        try self.setLocal(ueu.dest, unwrapped);
                    },
                    .route_to_handler => {
                        // `source catch <release-safe sentinel>` — on error the
                        // boxed payload is already in the TLS side-channel and
                        // the enclosing `try`'s landing pad (the following
                        // `raise_occurred()` check) takes over, so this value is
                        // never READ. It is, however, still bound into the
                        // straight-line try-body remainder and a dead ARC-managed
                        // binding gets a scope-exit release on the (taken) raise
                        // path — so the catch value MUST be release-safe. An
                        // `@as(T, undefined)` ARC value is a garbage non-null
                        // pointer whose release derefs a bogus ArcHeader; we emit
                        // a canonical empty/null sentinel instead (see
                        // `emitReleaseSafeCatchValue`).
                        const catch_value = try self.emitReleaseSafeCatchValue(ueu.payload_type);
                        const unwrapped = zir_builder_emit_catch(self.handle, source_ref, catch_value);
                        if (unwrapped == error_ref) return error.EmitFailed;
                        try self.setLocal(ueu.dest, unwrapped);
                    },
                    .abort_unhandled => {
                        // `source catch Kernel.abort_recoverable_raise(...)` —
                        // top-level terminus for a raise that is neither
                        // rescued nor propagated: recover the stashed box and
                        // abort through the Phase 2 crash report.
                        //
                        // The abort is `noreturn` and MUST run only on a
                        // genuine error. Emitting it via `zir_builder_emit_catch`
                        // (which takes a precomputed catch value) placed the
                        // abort call in straight-line position BEFORE the
                        // catch's condbr, so it fired UNCONDITIONALLY — on the
                        // success path too — reading the empty raise
                        // side-channel and aborting "attempt to use null value"
                        // (GAP-P3-01 / FU-33). Capture the abort call into the
                        // else branch instead, so the success path unwraps and
                        // yields the payload and the abort fires only on a real
                        // raise.
                        self.beginCapture();
                        var abort_capture_open = true;
                        errdefer if (abort_capture_open) self.discardCapture();

                        const abort_ref = try self.emitAbortRecoverableRaise(ueu.payload_type);
                        if (abort_ref == error_ref) return error.EmitFailed;
                        var else_len: u32 = 0;
                        const else_ptr = self.endCapture(&else_len);
                        abort_capture_open = false;
                        const else_insts = try self.allocator.alloc(u32, else_len);
                        defer self.allocator.free(else_insts);
                        @memcpy(else_insts, else_ptr[0..else_len]);
                        // The abort call is `noreturn`, so the else body
                        // self-terminates — no trailing break, `else_result`
                        // unused.
                        const unwrapped = zir_builder_emit_catch_with_body(
                            self.handle,
                            source_ref,
                            else_insts.ptr,
                            @intCast(else_insts.len),
                            abort_ref,
                            1,
                        );
                        if (unwrapped == error_ref) return error.EmitFailed;
                        try self.setLocal(ueu.dest, unwrapped);
                    },
                }
            },

            // Builtin calls — emit @import("zap_runtime").Struct.function(args)
            .call_builtin => |cb| {
                var args: std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (cb.args) |arg| {
                    const ref = try self.refForValueLocal(arg);
                    try args.append(self.allocator, ref);
                }

                // Handle generic container calls: "List:StructName.method"
                // These are emitted by the IR builder for struct element lists.
                const generic_handled = if (std.mem.startsWith(u8, cb.name, "List:")) blk: {
                    const after_prefix = cb.name["List:".len..];
                    const dot_idx = std.mem.findScalar(u8, after_prefix, '.') orelse return error.EmitFailed;
                    const type_name = after_prefix[0..dot_idx];
                    const method_name = after_prefix[dot_idx + 1 ..];
                    const type_ref = try self.emitRequiredEncodedContainerElementTypeRef(type_name);
                    const type_args = [_]u32{type_ref};
                    const list_type = try self.emitGenericContainerRef("List", &type_args);
                    const fn_ref = zir_builder_emit_field_val(self.handle, list_type, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                    break :blk true;
                } else if (std.mem.startsWith(u8, cb.name, "Map:")) blk2: {
                    // Handle "Map:keytype:ValueStructName.method"
                    const after_prefix = cb.name["Map:".len..];
                    // Parse key_type_name:value_struct_name.method
                    const colon_idx = std.mem.findScalar(u8, after_prefix, ':') orelse return error.EmitFailed;
                    const key_type_name = after_prefix[0..colon_idx];
                    const rest = after_prefix[colon_idx + 1 ..];
                    const dot_idx = std.mem.findScalar(u8, rest, '.') orelse return error.EmitFailed;
                    const value_struct_name = rest[0..dot_idx];
                    const method_name = rest[dot_idx + 1 ..];
                    const key_ref = try self.emitRequiredEncodedContainerElementTypeRef(key_type_name);
                    const val_ref = try self.emitRequiredEncodedContainerElementTypeRef(value_struct_name);
                    const type_args = [_]u32{ key_ref, val_ref };
                    const map_type = try self.emitGenericContainerRef("Map", &type_args);
                    const fn_ref = zir_builder_emit_field_val(self.handle, map_type, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;
                    // For Map(_, Term).get/put-style methods whose default value
                    // or value argument is supplied as a concrete Zap type, wrap
                    // the relevant arg in `Term.from` and remember the original
                    // ref so the result can be unwrapped back to that type.
                    var dispatched_args = args.items;
                    var wrapped_buf: [16]u32 = undefined;
                    var unwrap_default_ref: ?u32 = null;
                    const value_is_term = std.mem.eql(u8, value_struct_name, "Term");
                    if (value_is_term and args.items.len <= wrapped_buf.len) {
                        @memcpy(wrapped_buf[0..args.items.len], args.items);
                        if (std.mem.eql(u8, method_name, "get") and args.items.len >= 3) {
                            unwrap_default_ref = wrapped_buf[2];
                            wrapped_buf[2] = try self.emitTermWrap(wrapped_buf[2]);
                        }
                        if (std.mem.eql(u8, method_name, "put") and args.items.len >= 3) {
                            wrapped_buf[2] = try self.emitTermWrap(wrapped_buf[2]);
                        }
                        dispatched_args = wrapped_buf[0..args.items.len];
                    }
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, dispatched_args.ptr, @intCast(dispatched_args.len));
                    if (ref == error_ref) return error.EmitFailed;
                    var final_ref = ref;
                    // For `Map(_, Term).get`, unwrap the returned Term back to
                    // the default argument's static type so the call site stays
                    // type-compatible with the user-declared `value` slot in
                    // `Map.get` (`-> value`). Uses
                    // `Term.to(@TypeOf(default), result, default)`.
                    if (unwrap_default_ref) |default_ref| {
                        final_ref = try self.emitTermUnwrapWithDefault(ref, default_ref);
                    }
                    try self.setLocal(cb.dest, final_ref);
                    break :blk2 true;
                } else if (std.mem.startsWith(u8, cb.name, "ListNested:")) blk3: {
                    // Handle "ListNested:inner_type.method" for nested list dispatch
                    const after_prefix = cb.name["ListNested:".len..];
                    const dot_idx = std.mem.findScalar(u8, after_prefix, '.') orelse return error.EmitFailed;
                    const inner_type_name = after_prefix[0..dot_idx];
                    const method_name = after_prefix[dot_idx + 1 ..];
                    const inner_type_ref = try self.emitRequiredEncodedContainerElementTypeRef(inner_type_name);
                    // Build List(inner), call .empty(), @TypeOf for the pointer type
                    const inner_args = [_]u32{inner_type_ref};
                    const inner_list = try self.emitGenericContainerRef("List", &inner_args);
                    const empty_fn = zir_builder_emit_field_val(self.handle, inner_list, "empty", 5);
                    if (empty_fn == error_ref) return error.EmitFailed;
                    const empty_val = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (empty_val == error_ref) return error.EmitFailed;
                    const elem_type_ref = zir_builder_emit_typeof(self.handle, empty_val);
                    if (elem_type_ref == error_ref) return error.EmitFailed;
                    // Now call List(@TypeOf(empty_val)).method
                    const outer_args = [_]u32{elem_type_ref};
                    const outer_list = try self.emitGenericContainerRef("List", &outer_args);
                    const fn_ref = zir_builder_emit_field_val(self.handle, outer_list, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                    break :blk3 true;
                } else if (std.mem.startsWith(u8, cb.name, "MapNested:")) blk4: {
                    // Handle "MapNested:keytype:valtype.method" for nested map dispatch
                    const after_prefix = cb.name["MapNested:".len..];
                    const colon_idx = std.mem.findScalar(u8, after_prefix, ':') orelse return error.EmitFailed;
                    const key_type_name = after_prefix[0..colon_idx];
                    const rest = after_prefix[colon_idx + 1 ..];
                    const dot_idx = std.mem.findScalar(u8, rest, '.') orelse return error.EmitFailed;
                    const val_type_name = rest[0..dot_idx];
                    const method_name = rest[dot_idx + 1 ..];
                    if (!self.encodedContainerElementNameIsKnown(key_type_name)) return error.EmitFailed;
                    if (!(std.mem.eql(u8, val_type_name, "map") or std.mem.eql(u8, val_type_name, "list"))) {
                        return error.EmitFailed;
                    }
                    const helper_name = mapBridgeMethodToHelper("Map", method_name) orelse return error.EmitFailed;
                    const fn_ref = try self.emitRuntimeHelper(helper_name);
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(cb.dest, ref);
                    break :blk4 true;
                } else false;

                if (!generic_handled) {
                    // Parse "Struct.function" from the builtin name.
                    // e.g., "IO.println" → import zap_runtime, field "IO",
                    // field "println". Struct names map 1:1 to runtime
                    // struct names; List/Map need element-type instantiation.
                    if (std.mem.findScalar(u8, cb.name, '.')) |dot_idx| {
                        const mod_name = cb.name[0..dot_idx];
                        const func_name = cb.name[dot_idx + 1 ..];

                        const runtime_mod = mod_name;

                        // Generic container structs (List, Map): when the call
                        // name carries no concrete element-type encoding (which
                        // is the case for the bridge `:zig.Map.get(map, ...)`
                        // body inside `lib/map.zap` — `map` has parametric
                        // `%{K=>V}`), route through the runtime's type-derived
                        // dispatch helpers (`mapGet`, `listGetHead`, etc).
                        // These take `anytype` collections and reconstruct the
                        // monomorphic `Map(K, V)` / `List(T)` type via
                        // `@TypeOf`, so the actual runtime type — including
                        // `Map(u32, Term)` — is preserved.
                        const is_generic_container = std.mem.eql(u8, mod_name, "List") or std.mem.eql(u8, mod_name, "Map");
                        if (std.mem.eql(u8, mod_name, "ProcessRuntime") and std.mem.eql(u8, func_name, "receive_message")) {
                            // The GENERIC deep-copy receive. `macro.zig` routes
                            // every non-fixed-scalar `receive`/`receive_raw`
                            // here as `(:zig.ProcessRuntime.receive_message() ::
                            // T)`; monomorphize the walker decode
                            // `ProcessRuntime.receiveMessage(T)` on the message
                            // type reconstructed from the annotated result type
                            // (the same return-type-directed reconstruction the
                            // `List.new_empty` case below uses). This is how a
                            // rich `receive List(i64)` / `receive String` /
                            // `receive %Foo{}` — and, as their u32 atom id,
                            // `Atom`/a payload-free union — decode without a
                            // per-type named primitive. There is no Zig
                            // `receive_message`; this intercept is the ONLY
                            // lowering of that intrinsic name.
                            const message_type_ref = (try self.emitContainerElementTypeRef(cb.result_type)) orelse
                                return error.EmitFailed;
                            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                            if (rt_import == error_ref) return error.EmitFailed;
                            const proc_runtime = zir_builder_emit_field_val(self.handle, rt_import, "ProcessRuntime", 14);
                            if (proc_runtime == error_ref) return error.EmitFailed;
                            const receive_fn = zir_builder_emit_field_val(self.handle, proc_runtime, "receiveMessage", 14);
                            if (receive_fn == error_ref) return error.EmitFailed;
                            const type_args = [_]u32{message_type_ref};
                            const ref = zir_builder_emit_call_ref(self.handle, receive_fn, &type_args, 1);
                            if (ref == error_ref) return error.EmitFailed;
                            try self.setLocal(cb.dest, ref);
                        } else if (is_generic_container) {
                            if (std.mem.eql(u8, mod_name, "List") and
                                (std.mem.eql(u8, func_name, "new_empty") or std.mem.eql(u8, func_name, "new_filled")))
                            {
                                const result_type = if (std.meta.activeTag(cb.result_type) == .list)
                                    cb.result_type
                                else if (std.meta.activeTag(self.current_function_return_type) == .list)
                                    self.current_function_return_type
                                else
                                    ir.ZigType.any;
                                if (std.meta.activeTag(result_type) != .list) return error.EmitFailed;
                                const element_type = getListElementType(result_type);
                                const list_cell = try self.emitListCellRef(element_type);
                                const fn_ref = zir_builder_emit_field_val(self.handle, list_cell, func_name.ptr, @intCast(func_name.len));
                                if (fn_ref == error_ref) return error.EmitFailed;

                                var dispatched_args = args.items;
                                var wrapped_buf: [8]u32 = undefined;
                                if (std.meta.activeTag(element_type) == .term and
                                    std.mem.eql(u8, func_name, "new_filled") and
                                    args.items.len <= wrapped_buf.len and
                                    args.items.len >= 2)
                                {
                                    @memcpy(wrapped_buf[0..args.items.len], args.items);
                                    wrapped_buf[1] = try self.emitTermWrap(wrapped_buf[1]);
                                    dispatched_args = wrapped_buf[0..args.items.len];
                                }

                                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, dispatched_args.ptr, @intCast(dispatched_args.len));
                                if (ref == error_ref) return error.EmitFailed;
                                try self.setLocal(cb.dest, ref);
                            } else {
                                const helper_name = mapBridgeMethodToHelper(mod_name, func_name) orelse {
                                    // Fall back to the old default (Map(atom,i64) /
                                    // List(i64)) for methods without a type-derived
                                    // helper — these are typically methods that do
                                    // not depend on the element type (e.g. legacy
                                    // utility functions). The set covered by
                                    // `mapBridgeMethodToHelper` includes every
                                    // method exposed via `lib/map.zap` and
                                    // `lib/list.zap`, so reaching this branch means
                                    // a new Zap-side bridge was added without a
                                    // matching helper — surface the omission rather
                                    // than silently miscompiling.
                                    return error.EmitFailed;
                                };
                                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                                if (rt_import == error_ref) return error.EmitFailed;
                                const fn_ref = zir_builder_emit_field_val(self.handle, rt_import, helper_name.ptr, @intCast(helper_name.len));
                                if (fn_ref == error_ref) return error.EmitFailed;
                                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                                if (ref == error_ref) return error.EmitFailed;
                                try self.setLocal(cb.dest, ref);
                            }
                        } else if (self.findStructDef(runtime_mod) != null and !self.currentStructMatches(runtime_mod)) {
                            // `runtime_mod` names a user-defined struct (not a
                            // runtime module) AND the call crosses out of the
                            // struct currently being emitted. This reaches the
                            // `call_builtin` path when a protocol-method call
                            // on a concrete receiver — e.g. `Error.message(e)`
                            // where `e :: TimeoutError` — was devirtualized to
                            // the concrete impl `TimeoutError.message`, but the
                            // method's owning module is a separate per-struct
                            // emission (the `impl Error for TimeoutError`
                            // methods live in `TimeoutError`'s own ZIR file,
                            // not the caller's). Routing through
                            // `@import("zap_runtime").TimeoutError.message`
                            // fails Sema with `zap_runtime has no member named
                            // TimeoutError` because the runtime namespace owns
                            // no user types. Reach the method on its real
                            // module via the file-IS-struct import, exactly as
                            // a regular cross-struct call would.
                            //
                            // The `!currentStructMatches` guard is essential:
                            // a struct's OWN `:zig.<Self>.method` body bridge
                            // (e.g. `lib/range.zap`'s `:zig.Range.reverse`
                            // inside `Range`, or `:zig.Atom.to_string` inside
                            // `Atom`) targets the RUNTIME implementation, not
                            // the Zap module — and emitting `@import("Range")`
                            // from within `Range`'s own emission would be an
                            // illegal self-import (`no module named 'Range'
                            // within module 'Range'`). Those self-bridges keep
                            // the runtime path below.
                            const ref = try self.emitCrossStructCall(runtime_mod, func_name, args.items);
                            if (ref == error_ref) return error.EmitFailed;
                            try self.setLocal(cb.dest, ref);
                        } else {
                            const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                            if (rt_import == error_ref) return error.EmitFailed;
                            const mod_ref = zir_builder_emit_field_val(self.handle, rt_import, runtime_mod.ptr, @intCast(runtime_mod.len));
                            if (mod_ref == error_ref) return error.EmitFailed;

                            const fn_ref = zir_builder_emit_field_val(self.handle, mod_ref, func_name.ptr, @intCast(func_name.len));
                            if (fn_ref == error_ref) return error.EmitFailed;

                            const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                            if (ref == error_ref) return error.EmitFailed;
                            try self.setLocal(cb.dest, ref);
                        }
                    } else {
                        // Bare name (no struct qualifier) — route through Kernel.
                        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                        if (rt_import == error_ref) return error.EmitFailed;
                        const kernel = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.kernel);
                        if (kernel == error_ref) return error.EmitFailed;
                        const fn_ref = zir_builder_emit_field_val(self.handle, kernel, cb.name.ptr, @intCast(cb.name.len));
                        if (fn_ref == error_ref) return error.EmitFailed;
                        const ref = zir_builder_emit_call_ref(self.handle, fn_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cb.dest, ref);
                    }
                } // end if (!generic_handled)
            },

            // Tail calls — two strategies, picked at function-emission time:
            //
            //   * Default (TCO-safe params/return): emit a `musttail
            //     call + ret`. LLVM reuses the current stack frame.
            //   * Loopification (`Function.loopify == true`): store
            //     each new arg into the matching `loopify_slots` slot
            //     and emit `repeat` to jump back to the wrapping loop
            //     header. This sidesteps LLVM's `musttail` legality
            //     check (which rejects byref signatures on fastcc-bound
            //     argument shapes) and gives byref state bounded-stack
            //     recursion.
            .tail_call => |tc| {
                if (self.loopify_slots) |slots| {
                    var arg_refs: std.ArrayListUnmanaged(u32) = .empty;
                    defer arg_refs.deinit(self.allocator);
                    for (tc.args) |arg| {
                        const ref = try self.refForValueLocal(arg);
                        try arg_refs.append(self.allocator, ref);
                    }
                    // Commit the new arg values into their slots. The
                    // wrapping `loop` block re-iterates implicitly when
                    // its body falls through without breaking out, so
                    // we don't emit an explicit `repeat` here — Sema's
                    // ZIR `repeat` only resolves against the immediate
                    // body of `loop`, and these stores live inside a
                    // cond_br branch (case body of a switch_return /
                    // optional_dispatch). Letting the if-else's normal
                    // `break_inline` carry control back out of the
                    // branch gives Sema an "unfinished" body, which it
                    // turns into the loop back-edge.
                    for (arg_refs.items, 0..) |arg_ref, i| {
                        if (i >= slots.len) break;
                        if (zir_builder_emit_store(self.handle, slots[i], arg_ref) != 0)
                            return error.EmitFailed;
                    }
                    return;
                }

                // Guaranteed tail call: set always_tail modifier (4) so LLVM
                // emits a tail call that reuses the current stack frame.
                // Tail calls are always intra-struct (self-recursion).
                zir_builder_set_call_modifier(self.handle, 4); // always_tail
                var args: std.ArrayListUnmanaged(u32) = .empty;
                defer args.deinit(self.allocator);
                for (tc.args) |arg| {
                    const ref = try self.refForValueLocal(arg);
                    try args.append(self.allocator, ref);
                }
                const tail_name = if (self.current_emit_struct != null)
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
                    const selected_func = if (cd.clause_index) |clause_index|
                        self.findFunctionBySourceClause(cd.function, clause_index)
                    else
                        self.findFunctionById(cd.function);
                    // Look up function by ID, not array index (IDs may not match indices
                    // because __try variants and default wrappers are inserted into the list)
                    const func_name = blk: {
                        if (selected_func) |func| break :blk func.name;
                        for (prog.functions) |f| {
                            if (f.id == cd.function) break :blk f.name;
                        }
                        break :blk @as(?[]const u8, null);
                    };
                    if (func_name) |fname| {
                        var args: std.ArrayListUnmanaged(u32) = .empty;
                        defer args.deinit(self.allocator);
                        for (cd.args) |arg| {
                            const ref = try self.refForValueLocal(arg);
                            try args.append(self.allocator, ref);
                        }

                        {
                            const target_func = selected_func orelse self.findFunctionById(cd.function);
                            const target_struct = if (target_func) |tf| tf.struct_name else null;
                            const is_cross = xmod: {
                                if (target_struct == null and self.current_emit_struct == null) break :xmod false;
                                if (target_struct == null or self.current_emit_struct == null) break :xmod true;
                                break :xmod !std.mem.eql(u8, target_struct.?, self.current_emit_struct.?);
                            };

                            if (is_cross and target_struct != null) {
                                const target_local = if (target_func) |tf| tf.local_name else fname;
                                const ref = try self.emitCrossStructCall(target_struct.?, target_local, args.items);
                                try self.setLocal(cd.dest, ref);
                            } else {
                                const call_name = if (self.current_emit_struct != null)
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
                                if (ref == error_ref) return error.EmitFailed;
                                try self.setLocal(cd.dest, ref);
                            }
                        }
                    } else {
                        std.log.err("ZIR emit failed resolving call_direct target function id {d}", .{cd.function});
                        return error.EmitFailed;
                    }
                } else {
                    std.log.err("ZIR emit failed resolving call_direct target function id {d}: no program context", .{cd.function});
                    return error.EmitFailed;
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
                if (!zir_builder_emit_set_runtime_safety(self.handle, ref)) return error.EmitFailed;
            },
            // Phase 0 — DWARF foundation: emit a ZIR `dbg_stmt` at every
            // Zap statement boundary, carrying the Zap source line and
            // column. The Zig fork's Sema lowers this into a DWARF line
            // entry, which is what lldb/gdb/addr2line/perf/samply read
            // when mapping a machine address back to source. The IR
            // payload uses zero-based coordinates (Zap's `SourceSpan`
            // convention); the fork's `addDbgStmt` expects one-based
            // values to match the DWARF standard, so we add one in the
            // single canonical conversion site here. Skip emission when
            // either coordinate is zero (the IR builder uses 0,0 as a
            // synthetic-statement sentinel for IR nodes that did not
            // originate from user source — emitting them would point
            // the debugger at the file header).
            .dbg_stmt => |ds| {
                if (ds.line == 0 and ds.column == 0) return;
                // Pass zero-based coordinates through unchanged: the fork's
                // LLVM backend (FuncGen.airDbgStmt) computes the final
                // DWARF line as `base_line + dbg_stmt.line + 1`. Zap
                // currently leaves `base_line = 0` for every function
                // (the `pub_const_simple` declaration's `src_line` flag
                // is hard-zeroed in the ZIR builder), so the +1 there
                // alone produces the one-based DWARF coordinate the
                // standard requires.
                if (zir_builder_emit_dbg_stmt(self.handle, ds.line, ds.column) != 0) {
                    return error.EmitFailed;
                }
            },
            // Phase 0 — DWARF foundation: emit a ZIR `dbg_var_val` (or
            // `dbg_var_ptr`) carrying the Zap source identifier for a
            // named local binding. The fork's Sema preserves the name
            // into AIR `dbg_var_*`, which the LLVM backend emits as a
            // DWARF `.debug_info` local variable record. Debuggers
            // display this name — `x` instead of synthetic `__local_5`.
            //
            // The binding's runtime value lives in `dv.value`. If the
            // ZIR ref for that local isn't materialized yet (e.g., a
            // local whose value was inlined into a sibling expression
            // and never spilled), we skip emission rather than
            // synthesize a fake ref — DWARF would point at garbage.
            .dbg_var => |dv| {
                // Materialize the operand the same way every other
                // instruction does — `local_refs` may store either a
                // direct inst ref or a deferred decl ref, and the
                // `materializeValueRef` helper handles both.
                if (!self.local_refs.contains(dv.value)) return;
                const operand_ref = try self.refForLocal(dv.value);
                const result = if (dv.is_ptr)
                    zir_builder_emit_dbg_var_ptr(self.handle, dv.name.ptr, @intCast(dv.name.len), operand_ref)
                else
                    zir_builder_emit_dbg_var_val(self.handle, dv.name.ptr, @intCast(dv.name.len), operand_ref);
                if (result != 0) return error.EmitFailed;
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
            .optional_dispatch => |od| {
                try self.emitOptionalDispatch(od);
            },
            .cond_return => |cr| {
                const cond_ref = try self.refForLocal(cr.condition);
                if (cr.value) |val| {
                    const val_ref = try self.refForLocal(val);
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
                // The zero-element tuple `{}` is the canonical
                // `zap_runtime.EmptyTuple` named type, constructed as a
                // typed zero-field struct init `EmptyTuple{}` — NOT the
                // anonymous empty literal `.{}` (`@TypeOf(.{})`), which
                // would not coerce into the named `EmptyTuple` the boxed
                // `Callable` `call` slot / impl param expect. This is the
                // construction-site half of the empty-tuple
                // canonicalization (the type positions are handled in
                // `emitTupleParam` / `mapTupleElementType` /
                // `appendZigTypeForVTable`). A zero-element tuple holds no
                // values, so it never participates in Perceus reuse.
                if (ti.elements.len == 0) {
                    const empty_ty = try self.emitEmptyTupleTypeRef();
                    const ref = zir_builder_emit_struct_init_empty(self.handle, empty_ty);
                    if (ref == error_ref) return error.EmitFailed;
                    _ = self.reuse_backed_tuple_locals.remove(ti.dest);
                    try self.setLocal(ti.dest, ref);
                    return;
                }

                // Build field names ("0", "1", "2", ...) and value refs.
                // When the tuple's component type at index i is `.term`,
                // wrap the value via `Term.from(value)` so heterogeneous
                // tuple slots (e.g. `{Atom, Term}` representing a keyword
                // pair where the value type was promoted to `Term`) accept
                // concrete values like `comptime_int` literals.
                var names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens: std.ArrayListUnmanaged(u32) = .empty;
                defer names_lens.deinit(self.allocator);
                var values: std.ArrayListUnmanaged(u32) = .empty;
                defer values.deinit(self.allocator);
                var index_field_name_batch = try IndexFieldNameBatch.init(self.allocator, ti.elements.len);
                defer index_field_name_batch.deinit();

                for (ti.elements, 0..) |elem, i| {
                    var ref = try self.refForLocal(elem);
                    if (ti.component_types) |comps| {
                        if (i < comps.len and comps[i] == .term) {
                            ref = try self.emitTermWrap(ref);
                        }
                    }
                    const name = index_field_name_batch.get(i);
                    try names_ptrs.append(self.allocator, name.ptr);
                    try names_lens.append(self.allocator, name.len);
                    try values.append(self.allocator, ref);
                }

                // The body-local tuple_decl path is currently unused (no
                // caller populates the legacy tuple_type_stack), so this
                // always falls through to the anonymous init path.
                self.tuple_init_count += 1;
                const body_local_type: u32 = 0;
                if (ti.reuse_token) |token_local| {
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
                    const token_ref = try self.refForLocal(token_local);
                    const ptr_ref = try self.emitReuseAllocCall(type_ref, token_ref);
                    // Store the COMPLETE seed tuple into the reused cell in one
                    // aggregate store rather than element-by-element (IR-ZIRB-2--01,
                    // kept coherent with the struct/union reuse paths). The seed
                    // already carries every element (with `Term`-wrapping
                    // applied above), so this writes them all; it cannot leave
                    // any element holding stale bytes from the dropped value.
                    if (zir_builder_emit_store(self.handle, ptr_ref, seed_ref) != 0) return error.EmitFailed;
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
                const empty_fn = zir_builder_emit_field_val(self.handle, list_cell, "empty", 5);
                if (empty_fn == error_ref) return error.EmitFailed;

                if (li.elements.len == 0) {
                    // Empty list: List.empty() — typed null
                    const ref = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(li.dest, ref);
                } else {
                    // Build left-to-right with List.push so flat-buffer
                    // literals grow linearly instead of repeatedly
                    // copying tails through cons.
                    var current: u32 = zir_builder_emit_call_ref(self.handle, empty_fn, &.{}, 0);
                    if (current == error_ref) return error.EmitFailed;
                    const push_fn = zir_builder_emit_field_val(self.handle, list_cell, "push", 4);
                    if (push_fn == error_ref) return error.EmitFailed;
                    for (li.elements) |element_local| {
                        var elem_ref = try self.refForLocal(element_local);
                        if (li.element_type == .term) {
                            elem_ref = try self.emitTermWrap(elem_ref);
                        }
                        const call_args = [_]u32{ current, elem_ref };
                        current = zir_builder_emit_call_ref(self.handle, push_fn, &call_args, 2);
                        if (current == error_ref) return error.EmitFailed;
                    }
                    try self.setLocal(li.dest, current);
                }
            },
            .list_cons => |lc| {
                var head_ref = try self.refForLocal(lc.head);
                const tail_ref = try self.refForLocal(lc.tail);
                if (lc.element_type == .term) {
                    head_ref = try self.emitTermWrap(head_ref);
                }
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
                const key_type_ref = (try self.emitContainerElementTypeRef(mi.key_type)) orelse return error.EmitFailed;
                const val_type_ref = (try self.emitContainerElementTypeRef(mi.value_type)) orelse return error.EmitFailed;
                const map_type_args = [_]u32{ key_type_ref, val_type_ref };
                const map_cell = try self.emitGenericContainerRef("Map", &map_type_args);

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
                        var key_ref = try self.refForLocal(entry.key);
                        var val_ref = try self.refForLocal(entry.value);
                        // When the map's value/key type was promoted to
                        // `Term`, wrap each concrete value at the call site
                        // so `Map.put(_, K, Term)` accepts it.
                        if (mi.value_type == .term) {
                            val_ref = try self.emitTermWrap(val_ref);
                        }
                        if (mi.key_type == .term) {
                            key_ref = try self.emitTermWrap(key_ref);
                        }
                        const call_args = [_]u32{ current, key_ref, val_ref };
                        current = zir_builder_emit_call_ref(self.handle, put_fn, &call_args, 3);
                        if (current == error_ref) return error.EmitFailed;
                    }
                    try self.setLocal(mi.dest, current);
                }
            },
            .struct_init => |si| {
                var names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                defer names_ptrs.deinit(self.allocator);
                var names_lens: std.ArrayListUnmanaged(u32) = .empty;
                defer names_lens.deinit(self.allocator);
                var values: std.ArrayListUnmanaged(u32) = .empty;
                defer values.deinit(self.allocator);

                // Look up the struct def once so we can wrap values
                // for indirect-storage fields (recursive types).
                const si_struct_def = self.findStructDef(si.type_name);

                for (si.fields) |field| {
                    var ref = try self.refForValueLocal(field.value);
                    // Indirect-storage fields (self-referential
                    // recursive types) are laid out as `?*const T`.
                    // Promote a non-null `T` value to a heap-
                    // allocated `*const T` so Zig coerces it into the
                    // optional pointer slot. `null_value` passes
                    // through — Zig handles the nil-to-?*const T
                    // coercion natively.
                    //
                    // Skip the promote when the field's source type
                    // is itself a recursive struct: under the boxing
                    // ABI, recursive-typed expressions (param-get,
                    // call-return, prior `%T{}` site) already produce
                    // a `*const T` Ref. A second `allocAny` on top of
                    // that pointer would store the pointer-to-pointer
                    // into the field, breaking subsequent loads.
                    if (si_struct_def) |sdef| {
                        const def_field = findFieldDef(sdef, field.name);
                        if (def_field != null and def_field.?.storage == .indirect and
                            ref != @intFromEnum(Zir.Inst.Ref.null_value) and
                            !self.zigTypeIsRecursiveStruct(def_field.?.type_expr))
                        {
                            ref = try self.heapPromoteForIndirectField(ref);
                        }
                    }
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
                                        if (ref == error_ref) return error.EmitFailed;
                                        break :blk ref;
                                    },
                                    .bool_val => |v| if (v) @intFromEnum(Zir.Inst.Ref.bool_true) else @intFromEnum(Zir.Inst.Ref.bool_false),
                                    .float => |v| blk: {
                                        const ref = zir_builder_emit_float(self.handle, v);
                                        if (ref == error_ref) return error.EmitFailed;
                                        break :blk ref;
                                    },
                                    .string => |v| blk: {
                                        const ref = zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len));
                                        if (ref == error_ref) return error.EmitFailed;
                                        break :blk ref;
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

                // A zero-field struct construction `%T{}` (a non-capturing
                // closure's `__closure_N` has NO capture fields) must lower
                // to `struct_init_empty`, NOT a zero-field `struct_init`:
                // Sema's `zirStructInit` indexes the first (absent) field to
                // read its type and panics on an empty field list. The
                // dedicated `struct_init_empty` resolves the operand as the
                // result type and yields an empty value of it. (Same fork
                // primitive used for `zap_runtime.EmptyTuple{}`.) Typed to
                // the struct so the boxed `Callable` `data_ptr` carries the
                // correct nominal `__closure_N` identity. Closures can't
                // resolve struct-level `decl_val` refs from inside their own
                // environment, so an empty struct built INSIDE a closure body
                // (a nested non-capturing closure) falls back to the anon
                // empty struct.
                if (values.items.len == 0) {
                    const empty_struct = blk: {
                        if (!self.current_function_is_closure) {
                            if (self.findStructDef(si.type_name) != null) {
                                const type_ref = try self.emitStructTypeRef(si.type_name);
                                const typed = zir_builder_emit_struct_init_empty(self.handle, type_ref);
                                if (typed == error_ref) return error.EmitFailed;
                                break :blk typed;
                            }
                        }
                        const anon = zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, 0);
                        break :blk anon;
                    };
                    if (empty_struct == error_ref) return error.EmitFailed;
                    if (si.reuse_token) |_| _ = self.reuse_backed_struct_locals.remove(si.dest);
                    if (self.isRecursiveStruct(si.type_name)) {
                        const ptr_ref = try self.heapPromoteForIndirectField(empty_struct);
                        try self.setLocal(si.dest, ptr_ref);
                    } else {
                        try self.setLocal(si.dest, empty_struct);
                    }
                    return;
                }

                if (si.reuse_token) |token_local| {
                    // Use struct_init_typed for named structs to preserve
                    // type identity. The `current_function_is_closure` guard
                    // stays — closures can't resolve struct-level decl_val
                    // refs from inside their environment. The
                    // `capture_depth == 0` band-aid was needed when
                    // `addStructInitTyped` emitted `struct_init_field_type`
                    // outside the captured body's instruction list; now
                    // that the Zig fork's `addStructInitTyped` body-tracks
                    // those instructions, captured contexts (multi-clause
                    // dispatch arms, guard blocks) preserve nominal
                    // identity through `struct_init_typed`.
                    const seed_ref = blk: {
                        if (!self.current_function_is_closure) {
                            if (self.findStructDef(si.type_name) != null) {
                                const type_ref = try self.emitStructTypeRef(si.type_name);
                                const typed = zir_builder_emit_struct_init_typed(self.handle, type_ref, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                                if (typed == error_ref) return error.EmitFailed;
                                break :blk typed;
                            }
                        }
                        break :blk zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                    };
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    const token_ref = try self.refForLocal(token_local);
                    const ptr_ref = try self.emitReuseAllocCall(type_ref, token_ref);
                    // Store the COMPLETE seed value into the reused cell, not a
                    // hand-picked subset of fields (IR-ZIRB-2--01). The seed
                    // already carries every field — explicit values with
                    // indirect-storage heap promotion applied, plus
                    // default-filled omitted fields — so a single aggregate
                    // store writes them all correctly. The previous per-field
                    // loop iterated `si.fields` (the raw, un-promoted,
                    // possibly-incomplete instruction field list), which left
                    // defaulted fields holding stale bytes from the dropped
                    // object and stored un-promoted values into
                    // indirect-storage (`?*const T`) recursive-field slots.
                    // The whole-value store is also self-contained: it cannot
                    // reintroduce stale memory even if a future IR pass
                    // synthesizes an incomplete `struct_init` paired with a
                    // reuse token. Finding 1 guarantees the reused cell is
                    // large enough for the type, so this store never overflows.
                    if (zir_builder_emit_store(self.handle, ptr_ref, seed_ref) != 0) return error.EmitFailed;
                    try self.markReuseBackedStructLocal(si.dest, si.type_name);
                    try self.setLocal(si.dest, ptr_ref);
                } else if (self.shouldSkipArc(si.dest) and !self.isRecursiveStruct(si.type_name)) {
                    // Stack allocation path: escape analysis determined this value
                    // does not escape the current function AND the type is not
                    // recursive. Recursive struct values participate in the boxing
                    // ABI (every parameter, return, and field expects `*const T`),
                    // so even a non-escaping construction must be heap-promoted —
                    // a stack-allocated struct can't be passed where the call
                    // boundary needs an Arc-backed pointer with a refcount header.
                    _ = self.reuse_backed_struct_locals.remove(si.dest);
                    // See note above the reuse-pair branch — same fix:
                    // the `capture_depth == 0` band-aid is no longer
                    // necessary now that `struct_init_field_type` is
                    // body-tracked in the Zig fork.
                    const seed_ref = blk: {
                        if (!self.current_function_is_closure) {
                            if (self.findStructDef(si.type_name) != null) {
                                const type_ref = try self.emitStructTypeRef(si.type_name);
                                const typed = zir_builder_emit_struct_init_typed(self.handle, type_ref, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                                if (typed == error_ref) return error.EmitFailed;
                                break :blk typed;
                            }
                        }
                        break :blk zir_builder_emit_struct_init_anon(self.handle, names_ptrs.items.ptr, names_lens.items.ptr, values.items.ptr, @intCast(values.items.len));
                    };
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    // Allocate on stack and store
                    const alloc_ref = try self.emitAlloc(type_ref);
                    if (zir_builder_emit_store(self.handle, alloc_ref, seed_ref) != 0) return error.EmitFailed;
                    const const_ptr = try self.emitMakePtrConst(alloc_ref);
                    const loaded = try self.emitLoad(const_ptr);
                    try self.setLocal(si.dest, loaded);
                } else {
                    _ = self.reuse_backed_struct_locals.remove(si.dest);

                    // Use struct_init_typed with decl_val for nominal types
                    // in non-closure functions. Closures can't resolve struct-
                    // level decl_val refs, so fall back to struct_init_anon.
                    // The `capture_depth == 0` guard from the historical
                    // workaround is dropped: now that the Zig fork's
                    // `addStructInitTyped` body-tracks each
                    // `struct_init_field_type`, struct_init_typed is
                    // safe inside captured guard-block bodies.
                    var struct_value: u32 = error_ref;
                    if (!self.current_function_is_closure) {
                        if (self.findStructDef(si.type_name) != null) {
                            const type_ref = try self.emitStructTypeRef(si.type_name);
                            struct_value = zir_builder_emit_struct_init_typed(
                                self.handle,
                                type_ref,
                                names_ptrs.items.ptr,
                                names_lens.items.ptr,
                                values.items.ptr,
                                @intCast(values.items.len),
                            );
                            if (struct_value == error_ref) return error.EmitFailed;
                        }
                    }
                    if (struct_value == error_ref) {
                        struct_value = zir_builder_emit_struct_init_anon(
                            self.handle,
                            names_ptrs.items.ptr,
                            names_lens.items.ptr,
                            values.items.ptr,
                            @intCast(values.items.len),
                        );
                        if (struct_value == error_ref) return error.EmitFailed;
                    }

                    // Recursive structs are boxed at every cross-boundary
                    // position (params, returns, field storage of the same
                    // recursion class). The construction site must therefore
                    // heap-promote the freshly built value so the dest local
                    // holds `*const T`, not `T`. Without this promotion the
                    // struct flows out as a value Ref and downstream coercions
                    // to `*const T` (function calls, returns, field stores)
                    // emit invalid ZIR.
                    if (self.isRecursiveStruct(si.type_name)) {
                        const ptr_ref = try self.heapPromoteForIndirectField(struct_value);
                        try self.setLocal(si.dest, ptr_ref);
                    } else {
                        try self.setLocal(si.dest, struct_value);
                    }
                }
            },
            .field_get => |fg| {
                const obj_ref = try self.refForLocal(fg.object);
                var ref = zir_builder_emit_field_val(self.handle, obj_ref, fg.field.ptr, @intCast(fg.field.len));
                if (ref == error_ref) return error.EmitFailed;
                // Indirect-storage fields (self-referential recursive types)
                // are laid out as `*const T` or `?*const T`. Source-level the
                // user observes `T` / `?T`. Auto-deref so downstream code
                // operates on the source-level value and the storage shape
                // remains an implementation detail.
                if (fg.struct_type) |sname| {
                    if (self.findStructDef(sname)) |sdef| {
                        if (findFieldDef(sdef, fg.field)) |fdef| {
                            if (fdef.storage == .indirect) {
                                // Auto-deref the storage shape: source-level
                                // the user observes `T`/`?T`; storage-level
                                // we hold `*const T` / `?*const T`. Emitting
                                // the deref here keeps the storage indirection
                                // an implementation detail.
                                ref = try self.emitIndirectFieldDeref(ref, fdef.type_expr);
                                // Phase 1 Class A — the boxed-recursive
                                // retain that previously fired here as a
                                // direct `retainAnyOpt` ZIR call now lives
                                // at the IR level. The IR builder's
                                // `extract_struct` decision-tree arms (in
                                // `lowerDecisionTreeForCase` and
                                // `lowerDecisionTreeForDispatch`, plus the
                                // top-level `.field_get` arm in `lowerExpr`)
                                // emit an explicit `.retain` IR after the
                                // `.field_get`, which lowers via the canonical
                                // `.retain` handler below to `retainAny`.
                                // `retainAny` already handles optional pointers
                                // (`runtime.zig:1538-1554` unwraps optionals),
                                // so the previous `retainAnyOpt` specialization
                                // is unnecessary.
                                //
                                // The destructive-scrutinee retain-elision
                                // optimization (skip the retain when the parent
                                // is being destructively consumed) is not yet
                                // re-implemented at the IR level. The current
                                // behavior is correctness-preserving over-
                                // retain, paired with the matching scope-exit
                                // `.release` from `arc_drop_insertion`. A
                                // future arc_optimizer pass can elide the
                                // pair when destructive_scrutinee_locals
                                // proves the consumer owns the +1.
                            }
                        }
                    }
                }
                try self.setLocal(fg.dest, ref);
            },
            .field_set => |fs| {
                const obj_ref = try self.refForLocal(fs.object);
                const val_ref = try self.refForLocal(fs.value);
                const ptr = zir_builder_emit_field_ptr(self.handle, obj_ref, fs.field.ptr, @intCast(fs.field.len));
                if (ptr == error_ref) return error.EmitFailed;
                if (zir_builder_emit_store(self.handle, ptr, val_ref) != 0) return error.EmitFailed;
            },
            .index_get => |ig| {
                // Tuple/array element access by immediate index. When
                // `coerce_term_to` is set, the slot's runtime value MAY be
                // a `Term` (heterogeneous keyword list) or already the
                // declared concrete type (homogeneous case). The runtime
                // helper `coerceFromMaybeTerm(value, default)` handles
                // both via a comptime check on `@TypeOf(value)` so the
                // emitted code stays correct under either monomorphisation.
                const obj_ref = try self.refForLocal(ig.object);
                var ref = zir_builder_emit_elem_val_imm(self.handle, obj_ref, ig.index);
                if (ref == error_ref) return error.EmitFailed;
                if (ig.coerce_term_to != .any) {
                    const default_ref = try self.emitZeroDefaultForType(ig.coerce_term_to);
                    if (default_ref == error_ref) return error.EmitFailed;
                    const helper_fn = try self.emitRuntimeHelper("coerceFromMaybeTerm");
                    const args = [_]u32{ ref, default_ref };
                    const coerced = zir_builder_emit_call_ref(self.handle, helper_fn, &args, 2);
                    if (coerced == error_ref) return error.EmitFailed;
                    ref = coerced;
                }
                try self.setLocal(ig.dest, ref);
            },
            .list_len_check => |llc| {
                // Cons-cell length check. When `via_helper` is set, dispatch
                // through `listLength(anytype)` so the runtime element type
                // is honored even if the declared element type differs.
                const list_ref = try self.refForLocal(llc.scrutinee);
                const len_ref = if (llc.via_helper) blk: {
                    const helper_fn = try self.emitRuntimeHelper("listLength");
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, helper_fn, &call_args, 1);
                } else blk: {
                    const list_cell = try self.emitListCellRef(llc.element_type);
                    const len_fn = zir_builder_emit_field_val(self.handle, list_cell, "length", 6);
                    if (len_fn == error_ref) return error.EmitFailed;
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, len_fn, &call_args, 1);
                };
                if (len_ref == error_ref) return error.EmitFailed;
                const expected_ref = zir_builder_emit_int(self.handle, @intCast(llc.expected_len));
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag: u8 = @intFromEnum(if (llc.minimum) Zir.Inst.Tag.cmp_gte else Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, len_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(llc.dest, ref);
            },
            .list_get => |lg| {
                // List-based element access. When the list is param-backed
                // the runtime element type may differ from the declared one
                // (heterogeneous keyword lists), so route through the
                // `listGet(anytype, index)` helper which derives the actual
                // type from `@TypeOf(list)`.
                const list_ref = try self.refForLocal(lg.list);
                const index_ref = zir_builder_emit_int(self.handle, @intCast(lg.index));
                if (index_ref == error_ref) return error.EmitFailed;
                const ref = if (lg.via_helper) blk: {
                    const helper_fn = try self.emitRuntimeHelper("listGet");
                    const call_args = [_]u32{ list_ref, index_ref };
                    break :blk zir_builder_emit_call_ref(self.handle, helper_fn, &call_args, 2);
                } else blk: {
                    const list_cell = try self.emitListCellRef(lg.element_type);
                    const get_fn = zir_builder_emit_field_val(self.handle, list_cell, "get", 3);
                    if (get_fn == error_ref) return error.EmitFailed;
                    const call_args = [_]u32{ list_ref, index_ref };
                    break :blk zir_builder_emit_call_ref(self.handle, get_fn, &call_args, 2);
                };
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lg.dest, ref);
            },
            .list_is_not_empty => |lne| {
                // Flat List non-empty check: length(list) != 0.
                // Allocated zero-length buffers from List.new_empty are
                // non-null but still empty.
                const list_ref = try self.refForValueLocal(lne.list);
                const len_ref = if (lne.via_helper) blk: {
                    const helper_fn = try self.emitRuntimeHelper("listLength");
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, helper_fn, &call_args, 1);
                } else blk: {
                    const list_cell = try self.emitListCellRef(lne.element_type);
                    const len_fn = zir_builder_emit_field_val(self.handle, list_cell, "length", 6);
                    if (len_fn == error_ref) return error.EmitFailed;
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, len_fn, &call_args, 1);
                };
                if (len_ref == error_ref) return error.EmitFailed;
                const zero_ref = zir_builder_emit_int(self.handle, 0);
                if (zero_ref == error_ref) return error.EmitFailed;
                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_neq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, len_ref, zero_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lne.dest, ref);
            },
            .list_head => |lh| {
                // List head extraction. When `via_helper` is set, dispatch
                // through `listGetHead(anytype)` so the head's runtime type
                // is read from `@TypeOf(list)` instead of the declared one.
                const list_ref = try self.refForValueLocal(lh.list);
                const ref = if (lh.via_helper) blk: {
                    const helper_fn = try self.emitRuntimeHelper("listGetHead");
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, helper_fn, &call_args, 1);
                } else blk: {
                    const list_cell = try self.emitListCellRef(lh.element_type);
                    const fn_ref = zir_builder_emit_field_val(self.handle, list_cell, "getHead", 7);
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const call_args = [_]u32{list_ref};
                    break :blk zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 1);
                };
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lh.dest, ref);
            },
            .list_tail => |lt| {
                // List suffix extraction. Multi-head rest patterns set
                // `start_index` above one so the rest is materialized by
                // one indexed slice instead of chained tail clones.
                const list_ref = try self.refForValueLocal(lt.list);
                const start_ref = zir_builder_emit_int(self.handle, @intCast(lt.start_index));
                if (start_ref == error_ref) return error.EmitFailed;
                const ref = if (lt.via_helper) blk: {
                    const helper_fn = try self.emitRuntimeHelper(if (lt.consume_source)
                        "listSliceOwnedUnchecked"
                    else
                        "listSliceFrom");
                    const call_args = [_]u32{ list_ref, start_ref };
                    break :blk zir_builder_emit_call_ref(self.handle, helper_fn, &call_args, 2);
                } else blk: {
                    const list_cell = try self.emitListCellRef(lt.element_type);
                    const method_name = if (lt.consume_source) "slice_owned_unchecked" else "sliceFrom";
                    const fn_ref = zir_builder_emit_field_val(self.handle, list_cell, method_name.ptr, @intCast(method_name.len));
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const call_args = [_]u32{ list_ref, start_ref };
                    break :blk zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 2);
                };
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(lt.dest, ref);
            },
            .map_has_key => |mhk| {
                // Look up the right `Map(K, V)` cell from the IR's
                // recorded key/value types. The compiler defaults to
                // `.atom`/`.i64` when the IR lacks concrete types,
                // matching pre-existing behaviour for atom-keyed
                // integer maps emitted by older code paths.
                const map_ref = try self.refForLocal(mhk.map);
                const key_ref = try self.refForLocal(mhk.key);
                const map_cell = try self.emitMapCellRef(mhk.key_type, mhk.value_type);
                const fn_ref = zir_builder_emit_field_val(self.handle, map_cell, "hasKey", 6);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ map_ref, key_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mhk.dest, ref);
            },
            .map_get => |mg| {
                // Look up the right `Map(K, V)` cell from the IR's
                // recorded key/value types — the ZIR runtime's `Map`
                // generic is monomorphised per (K, V) pair, so a
                // `Map(u32, []const u8)` cell can't be reused for an
                // atom→int map.
                const map_ref = try self.refForLocal(mg.map);
                const key_ref = try self.refForLocal(mg.key);
                const default_ref = try self.refForLocal(mg.default);
                const map_cell = try self.emitMapCellRef(mg.key_type, mg.value_type);
                const fn_ref = zir_builder_emit_field_val(self.handle, map_cell, "get", 3);
                if (fn_ref == error_ref) return error.EmitFailed;
                const call_args = [_]u32{ map_ref, key_ref, default_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &call_args, 3);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mg.dest, ref);
            },
            .union_init => |ui| {
                // Consistent threading rule (Round 2 Blocker A): the
                // IR's `union_type` field carries the per-instantiation
                // mangled name (e.g. `Option_i64`) populated from HIR's
                // `.applied { base, args }` literal type. Resolve that
                // name to a ZIR union-type ref via the same dispatcher
                // every struct construction uses (`emitStructTypeRef`),
                // then emit `@unionInit(UnionType, ".Variant", value)`.
                //
                // Step 3.6 ensures every parametric union/enum
                // specialization has a synthetic Zig source file, so
                // `emitStructTypeRef` resolves regardless of whether
                // the enclosing function returns the union. Concrete
                // dotted unions (`Owner.Color`) and the
                // `cached_union_ret_type_ref` route stay as fallbacks
                // for the narrow cases the structural pipeline doesn't
                // cover yet (closures that lose the emission context;
                // unit-only enums that flow through enum_literal
                // instead of union_init).
                //
                // Unit-payload variants (e.g. `Option(i64).None`) carry
                // a `const_nil` value local from HIR. Sema expects the
                // payload type of a void variant to be `void`, not
                // `?void` — using `null_value` here would force a
                // `null` → `void` coercion failure. Detect the void-
                // payload case via the IR-emitted `union_def` variant
                // type_name and substitute `void_value` so
                // `@unionInit(Option_i64, "None", {})` lowers cleanly.
                const variant_type_name: ?[]const u8 = blk: {
                    if (self.findUnionDef(ui.union_type)) |udef| {
                        for (udef.variants) |variant| {
                            if (std.mem.eql(u8, variant.name, ui.variant_name)) {
                                break :blk variant.type_name;
                            }
                        }
                    }
                    break :blk null;
                };
                const variant_is_void = variant_type_name != null and std.mem.eql(u8, variant_type_name.?, "void");
                const val_ref = if (variant_is_void)
                    @intFromEnum(Zir.Inst.Ref.void_value)
                else
                    try self.refForValueLocal(ui.value);
                const names = [_][*]const u8{ui.variant_name.ptr};
                const lens = [_]u32{@intCast(ui.variant_name.len)};
                const vals = [_]u32{val_ref};
                if (ui.reuse_token) |token_local| {
                    const seed_ref = blk: {
                        if (!self.current_function_is_closure) {
                            if (self.findUnionDef(ui.union_type) != null) {
                                const union_type_ref = try self.emitStructTypeRef(ui.union_type);
                                const typed = zir_builder_emit_union_init(
                                    self.handle,
                                    union_type_ref,
                                    ui.variant_name.ptr,
                                    @intCast(ui.variant_name.len),
                                    val_ref,
                                );
                                if (typed == error_ref) return error.EmitFailed;
                                break :blk typed;
                            }
                        }
                        break :blk zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                    };
                    if (seed_ref == error_ref) return error.EmitFailed;
                    const type_ref = zir_builder_emit_typeof(self.handle, seed_ref);
                    if (type_ref == error_ref) return error.EmitFailed;
                    const token_ref = try self.refForLocal(token_local);
                    const ptr_ref = try self.emitReuseAllocCall(type_ref, token_ref);
                    // Store the COMPLETE seed union value (discriminant tag AND
                    // payload) into the reused cell (IR-ZIRB-2--01). The
                    // previous code stored ONLY the variant payload field via
                    // `field_ptr` + `store`, never the tag — so reconstructing
                    // a DIFFERENT variant from a reset cell (Perceus pairs any
                    // two variants of the same union) left the stale
                    // discriminant of the input variant, yielding a value that
                    // reads back as the wrong variant. The seed `union_init`
                    // already encodes the correct tag+payload, so one aggregate
                    // store fixes both. Finding 1 guarantees the cell fits.
                    if (zir_builder_emit_store(self.handle, ptr_ref, seed_ref) != 0) return error.EmitFailed;
                    try self.markReuseBackedUnionLocal(ui);
                    try self.setLocal(ui.dest, ptr_ref);
                } else {
                    _ = self.reuse_backed_union_locals.remove(ui.dest);

                    // Primary path: name-resolved union type via the
                    // shared struct/union-type dispatcher.
                    if (!self.current_function_is_closure) {
                        if (self.findUnionDef(ui.union_type) != null) {
                            const union_type_ref = try self.emitStructTypeRef(ui.union_type);
                            const ref = zir_builder_emit_union_init(
                                self.handle,
                                union_type_ref,
                                ui.variant_name.ptr,
                                @intCast(ui.variant_name.len),
                                val_ref,
                            );
                            if (ref == error_ref) return error.EmitFailed;
                            try self.setLocal(ui.dest, ref);
                            return;
                        }
                    }

                    // Fallback 1: function declared a union return type
                    // and Sema can reuse that ref. Preserved for the
                    // narrow case where `findUnionDef` doesn't see the
                    // type (closures, partial emissions).
                    if (self.cached_union_ret_type_ref != 0) {
                        const ref = zir_builder_emit_union_init(
                            self.handle,
                            self.cached_union_ret_type_ref,
                            ui.variant_name.ptr,
                            @intCast(ui.variant_name.len),
                            val_ref,
                        );
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(ui.dest, ref);
                        return;
                    }

                    // Fallback 2: anonymous construction. This is only for
                    // emission contexts that do not have a nominal union
                    // definition or reusable nominal return-type ref.
                    const ref = zir_builder_emit_struct_init_anon(self.handle, &names, &lens, &vals, 1);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(ui.dest, ref);
                }
            },

            // Construction-site auto-boxing for protocol existentials
            // (Phase 1.2.5.c). Lowers `box_as_protocol` as a runtime
            // call to `zap_runtime.ArcRuntime.boxAsProtocol(inner_ptr,
            // vtable_ptr)`, with `inner_ptr` produced by routing the
            // inner value through `heapPromoteForIndirectField` (which
            // expands to `allocAny(@TypeOf(value), allocator, value)`)
            // and `vtable_ptr` produced by taking `&@import("<VTableInstance>").<VTableInstance>`
            // through `emit_field_ptr` on the imported vtable file.
            //
            // Why a single runtime helper rather than inline ZIR struct-
            // init plus two `@ptrCast`s: the runtime helper folds the
            // `?*anyopaque` / `?*const anyopaque` coercions into one
            // comptime-typed Zig function. The ZIR primitives don't
            // expose an anyopaque-pointer type Ref directly, so emitting
            // an inline `.{ .data_ptr = @ptrCast(p), .vtable = @ptrCast(v) }`
            // literal would require a new C-ABI in the fork. The
            // helper-call route stays inside the existing
            // `call_ref(@import("zap_runtime").ArcRuntime.boxAsProtocol,
            // ...)` surface and keeps codegen uniform with `allocAny`.
            //
            // ARC contract: the inner allocation IS the box's owning
            // reference. No additional retain at this site — the
            // box's release through the vtable's `__drop__` slot
            // pairs against the alloc that just happened.
            .box_as_protocol => |bx| {
                const value_ref = try self.refForValueLocal(bx.value);
                const inner_ptr_ref = try self.heapPromoteForIndirectField(value_ref);

                // Take the address of the per-impl vtable instance
                // constant. `field_ptr` on the imported file's
                // namespace yields `&Namespace.<const>`, a
                // `*const <Protocol>VTable` — which `boxAsProtocol`'s
                // `@ptrCast` lowers to `?*const anyopaque`.
                //
                // The synthetic vtable instance file is named after
                // the *instance* constant (`<Protocol>VTable_for_<Target>`)
                // — not the target — so the import target is the
                // instance constant's name, which the IR-side
                // `findProtocolImplVTable` resolves at HIR
                // construction-site detection time.
                const program_ref = if (self.program) |*p| p else return error.EmitFailed;
                const vtable_instance_name = ir.findProtocolImplVTable(
                    program_ref,
                    bx.protocol_name,
                    bx.target_type_name,
                ) orelse {
                    // The HIR construction-site detector is supposed
                    // to catch missing impls before this lowering
                    // runs; reaching here means an upstream invariant
                    // broke. Surface explicitly rather than silently
                    // emitting an `undefined` vtable.
                    return error.EmitFailed;
                };
                const vtable_file_import = zir_builder_emit_import(
                    self.handle,
                    vtable_instance_name.ptr,
                    @intCast(vtable_instance_name.len),
                );
                if (vtable_file_import == error_ref) return error.EmitFailed;
                // Obtain `&<InstanceConst>` via the synthetic
                // `vtable_addr()` helper rather than a `field_ptr` ZIR op.
                // `@import(...)` yields a `type` (the file namespace), and
                // the ZIR `field_ptr` primitive requires a pointer object
                // — emitting `field_ptr(@import(...), <const>)` makes Sema
                // reject the site with `expected pointer, found 'type'`.
                // The helper resolves the address-of inside real Zig
                // source where it is well-formed and returns the erased
                // `?*const anyopaque` the runtime `boxAsProtocol` expects.
                // See `emitProtocolVTableInstanceSourceFile`.
                const vtable_addr_fn = zir_builder_emit_field_val(
                    self.handle,
                    vtable_file_import,
                    "vtable_addr",
                    11,
                );
                if (vtable_addr_fn == error_ref) return error.EmitFailed;
                const vtable_ptr_ref = zir_builder_emit_call_ref(
                    self.handle,
                    vtable_addr_fn,
                    &.{},
                    0,
                );
                if (vtable_ptr_ref == error_ref) return error.EmitFailed;

                // Call `zap_runtime.ArcRuntime.boxAsProtocol(inner_ptr,
                // vtable_ptr)` — the helper does the
                // `?*anyopaque`/`?*const anyopaque` casts and returns
                // the populated `ProtocolBox` value.
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                if (arc_runtime == error_ref) return error.EmitFailed;
                const box_fn = zir_builder_emit_field_val(
                    self.handle,
                    arc_runtime,
                    "boxAsProtocol",
                    13,
                );
                if (box_fn == error_ref) return error.EmitFailed;
                const args = [_]u32{ inner_ptr_ref, vtable_ptr_ref };
                const box_ref = zir_builder_emit_call_ref(self.handle, box_fn, &args, 2);
                if (box_ref == error_ref) return error.EmitFailed;
                try self.setLocal(bx.dest, box_ref);
            },

            // Consumption-site virtual dispatch through a
            // `runtime.ProtocolBox` (Phase 1.2.5.d). Lowers
            // `protocol_dispatch` to a call against the per-protocol
            // synthetic dispatcher helper emitted alongside the
            // `<Protocol>VTable` struct in its synthetic source file:
            //
            //   @import("<Protocol>VTable").dispatch_<method>(box,
            //                                                 arg0, ..., argN)
            //
            // The dispatcher's body (in
            // `emitProtocolVTableSourceFile`) performs the
            // `@ptrCast(@alignCast(box.vtable.?))` recovery, reads the
            // `<method>` slot, and calls the indirect function pointer
            // with `box.data_ptr` as the implicit receiver. Keeping
            // the cast + indirect call inside the synthetic Zig file
            // — rather than reaching for a custom C-ABI ZIR emitter —
            // matches the construction-site lowering style and means
            // every dispatch round-trips through ordinary `call_ref`
            // primitives.
            .protocol_dispatch => |pd| {
                const vtable_module_name = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}VTable",
                    .{pd.protocol_name},
                );
                defer self.allocator.free(vtable_module_name);

                const vtable_import = zir_builder_emit_import(
                    self.handle,
                    vtable_module_name.ptr,
                    @intCast(vtable_module_name.len),
                );
                if (vtable_import == error_ref) return error.EmitFailed;

                const dispatcher_name = try std.fmt.allocPrint(
                    self.allocator,
                    "dispatch_{s}",
                    .{pd.method_name},
                );
                defer self.allocator.free(dispatcher_name);

                const dispatcher_fn = zir_builder_emit_field_val(
                    self.handle,
                    vtable_import,
                    dispatcher_name.ptr,
                    @intCast(dispatcher_name.len),
                );
                if (dispatcher_fn == error_ref) return error.EmitFailed;

                // Assemble the actual argument list: receiver + each
                // non-receiver arg in source order. The dispatcher
                // helper takes the receiver by value and unwraps
                // `box.data_ptr` internally.
                const receiver_ref = try self.refForLocal(pd.receiver);
                var call_args: std.ArrayListUnmanaged(u32) = .empty;
                defer call_args.deinit(self.allocator);
                try call_args.append(self.allocator, receiver_ref);
                for (pd.args) |arg_local| {
                    const arg_ref = try self.refForLocal(arg_local);
                    try call_args.append(self.allocator, arg_ref);
                }

                const result_ref = zir_builder_emit_call_ref(
                    self.handle,
                    dispatcher_fn,
                    call_args.items.ptr,
                    @intCast(call_args.items.len),
                );
                if (result_ref == error_ref) return error.EmitFailed;
                try self.setLocal(pd.dest, result_ref);
            },

            // Consumption-site downcast of a `runtime.ProtocolBox` to
            // a concrete inner type (Phase 1.2.5.d). The pattern-match
            // compiler emits a `guard_block` whose condition calls the
            // per-impl `vtable_eq_<Target>(box) bool` helper; when the
            // guard fires, the arm's body executes the
            // `protocol_box_unbox` lowering here:
            //
            //   const unboxed = @import("<Protocol>VTable_for_<Target>")
            //                      .unbox(box);
            //
            // The helper is emitted in
            // `emitProtocolVTableInstanceSourceFile` alongside the
            // adapter functions. Its body does the
            // `@ptrCast(@alignCast(box.data_ptr.?)).*` recovery and
            // returns the typed concrete value. The IR-level guard
            // wiring lives in the surrounding match-arm compilation —
            // by the time this lowering runs, the box's vtable is
            // already known to point at this target's instance
            // constant.
            .protocol_box_unbox => |bu| {
                const instance_name = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}VTable_for_{s}",
                    .{ bu.protocol_name, bu.target_type_name },
                );
                defer self.allocator.free(instance_name);

                const instance_import = zir_builder_emit_import(
                    self.handle,
                    instance_name.ptr,
                    @intCast(instance_name.len),
                );
                if (instance_import == error_ref) return error.EmitFailed;

                const unbox_fn = zir_builder_emit_field_val(
                    self.handle,
                    instance_import,
                    "unbox",
                    5,
                );
                if (unbox_fn == error_ref) return error.EmitFailed;

                const box_ref = try self.refForLocal(bu.box);
                const args = [_]u32{box_ref};
                const result_ref = zir_builder_emit_call_ref(
                    self.handle,
                    unbox_fn,
                    &args,
                    1,
                );
                if (result_ref == error_ref) return error.EmitFailed;
                try self.setLocal(bu.dest, result_ref);
            },

            // Runtime type-test guard for a `ProtocolBox` (Phase 3.a). The
            // companion of `protocol_box_unbox`: lowers to a call of the
            // synthetic per-impl helper
            //
            //   const matches = @import("<Protocol>VTable_for_<Target>")
            //                      .vtable_eq(box);
            //
            // which pointer-compares `box.vtable` against this impl's vtable
            // instance constant (emitted in
            // `emitProtocolVTableInstanceSourceFile`) and returns `bool`. The
            // `rescue`-arm dispatch (`lowerRescueDispatch`) uses the result as
            // the condition of the arm's `if`, so a boxed `Error` is matched
            // against a specific concrete error type at runtime.
            .protocol_box_vtable_eq => |ve| {
                const instance_name = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}VTable_for_{s}",
                    .{ ve.protocol_name, ve.target_type_name },
                );
                defer self.allocator.free(instance_name);

                const instance_import = zir_builder_emit_import(
                    self.handle,
                    instance_name.ptr,
                    @intCast(instance_name.len),
                );
                if (instance_import == error_ref) return error.EmitFailed;

                const vtable_eq_fn = zir_builder_emit_field_val(
                    self.handle,
                    instance_import,
                    "vtable_eq",
                    9,
                );
                if (vtable_eq_fn == error_ref) return error.EmitFailed;

                const box_ref = try self.refForLocal(ve.box);
                const args = [_]u32{box_ref};
                const result_ref = zir_builder_emit_call_ref(
                    self.handle,
                    vtable_eq_fn,
                    &args,
                    1,
                );
                if (result_ref == error_ref) return error.EmitFailed;
                try self.setLocal(ve.dest, result_ref);
            },

            // Pattern matching — compare atom IDs (u32)
            .match_atom => |ma| {
                // Scrutinee is already a u32 atom ID (from atomIntern).
                // Intern the expected atom and compare IDs.
                const scrutinee_ref = try self.refForLocal(ma.scrutinee);

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
            .match_variant_tag => |mvt| {
                // Compare a tagged-union scrutinee's active tag
                // against the expected variant name. Mirrors the
                // tag-check logic at the head of `emitUnionSwitchReturn`:
                //   activeTag(scrutinee) == .VariantName
                // The result is a bool the surrounding guard_block
                // consumes for branching.
                const scrutinee_ref = try self.refForLocal(mvt.scrutinee);
                const std_import = zir_builder_emit_import(self.handle, "std", 3);
                if (std_import == error_ref) return error.EmitFailed;
                const meta_mod = zir_builder_emit_field_val(self.handle, std_import, "meta", 4);
                if (meta_mod == error_ref) return error.EmitFailed;
                const active_tag_fn = zir_builder_emit_field_val(self.handle, meta_mod, "activeTag", 9);
                if (active_tag_fn == error_ref) return error.EmitFailed;
                const tag_args = [_]u32{scrutinee_ref};
                const tag_ref = zir_builder_emit_call_ref(self.handle, active_tag_fn, &tag_args, 1);
                if (tag_ref == error_ref) return error.EmitFailed;

                const variant_ref = zir_builder_emit_enum_literal(self.handle, mvt.variant_name.ptr, @intCast(mvt.variant_name.len));
                if (variant_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, tag_ref, variant_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mvt.dest, ref);
            },
            .variant_payload_get => |vpg| {
                // Extract a tagged-union payload via the variant's
                // field name — `scrutinee.VariantName`. Mirrors the
                // payload-extraction step inside
                // `emitUnionSwitchReturn`'s per-case body. The
                // preceding `match_variant_tag` + `guard_block`
                // ensures Sema reaches this only when the variant
                // actually matches.
                const scrutinee_ref = try self.refForLocal(vpg.scrutinee);
                const payload_ref = zir_builder_emit_field_val(self.handle, scrutinee_ref, vpg.variant_name.ptr, @intCast(vpg.variant_name.len));
                if (payload_ref == error_ref) return error.EmitFailed;
                try self.setLocal(vpg.dest, payload_ref);
            },
            .match_int => |mi| {
                // Compare scrutinee against expected int via cmp_eq
                const scrutinee_ref = try self.refForLocal(mi.scrutinee);
                const expected_ref = zir_builder_emit_int(self.handle, mi.value);
                if (expected_ref == error_ref) return error.EmitFailed;
                const cmp_tag = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, expected_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mi.dest, ref);
            },
            .match_float => |mf| {
                // Compare scrutinee against expected float via cmp_eq
                const scrutinee_ref = try self.refForLocal(mf.scrutinee);
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
                const scrutinee_ref = try self.refForLocal(ms.scrutinee);
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
                const scrutinee_ref = try self.refForLocal(mt.scrutinee);

                // For .any, always matches — emit true
                if (mt.expected_type == .any) {
                    const ref = zir_builder_emit_bool(self.handle, true);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(mt.dest, ref);
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
                    return error.EmitFailed;
                }

                const typeof_ref = zir_builder_emit_typeof(self.handle, scrutinee_ref);
                if (typeof_ref == error_ref) return error.EmitFailed;

                const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
                const ref = zir_builder_emit_binop(self.handle, cmp_tag, typeof_ref, expected_type_raw);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(mt.dest, ref);
            },
            .match_fail => |mf| {
                // Every unrecoverable abort routes through the unified Phase 2
                // crash path — a `Kernel` sink that calls `crashReport` with a
                // canonical kind plus a symbolized Zap backtrace (Phase 2.f
                // GP1). The semantic class on the IR op selects the sink so
                // the report's `** (<kind>)` header is correct: a non-matching
                // `case`/clause set is `match_error`, while an explicit `panic`
                // or `unreachable` is `runtime_error`. The older bare
                // `Kernel.panic` (`panic:`+`exit(1)`, no backtrace) is retired.
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;

                const kernel = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.kernel);
                if (kernel == error_ref) return error.EmitFailed;

                const sink_name: []const u8 = switch (mf.kind) {
                    .match_clause => "match_fail",
                    .panic, .unreachable_reached => "panic",
                };
                const sink_fn = zir_builder_emit_field_val(self.handle, kernel, sink_name.ptr, @intCast(sink_name.len));
                if (sink_fn == error_ref) return error.EmitFailed;

                // `panic(msg)` carries a runtime message string in a local;
                // forward it so the report shows the user's message. All other
                // sites use the static IR message.
                const msg_ref = if (mf.kind == .panic and mf.message_local != null)
                    try self.refForLocal(mf.message_local.?)
                else
                    zir_builder_emit_str(self.handle, mf.message.ptr, @intCast(mf.message.len));
                if (msg_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{msg_ref};
                const sink_ref = zir_builder_emit_call_ref(self.handle, sink_fn, &args, 1);
                if (sink_ref == error_ref) return error.EmitFailed;
                // The sink is noreturn — emit unreachable so Zig knows control never continues
                if (zir_builder_emit_unreachable(self.handle) != 0) return error.EmitFailed;
            },
            .match_error_return => {
                // No-match in __try variant: return null.
                // The caller detects null and passes the unmatched input to the handler.
                if (zir_builder_emit_ret_null(self.handle) != 0)
                    return error.EmitFailed;
            },
            .ret_raise => {
                // Phase 3.b: a propagating `raise`. The preceding instruction
                // (lowered from the HIR `stash_call`) already emitted
                // `Kernel.recoverable_raise(box)`, stashing the boxed `Error`
                // existential into the thread-local side-channel. Now emit
                // `return error.ZapRaise` — the cross-function control signal.
                // Zig's `try`/`catch` at the call site unwinds it (building
                // the error return trace), and the nearest dynamically-
                // enclosing `try`/`rescue` recovers the boxed payload from the
                // side-channel. The function's return type was set to
                // `error{ZapRaise}!T` in `emitFunction`.
                const err_name = "ZapRaise";
                if (zir_builder_emit_ret_error(self.handle, err_name.ptr, @intCast(err_name.len)) != 0)
                    return error.EmitFailed;
            },

            .call_dispatch => |cd| {
                // Resolve the dispatch group to the actual function and call it.
                // The group_id is a valid FunctionId created during IR building.
                const ref = try self.emitNamedCallToTarget(cd.group_id, cd.args);
                try self.setLocal(cd.dest, ref);
            },
            .call_closure => |cc| {
                // =====================================================================
                // FCC — the FINAL closure-dispatch architecture (escape-driven).
                //
                // A `fn(A) -> R` value is a `Callable({A}, R)` existential. Escape
                // analysis collapses it to ONE of THREE runtime representations; each
                // is reachable (proven by ZAP_DISPATCH_TRACE across the full corpus +
                // script fixtures + unit tests) and serves a distinct case. Do NOT
                // delete any of them — each is the zero-overhead lowering for its case:
                //
                //  (1) NON-CAPTURING closure read from STORAGE (field/return/element).
                //      Its type stayed `ZigType.function` (a bare `*const fn(..)` code
                //      pointer — non-capturing has no environment to box). Invoked with
                //      a DIRECT `call_ref`. This is "Gap E": `cc.callee_is_bare_fn_value`
                //      (set by `ir.closureCalleeIsMaterializedValue`). Zero overhead.
                //      e.g. `p = M.picker(); p(7)` where `picker` returns a non-capturing
                //      `fn(i64)->i64`.
                //
                //  (2) PARAMETER-derived closure (a higher-order callback param — `#201`).
                //      The runtime value may be a bare fn-ptr OR a `{call_fn, env}` stack
                //      struct (a non-escaping CAPTURING closure devirtualized onto the
                //      stack — no box), so it dispatches through `Kernel.callCallableN`,
                //      which discriminates both shapes at comptime (`isZapClosure` /
                //      `isBareFunction`, see `runtime.zig`). This is the DEVIRTUALIZED
                //      capturing path and the single most-used branch. Deleting it would
                //      force boxing of every non-escaping capturing callback and regress
                //      perf — it is NOT subsumed by the boxed `protocol_dispatch` path.
                //      `callee_is_param` (`isParamDerivedClosure`). Arity > 3 falls back
                //      to a direct `call_ref` (the helper set covers 0..3). A call-site
                //      SPECIALIZATION (lambda-set singleton / contified / switch_dispatch
                //      from `escape_lattice` + `contification_rewrite` + `lambda_sets`)
                //      may further refine this to a direct named/tail/switch call.
                //
                //  (3) 0-CAPTURE closure / capturing closure bound to a LOCAL and called
                //      via that local (NOT a param, NOT read from storage). Resolved
                //      through `closure_function_map` (0-capture → direct named call,
                //      `emitNamedCallToTarget`) or, for a capturing one, the dynamic
                //      `{call_fn, env}` struct destructure tail. e.g. `f = fn(x){x+1};
                //      f(10)` (0-capture, `closure_function_map`) and `n = 5;
                //      f = fn(x){x+n}; f(10)` (capturing-local, struct destructure).
                //
                // The FOURTH representation — a BOXED `ProtocolBox(Callable)` for an
                // ESCAPING / heterogeneous / stored / returned-CAPTURING closure — never
                // reaches here: `ir.lowerBoxedCallableInvocation` intercepts a callee
                // whose representation is `.protocol_box(Callable)` BEFORE this
                // `call_closure` is emitted and routes it to `protocol_dispatch` through
                // the box vtable `call` slot. So everything below operates on the
                // NON-boxed (devirtualized) representations only.
                // =====================================================================
                const lattice = @import("escape_lattice.zig");
                const callee_is_param = self.isParamDerivedClosure(cc.callee);

                // Gap E — the callee is a MATERIALIZED closure VALUE read out
                // of storage (a struct field, a function return value, a
                // collection element). Its runtime representation is a bare
                // `*const fn(...) ret` code pointer (a non-capturing closure
                // that flowed through a concrete-typed position), so invoke
                // it with a DIRECT `call_ref` — NOT the `{call_fn, env}`
                // closure-struct destructuring (which would emit a `field_val`
                // on a function-pointer value: `type 'fn () ...' does not
                // support field access`) and NOT `Kernel.callCallableN` (the
                // param-position dynamic dispatch). The IR builder set this
                // flag from the callee expression's shape + function type.
                if (cc.callee_is_bare_fn_value) {
                    const callee_ref = try self.refForLocal(cc.callee);
                    var args: std.ArrayListUnmanaged(u32) = .empty;
                    defer args.deinit(self.allocator);
                    for (cc.args) |arg| {
                        const ref = try self.refForValueLocal(arg);
                        try args.append(self.allocator, ref);
                    }
                    var ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    // #201 — a raising closure's call yields `error{ZapRaise}!T`;
                    // skip the payload-narrowing `@as` (it would reject the
                    // error union) and leave the union for the following
                    // `unwrap_error_union`. A pure closure narrows to its
                    // declared return type.
                    const ret_type_ref = if (cc.raises) @as(u32, 0) else mapReturnType(cc.return_type);
                    if (ret_type_ref != 0) {
                        const cast = zir_builder_emit_as(self.handle, ret_type_ref, ref);
                        if (cast == error_ref) return error.EmitFailed;
                        ref = cast;
                    }
                    try self.setLocal(cc.dest, ref);
                    return;
                }

                // Parameter-derived closures: the callee is a function parameter.
                // It could be either a bare function pointer or a closure struct
                // with {call_fn, env}. Use Kernel.callCallableN for dispatch.
                if (callee_is_param) {
                    if (self.getCallSiteSpecialization(cc.callee)) |spec| {
                        switch (spec.decision) {
                            .direct_call, .contified => {
                                if (spec.lambda_set.isSingleton()) {
                                    const target_id = spec.lambda_set.members[0];
                                    if (self.findFunctionById(target_id)) |target_func| {
                                        const ref = if (target_func.captures.len == 0)
                                            try self.emitNamedCallToTarget(target_id, cc.args)
                                        else
                                            try self.emitCapturedClosureTargetCall(cc.callee, target_id, cc.args);
                                        try self.setLocal(cc.dest, ref);
                                        return;
                                    }
                                }
                            },
                            else => {},
                        }
                    }

                    const callee_ref = try self.refForLocal(cc.callee);
                    var args: std.ArrayListUnmanaged(u32) = .empty;
                    defer args.deinit(self.allocator);
                    for (cc.args) |arg| {
                        const ref2 = try self.refForValueLocal(arg);
                        try args.append(self.allocator, ref2);
                    }

                    const rt_ref = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_ref == error_ref) return error.EmitFailed;
                    const kernel_ref = emitRuntimeNamespaceField(self.handle, rt_ref, runtime_ns.kernel);
                    if (kernel_ref == error_ref) return error.EmitFailed;
                    const helper_name = switch (args.items.len) {
                        0 => "callCallable0",
                        1 => "callCallable1",
                        2 => "callCallable2",
                        3 => "callCallable3",
                        else => {
                            // Arity fallback: callCallableN helpers cover 0..3.
                            var ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                            if (ref == error_ref) return error.EmitFailed;
                            // #201 — a raising closure's call yields
                            // `error{ZapRaise}!T`; do NOT narrow to the
                            // payload here (the `@as` would reject the
                            // error union). The following
                            // `unwrap_error_union` consumes the union.
                            const ret_type_ref2 = if (cc.raises) @as(u32, 0) else mapReturnType(cc.return_type);
                            if (ret_type_ref2 != 0) {
                                const cast2 = zir_builder_emit_as(self.handle, ret_type_ref2, ref);
                                if (cast2 == error_ref) return error.EmitFailed;
                                ref = cast2;
                            }
                            try self.setLocal(cc.dest, ref);
                            return;
                        },
                    };
                    const helper_ref = zir_builder_emit_field_val(self.handle, kernel_ref, helper_name.ptr, @intCast(helper_name.len));
                    if (helper_ref == error_ref) return error.EmitFailed;
                    var full_args: std.ArrayListUnmanaged(u32) = .empty;
                    defer full_args.deinit(self.allocator);
                    try full_args.append(self.allocator, callee_ref);
                    try full_args.appendSlice(self.allocator, args.items);
                    var ref = zir_builder_emit_call_ref(self.handle, helper_ref, full_args.items.ptr, @intCast(full_args.items.len));
                    if (ref == error_ref) return error.EmitFailed;
                    // Cast the callCallableN result to the expected return
                    // type. The runtime helper returns CallReturnType which
                    // Zig infers from the callable, but the monomorphized
                    // function may declare a different concrete return type.
                    // #201 — for a raising closure the helper returns
                    // `error{ZapRaise}!T`; skip the payload-narrowing
                    // `@as` and let the following `unwrap_error_union`
                    // `try`/`catch` the error union.
                    const ret_type_ref = if (cc.raises) @as(u32, 0) else mapReturnType(cc.return_type);
                    if (ret_type_ref != 0) {
                        const cast = zir_builder_emit_as(self.handle, ret_type_ref, ref);
                        if (cast == error_ref) return error.EmitFailed;
                        ref = cast;
                    }
                    try self.setLocal(cc.dest, ref);
                    return;
                }

                // Fast path: use the closure function map to resolve the callee
                // directly to a named function call. This handles 0-capture closures
                // (anonymous functions and function refs) by tracking the function ID
                // through local assignments without needing backward instruction scanning.
                if (self.closure_function_map.get(cc.callee)) |func_id| {
                    if (self.findFunctionById(func_id)) |target_func| {
                        if (target_func.captures.len == 0) {
                            const ref = try self.emitNamedCallToTarget(func_id, cc.args);
                            try self.setLocal(cc.dest, ref);
                            return;
                        }
                    }
                }

                if (self.getCallSiteSpecialization(cc.callee)) |spec| {
                    switch (spec.decision) {
                        .unreachable_call => {
                            // Fall through to dynamic dispatch. The unreachable
                            // classification may be wrong when function IDs shift
                            // (e.g., anonymous closures inserted in the IR), or
                            // when cross-struct callers pass closures the local
                            // escape analysis didn't see.
                        },
                        .direct_call, .contified => {
                            if (spec.decision == .contified and self.isTailReturnOf(cc.dest) and spec.lambda_set.isSingleton()) {
                                const target_id = spec.lambda_set.members[0];
                                if (self.findFunctionById(target_id)) |target_func| {
                                    if (target_func.captures.len == 0) {
                                        try self.emitTailNamedCallToTarget(target_id, cc.args);
                                        self.skip_next_ret_local = cc.dest;
                                        return;
                                    }
                                }
                                if (try self.emitTailInvokeWrapperCall(cc.callee, target_id, cc.args)) {
                                    self.skip_next_ret_local = cc.dest;
                                    return;
                                }
                            }
                            if (spec.lambda_set.isSingleton()) {
                                const target_id = spec.lambda_set.members[0];
                                if (self.findFunctionById(target_id)) |target_func| {
                                    if (target_func.captures.len == 0) {
                                        const ref = try self.emitNamedCallToTarget(target_id, cc.args);
                                        try self.setLocal(cc.dest, ref);
                                        return;
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
                        if (self.analysis_context) |actx| {
                            const vkey = lattice.ValueKey{
                                .function = self.current_function_id,
                                .local = cc.callee,
                            };
                            if (actx.getLambdaSet(vkey)) |ls| {
                                if (ls.isSingleton()) {
                                    if (ls.members.len > 0) {
                                        const target_id = ls.members[0];
                                        if (self.findFunctionById(target_id)) |target_func| {
                                            if (target_func.captures.len == 0) {
                                                break :blk .{ .function_id = target_id, .captures = &.{} };
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
                    const ref = try self.emitNamedCallToTarget(target.function_id, cc.args);
                    try self.setLocal(cc.dest, ref);
                } else {
                    // Dynamic dispatch: extract call_fn and env from closure struct,
                    // call function with env prepended to args.
                    const callee_ref = try self.refForLocal(cc.callee);

                    // When the callee is a function parameter or a bare function ref
                    // (from a 0-capture make_closure), emit a direct call_ref without
                    // trying to destructure a closure struct.
                    const callee_is_bare_function_ref = if (callee_is_param) false else try self.isBareFunctionRef(cc.callee);
                    if (callee_is_param or callee_is_bare_function_ref) {
                        var args: std.ArrayListUnmanaged(u32) = .empty;
                        defer args.deinit(self.allocator);
                        for (cc.args) |arg| {
                            const ref = try self.refForValueLocal(arg);
                            try args.append(self.allocator, ref);
                        }
                        const ref = zir_builder_emit_call_ref(self.handle, callee_ref, args.items.ptr, @intCast(args.items.len));
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cc.dest, ref);
                        return;
                    }

                    // Extract function pointer and environment from closure struct
                    const call_fn_ref = zir_builder_emit_field_val(self.handle, callee_ref, "call_fn", 7);
                    if (call_fn_ref == error_ref) return error.EmitFailed;

                    const env_ref = zir_builder_emit_field_val(self.handle, callee_ref, "env", 3);
                    if (env_ref == error_ref) return error.EmitFailed;

                    // Build args: env as first argument, then user args
                    var full_args: std.ArrayListUnmanaged(u32) = .empty;
                    defer full_args.deinit(self.allocator);
                    try full_args.append(self.allocator, env_ref);
                    for (cc.args) |arg| {
                        const ref = try self.refForValueLocal(arg);
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
                    if (self.param_derived_closure_locals.contains(cap_local)) {
                        const key = @as(u64, mc.function) << 32 | @as(u64, @intCast(cap_idx));
                        try self.capture_param_derived_closure_map.put(self.allocator, key, {});
                    }
                }

                // Resolve the correct name for the current struct context.
                // In per-struct emission, functions are emitted with local_name,
                // so references must also use local_name (or @import for cross-struct).
                const emit_name = if (self.current_emit_struct != null and target_func.local_name.len > 0)
                    target_func.local_name
                else
                    target_func.name;

                // Determine if this is a cross-struct reference
                const target_struct = target_func.struct_name;
                const is_cross_struct = blk: {
                    if (target_struct == null and self.current_emit_struct == null) break :blk false;
                    if (target_struct == null or self.current_emit_struct == null) break :blk true;
                    break :blk !std.mem.eql(u8, target_struct.?, self.current_emit_struct.?);
                };

                // 0-capture closures: emit a bare function pointer via decl_ref.
                // This produces *const fn(args...) ret which is the uniform type
                // for all function references passed as callback parameters.
                if (mc.captures.len == 0) {
                    if (is_cross_struct and target_struct != null) {
                        try self.setLocalDecl(mc.dest, target_struct.?, target_func.local_name);
                    } else {
                        try self.setLocalDecl(mc.dest, null, emit_name);
                    }
                    return;
                }

                // Build the environment tuple: .{ capture0, capture1, ... }
                var env_names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
                defer env_names_ptrs.deinit(self.allocator);
                var env_names_lens: std.ArrayListUnmanaged(u32) = .empty;
                defer env_names_lens.deinit(self.allocator);
                var env_values: std.ArrayListUnmanaged(u32) = .empty;
                defer env_values.deinit(self.allocator);
                var index_field_name_batch = try IndexFieldNameBatch.init(self.allocator, mc.captures.len);
                defer index_field_name_batch.deinit();

                for (mc.captures, 0..) |cap, i| {
                    const cap_ref = try self.refForLocal(cap);
                    const name = index_field_name_batch.get(i);
                    try env_names_ptrs.append(self.allocator, name.ptr);
                    try env_names_lens.append(self.allocator, name.len);
                    try env_values.append(self.allocator, cap_ref);
                }

                const env_type_ref = try self.emitClosureEnvTypeRefForTarget(target_func);
                const env_ref = zir_builder_emit_struct_init_typed(
                    self.handle,
                    env_type_ref,
                    env_names_ptrs.items.ptr,
                    env_names_lens.items.ptr,
                    env_values.items.ptr,
                    @intCast(env_values.items.len),
                );
                if (env_ref == error_ref) return error.EmitFailed;

                // Build the closure struct: .{ .call_fn = func_ref, .env = env_ref }
                // Use struct-aware resolution: decl_ref for same-struct, @import for cross-struct.
                const fn_name_ref = if (is_cross_struct and target_struct != null)
                    try self.emitCrossStructRef(target_struct.?, target_func.local_name)
                else blk: {
                    const ref = zir_builder_emit_decl_ref(self.handle, emit_name.ptr, @intCast(emit_name.len));
                    if (ref == error_ref) return error.EmitFailed;
                    break :blk ref;
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
                    if (self.capture_param_derived_closure_map.contains(key)) {
                        try self.markParamDerivedClosureLocal(cg.dest);
                    } else {
                        self.unmarkParamDerivedClosureLocal(cg.dest);
                    }
                }
                if (self.currentClosureLowering()) |lowering| {
                    if (lowering.needs_env_param) {
                        const env_ref = self.current_closure_env_ref orelse {
                            const ref = zir_builder_emit_void(self.handle);
                            if (ref == error_ref) return error.EmitFailed;
                            try self.setLocal(cg.dest, ref);
                            return;
                        };
                        var field_name_buf: [max_index_field_name_len]u8 = undefined;
                        const name = indexFieldName(cg.index, &field_name_buf);
                        const ref = zir_builder_emit_field_val(self.handle, env_ref, name.ptr, name.len);
                        if (ref == error_ref) return error.EmitFailed;
                        try self.setLocal(cg.dest, ref);
                        return;
                    }
                }

                // Lambda-lifted closure: captures are prepended ordinary
                // parameters; resolve via capture_param_refs.
                if (cg.index < self.capture_param_refs.items.len) {
                    try self.setLocal(cg.dest, self.capture_param_refs.items[cg.index]);
                    return;
                }

                const ref = zir_builder_emit_void(self.handle);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(cg.dest, ref);
            },

            .optional_unwrap => |ou| {
                const source_ref = try self.refForLocal(ou.source);

                if (!ou.safety_check) {
                    const payload = zir_builder_emit_optional_payload_unsafe(self.handle, source_ref);
                    if (payload == error_ref) return error.EmitFailed;
                    try self.setLocal(ou.dest, payload);
                    return;
                }

                // Check if source is non-null
                const is_nonnull = zir_builder_emit_is_non_null(self.handle, source_ref);
                if (is_nonnull == error_ref) return error.EmitFailed;

                // Then branch: extract optional payload
                self.beginCapture();
                var then_capture_open = true;
                errdefer if (then_capture_open) self.discardCapture();

                const payload = zir_builder_emit_optional_payload(self.handle, source_ref);
                if (payload == error_ref) return error.EmitFailed;
                var then_len: u32 = 0;
                const then_ptr = self.endCapture(&then_len);
                then_capture_open = false;

                // Copy then instructions (capture buffer reused for else)
                var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
                defer then_insts.deinit(self.allocator);
                then_insts.appendSliceAssumeCapacity(then_ptr[0..then_len]);

                // Else branch: abort on nil access through the unified crash
                // path — @import("zap_runtime").Kernel.nil_access(message),
                // which calls crashReport with the canonical `nil_error` kind
                // plus a symbolized Zap backtrace (Phase 2.f GP1).
                self.beginCapture();
                var else_capture_open = true;
                errdefer if (else_capture_open) self.discardCapture();

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const kernel = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.kernel);
                if (kernel == error_ref) return error.EmitFailed;
                const panic_fn = zir_builder_emit_field_val(self.handle, kernel, "nil_access", 10);
                if (panic_fn == error_ref) return error.EmitFailed;
                const msg = "attempted to unwrap nil value";
                const msg_ref = zir_builder_emit_str(self.handle, msg.ptr, @intCast(msg.len));
                if (msg_ref == error_ref) return error.EmitFailed;
                const panic_args = [_]u32{msg_ref};
                const panic_call = zir_builder_emit_call_ref(self.handle, panic_fn, &panic_args, 1);
                if (panic_call == error_ref) return error.EmitFailed;
                var else_len: u32 = 0;
                const else_ptr = self.endCapture(&else_len);
                else_capture_open = false;

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
                    0,
                    0,
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
                const helpers = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.binary_helpers);
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
                    .dynamic => |d| try self.refForLocal(d),
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
                const helpers = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.binary_helpers);
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
                    .dynamic => |d| try self.refForLocal(d),
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{ source_ref, offset_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 2);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(brf.dest, ref);
            },
            .bin_slice => |bs| {
                // An explicit length lowers to BinaryHelpers.slice(source,
                // offset, length); an absent length (`null` = "rest of data")
                // lowers to BinaryHelpers.sliceRest(source, offset). The two
                // are distinct runtime helpers so a legitimate ZERO-length
                // slice yields "" rather than the entire remainder — the old
                // in-band `length == 0` sentinel conflated them (audit
                // ir-1--03). This matches the CTFE interpreter's semantics.
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.binary_helpers);
                if (helpers == error_ref) return error.EmitFailed;

                const source_ref = try self.refForLocal(bs.source);
                const offset_ref = switch (bs.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| try self.refForLocal(d),
                };
                if (offset_ref == error_ref) return error.EmitFailed;

                if (bs.length) |len| {
                    const fn_ref = zir_builder_emit_field_val(self.handle, helpers, "slice", 5);
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const length_ref = switch (len) {
                        .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                        .dynamic => |d| try self.refForLocal(d),
                    };
                    if (length_ref == error_ref) return error.EmitFailed;
                    const args = [_]u32{ source_ref, offset_ref, length_ref };
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 3);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bs.dest, ref);
                } else {
                    const fn_ref = zir_builder_emit_field_val(self.handle, helpers, "sliceRest", 9);
                    if (fn_ref == error_ref) return error.EmitFailed;
                    const args = [_]u32{ source_ref, offset_ref };
                    const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 2);
                    if (ref == error_ref) return error.EmitFailed;
                    try self.setLocal(bs.dest, ref);
                }
            },
            .bin_read_utf8 => |bru| {
                // Two calls: utf8ByteLen for dest_len, utf8Decode for dest_codepoint
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.binary_helpers);
                if (helpers == error_ref) return error.EmitFailed;

                const source_ref = try self.refForLocal(bru.source);
                const offset_ref = switch (bru.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| try self.refForLocal(d),
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
                // Emit: @import("zap_runtime").BinaryHelpers.matchPrefix(source, offset, expected)
                // The offset positions the comparison at the segment's true
                // byte position rather than always at byte 0 (audit ir-1--01).
                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const helpers = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.binary_helpers);
                if (helpers == error_ref) return error.EmitFailed;
                const fn_ref = zir_builder_emit_field_val(self.handle, helpers, "matchPrefix", 11);
                if (fn_ref == error_ref) return error.EmitFailed;

                const source_ref = try self.refForLocal(bmp.source);
                const offset_ref = switch (bmp.offset) {
                    .static => |s| zir_builder_emit_int(self.handle, @intCast(s)),
                    .dynamic => |d| try self.refForLocal(d),
                };
                if (offset_ref == error_ref) return error.EmitFailed;
                const expected_ref = zir_builder_emit_str(self.handle, bmp.expected.ptr, @intCast(bmp.expected.len));
                if (expected_ref == error_ref) return error.EmitFailed;

                const args = [_]u32{ source_ref, offset_ref, expected_ref };
                const ref = zir_builder_emit_call_ref(self.handle, fn_ref, &args, 3);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(bmp.dest, ref);
            },

            // Memory/ARC
            .retain => |ret| {
                // Phase 1.2.5 / G-box: protocol-existential retains route
                // through the per-protocol synthetic `<Protocol>VTable.retain(box)`
                // helper rather than the generic `retainAny` dispatcher.
                // The IR builder's post-drop-insertion rewrite
                // (`rewriteProtocolBoxReleases`) flipped the retain kind +
                // stamped the protocol name on every box-local retain.
                //
                // CRITICAL: this MUST run BEFORE the `shouldSkipArc` guard,
                // symmetric to the `.protocol_box_drop` release path. If a
                // box-local retain were skipped while its paired
                // `.protocol_box_drop` (now unconditional) still fired, the
                // inner would be over-released — a double-free. Keeping
                // both unconditional preserves the retain/drop balance for
                // a box shared into a borrowed call argument (the
                // `share_value(retain)` + post-call `release` pair around a
                // dispatch site). (G-box, round 2.)
                if (ret.kind == .protocol_box_retain) {
                    const protocol_name = ret.protocol_name orelse return error.EmitFailed;
                    const vtable_module_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}VTable",
                        .{protocol_name},
                    );
                    defer self.allocator.free(vtable_module_name);

                    const vtable_import = zir_builder_emit_import(
                        self.handle,
                        vtable_module_name.ptr,
                        @intCast(vtable_module_name.len),
                    );
                    if (vtable_import == error_ref) return error.EmitFailed;

                    const retain_helper = zir_builder_emit_field_val(
                        self.handle,
                        vtable_import,
                        "retain",
                        6,
                    );
                    if (retain_helper == error_ref) return error.EmitFailed;

                    const box_ref = try self.refForLocal(ret.value);
                    const retain_args = [_]u32{box_ref};
                    const retain_ref = zir_builder_emit_call_ref(self.handle, retain_helper, &retain_args, 1);
                    if (retain_ref == error_ref) return error.EmitFailed;
                    return;
                }

                // FCC Phase 2 clone-on-share: a PERSISTENT box retain creates a
                // genuine second owner with its own scope-exit
                // `.protocol_box_drop`. Route it through the per-protocol
                // `<Protocol>VTable.share(box)` helper and REBIND the new-owner
                // local to its result. `share` is comptime-specialized on the
                // active manager's REFCOUNT_V1 capability — under a refcount
                // manager it bumps the inner's refcount and returns the SAME box
                // (the rebind is an identity); under a no-REFCOUNT_V1 manager it
                // returns an independent CLONE so the new owner drops its own
                // inner exactly once, never double-freeing the inner the source
                // owner also frees. Like `.protocol_box_retain` this MUST run
                // before the `shouldSkipArc` guard: the paired
                // `.protocol_box_drop` is unconditional, so eliding the
                // share/clone here would leave the new owner aliasing the
                // source's inner — a double-free under `Memory.Tracking`.
                if (ret.kind == .protocol_box_share) {
                    const protocol_name = ret.protocol_name orelse return error.EmitFailed;
                    const vtable_module_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}VTable",
                        .{protocol_name},
                    );
                    defer self.allocator.free(vtable_module_name);

                    const vtable_import = zir_builder_emit_import(
                        self.handle,
                        vtable_module_name.ptr,
                        @intCast(vtable_module_name.len),
                    );
                    if (vtable_import == error_ref) return error.EmitFailed;

                    const share_helper = zir_builder_emit_field_val(
                        self.handle,
                        vtable_import,
                        "share",
                        5,
                    );
                    if (share_helper == error_ref) return error.EmitFailed;

                    const box_ref = try self.refForLocal(ret.value);
                    const share_args = [_]u32{box_ref};
                    const shared_ref = zir_builder_emit_call_ref(self.handle, share_helper, &share_args, 1);
                    if (shared_ref == error_ref) return error.EmitFailed;
                    try self.aggregate_component_original_refs.put(self.allocator, ret.value, box_ref);
                    try self.setLocal(ret.value, shared_ref);
                    self.unmarkShareSkippedForClone(ret.value);
                    return;
                }

                // Capability-gated symmetry (CapMem Phase 3): under an
                // `individual_no_refcount` + `clone_on_share` manager
                // (`Memory.Tracking`), `shouldSkipArc` elides ALL refcount
                // retains — correct for a refcount increment, but a
                // `.persistent` retain of an ARC-managed local is the
                // share-side mirror of the deep-walk `.release` carve-out
                // (`emit_deep_walk_under_no_refcount`): it creates a genuine
                // SECOND owner that the IR pairs with a scope-exit `.release`,
                // and that release IS emitted under this model. So the share
                // MUST be emitted too — otherwise the new owner aliases the
                // source's eagerly-freed cell and BOTH frees `core.deallocate`
                // it (the double-free segfault). The share lowers to
                // `shareAnyPersistent`, which under `clone_on_share_active`
                // deep-CLONES a value owning an eagerly-freed child
                // (indirect-storage recursive struct, boxed inner) so each
                // owner reaches a single free, and is a no-op identity
                // otherwise. `.normal` retains stay skipped: a transient borrow
                // has no scope-exit release to balance and must NOT clone (a
                // clone there would leak).
                //
                // Gated on the CAPABILITY axes (`cloneOnShareActive`), not the
                // mere absence of REFCOUNT_V1, so it fires ONLY for Tracking —
                // NEVER for Arena/NoOp/Leak (`bulk_or_never`, which alias-share
                // soundly and reclaim in bulk / never) or `traced`.
                const emit_share_under_clone_on_share = self.cloneOnShareActive() and
                    ret.kind == .persistent and
                    self.arc_managed_locals.contains(ret.value);
                if (!self.shouldSkipArc(ret.value) or emit_share_under_clone_on_share) {
                    // Phase 1 Class A: dispatch on the IR-level kind
                    // enum so callers control the helper choice
                    // (normal vs persistent) rather than every retain
                    // emission site re-deciding between runtime helpers.
                    //
                    //   * `.normal`     → `retainAny` (void). A transient
                    //     borrow-pass retain balanced by an immediate post-call
                    //     release; no second long-lived owner, no rebind.
                    //   * `.persistent` → `shareAnyPersistent` (value-returning)
                    //     + REBIND of the new-owner local to the result. A
                    //     persistent retain stashes the value in long-lived
                    //     storage (struct field, list slot, closure capture) and
                    //     so creates a genuine SECOND owner with its own
                    //     scope-exit release. Under REFCOUNTED `shareAnyPersistent`
                    //     bumps the cell's refcount and returns the SAME value
                    //     (identity rebind) — byte-for-byte the old persistent
                    //     path, including the type's own `retain` (Map share-event
                    //     tracking). Under `clone_on_share_active` it returns an
                    //     INDEPENDENT clone for any value owning an eagerly-freed
                    //     child so each owner reaches a single free. This is the
                    //     value-level analog of the `.protocol_box_share`
                    //     clone-on-share rebind above and the container
                    //     `ownElement` path.
                    const val_ref = try self.refForLocal(ret.value);

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                    if (arc_runtime == error_ref) return error.EmitFailed;

                    switch (ret.kind) {
                        .normal => {
                            const retain_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "retainAny", 9);
                            if (retain_fn == error_ref) return error.EmitFailed;
                            const args = [_]u32{val_ref};
                            const retain_ref = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);
                            if (retain_ref == error_ref) return error.EmitFailed;
                        },
                        .persistent => {
                            const share_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "shareAnyPersistent", 18);
                            if (share_fn == error_ref) return error.EmitFailed;
                            const args = [_]u32{val_ref};
                            const shared_ref = zir_builder_emit_call_ref(self.handle, share_fn, &args, 1);
                            if (shared_ref == error_ref) return error.EmitFailed;
                            try self.aggregate_component_original_refs.put(self.allocator, ret.value, val_ref);
                            try self.setLocal(ret.value, shared_ref);
                            // Under `clone_on_share_active` a `.persistent` retain
                            // emits a REAL `shareAnyPersistent` clone (above), so
                            // `ret.value` is now an INDEPENDENT owner. Its
                            // scope-exit `.release` must FIRE to free the clone
                            // (a standalone owner) — or be omitted by drop-insertion
                            // (a clone consumed into a container, freed by the
                            // container's deep-walk). Either way the provisional
                            // `arc_share_skipped` suppression that the `copy_value`
                            // handler installed (because `shouldSkipArc` is
                            // unconditionally true under this model) is WRONG for a
                            // clone and would LEAK it, so remove it. Transient
                            // borrows (`.normal` / `protocol_box_retain`) do NOT
                            // clone and keep their suppression. Under REFCOUNTED
                            // this is a no-op: `arc_share_skipped` only carries
                            // genuinely escape-elided dests there, never a
                            // refcount-bumping persistent retain's dest.
                            self.unmarkShareSkippedForClone(ret.value);
                        },
                        .protocol_box_retain, .protocol_box_share => unreachable, // handled above
                    }
                }
            },
            .release => |rel| {
                if (rel.kind != .aggregate_component and self.isReleaseSuppressed(rel.value)) {
                    // The matching retain was either skipped (escape
                    // analysis), elided because ownership transferred to
                    // a callee (consume mode — phase 4), or elided
                    // because ownership flowed into the function's
                    // return slot (return-source elision — phase 5).
                    // Suppress the release to keep the pair balanced.
                    //
                    // Phase 5: when the elision is specifically due to
                    // return-source ownership transfer, emit a ZIR call
                    // to `ArcRuntime.noteReturnElision` so the runtime
                    // `arc_return_elisions_total` counter is bumped at
                    // the program point where the release would have
                    // been emitted. Mirrors how `noteConsume` is wired
                    // from the share_value(.consume) lowering: one call
                    // per elided release. The three suppression causes
                    // are disjoint by construction (escape analysis
                    // operates over `dest` locals while consume/return
                    // operate over `source`/`ret-value` locals; the
                    // analyzer's `checkSoundness` further asserts
                    // consume and return are disjoint), so no double-
                    // counting is possible.
                    if (self.arc_returned_locals.contains(rel.value) and self.shouldEmitRefcountOps()) {
                        // Phase 6 elision: the `noteReturnElision`
                        // counter belongs to the refcount instrumentation
                        // pathway; under a non-REFCOUNT_V1 manager there
                        // are no releases to elide and the counter is
                        // not maintained.
                        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                        if (rt_import == error_ref) return error.EmitFailed;
                        const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                        if (arc_runtime == error_ref) return error.EmitFailed;
                        const note_return_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "noteReturnElision", 17);
                        if (note_return_fn == error_ref) return error.EmitFailed;
                        const args = [_]u32{};
                        const note_return_ref = zir_builder_emit_call_ref(self.handle, note_return_fn, &args, 0);
                        if (note_return_ref == error_ref) return error.EmitFailed;
                    }
                    return;
                }
                // Phase 1.2.5.d / G-box: protocol-existential drops route
                // through the per-protocol synthetic `<Protocol>VTable.drop(box)`
                // helper rather than the generic `releaseAny` dispatcher.
                // The IR builder's post-drop-insertion rewrite
                // (`rewriteProtocolBoxReleases`) flipped the release kind +
                // stamped the protocol name on every box-local release;
                // reaching this branch means we just need to find the
                // helper and pass the box value as its sole argument.
                //
                // CRITICAL: this MUST run BEFORE the `shouldSkipArc` guard.
                // `shouldSkipArc` is a heuristic that skips ARC ops for
                // locals the backend's ARC-managed set does not track —
                // but a `.protocol_box_drop` is an EXPLICIT, IR-confirmed
                // box drop whose elision would leak the box's heap-
                // allocated inner. A box reached as a call argument (the
                // caller suppresses the share's consume-release, the box
                // local's transient classification trips `shouldSkipArc`)
                // would otherwise have its scope-exit drop silently
                // dropped — the construction-site `allocAny` inner leaks
                // for every box passed by value. (G-box, round 2.)
                if (rel.kind == .protocol_box_drop or (rel.kind == .aggregate_component and rel.protocol_name != null)) {
                    const protocol_name = rel.protocol_name orelse return error.EmitFailed;
                    const vtable_module_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}VTable",
                        .{protocol_name},
                    );
                    defer self.allocator.free(vtable_module_name);

                    const vtable_import = zir_builder_emit_import(
                        self.handle,
                        vtable_module_name.ptr,
                        @intCast(vtable_module_name.len),
                    );
                    if (vtable_import == error_ref) return error.EmitFailed;

                    const drop_fn = zir_builder_emit_field_val(
                        self.handle,
                        vtable_import,
                        "drop",
                        4,
                    );
                    if (drop_fn == error_ref) return error.EmitFailed;

                    const box_ref = if (rel.kind == .aggregate_component)
                        self.aggregateComponentOriginalRefForLocal(rel.value) orelse
                            ((try self.arcReleaseRefForLocal(rel.value)) orelse return)
                    else
                        try self.refForLocal(rel.value);
                    const drop_args = [_]u32{box_ref};
                    const drop_ref = zir_builder_emit_call_ref(self.handle, drop_fn, &drop_args, 1);
                    if (drop_ref == error_ref) return error.EmitFailed;
                    return;
                }

                // Phase 4.c box-in-struct fix: under INDIVIDUAL_NO_REFCOUNT
                // (`Memory.Tracking`), `shouldSkipArc` elides ALL refcount
                // releases — correct for a refcount decrement, but a by-VALUE
                // aggregate that transitively OWNS a heap-promoted ARC child (a
                // `ProtocolBox` in an `Option(Error)` / struct field, an
                // indirect-storage recursive field) still needs its scope-exit
                // release EMITTED so the runtime's `releaseAny` →
                // `releaseChildrenAny` deep-walk reclaims that child via
                // `core.deallocate` (the child went through `core.allocate` on
                // the no-REFCOUNT_V1 `allocAny` path). Without it the child
                // leaks under `Memory.Tracking` even though it is correctly
                // freed under `Memory.ARC` (whose release is not elided). This
                // is EXACTLY the release ARC would emit — the IR is
                // cap-independent, only the ZIR elision differs — so it cannot
                // introduce a double-free that ARC does not already have: a box
                // consumed into the container had its own `.protocol_box_drop`
                // suppressed by the ownership-transfer analysis (the container
                // is the sole owner at scope exit). For the aggregate the
                // runtime takes the `isByValueAggregate` deep-walk branch
                // (frees owned children, never the stack value), so emitting it
                // is safe.
                //
                // Phase 2 three-way split: this deep-walk emission is the
                // INDIVIDUAL_NO_REFCOUNT individual-free path and fires ONLY
                // under that model. Under BULK_OR_NEVER / TRACED there is no
                // individual free — the manager reclaims in bulk (Arena at
                // exit), never (NoOp/Leak), or via tracing — so NOTHING is
                // emitted (the runtime's `releaseAny`/`releaseChildrenAny` are
                // comptime no-ops under those models anyway, but eliding the
                // emission too keeps the ZIR free of any `releaseAny` call site
                // and guarantees zero refcount overhead). Under REFCOUNTED the
                // `shouldSkipArc` path below handles the release.
                const release_walk_kind = rel.kind == .release or rel.kind == .aggregate_component;
                const emit_deep_walk_under_no_refcount = self.reclamationModel() == .individual_no_refcount and
                    release_walk_kind and
                    self.arc_managed_locals.contains(rel.value);
                if (!self.shouldSkipArc(rel.value) or emit_deep_walk_under_no_refcount) {
                    // Phase 2 Class B: dispatch on the IR-level kind
                    // enum so callers control deep vs shallow free
                    // semantics rather than every release-emission
                    // site re-deciding between runtime helpers. The
                    // `.release` kind lowers to `releaseAny` (full
                    // ARC release: decrement refcount, deep-walk
                    // children on zero-transition, free); the
                    // `.free` kind lowers to `freeAny` (shallow free
                    // when the refcount is statically known to be 1
                    // and children have already been extracted by
                    // an inner consumer — destructive-optional
                    // dispatch).
                    const helper_name: []const u8 = switch (rel.kind) {
                        .release, .aggregate_component => "releaseAny",
                        .free => "freeAny",
                        .protocol_box_drop => unreachable, // handled above
                    };
                    const val_ref = if (rel.kind == .aggregate_component)
                        self.aggregateComponentOriginalRefForLocal(rel.value) orelse
                            ((try self.arcReleaseRefForLocal(rel.value)) orelse return)
                    else
                        (try self.arcReleaseRefForLocal(rel.value)) orelse return;

                    const alloc_ref = try self.emitAllocatorRef();

                    const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                    if (rt_import == error_ref) return error.EmitFailed;
                    const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
                    if (arc_runtime == error_ref) return error.EmitFailed;
                    const release_fn = zir_builder_emit_field_val(self.handle, arc_runtime, helper_name.ptr, @intCast(helper_name.len));
                    if (release_fn == error_ref) return error.EmitFailed;

                    const args = [_]u32{ alloc_ref, val_ref };
                    const release_ref = zir_builder_emit_call_ref(self.handle, release_fn, &args, 2);
                    if (release_ref == error_ref) return error.EmitFailed;
                }
            },
            .reset => |r| {
                const val_ref = try self.refForLocal(r.source);
                const alloc_ref = try self.emitAllocatorRef();

                const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
                if (rt_import == error_ref) return error.EmitFailed;
                const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
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
                const token_ref = if (ra.token) |token|
                    try self.refForLocal(token)
                else
                    try self.emitReuseTokenNone();
                if (token_ref == error_ref) return error.EmitFailed;
                const ref = try self.emitReuseAllocCall(type_ref, token_ref);
                try self.setLocal(ra.dest, ref);
            },

            // Never generated by IrBuilder — verified in ir.zig.
            // SSA phi nodes would merge values from different control flow paths;
            // the IR builder uses structured control flow (if_expr, case_block)
            // instead of SSA phi.
            // Numeric widening — emit @as(DestType, source)
            .int_widen, .float_widen => |nw| {
                const source_ref = try self.refForValueLocal(nw.source);
                const dest_type_ref = mapReturnType(nw.dest_type);
                const ref = zir_builder_emit_as(self.handle, dest_type_ref, source_ref);
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(nw.dest, ref);
            },

            // Typed-undefined placeholder — emit `@as(ty, undefined)`. The
            // `undef` interned ref carries no type, so coerce it to `ty` via
            // `as` to give the merge edge a peer-resolvable typed value. Use
            // the full imported-type-ref path so the placeholder works for any
            // joined type (String, struct, protocol_box, optional, …), not
            // just primitives.
            .typed_undef => |tu| {
                const ty_ref = try self.emitImportedTypeRef(tu.ty);
                const ref = zir_builder_emit_as(self.handle, ty_ref, @intFromEnum(Zir.Inst.Ref.undef));
                if (ref == error_ref) return error.EmitFailed;
                try self.setLocal(tu.dest, ref);
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
        // A branch is noreturn when the IR builder explicitly flagged it
        // (`then_is_noreturn`/`else_is_noreturn` — set for a rescue arm whose
        // body ends in a `Never`-returning re-raise `do_raise`, which carries
        // no trailing `local_set`), OR — the pre-existing tail-call/early-
        // return case — when the branch yields no value (`*_result == null`)
        // and its captured body ends in a recognized noreturn terminator
        // (`ret`/`match_fail`/musttail `tail_call`). Both must suppress the
        // synthesized trailing break: the body is already terminal, so an
        // appended `break` would dangle after the noreturn instruction and
        // trip AIR Liveness. A noreturn branch's result ref is
        // `unreachable_value`, which Sema peer-merges with any value-producing
        // sibling branch's type.
        const then_is_noreturn = ie.then_is_noreturn or
            (ie.then_result == null and self.instructionsEndNoReturnFor(ie.then_instrs));
        const else_is_noreturn = ie.else_is_noreturn or
            (ie.else_result == null and self.instructionsEndNoReturnFor(ie.else_instrs));

        // --- then branch: capture top-level body instructions ---
        self.beginCapture();
        var then_capture_open = true;
        errdefer if (then_capture_open) self.discardCapture();

        for (ie.then_instrs) |ti| {
            try self.emitInstruction(ti);
        }
        var then_len: u32 = 0;
        const then_insts_ptr = self.endCapture(&then_len);
        then_capture_open = false;

        // Phase E.7: when the rewriter has collapsed the arm's
        // recursive call into a `tail_call`, `ie.then_result` is
        // `null` and the captured ZIR ends in a `ret` (musttail) or
        // falls through to the wrapping `loop`'s `repeat` (loopify).
        // The musttail case is noreturn at the ZIR level and must
        // emit `unreachable_value` so Sema does not treat the merge
        // as reachable. The loopify case is fall-through; `void_value`
        // is correct.
        const then_ref: u32 = if (then_is_noreturn)
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else if (ie.then_result) |tr|
            try self.refForLocal(tr)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Copy then indices — the capture buffer will be reused for else branch
        var then_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, then_len);
        defer then_insts.deinit(self.allocator);
        then_insts.appendSliceAssumeCapacity(then_insts_ptr[0..then_len]);

        // --- else branch: capture top-level body instructions ---
        self.beginCapture();
        var else_capture_open = true;
        errdefer if (else_capture_open) self.discardCapture();

        for (ie.else_instrs) |ei| {
            try self.emitInstruction(ei);
        }
        var else_len: u32 = 0;
        const else_insts_ptr = self.endCapture(&else_len);
        else_capture_open = false;

        const else_ref: u32 = if (else_is_noreturn)
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else if (ie.else_result) |er|
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
            @intFromBool(then_is_noreturn),
            @intFromBool(else_is_noreturn),
        );
        if (ref == error_ref) return error.EmitFailed;
        try self.setLocal(ie.dest, ref);
    }

    /// Emit a flat IR instruction sequence that may contain `guard_block`s,
    /// reorganizing it into nested if-else-bodies so that each guard's
    /// failure path becomes the next guard (or the trailing default ops).
    ///
    /// This is the same algorithm used by `emitFlatCaseBlock` for the
    /// top-level case_block pre_instrs, factored out so it can be applied
    /// to nested bodies (inside `guard_block` and inside captured arm/default
    /// bodies of `emitFlatCaseBlock`). Without this, nested guard_blocks
    /// produced by decision-tree lowering for patterns like `check_list →
    /// switch_literal/switch_tag` would fall through into the trailing
    /// default ops and execute both branches unconditionally.
    ///
    /// Recurses for both the trailing default body and each guard's own
    /// body so that arbitrarily nested patterns (e.g. check_list →
    /// check_tuple → switch_tag) all collapse correctly.
    fn emitFlattenedGuardSequence(self: *ZirDriver, instrs: []const ir.Instruction) BuildError!void {
        var has_guard = false;
        for (instrs) |instr| {
            if (instr == .guard_block) {
                has_guard = true;
                break;
            }
        }
        if (!has_guard) {
            for (instrs, 0..) |i, instr_index| {
                self.emitInstruction(i) catch |err| {
                    std.log.err(
                        "ZIR emit failed in flattened guard sequence at instruction {d} ({s}): {s}",
                        .{ instr_index, @tagName(i), @errorName(err) },
                    );
                    return err;
                };
            }
            return;
        }

        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
        const dest_opt = self.current_case_dest;

        var last_guard_idx: usize = 0;
        for (instrs, 0..) |instr, idx| {
            if (instr == .guard_block) last_guard_idx = idx;
        }
        const default_start = last_guard_idx + 1;
        const default_instrs = instrs[default_start..];

        var guards = std.ArrayListUnmanaged(struct {
            setup_start: usize,
            guard_idx: usize,
        }).empty;
        defer guards.deinit(self.allocator);

        var prev_end: usize = 0;
        for (instrs, 0..) |instr, idx| {
            if (instr == .guard_block) {
                try guards.append(self.allocator, .{
                    .setup_start = prev_end,
                    .guard_idx = idx,
                });
                prev_end = idx + 1;
            }
        }

        // Hoist the leading SHARED setup — the extraction instructions before
        // the first guard's condition is defined (e.g. the `list_get`/
        // `list_tail` that decompose a list scrutinee). All guards reference
        // these locals, but the reverse-order if-else construction below emits
        // the LATER guards' setup first; without hoisting, an inner guard's
        // condition `list_len_check` would reference a tail/head local whose
        // defining `list_tail`/`list_get` lives in the FIRST guard's setup
        // region and has not been emitted yet (the cause of an
        // `EmitFailed` for a multi-length `check_list` chain nested inside a
        // `check_list_cons` success body — audit hir-1--01 / TY-01 follow-on).
        // This mirrors `emitFlatCaseBlock`'s `common_setup_end` hoist.
        const shared_setup_end = if (guards.items.len > 0) blk: {
            const first_guard = guards.items[0];
            const first_gb = instrs[first_guard.guard_idx].guard_block;
            const condition_idx = findInstructionDefiningLocal(
                instrs[first_guard.setup_start..first_guard.guard_idx],
                first_gb.condition,
            ) orelse 0;
            break :blk first_guard.setup_start + condition_idx;
        } else 0;

        for (instrs[0..shared_setup_end]) |si| try self.emitInstruction(si);

        // Capture the trailing default body, recursing so any guard_blocks
        // it contains are themselves flattened.
        self.beginCapture();
        var default_capture_open = true;
        errdefer if (default_capture_open) self.discardCapture();

        try self.emitFlattenedGuardSequence(default_instrs);
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        default_capture_open = false;
        const default_result: u32 = if (dest_opt) |d|
            if (self.local_refs.get(d)) |vr| try self.materializeValueRef(vr) else void_ref
        else if (self.instructionsEndNoReturnFor(default_instrs))
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else
            void_ref;

        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);
        var current_else_result: u32 = default_result;

        var gi = guards.items.len;
        while (gi > 0) {
            gi -= 1;
            const guard = guards.items[gi];
            const gb = instrs[guard.guard_idx].guard_block;
            // Skip the hoisted shared setup; emit only this guard's own setup.
            const setup_start = @max(guard.setup_start, shared_setup_end);
            const setup_instrs = instrs[setup_start..guard.guard_idx];

            for (setup_instrs) |si| try self.emitInstruction(si);

            const cond_ref = try self.refForLocal(gb.condition);

            self.beginCapture();
            var body_capture_open = true;
            errdefer if (body_capture_open) self.discardCapture();

            try self.emitFlattenedGuardSequence(gb.body);
            var body_len: u32 = 0;
            const body_ptr = self.endCapture(&body_len);
            body_capture_open = false;

            const body_result: u32 = if (dest_opt) |d|
                if (self.local_refs.get(d)) |vr| try self.materializeValueRef(vr) else void_ref
            else
                void_ref;

            const body_insts = try self.allocator.alloc(u32, body_len);
            @memcpy(body_insts, body_ptr[0..body_len]);

            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                body_insts.ptr,
                @intCast(body_insts.len),
                body_result,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(body_insts);
            current_else_insts.clear();

            if (ref == error_ref) return error.EmitFailed;

            if (gi > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                current_else_result = ref;
            }
        }

        if (dest_opt) |d| {
            try self.setLocal(d, current_else_result);
        }
    }

    /// Emit a guard block: if (condition) { body } else { void }.
    /// Body instructions are captured and placed inside a condbr_inline's
    /// then branch so Sema only analyzes them when the condition is true.
    fn emitGuardBlock(self: *ZirDriver, gb: ir.GuardBlock) BuildError!void {
        const cond_ref = try self.refForLocal(gb.condition);

        // Capture body instructions, flattening any nested guard_blocks in
        // the body into proper if-else-bodies so trailing default ops do
        // not run unconditionally alongside the matching guard.
        self.beginCapture();
        var body_capture_open = true;
        errdefer if (body_capture_open) self.discardCapture();

        try self.emitFlattenedGuardSequence(gb.body);
        var body_len: u32 = 0;
        const body_ptr = self.endCapture(&body_len);
        body_capture_open = false;

        // Copy body indices (capture buffer may be reused)
        var body_insts = try std.ArrayListUnmanaged(u32).initCapacity(self.allocator, body_len);
        defer body_insts.deinit(self.allocator);
        body_insts.appendSliceAssumeCapacity(body_ptr[0..body_len]);

        const body_returns = gb.body.len > 0 and blk: {
            const last = gb.body[gb.body.len - 1];
            break :blk (last == .ret or last == .match_fail or last == .match_error_return or last == .ret_raise);
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
            const guard_ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                body_insts.items.ptr,
                @intCast(body_insts.items.len),
                void_ref,
                &empty,
                0,
                void_ref,
                0,
                0,
            );
            if (guard_ref == error_ref) return error.EmitFailed;
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

    /// Heap-promote a value Ref so it can occupy an indirect-storage
    /// (`?*const T`) struct field. Emits a runtime call to
    /// `ArcRuntime.allocAny(@TypeOf(value), allocator, value)` which
    /// heap-allocates an Arc-wrapped slot and returns `*T`. Zig
    /// auto-coerces `*T` to `*const T` and then to `?*const T` at the
    /// field assignment, so the caller never wraps explicitly.
    ///
    /// Why a runtime call instead of ZIR `alloc` + `store` + `make_ptr_const`:
    /// `alloc` is a *stack* allocation. The pointer becomes invalid the
    /// instant the constructing function returns, so any recursive
    /// structure built across multiple frames (`make(d) = ... make(d-1) ...`)
    /// would dereference dangling memory at depth >= 2. Routing through
    /// the runtime allocator keeps the storage live as long as the Arc
    /// header reaches it.
    ///
    /// Used by struct_init lowering for fields whose
    /// `FieldStorage == .indirect`. Caller must ensure `value_ref` is
    /// not `null_value` — `nil` short-circuits this path entirely.
    fn heapPromoteForIndirectField(self: *ZirDriver, value_ref: u32) BuildError!u32 {
        const type_ref = zir_builder_emit_typeof(self.handle, value_ref);
        if (type_ref == error_ref) return error.EmitFailed;

        const alloc_ref = try self.emitAllocatorRef();

        const rt_import = zir_builder_emit_import(self.handle, "zap_runtime", 11);
        if (rt_import == error_ref) return error.EmitFailed;
        const arc_runtime = emitRuntimeNamespaceField(self.handle, rt_import, runtime_ns.arc_runtime);
        if (arc_runtime == error_ref) return error.EmitFailed;
        const alloc_fn = zir_builder_emit_field_val(self.handle, arc_runtime, "allocAny", 8);
        if (alloc_fn == error_ref) return error.EmitFailed;

        const args = [_]u32{ type_ref, alloc_ref, value_ref };
        const ptr = zir_builder_emit_call_ref(self.handle, alloc_fn, &args, 3);
        if (ptr == error_ref) return error.EmitFailed;
        return ptr;
    }

    /// Auto-deref the storage value of an indirect-storage field so the
    /// caller observes the field's source-level type. Inverse of
    /// `heapPromoteForIndirectField`. Two cases:
    ///
    ///   * Source field type is non-optional `T`: the storage is
    ///     `*const T`. Emit a `load` to recover `T`.
    ///   * Source field type is `?T`: the storage is `?*const T`. Emit
    ///     `if (storage) |p| @as(?T, p.*) else null`. Both branches are
    ///     coerced to `?T` so peer-type resolution settles cleanly.
    ///
    /// `field_storage_ref` is the ZIR ref returned by `field_val` against
    /// the underlying storage slot. `source_type` is the user-written
    /// field type (the result of `indirectFieldType`'s inverse — i.e.,
    /// the raw `StructFieldDef.type_expr`).
    fn emitIndirectFieldDeref(
        self: *ZirDriver,
        field_storage_ref: u32,
        source_type: ir.ZigType,
    ) BuildError!u32 {
        // Boxed-recursive ABI: when the source field type is itself a
        // recursive struct, the consumer (param, return, sibling field,
        // construction site) already expects `*const T` / `?*const T`.
        // The storage shape and the consumer shape match, so the
        // deref / null-check / re-coerce dance below would only undo
        // and redo what's already correct — and in the deref+load
        // case it would also strip the source-Arc identity that
        // `releaseAny` needs at drop time. Pass the storage Ref
        // through unchanged.
        if (self.zigTypeIsRecursiveStruct(source_type)) {
            return field_storage_ref;
        }
        if (source_type != .optional) {
            // Storage is `*const T`; load to recover `T`.
            return try self.emitLoad(field_storage_ref);
        }

        // Storage is `?*const T`; conditionally unwrap and deref.
        const inner_type = source_type.optional.*;
        const optional_type_ref = blk: {
            const inner_ref = try self.emitImportedTypeRef(inner_type);
            const opt_ref = zir_builder_emit_optional_type(self.handle, inner_ref);
            if (opt_ref == error_ref) return error.EmitFailed;
            break :blk opt_ref;
        };

        const is_non_null = zir_builder_emit_is_non_null(self.handle, field_storage_ref);
        if (is_non_null == error_ref) return error.EmitFailed;

        // Then-branch: deref the pointer payload and coerce to `?T`.
        self.beginCapture();
        var then_capture_open = true;
        errdefer if (then_capture_open) self.discardCapture();

        const ptr_ref = zir_builder_emit_optional_payload_unsafe(self.handle, field_storage_ref);
        if (ptr_ref == error_ref) return error.EmitFailed;
        const value_ref = try self.emitLoad(ptr_ref);
        const then_value = zir_builder_emit_as(self.handle, optional_type_ref, value_ref);
        if (then_value == error_ref) return error.EmitFailed;
        var then_len: u32 = 0;
        const then_ptr = self.endCapture(&then_len);
        then_capture_open = false;
        const then_insts = try self.allocator.alloc(u32, then_len);
        defer self.allocator.free(then_insts);
        @memcpy(then_insts, then_ptr[0..then_len]);

        // Else-branch: coerce `null` to `?T`.
        self.beginCapture();
        var else_capture_open = true;
        errdefer if (else_capture_open) self.discardCapture();

        const null_ref = @intFromEnum(Zir.Inst.Ref.null_value);
        const else_value = zir_builder_emit_as(self.handle, optional_type_ref, null_ref);
        if (else_value == error_ref) return error.EmitFailed;
        var else_len: u32 = 0;
        const else_ptr = self.endCapture(&else_len);
        else_capture_open = false;
        const else_insts = try self.allocator.alloc(u32, else_len);
        defer self.allocator.free(else_insts);
        @memcpy(else_insts, else_ptr[0..else_len]);

        const result = zir_builder_emit_if_else_bodies(
            self.handle,
            is_non_null,
            then_insts.ptr,
            @intCast(then_insts.len),
            then_value,
            else_insts.ptr,
            @intCast(else_insts.len),
            else_value,
            0,
            0,
        );
        if (result == error_ref) return error.EmitFailed;
        return result;
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
        var default_capture_open = true;
        errdefer if (default_capture_open) self.discardCapture();

        for (sl.default_instrs, 0..) |di, default_index| {
            self.emitInstruction(di) catch |err| {
                std.log.err(
                    "ZIR emit failed in switch_literal default body at instruction {d} ({s}): {s}",
                    .{ default_index, @tagName(di), @errorName(err) },
                );
                return err;
            };
        }
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        default_capture_open = false;
        // Phase E.7: also recognise `tail_call` as noreturn in non-
        // loopify mode (see `instructionsEndNoReturnFor`). Without
        // this, a tail-call-rewritten default arm would be treated as
        // void-typed and Sema would reject the if/else merge.
        const default_result: u32 = if (sl.default_result) |dr|
            try self.refForLocal(dr)
        else if (self.instructionsEndNoReturnFor(sl.default_instrs))
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        // Copy default instructions
        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);
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
                std.log.err("ZIR emit failed emitting switch_literal case value", .{});
                return error.EmitFailed;
            }

            // Emit: scrutinee == case_value
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, case_val_ref);
            if (cond_ref == error_ref) {
                std.log.err("ZIR emit failed emitting switch_literal condition", .{});
                return error.EmitFailed;
            }

            // Capture the case body
            self.beginCapture();
            var case_capture_open = true;
            errdefer if (case_capture_open) self.discardCapture();

            for (case.body_instrs, 0..) |bi, body_index| {
                self.emitInstruction(bi) catch |err| {
                    std.log.err(
                        "ZIR emit failed in switch_literal case body at instruction {d} ({s}): {s}",
                        .{ body_index, @tagName(bi), @errorName(err) },
                    );
                    return err;
                };
            }
            var case_len: u32 = 0;
            const case_ptr = self.endCapture(&case_len);
            case_capture_open = false;

            // Phase E.7: a tail-call-rewritten case (`case.result == null`
            // because `tail_call` produces no merge value) is noreturn
            // at the ZIR level when the function is musttail-lowered;
            // emit `unreachable_value` so Sema does not consider the
            // merge reachable from this arm. In loopify mode the same
            // arm falls through to the wrapping `loop`'s `repeat` and
            // `void_value` remains correct.
            const case_result: u32 = if (case.result) |r|
                self.refForLocal(r) catch |err| {
                    std.log.err(
                        "ZIR emit failed resolving switch_literal case result local {d}: {s}",
                        .{ r, @errorName(err) },
                    );
                    return err;
                }
            else if (self.instructionsEndNoReturnFor(case.body_instrs))
                @intFromEnum(Zir.Inst.Ref.unreachable_value)
            else
                @intFromEnum(Zir.Inst.Ref.void_value);

            // Copy case body (capture buffer will be reused)
            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (cond) { case_body } else { current_else }
            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                case_result,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(case_insts);
            current_else_insts.clear();

            if (ref == error_ref) {
                std.log.err(
                    "ZIR emit failed building switch_literal branch merge: then_len={d} else_len={d} then_result={d} else_result={d}",
                    .{ case_insts.len, else_insts.len, case_result, current_else_result },
                );
                return error.EmitFailed;
            }

            if (i > 0) {
                // Inner iteration: pop the block_inline from function body
                // and include it in the else branch for the next outer level.
                const block_idx = zir_builder_pop_body_inst(self.handle);
                if (block_idx == error_ref) {
                    std.log.err(
                        "ZIR emit failed popping nested switch_literal block for else chain",
                        .{},
                    );
                    return error.EmitFailed;
                }
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                // Outermost iteration — block_inline stays in function body.
                current_else_result = ref;
            }
        }

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
        var default_capture_open = true;
        errdefer if (default_capture_open) self.discardCapture();

        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        default_capture_open = false;
        const default_result: u32 = if (cb.default_result) |dr|
            try self.refForLocal(dr)
        else if (self.instructionsEndNoReturnFor(cb.default_instrs))
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else
            @intFromEnum(Zir.Inst.Ref.void_value);

        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);
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
            var arm_capture_open = true;
            errdefer if (arm_capture_open) self.discardCapture();

            for (arm.body_instrs) |bi| try self.emitInstruction(bi);
            var arm_len: u32 = 0;
            const arm_ptr = self.endCapture(&arm_len);
            arm_capture_open = false;

            // Phase E.7: tail-call-rewritten arms have `result == null`
            // and the captured ZIR ends in a noreturn `ret` (musttail
            // mode). Use `unreachable_value` so Sema does not try to
            // type-merge the arm into the enclosing block.
            const arm_result: u32 = if (arm.result) |r|
                try self.refForLocal(r)
            else if (self.instructionsEndNoReturnFor(arm.body_instrs))
                @intFromEnum(Zir.Inst.Ref.unreachable_value)
            else
                @intFromEnum(Zir.Inst.Ref.void_value);

            const arm_insts = try self.allocator.alloc(u32, arm_len);
            @memcpy(arm_insts, arm_ptr[0..arm_len]);

            // Emit: if (arm.condition) { arm_body } else { current_else }
            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                arm_insts.ptr,
                @intCast(arm_insts.len),
                arm_result,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(arm_insts);
            current_else_insts.clear();

            if (ref == error_ref) return error.EmitFailed;

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                current_else_result = ref;
            }
        }

        // The last ref produced is the result of the entire case block
        try self.setLocal(cb.dest, current_else_result);
    }

    /// Find the setup instruction that defines a guard condition local.
    fn findInstructionDefiningLocal(
        instructions: []const ir.Instruction,
        local: ir.LocalId,
    ) ?usize {
        for (instructions, 0..) |instruction, idx| {
            if (instructionDefinesLocal(instruction, local)) return idx;
        }
        return null;
    }

    fn instructionDefinesLocal(instruction: ir.Instruction, local: ir.LocalId) bool {
        switch (instruction) {
            .bin_read_utf8 => |value| return value.dest_codepoint == local or value.dest_len == local,
            else => {},
        }
        return if (instructionDest(instruction)) |dest| dest == local else false;
    }

    fn instructionDest(instruction: ir.Instruction) ?ir.LocalId {
        return switch (instruction) {
            .const_int => |value| value.dest,
            .const_float => |value| value.dest,
            .const_string => |value| value.dest,
            .const_bool => |value| value.dest,
            .const_atom => |value| value.dest,
            .const_nil => |dest| dest,
            .tuple_init => |value| value.dest,
            .list_init => |value| value.dest,
            .list_cons => |value| value.dest,
            .map_init => |value| value.dest,
            .struct_init => |value| value.dest,
            .union_init => |value| value.dest,
            .box_as_protocol => |value| value.dest,
            .protocol_dispatch => |value| value.dest,
            .protocol_box_unbox => |value| value.dest,
            .protocol_box_vtable_eq => |value| value.dest,
            .enum_literal => |value| value.dest,
            .field_get => |value| value.dest,
            .index_get => |value| value.dest,
            .list_len_check => |value| value.dest,
            .list_get => |value| value.dest,
            .list_is_not_empty => |value| value.dest,
            .list_head => |value| value.dest,
            .list_tail => |value| value.dest,
            .map_has_key => |value| value.dest,
            .map_get => |value| value.dest,
            .binary_op => |value| value.dest,
            .unary_op => |value| value.dest,
            .call_direct => |value| value.dest,
            .call_named => |value| value.dest,
            .call_closure => |value| value.dest,
            .call_dispatch => |value| value.dest,
            .call_builtin => |value| value.dest,
            .try_call_named => |value| value.dest,
            .error_catch => |value| value.dest,
            .unwrap_error_union => |value| value.dest,
            .if_expr => |value| value.dest,
            .case_block => |value| value.dest,
            .switch_literal => |value| value.dest,
            .union_switch => |value| value.dest,
            .match_atom => |value| value.dest,
            .match_variant_tag => |value| value.dest,
            .variant_payload_get => |value| value.dest,
            .match_int => |value| value.dest,
            .match_float => |value| value.dest,
            .match_string => |value| value.dest,
            .match_type => |value| value.dest,
            .make_closure => |value| value.dest,
            .capture_get => |value| value.dest,
            .optional_unwrap => |value| value.dest,
            .bin_len_check => |value| value.dest,
            .bin_read_int => |value| value.dest,
            .bin_read_float => |value| value.dest,
            .bin_slice => |value| value.dest,
            .bin_match_prefix => |value| value.dest,
            .int_widen => |value| value.dest,
            .float_widen => |value| value.dest,
            .typed_undef => |value| value.dest,
            .phi => |value| value.dest,
            .reset => |value| value.dest,
            .reuse_alloc => |value| value.dest,
            .local_get => |value| value.dest,
            .borrow_value => |value| value.dest,
            .copy_value => |value| value.dest,
            .local_set => |value| value.dest,
            .move_value => |value| value.dest,
            .share_value => |value| value.dest,
            .param_get => |value| value.dest,
            .ret,
            .field_set,
            .set_safety,
            .guard_block,
            .branch,
            .cond_branch,
            .switch_tag,
            .switch_return,
            .union_switch_return,
            .optional_dispatch,
            .match_fail,
            .match_error_return,
            .ret_raise,
            .cond_return,
            .case_break,
            .jump,
            .retain,
            .release,
            .bin_read_utf8,
            .tail_call,
            // Debug-info markers do not define a destination local.
            .dbg_stmt,
            .dbg_var,
            => null,
        };
    }

    /// Handle a case_block where the frontend put all logic in pre_instrs
    /// as a flat sequence of guard_blocks (atom/pattern matching). We extract
    /// the guard_blocks as arms and restructure into nested if-else-bodies.
    fn emitFlatCaseBlock(self: *ZirDriver, cb: ir.CaseBlock) BuildError!void {
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

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
            return;
        }

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

        const common_setup_end = if (guards.items.len > 0) blk: {
            const first_guard = guards.items[0];
            const first_guard_block = cb.pre_instrs[first_guard.guard_idx].guard_block;
            const condition_idx = findInstructionDefiningLocal(
                cb.pre_instrs[first_guard.setup_start..first_guard.guard_idx],
                first_guard_block.condition,
            ) orelse 0;
            break :blk first_guard.setup_start + condition_idx;
        } else 0;

        for (cb.pre_instrs[0..common_setup_end]) |setup_instr| {
            try self.emitInstruction(setup_instr);
        }

        // Instructions after the last guard_block are the default body.
        const default_start = last_guard_idx.? + 1;
        const default_pre_instrs = cb.pre_instrs[default_start..];

        // Capture the default body (from both trailing pre_instrs and default_instrs).
        self.beginCapture();
        var default_capture_open = true;
        errdefer if (default_capture_open) self.discardCapture();

        for (default_pre_instrs) |di| try self.emitInstruction(di);
        for (cb.default_instrs) |di| try self.emitInstruction(di);
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        default_capture_open = false;
        var default_result: u32 = if (cb.default_result) |dr|
            try self.refForLocal(dr)
        else if (self.instructionsEndNoReturnFor(default_pre_instrs) or self.instructionsEndNoReturnFor(cb.default_instrs))
            @intFromEnum(Zir.Inst.Ref.unreachable_value)
        else
            void_ref;

        // If default_result is still void but default body was captured,
        // check if case_break inside the body set cb.dest
        if (default_result == void_ref and (default_len > 0 or default_pre_instrs.len > 0)) {
            default_result = if (self.local_refs.get(cb.dest)) |vr| try self.materializeValueRef(vr) else void_ref;
        }

        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);
        var current_else_result: u32 = default_result;

        var index_get_pre_emitted = false;

        // If the default body is empty AND there's a catch-all guard (_ pattern),
        // use the last guard's body as the default instead of void.
        // The last guard has condition=true (always matches), so the empty default
        // is unreachable. Promoting the catch-all to the default avoids a void
        // else branch that Sema can't merge with the other types.
        if (current_else_result == @intFromEnum(Zir.Inst.Ref.void_value) and
            default_pre_instrs.len == 0 and
            cb.default_instrs.len == 0 and
            guards.items.len > 0)
        {
            const last_guard = guards.items[guards.items.len - 1];
            const last_gb = cb.pre_instrs[last_guard.guard_idx].guard_block;

            // If this is the ONLY guard (catch-all), emit body as top-level instructions
            if (guards.items.len == 1) {
                // Emit setup instructions (e.g., match_type)
                for (cb.pre_instrs[common_setup_end..last_guard.guard_idx]) |si| try self.emitInstruction(si);
                // Emit body instructions at top level (flatten any nested
                // guard_blocks so trailing default ops do not run alongside).
                try self.emitFlattenedGuardSequence(last_gb.body);
                // The case_break in the body sets cb.dest
                const result = if (self.local_refs.get(cb.dest)) |vr| try self.materializeValueRef(vr) else @intFromEnum(Zir.Inst.Ref.void_value);
                try self.setLocal(cb.dest, result);
                return;
            }

            // Multiple guards — emit shared setup (index_get for tuple element
            // extraction) before capturing the catch-all body. Guard bodies
            // reference these locals via local_get, so they must be defined
            // before any body is captured. Per-guard setup (match_atom) is
            // emitted later in the reverse loop.
            for (guards.items) |guard| {
                const setup_start = @max(guard.setup_start, common_setup_end);
                for (cb.pre_instrs[setup_start..guard.guard_idx]) |si| {
                    if (std.meta.activeTag(si) == .index_get) {
                        try self.emitInstruction(si);
                    }
                }
            }
            index_get_pre_emitted = true;

            // Capture the catch-all body as default. Flatten nested
            // guard_blocks so that trailing default ops inside the catchall
            // body do not execute alongside the matching inner guard.
            self.beginCapture();
            var catchall_capture_open = true;
            errdefer if (catchall_capture_open) self.discardCapture();

            try self.emitFlattenedGuardSequence(last_gb.body);
            var catchall_len: u32 = 0;
            const catchall_ptr = self.endCapture(&catchall_len);
            catchall_capture_open = false;

            const catchall_result: u32 = if (self.local_refs.get(cb.dest)) |vr| try self.materializeValueRef(vr) else @intFromEnum(Zir.Inst.Ref.void_value);

            try current_else_insts.replaceWithCopy(catchall_ptr[0..catchall_len]);
            current_else_result = catchall_result;

            _ = guards.pop();
        }

        // Process guards in REVERSE order to build nested if-else chain
        var gi = guards.items.len;
        while (gi > 0) {
            gi -= 1;
            const guard = guards.items[gi];
            const gb = cb.pre_instrs[guard.guard_idx].guard_block;
            const setup_start = @max(guard.setup_start, common_setup_end);
            const setup_instrs = cb.pre_instrs[setup_start..guard.guard_idx];

            // Emit per-guard setup. Skip index_get if already pre-emitted
            // before the catchall capture.
            for (setup_instrs) |si| {
                if (index_get_pre_emitted and std.meta.activeTag(si) == .index_get) continue;
                try self.emitInstruction(si);
            }

            // Get the guard condition ref
            const cond_ref = try self.refForLocal(gb.condition);

            // Capture the guard body. Flatten nested guard_blocks (e.g.
            // those produced by inner switch_literal/switch_tag/check_list
            // lowerings) so each inner branch is a proper if-else and
            // trailing default ops do not run unconditionally.
            self.beginCapture();
            var body_capture_open = true;
            errdefer if (body_capture_open) self.discardCapture();

            try self.emitFlattenedGuardSequence(gb.body);
            var body_len: u32 = 0;
            const body_ptr = self.endCapture(&body_len);
            body_capture_open = false;

            // The guard body contains case_break which sets cb.dest via
            // current_case_dest. Use that ref as the body result.
            const body_result: u32 = if (self.local_refs.get(cb.dest)) |vr| try self.materializeValueRef(vr) else void_ref;

            const body_insts = try self.allocator.alloc(u32, body_len);
            @memcpy(body_insts, body_ptr[0..body_len]);

            // Emit: if (guard_cond) { guard_body } else { current_else }
            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                body_insts.ptr,
                @intCast(body_insts.len),
                body_result,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(body_insts);
            current_else_insts.clear();

            if (ref == error_ref) return error.EmitFailed;

            if (gi > 0) {
                // Inner — pop block_inline from body for nesting
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                // Outermost — block_inline stays in function body
                current_else_result = ref;
            }
        }

        // Set the case_block result
        try self.setLocal(cb.dest, current_else_result);
    }

    /// Emit a switch_return as a chain of if-else-bodies.
    /// Each case compares the scrutinee parameter against the literal value
    /// and the body contains the return instruction.
    fn emitSwitchReturn(self: *ZirDriver, sr: ir.SwitchReturn) BuildError!void {
        const scrutinee_ref = try self.refForParamIndex(sr.scrutinee_param);

        if (sr.cases.len == 0) {
            // No cases — just emit the default body
            for (sr.default_instrs) |di| try self.emitInstruction(di);
            // A clause body that already ends in a no-return terminator
            // (e.g. a propagating `ret_raise` emitted because the function
            // now lowers to an error union) must NOT get a trailing `ret`
            // appended after it — that would place a `ret` after a hard exit.
            if (sr.default_result) |dr| {
                if (!self.instructionsEndNoReturnFor(sr.default_instrs)) {
                    const ref = try self.refForLocal(dr);
                    if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
                }
            }
            return;
        }

        // Capture the default body (includes the return). Skip the trailing
        // `ret` when the body already ends in a no-return terminator.
        self.beginCapture();
        var default_capture_open = true;
        errdefer if (default_capture_open) self.discardCapture();

        for (sr.default_instrs) |di| try self.emitInstruction(di);
        if (sr.default_result) |dr| {
            if (!self.instructionsEndNoReturnFor(sr.default_instrs)) {
                const ref = try self.refForLocal(dr);
                if (zir_builder_emit_ret(self.handle, ref) != 0) return error.EmitFailed;
            }
        }
        var default_len: u32 = 0;
        const default_ptr = self.endCapture(&default_len);
        default_capture_open = false;
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);
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
            if (case_val_ref == error_ref) return error.EmitFailed;

            // Emit: scrutinee == case_value
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, scrutinee_ref, case_val_ref);
            if (cond_ref == error_ref) return error.EmitFailed;

            // Capture case body (includes the return). A clause whose body
            // already ends in a no-return terminator — e.g. `raise` lowered to
            // a propagating `ret_raise` now that the function emits an error
            // union — must NOT get a trailing `ret` appended after the hard
            // exit, which Sema would reject as a `ret` after a terminator.
            self.beginCapture();
            var case_capture_open = true;
            errdefer if (case_capture_open) self.discardCapture();

            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            if (case.return_value) |rv| {
                if (!self.instructionsEndNoReturnFor(case.body_instrs)) {
                    const ref = try self.refForLocal(rv);
                    if (zir_builder_emit_ret(self.handle, ref) != 0) {
                        return error.EmitFailed;
                    }
                }
            }
            var case_len: u32 = 0;
            const case_ptr = self.endCapture(&case_len);
            case_capture_open = false;

            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (cond) { case_body_with_ret } else { current_else }
            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                void_ref,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(case_insts);
            current_else_insts.clear();

            if (ref == error_ref) return error.EmitFailed;

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                current_else_result = ref;
            }
        }
    }

    /// Emit a union_switch_return as a chain of if-else-bodies.
    /// Each case checks the active tag via std.meta.activeTag, extracts the
    /// variant payload, binds fields to locals, and returns the result.
    fn emitUnionSwitchReturn(self: *ZirDriver, usr: ir.UnionSwitchReturn) BuildError!void {
        const scrutinee_ref = try self.refForParamIndex(usr.scrutinee_param);
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
        var current_else_insts = CurrentElseInsts.init(self.allocator);
        defer current_else_insts.deinit();
        try current_else_insts.replaceWithEmpty();
        var current_else_result: u32 = void_ref;

        var i = usr.cases.len;
        while (i > 0) {
            i -= 1;
            const case = usr.cases[i];

            // Emit: activeTag(scrutinee) == .variant_name
            const variant_ref = zir_builder_emit_enum_literal(self.handle, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (variant_ref == error_ref) return error.EmitFailed;
            const cmp_tag: u8 = @intFromEnum(Zir.Inst.Tag.cmp_eq);
            const cond_ref = zir_builder_emit_binop(self.handle, cmp_tag, tag_ref, variant_ref);
            if (cond_ref == error_ref) return error.EmitFailed;

            // Capture case body (payload extraction + field bindings + body + return)
            self.beginCapture();
            var case_capture_open = true;
            errdefer if (case_capture_open) self.discardCapture();

            // Extract variant payload: scrutinee.VariantName → struct payload
            const payload_ref = zir_builder_emit_field_val(self.handle, scrutinee_ref, case.variant_name.ptr, @intCast(case.variant_name.len));
            if (payload_ref == error_ref) return error.EmitFailed;

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
                    if (field_ref == error_ref) return error.EmitFailed;
                    try self.setLocal(fb.local_index, field_ref);
                }
            }

            for (case.body_instrs) |bi| try self.emitInstruction(bi);
            // A clause whose body already ends in a no-return terminator (e.g.
            // a propagating `ret_raise` now that the function emits an error
            // union) must NOT get a trailing `ret` after the hard exit.
            if (case.return_value) |rv| {
                if (!self.instructionsEndNoReturnFor(case.body_instrs)) {
                    const ref = try self.refForLocal(rv);
                    if (zir_builder_emit_ret(self.handle, ref) != 0) {
                        return error.EmitFailed;
                    }
                }
            }
            var case_len: u32 = 0;
            const case_ptr = self.endCapture(&case_len);
            case_capture_open = false;

            const case_insts = try self.allocator.alloc(u32, case_len);
            @memcpy(case_insts, case_ptr[0..case_len]);

            // Emit: if (tag == .variant) { case_body_with_ret } else { current_else }
            const else_insts = current_else_insts.get();
            const ref = zir_builder_emit_if_else_bodies(
                self.handle,
                cond_ref,
                case_insts.ptr,
                @intCast(case_insts.len),
                void_ref,
                else_insts.ptr,
                @intCast(else_insts.len),
                current_else_result,
                0,
                0,
            );

            self.allocator.free(case_insts);
            current_else_insts.clear();

            if (ref == error_ref) return error.EmitFailed;

            if (i > 0) {
                const block_idx = zir_builder_pop_body_inst(self.handle);
                try current_else_insts.replaceWithSingle(block_idx);
                current_else_result = ref;
            } else {
                current_else_result = ref;
            }
        }
    }

    /// Emit a `f(nil) / f(t :: T)` optional dispatcher as
    /// `if (param == null) { nil_body; ret nil } else { unwrap; struct_body; ret struct }`.
    /// While emitting the struct branch the param-ref slot for the
    /// optional parameter is replaced with the unwrapped payload ref so
    /// any `param_get(scrutinee_param)` inside the struct body reads the
    /// `T` value, not the `?T` storage.
    fn emitOptionalDispatch(self: *ZirDriver, od: ir.OptionalDispatch) BuildError!void {
        if (od.scrutinee_param >= self.param_refs.items.len) return error.EmitFailed;
        // Loopification: scrutinise the per-iteration slot load, not
        // the entry-scope param ref. See `emitSwitchReturn` for the
        // same redirect.
        const scrutinee_ref = if (self.loopify_slots != null)
            try self.loopifyLoadParam(od.scrutinee_param)
        else
            self.param_refs.items[od.scrutinee_param];
        const is_non_null = zir_builder_emit_is_non_null(self.handle, scrutinee_ref);
        if (is_non_null == error_ref) return error.EmitFailed;

        // then-branch: unwrap, override param ref, emit struct body, ret.
        self.beginCapture();
        var then_capture_open = true;
        errdefer if (then_capture_open) self.discardCapture();

        const payload_ref = zir_builder_emit_optional_payload_unsafe(self.handle, scrutinee_ref);
        if (payload_ref == error_ref) return error.EmitFailed;
        try self.setLocal(od.payload_local, payload_ref);

        {
            const saved_param_ref = self.param_refs.items[od.scrutinee_param];
            self.param_refs.items[od.scrutinee_param] = payload_ref;
            defer self.param_refs.items[od.scrutinee_param] = saved_param_ref;

            for (od.struct_instrs) |bi| try self.emitInstruction(bi);
            // Perceus drop point for owned optional-dispatch payloads.
            // Borrowed optional params are an unwrapped view of the
            // caller-owned `?T`; dropping that payload would decrement the
            // caller's Arc and poison any subsequent use after this
            // function returns. Owned optional params, by contrast, have
            // transferred their refcount unit into this function, so the
            // payload must be released between the struct branch body and
            // the ret unless the return-specialization suppresses it.
            if (od.struct_result) |sr| {
                const ret_ref = try self.refForLocal(sr);
                if (zir_builder_emit_ret(self.handle, ret_ref) != 0) {
                    return error.EmitFailed;
                }
            }
        }
        var then_len: u32 = 0;
        const then_ptr = self.endCapture(&then_len);
        then_capture_open = false;
        const then_insts = try self.allocator.alloc(u32, then_len);
        defer self.allocator.free(then_insts);
        @memcpy(then_insts, then_ptr[0..then_len]);

        // else-branch: emit nil body, ret.
        self.beginCapture();
        var else_capture_open = true;
        errdefer if (else_capture_open) self.discardCapture();

        for (od.nil_instrs) |bi| try self.emitInstruction(bi);
        if (od.nil_result) |nr| {
            const ret_ref = try self.refForLocal(nr);
            if (zir_builder_emit_ret(self.handle, ret_ref) != 0) {
                return error.EmitFailed;
            }
        }
        var else_len: u32 = 0;
        const else_ptr = self.endCapture(&else_len);
        else_capture_open = false;
        const else_insts = try self.allocator.alloc(u32, else_len);
        defer self.allocator.free(else_insts);
        @memcpy(else_insts, else_ptr[0..else_len]);

        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
        const result = zir_builder_emit_if_else_bodies(
            self.handle,
            is_non_null,
            then_insts.ptr,
            @intCast(then_insts.len),
            void_ref,
            else_insts.ptr,
            @intCast(else_insts.len),
            void_ref,
            0,
            0,
        );
        if (result == error_ref) return error.EmitFailed;
    }

    /// Lower a `union_switch` IR instruction to a single comptime-safe
    /// `switch_block` (one prong per variant, plus an optional `else`
    /// prong). This is the SINGLE lowering path for every tagged-union
    /// `case`. Sema only analyzes the active prong of a `switch_block` over
    /// a comptime-known scrutinee, so this never touches an inactive
    /// variant's payload field — fixing the comptime-fold UB that the old
    /// `match_variant_tag` + `guard_block` + `variant_payload_get` chain hit
    /// whenever more than one arm bound a payload.
    ///
    /// Mechanism: emit a `value_placeholder` whose Ref is the payload
    /// capture. Every payload-bearing prong binds its payload local to this
    /// placeholder Ref, so prong body instructions that read the payload
    /// resolve to the captured value when Sema maps the placeholder. Each
    /// prong body is pre-emitted (body_tracking OFF), its instruction
    /// indices collected, and its result Ref recorded. `addSwitchBlock`
    /// then writes the canonical SwitchBlock extra data.
    fn emitUnionSwitch(self: *ZirDriver, us: ir.UnionSwitch) BuildError!void {
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
        const scrutinee_ref = try self.refForLocal(us.scrutinee);

        if (us.cases.len == 0) return;

        // A single value_placeholder serves as the payload capture for ALL
        // capturing prongs. It is never analyzed in any body; Sema records
        // it in the SwitchBlock's payload_capture_placeholder slot and maps
        // the active prong's captured payload onto it.
        const placeholder = zir_builder_emit_value_placeholder(self.handle);
        if (placeholder == 0xFFFFFFFF) return error.EmitFailed;
        const placeholder_ref = @intFromEnum(Zir.Inst.Index.toRef(@enumFromInt(placeholder)));

        var names_ptrs: std.ArrayListUnmanaged([*]const u8) = .empty;
        defer names_ptrs.deinit(self.allocator);
        var names_lens: std.ArrayListUnmanaged(u32) = .empty;
        defer names_lens.deinit(self.allocator);
        var captures: std.ArrayListUnmanaged(u32) = .empty;
        defer captures.deinit(self.allocator);
        var body_lens: std.ArrayListUnmanaged(u32) = .empty;
        defer body_lens.deinit(self.allocator);
        var body_results: std.ArrayListUnmanaged(u32) = .empty;
        defer body_results.deinit(self.allocator);
        var all_body_insts: std.ArrayListUnmanaged(u32) = .empty;
        defer all_body_insts.deinit(self.allocator);
        // Per-prong `noreturn` flags. A prong whose body already terminates
        // with a `ret`/`unreachable` (e.g. the `?` operator's early-return
        // `Error` prong) must NOT get a synthesized trailing `break`, or the
        // dead `br` dangles and trips AIR Liveness. The fork's
        // `addSwitchBlock` honors these flags.
        var noreturn_flags: std.ArrayListUnmanaged(u32) = .empty;
        defer noreturn_flags.deinit(self.allocator);

        // Emit one scalar prong per variant.
        for (us.cases) |case| {
            const has_capture = case.field_bindings.len > 0;

            try names_ptrs.append(self.allocator, case.variant_name.ptr);
            try names_lens.append(self.allocator, @intCast(case.variant_name.len));
            try captures.append(self.allocator, @intFromBool(has_capture));
            try noreturn_flags.append(self.allocator, @intFromBool(instructionsEndNoReturn(case.body_instrs)));

            // Bind every payload local to the capture placeholder so prong
            // body reads of the payload resolve to the captured value. A
            // whole-payload bind (single FieldBinding with empty field_name)
            // maps the local directly to the placeholder.
            for (case.field_bindings) |fb| {
                try self.setLocal(fb.local_index, placeholder_ref);
            }

            const prong = try self.emitSwitchProngBody(
                case.body_instrs,
                case.return_value,
                us.dest,
                &all_body_insts,
            );
            try body_lens.append(self.allocator, prong.body_len);
            try body_results.append(self.allocator, prong.result_ref);
        }

        // Optional else prong (the `_` catch-all / decision-tree default).
        var else_len: u32 = 0;
        var else_result: u32 = void_ref;
        var else_is_noreturn: u32 = 0;
        if (us.has_else) {
            else_is_noreturn = @intFromBool(instructionsEndNoReturn(us.else_instrs));
            const prong = try self.emitSwitchProngBody(
                us.else_instrs,
                us.else_result,
                us.dest,
                &all_body_insts,
            );
            else_len = prong.body_len;
            else_result = prong.result_ref;
        }

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
            @intFromBool(us.has_else),
            else_len,
            else_result,
            placeholder,
            noreturn_flags.items.ptr,
            else_is_noreturn,
        );
        if (result == 0xFFFFFFFFFFFFFFFF) return error.EmitFailed;

        const switch_ref: u32 = @truncate(result);
        try self.setLocal(us.dest, switch_ref);
    }

    const SwitchProngEmit = struct {
        body_len: u32,
        result_ref: u32,
    };

    /// Emit one switch prong / else body with body_tracking OFF, appending
    /// the body's instruction indices to `out_insts`. Returns the number of
    /// instructions emitted and the prong's result Ref.
    ///
    /// The prong result is resolved one of two ways:
    ///   * if `explicit_result` is non-null, that local's Ref is the result
    ///     (the simple `Variant(v) -> expr` arm shape — the decision-tree
    ///     leaf records the arm body value as `return_value`);
    ///   * otherwise the body's `case_break` instructions write the result to
    ///     `case_dest` (the `union_switch.dest` local), exactly as
    ///     `emitFlatCaseBlock` does, so nested guards / sub-patterns inside a
    ///     prong body keep working. The result Ref is read from `case_dest`
    ///     after the body.
    ///
    /// Every body instruction — including `call_named` — is emitted through
    /// the normal `emitInstruction` path. The `call_named` handler resolves
    /// its target through the Zap-side program table (`findFunctionByName`)
    /// and `@import`-based cross-struct calls, neither of which depends on
    /// ZIR lexical scope, so a call works identically inside a switch prong
    /// body. (An earlier revision pre-resolved calls to a parent-scope
    /// `decl_ref` and re-emitted them as `call_ref` inside the prong; that
    /// crossed the prong's AIR body boundary and produced a malformed
    /// coercion `ty_op` that tripped AIR Liveness whenever a prong body
    /// contained a call.)
    ///
    /// The prong body instruction list is collected through the builder's
    /// `begin_capture`/`end_capture` mechanism rather than a naive contiguous
    /// `inst_count` range. A `call` ZIR instruction emits nested arg
    /// sub-bodies (`break_inline` per argument) that are NOT top-level body
    /// instructions — they belong to the call's own arg bodies, referenced by
    /// index from the `call` payload. The capture mechanism records only the
    /// top-level (would-be-body) instruction indices, excluding those nested
    /// sub-body insts; a contiguous range would wrongly fold them into the
    /// prong body and desync Sema's switch-case body bounds, manifesting as a
    /// wrong-active-union-field (`ty_op`) panic in AIR Liveness whenever a
    /// prong body contained a call.
    fn emitSwitchProngBody(
        self: *ZirDriver,
        instrs: []const ir.Instruction,
        explicit_result: ?ir.LocalId,
        case_dest: ir.LocalId,
        out_insts: *std.ArrayListUnmanaged(u32),
    ) BuildError!SwitchProngEmit {
        const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);
        const saved_case_dest = self.current_case_dest;
        self.current_case_dest = case_dest;
        defer self.current_case_dest = saved_case_dest;

        self.beginCapture();
        var capture_open = true;
        errdefer if (capture_open) self.discardCapture();

        for (instrs) |bi| {
            try self.emitInstruction(bi);
        }
        var captured_len: u32 = 0;
        const captured_ptr = self.endCapture(&captured_len);
        capture_open = false;

        const body_len = captured_len;
        for (captured_ptr[0..captured_len]) |inst_i| {
            try out_insts.append(self.allocator, inst_i);
        }

        const result_ref: u32 = if (explicit_result) |rv|
            try self.refForValueLocal(rv)
        else if (self.local_refs.get(case_dest)) |vr|
            try self.materializeValueRef(vr)
        else
            void_ref;

        return .{ .body_len = body_len, .result_ref = result_ref };
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
    InvalidMainReturnType,
    UnknownLocal,
    ZirInjectionFailed,
    OutOfMemory,
    /// Phase 0 — DWARF foundation: two emitted functions hashed to
    /// the same Zig-mangled symbol name. Surfaces a monomorphization
    /// bug; the symbol table cannot be made reversible until the
    /// collision is fixed.
    DuplicateMangledName,
};

pub fn buildAndInject(
    allocator: Allocator,
    program: ir.Program,
    compilation_ctx: *ZirContext,
    runtime_path: ?[:0]const u8,
    lib_mode: bool,
    builder_entry: ?[]const u8,
    /// P2-J2 — the resolved `runtime_concurrency` gate. Forwarded to
    /// `ZirDriver.runtime_concurrency`; ON reroutes executable entry
    /// emission through the root-process bootstrap (field doc).
    runtime_concurrency: bool,
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext,
    arc_ownership: ?*const @import("arc_liveness.zig").ProgramArcOwnership,
    declared_caps: u64,
    progress: ?*progress_mod.Reporter,
    /// Phase 1.5 — per-optimize-mode arithmetic-overflow policy. True for
    /// Debug / ReleaseSafe (overflow traps → `arithmetic_error`), false
    /// for ReleaseFast / ReleaseSmall (overflow wraps). Forwarded to
    /// `ZirDriver.arithmetic_overflow_traps`.
    arithmetic_overflow_traps: bool,
    /// Phase 0 — DWARF foundation: when non-null, the encoded
    /// reversible mangled-symbol ↔ Zap-symbol side table is
    /// written here on success. Caller takes ownership of the
    /// returned slice (alloc'd from `allocator`) and frees it
    /// after writing the sidecar / embedding it. `null` means the
    /// caller does not want a table (e.g. the legacy test harness
    /// or a builder run that emitted no functions); the driver
    /// still records mappings, but they are discarded.
    out_symbol_table: ?*?[]u8,
) BuildError!void {
    // Register the runtime struct if a path was provided.
    if (progress) |reporter| reporter.stage("ZIR: registering runtime", .{});
    if (runtime_path) |rpath| {
        if (zir_compilation_add_struct(compilation_ctx, "zap_runtime", rpath) != 0) {
            return error.ZirInjectionFailed;
        }
    }

    var driver = try ZirDriver.init(allocator);
    driver.lib_mode = lib_mode;
    driver.builder_entry = builder_entry;
    driver.runtime_concurrency = runtime_concurrency;
    driver.analysis_context = analysis_context;
    driver.arc_ownership = arc_ownership;
    driver.declared_caps = declared_caps;
    driver.compilation_ctx = compilation_ctx;
    driver.progress = progress;
    driver.arithmetic_overflow_traps = arithmetic_overflow_traps;

    driver.buildProgram(program) catch |err| {
        driver.deinit(); // destroy builder on error path
        return err;
    };

    // Encode the symbol table BEFORE handing the builder to the
    // injection step (which frees it). Failure to encode is fatal
    // for the build — a duplicate mangled name signals a real bug
    // in monomorphization. The caller may pass null to opt out.
    if (out_symbol_table) |out_ptr| {
        const encoded = driver.encodeSymbolTable() catch |err| {
            driver.deinit();
            return err;
        };
        out_ptr.* = encoded;
    }

    // zir_builder_inject consumes the builder handle (frees it internally),
    // so we must NOT call zir_builder_destroy afterward.
    if (progress) |reporter| reporter.stage("ZIR: injecting modules", .{});
    const result = zir_builder_inject(driver.handle, compilation_ctx);

    if (result != 0) {
        driver.deinit();
        return error.ZirInjectionFailed;
    }
    // Only clean up Zap-side state — the C ABI consumed the builder handle.
    driver.deinitAfterHandleConsumed();
}

pub fn buildAndInjectSelected(
    allocator: Allocator,
    program: ir.Program,
    compilation_ctx: *ZirContext,
    lib_mode: bool,
    builder_entry: ?[]const u8,
    /// P2-J2 — the resolved `runtime_concurrency` gate (see
    /// `buildAndInject`). Forwarded to `ZirDriver.runtime_concurrency`.
    runtime_concurrency: bool,
    analysis_context: ?*const @import("escape_lattice.zig").AnalysisContext,
    arc_ownership: ?*const @import("arc_liveness.zig").ProgramArcOwnership,
    declared_caps: u64,
    progress: ?*progress_mod.Reporter,
    /// Phase 1.5 — per-optimize-mode arithmetic-overflow policy (see
    /// `buildAndInject`). Forwarded to `ZirDriver.arithmetic_overflow_traps`.
    arithmetic_overflow_traps: bool,
    selected_structs: []const []const u8,
    include_root: bool,
    /// Phase 0 — DWARF foundation (Gap B): when non-null, the encoded
    /// reversible mangled-symbol ↔ Zap-symbol side table for the
    /// freshly-emitted *selected* structs (plus the root when
    /// `include_root` is true) is written here on success. The
    /// resulting blob is a strict subset of the full symbol set — the
    /// caller is responsible for adopting unchanged-struct entries
    /// from the prior sidecar via
    /// `zap_symbol_table.Builder.adoptFromSidecar` before encoding
    /// the merged result. `null` means the caller does not want a
    /// table (e.g. lib/obj outputs that have no sidecar).
    out_symbol_table: ?*?[]u8,
) BuildError!void {
    var driver = try ZirDriver.init(allocator);
    driver.lib_mode = lib_mode;
    driver.builder_entry = builder_entry;
    driver.runtime_concurrency = runtime_concurrency;
    driver.analysis_context = analysis_context;
    driver.arc_ownership = arc_ownership;
    driver.declared_caps = declared_caps;
    driver.compilation_ctx = compilation_ctx;
    driver.progress = progress;
    driver.arithmetic_overflow_traps = arithmetic_overflow_traps;
    driver.selected_structs = selected_structs;
    driver.selected_emit_root = include_root;

    driver.buildProgram(program) catch |err| {
        driver.deinit();
        return err;
    };

    // Encode the symbol table BEFORE the injection step (which frees
    // the driver's collected entries on the `include_root` path) so
    // the caller can merge it with the prior sidecar baseline. A
    // duplicate-mangled-name collision inside the selection is still
    // fatal — that signals a real monomorphization bug.
    if (out_symbol_table) |out_ptr| {
        const encoded = driver.encodeSymbolTable() catch |err| {
            driver.deinit();
            return err;
        };
        out_ptr.* = encoded;
    }

    if (include_root) {
        if (progress) |reporter| reporter.stage("ZIR: injecting selected modules and root", .{});
        const result = zir_builder_inject(driver.handle, compilation_ctx);
        if (result != 0) {
            driver.deinit();
            return error.ZirInjectionFailed;
        }
        driver.deinitAfterHandleConsumed();
    } else {
        if (progress) |reporter| reporter.stage("ZIR: injecting selected modules", .{});
        driver.deinit();
    }
}

test "mapBinopTag: per-mode integer overflow policy (checked vs wrapping)" {
    // Phase 1.5. In safe modes (overflow_traps == true) integer add/sub/mul
    // use the checked tags; in fast modes they use the wrapping tags.
    // Floats always use the plain tag regardless of mode.
    const add_checked = mapBinopTag(.add, .i64, true).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.add), add_checked);
    const add_wrap = mapBinopTag(.add, .i64, false).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.addwrap), add_wrap);

    const sub_checked = mapBinopTag(.sub, .i64, true).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.sub), sub_checked);
    const sub_wrap = mapBinopTag(.sub, .i64, false).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.subwrap), sub_wrap);

    const mul_checked = mapBinopTag(.mul, .i64, true).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.mul), mul_checked);
    const mul_wrap = mapBinopTag(.mul, .i64, false).?;
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.mulwrap), mul_wrap);

    // Floats use the plain tag in BOTH modes — the overflow policy is
    // integer-only.
    try std.testing.expectEqual(
        @intFromEnum(Zir.Inst.Tag.add),
        mapBinopTag(.add, .f64, true).?,
    );
    try std.testing.expectEqual(
        @intFromEnum(Zir.Inst.Tag.add),
        mapBinopTag(.add, .f64, false).?,
    );
}

test "mapReturnType routes optional returns through complex ret_ty emission" {
    const optional_i64_inner = try std.testing.allocator.create(ir.ZigType);
    defer std.testing.allocator.destroy(optional_i64_inner);
    optional_i64_inner.* = .i64;
    try std.testing.expectEqual(@as(u32, 0), mapReturnType(.{ .optional = optional_i64_inner }));

    const optional_string_inner = try std.testing.allocator.create(ir.ZigType);
    defer std.testing.allocator.destroy(optional_string_inner);
    optional_string_inner.* = .string;
    try std.testing.expectEqual(@as(u32, 0), mapReturnType(.{ .optional = optional_string_inner }));
}

fn p4j2TestFunction(id: ir.FunctionId, name: []const u8, local_name: []const u8, struct_name: ?[]const u8) ir.Function {
    return .{
        .id = id,
        .name = name,
        .struct_name = struct_name,
        .local_name = local_name,
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
    };
}

fn exerciseDeduplicateFunctionsAllocationFailures(allocator: Allocator) !void {
    const functions = [_]ir.Function{
        p4j2TestFunction(1, "first", "dup__0", null),
        p4j2TestFunction(2, "second", "second__0", null),
        p4j2TestFunction(3, "replacement", "dup__0", null),
        p4j2TestFunction(4, "fallback_name", "", null),
    };

    var deduped = try ZirDriver.deduplicateFunctions(allocator, &functions);
    defer deduped.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), deduped.items.len);
    try std.testing.expectEqual(@as(ir.FunctionId, 2), deduped.items[0].id);
    try std.testing.expectEqual(@as(ir.FunctionId, 3), deduped.items[1].id);
    try std.testing.expectEqual(@as(ir.FunctionId, 4), deduped.items[2].id);
}

test "ZirDriver.deduplicateFunctions keeps last function and cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeduplicateFunctionsAllocationFailures,
        .{},
    );
}

fn exerciseBuildProgramFunctionGroupsAllocationFailures(allocator: Allocator) !void {
    const functions = [_]ir.Function{
        p4j2TestFunction(1, "root_old", "root__0", null),
        p4j2TestFunction(2, "root_new", "root__0", null),
        p4j2TestFunction(3, "Math.old", "dup__0", "Math"),
        p4j2TestFunction(4, "Math.unique", "unique__0", "Math"),
        p4j2TestFunction(5, "Math.new", "dup__0", "Math"),
        p4j2TestFunction(6, "Parent_Child.member", "member__0", "Parent_Child"),
    };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    var groups = try ZirDriver.buildProgramFunctionGroups(allocator, program);
    defer groups.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), groups.root_funcs.items.len);
    try std.testing.expectEqual(@as(ir.FunctionId, 2), groups.root_funcs.items[0].id);
    try std.testing.expect(groups.all_struct_names.contains("Math"));
    try std.testing.expect(groups.all_struct_names.contains("Parent_Child"));

    const math_functions = groups.struct_funcs.get("Math") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), math_functions.items.len);
    try std.testing.expectEqual(@as(ir.FunctionId, 4), math_functions.items[0].id);
    try std.testing.expectEqual(@as(ir.FunctionId, 5), math_functions.items[1].id);

    const child_functions = groups.struct_funcs.get("Parent_Child") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), child_functions.items.len);
    try std.testing.expectEqual(@as(ir.FunctionId, 6), child_functions.items[0].id);
}

test "ZirDriver buildProgram grouping cleans up nested lists on allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseBuildProgramFunctionGroupsAllocationFailures,
        .{},
    );
}

test "ZIR naming helpers do not use semantic fallback literals" {
    const source = @embedFile("zir_builder.zig");
    const catch_zero = "catch " ++ "\"0\"";
    const catch_closure_env = "catch " ++ "\"__ClosureEnv\"";

    try std.testing.expect(std.mem.indexOf(u8, source, catch_zero) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, catch_closure_env) == null);
}

test "indexFieldName formats max u32 without fallback" {
    var name_buf: [max_index_field_name_len]u8 = undefined;
    const name = indexFieldName(std.math.maxInt(u32), &name_buf);
    const name_len: usize = @intCast(name.len);

    try std.testing.expectEqualStrings("4294967295", name.ptr[0..name_len]);
}

test "IndexFieldNameBatch keeps dynamic names stable and propagates allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        IndexFieldNameBatch.init(failing_allocator.allocator(), index_field_names.len + 1),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);

    var batch = try IndexFieldNameBatch.init(std.testing.allocator, index_field_names.len + 2);
    defer batch.deinit();

    var dynamic_names: [2]IndexFieldName = undefined;
    for (0..index_field_names.len + dynamic_names.len) |i| {
        const name = batch.get(i);
        if (i >= index_field_names.len) dynamic_names[i - index_field_names.len] = name;
    }

    const first_len: usize = @intCast(dynamic_names[0].len);
    const second_len: usize = @intCast(dynamic_names[1].len);
    try std.testing.expectEqualStrings("32", dynamic_names[0].ptr[0..first_len]);
    try std.testing.expectEqualStrings("33", dynamic_names[1].ptr[0..second_len]);
}

test "closureEnvTypeName propagates buffer exhaustion" {
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };

    var name_buf: [64]u8 = undefined;
    const name = try driver.closureEnvTypeName(42, &name_buf);
    try std.testing.expectEqualStrings("__ClosureEnv_42", name);

    var too_small_buf: [4]u8 = undefined;
    try std.testing.expectError(error.EmitFailed, driver.closureEnvTypeName(42, &too_small_buf));
}

test "ZirDriver local ref materialization propagates emission failures" {
    const source = @embedFile("zir_builder.zig");
    const ref_for_local = "self." ++ "refForLocal(";
    const ref_for_value_local = "self." ++ "refForValueLocal(";
    const materialize_value_ref = "self." ++ "materializeValueRef(";
    const catch_token = " " ++ "catch" ++ " ";

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const materializes_local =
            std.mem.indexOf(u8, line, ref_for_local) != null or
            std.mem.indexOf(u8, line, ref_for_value_local) != null or
            std.mem.indexOf(u8, line, materialize_value_ref) != null;
        if (!materializes_local) continue;

        if (std.mem.indexOf(u8, line, catch_token) == null) continue;
        if (std.mem.indexOf(u8, line, "catch return error.EmitFailed") != null) continue;
        if (std.mem.indexOf(u8, line, "catch |err|") != null) {
            if (std.mem.indexOf(u8, line, "return err;") != null) continue;

            var found_err_return = false;
            var remaining_lookahead: usize = 12;
            while (remaining_lookahead > 0) : (remaining_lookahead -= 1) {
                const catch_line = lines.next() orelse break;
                if (std.mem.indexOf(u8, catch_line, "return err;") != null) {
                    found_err_return = true;
                    break;
                }
            }
            try std.testing.expect(found_err_return);
            continue;
        }

        try std.testing.expect(false);
    }
}

test "ZirDriver nested type emission propagates emitted-name allocation failure at source level" {
    const source = @embedFile("zir_builder.zig");
    const start = std.mem.indexOf(u8, source, "fn emitNestedTypeDecl") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, source, start, "fn emitRootFields") orelse return error.TestUnexpectedResult;
    const nested_source = source[start..end];

    try std.testing.expect(std.mem.indexOf(u8, nested_source, "fn emitNestedTypeDecl(self: *ZirDriver, type_def: ir.TypeDef, emitted: *std.StringHashMap(void)) !void") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_source, "try emitted.put(short_name, {});") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested_source, "emitted.put(short_name, {}) catch return") == null);
}

test "ZirDriver monomorphized impl lookup distinguishes allocation failure from semantic absence" {
    const matching_function = ir.Function{
        .id = 1,
        .name = "List__member?__2",
        .struct_name = "Caller",
        .local_name = "List_member?__i64__2",
        .scope_id = 0,
        .arity = 2,
        .params = &.{},
        .return_type = .bool_type,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
    };
    const unrelated_function = ir.Function{
        .id = 2,
        .name = "Map__member?__2",
        .struct_name = "Caller",
        .local_name = "Map_member?__i64__2",
        .scope_id = 0,
        .arity = 2,
        .params = &.{},
        .return_type = .bool_type,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
    };
    const functions = [_]ir.Function{ unrelated_function, matching_function };
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = program,
    };
    defer driver.deinitOwnedState();

    const found = (try driver.findMonomorphizedImplFor("Caller", "List__member?__2")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ir.FunctionId, 1), found.id);

    const semantic_missing = try driver.findMonomorphizedImplFor("Caller", "Set__member?__2");
    try std.testing.expectEqual(@as(?ir.Function, null), semantic_missing);

    const other_namespace_function = ir.Function{
        .id = 3,
        .name = "List__member?__2",
        .struct_name = "Other",
        .local_name = "List_member?__i64__2",
        .scope_id = 0,
        .arity = 2,
        .params = &.{},
        .return_type = .bool_type,
        .body = &.{},
        .is_closure = false,
        .captures = &.{},
    };
    const other_namespace_functions = [_]ir.Function{other_namespace_function};
    const other_namespace_program = ir.Program{
        .functions = &other_namespace_functions,
        .type_defs = &.{},
        .entry = null,
    };
    var no_namespace_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var no_namespace_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = no_namespace_allocator.allocator(),
        .program = other_namespace_program,
    };
    defer no_namespace_driver.deinitOwnedState();

    const no_namespace_match = try no_namespace_driver.findMonomorphizedImplFor("Caller", "List__member?__2");
    try std.testing.expectEqual(@as(?ir.Function, null), no_namespace_match);
    try std.testing.expect(!no_namespace_allocator.has_induced_failure);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failing_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = failing_allocator.allocator(),
        .program = program,
    };
    defer failing_driver.deinitOwnedState();

    try std.testing.expectError(
        error.OutOfMemory,
        failing_driver.findMonomorphizedImplFor("Caller", "List__member?__2"),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "ZirDriver tuple type emission helpers propagate failures at source level" {
    const source = @embedFile("zir_builder.zig");
    const start = std.mem.indexOf(u8, source, "fn mapTupleElementType") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, source, start, "fn setLocal") orelse return error.TestUnexpectedResult;
    const helper_source = source[start..end];

    try std.testing.expect(std.mem.indexOf(u8, helper_source, "fn mapTupleElementType(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "fn collectNestedTupleTypes(self: *ZirDriver, zig_type: ir.ZigType) BuildError!void") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "fn emitBodyLocalTupleType(self: *ZirDriver, zig_type: ir.ZigType) BuildError!u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "try self.pending_ret_ty_untracked.append") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "try inner_refs.append(self.allocator, try self.mapTupleElementType(inner_elem))") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "try self.tuple_type_stack.append") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "try inner_refs.append(self.allocator, try self.emitBodyLocalTupleType(inner_elem))") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "return error.EmitFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "catch return 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "catch {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "catch 0") == null);
}

test "ZirDriver recursive struct boxing helpers propagate allocation failures at source level" {
    const source = @embedFile("zir_builder.zig");
    const start = std.mem.indexOf(u8, source, "fn indirectFieldType") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, source, start, "fn findEnumDef") orelse return error.TestUnexpectedResult;
    const helper_source = source[start..end];

    try std.testing.expect(std.mem.indexOf(u8, helper_source, "fn indirectFieldType(self: *ZirDriver, t: ir.ZigType) BuildError!ir.ZigType") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "fn boxRecursiveZigType(self: *ZirDriver, t: ir.ZigType) BuildError!ir.ZigType") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "page_allocator.create(ir.ZigType)") == null);
    try std.testing.expect(std.mem.indexOf(u8, helper_source, "catch break :blk t") == null);
}

test "ZirDriver.indirectFieldType propagates OutOfMemory instead of leaving recursive fields unboxed" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = failing_allocator.allocator(),
        .program = null,
    };
    defer driver.deinitOwnedState();

    try std.testing.expectError(error.OutOfMemory, driver.indirectFieldType(.{ .struct_ref = "Tree" }));
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "ZirDriver.boxRecursiveZigType boxes recursive structs and propagates OutOfMemory" {
    const recursive_field_type: ir.ZigType = .{ .struct_ref = "Tree" };
    const recursive_fields = [_]ir.StructFieldDef{
        .{ .name = "left", .type_expr = recursive_field_type, .storage = .indirect },
    };
    const recursive_type_defs = [_]ir.TypeDef{
        .{ .name = "Tree", .kind = .{ .struct_def = .{ .fields = &recursive_fields } } },
    };
    const recursive_program = ir.Program{
        .functions = &.{},
        .type_defs = &recursive_type_defs,
        .entry = null,
    };

    var normal_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = recursive_program,
    };
    defer normal_driver.deinitOwnedState();

    const boxed_struct = try normal_driver.boxRecursiveZigType(.{ .struct_ref = "Tree" });
    try std.testing.expect(boxed_struct == .ptr);
    try std.testing.expect(boxed_struct.ptr.* == .struct_ref);
    try std.testing.expectEqualStrings("Tree", boxed_struct.ptr.struct_ref);

    const optional_inner = try std.testing.allocator.create(ir.ZigType);
    defer std.testing.allocator.destroy(optional_inner);
    optional_inner.* = .{ .struct_ref = "Tree" };
    const boxed_optional = try normal_driver.boxRecursiveZigType(.{ .optional = optional_inner });
    try std.testing.expect(boxed_optional == .optional);
    try std.testing.expect(boxed_optional.optional.* == .ptr);
    try std.testing.expect(boxed_optional.optional.ptr.* == .struct_ref);
    try std.testing.expectEqualStrings("Tree", boxed_optional.optional.ptr.struct_ref);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failing_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = failing_allocator.allocator(),
        .program = recursive_program,
    };
    defer failing_driver.deinitOwnedState();

    try std.testing.expectError(error.OutOfMemory, failing_driver.boxRecursiveZigType(.{ .struct_ref = "Tree" }));
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "ZirDriver.collectNestedTupleTypes preserves DFS post-order" {
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer driver.tuple_type_stack.deinit(driver.allocator);

    const inner_elements = [_]ir.ZigType{ .i64, .string };
    const outer_elements = [_]ir.ZigType{
        .bool_type,
        .{ .tuple = &inner_elements },
    };
    const tuple_type: ir.ZigType = .{ .tuple = &outer_elements };

    try driver.collectNestedTupleTypes(tuple_type);

    try std.testing.expectEqual(@as(usize, 2), driver.tuple_type_stack.items.len);
    try std.testing.expect(driver.tuple_type_stack.items[0] == .tuple);
    try std.testing.expect(driver.tuple_type_stack.items[1] == .tuple);
    try std.testing.expectEqual(@as(usize, inner_elements.len), driver.tuple_type_stack.items[0].tuple.len);
    try std.testing.expectEqual(@as(usize, outer_elements.len), driver.tuple_type_stack.items[1].tuple.len);
}

test "ZirDriver.collectNestedTupleTypes propagates stack allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = failing_allocator.allocator(),
        .program = null,
    };
    defer driver.tuple_type_stack.deinit(driver.allocator);

    const tuple_elements = [_]ir.ZigType{.i64};
    const tuple_type: ir.ZigType = .{ .tuple = &tuple_elements };

    try std.testing.expectError(error.OutOfMemory, driver.collectNestedTupleTypes(tuple_type));
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), driver.tuple_type_stack.items.len);
}

test "closure lowering helper distinguishes immediate and stack tiers" {
    const lattice = @import("escape_lattice.zig");

    const immediate = ZirDriver.closure_lowering_for_tier(.immediate_invocation, 1);
    try std.testing.expectEqual(lattice.ClosureEnvTier.immediate_invocation, immediate.tier);
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

test "Phase 7e: ZIR entry paths call memory startup prologue" {
    // The regular `zig build test` target does not link the Zig fork's
    // ZIR builder C-ABI symbols, and `zig build zir-test` is not used
    // here. Pin the source-level emission contract instead: both
    // generated entry surfaces must call the shared startup-prologue
    // helper, and the builder entry must do so before
    // BuilderRuntime.buildEnvFromArgv().
    const source = @embedFile("zir_builder.zig");

    var builder_call_buf: [128]u8 = undefined;
    const builder_call = try std.fmt.bufPrint(
        &builder_call_buf,
        "try self.{s}(rt);",
        .{"emitMemoryStartupForEntryFromRuntime"},
    );
    const builder_call_index = std.mem.indexOf(u8, source, builder_call) orelse return error.TestUnexpectedResult;
    const build_env_index = std.mem.indexOf(u8, source, "buildEnvFromArgv") orelse return error.TestUnexpectedResult;
    try std.testing.expect(builder_call_index < build_env_index);

    var main_call_buf: [128]u8 = undefined;
    const main_call = try std.fmt.bufPrint(
        &main_call_buf,
        "try self.{s}();",
        .{"emitMemoryStartupForEntry"},
    );
    const main_gate_index = std.mem.indexOf(u8, source, "if (is_main) {") orelse return error.TestUnexpectedResult;
    const main_call_index = std.mem.indexOfPos(u8, source, main_gate_index, main_call) orelse return error.TestUnexpectedResult;
    const try_variant_index = std.mem.indexOfPos(u8, source, main_gate_index, "__try variants return optionals") orelse return error.TestUnexpectedResult;
    try std.testing.expect(main_call_index < try_variant_index);
}

test "findClosureTargetInInstrs follows local aliases" {
    const captures = [_]ir.LocalId{7};
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 4, .function = 9, .captures = &captures } },
        .{ .local_set = .{ .dest = 5, .value = 4 } },
        .{ .share_value = .{ .dest = 6, .source = 5 } },
    };

    const target = (try ZirDriver.findClosureTargetInInstrs(std.testing.allocator, &instrs, 6)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ir.FunctionId, 9), target.function_id);
    try std.testing.expectEqual(@as(usize, 1), target.captures.len);
    try std.testing.expectEqual(@as(ir.LocalId, 7), target.captures[0]);
}

test "findClosureTargetInInstrs resolves aliases beyond inline capacity" {
    const allocator = std.testing.allocator;
    const captures = [_]ir.LocalId{7};
    var instrs: std.ArrayListUnmanaged(ir.Instruction) = .empty;
    defer instrs.deinit(allocator);

    try instrs.append(allocator, .{ .make_closure = .{ .dest = 0, .function = 9, .captures = &captures } });
    for (1..72) |local_index| {
        try instrs.append(allocator, .{ .local_set = .{
            .dest = @intCast(local_index),
            .value = @intCast(local_index - 1),
        } });
    }

    const target = (try ZirDriver.findClosureTargetInInstrs(allocator, instrs.items, 71)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(ir.FunctionId, 9), target.function_id);
    try std.testing.expectEqual(@as(usize, 1), target.captures.len);
    try std.testing.expectEqual(@as(ir.LocalId, 7), target.captures[0]);
}

test "findClosureTargetInInstrs propagates visited allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const captures = [_]ir.LocalId{7};
    const instrs = [_]ir.Instruction{
        .{ .make_closure = .{ .dest = 4, .function = 9, .captures = &captures } },
    };

    try std.testing.expectError(
        error.OutOfMemory,
        ZirDriver.findClosureTargetInInstrs(failing_allocator.allocator(), &instrs, 4),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "encoded type-name resolver rejects unknown nested list elements" {
    try std.testing.expectEqual(@as(?u32, null), ZirDriver.encodedNameToTypeRef("not_a_type"));
    try std.testing.expect(ZirDriver.encodedNameToTypeRef("i64") != null);
    try std.testing.expect(ZirDriver.encodedNameToTypeRef("str") != null);
}

test "ZirDriver container type-ref helpers keep emission errors distinct from semantic null" {
    const source = @embedFile("zir_builder.zig");
    const container_start = std.mem.indexOf(u8, source, "fn emitContainerElementTypeRef") orelse return error.TestUnexpectedResult;
    const container_end = std.mem.indexOfPos(u8, source, container_start, "/// Emit a comptime generic container instantiation.") orelse return error.TestUnexpectedResult;
    const container_source = source[container_start..container_end];

    try std.testing.expect(std.mem.indexOf(u8, container_source, "fn emitContainerElementTypeRef(self: *ZirDriver, zig_type: ir.ZigType) BuildError!?u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "catch return null") == null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "== error_ref) return null") == null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "try self.emitStructTypeRef(name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "try self.emitGenericContainerRef(\"List\", &type_args)") != null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "try self.emitGenericContainerRef(\"Map\", &type_args)") != null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "try self.emitTermTypeRef()") != null);
    try std.testing.expect(std.mem.indexOf(u8, container_source, "try self.emitProtocolBoxTypeRef()") != null);

    const encoded_start = std.mem.indexOf(u8, source, "fn emitEncodedContainerElementTypeRef") orelse return error.TestUnexpectedResult;
    const encoded_end = std.mem.indexOfPos(u8, source, encoded_start, "/// Extract element type from a list ZigType.") orelse return error.TestUnexpectedResult;
    const encoded_source = source[encoded_start..encoded_end];

    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "fn emitEncodedContainerElementTypeRef(self: *ZirDriver, name: []const u8) BuildError!?u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "if (!self.findAnyTypeDef(name)) return null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "return try self.emitStructTypeRef(name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "fn emitRequiredEncodedContainerElementTypeRef(self: *ZirDriver, name: []const u8) BuildError!u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "orelse error.EmitFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_source, "fn encodedContainerElementNameIsKnown(self: *const ZirDriver, name: []const u8) bool") != null);

    const map_cell_start = std.mem.indexOf(u8, source, "fn emitMapCellRef") orelse return error.TestUnexpectedResult;
    const map_cell_end = std.mem.indexOfPos(u8, source, map_cell_start, "/// Set the return type to a generic container type.") orelse return error.TestUnexpectedResult;
    const map_cell_source = source[map_cell_start..map_cell_end];

    try std.testing.expect(std.mem.indexOf(u8, map_cell_source, "orelse return error.EmitFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_cell_source, "zigTypeToTypeRef(key_type) orelse") == null);
    try std.testing.expect(std.mem.indexOf(u8, map_cell_source, "zigTypeToTypeRef(value_type) orelse") == null);
    try std.testing.expect(std.mem.indexOf(u8, map_cell_source, "@intFromEnum(Zir.Inst.Ref.u32_type)") == null);
    try std.testing.expect(std.mem.indexOf(u8, map_cell_source, "@intFromEnum(Zir.Inst.Ref.i64_type)") == null);
}

test "ZirDriver generic container builtin lowering propagates emission failures at source level" {
    const source = @embedFile("zir_builder.zig");
    const start = std.mem.indexOf(u8, source, "            .call_builtin => |cb| {") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, source, start, "            .list_init => |li| {") orelse return error.TestUnexpectedResult;
    const call_builtin_source = source[start..end];

    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "catch error_ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "catch break :blk") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "break :blk false") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "break :blk2 false") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "break :blk3 false") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "break :blk4 false") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "MapOf(u32, i64)") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const type_ref = try self.emitRequiredEncodedContainerElementTypeRef(type_name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const key_ref = try self.emitRequiredEncodedContainerElementTypeRef(key_type_name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const val_ref = try self.emitRequiredEncodedContainerElementTypeRef(value_struct_name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const inner_type_ref = try self.emitRequiredEncodedContainerElementTypeRef(inner_type_name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const helper_name = mapBridgeMethodToHelper(\"Map\", method_name) orelse return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_builtin_source, "const fn_ref = try self.emitRuntimeHelper(helper_name);") != null);
}

test "ZirDriver map init and match type lowering reject unresolved emission inputs at source level" {
    const source = @embedFile("zir_builder.zig");
    const map_start = std.mem.indexOf(u8, source, "            .map_init => |mi| {") orelse return error.TestUnexpectedResult;
    const map_end = std.mem.indexOfPos(u8, source, map_start, "            .struct_init => |si| {") orelse return error.TestUnexpectedResult;
    const map_source = source[map_start..map_end];

    try std.testing.expect(std.mem.indexOf(u8, map_source, "const key_type_ref = (try self.emitContainerElementTypeRef(mi.key_type)) orelse return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_source, "const val_type_ref = (try self.emitContainerElementTypeRef(mi.value_type)) orelse return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, map_source, "orelse @intFromEnum(Zir.Inst.Ref.u32_type)") == null);
    try std.testing.expect(std.mem.indexOf(u8, map_source, "orelse @intFromEnum(Zir.Inst.Ref.i64_type)") == null);

    const match_start = std.mem.indexOf(u8, source, "            .match_type => |mt| {") orelse return error.TestUnexpectedResult;
    const match_end = std.mem.indexOfPos(u8, source, match_start, "            .match_fail => |mf| {") orelse return error.TestUnexpectedResult;
    const match_source = source[match_start..match_end];

    try std.testing.expect(std.mem.indexOf(u8, match_source, "if (ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, match_source, "if (ref != error_ref) try self.setLocal(mt.dest, ref);") == null);
    try std.testing.expect(std.mem.indexOf(u8, match_source, "if (expected_type_raw == 0) {\n                    return error.EmitFailed;\n                }") != null);
    try std.testing.expect(std.mem.indexOf(u8, match_source, "Unsupported type or void") == null);
    try std.testing.expect(std.mem.indexOf(u8, match_source, "emit true as fallback") == null);
}

test "ZirDriver nominal aggregate init lowering preserves type-ref emission failures" {
    const source = @embedFile("zir_builder.zig");

    const struct_start = std.mem.indexOf(u8, source, ".struct_init => |si| {") orelse return error.TestUnexpectedResult;
    const struct_end = std.mem.indexOfPos(u8, source, struct_start, ".field_get => |fg| {") orelse return error.TestUnexpectedResult;
    const struct_source = source[struct_start..struct_end];

    try std.testing.expect(std.mem.indexOf(u8, struct_source, "emitStructTypeRef(si.type_name) catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, struct_source, "const type_ref = try self.emitStructTypeRef(si.type_name);") != null);
    try std.testing.expect(std.mem.indexOf(u8, struct_source, "if (typed == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, struct_source, "if (typed_result != error_ref) struct_value = typed_result;") == null);
    try std.testing.expect(std.mem.indexOf(u8, struct_source, "zir_builder_emit_struct_init_anon") != null);

    const union_start = std.mem.indexOf(u8, source, ".union_init => |ui| {") orelse return error.TestUnexpectedResult;
    const union_end = std.mem.indexOfPos(u8, source, union_start, ".box_as_protocol => |bx| {") orelse return error.TestUnexpectedResult;
    const union_source = source[union_start..union_end];

    try std.testing.expect(std.mem.indexOf(u8, union_source, "emitStructTypeRef(ui.union_type) catch null") == null);
    try std.testing.expect(std.mem.indexOf(u8, union_source, "const union_type_ref = try self.emitStructTypeRef(ui.union_type);") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_source, "if (typed == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_source, "if (ref != error_ref)") == null);
    try std.testing.expect(std.mem.indexOf(u8, union_source, "zir_builder_emit_struct_init_anon") != null);
}

test "ZirDriver struct default emission propagates primitive emit failures at source level" {
    const source = @embedFile("zir_builder.zig");
    const struct_start = std.mem.indexOf(u8, source, ".struct_init => |si| {") orelse return error.TestUnexpectedResult;
    const struct_end = std.mem.indexOfPos(u8, source, struct_start, ".field_get => |fg| {") orelse return error.TestUnexpectedResult;
    const struct_source = source[struct_start..struct_end];
    const default_start = std.mem.indexOf(u8, struct_source, "Fill in missing fields with default values") orelse return error.TestUnexpectedResult;
    const default_end = std.mem.indexOfPos(u8, struct_source, default_start, "A zero-field struct construction") orelse return error.TestUnexpectedResult;
    const default_source = struct_source[default_start..default_end];

    try std.testing.expect(std.mem.indexOf(u8, default_source, "break :blk if (ref == error_ref)") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "@intFromEnum(Zir.Inst.Ref.zero) else ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "@intFromEnum(Zir.Inst.Ref.void_value) else ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "if (ref == error_ref) return error.EmitFailed;\n                                        break :blk ref;") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "const ref = zir_builder_emit_int(self.handle, v);\n                                        if (ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "const ref = zir_builder_emit_float(self.handle, v);\n                                        if (ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_source, "const ref = zir_builder_emit_str(self.handle, v.ptr, @intCast(v.len));\n                                        if (ref == error_ref) return error.EmitFailed;") != null);
}

test "ZirDriver index_get term coercion propagates default emission failure at source level" {
    const source = @embedFile("zir_builder.zig");
    const index_get_start = std.mem.indexOf(u8, source, ".index_get => |ig| {") orelse return error.TestUnexpectedResult;
    const index_get_end = std.mem.indexOfPos(u8, source, index_get_start, ".list_len_check => |llc| {") orelse return error.TestUnexpectedResult;
    const index_get_source = source[index_get_start..index_get_end];

    try std.testing.expect(std.mem.indexOf(u8, index_get_source, "emitZeroDefaultForType(ig.coerce_term_to) catch ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, index_get_source, "const default_ref = try self.emitZeroDefaultForType(ig.coerce_term_to);") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_get_source, "if (default_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_get_source, "const args = [_]u32{ ref, default_ref };") != null);
}

test "ZirDriver closure dispatch emission failures do not fall back at source level" {
    const source = @embedFile("zir_builder.zig");

    const tail_start = std.mem.indexOf(u8, source, "fn emitTailInvokeWrapperCall") orelse return error.TestUnexpectedResult;
    const tail_end = std.mem.indexOfPos(u8, source, tail_start, "/// True when the `call_closure`") orelse return error.TestUnexpectedResult;
    const tail_source = source[tail_start..tail_end];

    try std.testing.expect(std.mem.indexOf(u8, tail_source, "const func_def = self.findFunctionById(function_id) orelse return false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_source, "if (env_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_source, "if (arg_struct == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_source, "if (ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail_source, "== error_ref) return false") == null);

    const switch_start = std.mem.indexOf(u8, source, "fn emitClosureSwitchDispatch") orelse return error.TestUnexpectedResult;
    const switch_end = std.mem.indexOfPos(u8, source, switch_start, "fn emitInstruction") orelse return error.TestUnexpectedResult;
    const switch_source = source[switch_start..switch_end];

    try std.testing.expect(std.mem.indexOf(u8, switch_source, "if (call_fn_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "if (fallback_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "if (!emitted) return false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "== error_ref) return false") == null);

    const param_start = std.mem.indexOf(u8, source, "                // Parameter-derived closures:") orelse return error.TestUnexpectedResult;
    const runtime_start = std.mem.indexOfPos(u8, source, param_start, "const rt_ref = zir_builder_emit_import(self.handle, \"zap_runtime\", 11);") orelse return error.TestUnexpectedResult;
    const runtime_end = std.mem.indexOfPos(u8, source, runtime_start, "\n                }\n\n                // Fast path:") orelse return error.TestUnexpectedResult;
    const runtime_source = source[runtime_start..runtime_end];

    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (rt_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (kernel_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (helper_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "var ref = zir_builder_emit_call_ref(self.handle, helper_ref, full_args.items.ptr, @intCast(full_args.items.len));\n                    if (ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "// Arity fallback: callCallableN helpers cover 0..3.") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (rt_ref != error_ref)") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (kernel_ref != error_ref)") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (helper_ref != error_ref)") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "if (ref != error_ref) {\n                                    // Cast the callCallableN result") == null);
}

test "CurrentElseInsts preserves old buffer when replacement allocation fails" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var current_else_insts = CurrentElseInsts.init(failing_allocator.allocator());
    defer current_else_insts.deinit();

    try current_else_insts.replaceWithCopy(&.{ 10, 20 });
    try std.testing.expectError(error.OutOfMemory, current_else_insts.replaceWithCopy(&.{ 30, 40, 50 }));
    try std.testing.expectEqualSlices(u32, &.{ 10, 20 }, current_else_insts.get());
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "CurrentElseInsts clears consumed buffer before replacement" {
    var current_else_insts = CurrentElseInsts.init(std.testing.allocator);
    defer current_else_insts.deinit();

    try current_else_insts.replaceWithCopy(&.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, current_else_insts.get());

    current_else_insts.clear();
    try std.testing.expect(!current_else_insts.hasOwnedBuffer());

    try current_else_insts.replaceWithSingle(99);
    try std.testing.expectEqualSlices(u32, &.{99}, current_else_insts.get());

    try current_else_insts.replaceWithEmpty();
    try std.testing.expectEqual(@as(usize, 0), current_else_insts.get().len);
}

fn expectCurrentElseGuard(function_source: []const u8, initial_replace_marker: []const u8) !void {
    const init_marker = "var current_else_insts = CurrentElseInsts.init(self.allocator);";
    const defer_marker = "defer current_else_insts.deinit();";
    const get_marker = "const else_insts = current_else_insts.get();";
    const clear_marker = "current_else_insts.clear();";

    const init_pos = std.mem.indexOf(u8, function_source, init_marker) orelse return error.TestUnexpectedResult;
    const defer_pos = std.mem.indexOfPos(u8, function_source, init_pos, defer_marker) orelse return error.TestUnexpectedResult;
    const initial_replace_pos = std.mem.indexOfPos(u8, function_source, defer_pos, initial_replace_marker) orelse return error.TestUnexpectedResult;
    const get_pos = std.mem.indexOfPos(u8, function_source, initial_replace_pos, get_marker) orelse return error.TestUnexpectedResult;
    const clear_pos = std.mem.indexOfPos(u8, function_source, get_pos, clear_marker) orelse return error.TestUnexpectedResult;

    try std.testing.expect(init_pos < defer_pos);
    try std.testing.expect(defer_pos < initial_replace_pos);
    try std.testing.expect(initial_replace_pos < get_pos);
    try std.testing.expect(get_pos < clear_pos);
    try std.testing.expect(std.mem.indexOf(u8, function_source, "self.allocator.free(current_else_insts)") == null);
    try std.testing.expect(std.mem.indexOf(u8, function_source, "current_else_insts = try self.allocator.alloc") == null);
    try std.testing.expect(std.mem.indexOf(u8, function_source, "var current_else_insts = try self.allocator.alloc") == null);
    try std.testing.expect(std.mem.indexOf(u8, function_source, "current_else_insts.ptr") == null);
}

test "ZirDriver current else instruction ownership is guarded across nested emitters at source level" {
    const source = @embedFile("zir_builder.zig");

    const CurrentElseSource = struct {
        start_marker: []const u8,
        end_marker: []const u8,
        initial_replace_marker: []const u8,
    };
    const current_else_sources = [_]CurrentElseSource{
        .{
            .start_marker = "fn emitClosureSwitchDispatch",
            .end_marker = "fn emitInstruction",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(else_ptr[0..else_len]);",
        },
        .{
            .start_marker = "fn emitFlattenedGuardSequence",
            .end_marker = "/// Emit a guard block",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);",
        },
        .{
            .start_marker = "fn emitSwitchLiteral",
            .end_marker = "/// Emit a case_block as a chain",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);",
        },
        .{
            .start_marker = "fn emitCaseBlock",
            .end_marker = "/// Find the setup instruction",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);",
        },
        .{
            .start_marker = "fn emitFlatCaseBlock",
            .end_marker = "/// Emit a switch_return",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);",
        },
        .{
            .start_marker = "fn emitSwitchReturn",
            .end_marker = "/// Emit a union_switch_return",
            .initial_replace_marker = "try current_else_insts.replaceWithCopy(default_ptr[0..default_len]);",
        },
        .{
            .start_marker = "fn emitUnionSwitchReturn",
            .end_marker = "/// Emit a `f(nil) / f(t :: T)` optional dispatcher",
            .initial_replace_marker = "try current_else_insts.replaceWithEmpty();",
        },
    };

    for (current_else_sources) |current_else_source| {
        const source_start = std.mem.indexOf(u8, source, current_else_source.start_marker) orelse return error.TestUnexpectedResult;
        const source_end = std.mem.indexOfPos(u8, source, source_start, current_else_source.end_marker) orelse return error.TestUnexpectedResult;
        try expectCurrentElseGuard(source[source_start..source_end], current_else_source.initial_replace_marker);
    }
}

test "ZirDriver closure switch dispatch owns else body on all exits at source level" {
    const source = @embedFile("zir_builder.zig");

    const switch_start = std.mem.indexOf(u8, source, "fn emitClosureSwitchDispatch") orelse return error.TestUnexpectedResult;
    const switch_end = std.mem.indexOfPos(u8, source, switch_start, "fn emitInstruction") orelse return error.TestUnexpectedResult;
    const switch_source = source[switch_start..switch_end];

    const owner = "var current_else_insts = CurrentElseInsts.init(self.allocator);";
    const immediate_defer = "defer current_else_insts.deinit();";
    const initial_else_copy = "try current_else_insts.replaceWithCopy(else_ptr[0..else_len]);";
    const loop_start = "var emitted = false;";

    const owner_pos = std.mem.indexOf(u8, switch_source, owner) orelse return error.TestUnexpectedResult;
    const defer_pos = std.mem.indexOfPos(u8, switch_source, owner_pos, immediate_defer) orelse return error.TestUnexpectedResult;
    const copy_pos = std.mem.indexOfPos(u8, switch_source, defer_pos, initial_else_copy) orelse return error.TestUnexpectedResult;
    const loop_pos = std.mem.indexOfPos(u8, switch_source, defer_pos, loop_start) orelse return error.TestUnexpectedResult;

    try std.testing.expect(owner_pos < defer_pos);
    try std.testing.expect(defer_pos < copy_pos);
    try std.testing.expect(copy_pos < loop_pos);
    try std.testing.expect(defer_pos < loop_pos);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "defer self.allocator.free(current_else_insts);\n        if (!emitted) return false;") == null);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "const else_insts = current_else_insts.get();") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_source, "current_else_insts.clear();") != null);
}

test "ZirDriver closure switch dispatch balances capture cleanup on error at source level" {
    const source = @embedFile("zir_builder.zig");

    const helper_start = std.mem.indexOf(u8, source, "fn discardCapture") orelse return error.TestUnexpectedResult;
    const helper_end = std.mem.indexOfPos(u8, source, helper_start, "/// Phase E.7") orelse return error.TestUnexpectedResult;
    const helper_source = source[helper_start..helper_end];

    try std.testing.expect(std.mem.indexOf(u8, helper_source, "_ = self.endCapture(&discard_len);") != null);

    const switch_start = std.mem.indexOf(u8, source, "fn emitClosureSwitchDispatch") orelse return error.TestUnexpectedResult;
    const switch_end = std.mem.indexOfPos(u8, source, switch_start, "fn emitInstruction") orelse return error.TestUnexpectedResult;
    const switch_source = source[switch_start..switch_end];

    try expectCaptureCleanupBalance(switch_source, 2);

    const fallback_begin = std.mem.indexOf(u8, switch_source, "self.beginCapture();") orelse return error.TestUnexpectedResult;
    const fallback_errdefer = std.mem.indexOfPos(u8, switch_source, fallback_begin, "errdefer if (fallback_capture_open) self.discardCapture();") orelse return error.TestUnexpectedResult;
    const fallback_call = std.mem.indexOfPos(u8, switch_source, fallback_errdefer, "fallback_ref = zir_builder_emit_call_ref") orelse return error.TestUnexpectedResult;
    const fallback_end = std.mem.indexOfPos(u8, switch_source, fallback_call, "const else_ptr = self.endCapture(&else_len);") orelse return error.TestUnexpectedResult;
    const fallback_close = std.mem.indexOfPos(u8, switch_source, fallback_end, "fallback_capture_open = false;") orelse return error.TestUnexpectedResult;

    try std.testing.expect(fallback_begin < fallback_errdefer);
    try std.testing.expect(fallback_errdefer < fallback_call);
    try std.testing.expect(fallback_end < fallback_close);

    const then_begin = std.mem.indexOfPos(u8, switch_source, fallback_call, "self.beginCapture();") orelse return error.TestUnexpectedResult;
    const then_errdefer = std.mem.indexOfPos(u8, switch_source, then_begin, "errdefer if (capture_open) self.discardCapture();") orelse return error.TestUnexpectedResult;
    const direct_call = std.mem.indexOfPos(u8, switch_source, then_errdefer, "const direct_ref = try self.emitNamedCallToTarget") orelse return error.TestUnexpectedResult;

    try std.testing.expect(then_begin < then_errdefer);
    try std.testing.expect(then_errdefer < direct_call);
}

test "ZirDriver try_call_named balances capture cleanup on error at source level" {
    const source = @embedFile("zir_builder.zig");

    const helper_start = std.mem.indexOf(u8, source, "fn discardCapture") orelse return error.TestUnexpectedResult;
    const helper_end = std.mem.indexOfPos(u8, source, helper_start, "/// Phase E.7") orelse return error.TestUnexpectedResult;
    const helper_source = source[helper_start..helper_end];

    try std.testing.expect(std.mem.indexOf(u8, helper_source, "_ = self.endCapture(&discard_len);") != null);

    const emit_start = std.mem.indexOf(u8, source, "fn emitInstruction") orelse return error.TestUnexpectedResult;
    const try_call_start = std.mem.indexOfPos(u8, source, emit_start, "            .try_call_named => |tcn| {") orelse return error.TestUnexpectedResult;
    const try_call_end = std.mem.indexOfPos(u8, source, try_call_start, "            // Error catch") orelse return error.TestUnexpectedResult;
    const try_call_source = source[try_call_start..try_call_end];

    const begin_count = std.mem.count(u8, try_call_source, "self.beginCapture();");
    const guarded_cleanup_count = std.mem.count(u8, try_call_source, "errdefer if (capture_open) self.discardCapture();");

    try std.testing.expectEqual(@as(usize, 2), begin_count);
    try std.testing.expectEqual(begin_count, guarded_cleanup_count);

    const then_begin = std.mem.indexOf(u8, try_call_source, "self.beginCapture();") orelse return error.TestUnexpectedResult;
    const then_errdefer = std.mem.indexOfPos(u8, try_call_source, then_begin, "errdefer if (capture_open) self.discardCapture();") orelse return error.TestUnexpectedResult;
    const payload_emit = std.mem.indexOfPos(u8, try_call_source, then_errdefer, "const payload = zir_builder_emit_optional_payload_unsafe") orelse return error.TestUnexpectedResult;
    const then_end = std.mem.indexOfPos(u8, try_call_source, payload_emit, "const then_ptr = self.endCapture(&then_len);") orelse return error.TestUnexpectedResult;
    const then_close = std.mem.indexOfPos(u8, try_call_source, then_end, "capture_open = false;") orelse return error.TestUnexpectedResult;

    try std.testing.expect(then_begin < then_errdefer);
    try std.testing.expect(then_errdefer < payload_emit);
    try std.testing.expect(then_end < then_close);

    const else_begin = std.mem.indexOfPos(u8, try_call_source, then_close, "self.beginCapture();") orelse return error.TestUnexpectedResult;
    const else_errdefer = std.mem.indexOfPos(u8, try_call_source, else_begin, "errdefer if (capture_open) self.discardCapture();") orelse return error.TestUnexpectedResult;
    const handler_loop = std.mem.indexOfPos(u8, try_call_source, else_errdefer, "for (tcn.handler_instrs) |hi| try self.emitInstruction(hi);") orelse return error.TestUnexpectedResult;
    const handler_result = std.mem.indexOfPos(u8, try_call_source, handler_loop, "const handler_result_ref = if (tcn.handler_result) |hr|") orelse return error.TestUnexpectedResult;
    const else_end = std.mem.indexOfPos(u8, try_call_source, handler_result, "const else_ptr = self.endCapture(&else_len);") orelse return error.TestUnexpectedResult;
    const else_close = std.mem.indexOfPos(u8, try_call_source, else_end, "capture_open = false;") orelse return error.TestUnexpectedResult;

    try std.testing.expect(else_begin < else_errdefer);
    try std.testing.expect(else_errdefer < handler_loop);
    try std.testing.expect(handler_result < else_end);
    try std.testing.expect(else_end < else_close);
}

fn expectCaptureCleanupBalance(function_source: []const u8, expected_begin_count: usize) !void {
    const begin_marker = "self.beginCapture();";
    const errdefer_marker = "errdefer if (";
    const discard_marker = ") self.discardCapture();";
    const end_marker = "self.endCapture(&";

    var search_pos: usize = 0;
    var begin_count: usize = 0;
    while (std.mem.indexOfPos(u8, function_source, search_pos, begin_marker)) |begin_pos| {
        begin_count += 1;

        const end_pos = std.mem.indexOfPos(u8, function_source, begin_pos, end_marker) orelse return error.TestUnexpectedResult;
        const errdefer_pos = std.mem.indexOfPos(u8, function_source, begin_pos, errdefer_marker) orelse return error.TestUnexpectedResult;
        const discard_pos = std.mem.indexOfPos(
            u8,
            function_source,
            errdefer_pos + errdefer_marker.len,
            discard_marker,
        ) orelse return error.TestUnexpectedResult;

        try std.testing.expect(errdefer_pos < end_pos);
        try std.testing.expect(discard_pos < end_pos);

        const flag_name = function_source[errdefer_pos + errdefer_marker.len .. discard_pos];
        try std.testing.expect(flag_name.len > 0);

        const close_marker = try std.fmt.allocPrint(std.testing.allocator, "{s} = false;", .{flag_name});
        defer std.testing.allocator.free(close_marker);

        const close_pos = std.mem.indexOfPos(
            u8,
            function_source,
            end_pos + end_marker.len,
            close_marker,
        ) orelse return error.TestUnexpectedResult;
        const next_begin_pos = std.mem.indexOfPos(
            u8,
            function_source,
            begin_pos + begin_marker.len,
            begin_marker,
        ) orelse function_source.len;
        try std.testing.expect(close_pos < next_begin_pos);

        search_pos = begin_pos + begin_marker.len;
    }

    try std.testing.expectEqual(expected_begin_count, begin_count);
}

test "ZirDriver P4J2 remaining capture cleanup paths are balanced at source level" {
    const source = @embedFile("zir_builder.zig");

    const CaptureSource = struct {
        start_marker: []const u8,
        end_marker: []const u8,
        begin_count: usize,
    };
    const captures = [_]CaptureSource{
        .{
            .start_marker = "fn emitFunction(self: *ZirDriver",
            .end_marker = "/// Allocate one mutable stack slot per parameter",
            .begin_count = 1,
        },
        .{
            .start_marker = "            .unwrap_error_union => |ueu| {",
            .end_marker = "            // Builtin calls",
            .begin_count = 1,
        },
        .{
            .start_marker = "            .optional_unwrap => |ou| {",
            .end_marker = "            .bin_len_check => |blc| {",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitIfExpr",
            .end_marker = "/// Emit a flat IR instruction sequence",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitFlattenedGuardSequence",
            .end_marker = "/// Emit a guard block",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitGuardBlock",
            .end_marker = "/// Emit a short-circuit boolean AND",
            .begin_count = 1,
        },
        .{
            .start_marker = "fn emitIndirectFieldDeref",
            .end_marker = "/// Emit a mutable stack allocation",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitSwitchLiteral",
            .end_marker = "/// Emit a case_block as a chain",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitCaseBlock",
            .end_marker = "/// Find the setup instruction",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitFlatCaseBlock",
            .end_marker = "/// Emit a switch_return",
            .begin_count = 3,
        },
        .{
            .start_marker = "fn emitSwitchReturn",
            .end_marker = "/// Emit a union_switch_return",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitUnionSwitchReturn",
            .end_marker = "/// Emit a `f(nil) / f(t :: T)` optional dispatcher",
            .begin_count = 1,
        },
        .{
            .start_marker = "fn emitOptionalDispatch",
            .end_marker = "/// Lower a `union_switch` IR instruction",
            .begin_count = 2,
        },
        .{
            .start_marker = "fn emitSwitchProngBody",
            .end_marker = "// ---------------------------------------------------------------------------\n// Public API",
            .begin_count = 1,
        },
    };

    for (captures) |capture_source| {
        const source_start = std.mem.indexOf(u8, source, capture_source.start_marker) orelse return error.TestUnexpectedResult;
        const source_end = std.mem.indexOfPos(u8, source, source_start, capture_source.end_marker) orelse return error.TestUnexpectedResult;
        try expectCaptureCleanupBalance(source[source_start..source_end], capture_source.begin_count);
    }

    const prong_start = std.mem.indexOf(u8, source, "fn emitSwitchProngBody") orelse return error.TestUnexpectedResult;
    const prong_end = std.mem.indexOfPos(u8, source, prong_start, "// ---------------------------------------------------------------------------\n// Public API") orelse return error.TestUnexpectedResult;
    const prong_source = source[prong_start..prong_end];

    try std.testing.expect(std.mem.indexOf(u8, prong_source, "zir_builder_begin_capture(self.handle);") == null);
    try std.testing.expect(std.mem.indexOf(u8, prong_source, "zir_builder_end_capture(self.handle") == null);
}

test "ZirDriver try_call_named owns then body until if-else emission at source level" {
    const source = @embedFile("zir_builder.zig");

    const emit_start = std.mem.indexOf(u8, source, "fn emitInstruction") orelse return error.TestUnexpectedResult;
    const try_call_start = std.mem.indexOfPos(u8, source, emit_start, "            .try_call_named => |tcn| {") orelse return error.TestUnexpectedResult;
    const try_call_end = std.mem.indexOfPos(u8, source, try_call_start, "            // Error catch") orelse return error.TestUnexpectedResult;
    const try_call_source = source[try_call_start..try_call_end];

    const then_alloc = std.mem.indexOf(u8, try_call_source, "const then_insts = try self.allocator.alloc(u32, then_len);") orelse return error.TestUnexpectedResult;
    const then_copy = std.mem.indexOfPos(u8, try_call_source, then_alloc, "@memcpy(then_insts, then_ptr[0..then_len]);") orelse return error.TestUnexpectedResult;
    const then_transfer = std.mem.indexOfPos(u8, try_call_source, then_copy, "break :blk .{ .insts = then_insts, .result = success_value_ref };") orelse return error.TestUnexpectedResult;
    const then_defer = std.mem.indexOfPos(u8, try_call_source, then_transfer, "defer self.allocator.free(then_body.insts);") orelse return error.TestUnexpectedResult;
    const else_begin = std.mem.indexOfPos(u8, try_call_source, then_defer, "self.beginCapture();") orelse return error.TestUnexpectedResult;
    const emit_if_else = std.mem.indexOfPos(u8, try_call_source, else_begin, "const result = zir_builder_emit_if_else_bodies(") orelse return error.TestUnexpectedResult;
    const result_check = std.mem.indexOfPos(u8, try_call_source, emit_if_else, "if (result == error_ref) return error.EmitFailed;") orelse return error.TestUnexpectedResult;

    try std.testing.expect(then_alloc < then_copy);
    try std.testing.expect(then_copy < then_transfer);
    try std.testing.expect(then_transfer < then_defer);
    try std.testing.expect(then_defer < else_begin);
    try std.testing.expect(then_defer < emit_if_else);
    try std.testing.expect(emit_if_else < result_check);
    try std.testing.expect(std.mem.indexOf(u8, try_call_source, "self.allocator.free(then_insts);\n                if (result == error_ref) return error.EmitFailed;") == null);
}

test "ZirDriver P4J2 residual error_ref paths fail instead of falling through" {
    const source = @embedFile("zir_builder.zig");

    const param_start = std.mem.indexOf(u8, source, "fn emitTypedParam") orelse return error.TestUnexpectedResult;
    const param_end = std.mem.indexOfPos(u8, source, param_start, "/// Emit the return type declaration") orelse return error.TestUnexpectedResult;
    const param_source = source[param_start..param_end];

    try std.testing.expect(std.mem.indexOf(u8, param_source, "if (ref != error_ref) return ref;") == null);
    try std.testing.expect(std.mem.indexOf(u8, param_source, "zir_builder_emit_param_this_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, param_source, "zir_builder_emit_param_decl_val_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, param_source, "zir_builder_emit_param_imported_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, param_source, "zir_builder_emit_param_imported_root_type") != null);
    try std.testing.expect(std.mem.indexOf(u8, param_source, "if (ref == error_ref) return error.EmitFailed;") != null);

    const call_named_start = std.mem.indexOf(u8, source, "            .call_named => |cn| {") orelse return error.TestUnexpectedResult;
    const call_named_end = std.mem.indexOfPos(u8, source, call_named_start, "            .try_call_named => |tcn| {") orelse return error.TestUnexpectedResult;
    const call_named_source = source[call_named_start..call_named_end];

    try std.testing.expect(std.mem.indexOf(u8, call_named_source, "if (ref != error_ref) {\n                            try self.setLocal(cn.dest, ref);\n                        }") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_named_source, "if (ref == error_ref) return error.EmitFailed;\n                        try self.setLocal(cn.dest, ref);") != null);

    const call_direct_start = std.mem.indexOf(u8, source, "            .call_direct => |cd| {") orelse return error.TestUnexpectedResult;
    const call_direct_end = std.mem.indexOfPos(u8, source, call_direct_start, "            .call_closure => |cc| {") orelse return error.TestUnexpectedResult;
    const call_direct_source = source[call_direct_start..call_direct_end];

    try std.testing.expect(std.mem.indexOf(u8, call_direct_source, "if (func_name) |fname| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_direct_source, "return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_direct_source, "no program context") != null);

    const call_closure_start = std.mem.indexOf(u8, source, "            .call_closure => |cc| {") orelse return error.TestUnexpectedResult;
    const call_closure_end = std.mem.indexOfPos(u8, source, call_closure_start, "            .make_closure => |mc| {") orelse return error.TestUnexpectedResult;
    const call_closure_source = source[call_closure_start..call_closure_end];

    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (cast != error_ref) ref = cast;") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (cast2 != error_ref) ref = cast2;") == null);
    try std.testing.expect(std.mem.count(u8, call_closure_source, "if (cast == error_ref) return error.EmitFailed;\n                        ref = cast;") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (cast2 == error_ref) return error.EmitFailed;\n                                ref = cast2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (call_fn_ref == error_ref) {\n                        // Fallback: callee might be a bare function ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (call_fn_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (ref != error_ref) {\n                                            try self.setLocal(cc.dest, ref);") == null);
    try std.testing.expect(std.mem.indexOf(u8, call_closure_source, "if (ref != error_ref) try self.setLocal(cc.dest, ref);") == null);

    const make_closure_start = std.mem.indexOf(u8, source, "            .make_closure => |mc| {") orelse return error.TestUnexpectedResult;
    const make_closure_end = std.mem.indexOfPos(u8, source, make_closure_start, "            .capture_get => |cg| {") orelse return error.TestUnexpectedResult;
    const make_closure_source = source[make_closure_start..make_closure_end];

    try std.testing.expect(std.mem.indexOf(u8, make_closure_source, "break :blk if (ref != error_ref) ref else zir_builder_emit_str") == null);
    try std.testing.expect(std.mem.indexOf(u8, make_closure_source, "zir_builder_emit_str(self.handle, emit_name.ptr") == null);
    try std.testing.expect(std.mem.indexOf(u8, make_closure_source, "if (ref == error_ref) return error.EmitFailed;\n                    break :blk ref;") != null);

    const capture_get_start = std.mem.indexOf(u8, source, "            .capture_get => |cg| {") orelse return error.TestUnexpectedResult;
    const capture_get_end = std.mem.indexOfPos(u8, source, capture_get_start, "            .optional_unwrap => |ou| {") orelse return error.TestUnexpectedResult;
    const capture_get_source = source[capture_get_start..capture_get_end];

    try std.testing.expect(std.mem.indexOf(u8, capture_get_source, "if (ref != error_ref) try self.setLocal(cg.dest, ref);") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture_get_source, "const ref = zir_builder_emit_void(self.handle);\n                            if (ref == error_ref) return error.EmitFailed;\n                            try self.setLocal(cg.dest, ref);\n                            return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_get_source, "const ref = zir_builder_emit_void(self.handle);\n                if (ref == error_ref) return error.EmitFailed;\n                try self.setLocal(cg.dest, ref);") != null);
}

test "ZirDriver P4J2 side-effect emissions propagate backend failures at source level" {
    const source = @embedFile("zir_builder.zig");
    const discarded_emit = "_ = " ++ "zir_builder_emit_";

    try std.testing.expect(std.mem.indexOf(u8, source, discarded_emit) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const serialize_ref = zir_builder_emit_call_ref(self.handle, serialize_fn, &ser_args, 1);\n                if (serialize_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const note_consume_ref = zir_builder_emit_call_ref(self.handle, note_consume_fn, &args, 0);\n                                if (note_consume_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (!zir_builder_emit_set_runtime_safety(self.handle, ref)) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const sink_ref = zir_builder_emit_call_ref(self.handle, sink_fn, &args, 1);\n                if (sink_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (zir_builder_emit_unreachable(self.handle) != 0) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const retain_ref = zir_builder_emit_call_ref(self.handle, retain_helper, &retain_args, 1);\n                    if (retain_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const retain_ref = zir_builder_emit_call_ref(self.handle, retain_fn, &args, 1);\n                            if (retain_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const note_return_ref = zir_builder_emit_call_ref(self.handle, note_return_fn, &args, 0);\n                        if (note_return_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const drop_ref = zir_builder_emit_call_ref(self.handle, drop_fn, &drop_args, 1);\n                    if (drop_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const release_ref = zir_builder_emit_call_ref(self.handle, release_fn, &args, 2);\n                    if (release_ref == error_ref) return error.EmitFailed;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const guard_ref = zir_builder_emit_if_else_bodies(") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (guard_ref == error_ref) return error.EmitFailed;") != null);
}

test "ZirDriver P4J2 synthetic namespace stubs propagate registration failures at source level" {
    const source = @embedFile("zir_builder.zig");

    const registration_start = std.mem.indexOf(u8, source, "// Register empty stub structs for any namespace name") orelse return error.TestUnexpectedResult;
    const registration_end = std.mem.indexOfPos(u8, source, registration_start, "// ── Step 3: Emit each leaf struct as its own ZIR struct") orelse return error.TestUnexpectedResult;
    const registration_source = source[registration_start..registration_end];

    const discarded_struct_source_registration = "_ = " ++ "zir_compilation_add_struct_source";
    try std.testing.expect(std.mem.indexOf(u8, registration_source, discarded_struct_source_registration) == null);

    try std.testing.expect(std.mem.indexOf(u8, registration_source, "if (zir_compilation_add_struct_source(c, mod_name_z, stub.ptr, @intCast(stub.len)) != 0) {\n                            return error.EmitFailed;\n                        }") != null);
}

test "ZirDriver P4J2 namespace re-export source ownership is balanced at source level" {
    const source = @embedFile("zir_builder.zig");

    const reexport_start = std.mem.indexOf(u8, source, "// ── Step 4: Generate namespace re-export structs") orelse return error.TestUnexpectedResult;
    const reexport_end = std.mem.indexOfPos(u8, source, reexport_start, "// ── Step 5: Emit root struct functions") orelse return error.TestUnexpectedResult;
    const reexport_source = source[reexport_start..reexport_end];

    const source_buf_decl = std.mem.indexOf(u8, reexport_source, "var source_buf: std.ArrayListUnmanaged(u8) = .empty;") orelse return error.TestUnexpectedResult;
    _ = std.mem.indexOfPos(u8, reexport_source, source_buf_decl, "defer source_buf.deinit(self.allocator);") orelse return error.TestUnexpectedResult;

    const line_alloc = std.mem.indexOf(u8, reexport_source, "const line = try std.fmt.allocPrint(self.allocator") orelse return error.TestUnexpectedResult;
    const line_free = std.mem.indexOfPos(u8, reexport_source, line_alloc, "defer self.allocator.free(line);") orelse return error.TestUnexpectedResult;
    _ = std.mem.indexOfPos(u8, reexport_source, line_free, "try source_buf.appendSlice(self.allocator, line);") orelse return error.TestUnexpectedResult;

    const source_owned = std.mem.indexOf(u8, reexport_source, "const source = try source_buf.toOwnedSlice(self.allocator);") orelse return error.TestUnexpectedResult;
    const source_free = std.mem.indexOfPos(u8, reexport_source, source_owned, "defer self.allocator.free(source);") orelse return error.TestUnexpectedResult;
    _ = std.mem.indexOfPos(u8, reexport_source, source_free, "The Zig fork copies the bytes synchronously") orelse return error.TestUnexpectedResult;
    const registration = std.mem.indexOfPos(u8, reexport_source, source_free, "const registration_status = zir_compilation_add_struct_source(c, parent_z, source.ptr, @intCast(source.len));") orelse return error.TestUnexpectedResult;
    _ = std.mem.indexOfPos(u8, reexport_source, registration, "if (registration_status != 0) {\n                        return error.EmitFailed;\n                    }") orelse return error.TestUnexpectedResult;
}

// Runtime function routing is handled by `:zig.Struct.function(args)` calls
// in Zap library files (lib/*.zap). The compiler's HIR builder lowers those
// calls to `call_builtin` instructions, which the ZIR builder emits as
// `@import("zap_runtime").Struct.function(args)`.

/// Lookup a field by name in a struct definition. Used by struct-init
/// lowering to consult the field's storage strategy (`.direct` vs
/// `.indirect`) so recursive-type fields get heap-promoted at the
/// construction site.
fn findFieldDef(struct_def: ir.StructDef, name: []const u8) ?ir.StructFieldDef {
    for (struct_def.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ============================================================
// Release-suppression bookkeeping tests
//
// These tests pin the lifecycle and contract of the two release-
// suppression sets (`arc_share_skipped`, `arc_returned_locals`)
// without depending on the C-ABI ZIR-emit path. Consume mode is
// NOT a release-suppression cause — see the consume-mode branch in
// `share_value` lowering for the design rationale (callees borrow,
// they don't consume; suppressing the post-call release would leak
// the cell). Consume's only effect on lowering is "skip the retain
// at the share site"; the post-call release fires normally.
// ============================================================

test "ZirDriver: release-suppression sets default to empty" {
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
    }

    try std.testing.expectEqual(@as(u32, 0), driver.arc_share_skipped.size);
    try std.testing.expectEqual(@as(u32, 0), driver.arc_returned_locals.size);
    try std.testing.expect(!driver.isReleaseSuppressed(0));
    try std.testing.expect(!driver.isReleaseSuppressed(1234));
}

test "ZirDriver.markReturned populates arc_returned_locals" {
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
    }

    try driver.markReturned(7);
    try std.testing.expect(driver.arc_returned_locals.contains(7));
    try std.testing.expect(!driver.arc_returned_locals.contains(8));
}

test "ZirDriver.isReleaseSuppressed reports either of the two causes" {
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
    }

    // Escape-analysis cause.
    try driver.arc_share_skipped.put(driver.allocator, 100, {});
    try std.testing.expect(driver.isReleaseSuppressed(100));

    // Return-source cause.
    try driver.markReturned(102);
    try std.testing.expect(driver.isReleaseSuppressed(102));

    // Locals not in any set are not suppressed.
    try std.testing.expect(!driver.isReleaseSuppressed(103));
}

test "ZirDriver.isReleaseSuppressed: causes are independent" {
    // Pinning the contract that the two causes are distinct sets:
    // a local marked as a return source must NOT trip the share-
    // skipped check, and vice versa. Escape elision (low-level
    // physical optimization on the dest) and return-source ownership
    // transfer (semantic, on the source) target different IR locals
    // in normal code; encoding them as disjoint sets keeps the
    // diagnostic trail clean.
    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
    }

    try driver.arc_share_skipped.put(driver.allocator, 50, {});
    try std.testing.expect(driver.arc_share_skipped.contains(50));
    try std.testing.expect(!driver.arc_returned_locals.contains(50));

    try driver.markReturned(51);
    try std.testing.expect(driver.arc_returned_locals.contains(51));
    try std.testing.expect(!driver.arc_share_skipped.contains(51));
}

test "ZirDriver.unmarkShareSkippedForClone clears provisional suppression only under clone-on-share" {
    const memory_abi = @import("memory/abi.zig");

    var tracking_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
        .declared_caps = memory_abi.CAPS_INDIVIDUAL_NO_REFCOUNT,
    };
    defer tracking_driver.arc_share_skipped.deinit(tracking_driver.allocator);

    try tracking_driver.arc_share_skipped.put(tracking_driver.allocator, 7, {});
    tracking_driver.unmarkShareSkippedForClone(7);
    try std.testing.expect(!tracking_driver.arc_share_skipped.contains(7));

    var arc_driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
        .declared_caps = memory_abi.REFCOUNT_V1_BIT,
    };
    defer arc_driver.arc_share_skipped.deinit(arc_driver.allocator);

    try arc_driver.arc_share_skipped.put(arc_driver.allocator, 8, {});
    arc_driver.unmarkShareSkippedForClone(8);
    try std.testing.expect(arc_driver.arc_share_skipped.contains(8));
}

test "ZirDriver.shouldSkipArc returns true unconditionally under declared_caps=0" {
    // Phase 6 elision contract: when the active manager omits
    // REFCOUNT_V1, every retain/release call site is skipped before
    // any escape-state classification or arc-managed bookkeeping is
    // consulted. The local's properties (arc_managed, escape state,
    // function membership) do not matter. The runtime helpers
    // (`retainAny`, `releaseAny`, …) panic when dispatched under a
    // non-REFCOUNT_V1 manager (`src/runtime.zig`'s capability checks),
    // so the codegen-time skip is what keeps the program from ever
    // hitting those panics.
    const escape_lattice = @import("escape_lattice.zig");

    var actx = escape_lattice.AnalysisContext.init(std.testing.allocator);
    defer actx.deinit();

    // Pre-populate every shape that would normally OVERRIDE the skip
    // under REFCOUNT_V1: an `arc_managed_local` (heap-pool cell), a
    // `.no_escape` lattice classification (would skip under REFCOUNT_V1
    // too, but the elision must run BEFORE that check fires), and a
    // `.global_escape` classification (would NOT skip under
    // REFCOUNT_V1). Under declared_caps=0 all three must skip.
    const vkey_managed = escape_lattice.ValueKey{ .function = 0, .local = 100 };
    try actx.escape_states.put(vkey_managed, .no_escape);

    const vkey_global = escape_lattice.ValueKey{ .function = 0, .local = 200 };
    try actx.escape_states.put(vkey_global, .global_escape);

    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
        .declared_caps = 0,
        .analysis_context = &actx,
        .current_function_id = 0,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
        driver.arc_managed_locals.deinit(driver.allocator);
    }

    try driver.arc_managed_locals.put(driver.allocator, 100, {});

    // arc-managed local: under REFCOUNT_V1 this would return false
    // (managed cells always retain/release); under declared_caps=0 the
    // elision overrides and the skip fires anyway.
    try std.testing.expect(driver.shouldSkipArc(100));

    // global_escape local: under REFCOUNT_V1 this would return false
    // (escaping locals must retain/release); under declared_caps=0 the
    // skip still fires.
    try std.testing.expect(driver.shouldSkipArc(200));

    // Local with no classification at all: the default-skip path also
    // fires under declared_caps=0.
    try std.testing.expect(driver.shouldSkipArc(300));
}

test "ZirDriver.shouldSkipArc respects local state under REFCOUNT_V1" {
    // Mirror image of the elision test. Same fixture, REFCOUNT_V1
    // declared: arc-managed locals must NOT skip (their cells live on
    // the heap pool and require explicit retain/release), and
    // global-escape locals must NOT skip (the lattice forbids stack
    // eligibility). The pair locks the regression direction so a
    // future refactor that accidentally always-skips fails both
    // tests, not just one.
    const memory_abi = @import("memory/abi.zig");
    const escape_lattice = @import("escape_lattice.zig");

    var actx = escape_lattice.AnalysisContext.init(std.testing.allocator);
    defer actx.deinit();

    const vkey_managed = escape_lattice.ValueKey{ .function = 0, .local = 100 };
    try actx.escape_states.put(vkey_managed, .no_escape);

    const vkey_global = escape_lattice.ValueKey{ .function = 0, .local = 200 };
    try actx.escape_states.put(vkey_global, .global_escape);

    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
        .declared_caps = memory_abi.REFCOUNT_V1_BIT,
        .analysis_context = &actx,
        .current_function_id = 0,
    };
    defer {
        driver.arc_share_skipped.deinit(driver.allocator);
        driver.arc_returned_locals.deinit(driver.allocator);
        driver.arc_managed_locals.deinit(driver.allocator);
    }

    try driver.arc_managed_locals.put(driver.allocator, 100, {});

    // arc-managed local — never skipped under REFCOUNT_V1.
    try std.testing.expect(!driver.shouldSkipArc(100));

    // global-escape local — not stack-eligible per the escape lattice,
    // so retain/release must fire.
    try std.testing.expect(!driver.shouldSkipArc(200));
}

test "ZirDriver.arcReleaseValueRefForLocal skips trivial locals and trusts arc-managed releases" {
    const local_ownership = [_]ir.OwnershipClass{
        .trivial,
        .owned,
        .owned,
        .trivial,
    };
    const value_ref = @intFromEnum(Zir.Inst.Ref.one);
    const void_ref = @intFromEnum(Zir.Inst.Ref.void_value);

    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
        .current_function_local_ownership = &local_ownership,
    };
    defer driver.local_refs.deinit(driver.allocator);
    defer driver.arc_managed_locals.deinit(driver.allocator);

    try driver.local_refs.put(driver.allocator, 0, .{ .inst = value_ref });
    try driver.local_refs.put(driver.allocator, 1, .{ .inst = void_ref });
    try driver.local_refs.put(driver.allocator, 2, .{ .inst = value_ref });
    try driver.local_refs.put(driver.allocator, 3, .{ .inst = value_ref });
    try driver.arc_managed_locals.put(driver.allocator, 3, {});

    try std.testing.expect(try driver.arcReleaseValueRefForLocal(0) == null);
    try std.testing.expectError(error.EmitFailed, driver.arcReleaseValueRefForLocal(1));
    const releasable = (try driver.arcReleaseValueRefForLocal(2)).?;
    switch (releasable) {
        .inst => |ref| try std.testing.expectEqual(value_ref, ref),
        .decl => return error.UnexpectedDeclRef,
    }
    const arc_managed_trivial = (try driver.arcReleaseValueRefForLocal(3)).?;
    switch (arc_managed_trivial) {
        .inst => |ref| try std.testing.expectEqual(value_ref, ref),
        .decl => return error.UnexpectedDeclRef,
    }
}

test "ZirDriver.aggregateComponentOriginalRefForLocal preserves pre-rebind component ref" {
    const original_ref = @intFromEnum(Zir.Inst.Ref.one);
    const rebound_ref = @intFromEnum(Zir.Inst.Ref.zero);

    var driver = ZirDriver{
        .handle = undefined,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    defer driver.local_refs.deinit(driver.allocator);
    defer driver.aggregate_component_original_refs.deinit(driver.allocator);

    try driver.local_refs.put(driver.allocator, 0, .{ .inst = rebound_ref });
    try driver.aggregate_component_original_refs.put(driver.allocator, 0, original_ref);

    try std.testing.expectEqual(
        original_ref,
        driver.aggregateComponentOriginalRefForLocal(0).?,
    );
    try std.testing.expectEqual(rebound_ref, driver.local_refs.get(0).?.inst);
    try std.testing.expect(driver.aggregateComponentOriginalRefForLocal(1) == null);
}

test "StructEmissionScope restores driver state and destroys unconsumed temporary handle" {
    const FakeDestroy = struct {
        var call_count: usize = 0;
        var destroyed_handle: ?*ZirBuilderHandle = null;

        fn destroy(handle: *ZirBuilderHandle) void {
            call_count += 1;
            destroyed_handle = handle;
        }
    };
    FakeDestroy.call_count = 0;
    FakeDestroy.destroyed_handle = null;

    const root_handle: *ZirBuilderHandle = @ptrFromInt(0x1000);
    const temporary_handle: *ZirBuilderHandle = @ptrFromInt(0x2000);
    var driver = ZirDriver{
        .handle = root_handle,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    driver.current_emit_struct = "Root";

    {
        var struct_scope = StructEmissionScope.enterWithDestroyFn(&driver, temporary_handle, "Leaf", FakeDestroy.destroy);
        defer struct_scope.deinit();

        try std.testing.expect(driver.handle == temporary_handle);
        try std.testing.expectEqualStrings("Leaf", driver.current_emit_struct.?);
    }

    try std.testing.expect(driver.handle == root_handle);
    try std.testing.expectEqualStrings("Root", driver.current_emit_struct.?);
    try std.testing.expectEqual(@as(usize, 1), FakeDestroy.call_count);
    try std.testing.expect(FakeDestroy.destroyed_handle.? == temporary_handle);
}

test "StructEmissionScope transfers consumed temporary handle and restores driver state" {
    const FakeDestroy = struct {
        var call_count: usize = 0;

        fn destroy(_: *ZirBuilderHandle) void {
            call_count += 1;
        }
    };
    FakeDestroy.call_count = 0;

    const root_handle: *ZirBuilderHandle = @ptrFromInt(0x3000);
    const temporary_handle: *ZirBuilderHandle = @ptrFromInt(0x4000);
    var driver = ZirDriver{
        .handle = root_handle,
        .local_refs = .empty,
        .param_refs = .empty,
        .allocator = std.testing.allocator,
        .program = null,
    };
    {
        var struct_scope = StructEmissionScope.enterWithDestroyFn(&driver, temporary_handle, "Leaf", FakeDestroy.destroy);
        defer struct_scope.deinit();

        try std.testing.expect(driver.handle == temporary_handle);
        try std.testing.expectEqualStrings("Leaf", driver.current_emit_struct.?);
        struct_scope.markConsumedByInjection();
    }

    try std.testing.expect(driver.handle == root_handle);
    try std.testing.expect(driver.current_emit_struct == null);
    try std.testing.expectEqual(@as(usize, 0), FakeDestroy.call_count);
}

test "renderSpecializationSourceFileBody injects zap_runtime import for protocol_box variant payloads" {
    // Phase 1.2.5 Gap 1 root-cause pin. A parametric union
    // specialization like `Option_Error` whose `Some` variant payload
    // is `zap_runtime.ProtocolBox` MUST carry an explicit
    // `@import("zap_runtime")` in its synthetic source file —
    // otherwise the variant payload's namespace stays unresolved
    // through Sema and LLVM emits a constant referencing a never-
    // registered global, panicking in `Builder.toBitcode` with
    // "attempt to use null value" the moment a downstream call site
    // materializes the type (e.g. a `pub error MyError {}` whose
    // auto-injected `cause :: Option(Error)` field's default expr
    // builds an `Option_Error.None` value).
    const allocator = std.testing.allocator;
    const variants = [_]ir.UnionVariant{
        .{ .name = "Some", .type_name = "zap_runtime.ProtocolBox" },
        .{ .name = "None", .type_name = null },
    };
    const type_def: ir.TypeDef = .{
        .name = "Option_Error",
        .kind = .{ .union_def = .{ .variants = &variants } },
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try renderSpecializationSourceFileBody(allocator, &buf, type_def);

    // The import line MUST come before the union declaration so the
    // variant payload resolves correctly at every Sema reference.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "const zap_runtime = @import(\"zap_runtime\");") != null);
    const import_pos = std.mem.indexOf(u8, buf.items, "@import(\"zap_runtime\")").?;
    const union_pos = std.mem.indexOf(u8, buf.items, "= union(enum)").?;
    try std.testing.expect(import_pos < union_pos);
    // Variant payload still references the runtime namespace through
    // the freshly-imported alias.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Some: zap_runtime.ProtocolBox") != null);
}

test "renderSpecializationSourceFileBody omits zap_runtime import for plain instantiations" {
    // `Option_i64` carries an `i64` payload — no `zap_runtime`
    // reference, so the import line is dead weight (and would draw
    // an unused-namespace warning under stricter Zig modes). The
    // emitter must skip the import when no variant payload references
    // the runtime namespace.
    const allocator = std.testing.allocator;
    const variants = [_]ir.UnionVariant{
        .{ .name = "Some", .type_name = "i64" },
        .{ .name = "None", .type_name = null },
    };
    const type_def: ir.TypeDef = .{
        .name = "Option_i64",
        .kind = .{ .union_def = .{ .variants = &variants } },
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try renderSpecializationSourceFileBody(allocator, &buf, type_def);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "@import(\"zap_runtime\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Some: i64") != null);
}
