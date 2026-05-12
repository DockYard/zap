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
const elision = @import("memory/elision.zig");

/// Allocator for fresh `LocalId`s materialized into a function during
/// the ARC-record lowering pass. Mirrors `Lean 4`'s `mkFresh`, Roc's
/// `gen_unique`, Cranelift's `declare_var`, and Swift `SILBuilder`'s
/// fresh-variable mechanism: a single source of new IDs that grows the
/// function's local-slot space monotonically and extends the dense
/// `local_ownership` slice in lock-step so every downstream pass that
/// indexes by LocalId still sees a well-formed function.
///
/// Usage: `init(function, allocator)` → `alloc(ownership)` per fresh ID
/// → `commit()` once after all allocations land. The `commit` step
/// rewrites `function.local_ownership` to a freshly-allocated slice
/// holding the original ownership entries plus one entry per
/// allocated ID. Without `commit`, `local_count` is bumped but the
/// ownership table stays stale.
pub const LocalAllocator = struct {
    function: *ir.Function,
    allocator: std.mem.Allocator,
    new_ownerships: std.ArrayListUnmanaged(ir.OwnershipClass),

    pub fn init(function: *ir.Function, allocator: std.mem.Allocator) LocalAllocator {
        return .{
            .function = function,
            .allocator = allocator,
            .new_ownerships = .empty,
        };
    }

    pub fn deinit(self: *LocalAllocator) void {
        self.new_ownerships.deinit(self.allocator);
    }

    /// Allocate a fresh `LocalId` and record its `OwnershipClass`.
    /// The returned ID is unique within the function and dense — it
    /// equals the previous `local_count`, so subsequent allocations
    /// produce consecutive IDs.
    pub fn alloc(self: *LocalAllocator, ownership: ir.OwnershipClass) !ir.LocalId {
        const id = self.function.local_count;
        self.function.local_count += 1;
        try self.new_ownerships.append(self.allocator, ownership);
        return id;
    }

    /// Apply the accumulated ownership entries to the function's
    /// `local_ownership` slice. Must be called once after the last
    /// `alloc` and before any pass that reads `local_ownership`.
    ///
    /// Allocates a new slice of length `old_len + count` and copies
    /// the old contents in front of the new entries. The old slice
    /// belonged to the IR builder's arena and is left untouched —
    /// freeing it here would conflict with the arena's lifetime.
    pub fn commit(self: *LocalAllocator) !void {
        if (self.new_ownerships.items.len == 0) return;
        const old = self.function.local_ownership;
        const new_len = old.len + self.new_ownerships.items.len;
        const new_buf = try self.allocator.alloc(ir.OwnershipClass, new_len);
        @memcpy(new_buf[0..old.len], old);
        @memcpy(new_buf[old.len..], self.new_ownerships.items);
        self.function.local_ownership = new_buf;
        self.new_ownerships.clearRetainingCapacity();
    }
};

/// Top-level entry point. Walks `analysis_context.arc_ops` and
/// `analysis_context.drop_specializations`, materializing every
/// record whose `(function, block, path, instr_index)` can be
/// resolved to a concrete position in this function. Records
/// whose path can't be resolved (other function, non-existent
/// block, out-of-bounds path step, deferred kind) remain in
/// the analysis context.
///
/// `declared_caps` carries the active manager's `.zapmem` capability
/// bitmask. When the manager does not declare `REFCOUNT_V1` (Phase 6
/// elision), no `.retain` / `.release` / `.reset` IR is materialized
/// and the reuse-token rewrite is skipped — `Map(K,V)` / `List(T)` /
/// `Arc(T)` cells in that mode have no refcount, so Perceus-style
/// reuse and retain/release sequencing has no semantic meaning.
pub fn materializeAnalysisArcOps(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
    declared_caps: u64,
) !void {
    const emit_refcount_ops = elision.shouldEmitRefcountOps(declared_caps);

    // Replace the synthetic-LocalId placeholder perceus emits for
    // reset tokens (`10000 + match_site_id`) with real LocalIds
    // allocated against the function's slot space. After this
    // rewrite the synthetic IDs are gone from `reuse_pairs`; every
    // downstream consumer (the `.reset` IR materialization below,
    // the construction-instruction rewrite, the ZIR backend's
    // `refForLocal`) sees real, dense IDs.
    //
    // Skip under Phase 6 elision: with no REFCOUNT_V1, `.reset` IR
    // is not materialized, so reuse_pairs' tokens go un-consumed and
    // the construction-instruction rewrite below is a no-op.
    if (emit_refcount_ops) {
        try rewriteReuseTokensToRealLocals(allocator, function, analysis_context);
    }

    // Rewrite each reuse_pair's construction instruction
    // (tuple_init / struct_init / union_init) to carry the
    // `reuse_token` field. The ZIR backend's tuple_init /
    // struct_init / union_init handlers dispatch on this field,
    // routing through `emitReuseAllocCall` when set — the single
    // canonical `reuseAllocByType` emission site.
    if (emit_refcount_ops) {
        try rewriteReuseConstructions(allocator, function, analysis_context);
    }

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
    //
    // Phase 6 elision: under a non-REFCOUNT_V1 manager, no retain/
    // release/reset IR is materialized — the analysis-context
    // records still flow through (so other passes that inspect
    // them keep working) but nothing lands in the IR stream and
    // the ZIR backend emits zero refcount ops.
    if (emit_refcount_ops) {
        for (analysis_context.arc_ops.items, 0..) |op, src_idx| {
            if (op.insertion_point.function != function.id) continue;
            const new_instr: ir.Instruction = switch (op.kind) {
                .retain => .{ .retain = .{ .value = op.value } },
                .release => .{ .release = .{ .value = op.value } },
                // `.reset` materializes to an IR `.reset { dest, source }`
                // where `dest` is the token LocalId allocated by
                // `rewriteReuseTokensToRealLocals` (looked up via
                // `analysis_context.reuse_pairs` keyed on this arc_op's
                // source local).
                .reset => blk: {
                    const token_dest = findResetTokenForSource(analysis_context, function.id, op.value) orelse continue;
                    break :blk ir.Instruction{ .reset = .{ .dest = token_dest, .source = op.value } };
                },
                // `.reuse_alloc` is consumed by `rewriteReuseConstructions`
                // (per-construction-instruction mutation, not insertion).
                // Skip it here.
                .reuse_alloc => continue,
                // Dataflow-only kinds stay in the analysis context — they're
                // markers, not IR-emitting.
                .move_transfer, .share => continue,
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

/// Walk `analysis_context.reuse_pairs` and replace every reset
/// token's synthetic LocalId (`10000 + match_site_id` per
/// `perceus.zig:generateReusePair`) with a fresh real LocalId
/// allocated against the function's local-slot space. Updates
/// both `pair.reset.dest` and `pair.reuse.token` in place, plus
/// any `arc_op` whose `value` references the same synthetic ID.
/// After this pass, the synthetic placeholders are gone — every
/// downstream consumer (`materializeAnalysisArcOps`'s `.reset`
/// branch, `rewriteReuseConstructions`, the ZIR backend's
/// `refForLocal`) sees real LocalIds.
///
/// Token ownership is `.owned` — `resetAny` returns an opaque
/// pointer that downstream `reuseAllocByType` either reuses (the
/// RC=1 path returns the same pointer back) or discards (null
/// token triggers fresh allocation). Either way the SSA value
/// owns the slot.
fn rewriteReuseTokensToRealLocals(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *escape_lattice.AnalysisContext,
) !void {
    var token_remap: std.AutoHashMapUnmanaged(ir.LocalId, ir.LocalId) = .empty;
    defer token_remap.deinit(allocator);

    var local_allocator = LocalAllocator.init(function, allocator);
    defer local_allocator.deinit();

    // Pass 1: rewrite every reuse_pair belonging to this function.
    // Use a single fresh LocalId per match_site so a reset followed
    // by its paired reuse_alloc share the same token slot.
    for (analysis_context.reuse_pairs.items) |*pair| {
        if (pair.reuse.insertion_point.function != function.id) continue;
        const old_token = pair.reset.dest;
        const gop = try token_remap.getOrPut(allocator, old_token);
        if (!gop.found_existing) {
            gop.value_ptr.* = try local_allocator.alloc(.owned);
        }
        const new_token = gop.value_ptr.*;
        pair.reset.dest = new_token;
        if (pair.reuse.token) |_| pair.reuse.token = new_token;
    }

    if (token_remap.count() == 0) return;

    // Pass 2: rewrite arc_ops in the same function whose `value`
    // references one of the remapped tokens. Perceus does not
    // currently emit such arc_ops directly — the synthetic token
    // appears only in reuse_pairs — but rewriting is safe and
    // future-proofs the pass against new emitters that key on the
    // same shared LocalId.
    for (analysis_context.arc_ops.items) |*op| {
        if (op.insertion_point.function != function.id) continue;
        if (token_remap.get(op.value)) |new_id| {
            op.value = new_id;
        }
    }

    try local_allocator.commit();
}

/// Find the reset-token LocalId for the reuse_pair whose
/// `reset.source` matches `source_local` in `function_id`. Returns
/// `null` if no matching pair exists (no reuse opportunity for
/// this deconstruction).
fn findResetTokenForSource(
    analysis_context: *const escape_lattice.AnalysisContext,
    function_id: ir.FunctionId,
    source_local: ir.LocalId,
) ?ir.LocalId {
    for (analysis_context.reuse_pairs.items) |pair| {
        if (pair.reuse.insertion_point.function != function_id) continue;
        if (pair.reset.source != source_local) continue;
        return pair.reset.dest;
    }
    return null;
}

/// Walk `analysis_context.reuse_pairs` and rewrite each matching
/// construction instruction (tuple_init / struct_init / union_init)
/// to carry the pair's reuse token in its `reuse_token` field. The
/// ZIR backend's canonical lowering reads `instruction.reuse_token`
/// directly and routes through `emitReuseAllocCall`. Construction
/// sites can live at any nesting depth; the rewrite walks the
/// `pair.reuse.insertion_point.path` the same way
/// `materializeAnalysisArcOps` does for retain/release records.
fn rewriteReuseConstructions(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    analysis_context: *const escape_lattice.AnalysisContext,
) !void {
    for (analysis_context.reuse_pairs.items) |pair| {
        if (pair.reuse.insertion_point.function != function.id) continue;
        const token = pair.reuse.token orelse continue;
        const block_index = findBlockByLabel(function, pair.reuse.insertion_point.block) orelse continue;
        const block_ptr: *ir.Block = @constCast(&function.body[block_index]);
        const new_stream = try rewriteOneConstructionInStream(
            allocator,
            block_ptr.instructions,
            pair.reuse.insertion_point.path,
            pair.reuse.insertion_point.instr_index,
            pair.reuse.dest,
            token,
        );
        if (new_stream) |s| block_ptr.instructions = s;
    }
}

/// Walk `stream` along `path` until we reach the innermost stream
/// containing the construction at `instr_index`. Rewrite that
/// instruction's `reuse_token` field. Returns a rebuilt slice
/// (heap-allocated) or `null` if no rewrite happened.
fn rewriteOneConstructionInStream(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    path: []const escape_lattice.StreamStep,
    instr_index: u32,
    expected_dest: ir.LocalId,
    token: ir.LocalId,
) error{OutOfMemory}!?[]const ir.Instruction {
    if (path.len == 0) {
        // Leaf stream: mutate the target instruction at `instr_index`.
        if (instr_index >= stream.len) return null;
        const target = stream[instr_index];
        const rewritten = rewriteConstructionInstruction(target, expected_dest, token) orelse return null;
        const new_slice = try allocator.alloc(ir.Instruction, stream.len);
        @memcpy(new_slice, stream);
        new_slice[instr_index] = rewritten;
        return new_slice;
    }

    // Descend one level into the path.
    const step = path[0];
    const parent_idx = step.parent_instr_index;
    if (parent_idx >= stream.len) return null;
    const parent = stream[parent_idx];
    const rebuilt_parent = try rewriteParentChild(allocator, parent, step.child, path[1..], instr_index, expected_dest, token) orelse return null;
    const new_slice = try allocator.alloc(ir.Instruction, stream.len);
    @memcpy(new_slice, stream);
    new_slice[parent_idx] = rebuilt_parent;
    return new_slice;
}

/// Recurse into one specific child slot of `parent`, replacing the
/// matched nested stream with one whose innermost construction has
/// been rewritten to carry the reuse_token. Returns the rebuilt
/// parent (a copy with its sub-stream slice updated) or `null` if
/// the rewrite couldn't be applied.
fn rewriteParentChild(
    allocator: std.mem.Allocator,
    parent: ir.Instruction,
    slot: escape_lattice.ChildSlot,
    rest_path: []const escape_lattice.StreamStep,
    instr_index: u32,
    expected_dest: ir.LocalId,
    token: ir.LocalId,
) error{OutOfMemory}!?ir.Instruction {
    return switch (slot) {
        .if_expr_then => blk: {
            if (parent != .if_expr) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.if_expr.then_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.if_expr;
            copy.then_instrs = new_stream.?;
            break :blk ir.Instruction{ .if_expr = copy };
        },
        .if_expr_else => blk: {
            if (parent != .if_expr) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.if_expr.else_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.if_expr;
            copy.else_instrs = new_stream.?;
            break :blk ir.Instruction{ .if_expr = copy };
        },
        .case_block_pre => blk: {
            if (parent != .case_block) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.case_block.pre_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.case_block;
            copy.pre_instrs = new_stream.?;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .case_block_arm_cond => |arm_idx| blk: {
            if (parent != .case_block) break :blk null;
            const arms = parent.case_block.arms;
            if (arm_idx >= arms.len) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, arms[arm_idx].cond_instrs, rest_path, instr_index, expected_dest, token);
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
            const new_stream = try rewriteOneConstructionInStream(allocator, arms[arm_idx].body_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            const new_arms = try cloneArmsWithReplacedStream(allocator, arms, arm_idx, .body, new_stream.?);
            var copy = parent.case_block;
            copy.arms = new_arms;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .case_block_default => blk: {
            if (parent != .case_block) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.case_block.default_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.case_block;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .case_block = copy };
        },
        .switch_literal_case => |case_idx| blk: {
            if (parent != .switch_literal) break :blk null;
            const cases = parent.switch_literal.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, cases[case_idx].body_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneLitCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.switch_literal;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .switch_literal = copy };
        },
        .switch_literal_default => blk: {
            if (parent != .switch_literal) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.switch_literal.default_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.switch_literal;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .switch_literal = copy };
        },
        .switch_return_case => |case_idx| blk: {
            if (parent != .switch_return) break :blk null;
            const cases = parent.switch_return.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, cases[case_idx].body_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneReturnCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.switch_return;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .switch_return = copy };
        },
        .switch_return_default => blk: {
            if (parent != .switch_return) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.switch_return.default_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.switch_return;
            copy.default_instrs = new_stream.?;
            break :blk ir.Instruction{ .switch_return = copy };
        },
        .union_switch_case => |case_idx| blk: {
            if (parent != .union_switch) break :blk null;
            const cases = parent.union_switch.cases;
            if (case_idx >= cases.len) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, cases[case_idx].body_instrs, rest_path, instr_index, expected_dest, token);
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
            const new_stream = try rewriteOneConstructionInStream(allocator, cases[case_idx].body_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            const new_cases = try cloneUnionCasesWithReplacedBody(allocator, cases, case_idx, new_stream.?);
            var copy = parent.union_switch_return;
            copy.cases = new_cases;
            break :blk ir.Instruction{ .union_switch_return = copy };
        },
        .try_call_named_success => blk: {
            if (parent != .try_call_named) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.try_call_named.success_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.try_call_named;
            copy.success_instrs = new_stream.?;
            break :blk ir.Instruction{ .try_call_named = copy };
        },
        .try_call_named_handler => blk: {
            if (parent != .try_call_named) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.try_call_named.handler_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.try_call_named;
            copy.handler_instrs = new_stream.?;
            break :blk ir.Instruction{ .try_call_named = copy };
        },
        .guard_block_body => blk: {
            if (parent != .guard_block) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.guard_block.body, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.guard_block;
            copy.body = new_stream.?;
            break :blk ir.Instruction{ .guard_block = copy };
        },
        .optional_dispatch_nil => blk: {
            if (parent != .optional_dispatch) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.optional_dispatch.nil_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.optional_dispatch;
            copy.nil_instrs = new_stream.?;
            break :blk ir.Instruction{ .optional_dispatch = copy };
        },
        .optional_dispatch_struct => blk: {
            if (parent != .optional_dispatch) break :blk null;
            const new_stream = try rewriteOneConstructionInStream(allocator, parent.optional_dispatch.struct_instrs, rest_path, instr_index, expected_dest, token);
            if (new_stream == null) break :blk null;
            var copy = parent.optional_dispatch;
            copy.struct_instrs = new_stream.?;
            break :blk ir.Instruction{ .optional_dispatch = copy };
        },
    };
}

/// Set the `reuse_token` field of `instr` if it's a tuple_init,
/// struct_init, or union_init whose `dest` matches `expected_dest`.
/// Returns the rewritten instruction or `null` if the shape didn't
/// match.
fn rewriteConstructionInstruction(
    instr: ir.Instruction,
    expected_dest: ir.LocalId,
    token: ir.LocalId,
) ?ir.Instruction {
    switch (instr) {
        .tuple_init => |ti| {
            if (ti.dest != expected_dest) return null;
            var copy = ti;
            copy.reuse_token = token;
            return ir.Instruction{ .tuple_init = copy };
        },
        .struct_init => |si| {
            if (si.dest != expected_dest) return null;
            var copy = si;
            copy.reuse_token = token;
            return ir.Instruction{ .struct_init = copy };
        },
        .union_init => |ui| {
            if (ui.dest != expected_dest) return null;
            var copy = ui;
            copy.reuse_token = token;
            return ir.Instruction{ .union_init = copy };
        },
        else => return null,
    }
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

// ============================================================
// Phase 6 elision tests
// ============================================================

/// Count `.retain` / `.release` / `.reset` instructions across every block
/// of `function`. Used by the Phase 6 elision tests below to assert
/// that `materializeAnalysisArcOps` materialises every refcount op when
/// the active manager declares REFCOUNT_V1 (`declared_caps =
/// REFCOUNT_V1_BIT`) and elides every refcount op when the manager
/// omits it (`declared_caps = 0`).
fn countRefcountInstrs(function: *const ir.Function) struct { retains: u32, releases: u32, resets: u32 } {
    var retains: u32 = 0;
    var releases: u32 = 0;
    var resets: u32 = 0;
    for (function.body) |block| {
        for (block.instructions) |instr| switch (instr) {
            .retain => retains += 1,
            .release => releases += 1,
            .reset => resets += 1,
            else => {},
        };
    }
    return .{ .retains = retains, .releases = releases, .resets = resets };
}

test "materializeAnalysisArcOps strips refcount ops under declared_caps=0" {
    // Build a fixture with two `param_get` instructions and a return.
    // Stage three arc_ops at the top-level block targeting consecutive
    // instruction indices: a retain on local 0, a release on local 1,
    // and a release on the return slot. Under REFCOUNT_V1, materialize
    // inserts a `.retain` and two `.release` instructions; under
    // declared_caps=0, none of them appear in the IR.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const params = try arena.alloc(ir.Param, 2);
    params[0] = .{ .name = "a", .type_expr = .string };
    params[1] = .{ .name = "b", .type_expr = .string };

    const stream = try arena.alloc(ir.Instruction, 3);
    stream[0] = .{ .param_get = .{ .dest = 0, .index = 0 } };
    stream[1] = .{ .param_get = .{ .dest = 1, .index = 1 } };
    stream[2] = .{ .ret = .{ .value = 0 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 2);
    local_ownership[0] = .owned;
    local_ownership[1] = .owned;

    var function = ir.Function{
        .id = 0,
        .name = "materialize_elision_fixture",
        .scope_id = 0,
        .arity = 2,
        .params = params,
        .return_type = .string,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var actx = escape_lattice.AnalysisContext.init(std.testing.allocator);
    defer actx.deinit();

    // Stage three arc_ops: retain on local 0 before instr 0, release on
    // local 1 after instr 1, release on local 0 before the ret. Three
    // distinct refcount op kinds is enough to lock in the elision
    // contract for every kind without exercising the rest of the
    // materialiser's nested-stream descent.
    try actx.arc_ops.append(std.testing.allocator, .{
        .kind = .retain,
        .value = 0,
        .insertion_point = .{
            .function = 0,
            .block = 0,
            .instr_index = 0,
            .position = .before,
        },
        .reason = .shared_binding,
    });
    try actx.arc_ops.append(std.testing.allocator, .{
        .kind = .release,
        .value = 1,
        .insertion_point = .{
            .function = 0,
            .block = 0,
            .instr_index = 1,
            .position = .after,
        },
        .reason = .scope_exit,
    });
    try actx.arc_ops.append(std.testing.allocator, .{
        .kind = .release,
        .value = 0,
        .insertion_point = .{
            .function = 0,
            .block = 0,
            .instr_index = 2,
            .position = .before,
        },
        .reason = .scope_exit,
    });

    try materializeAnalysisArcOps(arena, &function, &actx, 0);

    const counts = countRefcountInstrs(&function);
    try std.testing.expectEqual(@as(u32, 0), counts.retains);
    try std.testing.expectEqual(@as(u32, 0), counts.releases);
    try std.testing.expectEqual(@as(u32, 0), counts.resets);

    // The analysis-context records are preserved verbatim under
    // elision so downstream passes (Phase 7 tracking managers, the
    // V10 audit) can still inspect them. Three records in, three
    // records back out.
    try std.testing.expectEqual(@as(usize, 3), actx.arc_ops.items.len);
}

test "materializeAnalysisArcOps emits refcount ops under REFCOUNT_V1" {
    // Mirror image of the elision test: same fixture, declared_caps =
    // REFCOUNT_V1_BIT, asserts the expected `.retain` / `.release`
    // IR materializes. Locks the regression direction: tomorrow's
    // refactor that accidentally always-elides must fail both
    // tests, not just one.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const params = try arena.alloc(ir.Param, 2);
    params[0] = .{ .name = "a", .type_expr = .string };
    params[1] = .{ .name = "b", .type_expr = .string };

    const stream = try arena.alloc(ir.Instruction, 3);
    stream[0] = .{ .param_get = .{ .dest = 0, .index = 0 } };
    stream[1] = .{ .param_get = .{ .dest = 1, .index = 1 } };
    stream[2] = .{ .ret = .{ .value = 0 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 2);
    local_ownership[0] = .owned;
    local_ownership[1] = .owned;

    var function = ir.Function{
        .id = 0,
        .name = "materialize_emit_fixture",
        .scope_id = 0,
        .arity = 2,
        .params = params,
        .return_type = .string,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var actx = escape_lattice.AnalysisContext.init(std.testing.allocator);
    defer actx.deinit();

    try actx.arc_ops.append(std.testing.allocator, .{
        .kind = .retain,
        .value = 0,
        .insertion_point = .{
            .function = 0,
            .block = 0,
            .instr_index = 0,
            .position = .before,
        },
        .reason = .shared_binding,
    });
    try actx.arc_ops.append(std.testing.allocator, .{
        .kind = .release,
        .value = 1,
        .insertion_point = .{
            .function = 0,
            .block = 0,
            .instr_index = 1,
            .position = .after,
        },
        .reason = .scope_exit,
    });

    const abi = @import("memory/abi.zig");
    try materializeAnalysisArcOps(arena, &function, &actx, abi.REFCOUNT_V1_BIT);

    const counts = countRefcountInstrs(&function);
    try std.testing.expect(counts.retains >= 1);
    try std.testing.expect(counts.releases >= 1);
}
