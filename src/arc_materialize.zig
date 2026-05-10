// ============================================================
// ARC analysis-record materialization pass.
//
// Phase 2 of the IR-source-of-truth ARC refactor (see
// `docs/arc-emission-architecture-research-brief.md`). This pass
// converts the analysis records produced by `perceus.zig` and
// `arc_optimizer.zig` (`actx.arc_ops`, `actx.drop_specializations`)
// into first-class `.retain { kind }` / `.release { kind }` IR
// instructions inserted directly into the function body. Once the
// records are materialized, the corresponding ZIR-time emit helpers
// (`emitAnalysisArcOps`, `emitDropSpecializationsForCurrentInstr`)
// observe an empty input list and become no-ops — the IR is the
// single source of truth for every retain/release the program
// executes.
//
// Pipeline placement: after `arc_drop_insertion.insertScopeExitDrops`
// and before the post-drop verifier in `compiler.zig`. arc_liveness's
// `live_before_ret` tables become stale post-insertion; that's
// fine because no consumer downstream needs them.
//
// Currently handles:
//   * `actx.arc_ops` `.retain`/`.release` records whose insertion
//     point is in a TOP-LEVEL block of the function body. Records
//     pointing into nested streams (if_expr arms, case_block arms,
//     etc.) are left in place — `emitAnalysisArcOps` continues to
//     emit them at ZIR time. As the pass's reach is extended into
//     nested streams in follow-up commits, the emit helper's input
//     shrinks until it can be deleted entirely.
//   * `actx.drop_specializations` records similarly, emitting
//     `.release { kind: .release | .free }` for each `FieldDrop`.
//     Same nested-stream limitation.
//
// Out of scope (Phase 3 follow-up):
//   * `actx.reuse_pairs` — `.reset` and `.reuse_alloc` IR. Perceus
//     allocates synthetic LocalIds (`10000 + match_site_id` per
//     `perceus.zig:682`); materializing requires either real-local
//     allocation or a synthetic-ID handling layer. Deferred.
//   * `actx.arc_ops` `.reset`/`.reuse_alloc`/`.move_transfer`/`.share`
//     kinds — these correspond to Phase 3 work or are dataflow
//     markers (`move_transfer`, `share`) that don't lower to IR
//     instructions of their own.
//
// Invariant: a record is removed from its analysis-context list
// only after the corresponding IR has been inserted successfully.
// Failure paths leave the record in place so the ZIR-time helper
// fires as a fallback.
// ============================================================

const std = @import("std");
const ir = @import("ir.zig");
const escape_lattice = @import("escape_lattice.zig");

/// Top-level entry point. Walks `analysis_context.arc_ops` and
/// `analysis_context.drop_specializations`, materializing records
/// whose insertion point is at top-level into `.retain`/`.release`
/// IR. Records pointing into nested streams stay in place for the
/// ZIR-time helpers to handle.
pub fn materializeAnalysisArcOps(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
) !void {
    try materializeArcOps(allocator, function, analysis_context);
    try materializeDropSpecializations(allocator, function, analysis_context);
}

fn materializeArcOps(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
) !void {
    // Collect arc_ops that target a top-level block in this function.
    // Group them by (block_index, instr_index, position) so multiple
    // insertions at the same site are batched and applied in reverse
    // order (to avoid index shifting).

    var ops_remaining: std.ArrayListUnmanaged(escape_lattice.ArcOperation) = .empty;
    defer ops_remaining.deinit(allocator);

    // Per-block scheduled insertions: list of (instr_index, position, ir.Instruction).
    var schedule_by_block: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(ScheduledInsertion)) = .empty;
    defer {
        var iter = schedule_by_block.valueIterator();
        while (iter.next()) |list| list.deinit(allocator);
        schedule_by_block.deinit(allocator);
    }

    for (analysis_context.arc_ops.items) |op| {
        if (op.insertion_point.function != function.id) {
            try ops_remaining.append(allocator, op);
            continue;
        }
        const new_instr: ?ir.Instruction = switch (op.kind) {
            .retain => ir.Instruction{ .retain = .{ .value = op.value } },
            .release => ir.Instruction{ .release = .{ .value = op.value } },
            // Phase 3 / out of scope: these are deferred. Keep the
            // record in place so the ZIR-time helper handles them.
            .reset, .reuse_alloc, .move_transfer, .share => null,
        };
        if (new_instr == null) {
            try ops_remaining.append(allocator, op);
            continue;
        }

        const block_index = findBlockByLabel(function, op.insertion_point.block) orelse {
            // Non-top-level block (insertion target is a nested
            // stream). Skip — emitAnalysisArcOps still handles it.
            try ops_remaining.append(allocator, op);
            continue;
        };

        const gop = try schedule_by_block.getOrPut(allocator, block_index);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, .{
            .instr_index = op.insertion_point.instr_index,
            .position = if (op.insertion_point.position == .before) .before else .after,
            .new_instr = new_instr.?,
        });
    }

    // Apply scheduled insertions per-block.
    var schedule_iter = schedule_by_block.iterator();
    while (schedule_iter.next()) |entry| {
        const block_index = entry.key_ptr.*;
        const insertions = entry.value_ptr.items;
        try applyInsertionsToBlock(allocator, function, block_index, insertions);
    }

    // Replace arc_ops with the unconsumed remainder.
    analysis_context.arc_ops.clearRetainingCapacity();
    for (ops_remaining.items) |op| {
        try analysis_context.arc_ops.append(allocator, op);
    }
}

fn materializeDropSpecializations(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
) !void {
    var specs_remaining: std.ArrayListUnmanaged(escape_lattice.DropSpecialization) = .empty;
    defer specs_remaining.deinit(allocator);

    var schedule_by_block: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(ScheduledInsertion)) = .empty;
    defer {
        var iter = schedule_by_block.valueIterator();
        while (iter.next()) |list| list.deinit(allocator);
        schedule_by_block.deinit(allocator);
    }

    for (analysis_context.drop_specializations.items) |spec| {
        if (spec.function != function.id) {
            try specs_remaining.append(allocator, spec);
            continue;
        }
        const block_index = findBlockByLabel(function, spec.insertion_point.block) orelse {
            try specs_remaining.append(allocator, spec);
            continue;
        };
        const gop = try schedule_by_block.getOrPut(allocator, block_index);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (spec.field_drops) |fd| {
            // The field_drop's `local` (when set) is the LocalId to
            // release. When not set, the spec's parent value is the
            // target — but the parent's LocalId isn't in the spec
            // record itself; the existing emit helper looks it up
            // via the case_block dest tracked by the ZIR driver.
            // For materialization, only field_drops with explicit
            // `local` set can be resolved without driver state;
            // others are kept in the unmaterialized remainder.
            const target_local = fd.local orelse {
                try specs_remaining.append(allocator, spec);
                continue;
            };
            const release_kind: ir.ReleaseKind = switch (fd.kind) {
                .deep => .release,
                .shallow => .free,
            };
            try gop.value_ptr.append(allocator, .{
                .instr_index = spec.insertion_point.instr_index,
                .position = if (spec.insertion_point.position == .before) .before else .after,
                .new_instr = ir.Instruction{ .release = .{ .value = target_local, .kind = release_kind } },
            });
        }
    }

    var schedule_iter = schedule_by_block.iterator();
    while (schedule_iter.next()) |entry| {
        const block_index = entry.key_ptr.*;
        const insertions = entry.value_ptr.items;
        try applyInsertionsToBlock(allocator, function, block_index, insertions);
    }

    analysis_context.drop_specializations.clearRetainingCapacity();
    for (specs_remaining.items) |spec| {
        try analysis_context.drop_specializations.append(allocator, spec);
    }
}

const ScheduledInsertion = struct {
    instr_index: u32,
    position: enum { before, after },
    new_instr: ir.Instruction,
};

fn findBlockByLabel(function: *const ir.Function, label: ir.LabelId) ?usize {
    for (function.body, 0..) |block, idx| {
        if (block.label == label) return idx;
    }
    return null;
}

/// Apply a batch of insertions to a single block. Insertions are
/// sorted by descending `instr_index` then by `position` (after
/// before before, since "after k" inserts at k+1 which is to the
/// right of "before k"). Allocates a fresh instruction slice.
fn applyInsertionsToBlock(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    block_index: usize,
    insertions: []ScheduledInsertion,
) !void {
    if (insertions.len == 0) return;

    // Sort by ascending insertion-effective-index. The effective
    // insert index for a `before k` is k; for `after k` is k+1.
    // Building the new slice in a single forward pass requires
    // sorted insertion points.
    std.mem.sort(ScheduledInsertion, insertions, {}, scheduledInsertionLessThan);

    const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
    const original = block_ptr.instructions;

    const new_total = original.len + insertions.len;
    const new_slice = try allocator.alloc(ir.Instruction, new_total);

    var write_idx: usize = 0;
    var ins_idx: usize = 0;
    for (original, 0..) |instr, read_idx| {
        // Emit any insertions whose effective index is at this read_idx
        // and `before` position.
        while (ins_idx < insertions.len) {
            const ins = insertions[ins_idx];
            if (ins.position == .before and ins.instr_index == @as(u32, @intCast(read_idx))) {
                new_slice[write_idx] = ins.new_instr;
                write_idx += 1;
                ins_idx += 1;
            } else break;
        }
        // Emit the original instruction.
        new_slice[write_idx] = instr;
        write_idx += 1;
        // Emit any insertions whose effective index is at this read_idx
        // and `after` position.
        while (ins_idx < insertions.len) {
            const ins = insertions[ins_idx];
            if (ins.position == .after and ins.instr_index == @as(u32, @intCast(read_idx))) {
                new_slice[write_idx] = ins.new_instr;
                write_idx += 1;
                ins_idx += 1;
            } else break;
        }
    }
    // Any remaining insertions whose instr_index is past the end (a
    // common pattern for "after the last instruction") fall through
    // here. Emit them in order.
    while (ins_idx < insertions.len) {
        new_slice[write_idx] = insertions[ins_idx].new_instr;
        write_idx += 1;
        ins_idx += 1;
    }
    std.debug.assert(write_idx == new_total);
    block_ptr.instructions = new_slice;
}

fn scheduledInsertionLessThan(_: void, a: ScheduledInsertion, b: ScheduledInsertion) bool {
    if (a.instr_index != b.instr_index) return a.instr_index < b.instr_index;
    // Same instr_index: `before` sorts before `after`.
    return a.position == .before and b.position == .after;
}
