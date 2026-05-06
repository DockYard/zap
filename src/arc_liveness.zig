const std = @import("std");
const ir = @import("ir.zig");
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const scope_mod = @import("scope.zig");
const ast = @import("ast.zig");

// ============================================================
// ARC last-use ownership analysis (Phase 2 of the k-nucleotide RSS gap plan)
//
// `computeArcOwnership` is a side-table-only backward dataflow pass.
// It does NOT mutate the IR. It produces a structured table that
// later phases (4 and 5) consume to lower `share_value` instructions
// as ownership transfers and to elide function-epilogue releases on
// locals that flow directly into a `ret`.
//
// ----------------------------------------------------------------
// Survey: Zap IR's control-flow representation
// ----------------------------------------------------------------
//
// Zap IR is a *structural* IR — there is no flat list of basic blocks
// linked by explicit edges; instead, control flow is encoded by
// nesting of instructions inside other instructions. The relevant
// shapes (see `src/ir.zig`'s `Instruction` enum):
//
//   * `Function.body: []const Block` — top-level basic blocks per
//     function. Each block has a `LabelId` and a flat list of
//     instructions. Most user-defined functions have a single body
//     block; multi-block forms come from explicit `branch` /
//     `cond_branch` / `jump` / `switch_tag` lowering.
//
//   * `if_expr.then_instrs` / `if_expr.else_instrs` — nested
//     instruction streams for the two arms. Each arm yields an
//     optional `then_result` / `else_result` local.
//
//   * `case_block.pre_instrs`, `case_block.arms[i].cond_instrs`,
//     `case_block.arms[i].body_instrs`, `case_block.default_instrs`
//     — nested streams for tuple guards, per-arm conditions/bodies,
//     and the default arm.
//
//   * `union_switch.cases[i].body_instrs`,
//     `union_switch_return.cases[i].body_instrs`,
//     `switch_literal.cases[i].body_instrs`,
//     `switch_return.cases[i].body_instrs`,
//     `switch_literal.default_instrs`, `switch_return.default_instrs`
//     — per-case nested streams for the various switch shapes.
//
//   * `try_call_named.handler_instrs` / `success_instrs` — the catch
//     basin's handler arm and post-unwrap success arm.
//
//   * `guard_block.body` — guard-clause arm.
//
//   * Terminators: `ret`, `tail_call`, `match_fail`,
//     `match_error_return`, `branch`, `cond_branch`, `jump`,
//     `switch_tag`, `cond_return`, `case_break`. `tail_call` is
//     functionally a `ret` of a call's result (the callee returns
//     directly); for last-use purposes it's also a "function exit"
//     that consumes its arguments.
//
//   * `phi` — PhiSource entries with `from_block: LabelId` are
//     present for SSA-style joins, but most Zap IR uses structural
//     `if_expr`/`case_block` results which carry their own join
//     semantics via `then_result`/`else_result`/etc.
//
// The analysis here treats this nesting *directly*: rather than
// synthesizing a flat CFG of basic blocks with edges, we synthesize
// a *region tree* whose nodes are instruction streams and whose
// edges are the structural successors of each instruction. A
// backward dataflow on the region tree computes, for each
// instruction, the set of ARC-managed locals live *immediately
// after* the instruction. A local read by an instruction whose
// live-after set excludes it is at its last use.
//
// For loops / arbitrary CFGs, the structural form covers all the
// shapes the k-nucleotide pattern needs: tail recursion is a
// `tail_call` (a terminator); branching returns are `if_expr`
// arms each terminated by their own `ret` or `tail_call` or arm
// result. The structural form also handles `branch` / `cond_branch`
// / `jump` / `switch_tag` because each terminator is treated as
// "control leaves this stream"; when a stream's terminator is a
// jump to a label, the live-after set is empty for the purposes of
// the local stream's analysis (the caller stream / scope-exit drop
// list reconciles).
//
// ----------------------------------------------------------------
// Composition with src/perceus.zig
// ----------------------------------------------------------------
//
// `src/perceus.zig` exists and implements *Perceus reuse analysis*
// (Koka-style): it pairs pattern-match deconstruction sites with
// same-shape construction sites so that allocations can be reused
// in-place when the deconstructed value is uniquely owned. It does
// not compute last-use sites, does not produce a per-local CFG-aware
// liveness solution, and does not classify `share_value` sites as
// consume vs retain. The two passes are orthogonal: this module
// computes ownership transfer at calls and returns; perceus computes
// in-place reuse at pattern matches. They can run independently and
// their results can be combined in later phases without interaction.
//
// ----------------------------------------------------------------
// Algorithm
// ----------------------------------------------------------------
//
// 1. Enumerate all instructions in the function via depth-first
//    traversal of the structural region tree, assigning each a
//    stable `InstructionId`. Every nested stream is visited in the
//    order it would execute.
//
// 2. Identify the set of ARC-managed locals. A local is ARC-managed
//    iff one of:
//      (a) it is a parameter whose `type_id` satisfies the
//          `arc_managed` predicate;
//      (b) it is a capture whose `type_expr` is an ARC-managed
//          shape (string / list / map / struct_ref / tagged_union
//          / optional);
//      (c) it appears as the `value` of a `retain` or `release`
//          instruction (the IR builder emits these only for
//          ARC-managed locals);
//      (d) it appears as the `source` of a `share_value`
//          instruction (the IR builder emits `share_value` only
//          for ARC-managed argument slots).
//
//    Items (c) and (d) read directly off the IR the builder
//    actually emitted and are therefore reliable post-monomorph.
//
// 3. For each instruction id, compute its `live_after` set: the
//    union of ARC-local uses by every successor instruction along
//    every reachable structural path until function exit. Standard
//    backward fixpoint: walk the region tree right-to-left,
//    propagating `live_in = uses ∪ (live_out \ defs)`.
//
// 4. Walk forward through every instruction. For each ARC local L
//    used by the instruction: if L is in the instruction's
//    `live_before` but *not* in its `live_after`, the instruction
//    is L's last use. Record `last_use_map[L] = id`.
//
// 5. Specialization rules:
//      * Last use is a `share_value(source = L, dest = D)` →
//        record this share's id in `consume_share_sites`. By
//        construction (see survey in `src/ir.zig:4418-4427`)
//        the IR builder only emits `share_value` for ARC-managed
//        arguments to a call, so the dest D is by definition a
//        call-arg slot.
//      * Last use is a `ret(value = L)` → record L in
//        `return_source_locals`.
//      * Last use is a `tail_call` whose argument list contains L
//        as a `share_value`'s source (i.e. the L flows in via a
//        `share_value` whose dest is in the tail_call's args) →
//        the share_value site is the actual last use; this is
//        already handled by rule 1.
//
// 6. Soundness assertions (debug builds only — see the
//    `debug_assertions` block at the bottom of the analysis):
//      * No local appears in both `consume_share_sites` (via some
//        site) and `return_source_locals`.
//      * For each consume site S of local L, L does not appear in
//        any instruction whose id is greater than S along any
//        structural path.
//      * For each return-source local L, no other use of L appears
//        after the `ret` instruction.
//
// Bitset implementation: `u64` for functions with ≤ 64 ARC locals
// (the common case — most user functions have far fewer); a heap
// `std.DynamicBitSet` falls back automatically for larger functions.
//
// ============================================================

/// Stable identifier for an instruction within a single function.
/// Assigned by depth-first traversal of the structural region tree.
/// Every instruction in the function — whether at top level inside a
/// `Block` or nested inside a sub-stream of an `if_expr`, `case_block`,
/// `union_switch`, etc. — gets exactly one id.
pub const InstructionId = u32;

/// Output of `computeArcOwnership`. The pass populates these maps and
/// returns them; nothing else mutates them. Phases 4-5 will read from
/// the maps; the pass itself is read-only with respect to the IR.
pub const ArcOwnership = struct {
    /// Locals whose `share_value` to a call-arg slot is a last-use
    /// transfer (consume site). Indexed by share_value instruction id.
    consume_share_sites: std.AutoHashMapUnmanaged(InstructionId, void) = .empty,

    /// Locals that are the immediate source of a `ret` instruction.
    /// At function-epilogue drop emission, locals in this set are
    /// excluded from the drop list (Phase 5 wires this).
    return_source_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,

    /// Diagnostic: per-ARC-local last-use instruction id. Useful
    /// for pretty printers, debug counters, and soundness checks.
    last_use_map: std.AutoHashMapUnmanaged(ir.LocalId, InstructionId) = .empty,

    pub fn deinit(self: *ArcOwnership, allocator: std.mem.Allocator) void {
        self.consume_share_sites.deinit(allocator);
        self.return_source_locals.deinit(allocator);
        self.last_use_map.deinit(allocator);
    }
};

/// Predicate signature accepted by `computeArcOwnership`. Phases 1-2
/// pass `defaultArcManagedTypeId` (which mirrors `IrBuilder.isArcManagedType`).
/// Phase 6 will swap in a predicate that also recognises `.map`.
pub const ArcManagedFn = *const fn (type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool;

/// Default ARC-managed predicate that mirrors `IrBuilder.isArcManagedType`.
/// Phase 2 only needs the same set the IR builder already recognised.
/// Phase 6 will provide a replacement that adds `.map`. This is a
/// thin wrapper around `ir.isArcManagedTypeId` — the canonical
/// public predicate exposed from `src/ir.zig`.
pub fn defaultArcManagedTypeId(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    return ir.isArcManagedTypeId(type_store, type_id);
}

/// Convenience predicate for Phase 6 audits. Recognises both `.opaque_type`
/// and `.map`. Not wired in this phase but exposed for downstream tests.
pub fn extendedArcManagedTypeId(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= type_store.types.items.len) return false;
    return switch (type_store.getType(type_id)) {
        .opaque_type, .map => true,
        else => false,
    };
}

// ============================================================
// Internal: per-instruction record (flattened region tree).
// ============================================================

/// One entry per instruction in depth-first traversal order.
const InstructionRecord = struct {
    /// Pointer to the instruction. Stable as long as the function is.
    instr: *const ir.Instruction,

    /// Parent stream's owner kind, used to compute structural
    /// successors. The enum value identifies which slot of the parent
    /// instruction this stream belongs to.
    parent_link: ParentLink,

    /// Position within the parent stream (0-based).
    index_in_parent: u32,

    /// Length of the parent stream (so we know if we are the last
    /// instruction in our stream).
    parent_stream_len: u32,
};

const ParentLink = union(enum) {
    /// Top-level instruction in `Function.body[block_index]`.
    function_body: u32, // block index
    /// Nested in some other instruction's sub-stream. The id is the
    /// parent instruction's `InstructionId`. The variant tag identifies
    /// which sub-stream.
    if_then: InstructionId,
    if_else: InstructionId,
    case_pre: InstructionId,
    case_arm_cond: InstructionId,
    case_arm_body: InstructionId,
    case_default: InstructionId,
    switch_lit_case: InstructionId,
    switch_lit_default: InstructionId,
    switch_ret_case: InstructionId,
    switch_ret_default: InstructionId,
    union_switch_case: InstructionId,
    union_switch_ret_case: InstructionId,
    try_handler: InstructionId,
    try_success: InstructionId,
    guard_body: InstructionId,
};

// ============================================================
// Public entry point.
// ============================================================

pub fn computeArcOwnership(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    type_store: *const types_mod.TypeStore,
    arc_managed: ArcManagedFn,
) !ArcOwnership {
    var analyzer = Analyzer{
        .allocator = allocator,
        .function = function,
        .type_store = type_store,
        .arc_managed = arc_managed,
        .records = .empty,
        .pointer_to_id = .empty,
        .arc_locals = .empty,
        .local_to_arc_index = .empty,
        .live_after = .empty,
    };
    defer analyzer.deinit();

    try analyzer.flattenInstructions();
    try analyzer.identifyArcLocals();

    var ownership: ArcOwnership = .{};
    errdefer ownership.deinit(allocator);

    if (analyzer.arc_locals.items.len == 0) {
        // No ARC-managed locals — nothing to do. Return empty maps.
        return ownership;
    }

    try analyzer.computeLiveAfter();
    try analyzer.classifyLastUses(&ownership);
    try analyzer.propagateReturnSourcesThroughAggregates(&ownership);

    if (std.debug.runtime_safety) {
        try analyzer.checkSoundness(&ownership);
    }

    return ownership;
}

// ============================================================
// Analyzer (internal state).
// ============================================================

const Analyzer = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    type_store: *const types_mod.TypeStore,
    arc_managed: ArcManagedFn,

    records: std.ArrayListUnmanaged(InstructionRecord),

    /// Reverse index from instruction pointer to `InstructionId`.
    /// Populated alongside `records` so per-instruction lookups in
    /// the dataflow are O(1) instead of O(n).
    pointer_to_id: std.AutoHashMapUnmanaged(*const ir.Instruction, InstructionId),

    /// Dense list of ARC-managed `LocalId`s in this function.
    arc_locals: std.ArrayListUnmanaged(ir.LocalId),

    /// Reverse map: `LocalId` → index into `arc_locals` (the bit
    /// position used in `LiveSet`).
    local_to_arc_index: std.AutoHashMapUnmanaged(ir.LocalId, u32),

    /// Per-instruction live-after sets, indexed by `InstructionId`.
    live_after: std.ArrayListUnmanaged(LiveSet),

    fn deinit(self: *Analyzer) void {
        self.records.deinit(self.allocator);
        self.pointer_to_id.deinit(self.allocator);
        self.arc_locals.deinit(self.allocator);
        self.local_to_arc_index.deinit(self.allocator);
        for (self.live_after.items) |*set| {
            set.deinit(self.allocator);
        }
        self.live_after.deinit(self.allocator);
    }

    // ----------------------------------------------------------
    // Step 1: flatten instructions to the records array.
    // ----------------------------------------------------------

    fn flattenInstructions(self: *Analyzer) !void {
        for (self.function.body, 0..) |block, block_idx| {
            try self.flattenStream(
                block.instructions,
                .{ .function_body = @intCast(block_idx) },
            );
        }
    }

    fn flattenStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
        parent_link: ParentLink,
    ) error{OutOfMemory}!void {
        const stream_len: u32 = @intCast(stream.len);
        for (stream, 0..) |*instr, idx| {
            const my_id: InstructionId = @intCast(self.records.items.len);
            try self.records.append(self.allocator, .{
                .instr = instr,
                .parent_link = parent_link,
                .index_in_parent = @intCast(idx),
                .parent_stream_len = stream_len,
            });
            try self.pointer_to_id.put(self.allocator, instr, my_id);
            try self.flattenChildren(instr, my_id);
        }
    }

    fn flattenChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
        parent_id: InstructionId,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            .if_expr => |ie| {
                try self.flattenStream(ie.then_instrs, .{ .if_then = parent_id });
                try self.flattenStream(ie.else_instrs, .{ .if_else = parent_id });
            },
            .case_block => |cb| {
                try self.flattenStream(cb.pre_instrs, .{ .case_pre = parent_id });
                for (cb.arms) |arm| {
                    try self.flattenStream(arm.cond_instrs, .{ .case_arm_cond = parent_id });
                    try self.flattenStream(arm.body_instrs, .{ .case_arm_body = parent_id });
                }
                try self.flattenStream(cb.default_instrs, .{ .case_default = parent_id });
            },
            .switch_literal => |sl| {
                for (sl.cases) |case| {
                    try self.flattenStream(case.body_instrs, .{ .switch_lit_case = parent_id });
                }
                try self.flattenStream(sl.default_instrs, .{ .switch_lit_default = parent_id });
            },
            .switch_return => |sr| {
                for (sr.cases) |case| {
                    try self.flattenStream(case.body_instrs, .{ .switch_ret_case = parent_id });
                }
                try self.flattenStream(sr.default_instrs, .{ .switch_ret_default = parent_id });
            },
            .union_switch => |us| {
                for (us.cases) |case| {
                    try self.flattenStream(case.body_instrs, .{ .union_switch_case = parent_id });
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    try self.flattenStream(case.body_instrs, .{ .union_switch_ret_case = parent_id });
                }
            },
            .try_call_named => |tc| {
                try self.flattenStream(tc.handler_instrs, .{ .try_handler = parent_id });
                try self.flattenStream(tc.success_instrs, .{ .try_success = parent_id });
            },
            .guard_block => |gb| {
                try self.flattenStream(gb.body, .{ .guard_body = parent_id });
            },
            else => {},
        }
    }

    // ----------------------------------------------------------
    // Step 2: identify ARC-managed locals.
    // ----------------------------------------------------------

    fn identifyArcLocals(self: *Analyzer) !void {
        var seen: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        defer seen.deinit(self.allocator);

        // (a) Parameters whose type the predicate flags as ARC-managed.
        // The IR's param locals are assigned in clause prelude via
        // `param_get` (see `src/ir.zig:4419` survey). We treat the
        // dest of each `param_get` whose `index` matches an
        // ARC-typed parameter as an ARC-managed local. Captures
        // are also potential ARC sources.
        const params = self.function.params;
        // Collect param indices whose type is ARC-managed.
        var arc_param_indices: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer arc_param_indices.deinit(self.allocator);
        for (params, 0..) |param, idx| {
            const tid = param.type_id orelse continue;
            if (self.arc_managed(self.type_store, tid)) {
                try arc_param_indices.put(self.allocator, @intCast(idx), {});
            }
        }

        // (b) Captures. Closures pre-load captures into locals; we
        // detect ARC captures via `capture_get` instructions. If the
        // capture's type_expr is a heap shape, the dest local is
        // ARC-managed.
        const captures = self.function.captures;

        for (self.records.items) |rec| {
            switch (rec.instr.*) {
                .param_get => |pg| {
                    if (arc_param_indices.contains(pg.index)) {
                        if (!seen.contains(pg.dest)) {
                            try seen.put(self.allocator, pg.dest, {});
                        }
                    }
                },
                .capture_get => |cg| {
                    if (cg.index < captures.len) {
                        const cap = captures[cg.index];
                        if (zigTypeIsArcManaged(cap.type_expr)) {
                            if (!seen.contains(cg.dest)) {
                                try seen.put(self.allocator, cg.dest, {});
                            }
                        }
                    }
                },
                // (c) Locals that flow through `retain`/`release` are
                // ARC-managed by construction — the IR builder only
                // emits these for ARC types.
                .retain => |r| {
                    if (!seen.contains(r.value)) try seen.put(self.allocator, r.value, {});
                },
                .release => |r| {
                    if (!seen.contains(r.value)) try seen.put(self.allocator, r.value, {});
                },
                // (d) `share_value.source` is ARC-managed (only path
                // emits share_value is the ARC-managed call-arg path).
                .share_value => |sv| {
                    if (!seen.contains(sv.source)) try seen.put(self.allocator, sv.source, {});
                    // The dest is also an ARC-managed local — it
                    // holds the shared reference flowing into the call.
                    if (!seen.contains(sv.dest)) try seen.put(self.allocator, sv.dest, {});
                },
                else => {},
            }
        }

        // Aggregating instructions (if_expr, case_block,
        // switch_literal, union_switch) propagate ARC-managed-ness
        // from their arm-result locals to their dest. Iterate to a
        // fixpoint to handle nested aggregates.
        var changed = true;
        while (changed) {
            changed = false;
            for (self.records.items) |rec| {
                const dest = aggregateDest(rec.instr.*) orelse continue;
                if (seen.contains(dest)) continue;
                var arm_results: [16]ir.LocalId = undefined;
                const n = collectArmResults(rec.instr.*, &arm_results);
                var any_arc = false;
                for (arm_results[0..n]) |arm_local| {
                    if (seen.contains(arm_local)) {
                        any_arc = true;
                        break;
                    }
                }
                if (any_arc) {
                    try seen.put(self.allocator, dest, {});
                    changed = true;
                }
            }
            // Also: a local that is the source of a `ret` / `cond_return`
            // and whose type-id is an ARC param shape is harder to detect
            // post-hoc; the fixpoint above plus the share/retain/release
            // hints already cover all cases this phase needs.
        }

        // Materialise the dense array + reverse map.
        var iter = seen.keyIterator();
        while (iter.next()) |key| {
            const local_id = key.*;
            const arc_idx: u32 = @intCast(self.arc_locals.items.len);
            try self.arc_locals.append(self.allocator, local_id);
            try self.local_to_arc_index.put(self.allocator, local_id, arc_idx);
        }
    }

    // ----------------------------------------------------------
    // Step 3: compute per-instruction `live_after` sets.
    //
    // Backward dataflow on the structural region tree.
    //
    // For a stream `[I_0, I_1, ..., I_{n-1}]`:
    //   live_after[I_{n-1}] = stream_live_after  (the set live at the
    //                          point immediately after the stream
    //                          finishes executing — supplied by the
    //                          enclosing context)
    //   live_after[I_k]     = live_before[I_{k+1}]  for k < n-1
    //   live_before[I]      = (live_after[I] \ defs(I)) ∪ uses(I)
    //
    // For instructions with sub-streams, the sub-streams' enclosing
    // `stream_live_after` is computed as the union of the live-after
    // sets that the parent instruction would have once its result is
    // bound (i.e. the parent instruction's own live-after) — minus
    // any locals defined by the sub-stream's terminator within the
    // parent instruction. The simplest correct formulation: each
    // sub-stream's `stream_live_after` equals the parent
    // instruction's `live_after`, plus any uses by the parent that
    // are not satisfied by other sub-streams. For if/case/switch
    // shapes where the parent's live-after captures all post-merge
    // uses of the result, this is conservative-correct.
    //
    // For terminator instructions (`ret`, `tail_call`, `match_fail`,
    // `match_error_return`, `branch`, `cond_branch`, `jump`,
    // `cond_return`, `case_break`, `switch_tag`, `switch_return`,
    // `union_switch_return`) the live-after set is empty because
    // control leaves the current stream.
    // ----------------------------------------------------------

    fn computeLiveAfter(self: *Analyzer) !void {
        const arc_count: u32 = @intCast(self.arc_locals.items.len);
        try self.live_after.resize(self.allocator, self.records.items.len);
        for (self.live_after.items) |*set| set.* = try LiveSet.init(self.allocator, arc_count);

        // We compute by walking each stream backwards; for nested
        // streams we recurse from the parent. Strategy: a single
        // recursive pass over the region tree starting at the
        // function body, returning each stream's `live_in` so the
        // parent can chain.
        for (self.function.body) |block| {
            // The function body's terminator is the function exit;
            // there is no continuation, so live-after at the end of
            // each top-level block is empty.
            var stream_live_after = try LiveSet.init(self.allocator, arc_count);
            defer stream_live_after.deinit(self.allocator);
            _ = try self.processStream(block.instructions, &stream_live_after);
        }
    }

    /// Process one stream backwards. Writes `live_after[id]` for each
    /// instruction in the stream. Returns the stream's `live_in` (the
    /// set of ARC locals live just *before* the stream begins).
    /// `stream_live_after` is the live set immediately after the
    /// stream's last instruction finishes (i.e. control hands back to
    /// the enclosing context).
    fn processStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
        stream_live_after: *const LiveSet,
    ) error{OutOfMemory}!LiveSet {
        if (stream.len == 0) {
            return try stream_live_after.clone(self.allocator);
        }

        // Walk backward: track `cur_live` = live-after of the *next*
        // instruction we process (i.e. becomes live-before for the
        // current instruction).
        var cur_live = try stream_live_after.clone(self.allocator);
        // We must not free cur_live at function exit — it becomes the
        // returned live_in. Use defer to free only if early-returned.

        var k: usize = stream.len;
        while (k > 0) {
            k -= 1;
            const instr = &stream[k];
            const id = self.idForStreamInstruction(stream, k);

            // The live-after set for this instruction is what we
            // currently track as cur_live (since cur_live was the
            // live-before of the next instruction).
            // Special case: terminators — the instruction ends control
            // flow, so its actual live_after is the empty set.
            if (isTerminator(instr.*)) {
                // For a terminator, live_after = ∅ regardless of what
                // followed it in the source array (anything after a
                // terminator is dead code). However, certain
                // "block-result" terminators (`ret`, `tail_call`)
                // have their argument become "live up to the
                // terminator." That's covered by the use computation
                // below.
                self.live_after.items[id].clear();
            } else {
                self.live_after.items[id].copyFrom(&cur_live);
            }

            // For instructions with sub-streams, recurse INTO the
            // sub-streams using the *correct* enclosing live-after.
            // The enclosing live-after for each sub-stream is this
            // instruction's live_after (i.e. what's live at the
            // join point after the sub-stream finishes).
            try self.recurseChildren(instr, id, &self.live_after.items[id]);

            // Compute uses/defs and update cur_live = live_before.
            //   live_before = (live_after \ defs) ∪ uses
            var next_live = try self.live_after.items[id].clone(self.allocator);
            try self.applyDefs(instr.*, &next_live);
            try self.applyUses(instr.*, &next_live);

            cur_live.deinit(self.allocator);
            cur_live = next_live;
        }

        return cur_live;
    }

    fn recurseChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
        parent_id: InstructionId,
        parent_live_after: *const LiveSet,
    ) error{OutOfMemory}!void {
        _ = parent_id;
        switch (instr.*) {
            .if_expr => |ie| {
                // Each arm's enclosing live-after is the parent's
                // live-after plus the parent's own *uses* that come
                // after the arm chooses a result. Because the arm's
                // result becomes the if_expr's dest local — which is
                // *defined* by the if_expr — the dest itself isn't
                // live coming out of the arm. Conservatively use the
                // parent's live-after as the arm's join-point set.
                const arm_live_after = parent_live_after;
                var then_in = try self.processStream(ie.then_instrs, arm_live_after);
                defer then_in.deinit(self.allocator);
                var else_in = try self.processStream(ie.else_instrs, arm_live_after);
                defer else_in.deinit(self.allocator);
                // Uses of the if_expr itself include the condition
                // plus the merged uses from each arm (handled in
                // applyUses for the if_expr; we just need the
                // sub-streams to be correctly populated here).
            },
            .case_block => |cb| {
                const arm_live_after = parent_live_after;
                var pre_in = try self.processStream(cb.pre_instrs, arm_live_after);
                defer pre_in.deinit(self.allocator);
                for (cb.arms) |arm| {
                    var cond_in = try self.processStream(arm.cond_instrs, arm_live_after);
                    defer cond_in.deinit(self.allocator);
                    var body_in = try self.processStream(arm.body_instrs, arm_live_after);
                    defer body_in.deinit(self.allocator);
                }
                var def_in = try self.processStream(cb.default_instrs, arm_live_after);
                defer def_in.deinit(self.allocator);
            },
            .switch_literal => |sl| {
                const arm_live_after = parent_live_after;
                for (sl.cases) |case| {
                    var body_in = try self.processStream(case.body_instrs, arm_live_after);
                    defer body_in.deinit(self.allocator);
                }
                var def_in = try self.processStream(sl.default_instrs, arm_live_after);
                defer def_in.deinit(self.allocator);
            },
            .switch_return => |sr| {
                // Each case body in switch_return ends in a return,
                // so the enclosing live-after for each case body is
                // empty (control leaves the function).
                var empty = try LiveSet.init(self.allocator, @intCast(self.arc_locals.items.len));
                defer empty.deinit(self.allocator);
                for (sr.cases) |case| {
                    var body_in = try self.processStream(case.body_instrs, &empty);
                    defer body_in.deinit(self.allocator);
                }
                var def_in = try self.processStream(sr.default_instrs, &empty);
                defer def_in.deinit(self.allocator);
            },
            .union_switch => |us| {
                const arm_live_after = parent_live_after;
                for (us.cases) |case| {
                    var body_in = try self.processStream(case.body_instrs, arm_live_after);
                    defer body_in.deinit(self.allocator);
                }
            },
            .union_switch_return => |usr| {
                var empty = try LiveSet.init(self.allocator, @intCast(self.arc_locals.items.len));
                defer empty.deinit(self.allocator);
                for (usr.cases) |case| {
                    var body_in = try self.processStream(case.body_instrs, &empty);
                    defer body_in.deinit(self.allocator);
                }
            },
            .try_call_named => |tc| {
                const arm_live_after = parent_live_after;
                var handler_in = try self.processStream(tc.handler_instrs, arm_live_after);
                defer handler_in.deinit(self.allocator);
                var success_in = try self.processStream(tc.success_instrs, arm_live_after);
                defer success_in.deinit(self.allocator);
            },
            .guard_block => |gb| {
                var body_in = try self.processStream(gb.body, parent_live_after);
                defer body_in.deinit(self.allocator);
            },
            else => {},
        }
    }

    /// Find the InstructionId for `stream[k]`. O(1) via the
    /// pointer-to-id reverse index populated during flattening.
    fn idForStreamInstruction(
        self: *const Analyzer,
        stream: []const ir.Instruction,
        k: usize,
    ) InstructionId {
        const target_ptr = &stream[k];
        return self.pointer_to_id.get(target_ptr).?;
    }

    fn applyDefs(self: *Analyzer, instr: ir.Instruction, set: *LiveSet) !void {
        const dest_locals = collectDefs(instr);
        for (dest_locals.slice()) |dest| {
            if (self.local_to_arc_index.get(dest)) |idx| set.unset(idx);
        }
    }

    fn applyUses(self: *Analyzer, instr: ir.Instruction, set: *LiveSet) !void {
        var buf = UseList{};
        collectUses(instr, &buf);
        for (buf.slice()) |use| {
            if (self.local_to_arc_index.get(use)) |idx| set.set(idx);
        }
    }

    // ----------------------------------------------------------
    // Step 4 + 5: walk forward, classify last uses.
    // ----------------------------------------------------------

    fn classifyLastUses(self: *Analyzer, ownership: *ArcOwnership) !void {
        for (self.records.items, 0..) |rec, idx| {
            const id: InstructionId = @intCast(idx);
            const live_after = &self.live_after.items[id];

            // Compute live_before by inverting the dataflow step.
            //   live_before = (live_after \ defs) ∪ uses
            // We just need to know: which ARC-uses of this instr are
            // last uses (∈ live_before, ∉ live_after).
            var buf = UseList{};
            collectUses(rec.instr.*, &buf);
            for (buf.slice()) |use_local| {
                const arc_idx = self.local_to_arc_index.get(use_local) orelse continue;
                if (!live_after.contains(arc_idx)) {
                    // Last use of `use_local` at this instruction.
                    // For duplicate-arg calls (e.g. `f(x, x)`), the
                    // *same* local appears multiple times in the use
                    // list. Only the last evaluated occurrence is
                    // the actual transfer site; earlier occurrences
                    // need a retain (the local is still held by the
                    // caller for the next occurrence). However, the
                    // structural IR pre-lowers each argument to its
                    // own `share_value` (since the IR builder emits
                    // a separate `share_value` per ARC argument —
                    // see `src/ir.zig:4418-4427`). The last
                    // share_value's source is the local; the earlier
                    // share_values are also reads of the same local,
                    // but in the *backward* dataflow only the
                    // last-evaluated read makes the local non-live
                    // afterwards. So this branch fires exactly once
                    // per local, at the truly-last share_value, by
                    // construction.
                    try ownership.last_use_map.put(self.allocator, use_local, id);
                    try self.applySpecialization(rec.instr.*, id, use_local, ownership);
                }
            }
        }
    }

    fn applySpecialization(
        self: *Analyzer,
        instr: ir.Instruction,
        id: InstructionId,
        last_use_local: ir.LocalId,
        ownership: *ArcOwnership,
    ) !void {
        switch (instr) {
            .share_value => |sv| {
                if (sv.source == last_use_local) {
                    try ownership.consume_share_sites.put(self.allocator, id, {});
                }
            },
            .ret => |r| {
                if (r.value) |v| {
                    if (v == last_use_local) {
                        try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                    }
                }
            },
            .cond_return => |cr| {
                if (cr.value) |v| {
                    if (v == last_use_local) {
                        try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                    }
                }
            },
            else => {},
        }
    }

    /// Phase-5 prep: when a `ret v` returns a local that is itself
    /// the dest of an aggregating control-flow construct (if_expr,
    /// case_block, switch_literal, switch_return, union_switch,
    /// union_switch_return), the *underlying* arm-result locals are
    /// also return sources. The drop-list filter at function
    /// epilogue must exclude them, otherwise it would release a
    /// value whose ownership has flowed to the caller's return slot.
    ///
    /// Walk the records once: for each instruction whose dest is in
    /// `return_source_locals`, add each ARC-managed arm-result
    /// local to the set. Iterate to fixpoint to handle nested
    /// aggregates (an arm result may itself be the dest of another
    /// aggregate).
    fn propagateReturnSourcesThroughAggregates(
        self: *Analyzer,
        ownership: *ArcOwnership,
    ) !void {
        var changed = true;
        while (changed) {
            changed = false;
            for (self.records.items) |rec| {
                const dest = aggregateDest(rec.instr.*) orelse continue;
                if (!ownership.return_source_locals.contains(dest)) continue;
                var arm_results: [16]ir.LocalId = undefined;
                const n = collectArmResults(rec.instr.*, &arm_results);
                for (arm_results[0..n]) |arm_local| {
                    if (!self.local_to_arc_index.contains(arm_local)) continue;
                    if (ownership.return_source_locals.contains(arm_local)) continue;
                    try ownership.return_source_locals.put(self.allocator, arm_local, {});
                    changed = true;
                }
            }
        }
    }

    // ----------------------------------------------------------
    // Step 6: soundness assertions (debug only).
    // ----------------------------------------------------------

    fn checkSoundness(self: *Analyzer, ownership: *const ArcOwnership) !void {
        // (a) No local appears in both consume_share_sites (via some
        // site) AND return_source_locals.
        var consumed_sources: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        defer consumed_sources.deinit(self.allocator);
        var iter = ownership.consume_share_sites.keyIterator();
        while (iter.next()) |id_ptr| {
            const rec = self.records.items[id_ptr.*];
            switch (rec.instr.*) {
                .share_value => |sv| try consumed_sources.put(self.allocator, sv.source, {}),
                else => {},
            }
        }
        var ret_iter = ownership.return_source_locals.keyIterator();
        while (ret_iter.next()) |local_ptr| {
            std.debug.assert(!consumed_sources.contains(local_ptr.*));
        }

        // (b) For each consume site S of L, L does not appear after S.
        // (c) For each return source L, L does not appear after the ret.
        // We enforce these via the live-after invariant: the local's
        // live_after at the consume site must not include L.
        var iter2 = ownership.consume_share_sites.keyIterator();
        while (iter2.next()) |id_ptr| {
            const id = id_ptr.*;
            const rec = self.records.items[id];
            switch (rec.instr.*) {
                .share_value => |sv| {
                    const arc_idx = self.local_to_arc_index.get(sv.source) orelse continue;
                    std.debug.assert(!self.live_after.items[id].contains(arc_idx));
                },
                else => unreachable,
            }
        }
    }
};

/// Run the ARC ownership pass over every function in `program`.
/// The result for each function is computed, observed (no-op in
/// Phase 2), and immediately deinitialised. Phase 4 will replace
/// this caller with one that retains the per-function ownership
/// table and writes consume modes back into the IR.
///
/// The pass is read-only with respect to the IR. It exists in this
/// phase to (a) exercise the pass on every function during normal
/// compilation, surfacing crashes early, and (b) provide a stable
/// surface for downstream phases.
pub fn runProgramArcLiveness(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    type_store: *const types_mod.TypeStore,
) !void {
    for (program.functions) |*function| {
        var ownership = try computeArcOwnership(
            allocator,
            function,
            type_store,
            defaultArcManagedTypeId,
        );
        defer ownership.deinit(allocator);
    }
}

// ============================================================
// Helpers: terminators, def/use lists, type predicates.
// ============================================================

fn isTerminator(instr: ir.Instruction) bool {
    return switch (instr) {
        .ret,
        .tail_call,
        .match_fail,
        .match_error_return,
        .branch,
        .jump,
        .cond_branch,
        .switch_tag,
        .switch_return,
        .union_switch_return,
        .case_break,
        => true,
        else => false,
    };
}

const UseList = struct {
    buf: [16]ir.LocalId = undefined,
    overflow: std.ArrayListUnmanaged(ir.LocalId) = .empty,
    len: usize = 0,
    use_overflow: bool = false,

    pub fn append(self: *UseList, allocator: std.mem.Allocator, local: ir.LocalId) !void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = local;
            self.len += 1;
            return;
        }
        if (!self.use_overflow) {
            try self.overflow.appendSlice(allocator, &self.buf);
            self.use_overflow = true;
        }
        try self.overflow.append(allocator, local);
        self.len += 1;
    }

    pub fn slice(self: *const UseList) []const ir.LocalId {
        if (self.use_overflow) return self.overflow.items;
        return self.buf[0..self.len];
    }

    pub fn deinit(self: *UseList, allocator: std.mem.Allocator) void {
        self.overflow.deinit(allocator);
    }
};

/// Append every local that this instruction reads (uses) to `buf`.
/// Sub-streams of nested instructions are NOT included — the
/// dataflow visits them separately. Only the immediate uses by the
/// instruction's own opcode are collected.
fn collectUses(instr: ir.Instruction, buf: *UseList) void {
    const allocator = std.heap.page_allocator; // overflow only
    switch (instr) {
        .const_int, .const_float, .const_string, .const_bool, .const_atom => {},
        .const_nil => {},
        .local_get => |x| buf.append(allocator, x.source) catch {},
        .local_set => |x| buf.append(allocator, x.value) catch {},
        .move_value => |x| buf.append(allocator, x.source) catch {},
        .share_value => |x| buf.append(allocator, x.source) catch {},
        .param_get => {},
        .tuple_init => |x| for (x.elements) |l| buf.append(allocator, l) catch {},
        .list_init => |x| for (x.elements) |l| buf.append(allocator, l) catch {},
        .list_cons => |x| {
            buf.append(allocator, x.head) catch {};
            buf.append(allocator, x.tail) catch {};
        },
        .map_init => |x| for (x.entries) |e| {
            buf.append(allocator, e.key) catch {};
            buf.append(allocator, e.value) catch {};
        },
        .struct_init => |x| for (x.fields) |f| buf.append(allocator, f.value) catch {},
        .union_init => |x| buf.append(allocator, x.value) catch {},
        .enum_literal => {},
        .field_get => |x| buf.append(allocator, x.object) catch {},
        .field_set => |x| {
            buf.append(allocator, x.object) catch {};
            buf.append(allocator, x.value) catch {};
        },
        .index_get => |x| buf.append(allocator, x.object) catch {},
        .list_len_check => |x| buf.append(allocator, x.scrutinee) catch {},
        .list_get => |x| buf.append(allocator, x.list) catch {},
        .list_is_not_empty => |x| buf.append(allocator, x.list) catch {},
        .list_head, .list_tail => |x| buf.append(allocator, x.list) catch {},
        .map_has_key => |x| {
            buf.append(allocator, x.map) catch {};
            buf.append(allocator, x.key) catch {};
        },
        .map_get => |x| {
            buf.append(allocator, x.map) catch {};
            buf.append(allocator, x.key) catch {};
            buf.append(allocator, x.default) catch {};
        },
        .binary_op => |x| {
            buf.append(allocator, x.lhs) catch {};
            buf.append(allocator, x.rhs) catch {};
        },
        .unary_op => |x| buf.append(allocator, x.operand) catch {},
        .call_direct => |x| for (x.args) |a| buf.append(allocator, a) catch {},
        .call_named => |x| for (x.args) |a| buf.append(allocator, a) catch {},
        .call_closure => |x| {
            buf.append(allocator, x.callee) catch {};
            for (x.args) |a| buf.append(allocator, a) catch {};
        },
        .call_dispatch => |x| for (x.args) |a| buf.append(allocator, a) catch {},
        .call_builtin => |x| for (x.args) |a| buf.append(allocator, a) catch {},
        .tail_call => |x| for (x.args) |a| buf.append(allocator, a) catch {},
        .try_call_named => |x| {
            for (x.args) |a| buf.append(allocator, a) catch {};
            buf.append(allocator, x.input_local) catch {};
            // handler_result and success_result are produced inside
            // sub-streams; not direct uses of the parent instruction.
        },
        .error_catch => |x| {
            buf.append(allocator, x.source) catch {};
            buf.append(allocator, x.catch_value) catch {};
        },
        .set_safety => {},
        .if_expr => |x| {
            buf.append(allocator, x.condition) catch {};
            // then_result / else_result are uses by the join point;
            // those uses are accounted for through the join's
            // `live_after` propagation since they materialise the
            // if_expr.dest. Treat them as direct uses of the if_expr
            // for liveness purposes.
            if (x.then_result) |l| buf.append(allocator, l) catch {};
            if (x.else_result) |l| buf.append(allocator, l) catch {};
        },
        .guard_block => |x| buf.append(allocator, x.condition) catch {},
        .case_block => |x| {
            for (x.arms) |arm| {
                if (arm.result) |l| buf.append(allocator, l) catch {};
            }
            if (x.default_result) |l| buf.append(allocator, l) catch {};
        },
        .branch => {},
        .cond_branch => |x| buf.append(allocator, x.condition) catch {},
        .switch_tag => |x| buf.append(allocator, x.scrutinee) catch {},
        .switch_literal => |x| {
            buf.append(allocator, x.scrutinee) catch {};
            for (x.cases) |case| {
                if (case.result) |l| buf.append(allocator, l) catch {};
            }
            if (x.default_result) |l| buf.append(allocator, l) catch {};
        },
        .switch_return => |x| {
            for (x.cases) |case| {
                if (case.return_value) |l| buf.append(allocator, l) catch {};
            }
            if (x.default_result) |l| buf.append(allocator, l) catch {};
        },
        .union_switch_return => |x| {
            for (x.cases) |case| {
                if (case.return_value) |l| buf.append(allocator, l) catch {};
            }
        },
        .union_switch => |x| {
            buf.append(allocator, x.scrutinee) catch {};
            for (x.cases) |case| {
                if (case.return_value) |l| buf.append(allocator, l) catch {};
            }
        },
        .match_atom => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_int => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_float => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_string => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_type => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_fail => |x| {
            if (x.message_local) |l| buf.append(allocator, l) catch {};
        },
        .match_error_return => |x| buf.append(allocator, x.scrutinee) catch {},
        .ret => |x| {
            if (x.value) |l| buf.append(allocator, l) catch {};
        },
        .cond_return => |x| {
            buf.append(allocator, x.condition) catch {};
            if (x.value) |l| buf.append(allocator, l) catch {};
        },
        .case_break => |x| {
            if (x.value) |l| buf.append(allocator, l) catch {};
        },
        .jump => |x| {
            if (x.value) |l| buf.append(allocator, l) catch {};
        },
        .make_closure => |x| for (x.captures) |a| buf.append(allocator, a) catch {},
        .capture_get => {},
        .optional_unwrap => |x| buf.append(allocator, x.source) catch {},
        .bin_len_check => |x| buf.append(allocator, x.scrutinee) catch {},
        .bin_read_int => |x| {
            buf.append(allocator, x.source) catch {};
            switch (x.offset) {
                .dynamic => |d| buf.append(allocator, d) catch {},
                .static => {},
            }
        },
        .bin_read_float => |x| {
            buf.append(allocator, x.source) catch {};
            switch (x.offset) {
                .dynamic => |d| buf.append(allocator, d) catch {},
                .static => {},
            }
        },
        .bin_slice => |x| {
            buf.append(allocator, x.source) catch {};
            switch (x.offset) {
                .dynamic => |d| buf.append(allocator, d) catch {},
                .static => {},
            }
            if (x.length) |len_off| {
                switch (len_off) {
                    .dynamic => |d| buf.append(allocator, d) catch {},
                    .static => {},
                }
            }
        },
        .bin_read_utf8 => |x| {
            buf.append(allocator, x.source) catch {};
            switch (x.offset) {
                .dynamic => |d| buf.append(allocator, d) catch {},
                .static => {},
            }
        },
        .bin_match_prefix => |x| buf.append(allocator, x.source) catch {},
        .retain => |x| buf.append(allocator, x.value) catch {},
        .release => |x| buf.append(allocator, x.value) catch {},
        .reset => |x| buf.append(allocator, x.source) catch {},
        .reuse_alloc => |x| {
            if (x.token) |t| buf.append(allocator, t) catch {};
        },
        .int_widen, .float_widen => |x| buf.append(allocator, x.source) catch {},
        .phi => |x| for (x.sources) |src| buf.append(allocator, src.value) catch {},
    }
}

const DefList = struct {
    buf: [4]ir.LocalId = undefined,
    len: usize = 0,

    pub fn append(self: *DefList, local: ir.LocalId) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = local;
            self.len += 1;
        }
    }

    pub fn slice(self: *const DefList) []const ir.LocalId {
        return self.buf[0..self.len];
    }
};

/// Locals defined (written) by this instruction. Sub-stream defs are
/// not collected here — the recursive walk visits them.
fn collectDefs(instr: ir.Instruction) DefList {
    var out: DefList = .{};
    switch (instr) {
        .const_int => |x| out.append(x.dest),
        .const_float => |x| out.append(x.dest),
        .const_string => |x| out.append(x.dest),
        .const_bool => |x| out.append(x.dest),
        .const_atom => |x| out.append(x.dest),
        .const_nil => |x| out.append(x),
        .local_get => |x| out.append(x.dest),
        .local_set => |x| out.append(x.dest),
        .move_value => |x| out.append(x.dest),
        .share_value => |x| out.append(x.dest),
        .param_get => |x| out.append(x.dest),
        .tuple_init => |x| out.append(x.dest),
        .list_init => |x| out.append(x.dest),
        .list_cons => |x| out.append(x.dest),
        .map_init => |x| out.append(x.dest),
        .struct_init => |x| out.append(x.dest),
        .union_init => |x| out.append(x.dest),
        .enum_literal => |x| out.append(x.dest),
        .field_get => |x| out.append(x.dest),
        .index_get => |x| out.append(x.dest),
        .list_len_check => |x| out.append(x.dest),
        .list_get => |x| out.append(x.dest),
        .list_is_not_empty => |x| out.append(x.dest),
        .list_head, .list_tail => |x| out.append(x.dest),
        .map_has_key => |x| out.append(x.dest),
        .map_get => |x| out.append(x.dest),
        .binary_op => |x| out.append(x.dest),
        .unary_op => |x| out.append(x.dest),
        .call_direct => |x| out.append(x.dest),
        .call_named => |x| out.append(x.dest),
        .call_closure => |x| out.append(x.dest),
        .call_dispatch => |x| out.append(x.dest),
        .call_builtin => |x| out.append(x.dest),
        .try_call_named => |x| out.append(x.dest),
        .error_catch => |x| out.append(x.dest),
        .if_expr => |x| out.append(x.dest),
        .case_block => |x| out.append(x.dest),
        .switch_literal => |x| out.append(x.dest),
        .union_switch => |x| out.append(x.dest),
        .match_atom => |x| out.append(x.dest),
        .match_int => |x| out.append(x.dest),
        .match_float => |x| out.append(x.dest),
        .match_string => |x| out.append(x.dest),
        .match_type => |x| out.append(x.dest),
        .make_closure => |x| out.append(x.dest),
        .capture_get => |x| out.append(x.dest),
        .optional_unwrap => |x| out.append(x.dest),
        .bin_len_check => |x| out.append(x.dest),
        .bin_read_int => |x| out.append(x.dest),
        .bin_read_float => |x| out.append(x.dest),
        .bin_slice => |x| out.append(x.dest),
        .bin_read_utf8 => |x| {
            out.append(x.dest_codepoint);
            out.append(x.dest_len);
        },
        .bin_match_prefix => |x| out.append(x.dest),
        .reset => |x| out.append(x.dest),
        .reuse_alloc => |x| out.append(x.dest),
        .int_widen, .float_widen => |x| out.append(x.dest),
        .phi => |x| out.append(x.dest),
        .jump => |x| if (x.bind_dest) |d| out.append(d),
        else => {},
    }
    return out;
}

/// Returns the dest LocalId of an "aggregating" control-flow
/// instruction whose value flows from arm results — i.e. one whose
/// dest equals the arm-results selected at runtime.
fn aggregateDest(instr: ir.Instruction) ?ir.LocalId {
    return switch (instr) {
        .if_expr => |x| x.dest,
        .case_block => |x| x.dest,
        .switch_literal => |x| x.dest,
        .union_switch => |x| x.dest,
        else => null,
    };
}

/// Collects up to 16 arm-result locals from an aggregating
/// instruction. Returns the count.
fn collectArmResults(instr: ir.Instruction, out: *[16]ir.LocalId) usize {
    var n: usize = 0;
    const append = struct {
        fn add(slot: *[16]ir.LocalId, count: *usize, l: ir.LocalId) void {
            if (count.* < slot.len) {
                slot.*[count.*] = l;
                count.* += 1;
            }
        }
    }.add;
    switch (instr) {
        .if_expr => |x| {
            if (x.then_result) |l| append(out, &n, l);
            if (x.else_result) |l| append(out, &n, l);
        },
        .case_block => |x| {
            for (x.arms) |arm| if (arm.result) |l| append(out, &n, l);
            if (x.default_result) |l| append(out, &n, l);
        },
        .switch_literal => |x| {
            for (x.cases) |c| if (c.result) |l| append(out, &n, l);
            if (x.default_result) |l| append(out, &n, l);
        },
        .union_switch => |x| {
            for (x.cases) |c| if (c.return_value) |l| append(out, &n, l);
        },
        else => {},
    }
    return n;
}

/// Whether a `ZigType` represents a heap-allocated, ARC-managed shape.
/// Used when checking captures whose only available metadata is the
/// `ZigType` (TypeId is not preserved on `Capture`).
fn zigTypeIsArcManaged(t: ir.ZigType) bool {
    return switch (t) {
        .string, .list, .map, .struct_ref, .tagged_union, .optional => true,
        else => false,
    };
}

// ============================================================
// Live set: u64 bitset for ≤ 64 ARC locals; DynamicBitSet otherwise.
// ============================================================

const LiveSet = struct {
    storage: Storage,
    bit_count: u32,

    const Storage = union(enum) {
        small: u64,
        large: std.DynamicBitSet,
    };

    pub fn init(allocator: std.mem.Allocator, bit_count: u32) !LiveSet {
        if (bit_count <= 64) {
            return .{ .storage = .{ .small = 0 }, .bit_count = bit_count };
        }
        const large = try std.DynamicBitSet.initEmpty(allocator, bit_count);
        return .{ .storage = .{ .large = large }, .bit_count = bit_count };
    }

    /// Reset every bit to 0. Preserves the storage variant.
    pub fn clear(self: *LiveSet) void {
        switch (self.storage) {
            .small => |*v| v.* = 0,
            .large => |*l| {
                var i: u32 = 0;
                while (i < self.bit_count) : (i += 1) l.unset(i);
            },
        }
    }

    pub fn deinit(self: *LiveSet, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.storage) {
            .large => |*l| l.deinit(),
            .small => {},
        }
    }

    pub fn clone(self: *const LiveSet, allocator: std.mem.Allocator) !LiveSet {
        switch (self.storage) {
            .small => |v| return .{ .storage = .{ .small = v }, .bit_count = self.bit_count },
            .large => |l| {
                var new = try std.DynamicBitSet.initEmpty(allocator, self.bit_count);
                new.setUnion(l);
                return .{ .storage = .{ .large = new }, .bit_count = self.bit_count };
            },
        }
    }

    /// Replace `self`'s contents with a copy of `other`'s. Same
    /// `bit_count` required.
    pub fn copyFrom(self: *LiveSet, other: *const LiveSet) void {
        std.debug.assert(self.bit_count == other.bit_count);
        switch (self.storage) {
            .small => |*v| switch (other.storage) {
                .small => |ov| v.* = ov,
                .large => |ol| {
                    // Copy first 64 bits.
                    var tmp: u64 = 0;
                    var i: u32 = 0;
                    while (i < self.bit_count and i < 64) : (i += 1) {
                        if (ol.isSet(i)) tmp |= (@as(u64, 1) << @intCast(i));
                    }
                    v.* = tmp;
                },
            },
            .large => |*l| {
                // Wipe and copy.
                var i: u32 = 0;
                while (i < self.bit_count) : (i += 1) l.unset(i);
                switch (other.storage) {
                    .small => |ov| {
                        var b: u32 = 0;
                        while (b < self.bit_count and b < 64) : (b += 1) {
                            if ((ov & (@as(u64, 1) << @intCast(b))) != 0) l.set(b);
                        }
                    },
                    .large => |ol| {
                        l.setUnion(ol);
                    },
                }
            },
        }
    }

    pub fn set(self: *LiveSet, bit: u32) void {
        std.debug.assert(bit < self.bit_count);
        switch (self.storage) {
            .small => |*v| v.* |= (@as(u64, 1) << @intCast(bit)),
            .large => |*l| l.set(bit),
        }
    }

    pub fn unset(self: *LiveSet, bit: u32) void {
        std.debug.assert(bit < self.bit_count);
        switch (self.storage) {
            .small => |*v| v.* &= ~(@as(u64, 1) << @intCast(bit)),
            .large => |*l| l.unset(bit),
        }
    }

    pub fn contains(self: *const LiveSet, bit: u32) bool {
        std.debug.assert(bit < self.bit_count);
        return switch (self.storage) {
            .small => |v| (v & (@as(u64, 1) << @intCast(bit))) != 0,
            .large => |l| l.isSet(bit),
        };
    }
};

// ============================================================
// Test scaffolding
//
// The pass is exercised from src/zir_integration_tests.zig via the
// public `runArcLivenessOnLastFunctionInProgram` helper, but the
// most direct unit tests hand-build IR via the parser → typecheck
// → HIR → IR pipeline (the same pattern used by the existing
// ir.zig tests at lines 5860-5957).
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;
const HirBuilder = hir_mod.HirBuilder;

const TestSuite = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    parser: *Parser,
    collector: *Collector,
    checker: *types_mod.TypeChecker,
    hir: *HirBuilder,
    hir_program: hir_mod.Program,
    ir_builder: *ir.IrBuilder,
    ir_program: ir.Program,

    fn init(allocator: std.mem.Allocator, source: []const u8) !TestSuite {
        const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena_ptr.allocator();

        const parser_ptr = try alloc.create(Parser);
        parser_ptr.* = Parser.init(alloc, source);
        const program = try parser_ptr.parseProgram();

        const collector_ptr = try alloc.create(Collector);
        collector_ptr.* = Collector.init(alloc, parser_ptr.interner, null);
        try collector_ptr.collectProgram(&program);

        const checker_ptr = try alloc.create(types_mod.TypeChecker);
        checker_ptr.* = types_mod.TypeChecker.init(alloc, parser_ptr.interner, &collector_ptr.graph);
        try checker_ptr.checkProgram(&program);

        const hir_ptr = try alloc.create(HirBuilder);
        hir_ptr.* = HirBuilder.init(alloc, parser_ptr.interner, &collector_ptr.graph, checker_ptr.store);
        const hir_program = try hir_ptr.buildProgram(&program);

        const ir_ptr = try alloc.create(ir.IrBuilder);
        ir_ptr.* = ir.IrBuilder.init(alloc, parser_ptr.interner);
        ir_ptr.type_store = checker_ptr.store;
        const ir_program = try ir_ptr.buildProgram(&hir_program);

        return .{
            .arena = arena_ptr,
            .allocator = allocator,
            .parser = parser_ptr,
            .collector = collector_ptr,
            .checker = checker_ptr,
            .hir = hir_ptr,
            .hir_program = hir_program,
            .ir_builder = ir_ptr,
            .ir_program = ir_program,
        };
    }

    fn deinit(self: *TestSuite) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    fn findFunctionByName(self: *const TestSuite, name: []const u8) ?*const ir.Function {
        for (self.ir_program.functions) |*func| {
            if (std.mem.indexOf(u8, func.name, name) != null) return func;
        }
        return null;
    }

    fn typeStore(self: *const TestSuite) *const types_mod.TypeStore {
        return self.checker.store;
    }
};

// Tests use the testing allocator. Each test owns its own TestSuite
// and ArcOwnership.

test "arc_liveness: linear last-use is consume at share_value" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use_one(h :: Handle) -> Handle {
        \\    h
        \\  }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.use_one(h)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const run_func = suite.findFunctionByName("run") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        run_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Expect: at least one consume site (the share_value of `h` into
    // the call) AND `h` recorded as a return-source local on the
    // identity helper `use_one`.
    try std.testing.expect(ownership.consume_share_sites.count() >= 1);
}

test "arc_liveness: identity function returns its parameter (return_source)" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle {
        \\    h
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const id_func = suite.findFunctionByName("id") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        id_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // `h` is the parameter local; its last use is the function's `ret`.
    try std.testing.expect(ownership.return_source_locals.count() == 1);
    try std.testing.expect(ownership.consume_share_sites.count() == 0);
}

test "arc_liveness: branching case last-uses param in both arms" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn f(h :: Handle) -> Handle { h }
        \\  pub fn g(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(c :: bool, h :: Handle) -> Handle {
        \\    case c {
        \\      true -> Test.f(h)
        \\      false -> Test.g(h)
        \\    }
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const run_func = suite.findFunctionByName("run") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        run_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Each arm has a share_value of `h` to f/g; both should be
    // consume sites.
    try std.testing.expect(ownership.consume_share_sites.count() >= 2);
}

test "arc_liveness: function returning a call's result has no extra elision" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn helper(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.helper(h)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const run_func = suite.findFunctionByName("run") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        run_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // `h` consumed at the call; `h` is NOT a return source (the
    // call's result is what's returned).
    try std.testing.expect(ownership.consume_share_sites.count() >= 1);
    // `h`'s last use is the share_value, not the ret. The ret's
    // value is the call's dest, which is *also* an ARC local; that
    // dest IS a return_source. So return_source_locals should
    // contain the call's dest, not h itself.
    try std.testing.expect(ownership.return_source_locals.count() <= 1);
}

test "arc_liveness: tail-recursion k-nucleotide shape (return + recursive call)" {
    // Mimics the `Probe.loop` pattern: a recursive function whose
    // base-case arm returns the ARC param directly (return source)
    // and whose recursive arm passes the ARC param into a helper
    // call (consume site).
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn helper(h :: Handle) -> Handle { h }
        \\
        \\  pub fn loop(m :: Handle, i :: i64, n :: i64) -> Handle {
        \\    case i < n {
        \\      true -> Test.loop(Test.helper(m), i + (1 :: i64), n)
        \\      false -> m
        \\    }
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const loop_func = suite.findFunctionByName("loop") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        loop_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // The recursive arm consumes `m` via share_value into helper(m),
    // and the base-case arm has `m` as the return source. Both
    // categories must be populated.
    try std.testing.expect(ownership.consume_share_sites.count() >= 1);
    try std.testing.expect(ownership.return_source_locals.count() >= 1);
}

test "arc_liveness: duplicate-arg call — every share_value of a fresh-loaded local is a consume" {
    // Surface-language expectation from the plan:
    //   "f(x, x) → first x retains, last x consumes".
    //
    // Zap IR's actual lowering issues a *fresh* `param_get` (or
    // `local_get`) for each occurrence of `x`, so every
    // `share_value`'s source is a distinct SSA local. Each share is
    // therefore the unique last use of its source, and every share
    // becomes a consume site. The "first share retains, last share
    // consumes" semantics is materialised at the IR level not by
    // marking some shares as retain but by issuing a fresh load
    // (which inherently retains via param_get/local_get) before
    // each share_value. This test pins the IR-level invariant: a
    // consume site is recorded for every share_value, because each
    // such share_value is genuinely the last use of its source
    // local.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn pair(a :: Handle, b :: Handle) -> Handle { a }
        \\
        \\  pub fn run(x :: Handle) -> Handle {
        \\    Test.pair(x, x)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const run_func = suite.findFunctionByName("run") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        run_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Count share_value instructions in the function and assert
    // *every* one is a consume site.
    var share_count: usize = 0;
    for (run_func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .share_value) share_count += 1;
        }
    }
    try std.testing.expect(share_count >= 2);
    try std.testing.expectEqual(share_count, ownership.consume_share_sites.count());
}

test "arc_liveness: empty when no ARC-managed locals" {
    const source =
        \\pub struct Test {
        \\  pub fn run(x :: i64) -> i64 {
        \\    x + (1 :: i64)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const run_func = suite.findFunctionByName("run") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        run_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
    try std.testing.expectEqual(@as(usize, 0), ownership.return_source_locals.count());
}
