//! ZIR Builder — lowers Zap IR directly to ZIR instruction arrays.
//!
//! Instead of emitting Zig source text (codegen.zig), this module builds the
//! three ZIR data arrays (instructions, string_bytes, extra) that the Zig
//! compiler's Sema pass consumes. This bypasses AstGen entirely.
//!
//! Uses the real `std.zig.Zir` types from the standard library so that tag
//! values and data layouts exactly match what Sema expects.

const std = @import("std");
const ir = @import("ir.zig");
const Allocator = std.mem.Allocator;
const Zir = std.zig.Zir;

/// Mirrors the ZirData extern struct in the Zig fork's zir_api.zig.
pub const ZirData = extern struct {
    instructions_tags: [*]u8,
    instructions_data: [*]u8,
    instructions_len: u32,
    string_bytes: [*]u8,
    string_bytes_len: u32,
    extra: [*]u32,
    extra_len: u32,
};

// ---------------------------------------------------------------------------
// ZIR Builder
// ---------------------------------------------------------------------------

pub const ZirBuilder = struct {
    allocator: Allocator,

    // The three output arrays, built up incrementally.
    tags: std.ArrayListUnmanaged(u8),
    /// Stores raw bytes for Zir.Inst.Data. Each element is @sizeOf(Zir.Inst.Data) bytes.
    /// We use a byte array because Data is an untagged union whose size varies
    /// between Debug (16 bytes) and Release (8 bytes) modes.
    data_bytes: std.ArrayListUnmanaged(u8),
    string_bytes: std.ArrayListUnmanaged(u8),
    extra: std.ArrayListUnmanaged(u32),

    // String interning: maps string content to its index in string_bytes.
    string_map: std.StringHashMapUnmanaged(u32),

    // Tracks the mapping from Zap IR LocalId to ZIR Inst.Ref (stored as u32).
    local_refs: std.AutoHashMapUnmanaged(ir.LocalId, u32),

    const data_elem_size = @sizeOf(Zir.Inst.Data);

    pub fn init(allocator: Allocator) ZirBuilder {
        return .{
            .allocator = allocator,
            .tags = .empty,
            .data_bytes = .empty,
            .string_bytes = .empty,
            .extra = .empty,
            .string_map = .empty,
            .local_refs = .empty,
        };
    }

    pub fn deinit(self: *ZirBuilder) void {
        self.tags.deinit(self.allocator);
        self.data_bytes.deinit(self.allocator);
        self.string_bytes.deinit(self.allocator);
        self.extra.deinit(self.allocator);
        self.string_map.deinit(self.allocator);
        self.local_refs.deinit(self.allocator);
    }

    /// Must be called after init, before building.
    pub fn prepare(self: *ZirBuilder) !void {
        // Reserve index 0 in string_bytes (sentinel).
        try self.string_bytes.append(self.allocator, 0);
        // Reserve extra indices 0 and 1 (compile_errors, imports).
        try self.extra.append(self.allocator, 0);
        try self.extra.append(self.allocator, 0);
    }

    // -- Instruction emission -------------------------------------------------

    fn addInst(self: *ZirBuilder, tag: Zir.Inst.Tag, data: Zir.Inst.Data) !u32 {
        const index: u32 = @intCast(self.tags.items.len);
        try self.tags.append(self.allocator, @intFromEnum(tag));
        // Append raw bytes of the Data union.
        const bytes: *const [data_elem_size]u8 = @ptrCast(&data);
        try self.data_bytes.appendSlice(self.allocator, bytes);
        return index;
    }

    fn setInstData(self: *ZirBuilder, index: u32, data: Zir.Inst.Data) void {
        const offset = @as(usize, index) * data_elem_size;
        const bytes: *const [data_elem_size]u8 = @ptrCast(&data);
        @memcpy(self.data_bytes.items[offset..][0..data_elem_size], bytes);
    }

    fn addExtra(self: *ZirBuilder, value: u32) !u32 {
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.append(self.allocator, value);
        return index;
    }

    fn addExtraSlice(self: *ZirBuilder, values: []const u32) !u32 {
        const index: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.allocator, values);
        return index;
    }

    // -- Data construction helpers -------------------------------------------

    fn makePlNode(payload_index: u32, src_node: u32) Zir.Inst.Data {
        return .{ .pl_node = .{
            .payload_index = payload_index,
            .src_node = @enumFromInt(src_node),
        } };
    }

    fn makeUnNode(operand: u32, src_node: u32) Zir.Inst.Data {
        return .{ .un_node = .{
            .operand = @enumFromInt(operand),
            .src_node = @enumFromInt(@as(i32, @bitCast(src_node))),
        } };
    }

    fn makeStrTok(string_index: u32, src_tok: u32) Zir.Inst.Data {
        return .{ .str_tok = .{
            .start = @enumFromInt(string_index),
            .src_tok = @enumFromInt(@as(i32, @bitCast(src_tok))),
        } };
    }

    fn makeStr(start: u32, len: u32) Zir.Inst.Data {
        return .{ .str = .{
            .start = @enumFromInt(start),
            .len = len,
        } };
    }

    fn makeExtended(opcode: Zir.Inst.Extended, small: u16, operand: u32) Zir.Inst.Data {
        return .{ .extended = .{
            .opcode = opcode,
            .small = small,
            .operand = operand,
        } };
    }

    fn makeBreak(operand_ref: u32, payload_index: u32) Zir.Inst.Data {
        return .{ .@"break" = .{
            .operand = @enumFromInt(operand_ref),
            .payload_index = payload_index,
        } };
    }

    fn makeDeclaration(src_node: u32, payload_index: u32) Zir.Inst.Data {
        return .{ .declaration = .{
            .src_node = @enumFromInt(src_node),
            .payload_index = payload_index,
        } };
    }

    fn makeUnTok(operand: u32, src_tok: u32) Zir.Inst.Data {
        return .{ .un_tok = .{
            .operand = @enumFromInt(operand),
            .src_tok = @enumFromInt(@as(i32, @bitCast(src_tok))),
        } };
    }

    // -- String interning -----------------------------------------------------

    fn internString(self: *ZirBuilder, str: []const u8) !u32 {
        const gop = try self.string_map.getOrPut(self.allocator, str);
        if (gop.found_existing) return gop.value_ptr.*;
        const index: u32 = @intCast(self.string_bytes.items.len);
        try self.string_bytes.appendSlice(self.allocator, str);
        try self.string_bytes.append(self.allocator, 0);
        gop.value_ptr.* = index;
        return index;
    }

    // -- Ref helpers ----------------------------------------------------------

    /// The number of pre-defined refs before instruction indices begin.
    /// Computed at comptime from the Zir.Inst.Ref enum: it's one past the
    /// highest named value (excluding `none` which is maxInt sentinel).
    const ref_start_index: u32 = blk: {
        const fields = @typeInfo(Zir.Inst.Ref).@"enum".fields;
        var max_val: u32 = 0;
        for (fields) |f| {
            const v: u32 = @intCast(f.value);
            if (v != std.math.maxInt(u32)) {
                max_val = @max(max_val, v + 1);
            }
        }
        break :blk max_val;
    };

    fn instRef(index: u32) u32 {
        return index + ref_start_index;
    }

    fn refForLocal(self: *ZirBuilder, local: ir.LocalId) !u32 {
        return self.local_refs.get(local) orelse return error.OutOfMemory;
    }

    fn setLocal(self: *ZirBuilder, local: ir.LocalId, ref: u32) !void {
        try self.local_refs.put(self.allocator, local, ref);
    }

    // -- Well-known refs ------------------------------------------------------

    const void_value_ref: u32 = @intFromEnum(Zir.Inst.Ref.void_value);
    const bool_true_ref: u32 = @intFromEnum(Zir.Inst.Ref.bool_true);
    const bool_false_ref: u32 = @intFromEnum(Zir.Inst.Ref.bool_false);
    const zero_ref: u32 = @intFromEnum(Zir.Inst.Ref.zero);
    const one_ref: u32 = @intFromEnum(Zir.Inst.Ref.one);

    // -- Program emission -----------------------------------------------------

    pub fn buildProgram(self: *ZirBuilder, program: ir.Program) !ZirData {
        try self.prepare();

        try self.emitRootStruct(program);

        return .{
            .instructions_tags = self.tags.items.ptr,
            .instructions_data = self.data_bytes.items.ptr,
            .instructions_len = @intCast(self.tags.items.len),
            .string_bytes = self.string_bytes.items.ptr,
            .string_bytes_len = @intCast(self.string_bytes.items.len),
            .extra = self.extra.items.ptr,
            .extra_len = @intCast(self.extra.items.len),
        };
    }

    // -- Root struct emission -------------------------------------------------
    //
    // The format exactly mirrors what AstGen produces:
    //   inst 0: extended/struct_decl (root container)
    //   inst 1: declaration (for each top-level decl)
    //   inst 2..N: function body instructions
    //   inst N+1: func (function definition)
    //   inst N+2: break_inline (returns func as decl value)

    fn emitRootStruct(self: *ZirBuilder, program: ir.Program) !void {
        var decl_indices = std.ArrayListUnmanaged(u32).empty;
        defer decl_indices.deinit(self.allocator);

        // Reserve instruction index 0 for the root struct_decl (filled in later).
        _ = try self.addInst(.extended, makeExtended(.struct_decl, 0, 0));

        // Only emit the main/entry function.
        // Stdlib wrapper functions reference zap_runtime which doesn't exist
        // in this compilation context.
        for (program.functions) |func| {
            const is_main = std.mem.eql(u8, func.name, "main");
            if (!is_main) continue;
            const decl_idx = try self.emitFunctionDeclaration(func);
            try decl_indices.append(self.allocator, decl_idx);
        }

        // Build the root struct_decl payload in extra.
        const struct_payload_idx: u32 = @intCast(self.extra.items.len);

        // StructDecl payload: fields_hash[4] + src_line + src_node
        try self.extra.appendSlice(self.allocator, &.{
            0, 0, 0, 0, // fields_hash
            0, // src_line
            0, // src_node
        });

        // Trailing: decls_len + decl instruction indices.
        _ = try self.addExtra(@intCast(decl_indices.items.len));
        for (decl_indices.items) |idx| {
            _ = try self.addExtra(idx);
        }

        // Fix up instruction 0 with the real extended data.
        self.setInstData(0, makeExtended(.struct_decl, 0x0004, struct_payload_idx));
    }

    // -- Function declaration emission ----------------------------------------

    fn emitFunctionDeclaration(self: *ZirBuilder, func: ir.Function) !u32 {
        self.local_refs.clearRetainingCapacity();

        // Step 1: Emit the declaration instruction first (reserves its index).
        // The declaration's payload will be filled in after we know the func inst.
        const decl_inst = try self.addInst(.declaration, makeDeclaration(0, 0)); // placeholder

        // Step 2: Emit function body instructions.
        const body_start: u32 = @intCast(self.tags.items.len);

        // Every function body starts with restore_err_ret_index_unconditional.
        _ = try self.addInst(.restore_err_ret_index_unconditional, makeUnNode(
            @intFromEnum(Zir.Inst.Ref.none), // operand = .none
            0, // src_node = 0
        ));

        // Register params as locals.
        for (func.params, 0..) |_, i| {
            try self.setLocal(@intCast(i), @intCast(i));
        }

        for (func.body) |block| {
            for (block.instructions) |instr| {
                try self.emitInstruction(instr);
            }
        }

        // Ensure there's always a terminator. If the last instruction isn't
        // already a return, add an implicit void return.
        const last_tag: ?Zir.Inst.Tag = if (self.tags.items.len > body_start)
            @enumFromInt(self.tags.items[self.tags.items.len - 1])
        else
            null;
        if (last_tag != .ret_node and last_tag != .ret_implicit) {
            _ = try self.addInst(.ret_implicit, makeUnTok(void_value_ref, 0));
        }

        const body_end: u32 = @intCast(self.tags.items.len);
        const body_len = body_end - body_start;

        // Step 3: Emit the func instruction.
        // Func payload: { ret_ty: RetTy(u32), param_block: Index(u32), body_len: u32 }
        const func_payload_idx = try self.addExtraSlice(&.{
            0, // ret_ty: body_len=0 = void return, is_generic=false
            decl_inst, // param_block: points to the declaration (matches AstGen pattern)
            body_len,
        });

        // Trailing: body instruction indices.
        {
            var bi: u32 = body_start;
            while (bi < body_end) : (bi += 1) {
                _ = try self.addExtra(bi);
            }
        }

        // SrcLocs (3 u32s) + proto_hash (4 u32s) — required when body_len != 0.
        if (body_len != 0) {
            try self.extra.appendSlice(self.allocator, &.{ 0, 0, 0 }); // SrcLocs
            try self.extra.appendSlice(self.allocator, &.{ 0, 0, 0, 0 }); // proto_hash
        }

        const func_inst = try self.addInst(.func, makePlNode(func_payload_idx, 0));

        // Step 4: Emit break_inline that returns the func as the declaration's value.
        // break_inline data: { operand: Ref, payload_index: u32 }
        // operand = Ref to the func instruction
        // payload = Break { operand_src_node: OptionalOffset, block_inst: Index }
        const break_payload_idx = try self.addExtraSlice(&.{
            @as(u32, 0x7FFFFFFF), // operand_src_node: OptionalOffset.none = maxInt(i32)
            decl_inst, // block_inst: points to the declaration
        });
        const func_ref = instRef(func_inst);
        _ = try self.addInst(.break_inline, makeBreak(func_ref, break_payload_idx));

        // Step 5: Build the Declaration payload in extra.
        const decl_payload_idx: u32 = @intCast(self.extra.items.len);

        // Declaration: src_hash[4] + flags[2]
        try self.extra.appendSlice(self.allocator, &.{ 0, 0, 0, 0 }); // src_hash

        // Flags: packed u64 { src_line: u30, src_column: u29, id: Id(u5) }
        // pub_const_simple (id=7): has name, has value body, no type/special bodies
        const id_val: u5 = @intFromEnum(Zir.Inst.Declaration.Flags.Id.pub_const_simple);
        const flags: u64 = @as(u64, id_val) << 59; // id is in top 5 bits
        _ = try self.addExtra(@truncate(flags));
        _ = try self.addExtra(@truncate(flags >> 32));

        // Trailing for pub_const_simple: name
        const name_idx = try self.internString(func.name);
        _ = try self.addExtra(name_idx);

        // Trailing: value_body_len + body instruction indices
        // Value body = [func_inst, break_inline_inst]
        _ = try self.addExtra(2); // value_body_len
        _ = try self.addExtra(func_inst);
        _ = try self.addExtra(func_inst + 1); // break_inline is right after func

        // Fix up declaration instruction data.
        self.setInstData(decl_inst, makeDeclaration(0, decl_payload_idx));

        return decl_inst;
    }

    // -- Instruction dispatch -------------------------------------------------

    fn emitInstruction(self: *ZirBuilder, instr: ir.Instruction) error{OutOfMemory}!void {
        switch (instr) {
            // Constants
            .const_int => |ci| try self.emitConstInt(ci),
            .const_float => |cf| try self.emitConstFloat(cf),
            .const_string => |cs| try self.emitConstString(cs),
            .const_bool => |cb| try self.emitConstBool(cb),
            .const_nil => |dest| try self.setLocal(dest, void_value_ref),
            .const_atom => |ca| try self.emitConstString(.{ .dest = ca.dest, .value = ca.value }),

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

            // Arithmetic / logic
            .binary_op => |bo| self.emitBinaryOp(bo) catch {},
            .unary_op => |uo| self.emitUnaryOp(uo) catch {},

            // Returns
            .ret => |ret| self.emitReturn(ret) catch {},
            .cond_return => |cr| self.emitCondReturn(cr) catch {},

            // Aggregates
            .tuple_init => |ti| self.emitTupleInit(ti) catch {},
            .list_init => |li| self.emitListInit(li) catch {},
            .struct_init => |si| self.emitStructInit(si) catch {},
            .enum_literal => |el| self.emitEnumLiteral(el) catch {},
            .field_get => |fg| self.emitFieldGet(fg) catch {},
            .index_get => |ig| self.emitIndexGet(ig) catch {},

            // Calls
            .call_named => |cn| self.emitCallNamed(cn) catch {},
            .call_direct => |cd| self.emitCallDirect(cd) catch {},
            .call_builtin => |cb| self.emitCallBuiltin(cb) catch {},
            .call_closure => |cc| self.emitCallClosure(cc) catch {},
            .tail_call => |tc| self.emitTailCall(tc) catch {},

            // Control flow
            .if_expr => |ie| self.emitIfExpr(ie) catch {},
            .case_block => |cb| self.emitCaseBlock(cb) catch {},
            .switch_literal => |sl| self.emitSwitchLiteral(sl) catch {},

            // Pattern matching (emit as conditional checks)
            .match_atom => |ma| self.emitMatchAtom(ma) catch {},
            .match_int => |mi| self.emitMatchInt(mi) catch {},
            .match_string => |ms| self.emitMatchString(ms) catch {},
            .match_fail => {},
            .case_break => {},

            // Remaining — stubbed for now
            .call_dispatch,
            .map_init,
            .union_init,
            .field_set,
            .list_len_check,
            .list_get,
            .guard_block,
            .branch,
            .cond_branch,
            .switch_tag,
            .switch_return,
            .union_switch_return,
            .match_float,
            .match_type,
            .jump,
            .make_closure,
            .capture_get,
            .optional_unwrap,
            .bin_len_check,
            .bin_read_int,
            .bin_read_float,
            .bin_slice,
            .bin_read_utf8,
            .bin_match_prefix,
            .alloc_owned,
            .retain,
            .release,
            .phi,
            => {},
        }
    }

    // -- Constants ------------------------------------------------------------

    fn emitConstInt(self: *ZirBuilder, ci: ir.ConstInt) !void {
        if (ci.value == 0) {
            try self.setLocal(ci.dest, zero_ref);
            return;
        }
        if (ci.value == 1) {
            try self.setLocal(ci.dest, one_ref);
            return;
        }
        const inst = try self.addInst(.int, .{ .int = @bitCast(ci.value) });
        try self.setLocal(ci.dest, instRef(inst));
    }

    fn emitConstFloat(self: *ZirBuilder, cf: ir.ConstFloat) !void {
        const inst = try self.addInst(.float, .{ .float = @bitCast(cf.value) });
        try self.setLocal(cf.dest, instRef(inst));
    }

    fn emitConstString(self: *ZirBuilder, cs: ir.ConstString) !void {
        const str_idx = try self.internString(cs.value);
        const inst = try self.addInst(.str, makeStr(str_idx, @intCast(cs.value.len)));
        try self.setLocal(cs.dest, instRef(inst));
    }

    fn emitConstBool(self: *ZirBuilder, cb: ir.ConstBool) !void {
        try self.setLocal(cb.dest, if (cb.value) bool_true_ref else bool_false_ref);
    }

    // -- Binary operations ----------------------------------------------------

    fn emitBinaryOp(self: *ZirBuilder, bo: ir.BinaryOp) !void {
        const lhs = try self.refForLocal(bo.lhs);
        const rhs = try self.refForLocal(bo.rhs);
        const payload = try self.addExtraSlice(&.{ lhs, rhs });

        const tag: Zir.Inst.Tag = switch (bo.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div_trunc,
            .rem_op => .rem,
            .eq => .cmp_eq,
            .neq => .cmp_neq,
            .lt => .cmp_lt,
            .gt => .cmp_gt,
            .lte => .cmp_lte,
            .gte => .cmp_gte,
            .bool_and => .bool_br_and,
            .bool_or => .bool_br_or,
            .concat => return, // TODO: array_cat
        };

        const inst = try self.addInst(tag, makePlNode(payload, 0));
        try self.setLocal(bo.dest, instRef(inst));
    }

    fn emitUnaryOp(self: *ZirBuilder, uo: ir.UnaryOp) !void {
        const operand = try self.refForLocal(uo.operand);
        const tag: Zir.Inst.Tag = switch (uo.op) {
            .negate => .negate,
            .bool_not => .bool_not,
        };
        const inst = try self.addInst(tag, makeUnNode(operand, 0));
        try self.setLocal(uo.dest, instRef(inst));
    }

    // -- Return ---------------------------------------------------------------

    fn emitReturn(self: *ZirBuilder, ret: ir.Return) !void {
        if (ret.value) |val| {
            const ref = try self.refForLocal(val);
            _ = try self.addInst(.ret_node, makeUnNode(ref, 0));
        } else {
            _ = try self.addInst(.ret_implicit, makeUnTok(void_value_ref, 0));
        }
    }

    // -- Aggregates -----------------------------------------------------------

    fn emitTupleInit(self: *ZirBuilder, ti: ir.AggregateInit) !void {
        const start = try self.addExtra(@intCast(ti.elements.len));
        for (ti.elements) |elem| {
            const ref = try self.refForLocal(elem);
            _ = try self.addExtra(ref);
        }
        const inst = try self.addInst(.struct_init_anon, makePlNode(start, 0));
        try self.setLocal(ti.dest, instRef(inst));
    }

    fn emitListInit(self: *ZirBuilder, li: ir.AggregateInit) !void {
        const start = try self.addExtra(@intCast(li.elements.len));
        for (li.elements) |elem| {
            const ref = try self.refForLocal(elem);
            _ = try self.addExtra(ref);
        }
        const inst = try self.addInst(.array_init_anon, makePlNode(start, 0));
        try self.setLocal(li.dest, instRef(inst));
    }

    // -- Calls ----------------------------------------------------------------

    fn emitCallNamed(self: *ZirBuilder, cn: ir.CallNamed) !void {
        const name_idx = try self.internString(cn.name);
        const callee_inst = try self.addInst(.decl_val, makeStrTok(name_idx, 0));
        const callee_ref = instRef(callee_inst);

        const payload_start = try self.addExtraSlice(&.{
            callee_ref,
            @as(u32, @intCast(cn.args.len)),
        });
        for (cn.args) |arg| {
            const ref = try self.refForLocal(arg);
            _ = try self.addExtra(ref);
        }

        const inst = try self.addInst(.call, makePlNode(payload_start, 0));
        try self.setLocal(cn.dest, instRef(inst));
    }

    // -- Control flow ---------------------------------------------------------

    fn emitIfExpr(self: *ZirBuilder, ie: ir.IfExpr) !void {
        // Simplified: emit both branches linearly and use condbr.
        // A full implementation would use ZIR blocks properly.
        const cond_ref = try self.refForLocal(ie.condition);

        for (ie.then_instrs) |instr| try self.emitInstruction(instr);
        const then_ref = if (ie.then_result) |r| try self.refForLocal(r) else void_value_ref;

        for (ie.else_instrs) |instr| try self.emitInstruction(instr);
        const else_ref = if (ie.else_result) |r| try self.refForLocal(r) else void_value_ref;

        const payload = try self.addExtraSlice(&.{ cond_ref, then_ref, else_ref });
        const inst = try self.addInst(.condbr, makePlNode(payload, 0));
        try self.setLocal(ie.dest, instRef(inst));
    }

    fn emitCondReturn(self: *ZirBuilder, cr: ir.CondReturn) !void {
        const cond = try self.refForLocal(cr.condition);
        if (cr.value) |val| {
            const ref = try self.refForLocal(val);
            // Emit: if (cond) return ref;
            const payload = try self.addExtraSlice(&.{ cond, ref });
            _ = try self.addInst(.condbr, makePlNode(payload, 0));
        } else {
            _ = try self.addInst(.condbr, makePlNode(cond, 0));
        }
    }

    fn emitCaseBlock(self: *ZirBuilder, cb: ir.CaseBlock) !void {
        // Emit pre-instructions.
        for (cb.pre_instrs) |instr| try self.emitInstruction(instr);
        // Emit each arm.
        for (cb.arms) |arm| {
            for (arm.cond_instrs) |instr| try self.emitInstruction(instr);
            for (arm.body_instrs) |instr| try self.emitInstruction(instr);
            if (arm.result) |r| {
                if (self.local_refs.get(r)) |ref| {
                    try self.setLocal(cb.dest, ref);
                }
            }
        }
        // Emit default.
        for (cb.default_instrs) |instr| try self.emitInstruction(instr);
        if (cb.default_result) |r| {
            if (self.local_refs.get(r)) |ref| {
                try self.setLocal(cb.dest, ref);
            }
        }
    }

    fn emitSwitchLiteral(self: *ZirBuilder, sl: ir.SwitchLiteral) !void {
        // Simplified: emit all case bodies sequentially.
        // A real implementation would use ZIR switch_block.
        for (sl.cases) |case| {
            for (case.body_instrs) |instr| try self.emitInstruction(instr);
            if (case.result) |r| {
                if (self.local_refs.get(r)) |ref| {
                    try self.setLocal(sl.dest, ref);
                }
            }
        }
        for (sl.default_instrs) |instr| try self.emitInstruction(instr);
        if (sl.default_result) |r| {
            if (self.local_refs.get(r)) |ref| {
                try self.setLocal(sl.dest, ref);
            }
        }
    }

    // -- Additional aggregates ------------------------------------------------

    fn emitStructInit(self: *ZirBuilder, si: ir.StructInit) !void {
        // Struct init: emit as struct_init_anon with field names.
        const start = try self.addExtra(@intCast(si.fields.len));
        for (si.fields) |field| {
            const name_idx = try self.internString(field.name);
            _ = try self.addExtra(name_idx);
            const ref = self.local_refs.get(field.value) orelse continue;
            _ = try self.addExtra(ref);
        }
        const inst = try self.addInst(.struct_init_anon, makePlNode(start, 0));
        try self.setLocal(si.dest, instRef(inst));
    }

    fn emitEnumLiteral(self: *ZirBuilder, el: ir.EnumLiteral) !void {
        // Emit enum literal as a string reference for now.
        const str_idx = try self.internString(el.variant);
        const inst = try self.addInst(.str, makeStr(str_idx, @intCast(el.variant.len)));
        try self.setLocal(el.dest, instRef(inst));
    }

    fn emitFieldGet(self: *ZirBuilder, fg: ir.FieldGet) !void {
        const obj_ref = try self.refForLocal(fg.object);
        const name_idx = try self.internString(fg.field);
        const payload = try self.addExtraSlice(&.{ name_idx, obj_ref });
        const inst = try self.addInst(.field_val, makePlNode(payload, 0));
        try self.setLocal(fg.dest, instRef(inst));
    }

    fn emitIndexGet(self: *ZirBuilder, ig: ir.IndexGet) !void {
        const obj_ref = try self.refForLocal(ig.object);
        const inst = try self.addInst(.elem_val_imm, .{ .elem_val_imm = .{
            .operand = @enumFromInt(obj_ref),
            .idx = ig.index,
        } });
        try self.setLocal(ig.dest, instRef(inst));
    }

    // -- Additional calls -----------------------------------------------------

    fn emitCallDirect(self: *ZirBuilder, cd: ir.CallDirect) !void {
        // Direct calls reference a function by ID. Map to the function name
        // via the program's function table (not available here — use index as name).
        const name = std.fmt.allocPrint(self.allocator, "__fn_{d}", .{cd.function}) catch return;
        defer self.allocator.free(name);
        const name_idx = try self.internString(name);
        const callee_inst = try self.addInst(.decl_val, makeStrTok(name_idx, 0));
        const callee_ref = instRef(callee_inst);

        const payload_start = try self.addExtraSlice(&.{
            callee_ref,
            @as(u32, @intCast(cd.args.len)),
        });
        for (cd.args) |arg| {
            const ref = self.local_refs.get(arg) orelse continue;
            _ = try self.addExtra(ref);
        }

        const inst = try self.addInst(.call, makePlNode(payload_start, 0));
        try self.setLocal(cd.dest, instRef(inst));
    }

    fn emitCallBuiltin(self: *ZirBuilder, cb: ir.CallBuiltin) !void {
        // Builtin calls map to runtime function calls.
        const name_idx = try self.internString(cb.name);
        const callee_inst = try self.addInst(.decl_val, makeStrTok(name_idx, 0));
        const callee_ref = instRef(callee_inst);

        const payload_start = try self.addExtraSlice(&.{
            callee_ref,
            @as(u32, @intCast(cb.args.len)),
        });
        for (cb.args) |arg| {
            const ref = self.local_refs.get(arg) orelse continue;
            _ = try self.addExtra(ref);
        }

        const inst = try self.addInst(.call, makePlNode(payload_start, 0));
        try self.setLocal(cb.dest, instRef(inst));
    }

    fn emitCallClosure(self: *ZirBuilder, cc: ir.CallClosure) !void {
        const callee_ref = try self.refForLocal(cc.callee);

        const payload_start = try self.addExtraSlice(&.{
            callee_ref,
            @as(u32, @intCast(cc.args.len)),
        });
        for (cc.args) |arg| {
            const ref = self.local_refs.get(arg) orelse continue;
            _ = try self.addExtra(ref);
        }

        const inst = try self.addInst(.call, makePlNode(payload_start, 0));
        try self.setLocal(cc.dest, instRef(inst));
    }

    fn emitTailCall(self: *ZirBuilder, tc: ir.TailCall) !void {
        // Tail calls are emitted as regular calls followed by ret.
        const name_idx = try self.internString(tc.name);
        const callee_inst = try self.addInst(.decl_val, makeStrTok(name_idx, 0));
        const callee_ref = instRef(callee_inst);

        const payload_start = try self.addExtraSlice(&.{
            callee_ref,
            @as(u32, @intCast(tc.args.len)),
        });
        for (tc.args) |arg| {
            const ref = self.local_refs.get(arg) orelse continue;
            _ = try self.addExtra(ref);
        }

        const call_inst = try self.addInst(.call, makePlNode(payload_start, 0));
        _ = try self.addInst(.ret_node, makeUnNode(instRef(call_inst), 0));
    }

    // -- Pattern matching (simplified) ----------------------------------------

    fn emitMatchAtom(self: *ZirBuilder, ma: ir.MatchAtom) !void {
        // Compare scrutinee with the atom value using cmp_eq.
        const scrutinee = try self.refForLocal(ma.scrutinee);
        const atom_idx = try self.internString(ma.atom_name);
        const atom_inst = try self.addInst(.str, makeStr(atom_idx, @intCast(ma.atom_name.len)));
        const payload = try self.addExtraSlice(&.{ scrutinee, instRef(atom_inst) });
        const inst = try self.addInst(.cmp_eq, makePlNode(payload, 0));
        try self.setLocal(ma.dest, instRef(inst));
    }

    fn emitMatchInt(self: *ZirBuilder, mi: ir.MatchInt) !void {
        const scrutinee = try self.refForLocal(mi.scrutinee);
        const val_inst = try self.addInst(.int, .{ .int = @bitCast(mi.value) });
        const payload = try self.addExtraSlice(&.{ scrutinee, instRef(val_inst) });
        const inst = try self.addInst(.cmp_eq, makePlNode(payload, 0));
        try self.setLocal(mi.dest, instRef(inst));
    }

    fn emitMatchString(self: *ZirBuilder, ms: ir.MatchString) !void {
        const scrutinee = try self.refForLocal(ms.scrutinee);
        const str_idx = try self.internString(ms.expected);
        const str_inst = try self.addInst(.str, makeStr(str_idx, @intCast(ms.expected.len)));
        const payload = try self.addExtraSlice(&.{ scrutinee, instRef(str_inst) });
        const inst = try self.addInst(.cmp_eq, makePlNode(payload, 0));
        try self.setLocal(ms.dest, instRef(inst));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ZirBuilder: const_int" {
    var b = ZirBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.prepare();

    try b.emitConstInt(.{ .dest = 0, .value = 42 });

    try std.testing.expectEqual(@as(usize, 1), b.tags.items.len);
    try std.testing.expect(b.local_refs.get(0) != null);
}

test "ZirBuilder: const_int zero uses special ref" {
    var b = ZirBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.prepare();

    try b.emitConstInt(.{ .dest = 0, .value = 0 });

    // No instruction emitted — zero uses a pre-defined ref.
    try std.testing.expectEqual(@as(usize, 0), b.tags.items.len);
    try std.testing.expectEqual(ZirBuilder.zero_ref, b.local_refs.get(0).?);
}

test "ZirBuilder: const_string interns" {
    var b = ZirBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.prepare();

    try b.emitConstString(.{ .dest = 0, .value = "hello" });
    try std.testing.expectEqual(@as(usize, 1), b.tags.items.len);

    const idx1 = try b.internString("hello");
    const idx2 = try b.internString("hello");
    try std.testing.expectEqual(idx1, idx2);
}

test "ZirBuilder: binary_op add" {
    var b = ZirBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.prepare();

    try b.emitConstInt(.{ .dest = 0, .value = 10 });
    try b.emitConstInt(.{ .dest = 1, .value = 20 });
    try b.emitBinaryOp(.{ .dest = 2, .op = .add, .lhs = 0, .rhs = 1 });

    try std.testing.expectEqual(@as(usize, 3), b.tags.items.len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.add), b.tags.items[2]);
}

test "ZirBuilder: return value" {
    var b = ZirBuilder.init(std.testing.allocator);
    defer b.deinit();
    try b.prepare();

    try b.emitConstInt(.{ .dest = 0, .value = 42 });
    try b.emitReturn(.{ .value = 0 });

    try std.testing.expectEqual(@as(usize, 2), b.tags.items.len);
    try std.testing.expectEqual(@intFromEnum(Zir.Inst.Tag.ret_node), b.tags.items[1]);
}
