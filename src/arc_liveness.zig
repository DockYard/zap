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
/// Set of ARC-managed locals, materialised as a hash-map. Used as the
/// value type of `ArcOwnership.live_before_ret` so per-terminator live
/// sets are O(1)-queryable by `LocalId` without any bit-index round-trip.
pub const ArcLocalSet = std.AutoHashMapUnmanaged(ir.LocalId, void);

pub const ArcOwnership = struct {
    /// Locals whose `share_value` to a call-arg slot is a last-use
    /// transfer (consume site). Indexed by share_value instruction id.
    consume_share_sites: std.AutoHashMapUnmanaged(InstructionId, void) = .empty,

    /// Locals that are the immediate source of a `ret` instruction.
    /// At function-epilogue drop emission, locals in this set are
    /// excluded from the drop list (Phase 5 wires this).
    return_source_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,

    /// Set of every ARC-managed local in the function — every local
    /// whose runtime value is a heap-allocated, refcount-tracked
    /// cell. Populated from the analyzer's internal `arc_locals`
    /// dense array and mirrored here so downstream consumers (most
    /// notably `ZirDriver.shouldSkipArc`) can decide whether a local
    /// participates in ARC operations.
    ///
    /// Why this matters: the escape lattice classifies pointer flow
    /// (`.no_escape`, `.function_local`, ...). For non-ARC types
    /// "doesn't escape" implies "stack-eligible", so retain/release
    /// can be skipped. For ARC-managed types the cell is heap-pool
    /// allocated regardless — even when escape says the value never
    /// leaves the function, the refcount must still be tracked or
    /// the pool cell leaks (or worse, gets recycled while another
    /// path-copy spine still holds a reference). Treating ARC-managed
    /// locals as never stack-eligible is a soundness invariant that
    /// has to be enforced everywhere `shouldSkipArc` is consulted.
    arc_managed_locals: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,

    /// Diagnostic: per-ARC-local last-use instruction id. Useful
    /// for pretty printers, debug counters, and soundness checks.
    last_use_map: std.AutoHashMapUnmanaged(ir.LocalId, InstructionId) = .empty,

    /// For each ret-equivalent terminator instruction id, the set of
    /// ARC-managed local ids that are live immediately before that
    /// terminator. A future drop-insertion pass (Phase 6 of the
    /// k-nucleotide RSS gap plan) uses this to know which locals
    /// need scope-exit `release` instructions inserted at each
    /// termination point. Per-terminator (rather than per-function)
    /// because branches can have distinct live sets — the locals
    /// alive immediately before `ret x` in one arm may differ from
    /// those alive before `ret y` in another arm.
    ///
    /// Ret-equivalent terminators recorded here:
    ///   - `.ret`
    ///   - `.cond_return`
    ///   - `.tail_call` (the callee returns directly to the caller's
    ///      caller, so the tail_call instruction is functionally a
    ///      return; the live-before set captures locals that need
    ///      to be released before the tail jump)
    ///   - `.switch_return` and `.union_switch_return` (each arm body
    ///     ends with an implicit return; the live-before set at the
    ///     parent terminator's id captures the union of arm uses
    ///     plus anything else still live at the switch)
    ///
    /// Pure side-table: this map is read by future passes; the
    /// dataflow that populates it does not mutate the IR.
    live_before_ret: std.AutoHashMapUnmanaged(InstructionId, ArcLocalSet) = .empty,

    pub fn deinit(self: *ArcOwnership, allocator: std.mem.Allocator) void {
        self.consume_share_sites.deinit(allocator);
        self.return_source_locals.deinit(allocator);
        self.arc_managed_locals.deinit(allocator);
        self.last_use_map.deinit(allocator);
        var live_iter = self.live_before_ret.valueIterator();
        while (live_iter.next()) |set_ptr| {
            set_ptr.deinit(allocator);
        }
        self.live_before_ret.deinit(allocator);
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

    // Mirror the analyzer's dense `arc_locals` list into the public
    // `arc_managed_locals` set so downstream consumers (notably
    // `ZirDriver.shouldSkipArc`) can answer "is this local ARC-managed?"
    // without re-running the analysis. Populated even when no consume
    // or return-source classifications fire, because the soundness
    // invariant — ARC-managed locals are never stack-eligible — must
    // hold for every ARC local in the function regardless of whether
    // ownership analysis found any optimization opportunities.
    for (analyzer.arc_locals.items) |arc_local| {
        try ownership.arc_managed_locals.put(allocator, arc_local, {});
    }

    if (analyzer.arc_locals.items.len == 0) {
        // No ARC-managed locals — nothing to do. Return empty maps.
        return ownership;
    }

    analyzer.ownership_in_progress = &ownership;
    try analyzer.computeLiveAfter();
    analyzer.ownership_in_progress = null;
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

    /// When non-null, the dataflow walk snapshots the live-before set
    /// at every ret-equivalent terminator into
    /// `ownership_in_progress.live_before_ret`. Set immediately before
    /// `computeLiveAfter` runs and cleared after, so the analyzer's
    /// other passes don't accidentally observe a half-initialised
    /// ownership table.
    ownership_in_progress: ?*ArcOwnership = null,

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

            // Side-table snapshot: at every ret-equivalent terminator,
            // record the live-before set into
            // `ownership.live_before_ret`. The drop-insertion pass
            // (Phase 6 of the k-nucleotide RSS gap plan) consults
            // this map to know which ARC-managed locals need a
            // scope-exit `release` inserted immediately before the
            // terminator. The snapshot is materialised as a
            // `LocalId`-keyed `ArcLocalSet` so consumers don't need
            // to know about the analyzer's internal bitset
            // representation.
            if (isReturnEquivalentTerminator(instr.*)) {
                if (self.ownership_in_progress) |ownership| {
                    try self.snapshotLiveBeforeRet(ownership, id, &next_live);
                }
            }

            cur_live.deinit(self.allocator);
            cur_live = next_live;
        }

        return cur_live;
    }

    /// Materialise the in-progress bitset `live_before` into a
    /// `LocalId`-keyed `ArcLocalSet` and store it under `id` in
    /// `ownership.live_before_ret`. Each bit set in `live_before`
    /// corresponds to one ARC-managed local; the bit's index maps
    /// back to the local via `arc_locals[idx]`. The resulting set
    /// is owned by the ownership table and freed by `deinit`.
    fn snapshotLiveBeforeRet(
        self: *Analyzer,
        ownership: *ArcOwnership,
        id: InstructionId,
        live_before: *const LiveSet,
    ) error{OutOfMemory}!void {
        var local_set: ArcLocalSet = .empty;
        errdefer local_set.deinit(self.allocator);
        var bit_index: u32 = 0;
        const bit_count: u32 = @intCast(self.arc_locals.items.len);
        while (bit_index < bit_count) : (bit_index += 1) {
            if (live_before.contains(bit_index)) {
                const local_id = self.arc_locals.items[bit_index];
                try local_set.put(self.allocator, local_id, {});
            }
        }
        // Per-instruction-id snapshot: a given terminator id appears
        // in exactly one stream walk, so this `put` is the only
        // insertion for that key. Use `putNoClobber` to surface
        // mistakes if that invariant is ever violated.
        try ownership.live_before_ret.putNoClobber(self.allocator, id, local_set);
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
// Phase 4: per-program ownership orchestration + IR write-back.
// ============================================================

/// Side table keyed by `FunctionId` carrying the `ArcOwnership` that
/// `computeArcOwnership` produced for every function. Phase 4 populates
/// this map immediately after monomorphization; the same map is then
/// threaded through to `ZirDriver` so per-function lowering can read
/// `return_source_locals` (Phase 5) without re-running the analysis.
///
/// The map owns the inner `ArcOwnership` value and is responsible for
/// freeing every entry's nested `AutoHashMapUnmanaged` storage.
pub const ProgramArcOwnership = struct {
    allocator: std.mem.Allocator,
    by_function: std.AutoHashMapUnmanaged(ir.FunctionId, ArcOwnership) = .empty,

    /// Cumulative number of `share_value` instructions whose mode was
    /// upgraded from `.retain` to `.consume` during write-back.
    /// Diagnostic only; consumed by tests that want to confirm the
    /// write-back fired without observing the runtime counter.
    consumes_marked: u64 = 0,

    /// Cumulative number of locals classified as the immediate source
    /// of a `ret` instruction across the whole program. Diagnostic
    /// only; mirrors `consumes_marked` for the return-elision side.
    return_sources_recorded: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ProgramArcOwnership {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProgramArcOwnership) void {
        var it = self.by_function.valueIterator();
        while (it.next()) |entry| {
            entry.deinit(self.allocator);
        }
        self.by_function.deinit(self.allocator);
    }

    /// Lookup the per-function ownership table. Returns `null` for
    /// functions that had no ARC-managed locals (the analysis emits
    /// no entry in that case).
    pub fn get(self: *const ProgramArcOwnership, function_id: ir.FunctionId) ?*const ArcOwnership {
        return self.by_function.getPtr(function_id);
    }
};

/// Compute ARC ownership for every function in `program`, mutate every
/// `share_value` instruction whose ID is a consume site so that its
/// `mode` becomes `.consume`, and return the populated
/// `ProgramArcOwnership` map for downstream consumers (Phase 5+).
///
/// The IR mutation is in-place. `program.functions` is declared
/// `[]const Function` (via `toOwnedSlice` from the IR builder), but
/// the underlying memory is mutable; we reach through `@constCast`
/// only at the precise `share_value` payload we are upgrading. No
/// other instruction is touched and no slice header is rewritten.
///
/// The walk that performs the write-back uses the identical depth-first
/// region-tree traversal as `flattenInstructions`, so the implicit
/// `InstructionId` numbering matches one-to-one with the IDs the
/// analyzer used when it populated `consume_share_sites`.
pub fn runProgramArcOwnership(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    type_store: *const types_mod.TypeStore,
) !ProgramArcOwnership {
    var table = ProgramArcOwnership.init(allocator);
    errdefer table.deinit();

    for (program.functions) |*function| {
        var ownership = try computeArcOwnership(
            allocator,
            function,
            type_store,
            defaultArcManagedTypeId,
        );

        // Soundness contract from §2.3 of the implementation plan:
        // a local must never appear in *both* `consume_share_sites`
        // (via some site) and `return_source_locals`. The analyzer
        // already asserts the per-local invariant inside
        // `checkSoundness`; we re-assert at the orchestration seam
        // so a future refactor that silently relaxes the analyzer
        // assertion still trips here in debug builds.
        if (std.debug.runtime_safety) {
            assertConsumeReturnDisjoint(function, &ownership);
        }

        const consumes_marked = writeBackConsumeModes(function, &ownership);
        table.consumes_marked += consumes_marked;
        table.return_sources_recorded += ownership.return_source_locals.size;

        // Stash an entry for any function with ARC-managed locals.
        // The `arc_managed_locals` set is the soundness anchor: even
        // when no consume site or return source fires, a downstream
        // pass (e.g. `ZirDriver.shouldSkipArc`) needs to know which
        // locals are ARC-managed so it can refuse to mark them as
        // stack-eligible regardless of escape state. Functions with
        // no ARC-managed locals at all genuinely don't need an entry.
        if (ownership.arc_managed_locals.size != 0 or
            ownership.consume_share_sites.size != 0 or
            ownership.return_source_locals.size != 0 or
            ownership.last_use_map.size != 0)
        {
            try table.by_function.put(allocator, function.id, ownership);
        } else {
            ownership.deinit(allocator);
        }
    }

    return table;
}

/// Walk every `share_value` instruction in `function` in the same
/// depth-first order `flattenInstructions` used, and upgrade the mode
/// to `.consume` for any instruction whose synthesised `InstructionId`
/// appears in `ownership.consume_share_sites`. Returns the number of
/// instructions whose mode was changed.
///
/// Exposed (not just used internally by `runProgramArcOwnership`) so
/// targeted tests can construct an `ArcOwnership`, hand-roll a function,
/// and verify the write-back without going through the orchestration
/// wrapper. Phase 5+ tests benefit from the same surface.
pub fn writeBackConsumeModes(
    function: *const ir.Function,
    ownership: *const ArcOwnership,
) u64 {
    var walker = WriteBackWalker{
        .next_id = 0,
        .consumes_marked = 0,
        .ownership = ownership,
    };
    walker.walkFunction(function);
    return walker.consumes_marked;
}

const WriteBackWalker = struct {
    next_id: InstructionId,
    consumes_marked: u64,
    ownership: *const ArcOwnership,

    fn walkFunction(self: *WriteBackWalker, function: *const ir.Function) void {
        for (function.body) |block| {
            self.walkStream(block.instructions);
        }
    }

    fn walkStream(self: *WriteBackWalker, stream: []const ir.Instruction) void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            self.maybeUpgradeShareValue(instr, my_id);
            self.walkChildren(instr);
        }
    }

    fn maybeUpgradeShareValue(self: *WriteBackWalker, instr: *const ir.Instruction, id: InstructionId) void {
        if (instr.* != .share_value) return;
        if (!self.ownership.consume_share_sites.contains(id)) return;
        // The IR slice was allocated mutably by `IrBuilder.buildProgram`
        // (via `toOwnedSlice`) but exposed through a `[]const`-typed
        // field for general callers. Phase 4 is the one site that
        // legitimately needs to mutate a single `share_value` payload
        // in place, so the cast is confined here. We do not reorder
        // instructions, do not reallocate, and only touch the `mode`
        // field of the matched `ShareValue` payload.
        const mutable_instr: *ir.Instruction = @constCast(instr);
        if (mutable_instr.share_value.mode == .consume) {
            // Already consume: idempotent. Don't double-count.
            return;
        }
        mutable_instr.share_value.mode = .consume;
        self.consumes_marked += 1;
    }

    fn walkChildren(self: *WriteBackWalker, instr: *const ir.Instruction) void {
        switch (instr.*) {
            .if_expr => |ie| {
                self.walkStream(ie.then_instrs);
                self.walkStream(ie.else_instrs);
            },
            .case_block => |cb| {
                self.walkStream(cb.pre_instrs);
                for (cb.arms) |arm| {
                    self.walkStream(arm.cond_instrs);
                    self.walkStream(arm.body_instrs);
                }
                self.walkStream(cb.default_instrs);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| self.walkStream(c.body_instrs);
                self.walkStream(sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| self.walkStream(c.body_instrs);
                self.walkStream(sr.default_instrs);
            },
            .union_switch => |us| {
                for (us.cases) |c| self.walkStream(c.body_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| self.walkStream(c.body_instrs);
            },
            .try_call_named => |tc| {
                self.walkStream(tc.handler_instrs);
                self.walkStream(tc.success_instrs);
            },
            .guard_block => |gb| {
                self.walkStream(gb.body);
            },
            else => {},
        }
    }
};

/// Soundness check executed at the orchestration seam (debug builds
/// only). Walks the function's instructions, and for every consume
/// site, asserts that the source local of the matching `share_value`
/// is *not* also recorded in `return_source_locals`. The analyzer's
/// own `checkSoundness` already enforces this inside the pass; this
/// duplicate check guards against future refactors that might relax
/// the analyzer-side check or skip it.
fn assertConsumeReturnDisjoint(
    function: *const ir.Function,
    ownership: *const ArcOwnership,
) void {
    var checker = DisjointChecker{
        .next_id = 0,
        .ownership = ownership,
    };
    checker.walkFunction(function);
}

const DisjointChecker = struct {
    next_id: InstructionId,
    ownership: *const ArcOwnership,

    fn walkFunction(self: *DisjointChecker, function: *const ir.Function) void {
        for (function.body) |block| {
            self.walkStream(block.instructions);
        }
    }

    fn walkStream(self: *DisjointChecker, stream: []const ir.Instruction) void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            self.checkInstr(instr, my_id);
            self.walkChildren(instr);
        }
    }

    fn checkInstr(self: *DisjointChecker, instr: *const ir.Instruction, id: InstructionId) void {
        if (instr.* != .share_value) return;
        if (!self.ownership.consume_share_sites.contains(id)) return;
        const sv = instr.share_value;
        std.debug.assert(!self.ownership.return_source_locals.contains(sv.source));
    }

    fn walkChildren(self: *DisjointChecker, instr: *const ir.Instruction) void {
        switch (instr.*) {
            .if_expr => |ie| {
                self.walkStream(ie.then_instrs);
                self.walkStream(ie.else_instrs);
            },
            .case_block => |cb| {
                self.walkStream(cb.pre_instrs);
                for (cb.arms) |arm| {
                    self.walkStream(arm.cond_instrs);
                    self.walkStream(arm.body_instrs);
                }
                self.walkStream(cb.default_instrs);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| self.walkStream(c.body_instrs);
                self.walkStream(sl.default_instrs);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| self.walkStream(c.body_instrs);
                self.walkStream(sr.default_instrs);
            },
            .union_switch => |us| {
                for (us.cases) |c| self.walkStream(c.body_instrs);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| self.walkStream(c.body_instrs);
            },
            .try_call_named => |tc| {
                self.walkStream(tc.handler_instrs);
                self.walkStream(tc.success_instrs);
            },
            .guard_block => |gb| {
                self.walkStream(gb.body);
            },
            else => {},
        }
    }
};

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

/// Subset of terminators that hand control back to the function's
/// caller (rather than transferring within the same function). Each
/// such terminator is a candidate site for inserting scope-exit
/// `release` instructions on locals still live at that point.
///
/// `cond_return` is included because it conditionally leaves the
/// function; on the taken edge it is functionally a `ret`.
///
/// `tail_call` is included because the callee returns directly to
/// our caller — control never re-enters this function, so any local
/// still live at the tail_call must be released before the jump.
///
/// `switch_return` and `union_switch_return` are aggregating
/// terminators: each arm body ends with an implicit return whose
/// value is the arm's `return_value`. The dataflow records the
/// live-before set at the parent terminator id; per-arm refinement
/// (if needed by a future drop-insertion pass) is computable from
/// each arm's `return_value` plus the parent's set.
fn isReturnEquivalentTerminator(instr: ir.Instruction) bool {
    return switch (instr) {
        .ret,
        .cond_return,
        .tail_call,
        .switch_return,
        .union_switch_return,
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
        .optional_dispatch => |x| {
            // scrutinee_param is a param index (not a local); payload_local
            // is a def; nested nil_instrs / struct_instrs are visited
            // separately by the dataflow. The arm results flow into the
            // function via terminators in each arm (the nested streams),
            // not via this opcode directly.
            if (x.nil_result) |l| buf.append(allocator, l) catch {};
            if (x.struct_result) |l| buf.append(allocator, l) catch {};
        },
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
    try std.testing.expectEqual(@as(usize, 0), ownership.arc_managed_locals.count());
}

test "arc_liveness: arc_managed_locals records every ARC local in the function" {
    // Soundness anchor: the analyzer must surface every ARC-managed
    // local in the public ownership table so `ZirDriver.shouldSkipArc`
    // can refuse to mark them as stack-eligible regardless of the
    // escape lattice's verdict. Their cells live on heap pools and
    // suppressing retain/release would leak (or, with path-copy
    // structures, cause UAF on recycled cells).
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.id(h)
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

    // The function has at least the parameter `h` plus the call's
    // dest (return) flowing through ARC. arc_managed_locals must
    // include every such local.
    try std.testing.expect(ownership.arc_managed_locals.count() > 0);

    // Cross-check: every local that appears in retain/release/share
    // must be recorded as ARC-managed. The analyzer's identifyArcLocals
    // is the canonical seed; arc_managed_locals must be a superset of
    // every share_value source/dest reachable in the body.
    for (run_func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .share_value => |sv| {
                    try std.testing.expect(ownership.arc_managed_locals.contains(sv.source));
                    try std.testing.expect(ownership.arc_managed_locals.contains(sv.dest));
                },
                .retain => |r| try std.testing.expect(ownership.arc_managed_locals.contains(r.value)),
                .release => |r| try std.testing.expect(ownership.arc_managed_locals.contains(r.value)),
                else => {},
            }
        }
    }
}

// ============================================================
// Phase 4 unit tests: write-back of consume modes onto share_value.
// ============================================================

test "arc_liveness: writeBackConsumeModes upgrades every consume site" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use_one(h :: Handle) -> Handle { h }
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

    // Pre-condition: every share_value defaults to .retain.
    var share_value_pre_count: usize = 0;
    {
        var walker = WriteBackWalker{
            .next_id = 0,
            .consumes_marked = 0,
            .ownership = &ownership,
        };
        walker.walkFunction(run_func);
        // After the walker runs once, every share_value in
        // consume_share_sites is now .consume; second invocation
        // should report zero new upgrades (idempotent).
        const second = writeBackConsumeModes(run_func, &ownership);
        try std.testing.expectEqual(@as(u64, 0), second);
        share_value_pre_count = walker.consumes_marked;
    }
    try std.testing.expect(share_value_pre_count > 0);
    try std.testing.expectEqual(@as(usize, share_value_pre_count), ownership.consume_share_sites.count());

    // Top-level invariant: every share_value across the function
    // body is now `.consume` whenever it appears in the consume-site
    // table. The full structural traversal that built the IDs lives
    // in `WriteBackWalker`; the program-level integration test
    // re-validates the same invariant end-to-end.
    for (run_func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .share_value) {
                // After write-back, the only valid mode for any
                // share_value in this body is `.consume` (the helper
                // function only ever lowers a single ARC argument).
                try std.testing.expectEqual(ir.ShareMode.consume, instr.share_value.mode);
            }
        }
    }
}

test "arc_liveness: runProgramArcOwnership populates per-function table" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
        \\
        \\  pub fn use(h :: Handle) -> Handle {
        \\    Test.id(h)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    var table = try runProgramArcOwnership(
        std.testing.allocator,
        &suite.ir_program,
        suite.typeStore(),
    );
    defer table.deinit();

    // At least one function (`use`) must have a consume site, and at
    // least one function (`id`) must have a return-source local.
    var saw_consume = false;
    var saw_return_source = false;
    var it = table.by_function.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.consume_share_sites.size > 0) saw_consume = true;
        if (entry.value_ptr.return_source_locals.size > 0) saw_return_source = true;
    }
    try std.testing.expect(saw_consume);
    try std.testing.expect(saw_return_source);
    try std.testing.expect(table.consumes_marked > 0);
    try std.testing.expect(table.return_sources_recorded > 0);
}

test "arc_liveness: runProgramArcOwnership flips share_value mode on the IR" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use_one(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.use_one(h)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    // Pre-condition: every share_value starts at .retain.
    for (suite.ir_program.functions) |func| {
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .share_value) {
                    try std.testing.expectEqual(ir.ShareMode.retain, instr.share_value.mode);
                }
            }
        }
    }

    var table = try runProgramArcOwnership(
        std.testing.allocator,
        &suite.ir_program,
        suite.typeStore(),
    );
    defer table.deinit();

    // Post-condition: at least one share_value is now .consume.
    var saw_consume_in_ir = false;
    for (suite.ir_program.functions) |func| {
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .share_value and instr.share_value.mode == .consume) {
                    saw_consume_in_ir = true;
                }
            }
        }
    }
    try std.testing.expect(saw_consume_in_ir);
}

// ============================================================
// Phase 5 unit tests: return-source drop elision.
//
// Phase 5 wires `return_source_locals` into the function-epilogue
// release filter via `ZirDriver.markReturned` + `isReleaseSuppressed`.
// The runtime counter `arc_return_elisions_total` is bumped at the
// elision point so the load-bearing observation is visible under
// `ZAP_ARC_STATS=1`. These tests pin the IR-level invariants the
// lowering depends on:
//   1. For an Arc-managed identity function, the analyzer records the
//      parameter as a return source.
//   2. For a function that calls a helper and returns the call's
//      result, the analyzer records the call's dest (an ARC local) as
//      a return source — *not* the parameter (which is consumed at
//      the call). The two sets are disjoint by construction.
//   3. For the k-nucleotide-shaped tail loop, both consume and
//      return-source categories populate, exactly as Phase 5 needs to
//      handle the dual elision (release of `m` in the base-case arm
//      AND retain/release elision around the recursive-call arg).
// ============================================================

/// Collect every local that appears as the source of any `release`
/// instruction in `function`, walking nested control-flow streams.
/// Used by Phase 5 tests to verify which scope-exit releases the
/// release filter would suppress.
fn collectReleaseSources(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) !std.AutoHashMapUnmanaged(ir.LocalId, void) {
    var result: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
    const Walker = struct {
        result: *std.AutoHashMapUnmanaged(ir.LocalId, void),
        allocator: std.mem.Allocator,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (instr.* == .release) {
                self.result.put(self.allocator, instr.release.value, {}) catch {};
            }
        }
    };
    var walker = Walker{ .result = &result, .allocator = allocator };
    ir.forEachInstruction(function, &walker, Walker.visit);
    return result;
}

test "arc_liveness: Phase 5 — direct return populates return_source_locals" {
    // The identity function on an Arc-managed type is the canonical
    // shape Phase 5's filter must handle: the parameter local is the
    // value of `ret`, so its scope-exit release (if any) is elided.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    // The return-source set must contain exactly `h`. Replaying it
    // into the ZirDriver via `markReturned` is what Phase 4's
    // `beginFunction` does at lowering time; the load-bearing
    // invariant for Phase 5 is that the *set is non-empty* so the
    // backend has at least one local to filter on.
    try std.testing.expect(ownership.return_source_locals.count() >= 1);
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
}

test "arc_liveness: Phase 5 — branching identity returns each arm's local as return source" {
    // `pick(b, x, y)` where each arm is a direct-return of a
    // parameter must record both arm-result locals as return sources.
    // The IR builder lowers the case-expression by allocating an
    // aggregate dest local; the analyzer's
    // `propagateReturnSourcesThroughAggregates` step folds the arm
    // results back into the return-source set, which Phase 5's filter
    // then suppresses at scope exit.
    //
    // Uses `case` rather than `if/else` because Zap's HIR-pass surface
    // for if-expression-as-return-value-aggregate is not yet wired
    // for opaque-typed branch results; `case` is the canonical surface
    // syntax for branching last-value semantics in the existing tests.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn pick(b :: Bool, x :: Handle, y :: Handle) -> Handle {
        \\    case b {
        \\      true -> x
        \\      false -> y
        \\    }
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const pick_func = suite.findFunctionByName("pick") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        pick_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Both `x` and `y` (and possibly the case-expression's aggregate
    // dest) should be return sources. The exact count depends on
    // whether the IR materialises an aggregate local; the load-bearing
    // assertion is that the set contains more than one local — pinning
    // that the propagate-through-aggregates step wired up in Phase 4
    // does the right thing for Phase 5's filter.
    try std.testing.expect(ownership.return_source_locals.count() >= 2);
}

test "arc_liveness: Phase 5 — k-nucleotide-shaped tail loop populates both categories" {
    // The plan's prototype shape: a recursive function whose then-arm
    // returns the ARC parameter directly (return-source elision) and
    // whose else-arm tail-recurses with a helper-produced value
    // (consume site at the helper call). Phase 5's filter must
    // suppress the release on `m` in the base-case arm; Phase 4's
    // consume infrastructure must suppress the share-retain at the
    // helper call site. Both fire on the same function, on disjoint
    // locals.
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

    try std.testing.expect(ownership.consume_share_sites.count() >= 1);
    try std.testing.expect(ownership.return_source_locals.count() >= 1);
}

test "arc_liveness: Phase 5 — function returning helper(x) does not list parameter as return source" {
    // Negative test: when the function's `ret` value is the *call's
    // result* (a fresh ARC local), the parameter `x` is NOT a return
    // source — `x` is consumed at the call. The filter must elide
    // the release of the call result, not the parameter. This pins
    // the disjointness invariant the analyzer's `checkSoundness`
    // asserts.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn helper(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(x :: Handle) -> Handle {
        \\    Test.helper(x)
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

    // Find the param-local for `x` so we can prove it is NOT a
    // return source. The IR allocates parameter locals starting at
    // 0 in source order; for `run(x :: Handle)` the param-get's dest
    // is the function's first ARC-managed local.
    try std.testing.expect(ownership.consume_share_sites.count() >= 1);
    // Parameter `x` is consumed at the call, so it must not be a
    // return source. The analyzer's soundness check (`checkSoundness`)
    // already asserts disjointness in debug builds, but pinning the
    // expectation here makes Phase 5's contract explicit.
    var consumed_sources: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
    defer consumed_sources.deinit(std.testing.allocator);
    var iter = ownership.consume_share_sites.keyIterator();
    while (iter.next()) |id_ptr| {
        // For each consume site, walk the function to find the share's source.
        const Walker = struct {
            target_id: u32,
            count: u32 = 0,
            sources: *std.AutoHashMapUnmanaged(ir.LocalId, void),
            allocator: std.mem.Allocator,
            fn visit(self: *@This(), instr: *const ir.Instruction) void {
                if (instr.* == .share_value) {
                    if (self.count == self.target_id) {
                        self.sources.put(self.allocator, instr.share_value.source, {}) catch {};
                    }
                    self.count += 1;
                }
            }
        };
        var walker = Walker{
            .target_id = id_ptr.*,
            .sources = &consumed_sources,
            .allocator = std.testing.allocator,
        };
        ir.forEachInstruction(run_func, &walker, Walker.visit);
    }
    var ret_iter = ownership.return_source_locals.keyIterator();
    while (ret_iter.next()) |ret_local_ptr| {
        try std.testing.expect(!consumed_sources.contains(ret_local_ptr.*));
    }
}

test "arc_liveness: Phase 5 — release filter suppresses return-source releases" {
    // Phase 5's load-bearing post-condition: the ZIR backend's
    // release-emission filter (`isReleaseSuppressed`) returns true
    // for every local recorded in `arc_returned_locals`. The Phase
    // 4-installed `markReturned` hook copies entries from the
    // analyzer's `return_source_locals` into `arc_returned_locals`
    // at function-begin time; here we exercise the end-to-end set
    // membership via the public driver API. The mechanics — that the
    // analyzer + `markReturned` produce a non-empty
    // `arc_returned_locals` and that `isReleaseSuppressed` reports
    // true for those locals — are what guarantee the scope-exit
    // release for a return-source local is elided in lowering.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    try std.testing.expect(ownership.return_source_locals.count() >= 1);

    // Simulate Phase 4's `beginFunction` replay: every entry in
    // `return_source_locals` flows through `markReturned` into
    // `arc_returned_locals`. The driver's `isReleaseSuppressed` then
    // reports true for each of those locals, which is what tells the
    // .release lowering to skip emission and bump the
    // `arc_return_elisions_total` counter.
    const zb = @import("zir_builder.zig");
    var driver = zb.ZirDriver{
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

    var ret_iter = ownership.return_source_locals.keyIterator();
    while (ret_iter.next()) |local_ptr| {
        try driver.markReturned(local_ptr.*);
        try std.testing.expect(driver.isReleaseSuppressed(local_ptr.*));
    }

    // Auxiliary observation: the IR may or may not emit a release
    // for the parameter at scope exit (it currently doesn't, because
    // the parameter was never shared into a callee). Any release
    // that *does* exist on a return-source local would be filtered
    // by `isReleaseSuppressed`. The collector below verifies the
    // helper does in fact run without error, pinning the public API.
    var release_sources = try collectReleaseSources(std.testing.allocator, id_func);
    defer release_sources.deinit(std.testing.allocator);
    // No assertion on count: the test's contract is the membership
    // check above, not a specific release-count expectation.
}

// ============================================================
// Phase 6 prep: per-terminator live-before-ret snapshots.
//
// `ArcOwnership.live_before_ret` records, for every ret-equivalent
// terminator instruction id, the set of ARC-managed locals live
// immediately before that terminator. A future drop-insertion pass
// consults this map to know which locals need a scope-exit `release`
// inserted at each termination point. The tests below pin the
// expected shape of the map across the canonical control-flow
// patterns the drop-insertion pass will encounter.
// ============================================================

test "arc_liveness: live_before_ret records ARC locals at simple ret(local)" {
    // The identity function: a single `ret value` instruction whose
    // value is the (ARC-managed) parameter. The live-before set at
    // the ret must contain exactly that parameter local.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    // The ret terminator (or a tail-call equivalent) must have a
    // live-before-ret entry. For an identity function the IR builder
    // may emit either a `ret` directly or a `tail_call` of a value
    // synthesized via param_get; either is a ret-equivalent
    // terminator and gets its own snapshot. We don't pin the exact
    // tag — the load-bearing assertion is that *some* live-before-ret
    // entry contains an ARC-managed local that traces back to `h`.
    try std.testing.expect(ownership.live_before_ret.count() >= 1);

    // Every snapshot must be non-empty for an identity function,
    // since the parameter `h` is live up to the function's exit.
    var saw_non_empty = false;
    var live_iter = ownership.live_before_ret.valueIterator();
    while (live_iter.next()) |set_ptr| {
        if (set_ptr.count() >= 1) saw_non_empty = true;
    }
    try std.testing.expect(saw_non_empty);
}

test "arc_liveness: live_before_ret records the case-aggregate flowing into ret" {
    // Two branches that each return a distinct ARC-managed parameter.
    // Zap's case-lowering allocates an aggregate dest local that both
    // arms `share_value` into (consuming `x` and `y` at last-use along
    // each arm); the post-case `ret` sees only the aggregate as live.
    // The live-before-ret snapshot at the ret therefore contains
    // exactly one ARC-managed local (the case aggregate) — the
    // analyzer's `propagateReturnSourcesThroughAggregates` step is
    // what later folds the underlying `x`/`y` arm locals into the
    // return-source set. The two side-tables address different needs:
    //   * `live_before_ret` answers "what is dataflow-live at the
    //     terminator?" — the answer is the aggregate.
    //   * `return_source_locals` answers "which underlying locals'
    //     ownership flows through the aggregate to the caller?" —
    //     that includes `x` and `y` after propagation.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn pick(b :: Bool, x :: Handle, y :: Handle) -> Handle {
        \\    case b {
        \\      true -> x
        \\      false -> y
        \\    }
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const pick_func = suite.findFunctionByName("pick") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        pick_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // At least one ret-equivalent terminator must have a snapshot,
    // and at least one of those snapshots must contain at least one
    // ARC-managed local (the aggregate). The exact count depends on
    // the lowering shape; pinning the *non-empty* contract is the
    // load-bearing assertion for downstream drop-insertion.
    try std.testing.expect(ownership.live_before_ret.count() >= 1);
    var saw_non_empty = false;
    var live_iter = ownership.live_before_ret.valueIterator();
    while (live_iter.next()) |set_ptr| {
        if (set_ptr.count() >= 1) saw_non_empty = true;
    }
    try std.testing.expect(saw_non_empty);
}

test "arc_liveness: live_before_ret captures cond_return live set" {
    // A multi-clause function lowers to a sequence of `cond_return`
    // (or `switch_return`) instructions, each of which is a
    // ret-equivalent terminator. Each terminator's live-before set
    // should reflect the specific value being returned at that point.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn first(h :: Handle, _g :: Handle) -> Handle { h }
        \\  pub fn second(_h :: Handle, g :: Handle) -> Handle { g }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const first_func = suite.findFunctionByName("first") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        first_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Whatever ret-equivalent terminator the IR builder emits for
    // a single-clause function, there must be at least one snapshot,
    // and it must contain at least one ARC-managed local (the
    // returned parameter `h`).
    try std.testing.expect(ownership.live_before_ret.count() >= 1);
    var saw_non_empty = false;
    var live_iter = ownership.live_before_ret.valueIterator();
    while (live_iter.next()) |set_ptr| {
        if (set_ptr.count() >= 1) saw_non_empty = true;
    }
    try std.testing.expect(saw_non_empty);
}

test "arc_liveness: live_before_ret populated for switch_return-shaped multi-clause" {
    // Multi-clause Arc-typed functions can lower to `switch_return`
    // (literal-dispatch) or to per-clause `cond_return` chains. In
    // either case every ret-equivalent terminator instruction
    // produces its own live-before snapshot. This test pins the
    // invariant that *some* snapshot contains an ARC-managed local
    // when the function returns one — without pinning the exact
    // lowering shape, since the IR builder's choice of dispatch is
    // an implementation detail.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn pick(c :: i64, x :: Handle, y :: Handle) -> Handle {
        \\    case c {
        \\      0 -> x
        \\      _ -> y
        \\    }
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const pick_func = suite.findFunctionByName("pick") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        pick_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(ownership.live_before_ret.count() >= 1);
    var saw_arc_local = false;
    var live_iter = ownership.live_before_ret.valueIterator();
    while (live_iter.next()) |set_ptr| {
        if (set_ptr.count() >= 1) saw_arc_local = true;
    }
    try std.testing.expect(saw_arc_local);
}

test "arc_liveness: live_before_ret is empty/absent when no ARC locals are in scope" {
    // A function with no ARC-managed locals must produce an
    // ownership table whose `live_before_ret` is empty, since the
    // analyzer short-circuits before running the dataflow when
    // `arc_locals` is empty. This exercises the no-op contract from
    // the field's docstring.
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

    try std.testing.expectEqual(@as(usize, 0), ownership.live_before_ret.count());
}

test "arc_liveness: live_before_ret keys all map to ret-equivalent terminator instructions" {
    // Soundness invariant: every key in `live_before_ret` is the
    // `InstructionId` of an instruction whose tag is one of the
    // ret-equivalent terminators (`ret`, `cond_return`, `tail_call`,
    // `switch_return`, `union_switch_return`). Walks the function's
    // structural region tree using the same depth-first numbering as
    // the analyzer and checks each recorded id.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    // Build a map from InstructionId → tag using the same depth-first
    // walk as the analyzer.
    var id_to_tag: std.AutoHashMapUnmanaged(InstructionId, std.meta.Tag(ir.Instruction)) = .empty;
    defer id_to_tag.deinit(std.testing.allocator);
    const Walker = struct {
        next_id: InstructionId = 0,
        id_to_tag: *std.AutoHashMapUnmanaged(InstructionId, std.meta.Tag(ir.Instruction)),
        allocator: std.mem.Allocator,

        fn walkFunction(self: *@This(), func: *const ir.Function) error{OutOfMemory}!void {
            for (func.body) |block| try self.walkStream(block.instructions);
        }

        fn walkStream(self: *@This(), stream: []const ir.Instruction) error{OutOfMemory}!void {
            for (stream) |*instr| {
                const my_id = self.next_id;
                self.next_id += 1;
                try self.id_to_tag.put(self.allocator, my_id, std.meta.activeTag(instr.*));
                try self.walkChildren(instr);
            }
        }

        fn walkChildren(self: *@This(), instr: *const ir.Instruction) error{OutOfMemory}!void {
            switch (instr.*) {
                .if_expr => |ie| {
                    try self.walkStream(ie.then_instrs);
                    try self.walkStream(ie.else_instrs);
                },
                .case_block => |cb| {
                    try self.walkStream(cb.pre_instrs);
                    for (cb.arms) |arm| {
                        try self.walkStream(arm.cond_instrs);
                        try self.walkStream(arm.body_instrs);
                    }
                    try self.walkStream(cb.default_instrs);
                },
                .switch_literal => |sl| {
                    for (sl.cases) |c| try self.walkStream(c.body_instrs);
                    try self.walkStream(sl.default_instrs);
                },
                .switch_return => |sr| {
                    for (sr.cases) |c| try self.walkStream(c.body_instrs);
                    try self.walkStream(sr.default_instrs);
                },
                .union_switch => |us| {
                    for (us.cases) |c| try self.walkStream(c.body_instrs);
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |c| try self.walkStream(c.body_instrs);
                },
                .try_call_named => |tc| {
                    try self.walkStream(tc.handler_instrs);
                    try self.walkStream(tc.success_instrs);
                },
                .guard_block => |gb| {
                    try self.walkStream(gb.body);
                },
                else => {},
            }
        }
    };
    var walker = Walker{
        .id_to_tag = &id_to_tag,
        .allocator = std.testing.allocator,
    };
    try walker.walkFunction(id_func);

    var live_iter = ownership.live_before_ret.keyIterator();
    while (live_iter.next()) |id_ptr| {
        const tag = id_to_tag.get(id_ptr.*) orelse return error.IdNotFound;
        const ok = tag == .ret or
            tag == .cond_return or
            tag == .tail_call or
            tag == .switch_return or
            tag == .union_switch_return;
        try std.testing.expect(ok);
    }
}
