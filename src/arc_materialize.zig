// ============================================================
// ARC analysis-record materialization pass.
//
// Phase 2/3 of the IR-source-of-truth ARC refactor (see
// `docs/arc-emission-architecture-research-brief.md`, `arc3.md`,
// `arc4.md`). This pass converts the analysis records produced
// by `perceus.zig` and `arc_optimizer.zig` (`actx.arc_ops`,
// `actx.drop_specializations`) into first-class
// `.retain { kind }` / `.release { kind }` IR instructions
// inserted directly into the function body. Once the records
// are materialized, the ZIR backend simply lowers the IR ops
// and the legacy emit-from-analysis-record helpers in
// `zir_builder.zig` become no-ops on their way out.
//
// Pipeline placement: after `arc_drop_insertion.insertScopeExitDrops`
// and before the post-drop verifier in `compiler.zig`.
// `arc_liveness`'s `live_before_ret` tables become stale post-
// insertion; that's fine because no consumer downstream needs
// them.
//
// Path-based addressing
// ---------------------
//
// Records carry an `InsertionPoint { function, block, path,
// instr_index, position }`. `path.len == 0` means the record
// targets the top-level block whose label is `block`;
// `instr_index` then indexes into that block's instructions.
//
// When `path.len > 0`, each `StreamStep` descends one level of
// nesting. `path[0].parent_instr_index` is the index within the
// top-level block of the instruction whose nested stream the
// record targets; `path[0].child` identifies which sub-stream
// (e.g. `case_block_arm_body 2`). `path[1]` then names the
// position within that nested stream and the slot it descends
// into, and so on. `instr_index` indexes into the final stream
// reached by walking the full path.
//
// The materializer mirrors `arc_drop_insertion.zig`'s
// `StreamRebuilder.rebuildChildren` switch — for each instruction
// tag that hosts nested streams (`if_expr`, `case_block`,
// `switch_literal`, `switch_return`, `union_switch`,
// `union_switch_return`, `try_call_named`, `guard_block`,
// `optional_dispatch`), we recursively rebuild every sub-stream
// that has pending insertions and stitch the rebuilt parent
// instruction back in.
//
// What this pass materializes
// ---------------------------
//
//   * `actx.arc_ops` with kind `.retain` or `.release`, at any
//     insertion-point depth.
//   * `actx.drop_specializations` field-drops whose `local` is
//     explicitly set, at any depth.
//
// Out of scope (Phase 3 follow-up — Task 10.4):
//   * `.reset` / `.reuse_alloc` arc-op kinds. Perceus currently
//     allocates synthetic LocalIds (`10000 + match_site_id`) for
//     reset tokens; lowering them to IR requires a real-local
//     allocator. Tracked separately.
//   * `.move_transfer` / `.share` — these are dataflow markers
//     that do not correspond to standalone IR instructions.
//
// Invariant: a record is removed from its analysis-context list
// only after the corresponding IR has been inserted successfully.
// If a record's insertion point cannot be resolved (path doesn't
// match the IR shape, or `instr_index` is out of bounds), the
// record is left in the analysis context so the V10 audit can
// surface the mismatch — there is no silent fallback path.
// ============================================================

const std = @import("std");
const ir = @import("ir.zig");
const escape_lattice = @import("escape_lattice.zig");

/// Top-level entry point. Walks `analysis_context.arc_ops` and
/// `analysis_context.drop_specializations`, materializing every
/// record whose `(function, block, path, instr_index)` can be
/// resolved to a concrete position in this function. Records
/// whose path can't be resolved (other function, non-existent
/// block, out-of-bounds path step, deferred kind) remain in
/// the analysis context.
pub fn materializeAnalysisArcOps(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
) !void {
    var pending = PendingTree.init(allocator);
    defer pending.deinit();

    // Track which original-array entries this pass consumes so we
    // can rebuild the unconsumed remainder at the end.
    var consumed_arc_ops: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer consumed_arc_ops.deinit(allocator);
    var consumed_specs: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer consumed_specs.deinit(allocator);

    // Build the pending tree. Each `pending` entry carries an
    // `Origin` that references the *index* of the source record
    // in the analysis context's array. After materialization, we
    // promote any origin whose insertion site was actually applied
    // into the consumed set. Records that failed or were deferred
    // stay out of the consumed set and land in the remainder.
    for (analysis_context.arc_ops.items, 0..) |op, src_idx| {
        if (op.insertion_point.function != function.id) continue;
        const new_instr: ir.Instruction = switch (op.kind) {
            .retain => .{ .retain = .{ .value = op.value } },
            .release => .{ .release = .{ .value = op.value } },
            // Phase 3 / dataflow-only kinds stay in the analysis
            // context — they're not materializable as IR yet.
            .reset, .reuse_alloc, .move_transfer, .share => continue,
        };
        try pending.add(.{
            .block = op.insertion_point.block,
            .path = op.insertion_point.path,
            .instr_index = op.insertion_point.instr_index,
            .position = if (op.insertion_point.position == .before) .before else .after,
            .new_instr = new_instr,
            .origin = .{ .kind = .arc_op, .src_index = src_idx },
        });
    }

    for (analysis_context.drop_specializations.items, 0..) |spec, src_idx| {
        if (spec.function != function.id) continue;
        // A specialization materializes only if every field_drop
        // has an explicit `local`. Partial materialization would
        // split the spec across two backends, which the IR-source-
        // of-truth invariant forbids.
        var all_materializable = true;
        for (spec.field_drops) |fd| {
            if (fd.local == null) {
                all_materializable = false;
                break;
            }
        }
        if (!all_materializable) continue;
        for (spec.field_drops) |fd| {
            const target_local = fd.local.?;
            const release_kind: ir.ReleaseKind = switch (fd.kind) {
                .deep => .release,
                .shallow => .free,
            };
            try pending.add(.{
                .block = spec.insertion_point.block,
                .path = spec.insertion_point.path,
                .instr_index = spec.insertion_point.instr_index,
                .position = if (spec.insertion_point.position == .before) .before else .after,
                .new_instr = .{ .release = .{ .value = target_local, .kind = release_kind } },
                .origin = .{ .kind = .drop_spec, .src_index = src_idx },
            });
        }
    }

    // Apply. Origins for insertions that were successfully placed
    // get added to the consumed sets; origins for insertions whose
    // (block/path/instr_index) didn't resolve stay un-consumed.
    var block_iter = pending.blocks.iterator();
    while (block_iter.next()) |entry| {
        const block_label = entry.key_ptr.*;
        const stream_tree = entry.value_ptr;
        const block_index = findBlockByLabel(function, block_label) orelse continue;
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const new_stream = try rebuildStream(
            allocator,
            block_ptr.instructions,
            stream_tree,
            &consumed_arc_ops,
            &consumed_specs,
        );
        if (new_stream) |s| block_ptr.instructions = s;
    }

    // Rebuild the unconsumed remainder in source order. Records
    // belonging to other functions are unconditionally preserved.
    var unconsumed_arc_ops: std.ArrayListUnmanaged(escape_lattice.ArcOperation) = .empty;
    defer unconsumed_arc_ops.deinit(allocator);
    for (analysis_context.arc_ops.items, 0..) |op, src_idx| {
        if (op.insertion_point.function != function.id) {
            try unconsumed_arc_ops.append(allocator, op);
            continue;
        }
        if (consumed_arc_ops.contains(src_idx)) continue;
        try unconsumed_arc_ops.append(allocator, op);
    }

    var unconsumed_specs: std.ArrayListUnmanaged(escape_lattice.DropSpecialization) = .empty;
    defer unconsumed_specs.deinit(allocator);
    for (analysis_context.drop_specializations.items, 0..) |spec, src_idx| {
        if (spec.function != function.id) {
            try unconsumed_specs.append(allocator, spec);
            continue;
        }
        if (consumed_specs.contains(src_idx)) continue;
        try unconsumed_specs.append(allocator, spec);
    }

    // Path slices for both consumed and unconsumed records are
    // owned by the analysis context and freed at its deinit.
    analysis_context.arc_ops.clearRetainingCapacity();
    try analysis_context.arc_ops.appendSlice(allocator, unconsumed_arc_ops.items);

    analysis_context.drop_specializations.clearRetainingCapacity();
    try analysis_context.drop_specializations.appendSlice(allocator, unconsumed_specs.items);
}

// ============================================================
// PendingTree — grouped insertions keyed by stream
// ============================================================

const InsertPosition = enum { before, after };

const Origin = struct {
    kind: enum { arc_op, drop_spec },
    /// Index into the source `analysis_context.arc_ops` /
    /// `drop_specializations` array this insertion came from.
    src_index: usize,
};

const PendingInsertion = struct {
    instr_index: u32,
    position: InsertPosition,
    new_instr: ir.Instruction,
    origin: Origin,
};

const StreamNode = struct {
    allocator: std.mem.Allocator,
    /// Insertions that target this stream directly (path ends here).
    direct: std.ArrayListUnmanaged(PendingInsertion) = .empty,
    /// Sub-stream descents keyed by StreamStep.
    children: std.ArrayListUnmanaged(ChildEntry) = .empty,

    fn deinit(self: *StreamNode) void {
        self.direct.deinit(self.allocator);
        for (self.children.items) |*entry| {
            entry.node.deinit();
            self.allocator.destroy(entry.node);
        }
        self.children.deinit(self.allocator);
    }

    fn findChild(self: *StreamNode, step: escape_lattice.StreamStep) ?*StreamNode {
        for (self.children.items) |entry| {
            if (streamStepEql(entry.step, step)) return entry.node;
        }
        return null;
    }

    fn getOrCreateChild(self: *StreamNode, step: escape_lattice.StreamStep) !*StreamNode {
        if (self.findChild(step)) |n| return n;
        const node = try self.allocator.create(StreamNode);
        node.* = .{ .allocator = self.allocator };
        try self.children.append(self.allocator, .{ .step = step, .node = node });
        return node;
    }
};

const ChildEntry = struct {
    step: escape_lattice.StreamStep,
    node: *StreamNode,
};

const PendingTree = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMapUnmanaged(ir.LabelId, StreamNode),

    fn init(allocator: std.mem.Allocator) PendingTree {
        return .{
            .allocator = allocator,
            .blocks = .empty,
        };
    }

    fn deinit(self: *PendingTree) void {
        var iter = self.blocks.valueIterator();
        while (iter.next()) |node| node.deinit();
        self.blocks.deinit(self.allocator);
    }

    const Request = struct {
        block: ir.LabelId,
        path: []const escape_lattice.StreamStep,
        instr_index: u32,
        position: InsertPosition,
        new_instr: ir.Instruction,
        origin: Origin,
    };

    fn add(self: *PendingTree, req: Request) !void {
        const gop = try self.blocks.getOrPut(self.allocator, req.block);
        if (!gop.found_existing) gop.value_ptr.* = .{ .allocator = self.allocator };
        var node: *StreamNode = gop.value_ptr;
        for (req.path) |step| {
            node = try node.getOrCreateChild(step);
        }
        try node.direct.append(self.allocator, .{
            .instr_index = req.instr_index,
            .position = req.position,
            .new_instr = req.new_instr,
            .origin = req.origin,
        });
    }
};

fn streamStepEql(a: escape_lattice.StreamStep, b: escape_lattice.StreamStep) bool {
    if (a.parent_instr_index != b.parent_instr_index) return false;
    if (@as(std.meta.Tag(escape_lattice.ChildSlot), a.child) != @as(std.meta.Tag(escape_lattice.ChildSlot), b.child)) return false;
    return switch (a.child) {
        .case_block_arm_cond => |idx| idx == b.child.case_block_arm_cond,
        .case_block_arm_body => |idx| idx == b.child.case_block_arm_body,
        .switch_literal_case => |idx| idx == b.child.switch_literal_case,
        .switch_return_case => |idx| idx == b.child.switch_return_case,
        .union_switch_case => |idx| idx == b.child.union_switch_case,
        .union_switch_return_case => |idx| idx == b.child.union_switch_return_case,
        else => true,
    };
}

// ============================================================
// Stream rebuilding (mirrors arc_drop_insertion.StreamRebuilder)
// ============================================================

/// Rebuild a stream by:
///   1) recursively rebuilding any nested sub-stream that has
///      pending insertions in `node.children`,
///   2) interleaving `node.direct` insertions at their
///      `(instr_index, position)` coordinates.
/// Returns `null` when nothing in or below the stream changed.
fn rebuildStream(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    node: *StreamNode,
    consumed_arc_ops: *std.AutoHashMapUnmanaged(usize, void),
    consumed_specs: *std.AutoHashMapUnmanaged(usize, void),
) error{OutOfMemory}!?[]const ir.Instruction {
    // Pass 1: descend into children. Build a parallel array of
    // possibly-rebuilt instructions for any index whose children
    // changed.
    var rebuilt_at: std.AutoHashMapUnmanaged(u32, ir.Instruction) = .empty;
    defer rebuilt_at.deinit(allocator);

    for (node.children.items) |entry| {
        const parent_idx = entry.step.parent_instr_index;
        if (parent_idx >= stream.len) continue;
        const parent_instr = stream[parent_idx];
        const base: ir.Instruction = rebuilt_at.get(parent_idx) orelse parent_instr;
        const updated_opt = try rebuildOneChild(allocator, base, entry.step.child, entry.node, consumed_arc_ops, consumed_specs);
        if (updated_opt) |updated| {
            try rebuilt_at.put(allocator, parent_idx, updated);
        }
    }

    // Pass 2: schedule direct insertions, bounds-checking each.
    var scheduled: std.ArrayListUnmanaged(PendingInsertion) = .empty;
    defer scheduled.deinit(allocator);
    for (node.direct.items) |ins| {
        if (ins.instr_index > stream.len) continue;
        try scheduled.append(allocator, ins);
    }

    if (rebuilt_at.count() == 0 and scheduled.items.len == 0) return null;

    // Pass 3: produce the new stream. Sort scheduled insertions by
    // (instr_index ascending, before-before-after).
    std.mem.sort(PendingInsertion, scheduled.items, {}, insertionLessThan);

    const new_total = stream.len + scheduled.items.len;
    const new_slice = try allocator.alloc(ir.Instruction, new_total);
    var write_idx: usize = 0;
    var ins_idx: usize = 0;
    for (stream, 0..) |instr, read_idx| {
        const read_u32: u32 = @intCast(read_idx);
        while (ins_idx < scheduled.items.len) {
            const ins = scheduled.items[ins_idx];
            if (ins.position == .before and ins.instr_index == read_u32) {
                new_slice[write_idx] = ins.new_instr;
                try markConsumed(allocator, consumed_arc_ops, consumed_specs, ins.origin);
                write_idx += 1;
                ins_idx += 1;
            } else break;
        }
        new_slice[write_idx] = rebuilt_at.get(read_u32) orelse instr;
        write_idx += 1;
        while (ins_idx < scheduled.items.len) {
            const ins = scheduled.items[ins_idx];
            if (ins.position == .after and ins.instr_index == read_u32) {
                new_slice[write_idx] = ins.new_instr;
                try markConsumed(allocator, consumed_arc_ops, consumed_specs, ins.origin);
                write_idx += 1;
                ins_idx += 1;
            } else break;
        }
    }
    // "Past the end" tail (records using `instr_index == stream.len`
    // for "append at end" of a stream).
    while (ins_idx < scheduled.items.len) {
        new_slice[write_idx] = scheduled.items[ins_idx].new_instr;
        try markConsumed(allocator, consumed_arc_ops, consumed_specs, scheduled.items[ins_idx].origin);
        write_idx += 1;
        ins_idx += 1;
    }
    std.debug.assert(write_idx == new_total);
    return new_slice;
}

/// Descend into one specific child slot of one parent instruction.
/// Returns the rebuilt parent (a copy with the rewritten sub-stream)
/// or `null` if no rewriting was needed below this slot.
fn rebuildOneChild(
    allocator: std.mem.Allocator,
    parent: ir.Instruction,
    slot: escape_lattice.ChildSlot,
    child_node: *StreamNode,
    consumed_arc_ops: *std.AutoHashMapUnmanaged(usize, void),
    consumed_specs: *std.AutoHashMapUnmanaged(usize, void),
) error{OutOfMemory}!?ir.Instruction {
    return switch (slot) {
        .if_expr_then => blk: {
            if (parent != .if_expr) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.if_expr.then_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.if_expr;
            copy.then_instrs = new_stream.?;
            break :blk ir.Instruction{ .if_expr = copy };
        },
        .if_expr_else => blk: {
            if (parent != .if_expr) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.if_expr.else_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.if_expr;
            copy.else_instrs = new_stream.?;
            break :blk ir.Instruction{ .if_expr = copy };
        },
        .case_block_pre => blk: {
            if (parent != .case_block) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.case_block.pre_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.case_block;
            copy.pre_instrs = new_stream.?;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .case_block_arm_cond => |arm_idx| blk: {
            if (parent != .case_block) break :blk null;
            const arms = parent.case_block.arms;
            if (arm_idx >= arms.len) break :blk null;
            const new_stream = try rebuildStream(allocator, arms[arm_idx].cond_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_arms = try cloneArmsWithReplacedStream(allocator, arms, arm_idx, .cond, new_stream.?);
            var copy = parent.case_block;
            copy.arms = new_arms;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .case_block_arm_body => |arm_idx| blk: {
            if (parent != .case_block) break :blk null;
            const arms = parent.case_block.arms;
            if (arm_idx >= arms.len) break :blk null;
            const new_stream = try rebuildStream(allocator, arms[arm_idx].body_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_arms = try cloneArmsWithReplacedStream(allocator, arms, arm_idx, .body, new_stream.?);
            var copy = parent.case_block;
            copy.arms = new_arms;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .case_block_default => blk: {
            if (parent != .case_block) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.case_block.default_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.case_block;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .switch_literal_case => |case_idx| blk: {
            if (parent != .switch_literal) break :blk null;
            const cases = parent.switch_literal.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rebuildStream(allocator, cases[case_idx].body_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneLitCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.switch_literal;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .switch_literal = copy };
        },
        .switch_literal_default => blk: {
            if (parent != .switch_literal) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.switch_literal.default_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.switch_literal;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .switch_literal = copy };
        },
        .switch_return_case => |case_idx| blk: {
            if (parent != .switch_return) break :blk null;
            const cases = parent.switch_return.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rebuildStream(allocator, cases[case_idx].body_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneReturnCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.switch_return;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .switch_return = copy };
        },
        .switch_return_default => blk: {
            if (parent != .switch_return) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.switch_return.default_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.switch_return;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .switch_return = copy };
        },
        .union_switch_case => |case_idx| blk: {
            if (parent != .union_switch) break :blk null;
            const cases = parent.union_switch.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rebuildStream(allocator, cases[case_idx].body_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneUnionCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.union_switch;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .union_switch = copy };
        },
        .union_switch_return_case => |case_idx| blk: {
            if (parent != .union_switch_return) break :blk null;
            const cases = parent.union_switch_return.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rebuildStream(allocator, cases[case_idx].body_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneUnionCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.union_switch_return;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .union_switch_return = copy };
        },
        .try_call_named_success => blk: {
            if (parent != .try_call_named) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.try_call_named.success_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.try_call_named;
            copy.success_instrs = new_stream.?;
            break :blk ir.Instruction{ .try_call_named = copy };
        },
        .try_call_named_handler => blk: {
            if (parent != .try_call_named) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.try_call_named.handler_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.try_call_named;
            copy.handler_instrs = new_stream.?;
            break :blk ir.Instruction{ .try_call_named = copy };
        },
        .guard_block_body => blk: {
            if (parent != .guard_block) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.guard_block.body, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.guard_block;
            copy.body = new_stream.?;
            break :blk ir.Instruction{ .guard_block = copy };
        },
        .optional_dispatch_nil => blk: {
            if (parent != .optional_dispatch) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.optional_dispatch.nil_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.optional_dispatch;
            copy.nil_instrs = new_stream.?;
            break :blk ir.Instruction{ .optional_dispatch = copy };
        },
        .optional_dispatch_struct => blk: {
            if (parent != .optional_dispatch) break :blk null;
            const new_stream = try rebuildStream(allocator, parent.optional_dispatch.struct_instrs, child_node, consumed_arc_ops, consumed_specs);
            if (new_stream == null) break :blk null;
            var copy = parent.optional_dispatch;
            copy.struct_instrs = new_stream.?;
            break :blk ir.Instruction{ .optional_dispatch = copy };
        },
    };
}

fn markConsumed(
    allocator: std.mem.Allocator,
    consumed_arc_ops: *std.AutoHashMapUnmanaged(usize, void),
    consumed_specs: *std.AutoHashMapUnmanaged(usize, void),
    origin: Origin,
) error{OutOfMemory}!void {
    const map = switch (origin.kind) {
        .arc_op => consumed_arc_ops,
        .drop_spec => consumed_specs,
    };
    try map.put(allocator, origin.src_index, {});
}

// ============================================================
// Slice cloning helpers
// ============================================================

const ArmSlot = enum { cond, body };

fn cloneArmsWithReplacedStream(
    allocator: std.mem.Allocator,
    arms: []const ir.IrCaseArm,
    arm_idx: u32,
    slot: ArmSlot,
    new_stream: []const ir.Instruction,
) ![]const ir.IrCaseArm {
    const buf = try allocator.alloc(ir.IrCaseArm, arms.len);
    for (arms, 0..) |arm, i| buf[i] = arm;
    switch (slot) {
        .cond => buf[arm_idx].cond_instrs = new_stream,
        .body => buf[arm_idx].body_instrs = new_stream,
    }
    return buf;
}

fn cloneLitCasesWithReplacedBody(
    allocator: std.mem.Allocator,
    cases: []const ir.LitCase,
    case_idx: u32,
    new_body: []const ir.Instruction,
) ![]const ir.LitCase {
    const buf = try allocator.alloc(ir.LitCase, cases.len);
    for (cases, 0..) |c, i| buf[i] = c;
    buf[case_idx].body_instrs = new_body;
    return buf;
}

fn cloneReturnCasesWithReplacedBody(
    allocator: std.mem.Allocator,
    cases: []const ir.ReturnCase,
    case_idx: u32,
    new_body: []const ir.Instruction,
) ![]const ir.ReturnCase {
    const buf = try allocator.alloc(ir.ReturnCase, cases.len);
    for (cases, 0..) |c, i| buf[i] = c;
    buf[case_idx].body_instrs = new_body;
    return buf;
}

fn cloneUnionCasesWithReplacedBody(
    allocator: std.mem.Allocator,
    cases: []const ir.UnionCase,
    case_idx: u32,
    new_body: []const ir.Instruction,
) ![]const ir.UnionCase {
    const buf = try allocator.alloc(ir.UnionCase, cases.len);
    for (cases, 0..) |c, i| buf[i] = c;
    buf[case_idx].body_instrs = new_body;
    return buf;
}

// ============================================================
// Misc helpers
// ============================================================

fn findBlockByLabel(function: *const ir.Function, label: ir.LabelId) ?usize {
    for (function.body, 0..) |block, idx| {
        if (block.label == label) return idx;
    }
    return null;
}

fn insertionLessThan(_: void, a: PendingInsertion, b: PendingInsertion) bool {
    if (a.instr_index != b.instr_index) return a.instr_index < b.instr_index;
    return a.position == .before and b.position == .after;
}
