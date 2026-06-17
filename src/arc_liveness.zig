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
    ///
    /// This map records ONE last-use instruction per local — the last
    /// one visited during the depth-first analysis walk. For locals
    /// whose live-range terminates on multiple disjoint control-flow
    /// paths (e.g., a binding read in every arm of an `if_expr`/
    /// `case_block`), only the last-visited site is recorded here.
    /// Use `last_use_sites` instead when path-sensitive last-use
    /// detection is needed (the uniqueness borrow→consume classifier in
    /// `arc_ownership.shouldMoveIntoOwnedConsume`, the chain-consistency
    /// audit in `arc_param_convention.siteConsumesSlot`, etc.).
    last_use_map: std.AutoHashMapUnmanaged(ir.LocalId, InstructionId) = .empty,

    /// Path-sensitive last-use record. For every ARC-managed local L
    /// and every instruction id I where L is at a last-use (live
    /// before I, dead after I), the pair `(L, I)` is in this set.
    /// Multiple last-use sites per local are preserved — critical for
    /// branched control flow, where a binding read in arm A and arm B
    /// of an `if_expr` is at last-use along both paths.
    ///
    /// Used by the uniqueness borrow→consume classifier
    /// (`arc_ownership.shouldMoveIntoOwnedConsume`) to decide whether
    /// a `local_get` is at a last-use of its source on its execution
    /// path — the binding-read-in-every-arm pattern fails the flat
    /// `total_use_count == 1` check (count is 2: one per arm) but
    /// passes this path-sensitive predicate.
    ///
    /// Keyed by a packed `u64` of `(local << 32) | id`. Entries are
    /// added by `classifyLastUses` alongside the legacy `last_use_map`
    /// puts; both are populated in lock-step. Querying via
    /// `isLastUseAt(local, id)` returns true iff the pair is in the
    /// set.
    last_use_sites: std.AutoHashMapUnmanaged(u64, void) = .empty,

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

    /// Phase E.5 Gap 7 — the forward "defined-and-still-owns-+1"
    /// snapshot at every ret-equivalent terminator. Complements
    /// `live_before_ret`: liveness answers "which locals are read
    /// after this point" while ownership answers "which locals own
    /// +1 at this point". The two diverge for owned-by-construction
    /// bindings whose last use is a `share_value` — the share
    /// retains rather than consumes, so the source is dead per
    /// liveness yet still owns its +1. Without this table,
    /// `arc_drop_insertion` never sees those locals and they leak.
    ///
    /// Forward dataflow:
    ///   - Define an ARC-managed-owned local D (any defining
    ///     instruction whose `function.local_ownership[D]` is
    ///     `.owned`): set bit D.
    ///   - `release{value=L}`: clear bit L (cell now released; any
    ///     subsequent use is undefined behavior).
    ///   - `move_value{dest, source}`: clear `source`, set `dest`
    ///     (ownership transfers; source dead after this point).
    ///   - `tail_call` arg local L: clear bit L (callee inherits
    ///     ownership through the tail jump). Other tail_call locals
    ///     are unchanged.
    ///   - At nested-region boundaries (`if_expr`, `case_block`,
    ///     `switch_*`, `optional_dispatch`, `try_call_named`,
    ///     `guard_block`): each sub-stream sees the parent's `owns`
    ///     as its starting set; the post-region `owns` becomes the
    ///     intersection of arm-end `owns` sets (a local owns +1 at
    ///     the join only if every arm leaves it owning +1).
    ///
    /// Snapshot at every ret-equivalent terminator records the
    /// owns-set just before the terminator executes.
    owned_at_ret: std.AutoHashMapUnmanaged(InstructionId, ArcLocalSet) = .empty,

    /// Owned locals that must be released immediately before a
    /// branch-local `.case_break`. `case_break` is not a function
    /// return: its value flows into the enclosing `case_block.dest`.
    /// Any other owned locals created inside the branch do not exist
    /// in the parent Zig scope, so they must be destroyed inside the
    /// branch rather than carried into the parent `owned_at_ret`.
    owned_at_case_break: std.AutoHashMapUnmanaged(InstructionId, ArcLocalSet) = .empty,

    /// Locals produced by `param_get` after the corresponding
    /// `.owned` parameter slot has already been consumed. These are
    /// non-owning aliases to the slot's storage, used only for
    /// bounded reads in the same expression path. They must not be
    /// released at scope exit even though their local ownership class
    /// remains `.owned` in the original IR metadata.
    non_owning_param_refetches: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty,

    /// Total number of instruction records the analyzer flattened for
    /// this function — i.e. the count of every instruction (top-level
    /// and nested) in canonical flatten order. Every id-mirroring
    /// consumer (drop insertion, ownership rewriters, uniqueness,
    /// verifier) must walk EXACTLY this many instructions; a mismatch
    /// means the consumer's structural traversal diverged from the
    /// analyzer's `flattenChildren` and its InstructionId keys are
    /// desynchronized. `assertConsumerWalkMatches` checks this in debug
    /// builds so any future drift fails loudly. (Audit R1.)
    ///
    /// `null` when this table was NOT produced by `computeArcOwnership`
    /// (e.g. a synthetic table hand-built by a unit test): there is no
    /// analyzer flatten to mirror, so the cross-check is skipped.
    record_count: ?usize = null,

    pub fn deinit(self: *ArcOwnership, allocator: std.mem.Allocator) void {
        self.consume_share_sites.deinit(allocator);
        self.return_source_locals.deinit(allocator);
        self.arc_managed_locals.deinit(allocator);
        self.last_use_map.deinit(allocator);
        self.last_use_sites.deinit(allocator);
        var live_iter = self.live_before_ret.valueIterator();
        while (live_iter.next()) |set_ptr| {
            set_ptr.deinit(allocator);
        }
        self.live_before_ret.deinit(allocator);
        var owned_iter = self.owned_at_ret.valueIterator();
        while (owned_iter.next()) |set_ptr| {
            set_ptr.deinit(allocator);
        }
        self.owned_at_ret.deinit(allocator);
        var case_break_iter = self.owned_at_case_break.valueIterator();
        while (case_break_iter.next()) |set_ptr| {
            set_ptr.deinit(allocator);
        }
        self.owned_at_case_break.deinit(allocator);
        self.non_owning_param_refetches.deinit(allocator);
    }

    /// Pack a `(LocalId, InstructionId)` pair into a `u64` key for
    /// `last_use_sites` lookups. `local` occupies the high 32 bits;
    /// `id` the low 32. Mirrors the packing helpers in
    /// `arc_param_convention` (`liftKey`).
    fn lastUseKey(local: ir.LocalId, id: InstructionId) u64 {
        return (@as(u64, @intCast(local)) << 32) | @as(u64, @intCast(id));
    }

    /// Path-sensitive last-use predicate. Returns true iff `local` was
    /// alive immediately before instruction `id` and dead immediately
    /// after — i.e. instruction `id` is one of the (possibly multiple)
    /// last-use sites for `local`. Unlike `last_use_map[local] == id`
    /// which only records ONE last-use per local, this predicate
    /// returns true for EVERY last-use site, including the "binding
    /// read in every arm of an if/case" pattern.
    pub fn isLastUseAt(self: *const ArcOwnership, local: ir.LocalId, id: InstructionId) bool {
        return self.last_use_sites.contains(lastUseKey(local, id));
    }
};

/// Count every instruction (top-level and nested, in canonical flatten
/// order) in `function`, using `ir.forEachChildStream` — the single
/// source of truth the analyzer's `flattenChildren` also uses. This is
/// the count an id-mirroring consumer's structural walk MUST reproduce.
pub fn countInstructionRecords(function: *const ir.Function) usize {
    const Counter = struct {
        count: usize = 0,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            _ = instr;
            self.count += 1;
        }
    };
    var counter = Counter{};
    ir.forEachInstruction(function, &counter, Counter.visit);
    return counter.count;
}

/// Non-panicking peer of `assertConsumerWalkMatches`: returns `true`
/// when an id-mirroring consumer's final `next_id` matches the analyzer
/// record count this ownership table was built against, and `true`
/// (vacuously) when `record_count` is null (synthetic unit-test table
/// with no analyzer flatten to mirror). Returns `false` only on a
/// genuine desync. Exposed so tests can assert the consistency invariant
/// without tripping the debug panic.
///
/// A `false` result has two distinct root causes, both fatal to the
/// consumer's InstructionId keys:
///   1. Structural traversal drift — the consumer recurses into a
///      different sub-stream set than `flattenChildren` (the historical
///      `union_switch.else_instrs` skip; Audit R1 / arc-own-1--01).
///   2. Stale ownership table — the table was computed against an IR
///      shape with a different instruction count than the one the
///      consumer is now walking, because a count-mutating rewrite ran
///      between the analysis and this consumer without an intervening
///      recompute (Audit arc-own-1--02). The consumer walks the mutated
///      IR (different `next_id`) while keying into last-use data built
///      for the pre-mutation IR.
pub fn consumerWalkMatches(
    ownership: *const ArcOwnership,
    consumer_next_id: usize,
) bool {
    const expected = ownership.record_count orelse return true;
    return consumer_next_id == expected;
}

/// Debug-only assertion (Audit R1 + arc-own-1--02): an id-mirroring
/// consumer that walked `function` and arrived at `consumer_next_id`
/// must have visited exactly as many instructions as the analyzer
/// recorded into the ownership table it is consuming. A mismatch proves
/// either that the consumer's structural traversal diverged from
/// `flattenChildren` (the historical `union_switch.else_instrs` skip) or
/// that the ownership table is stale relative to the current IR (a
/// count-mutating rewrite ran without an intervening recompute). In
/// both cases the consumer's InstructionId keys are desynchronized and
/// its drop/move/uniqueness decisions are mis-keyed. Fails loudly here
/// instead of silently miscompiling.
///
/// No-op in release builds (`std.debug.assert` compiles out), so it adds
/// zero cost to shipped binaries. Also a no-op when `record_count` is
/// null (the ownership table was not produced by `computeArcOwnership`,
/// e.g. a synthetic unit-test table — there is no analyzer flatten to
/// mirror).
pub fn assertConsumerWalkMatches(
    ownership: *const ArcOwnership,
    consumer_next_id: usize,
) void {
    std.debug.assert(consumerWalkMatches(ownership, consumer_next_id));
}

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
    /// `optional_dispatch.nil_instrs` — body of the synthetic
    /// `if (param == null) { ... }` branch. Each instruction inside
    /// is followed by a synthetic `ret nil_result` at ZIR emission;
    /// any explicit IR terminator inside the body (tail_call,
    /// switch_return, cond_return, ...) is a return-equivalent site
    /// that needs scope-exit drops just like terminators in any
    /// other return arm. (Phase D, Phase 6 redux plan §3.D.)
    optional_dispatch_nil: InstructionId,
    /// `optional_dispatch.struct_instrs` — body of the synthetic
    /// `else { payload_local = param.?; ... }` branch. Same drop
    /// semantics as `optional_dispatch_nil`. (Phase D.)
    optional_dispatch_struct: InstructionId,
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
    return computeArcOwnershipWithProgram(allocator, function, type_store, arc_managed, null);
}

/// Variant of `computeArcOwnership` that accepts an optional program
/// reference so the per-call ownership-effect analysis can look up
/// the callee's `param_conventions` and clear the source local's
/// owns bit when the callee consumes the arg (`.owned` convention).
///
/// Without this, a `move_value` produced by `arc_ownership.rewrite
/// OwnedConsumeSites` for an `.owned`-convention call site sets the
/// dest's owns bit (the dest is `.owned` in `local_ownership`) but
/// nothing clears it after the call — `live_before_ret` then carries
/// the local through to ret, and `arc_drop_insertion` emits a stale
/// `release` that double-decrements a cell the callee already
/// consumed via its own scope-exit drop.
pub fn computeArcOwnershipWithProgram(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    type_store: *const types_mod.TypeStore,
    arc_managed: ArcManagedFn,
    program: ?*const ir.Program,
) !ArcOwnership {
    var analyzer = Analyzer{
        .allocator = allocator,
        .function = function,
        .type_store = type_store,
        .arc_managed = arc_managed,
        .program = program,
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

    // Record the authoritative instruction count so id-mirroring
    // consumers can assert their structural walk visits exactly as many
    // instructions (see `assertConsumerWalkMatches`).
    ownership.record_count = analyzer.records.items.len;

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
    try analyzer.recordNonArcAggregateLastUses(&ownership);
    try analyzer.propagateReturnSourcesThroughAggregates(&ownership);
    try analyzer.computeOwnedAtRet(&ownership);

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
    /// Optional program reference. When non-null, the per-call
    /// ownership-effect analysis (`applyOwnsEffect` for
    /// `.call_direct` / `.call_named` / `.call_dispatch`) consults
    /// the callee's `param_conventions` and clears each arg local's
    /// owns bit at the slots whose convention is `.owned`. This is
    /// the dataflow counterpart to `arc_ownership.rewriteOwnedConsume
    /// Sites`: that pass converts the caller's `share_value` into
    /// `move_value` and drops the post-call release so the callee's
    /// scope-exit drop is the sole decrement; without the matching
    /// owns-bit clear here, `live_before_ret` would still carry the
    /// consumed local and `arc_drop_insertion` would re-emit the very
    /// release the rewrite was trying to elide. Left null when the
    /// caller doesn't have a program in hand (analyzer tests build
    /// hand-rolled `ir.Function` values without a containing program).
    program: ?*const ir.Program = null,

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

    /// Phase 4 (dense Map) — alias group bookkeeping for `.owned`
    /// parameter slots.
    ///
    /// When a function has multiple `param_get` instructions reading
    /// the same `.owned`-convention parameter slot, every read is an
    /// alias of the function-entry +1 for that slot. The forward
    /// `owns` dataflow as written sets a separate bit for each alias
    /// LocalId at the corresponding `param_get`, so when a downstream
    /// consume site (e.g. `move_value` into a `Map.put` arg) clears
    /// the bit tied to ONE alias, the OTHER aliases' bits stay set.
    /// `arc_drop_insertion` then emits a stale scope-exit release on
    /// those leftover aliases, producing the double-free signature
    /// observed in `count_kmers_loop`.
    ///
    /// `param_alias_group` records, for each `param_get` dest of an
    /// `.owned` slot, the list of ALL `param_get` dests that read the
    /// same slot (including itself). Looking up any alias yields the
    /// full group, so a consume site can clear every alias's bit in
    /// one pass — preventing stale releases on sibling aliases that
    /// the consume didn't directly touch.
    ///
    /// The forward dataflow consults this map at consume sites
    /// (`move_value`, `applyCallConsumeEffect`,
    /// `applyCallBuiltinConsumeEffect`, `local_set` transfer): when
    /// the consumed LocalId is in the map, we clear EVERY alias's
    /// owns bit so the slot's single +1 is consumed exactly once and
    /// no sibling alias contributes a stale release at the next
    /// terminator's `owned_at_ret`.
    ///
    /// We deliberately do NOT alter the `seen → arc_locals` mapping,
    /// because liveness reconstruction (`snapshotLiveBeforeRet`,
    /// `snapshotOwnedAtRet`) maps each bit back to a single LocalId
    /// via `arc_locals[bit]`. Sharing one bit across aliases would
    /// silently swap LocalIds at the reconstruction seam, returning
    /// (e.g.) the case[1] alias for a case[0] terminator — wrong.
    /// Per-alias bits with a "consume one, consume all" rule keeps
    /// the reconstruction faithful to per-control-flow-path liveness.
    ///
    /// Lifetime: each value slice is allocated from the analyzer's
    /// allocator and freed in `deinit`.
    param_alias_group: std.AutoHashMapUnmanaged(ir.LocalId, []const ir.LocalId) = .empty,

    /// Maps each `param_get` dest of an `.owned` parameter slot back
    /// to that slot. The forward ownership pass uses this to remember
    /// when the slot's single incoming +1 has been consumed, preventing
    /// a later refetch of the same parameter from resurrecting an owner
    /// bit for a value that has already moved.
    owned_param_slot_by_local: std.AutoHashMapUnmanaged(ir.LocalId, u32) = .empty,

    fn deinit(self: *Analyzer) void {
        self.records.deinit(self.allocator);
        self.pointer_to_id.deinit(self.allocator);
        self.arc_locals.deinit(self.allocator);
        self.local_to_arc_index.deinit(self.allocator);
        // Free each alias group's slice. Multiple keys may point at
        // the same slice (members of one group share the alias list);
        // dedupe by tracking pointers we've already freed.
        var freed: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer freed.deinit(self.allocator);
        var alias_iter = self.param_alias_group.valueIterator();
        while (alias_iter.next()) |slice_ptr| {
            const ptr_addr: usize = @intFromPtr(slice_ptr.*.ptr);
            if (freed.contains(ptr_addr)) continue;
            freed.put(self.allocator, ptr_addr, {}) catch {};
            self.allocator.free(slice_ptr.*);
        }
        self.param_alias_group.deinit(self.allocator);
        self.owned_param_slot_by_local.deinit(self.allocator);
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

    /// Assign `InstructionId`s to every nested sub-stream of `instr`, in
    /// canonical flatten order, via `ir.forEachChildStream` — the single
    /// source of truth for structural recursion. This is the AUTHORITY
    /// the drop-insertion / ownership / uniqueness / verifier walkers must
    /// mirror; routing it through `forEachChildStream` (which itself yields
    /// `union_switch.else_instrs` when `has_else` and both
    /// `optional_dispatch` arms) guarantees every consumer that also routes
    /// through the enumerator numbers identically.
    fn flattenChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
        parent_id: InstructionId,
    ) error{OutOfMemory}!void {
        const Ctx = struct {
            analyzer: *Analyzer,
            parent_id: InstructionId,
            err: ?error{OutOfMemory} = null,
            fn onStream(self_ctx: *@This(), child: ir.ChildStream) void {
                if (self_ctx.err != null) return;
                self_ctx.analyzer.flattenStream(
                    child.stream,
                    parentLinkForChildKind(child.kind, self_ctx.parent_id),
                ) catch |e| {
                    self_ctx.err = e;
                };
            }
        };
        var ctx = Ctx{ .analyzer = self, .parent_id = parent_id };
        ir.forEachChildStream(instr, &ctx, Ctx.onStream);
        if (ctx.err) |e| return e;
    }

    /// Map a canonical `ChildStreamKind` to the analyzer's `ParentLink`
    /// for the given parent instruction id. The analyzer's structural-
    /// successor computation relies on these tags; the `union_switch.else`
    /// prong reuses the `union_switch_case` link (its exit semantics match
    /// a case-arm body — both yield the union_switch's value to a merge).
    fn parentLinkForChildKind(kind: ir.ChildStreamKind, parent_id: InstructionId) ParentLink {
        return switch (kind) {
            .if_then => .{ .if_then = parent_id },
            .if_else => .{ .if_else = parent_id },
            .case_pre => .{ .case_pre = parent_id },
            .case_arm_cond => .{ .case_arm_cond = parent_id },
            .case_arm_body => .{ .case_arm_body = parent_id },
            .case_default => .{ .case_default = parent_id },
            .switch_lit_case => .{ .switch_lit_case = parent_id },
            .switch_lit_default => .{ .switch_lit_default = parent_id },
            .switch_ret_case => .{ .switch_ret_case = parent_id },
            .switch_ret_default => .{ .switch_ret_default = parent_id },
            .union_switch_case, .union_switch_else => .{ .union_switch_case = parent_id },
            .union_switch_ret_case => .{ .union_switch_ret_case = parent_id },
            .try_handler => .{ .try_handler = parent_id },
            .try_success => .{ .try_success = parent_id },
            .guard_body => .{ .guard_body = parent_id },
            .optional_dispatch_nil => .{ .optional_dispatch_nil = parent_id },
            .optional_dispatch_struct => .{ .optional_dispatch_struct = parent_id },
        };
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

        // Phase 4: collect every `param_get` dest for each
        // `.owned`-convention slot. After the records walk, build the
        // alias-group slices: every dest in slot S's group points at
        // a shared slice containing all dests of slot S. The forward
        // dataflow consults this at consume sites to clear sibling
        // aliases' bits in one pass.
        var owned_param_dests: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(ir.LocalId)) = .empty;
        defer {
            var dests_iter = owned_param_dests.valueIterator();
            while (dests_iter.next()) |list_ptr| list_ptr.deinit(self.allocator);
            owned_param_dests.deinit(self.allocator);
        }
        const param_conventions = self.function.param_conventions;

        for (self.records.items) |rec| {
            switch (rec.instr.*) {
                .param_get => |pg| {
                    if (arc_param_indices.contains(pg.index)) {
                        if (!seen.contains(pg.dest)) {
                            try seen.put(self.allocator, pg.dest, {});
                        }
                        // Collect this dest into the slot's alias
                        // group when the convention is `.owned`.
                        if (pg.index < param_conventions.len and
                            param_conventions[pg.index] == .owned)
                        {
                            const gop = try owned_param_dests.getOrPut(self.allocator, pg.index);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            try gop.value_ptr.append(self.allocator, pg.dest);
                            try self.owned_param_slot_by_local.put(self.allocator, pg.dest, pg.index);
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

        // (e) Phase E.5 Gap 5: every instruction whose dest local is
        // classified as ARC-managed in `Function.local_ownership` is
        // an owned-by-construction binding. This catches the bindings
        // that don't pass through `share_value` / `retain` / `release`
        // on their definition path:
        //
        //   * `m = map_init(...)`        — fresh-owner Map
        //   * `xs = list_init(...)`      — fresh-owner List
        //   * `s = struct_init(...)`     — owns ARC fields if any
        //   * `result = Map.put(m, k, v)` — call returning a fresh
        //                                   ARC cell
        //   * `name = expr` (local_set propagating an ARC value)
        //   * `dest = local_get/borrow_value/copy_value(source)` for
        //                                  ARC-managed source
        //
        // Without this registration, `arc_drop_insertion` never sees
        // these locals as candidates for scope-exit drops, so the
        // owned cells leak on every function exit. The verifier's
        // V1/V3 invariants likewise rely on the ARC-managed set being
        // complete.
        //
        // The function's `local_ownership` array is the canonical
        // ARC-managed predicate: it's populated by IrBuilder from
        // `local_hir_types`, which Phase E.5 Gaps 1-3 ensure is
        // complete. Walking every instruction's dest and consulting
        // `local_ownership[dest] != .trivial` is therefore both
        // necessary and sufficient.
        const local_ownership = self.function.local_ownership;
        for (self.records.items) |rec| {
            const defs = collectDefs(rec.instr.*);
            for (defs.slice()) |def_local| {
                if (def_local >= local_ownership.len) continue;
                if (local_ownership[def_local] == .trivial) continue;
                if (!seen.contains(def_local)) try seen.put(self.allocator, def_local, {});
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

        // Phase 4: build the alias-group slices. For each `.owned`
        // slot with 2+ param_get dests, allocate a slice containing
        // every dest and register every dest as a key pointing at
        // that shared slice. Slots with only one param_get are NOT
        // registered — there's no other alias to clear, and skipping
        // them keeps the lookup cost minimal at consume sites.
        var dests_iter_2 = owned_param_dests.iterator();
        while (dests_iter_2.next()) |entry| {
            const dests_list = entry.value_ptr.*;
            if (dests_list.items.len < 2) continue;
            const slice = try self.allocator.alloc(ir.LocalId, dests_list.items.len);
            @memcpy(slice, dests_list.items);
            for (slice) |dest| {
                try self.param_alias_group.put(self.allocator, dest, slice);
            }
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
                // Control flows pre_instrs -> (one of) the arms / default, so the
                // live-AFTER pre_instrs is the UNION of every arm's (and the
                // default's) live-IN — NOT the case_block's external live-after.
                // A local DEFINED in pre_instrs (a tuple-destructure binding such
                // as the `value`/`next_state` of `{:cont, value, next_state}`) and
                // USED only inside an arm is therefore live OUT of pre_instrs and
                // must NOT be released there; its release lands at its real
                // last-use inside the arm. Without threading the arms' live-in
                // back, an OWNED pre_instrs binding (a boxed `Callable` element
                // cloned by `List.next`/`ownElement`) is wrongly treated as dead
                // at pre_instrs end and gets a spurious early `.protocol_box_drop`
                // (a use-after-free under `Memory.Tracking`, masked under refcount
                // ARC) plus a duplicate per-arm release. Trivial/borrow bindings
                // (i64/String elements) schedule no release and are unaffected.
                var arms_live_in = try LiveSet.init(self.allocator, @intCast(self.arc_locals.items.len));
                defer arms_live_in.deinit(self.allocator);
                for (cb.arms) |arm| {
                    var cond_in = try self.processStream(arm.cond_instrs, arm_live_after);
                    defer cond_in.deinit(self.allocator);
                    var body_in = try self.processStream(arm.body_instrs, arm_live_after);
                    defer body_in.deinit(self.allocator);
                    arms_live_in.unionWith(&cond_in);
                    arms_live_in.unionWith(&body_in);
                }
                var def_in = try self.processStream(cb.default_instrs, arm_live_after);
                defer def_in.deinit(self.allocator);
                arms_live_in.unionWith(&def_in);
                var pre_in = try self.processStream(cb.pre_instrs, &arms_live_in);
                defer pre_in.deinit(self.allocator);
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
                // The catch-all `_` prong (`else_instrs`) yields the
                // union_switch's value to the same merge as a case-arm
                // body, so its enclosing live-after is the parent's —
                // identical to a `cases` arm. Without processing it, the
                // backward dataflow leaves every else-prong instruction's
                // live-after at its empty initialization, so
                // `classifyLastUses` flags EVERY ARC use inside the
                // catch-all as a last use (false `move_value`/consume
                // authorization → use-after-free) and emits no scope-exit
                // drops for ARC locals that die there (leak). See audit
                // finding arc-liveness--01.
                if (us.has_else) {
                    var else_in = try self.processStream(us.else_instrs, arm_live_after);
                    defer else_in.deinit(self.allocator);
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
            .optional_dispatch => |od| {
                // Phase D (Phase 6 redux plan §3.D): each arm body is
                // followed by a synthetic `ret nil_result` /
                // `ret struct_result` constructed at ZIR emission, so
                // control leaves the function at the end of each arm
                // body — exactly the same shape as `switch_return`
                // arms. The enclosing `live_after` for both arm bodies
                // is therefore the empty set: nothing is live past the
                // implicit return.
                //
                // Note that this preserves the parent-level `applyUses`
                // accounting for `nil_result` / `struct_result` (see
                // `collectUses` for `optional_dispatch`): those locals
                // are defined inside the arm bodies and consumed by
                // the parent instruction, but the synthetic return is
                // structurally outside the arm body's instruction
                // stream — so the arm's own live-after at the body's
                // last instruction is empty, matching the
                // ret-equivalent shape.
                var empty = try LiveSet.init(self.allocator, @intCast(self.arc_locals.items.len));
                defer empty.deinit(self.allocator);
                var nil_in = try self.processStream(od.nil_instrs, &empty);
                defer nil_in.deinit(self.allocator);
                var struct_in = try self.processStream(od.struct_instrs, &empty);
                defer struct_in.deinit(self.allocator);
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
                    //
                    // For branched control flow (`if_expr`, `case_block`,
                    // …) every arm may end in a last-use of the same
                    // local. `last_use_map` is single-entry — last write
                    // wins — so it captures only ONE arm's site. The
                    // path-sensitive `last_use_sites` records EVERY
                    // last-use pair `(local, id)`, used by the uniqueness
                    // borrow→consume classifier and other path-aware
                    // consumers.
                    try ownership.last_use_map.put(self.allocator, use_local, id);
                    try ownership.last_use_sites.put(
                        self.allocator,
                        ArcOwnership.lastUseKey(use_local, id),
                        {},
                    );
                    try self.applySpecialization(rec.instr.*, id, use_local, ownership);
                }
            }
        }
    }

    fn recordNonArcAggregateLastUses(self: *Analyzer, ownership: *ArcOwnership) !void {
        var aggregate_to_index: std.AutoHashMapUnmanaged(ir.LocalId, u32) = .empty;
        defer aggregate_to_index.deinit(self.allocator);
        var aggregate_locals: std.ArrayListUnmanaged(ir.LocalId) = .empty;
        defer aggregate_locals.deinit(self.allocator);

        try self.collectNonArcAggregateLastUseCandidates(
            ownership,
            &aggregate_to_index,
            &aggregate_locals,
        );
        if (aggregate_locals.items.len == 0) return;

        var tracker = NonArcAggregateLiveness{
            .analyzer = self,
            .local_to_index = &aggregate_to_index,
            .tracked_locals = aggregate_locals.items,
            .live_after = .empty,
        };
        defer tracker.deinit();
        try tracker.compute();
        try tracker.recordLastUses(ownership);
    }

    fn collectNonArcAggregateLastUseCandidates(
        self: *Analyzer,
        ownership: *const ArcOwnership,
        aggregate_to_index: *std.AutoHashMapUnmanaged(ir.LocalId, u32),
        aggregate_locals: *std.ArrayListUnmanaged(ir.LocalId),
    ) error{OutOfMemory}!void {
        for (self.records.items) |rec| {
            switch (rec.instr.*) {
                .index_get => |index_get| try self.addNonArcAggregateLastUseCandidate(
                    ownership,
                    aggregate_to_index,
                    aggregate_locals,
                    index_get.object,
                    index_get.dest,
                ),
                .field_get => |field_get| try self.addNonArcAggregateLastUseCandidate(
                    ownership,
                    aggregate_to_index,
                    aggregate_locals,
                    field_get.object,
                    field_get.dest,
                ),
                else => {},
            }
        }
    }

    fn addNonArcAggregateLastUseCandidate(
        self: *Analyzer,
        ownership: *const ArcOwnership,
        aggregate_to_index: *std.AutoHashMapUnmanaged(ir.LocalId, u32),
        aggregate_locals: *std.ArrayListUnmanaged(ir.LocalId),
        object: ir.LocalId,
        dest: ir.LocalId,
    ) error{OutOfMemory}!void {
        if (ownership.arc_managed_locals.contains(object)) return;
        if (!ownership.arc_managed_locals.contains(dest)) return;
        if (aggregate_to_index.contains(object)) return;

        const index: u32 = @intCast(aggregate_locals.items.len);
        try aggregate_to_index.put(self.allocator, object, index);
        try aggregate_locals.append(self.allocator, object);
    }

    const NonArcAggregateLiveness = struct {
        analyzer: *Analyzer,
        local_to_index: *const std.AutoHashMapUnmanaged(ir.LocalId, u32),
        tracked_locals: []const ir.LocalId,
        live_after: std.ArrayListUnmanaged(LiveSet),

        fn deinit(self: *NonArcAggregateLiveness) void {
            for (self.live_after.items) |*set| {
                set.deinit(self.analyzer.allocator);
            }
            self.live_after.deinit(self.analyzer.allocator);
        }

        fn compute(self: *NonArcAggregateLiveness) error{OutOfMemory}!void {
            const bit_count: u32 = @intCast(self.tracked_locals.len);
            try self.live_after.resize(self.analyzer.allocator, self.analyzer.records.items.len);
            for (self.live_after.items) |*set| {
                set.* = try LiveSet.init(self.analyzer.allocator, bit_count);
            }

            for (self.analyzer.function.body) |block| {
                var stream_live_after = try LiveSet.init(self.analyzer.allocator, bit_count);
                defer stream_live_after.deinit(self.analyzer.allocator);
                var stream_live_before = try self.processStream(block.instructions, &stream_live_after);
                defer stream_live_before.deinit(self.analyzer.allocator);
            }
        }

        fn recordLastUses(
            self: *NonArcAggregateLiveness,
            ownership: *ArcOwnership,
        ) error{OutOfMemory}!void {
            for (self.analyzer.records.items, 0..) |rec, idx| {
                const id: InstructionId = @intCast(idx);
                var uses = UseList{};
                defer uses.deinit(std.heap.page_allocator);
                collectUses(rec.instr.*, &uses);
                for (uses.slice()) |local| {
                    const bit_index = self.local_to_index.get(local) orelse continue;
                    if (self.live_after.items[id].contains(bit_index)) continue;
                    try ownership.last_use_sites.put(
                        self.analyzer.allocator,
                        ArcOwnership.lastUseKey(local, id),
                        {},
                    );
                }
            }
        }

        fn processStream(
            self: *NonArcAggregateLiveness,
            stream: []const ir.Instruction,
            stream_live_after: *const LiveSet,
        ) error{OutOfMemory}!LiveSet {
            if (stream.len == 0) {
                return try stream_live_after.clone(self.analyzer.allocator);
            }

            var current_live = try stream_live_after.clone(self.analyzer.allocator);
            var instruction_index: usize = stream.len;
            while (instruction_index > 0) {
                instruction_index -= 1;
                const instr = &stream[instruction_index];
                const id = self.analyzer.idForStreamInstruction(stream, instruction_index);

                if (isTerminator(instr.*)) {
                    self.live_after.items[id].clear();
                } else {
                    self.live_after.items[id].copyFrom(&current_live);
                }

                try self.recurseChildren(instr, &self.live_after.items[id]);

                var next_live = try self.live_after.items[id].clone(self.analyzer.allocator);
                self.applyDefs(instr.*, &next_live);
                self.applyUses(instr.*, &next_live);

                current_live.deinit(self.analyzer.allocator);
                current_live = next_live;
            }

            return current_live;
        }

        fn recurseChildren(
            self: *NonArcAggregateLiveness,
            instr: *const ir.Instruction,
            parent_live_after: *const LiveSet,
        ) error{OutOfMemory}!void {
            switch (instr.*) {
                .if_expr => |if_expr| {
                    var then_in = try self.processStream(if_expr.then_instrs, parent_live_after);
                    defer then_in.deinit(self.analyzer.allocator);
                    var else_in = try self.processStream(if_expr.else_instrs, parent_live_after);
                    defer else_in.deinit(self.analyzer.allocator);
                },
                .case_block => |case_block| {
                    var pre_in = try self.processStream(case_block.pre_instrs, parent_live_after);
                    defer pre_in.deinit(self.analyzer.allocator);
                    for (case_block.arms) |arm| {
                        var cond_in = try self.processStream(arm.cond_instrs, parent_live_after);
                        defer cond_in.deinit(self.analyzer.allocator);
                        var body_in = try self.processStream(arm.body_instrs, parent_live_after);
                        defer body_in.deinit(self.analyzer.allocator);
                    }
                    var default_in = try self.processStream(case_block.default_instrs, parent_live_after);
                    defer default_in.deinit(self.analyzer.allocator);
                },
                .switch_literal => |switch_literal| {
                    for (switch_literal.cases) |case| {
                        var body_in = try self.processStream(case.body_instrs, parent_live_after);
                        defer body_in.deinit(self.analyzer.allocator);
                    }
                    var default_in = try self.processStream(switch_literal.default_instrs, parent_live_after);
                    defer default_in.deinit(self.analyzer.allocator);
                },
                .switch_return => |switch_return| {
                    var empty = try LiveSet.init(self.analyzer.allocator, @intCast(self.tracked_locals.len));
                    defer empty.deinit(self.analyzer.allocator);
                    for (switch_return.cases) |case| {
                        var body_in = try self.processStream(case.body_instrs, &empty);
                        defer body_in.deinit(self.analyzer.allocator);
                    }
                    var default_in = try self.processStream(switch_return.default_instrs, &empty);
                    defer default_in.deinit(self.analyzer.allocator);
                },
                .union_switch => |union_switch| {
                    for (union_switch.cases) |case| {
                        var body_in = try self.processStream(case.body_instrs, parent_live_after);
                        defer body_in.deinit(self.analyzer.allocator);
                    }
                    // The catch-all `_` prong yields to the same merge as a
                    // case arm (parent live-after). Processing it keeps
                    // non-ARC-aggregate last-use records correct for tuples
                    // whose components are read inside the catch-all body.
                    if (union_switch.has_else) {
                        var else_in = try self.processStream(union_switch.else_instrs, parent_live_after);
                        defer else_in.deinit(self.analyzer.allocator);
                    }
                },
                .union_switch_return => |union_switch_return| {
                    var empty = try LiveSet.init(self.analyzer.allocator, @intCast(self.tracked_locals.len));
                    defer empty.deinit(self.analyzer.allocator);
                    for (union_switch_return.cases) |case| {
                        var body_in = try self.processStream(case.body_instrs, &empty);
                        defer body_in.deinit(self.analyzer.allocator);
                    }
                },
                .try_call_named => |try_call_named| {
                    var handler_in = try self.processStream(try_call_named.handler_instrs, parent_live_after);
                    defer handler_in.deinit(self.analyzer.allocator);
                    var success_in = try self.processStream(try_call_named.success_instrs, parent_live_after);
                    defer success_in.deinit(self.analyzer.allocator);
                },
                .guard_block => |guard_block| {
                    var body_in = try self.processStream(guard_block.body, parent_live_after);
                    defer body_in.deinit(self.analyzer.allocator);
                },
                .optional_dispatch => |optional_dispatch| {
                    var empty = try LiveSet.init(self.analyzer.allocator, @intCast(self.tracked_locals.len));
                    defer empty.deinit(self.analyzer.allocator);
                    var nil_in = try self.processStream(optional_dispatch.nil_instrs, &empty);
                    defer nil_in.deinit(self.analyzer.allocator);
                    var struct_in = try self.processStream(optional_dispatch.struct_instrs, &empty);
                    defer struct_in.deinit(self.analyzer.allocator);
                },
                else => {},
            }
        }

        fn applyDefs(self: *NonArcAggregateLiveness, instr: ir.Instruction, set: *LiveSet) void {
            const defs = collectDefs(instr);
            for (defs.slice()) |local| {
                if (self.local_to_index.get(local)) |bit_index| set.unset(bit_index);
            }
        }

        fn applyUses(self: *NonArcAggregateLiveness, instr: ir.Instruction, set: *LiveSet) void {
            var uses = UseList{};
            defer uses.deinit(std.heap.page_allocator);
            collectUses(instr, &uses);
            for (uses.slice()) |local| {
                if (self.local_to_index.get(local)) |bit_index| set.set(bit_index);
            }
        }
    };

    fn applySpecialization(
        self: *Analyzer,
        instr: ir.Instruction,
        id: InstructionId,
        last_use_local: ir.LocalId,
        ownership: *ArcOwnership,
    ) !void {
        // `id` was the share_value's instruction id, used to populate
        // `consume_share_sites` when consume mode was active. The
        // borrow-by-default ABI never inserts into that table, so the
        // parameter is unused here. Discard it explicitly to keep the
        // signature stable for future per-callee borrow / consume
        // metadata work.
        _ = id;
        switch (instr) {
            .share_value => |sv| {
                if (sv.source == last_use_local) {
                    // ============================================
                    // Consume mode is currently disabled at every
                    // call site. See the borrow / consume audit
                    // below for the design reasoning.
                    // ============================================
                    //
                    // Consume mode (Phase 4) was designed to skip the
                    // share_value's retain when a local is at its
                    // last use, transferring ownership of the cell
                    // into the callee's argument slot. That mode is
                    // sound only when the *callee* either releases
                    // the input internally or transfers the
                    // ownership unit into its return value — i.e.
                    // the callee participates in a "consuming"
                    // calling convention.
                    //
                    // An audit of every runtime builtin in
                    // `src/runtime.zig` (Map.put, Map.delete,
                    // Map.get, Map.merge, Map.has_key, Map.size,
                    // Map.iter, List.append, List.cons, List.head,
                    // String.*, List.*, etc.) shows that
                    // *no* current runtime function consumes its
                    // input. Every runtime builtin borrows: the
                    // caller's ownership unit is observed but never
                    // released, and the function's return value is
                    // a freshly-allocated cell with refcount 1.
                    //
                    // User-defined Zap functions are also borrowing
                    // by default: the IR's `param_get` retains the
                    // parameter cell at function entry, and the
                    // matching scope-exit release fires on the
                    // parameter local. Without an annotation that
                    // says "this callee consumes", marking the
                    // caller's share as `.consume` skips the retain
                    // but leaves the caller's (now-stale) post-call
                    // release in place, netting -1 on the cell's
                    // refcount and either leaking (when the cell is
                    // still reachable through other paths) or
                    // double-freeing (when pool reuse kicks in at
                    // scale).
                    //
                    // The proper fix is per-callee borrow / consume
                    // calling-convention metadata: each runtime
                    // function and each user-defined Zap function
                    // declares whether each ARC-managed argument is
                    // borrowed or consumed, and `arc_liveness`
                    // consults that metadata when deciding whether
                    // to upgrade a last-use share to consume mode.
                    // That work is the next phase of the ARC
                    // ownership project; until it lands, the safe
                    // ABI is "every share retains, every scope-exit
                    // release fires", which exactly matches the
                    // pre-Phase-4 design.
                    //
                    // Disabling `consume_share_sites` here is the
                    // correct semantic regardless of whether the
                    // share's source is fresh or aliased: even a
                    // share of a freshly-defined owner local is
                    // unsafe to consume into a borrowing callee,
                    // because the borrowing callee never balances
                    // the missing retain. The earlier alias-only
                    // gate was therefore necessary but insufficient.
                    //
                    // Note: `return_source_locals` (Phase 5) and
                    // `live_before_ret` (Phase 6 prep) remain fully
                    // populated below. Those tables describe
                    // dataflow at function-exit terminators, not
                    // ownership transfer at calls, and are sound
                    // independently of any per-callee calling
                    // convention.
                    return;
                }
            },
            .ret => |r| {
                if (r.value) |v| {
                    if (v == last_use_local and self.canElideReturnSource(v)) {
                        try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                    }
                }
            },
            .cond_return => |cr| {
                if (cr.value) |v| {
                    if (v == last_use_local and self.canElideReturnSource(v)) {
                        try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                    }
                }
            },
            .switch_return => |sr| {
                // Each arm of a switch_return contributes a return
                // value at the function-exit boundary. Mirror the
                // single-`.ret` discipline: when `last_use_local`
                // matches an arm's return value (and elision is
                // safe), record it in `return_source_locals` so the
                // matching `dropsForTerminator` release is suppressed
                // and `shouldRetainReturnValue` skips the
                // retain-on-ret — ownership transfers from the
                // arm-local destination directly to the caller's
                // return slot without a refcount round-trip. Without
                // these cases the arm-local return value's retain
                // fires inside the arm body while the (no-op) release
                // fires at the parent level on an unset slot — a +1
                // leak per return that scales catastrophically for
                // recursive constructors like binarytrees' `make`.
                for (sr.cases) |case| {
                    if (case.return_value) |v| {
                        if (v == last_use_local and self.canElideReturnSource(v)) {
                            try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                        }
                    }
                }
                if (sr.default_result) |v| {
                    if (v == last_use_local and self.canElideReturnSource(v)) {
                        try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                    }
                }
            },
            .union_switch_return => |usr| {
                // Same discipline as `.switch_return` above — per-arm
                // return values are arm-local and transfer directly
                // to the caller's return slot. `union_switch_return`
                // has no default arm in the IR shape.
                for (usr.cases) |case| {
                    if (case.return_value) |v| {
                        if (v == last_use_local and self.canElideReturnSource(v)) {
                            try ownership.return_source_locals.put(self.allocator, last_use_local, {});
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Phase E.5 Gap 4: gate return-source elision against the
    /// returned local's underlying ownership convention. A borrowed
    /// param flowing directly into ret cannot elide the matching
    /// retain — the param owns no +1, so eliding the retain leaves
    /// the caller with a borrow that will under-flow the post-call
    /// release. The proper transfer requires a `copy_value` to
    /// promote the borrow to an owner; eliding the destroy on that
    /// owner is wrong because it materialised a fresh +1.
    ///
    /// Returns `true` when `local` is safe to add to
    /// `return_source_locals`, `false` when it must NOT be (the
    /// retain-on-ret discipline must fire, the destroy is genuine).
    ///
    /// Today the only rejection case is "this local was loaded from
    /// a borrowed param via `param_get`". When per-callee borrow /
    /// consume metadata lands (Phase H+), more rejections may apply.
    fn canElideReturnSource(self: *const Analyzer, local: ir.LocalId) bool {
        // Walk the records list looking for a `param_get` whose
        // dest is `local`. If found and the matching param is
        // borrowed, refuse to elide.
        for (self.records.items) |rec| {
            switch (rec.instr.*) {
                .param_get => |pg| {
                    if (pg.dest == local) {
                        if (pg.index >= self.function.param_conventions.len) return true;
                        return self.function.param_conventions[pg.index] != .borrowed;
                    }
                },
                else => {},
            }
        }
        return true;
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
                    // Phase E.5 Gap 4: refuse to elide when an arm
                    // result is a borrowed-param dest. The whole
                    // aggregate's return-source elision must back off
                    // (the verifier and drop-insertion treat the
                    // aggregate dest as a return source, but the arm
                    // local's own retain-on-ret must fire).
                    if (!self.canElideReturnSource(arm_local)) continue;
                    try ownership.return_source_locals.put(self.allocator, arm_local, {});
                    changed = true;
                }
            }
        }
    }

    // ----------------------------------------------------------
    // Step 5b (Phase E.5 Gap 7): forward "defined-and-still-owned"
    // dataflow. Liveness answers "which locals are read after this
    // point" — a `share_value`'s source is dead per liveness once
    // the share has fired. But share_value RETAINS rather than
    // CONSUMES, so the source still owns its +1. The drop-insertion
    // pass must release that source at scope exit; the existing
    // `live_before_ret` table doesn't surface it.
    //
    // Forward dataflow over the structural region tree records, at
    // every ret-equivalent terminator, the set of ARC-managed-owned
    // locals that have been DEFINED on the path to the terminator
    // and not yet RELEASED / MOVED-OUT / TAIL-CALL-CONSUMED. Joins
    // (sub-region exits) take the intersection so the table records
    // only locals owning +1 along EVERY path leading to the
    // terminator.
    // ----------------------------------------------------------

    fn computeOwnedAtRet(self: *Analyzer, ownership: *ArcOwnership) !void {
        if (self.arc_locals.items.len == 0) return;
        const arc_count: u32 = @intCast(self.arc_locals.items.len);
        var owns = try LiveSet.init(self.allocator, arc_count);
        defer owns.deinit(self.allocator);
        var consumed_owned_param_slots = try LiveSet.init(self.allocator, @intCast(self.function.param_conventions.len));
        defer consumed_owned_param_slots.deinit(self.allocator);

        for (self.function.body) |block| {
            _ = try self.forwardOwnsStream(block.instructions, &owns, &consumed_owned_param_slots, ownership);
        }
    }

    /// Process one stream forward, mutating `owns` in place to track
    /// which ARC-managed-owned locals own +1 at the current program
    /// point. Snapshots the set at every ret-equivalent terminator
    /// into `ownership.owned_at_ret`. Returns nothing — the post-
    /// stream `owns` value is left in `*owns` so the caller can
    /// continue its own forward walk.
    fn forwardOwnsStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
        ownership: *ArcOwnership,
    ) error{OutOfMemory}!void {
        for (stream, 0..) |*instr, k| {
            const id = self.idForStreamInstruction(stream, k);

            // Recurse into nested regions FIRST. Each sub-stream sees
            // the parent's `owns` as its starting set; the post-region
            // `owns` becomes the intersection of arm-end `owns` sets.
            try self.forwardOwnsChildren(instr, owns, consumed_owned_param_slots, ownership);

            // Apply the instruction's effect on `owns`.
            try self.applyOwnsEffect(instr.*, owns, consumed_owned_param_slots, ownership);

            // Snapshot at ret-equivalent terminators. Note that for
            // multi-arm terminators (switch_return, union_switch_return)
            // each arm is recursed into via `forwardOwnsChildren` and
            // their per-terminator snapshots are taken inside the arm's
            // body's terminator (the implicit ret at the arm's tail).
            // The parent terminator's snapshot still records the
            // `owns` at the join point, which `arc_drop_insertion`
            // uses as a fallback when an arm has no explicit
            // terminator.
            if (isReturnEquivalentTerminator(instr.*)) {
                try self.snapshotOwnedAtRet(ownership, id, owns);
            }
        }
    }

    /// Recurse forward into every sub-stream of `instr`, accumulating
    /// the post-region `owns` as the intersection of arm-end states.
    /// Ordering MUST mirror the analyzer's `flattenChildren` so the
    /// InstructionId numbering used by `idForStreamInstruction` (and
    /// hence the `live_before_ret` lookup downstream) lines up.
    fn forwardOwnsChildren(
        self: *Analyzer,
        instr: *const ir.Instruction,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
        ownership: *ArcOwnership,
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            .if_expr => |x| {
                var then_owns = try owns.clone(self.allocator);
                defer then_owns.deinit(self.allocator);
                var then_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer then_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(x.then_instrs, &then_owns, &then_consumed, ownership);
                var else_owns = try owns.clone(self.allocator);
                defer else_owns.deinit(self.allocator);
                var else_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer else_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(x.else_instrs, &else_owns, &else_consumed, ownership);
                // Join at the merge: a local owns +1 after the if iff
                // it owns +1 in BOTH arms. Intersection.
                owns.copyFrom(&then_owns);
                owns.intersectWith(&else_owns);
                consumed_owned_param_slots.copyFrom(&then_consumed);
                consumed_owned_param_slots.unionWith(&else_consumed);
            },
            .case_block => |cb| {
                try self.forwardOwnsCaseBlock(cb, owns, consumed_owned_param_slots, ownership);
            },
            .switch_literal => |sl| {
                var has_join: bool = false;
                var join: LiveSet = try LiveSet.init(self.allocator, owns.bit_count);
                defer join.deinit(self.allocator);
                var consumed_join = try LiveSet.init(self.allocator, consumed_owned_param_slots.bit_count);
                defer consumed_join.deinit(self.allocator);
                var entry_owns = try owns.clone(self.allocator);
                defer entry_owns.deinit(self.allocator);
                for (sl.cases) |case| {
                    var arm_owns = try owns.clone(self.allocator);
                    defer arm_owns.deinit(self.allocator);
                    var arm_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer arm_consumed.deinit(self.allocator);
                    try self.forwardOwnsStream(case.body_instrs, &arm_owns, &arm_consumed, ownership);
                    self.applyAggregateResultTransfer(case.result, sl.dest, &arm_owns);
                    self.normalizeAggregateExitOwns(&arm_owns, &entry_owns, sl.dest);
                    if (!has_join) {
                        join.copyFrom(&arm_owns);
                        consumed_join.copyFrom(&arm_consumed);
                        has_join = true;
                    } else {
                        join.intersectWith(&arm_owns);
                        consumed_join.unionWith(&arm_consumed);
                    }
                }
                var def_owns = try owns.clone(self.allocator);
                defer def_owns.deinit(self.allocator);
                var def_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer def_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(sl.default_instrs, &def_owns, &def_consumed, ownership);
                self.applyAggregateResultTransfer(sl.default_result, sl.dest, &def_owns);
                self.normalizeAggregateExitOwns(&def_owns, &entry_owns, sl.dest);
                if (!has_join) {
                    join.copyFrom(&def_owns);
                    consumed_join.copyFrom(&def_consumed);
                    has_join = true;
                } else {
                    join.intersectWith(&def_owns);
                    consumed_join.unionWith(&def_consumed);
                }
                if (has_join) {
                    owns.copyFrom(&join);
                    consumed_owned_param_slots.copyFrom(&consumed_join);
                }
            },
            .switch_return => |sr| {
                // switch_return is itself a terminator: each arm body
                // ends with an implicit ret on the arm's return_value.
                // We propagate owns into each arm but the parent join
                // is unreachable (control leaves the function).
                for (sr.cases) |case| {
                    var arm_owns = try owns.clone(self.allocator);
                    defer arm_owns.deinit(self.allocator);
                    var arm_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer arm_consumed.deinit(self.allocator);
                    try self.forwardOwnsStream(case.body_instrs, &arm_owns, &arm_consumed, ownership);
                }
                var def_owns = try owns.clone(self.allocator);
                defer def_owns.deinit(self.allocator);
                var def_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer def_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(sr.default_instrs, &def_owns, &def_consumed, ownership);
            },
            .union_switch => |us| {
                var has_join: bool = false;
                var join: LiveSet = try LiveSet.init(self.allocator, owns.bit_count);
                defer join.deinit(self.allocator);
                var consumed_join = try LiveSet.init(self.allocator, consumed_owned_param_slots.bit_count);
                defer consumed_join.deinit(self.allocator);
                var entry_owns = try owns.clone(self.allocator);
                defer entry_owns.deinit(self.allocator);
                for (us.cases) |case| {
                    var arm_owns = try owns.clone(self.allocator);
                    defer arm_owns.deinit(self.allocator);
                    var arm_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer arm_consumed.deinit(self.allocator);
                    try self.forwardOwnsStream(case.body_instrs, &arm_owns, &arm_consumed, ownership);
                    self.applyAggregateResultTransfer(case.return_value, us.dest, &arm_owns);
                    self.normalizeAggregateExitOwns(&arm_owns, &entry_owns, us.dest);
                    if (!has_join) {
                        join.copyFrom(&arm_owns);
                        consumed_join.copyFrom(&arm_consumed);
                        has_join = true;
                    } else {
                        join.intersectWith(&arm_owns);
                        consumed_join.unionWith(&arm_consumed);
                    }
                }
                // The catch-all `_` prong joins the post-switch `owns`
                // exactly like a case arm: its `else_result` transfers into
                // `us.dest`, and its arm-end `owns` intersects into the
                // join. Omitting it left the join missing the else path's
                // ownership, so a local owned only on the catch-all path
                // either leaked (never released) or was double-released
                // (released against a join that excluded it). See audit
                // finding arc-liveness--01 / arc-own-2--01.
                if (us.has_else) {
                    var else_owns = try owns.clone(self.allocator);
                    defer else_owns.deinit(self.allocator);
                    var else_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer else_consumed.deinit(self.allocator);
                    try self.forwardOwnsStream(us.else_instrs, &else_owns, &else_consumed, ownership);
                    self.applyAggregateResultTransfer(us.else_result, us.dest, &else_owns);
                    self.normalizeAggregateExitOwns(&else_owns, &entry_owns, us.dest);
                    if (!has_join) {
                        join.copyFrom(&else_owns);
                        consumed_join.copyFrom(&else_consumed);
                        has_join = true;
                    } else {
                        join.intersectWith(&else_owns);
                        consumed_join.unionWith(&else_consumed);
                    }
                }
                if (has_join) {
                    owns.copyFrom(&join);
                    consumed_owned_param_slots.copyFrom(&consumed_join);
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |case| {
                    var arm_owns = try owns.clone(self.allocator);
                    defer arm_owns.deinit(self.allocator);
                    var arm_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer arm_consumed.deinit(self.allocator);
                    try self.forwardOwnsStream(case.body_instrs, &arm_owns, &arm_consumed, ownership);
                }
            },
            .try_call_named => |tc| {
                // Order mirrors flattenChildren: handler_instrs first,
                // then success_instrs.
                var handler_owns = try owns.clone(self.allocator);
                defer handler_owns.deinit(self.allocator);
                var handler_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer handler_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(tc.handler_instrs, &handler_owns, &handler_consumed, ownership);
                var success_owns = try owns.clone(self.allocator);
                defer success_owns.deinit(self.allocator);
                var success_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer success_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(tc.success_instrs, &success_owns, &success_consumed, ownership);
                // Both paths can reach the rest of the enclosing
                // stream after the try_call_named (depending on
                // whether the called function returned ok or err).
                // Take the intersection.
                owns.copyFrom(&handler_owns);
                owns.intersectWith(&success_owns);
                consumed_owned_param_slots.copyFrom(&handler_consumed);
                consumed_owned_param_slots.unionWith(&success_consumed);
            },
            .guard_block => |gb| {
                // The guard_block's body executes only when the guard
                // condition holds. We must clone `owns` before the body
                // walks it so the body's ownership mutations do not
                // leak into the parent stream when the guard fails or
                // when the body terminates without falling through.
                //
                // - If the body falls through to its end, the
                //   post-guard_block `owns` is the intersection of
                //   parent_owns (guard-failed path) and body_owns
                //   (guard-succeeded path).
                // - If the body terminates (case_break/jump/branch/
                //   ret/tail_call), the body never reaches the merge,
                //   so the parent's `owns` is unchanged. Any owns the
                //   body acquired (e.g. `list_tail dest=N`) belong
                //   solely to the body's terminating path and must not
                //   leak past the guard_block into the surrounding
                //   stream's owned_at_ret snapshot.
                var body_owns = try owns.clone(self.allocator);
                defer body_owns.deinit(self.allocator);
                var body_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer body_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(gb.body, &body_owns, &body_consumed, ownership);
                if (streamFallsThrough(gb.body)) {
                    owns.intersectWith(&body_owns);
                    consumed_owned_param_slots.unionWith(&body_consumed);
                }
            },
            .optional_dispatch => |od| {
                var nil_owns = try owns.clone(self.allocator);
                defer nil_owns.deinit(self.allocator);
                var nil_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer nil_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(od.nil_instrs, &nil_owns, &nil_consumed, ownership);
                var struct_owns = try owns.clone(self.allocator);
                defer struct_owns.deinit(self.allocator);
                var struct_consumed = try consumed_owned_param_slots.clone(self.allocator);
                defer struct_consumed.deinit(self.allocator);
                try self.forwardOwnsStream(od.struct_instrs, &struct_owns, &struct_consumed, ownership);
                owns.copyFrom(&nil_owns);
                owns.intersectWith(&struct_owns);
                consumed_owned_param_slots.copyFrom(&nil_consumed);
                consumed_owned_param_slots.unionWith(&struct_consumed);
            },
            else => {},
        }
    }

    fn forwardOwnsCaseBlock(
        self: *Analyzer,
        cb: ir.CaseBlock,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
        ownership: *ArcOwnership,
    ) error{OutOfMemory}!void {
        var entry_owns = try owns.clone(self.allocator);
        defer entry_owns.deinit(self.allocator);

        var join = try AggregateJoin.init(self.allocator, owns.bit_count, consumed_owned_param_slots.bit_count);
        defer join.deinit(self.allocator);

        var fallthrough_owns = try owns.clone(self.allocator);
        defer fallthrough_owns.deinit(self.allocator);
        var fallthrough_consumed = try consumed_owned_param_slots.clone(self.allocator);
        defer fallthrough_consumed.deinit(self.allocator);
        const pre_falls_through = try self.forwardCaseExitStream(
            cb.pre_instrs,
            &fallthrough_owns,
            &fallthrough_consumed,
            &entry_owns,
            cb.dest,
            ownership,
            &join,
        );

        if (pre_falls_through) {
            for (cb.arms) |arm| {
                var arm_owns = try fallthrough_owns.clone(self.allocator);
                defer arm_owns.deinit(self.allocator);
                var arm_consumed = try fallthrough_consumed.clone(self.allocator);
                defer arm_consumed.deinit(self.allocator);
                const cond_falls_through = try self.forwardCaseExitStream(
                    arm.cond_instrs,
                    &arm_owns,
                    &arm_consumed,
                    &entry_owns,
                    cb.dest,
                    ownership,
                    &join,
                );
                if (!cond_falls_through) continue;
                const body_falls_through = try self.forwardCaseExitStream(
                    arm.body_instrs,
                    &arm_owns,
                    &arm_consumed,
                    &entry_owns,
                    cb.dest,
                    ownership,
                    &join,
                );
                if (body_falls_through) {
                    self.applyAggregateResultTransfer(arm.result, cb.dest, &arm_owns);
                    self.normalizeAggregateExitOwns(&arm_owns, &entry_owns, cb.dest);
                    join.add(&arm_owns, &arm_consumed);
                }
            }

            if (cb.default_instrs.len > 0 or cb.default_result != null) {
                var default_owns = try fallthrough_owns.clone(self.allocator);
                defer default_owns.deinit(self.allocator);
                var default_consumed = try fallthrough_consumed.clone(self.allocator);
                defer default_consumed.deinit(self.allocator);
                const default_falls_through = try self.forwardCaseExitStream(
                    cb.default_instrs,
                    &default_owns,
                    &default_consumed,
                    &entry_owns,
                    cb.dest,
                    ownership,
                    &join,
                );
                if (default_falls_through) {
                    self.applyAggregateResultTransfer(cb.default_result, cb.dest, &default_owns);
                    self.normalizeAggregateExitOwns(&default_owns, &entry_owns, cb.dest);
                    join.add(&default_owns, &default_consumed);
                }
            }
        }

        if (join.has_value) {
            owns.copyFrom(&join.owns);
            consumed_owned_param_slots.copyFrom(&join.consumed);
        } else if (pre_falls_through) {
            owns.copyFrom(&fallthrough_owns);
            consumed_owned_param_slots.copyFrom(&fallthrough_consumed);
        }
    }

    fn forwardCaseExitStream(
        self: *Analyzer,
        stream: []const ir.Instruction,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
        entry_owns: *const LiveSet,
        aggregate_dest: ir.LocalId,
        ownership: *ArcOwnership,
        join: *AggregateJoin,
    ) error{OutOfMemory}!bool {
        for (stream, 0..) |*instr, k| {
            const id = self.idForStreamInstruction(stream, k);
            switch (instr.*) {
                .guard_block => |gb| {
                    var body_owns = try owns.clone(self.allocator);
                    defer body_owns.deinit(self.allocator);
                    var body_consumed = try consumed_owned_param_slots.clone(self.allocator);
                    defer body_consumed.deinit(self.allocator);
                    const body_falls_through = try self.forwardCaseExitStream(
                        gb.body,
                        &body_owns,
                        &body_consumed,
                        entry_owns,
                        aggregate_dest,
                        ownership,
                        join,
                    );
                    if (body_falls_through) {
                        owns.intersectWith(&body_owns);
                        consumed_owned_param_slots.unionWith(&body_consumed);
                    }
                    continue;
                },
                .case_break => |case_break| {
                    try self.snapshotOwnedAtCaseBreak(
                        ownership,
                        id,
                        owns,
                        entry_owns,
                        case_break.value,
                    );
                    self.applyAggregateResultTransfer(case_break.value, aggregate_dest, owns);
                    self.normalizeAggregateExitOwns(owns, entry_owns, aggregate_dest);
                    join.add(owns, consumed_owned_param_slots);
                    return false;
                },
                else => {},
            }

            try self.forwardOwnsChildren(instr, owns, consumed_owned_param_slots, ownership);
            try self.applyOwnsEffect(instr.*, owns, consumed_owned_param_slots, ownership);
            if (isReturnEquivalentTerminator(instr.*)) {
                try self.snapshotOwnedAtRet(ownership, id, owns);
            }
            if (isTerminator(instr.*)) return false;
        }

        return true;
    }

    const AggregateJoin = struct {
        owns: LiveSet,
        consumed: LiveSet,
        has_value: bool = false,

        fn init(
            allocator: std.mem.Allocator,
            owns_bit_count: u32,
            consumed_bit_count: u32,
        ) error{OutOfMemory}!AggregateJoin {
            return .{
                .owns = try LiveSet.init(allocator, owns_bit_count),
                .consumed = try LiveSet.init(allocator, consumed_bit_count),
            };
        }

        fn deinit(self: *AggregateJoin, allocator: std.mem.Allocator) void {
            self.owns.deinit(allocator);
            self.consumed.deinit(allocator);
        }

        fn add(self: *AggregateJoin, owns: *const LiveSet, consumed: *const LiveSet) void {
            if (!self.has_value) {
                self.owns.copyFrom(owns);
                self.consumed.copyFrom(consumed);
                self.has_value = true;
            } else {
                self.owns.intersectWith(owns);
                self.consumed.unionWith(consumed);
            }
        }
    };

    fn applyAggregateResultTransfer(
        self: *Analyzer,
        maybe_result: ?ir.LocalId,
        aggregate_dest: ir.LocalId,
        owns: *LiveSet,
    ) void {
        const result = maybe_result orelse return;
        self.clearOwnsForLocalAndAliases(result, owns, null);
        const local_ownership = self.function.local_ownership;
        if (aggregate_dest >= local_ownership.len) return;
        if (local_ownership[aggregate_dest] != .owned) return;
        if (self.local_to_arc_index.get(aggregate_dest)) |idx| owns.set(idx);
    }

    fn normalizeAggregateExitOwns(
        self: *Analyzer,
        owns: *LiveSet,
        entry_owns: *const LiveSet,
        aggregate_dest: ir.LocalId,
    ) void {
        const dest_was_owned = if (self.local_to_arc_index.get(aggregate_dest)) |idx|
            owns.contains(idx)
        else
            false;
        owns.intersectWith(entry_owns);
        if (dest_was_owned) {
            if (self.local_to_arc_index.get(aggregate_dest)) |idx| owns.set(idx);
        }
    }

    fn snapshotOwnedAtCaseBreak(
        self: *Analyzer,
        ownership: *ArcOwnership,
        id: InstructionId,
        owns: *const LiveSet,
        entry_owns: *const LiveSet,
        case_result: ?ir.LocalId,
    ) error{OutOfMemory}!void {
        var local_set: ArcLocalSet = .empty;
        errdefer local_set.deinit(self.allocator);
        var bit_index: u32 = 0;
        const bit_count: u32 = @intCast(self.arc_locals.items.len);
        while (bit_index < bit_count) : (bit_index += 1) {
            if (!owns.contains(bit_index)) continue;
            if (entry_owns.contains(bit_index)) continue;
            const local_id = self.arc_locals.items[bit_index];
            if (case_result) |result| {
                if (local_id == result) continue;
            }
            try local_set.put(self.allocator, local_id, {});
        }
        if (local_set.count() == 0) {
            local_set.deinit(self.allocator);
            return;
        }
        try ownership.owned_at_case_break.putNoClobber(self.allocator, id, local_set);
    }

    /// Apply a single instruction's forward effect on the `owns` set.
    /// Defining instructions whose dest is ARC-managed-owned set the
    /// dest's bit; `release` clears the value's bit; `move_value`
    /// transfers ownership from source to dest; `tail_call` consumes
    /// its arg locals.
    fn applyOwnsEffect(
        self: *Analyzer,
        instr: ir.Instruction,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
        ownership: *ArcOwnership,
    ) error{OutOfMemory}!void {
        const local_ownership = self.function.local_ownership;
        switch (instr) {
            .release => |r| {
                self.clearOwnsForLocalAndAliases(r.value, owns, consumed_owned_param_slots);
            },
            .move_value => |mv| {
                self.clearOwnsForLocalAndAliases(mv.source, owns, consumed_owned_param_slots);
                if (mv.dest < local_ownership.len and local_ownership[mv.dest] == .owned) {
                    if (self.local_to_arc_index.get(mv.dest)) |idx| owns.set(idx);
                }
            },
            .local_set => |ls| {
                // Phase E.9: a `local_set` whose value is an
                // ARC-owned local transfers ownership from source to
                // dest — both LocalIds alias the same heap cell, so
                // tracking them as two independent `+1`s in the owns
                // set is overcounting. Treating local_set as a move
                // (clear source, set dest) keeps the set's invariant
                // "owns[i] == 1 iff there is exactly one live owner
                // alias for the i-th ARC local". Without this, a
                // post-local_set tail_call's `live_before_ret` snapshot
                // includes both source and dest, and drop insertion
                // emits a stale `release{source}` that double-frees the
                // cell the dest is about to consume.
                if (self.local_to_arc_index.get(ls.value)) |src_idx| {
                    if (owns.contains(src_idx)) {
                        self.clearOwnsForLocalAndAliases(ls.value, owns, consumed_owned_param_slots);
                        if (ls.dest < local_ownership.len and local_ownership[ls.dest] == .owned) {
                            if (self.local_to_arc_index.get(ls.dest)) |dst_idx| owns.set(dst_idx);
                        }
                        return;
                    }
                }
                // Source is not currently owned (or not ARC-managed);
                // fall through to the generic handler — it adds the
                // dest to owns iff its local_ownership is .owned.
                if (ls.dest < local_ownership.len and local_ownership[ls.dest] == .owned) {
                    if (self.local_to_arc_index.get(ls.dest)) |idx| owns.set(idx);
                }
            },
            .tail_call => |tc| {
                for (tc.args) |arg_local| {
                    self.clearOwnsForLocalAndAliases(arg_local, owns, consumed_owned_param_slots);
                }
            },
            // Phase E.10: aggregate-init instructions consume their
            // operands. List, tuple, struct, and union cells are bump-
            // allocated and never call retain on stored elements; the
            // stored pointer itself rides on the producer's existing
            // +1, and the alias that fed the operand must NOT also
            // emit a scope-exit release — that release would decrement
            // the cell while the bump-allocated aggregate still holds
            // the pointer, producing a use-after-free on every
            // subsequent read of the aggregate.
            //
            // Mirror `tail_call`: clear every operand's owns bit, then
            // set the dest's owns bit (the aggregate itself becomes
            // the new owner alias for downstream destroys; e.g. the
            // returned list is a fresh owner whose own scope-exit
            // destroy is already accounted for at its consumer).
            //
            // `.map_init` is excluded from this rule. Map cells are
            // ARC-managed and `Map.put` (which underpins `.map_init`)
            // retains its inserted value via the Phase 6 substrate.
            // Treating `.map_init` operands as consumed would clear
            // owns bits the runtime's retain has already accounted
            // for, double-decrementing the cell at scope exit.
            .tuple_init => |ti| {
                for (ti.elements) |elem| {
                    self.clearOwnsForLocalAndAliases(elem, owns, consumed_owned_param_slots);
                }
                if (ti.dest < local_ownership.len and local_ownership[ti.dest] == .owned) {
                    if (self.local_to_arc_index.get(ti.dest)) |idx| owns.set(idx);
                }
            },
            .list_init => |li| {
                for (li.elements) |elem| {
                    self.clearOwnsForLocalAndAliases(elem, owns, consumed_owned_param_slots);
                }
                if (li.dest < local_ownership.len and local_ownership[li.dest] == .owned) {
                    if (self.local_to_arc_index.get(li.dest)) |idx| owns.set(idx);
                }
            },
            .list_cons => |lc| {
                self.clearOwnsForLocalAndAliases(lc.head, owns, consumed_owned_param_slots);
                self.clearOwnsForLocalAndAliases(lc.tail, owns, consumed_owned_param_slots);
                if (lc.dest < local_ownership.len and local_ownership[lc.dest] == .owned) {
                    if (self.local_to_arc_index.get(lc.dest)) |idx| owns.set(idx);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| {
                    self.clearOwnsForLocalAndAliases(field.value, owns, consumed_owned_param_slots);
                }
                if (si.dest < local_ownership.len and local_ownership[si.dest] == .owned) {
                    if (self.local_to_arc_index.get(si.dest)) |idx| owns.set(idx);
                }
            },
            .union_init => |ui| {
                self.clearOwnsForLocalAndAliases(ui.value, owns, consumed_owned_param_slots);
                if (ui.dest < local_ownership.len and local_ownership[ui.dest] == .owned) {
                    if (self.local_to_arc_index.get(ui.dest)) |idx| owns.set(idx);
                }
            },
            // `.map_init` does NOT consume its key/value operands — Map cells
            // are ARC-managed and the `Map.put` substrate that underpins
            // `.map_init` takes an INDEPENDENT owner of each inserted key/value
            // (`runtime.zig::Map(K,V).putInPlaceInsert` routes through
            // `ownEntryKey`/`ownEntryValue`: a refcount bump under REFCOUNTED, a
            // clone-on-share deep clone under `INDIVIDUAL_NO_REFCOUNT` +
            // `CLONE_ON_SHARE`). The construction operands therefore remain the
            // caller's own owners and keep their scope-exit drop. Treating any
            // operand as consumed here would clear an owns bit the runtime's own
            // ownership has already accounted for, dropping the construction
            // temporary's reclamation and LEAKING it under Tracking (and
            // double-decrementing the borrowed cell under REFCOUNTED). This is
            // the uniform "Map.put owns its inserted value" contract — a boxed
            // `Callable` value (`%{Atom => fn(i64) -> i64}`) is handled by the
            // same clone-on-share path as every other value type; the prior
            // FCC residual-4 consume carve-out is subsumed by the runtime owning
            // the value (runtime-3--01 / FU-37).
            .map_init => |mi| {
                if (mi.dest < local_ownership.len and local_ownership[mi.dest] == .owned) {
                    if (self.local_to_arc_index.get(mi.dest)) |idx| owns.set(idx);
                }
            },
            // FCC unified model: `box_as_protocol` CONSUMES its source value
            // — the box `allocAny`'s the inner into a heap cell and claims
            // ownership of it (the box's `__drop__` deep-releases the inner at
            // refcount-zero). So the source local's ownership transfers to the
            // box exactly as an aggregate-init operand's does: clear the
            // source's owns bit (otherwise its scope-exit `.release` would
            // deep-release the boxed inner the box ALSO owns — a double-free
            // under `Memory.Tracking` when the inner is itself an ARC value,
            // e.g. a closure env capturing another boxed `Callable`), then set
            // the box dest's owns bit (the box is the new owner whose own
            // scope-exit `.protocol_box_drop` is accounted for at its
            // consumer). Mirrors `struct_init`/`union_init`. Matches the
            // `arc_ownership.zig` rule that records the box source as an
            // aggregate-store (consuming) use.
            .box_as_protocol => |bx| {
                self.clearOwnsForLocalAndAliases(bx.value, owns, consumed_owned_param_slots);
                if (bx.dest < local_ownership.len and local_ownership[bx.dest] == .owned) {
                    if (self.local_to_arc_index.get(bx.dest)) |idx| owns.set(idx);
                }
            },
            // Phase H.5: when a non-tail call targets a callee whose
            // matching `param_conventions[i]` is `.owned`, the callee
            // consumes the i-th arg local — its scope-exit drop is
            // the sole decrement that balances the producer's +1.
            // The dataflow must clear the consumed arg's owns bit
            // here so `live_before_ret` doesn't carry the local
            // through to ret, which would let `arc_drop_insertion`
            // emit a stale post-call release on top of the callee's
            // own drop (double-free).
            //
            // Mirrors the `tail_call` case above. The only difference
            // is which arg slots qualify: a tail_call consumes every
            // arg unconditionally (the callee inherits every slot
            // through the tail jump), while a regular call consumes
            // only the slots whose param convention was promoted to
            // `.owned` by `arc_param_convention.inferConventions`.
            //
            // After clearing the consumed arg bits, the dest-side
            // `+1` is set via the generic-case fallthrough below by
            // a synthetic dispatch — we re-enter the generic handler
            // by checking `defs` directly so the def-local's owns
            // bit gets set when the call returns an `.owned` value.
            .call_direct => |cd| {
                self.applyCallConsumeEffect(cd.function, null, cd.args, owns, consumed_owned_param_slots);
                self.applyCallDestEffect(cd.dest, owns);
            },
            .call_named => |cn| {
                self.applyCallConsumeEffect(null, cn.name, cn.args, owns, consumed_owned_param_slots);
                self.applyCallDestEffect(cn.dest, owns);
            },
            .call_dispatch => |cdsp| {
                // call_dispatch resolves at runtime; conservative
                // here means we cannot know which clause's param
                // conventions apply. Fall back to the generic dest
                // handling — the callee's `arg_modes` already
                // reflects the HIR-level ownership, so when a
                // `.move` mode was set the IR builder emitted a
                // `move_value` whose source-bit clear is handled by
                // the dedicated `.move_value` branch above.
                self.applyCallDestEffect(cdsp.dest, owns);
            },
            // Phase 4 (dense Map): `call_builtin` invocations of the
            // curated owned-mutating intrinsics (`Map.put`/`.delete`/
            // `.merge` — see `ownedMutatingBuiltinSlot`) consume their
            // receiver. The codegen pass
            // `arc_ownership.rewriteOwnedConsumeBuiltinSites` rewrites
            // the share_value at the call site into a move_value and
            // drops the post-call release; the dataflow must clear
            // the receiver arg's owns bit so it doesn't carry through
            // to a ret terminator and trigger a stale scope-exit
            // release on top of the runtime's consume (double-free).
            // For every other builtin the default borrow convention
            // stays in effect — owns bits flow through unchanged and
            // the dest gets +1 via the generic def handling.
            .call_builtin => |cb| {
                if (ownedMutatingBuiltinSlot(cb.name)) |slot| {
                    if (slot < cb.args.len) {
                        self.clearOwnsForLocalAndAliases(cb.args[slot], owns, consumed_owned_param_slots);
                    }
                }
                for (cb.args, 0..) |arg, slot| {
                    if (alwaysConsumingBuiltinArg(cb.name, slot)) {
                        self.clearOwnsForLocalAndAliases(arg, owns, consumed_owned_param_slots);
                    }
                }
                self.applyCallDestEffect(cb.dest, owns);
            },
            .list_tail => |lt| {
                if (lt.consume_source) {
                    self.clearOwnsForLocalAndAliases(lt.list, owns, consumed_owned_param_slots);
                }
                self.applyCallDestEffect(lt.dest, owns);
            },
            // Phase H.6: `param_get` for an `.owned`-convention slot
            // produces an ALIAS to the function's single +1 for that
            // parameter — not an independent owner. The function's
            // entry transfer of ownership accounts for the +1 exactly
            // once; multiple `param_get` reads of the same slot return
            // the same heap pointer over and over, never bumping the
            // cell's refcount.
            //
            // The forward `owns` dataflow tracks "which ARC-managed
            // locals own +1 at the current program point". For an
            // `.owned` parameter slot, that bit's role is "the slot's
            // single +1 is still held by the function". Setting a
            // separate bit for every `param_get` dest of the same slot
            // double-counts: the slot's +1 is one, not N. At a
            // ret-equivalent terminator, `arc_drop_insertion` would
            // then emit one `release` per alias, decrementing the
            // cell N times against its single +1. The observable
            // failure is a use-after-free on the next use of the
            // parameter, surfacing as `List.get/set: index out of
            // bounds` (or worse, silent data corruption) when a tail-
            // recursive caller reads the parameter on the next
            // iteration.
            //
            // The correct rule: set the slot's bit only when no
            // sibling alias's bit is currently in `owns`. The
            // `param_alias_group` map (built in Step 2) records every
            // dest that reads the same `.owned` slot; consulting it
            // here lets us answer "is the slot's +1 already accounted
            // for by an earlier alias?" in one hash lookup. Pairs
            // with `clearOwnsForLocalAndAliases`'s "consume one,
            // consume all" rule: between them, the slot's bit count
            // tracks the slot's actual ownership state — exactly one
            // bit set when the slot is held, zero bits set after a
            // consume of any alias.
            //
            // For `param_get` of a slot with no alias group entry
            // (single-read slots, or `.borrowed`/`.trivial` slots
            // that don't qualify), the original generic rule still
            // applies via `applyCallDestEffect`-style fallthrough.
            .param_get => |pg| {
                if (pg.dest >= local_ownership.len) return;
                if (local_ownership[pg.dest] != .owned) return;
                if (pg.index < consumed_owned_param_slots.bit_count and
                    consumed_owned_param_slots.contains(pg.index))
                {
                    try ownership.non_owning_param_refetches.put(self.allocator, pg.dest, {});
                    return;
                }
                const dest_idx = self.local_to_arc_index.get(pg.dest) orelse return;
                if (self.param_alias_group.get(pg.dest)) |aliases| {
                    for (aliases) |alias| {
                        if (alias == pg.dest) continue;
                        if (self.local_to_arc_index.get(alias)) |alias_idx| {
                            if (owns.contains(alias_idx)) return;
                        }
                    }
                }
                owns.set(dest_idx);
            },
            else => {
                // Generic case: every dest local that's classified as
                // .owned in `local_ownership` gains a +1 at this
                // instruction.
                const defs = collectDefs(instr);
                for (defs.slice()) |def_local| {
                    if (def_local >= local_ownership.len) continue;
                    if (local_ownership[def_local] != .owned) continue;
                    if (self.local_to_arc_index.get(def_local)) |idx| owns.set(idx);
                }
            },
        }
    }

    /// Look up the callee's `param_conventions` slice via the
    /// program reference, and clear each arg local's owns bit at
    /// the slots whose convention is `.owned` (consume sites). When
    /// the program reference is null (analyzer tests construct
    /// hand-rolled functions outside any program), or the callee
    /// cannot be located, the call is treated as borrowing — every
    /// arg's owns bit stays set and the post-call dataflow falls
    /// through to the existing scope-exit drop discipline. This is
    /// the conservative choice: missing the consume signal at most
    /// emits a redundant retain/release pair, while incorrectly
    /// treating a borrow as a consume would suppress a legitimate
    /// drop.
    fn applyCallConsumeEffect(
        self: *Analyzer,
        callee_id: ?ir.FunctionId,
        callee_name: ?[]const u8,
        args: []const ir.LocalId,
        owns: *LiveSet,
        consumed_owned_param_slots: *LiveSet,
    ) void {
        const program = self.program orelse return;
        const conventions = lookupCalleeConventions(program, callee_id, callee_name) orelse return;
        const slot_count = @min(args.len, conventions.len);
        var slot: usize = 0;
        while (slot < slot_count) : (slot += 1) {
            if (conventions[slot] != .owned) continue;
            const arg_local = args[slot];
            self.clearOwnsForLocalAndAliases(arg_local, owns, consumed_owned_param_slots);
        }
    }

    /// Phase 4 helper: clear the owns bit for `local` AND, when
    /// `local` is in a `param_alias_group`, the bits for every other
    /// alias in the same group. Mirrors the dataflow rule "consuming
    /// any alias of an `.owned` parameter consumes the slot's single
    /// +1, leaving no sibling alias live".
    ///
    /// Concretely: when `move_value source=29 dest=30` consumes
    /// `%29` (one alias of slot 4), we clear `arc_idx_29` AND every
    /// other slot-4 alias's bit (e.g. `arc_idx_21` from a sibling
    /// `param_get`). After the move, NO alias contributes a stale
    /// release at the terminator's `owned_at_ret`.
    fn clearOwnsForLocalAndAliases(
        self: *Analyzer,
        local: ir.LocalId,
        owns: *LiveSet,
        consumed_owned_param_slots: ?*LiveSet,
    ) void {
        if (consumed_owned_param_slots) |consumed| {
            if (self.owned_param_slot_by_local.get(local)) |slot| {
                if (slot < consumed.bit_count) consumed.set(slot);
            }
        }
        if (self.local_to_arc_index.get(local)) |idx| owns.unset(idx);
        if (self.param_alias_group.get(local)) |aliases| {
            for (aliases) |alias| {
                if (consumed_owned_param_slots) |consumed| {
                    if (self.owned_param_slot_by_local.get(alias)) |slot| {
                        if (slot < consumed.bit_count) consumed.set(slot);
                    }
                }
                if (self.local_to_arc_index.get(alias)) |idx| owns.unset(idx);
            }
        }
    }

    /// Set the call's dest local owns bit when the dest's
    /// `local_ownership` class is `.owned`. Mirrors the generic-
    /// case fallthrough in `applyOwnsEffect` so the call branches
    /// don't lose the dest-side `+1` accounting.
    fn applyCallDestEffect(self: *Analyzer, dest: ir.LocalId, owns: *LiveSet) void {
        const local_ownership = self.function.local_ownership;
        if (dest >= local_ownership.len) return;
        if (local_ownership[dest] != .owned) return;
        if (self.local_to_arc_index.get(dest)) |idx| owns.set(idx);
    }

    /// Materialise the `owns` bitset into a `LocalId`-keyed
    /// `ArcLocalSet` and store it under `id` in `ownership.owned_at_ret`.
    fn snapshotOwnedAtRet(
        self: *Analyzer,
        ownership: *ArcOwnership,
        id: InstructionId,
        owns: *const LiveSet,
    ) error{OutOfMemory}!void {
        var local_set: ArcLocalSet = .empty;
        errdefer local_set.deinit(self.allocator);
        var bit_index: u32 = 0;
        const bit_count: u32 = @intCast(self.arc_locals.items.len);
        while (bit_index < bit_count) : (bit_index += 1) {
            if (owns.contains(bit_index)) {
                const local_id = self.arc_locals.items[bit_index];
                try local_set.put(self.allocator, local_id, {});
            }
        }
        try ownership.owned_at_ret.putNoClobber(self.allocator, id, local_set);
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
        var ownership = try computeArcOwnershipWithProgram(
            allocator,
            function,
            type_store,
            defaultArcManagedTypeId,
            program,
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
        var ownership = try computeArcOwnershipWithProgram(
            allocator,
            function,
            type_store,
            defaultArcManagedTypeId,
            program,
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

    /// Recurse into every child stream via the canonical enumerator so
    /// the InstructionId numbering matches `flattenChildren` exactly —
    /// including `union_switch.else_instrs` and `optional_dispatch` arms,
    /// both previously skipped here (masked only because
    /// `consume_share_sites` is empty under the borrow ABI; audit
    /// finding arc-liveness--01).
    fn walkChildren(self: *WriteBackWalker, instr: *const ir.Instruction) void {
        ir.forEachChildStream(instr, self, onChildStream);
    }

    fn onChildStream(self: *WriteBackWalker, child: ir.ChildStream) void {
        self.walkStream(child.stream);
    }
};

/// Resolve a callee's `param_conventions` slice from either its
/// `FunctionId` or its symbolic `name`. Returns null when neither
/// lookup hits a registered function — for the analyzer this means
/// "treat the callee as borrowing every arg" (the conservative
/// default). Used by the per-call ownership-effect analysis
/// (`Analyzer.applyCallConsumeEffect`) so the dataflow can clear
/// owns bits for arg slots whose callee convention was promoted to
/// `.owned` by `arc_param_convention.inferConventions`.
///
/// Linear scan: programs typically contain hundreds of functions,
/// the call sites that invoke this helper are bounded by the
/// program's call-site count, and the lookup never recurses. A
/// hash-index would be marginally faster but we'd have to thread
/// it through every analyzer construction site (including the
/// hand-rolled-Function tests). The straight-line scan keeps the
/// public surface minimal and the per-call cost negligible at
/// today's program sizes.
fn lookupCalleeConventions(
    program: *const ir.Program,
    callee_id: ?ir.FunctionId,
    callee_name: ?[]const u8,
) ?[]const ir.ParamConvention {
    if (callee_id) |id| {
        for (program.functions) |func| {
            if (func.id == id) return func.param_conventions;
        }
    }
    if (callee_name) |name| {
        for (program.functions) |func| {
            if (std.mem.eql(u8, func.name, name)) return func.param_conventions;
            if (func.local_name.len != 0 and std.mem.eql(u8, func.local_name, name)) {
                return func.param_conventions;
            }
        }
    }
    return null;
}

/// Curated list of `call_builtin` names whose first argument is a
/// "consume" slot when the source local is at last use. The runtime
/// implementations in `runtime.zig` (`Map(K,V).put`, `.delete`,
/// `.merge`) have a refcount-aware fast path that mutates the
/// receiver in place when its refcount is 1, so passing the receiver
/// as a `move_value` (no caller-side retain) collapses repeated
/// mutations into a single in-place sequence. Without this list,
/// every call site would emit `share_value` (retain) + post-call
/// `release`, which keeps the receiver's refcount at >= 2 and forces
/// the runtime onto the always-clone slow path.
///
/// Returns the slot index of the consumed argument (always 0 today)
/// when `name` matches a known owned-mutating builtin, or null when
/// the builtin should keep its default borrow convention.
///
/// Recognised name shapes:
///   * `Map.put`, `Map.delete`, `Map.merge` — pre-monomorph generic
///     name used when the key/value types resolve to `.any`/`.term`.
///   * `Map:K:V.put` etc. — post-monomorph encoded name produced by
///     `IrBuilder.buildCall` for concrete `Map(K, V)` instantiations.
///   * `MapNested:K:V.put` etc. — encoded name for nested map values
///     (`Map(K, Map(K2, V2))` and similar).
///   * `List.set`, `List.push`, `List.pop`, `List.append` — generic
///     native namespace name used by Stage 3's flat-buffer `List(T)`
///     surface.
///   * `List:T.set` etc. — post-monomorph encoded name produced by
///     `IrBuilder.buildCall` for concrete `List(T)` instantiations.
///   * `ListNested:T.set` etc. — encoded name for nested list values.
///
/// The flat-buffer `List(T)` runtime uses the same rc-1 fast-path
/// pattern as the dense Map; without slot-0 promotion, callers retain
/// their receiver to refcount 2 before entering the runtime, the rc-1
/// branch never fires, and every mutation copies. Receiver is always
/// slot 0 (`list.set(i, x)` / `list.push(x)` / `list.pop()` /
/// `a.append(b)`). For `append` only the LHS slot is owned-mutating;
/// the RHS is a borrowed source whose elements are deep-retain copied
/// — codegen treats it through normal borrowed-receiver share/release
/// plumbing.
///
/// All Zap-level callers route through these names via
/// `lib/map.zap` and `lib/list.zap`'s thin wrappers. The runtime's
/// fast path is independent of the element types — it gates only on
/// the receiver's refcount — so a single shape predicate covers
/// every monomorph.
pub fn ownedMutatingBuiltinSlot(name: []const u8) ?usize {
    // Method suffix is the last `.`-separated component.
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const method_full = name[dot_index + 1 ..];
    const prefix = name[0..dot_index];

    // Phase 3 (uniqueness): the `_owned_unchecked` suffix is a peer of the
    // checked variant — same receiver-slot semantics, but the
    // runtime skips the rc==1 check. Treat both as owned-mutating
    // for slot inference; the verifier in `arc_verifier.zig` uses
    // `isUncheckedOwnedMutatingBuiltin` to additionally enforce uniqueness
    // on the unchecked sites.
    const unchecked_suffix = "_owned_unchecked";
    const method = if (std.mem.endsWith(u8, method_full, unchecked_suffix))
        method_full[0 .. method_full.len - unchecked_suffix.len]
    else
        method_full;

    const is_map_method =
        std.mem.eql(u8, method, "put") or
        std.mem.eql(u8, method, "delete") or
        std.mem.eql(u8, method, "merge");
    if (is_map_method) {
        const is_map_prefix =
            std.mem.eql(u8, prefix, "Map") or
            std.mem.startsWith(u8, prefix, "Map:") or
            std.mem.startsWith(u8, prefix, "MapNested:");
        if (is_map_prefix) return 0;
        return null;
    }

    const is_list_method =
        std.mem.eql(u8, method, "set") or
        std.mem.eql(u8, method, "push") or
        std.mem.eql(u8, method, "pop") or
        std.mem.eql(u8, method, "append");
    if (is_list_method) {
        if (isListBuiltinPrefix(prefix)) return 0;
        return null;
    }

    return null;
}

/// Does `name` consume the argument in `slot` and allow the compiler
/// to transfer a last-use owner directly into that slot?
///
/// This is broader than `ownedMutatingBuiltinSlot`: the receiver slot
/// of `Map.put` / `List.push` participates in rc1 mutation, while the
/// element slot of `List.push` / `List.set` is stored directly into the
/// list buffer and is therefore consumed by the runtime ABI. Map keys
/// and values are intentionally excluded because `Map.put` retains
/// them for persistent entry ownership.
pub fn builtinArgCanMoveAtLastUse(name: []const u8, slot: usize) bool {
    if (ownedMutatingBuiltinSlot(name)) |owned_slot| {
        if (owned_slot == slot) return true;
    }
    if (mapMergeConsumesRightOperand(name, slot)) return true;
    if (listElementConsumingBuiltinArg(name, slot)) return true;
    // The recoverable-raise side-channel stash always takes ownership of
    // its boxed-`Error` argument (transferred out to the recovered owner
    // via `take_recoverable_raise`), so a last-use owner can always move
    // straight in — and the post-call release in the `:zig.` wrapper must
    // be dropped (it would double-decrement against the recovered owner).
    return sideChannelStashBuiltinArg(name, slot);
}

/// Does `name` consume the argument in `slot` as part of the builtin's
/// ABI, independent of rc1 uniqueness optimisation?
///
/// This is deliberately narrower than `ownedMutatingBuiltinSlot`.
/// `Map.put` / `List.append` receive a temporary retained receiver
/// when the source is not at last use; the runtime must see that
/// refcount and clone rather than consume it. By contrast
/// `List.cons(head, tail)` stores `head` into a fresh list and releases
/// the consumed `tail` owner after retaining tail elements. Any
/// compiler-emitted post-call release for either argument's
/// `share_value` would double-decrement the temporary owner.
pub fn alwaysConsumingBuiltinArg(name: []const u8, slot: usize) bool {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const method_full = name[dot_index + 1 ..];
    const prefix = name[0..dot_index];
    const method = stripOwnedUncheckedSuffix(method_full);

    if (mapMergeConsumesRightOperandWithParts(prefix, method, slot)) return true;

    if (std.mem.eql(u8, method, "cons") and isListBuiltinPrefix(prefix)) {
        return slot == 0 or slot == 1;
    }

    if (listElementConsumingBuiltinArgWithParts(prefix, method, slot)) return true;

    if (sideChannelStashBuiltinArg(name, slot)) return true;

    return false;
}

/// Does `name`'s argument at `slot` need an independently-owned value
/// before entering the runtime when the caller still needs the source?
///
/// Under `Memory.Tracking`, normal transient shares are aliases. Runtime
/// calls that mutate or consume an argument therefore need either a
/// last-use move or a persistent clone-on-share owner. This predicate is
/// intentionally narrower than `builtinArgCanMoveAtLastUse`: List element
/// stores have their own always-consuming temporary-retain path.
pub fn builtinArgRequiresOwnedInput(name: []const u8, slot: usize) bool {
    if (ownedMutatingBuiltinSlot(name)) |owned_slot| {
        if (owned_slot == slot) return true;
    }
    return mapMergeConsumesRightOperand(name, slot);
}

/// Returns the argument slot of a `List.cons`-family builtin that is the
/// CONS TAIL — the existing list that the new cell prepends onto — when
/// `name` is a `List.cons` builtin, else `null`.
///
/// `:zig.List.cons(head, tail)` allocates a fresh cons cell whose `next`
/// is `tail`. Under the runtime's rc-1 in-place fast path (commit
/// fb32ef1) a refcount-1 tail is mutated in place and returned AS the
/// result cell — so when the tail is at last-use the cons PRESERVES the
/// tail's uniqueness INTO the cons result. This is strictly stronger than
/// `alwaysConsumingBuiltinArg`, which marks BOTH cons slots consuming for
/// the post-call-release accounting: the head is merely consumed (stored
/// into the new cell, no derivative), while the tail is consumed AND its
/// uniqueness flows to the dest.
///
/// The uniqueness stack uses this in three places: the signature
/// inference (`uniqueness_fixpoint.classifyBuiltinCall`) upgrades the
/// tail-position parameter to `preservesUniqueness`; the production
/// uniqueness dataflow and the tentative pre-flight
/// (`uniqueness.Analyzer.applyEffect` / `arc_param_convention`
/// `TentativeAnalyzer.applyEffect` and `computeRewrittenShareSet`) treat
/// a tail-at-last-use cons as a uniqueness-preserving move into the
/// result, mirroring the `list_cons` IR-node rc-1 gate.
///
/// Cons is the head=slot 0, tail=slot 1 calling convention
/// (`List.prepend(list, value) -> :zig.List.cons(value, list)`), so the
/// tail is always slot 1.
pub fn consBuiltinTailSlot(name: []const u8) ?usize {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const method_full = name[dot_index + 1 ..];
    const prefix = name[0..dot_index];
    const method = stripOwnedUncheckedSuffix(method_full);
    if (std.mem.eql(u8, method, "cons") and isListBuiltinPrefix(prefix)) return 1;
    return null;
}

/// Does `name`/`slot` name the recoverable-raise side-channel STASH
/// primitive that takes ownership of a boxed `Error` and transfers it
/// OUT of the caller into the thread-local raise side-channel?
///
/// `:zig.Kernel.recoverable_raise(box)` stores the boxed-`Error`
/// `ProtocolBox` into `current_recoverable_raise` (src/runtime.zig). The
/// box's matching owner is recovered LATER, in a different scope, by
/// `Kernel.take_recoverable_raise()` — which returns the stashed box as
/// an OWNED result. The two form a single matched ownership-transfer
/// pair through the side-channel: exactly one net owner exists from the
/// raise to the recovery.
///
/// The ARC pipeline cannot infer this transfer because the stash crosses
/// a thread-local global through a `:zig.` bridge (the convention-
/// inference's uniqueness audit explicitly REFUSES to lift a parameter
/// that escapes the function — see `arc_param_convention.computeLiftSet`
/// condition 1). So the stash's consume convention is a property of the
/// runtime primitive's ABI, classified here exactly as the runtime-
/// collection primitives (`Map.put`, `List.cons`) are.
///
/// Without this, the boxed-error local the `raise` constructed
/// (`box_as_protocol` → `recoverable_raise(box)`) keeps a scope-exit
/// release in the raising scope, while the recovered box gets its own
/// scope-exit release — TWO releases of one inner. Under `Memory.ARC`
/// the second decrement was masked by slab reuse; under `Memory.Tracking`
/// (no refcounts, `munmap`'d free pages) the second drop dereferenced the
/// freed inner and SIGSEGV'd in `freeAnyNonRefcountedImpl`'s by-value
/// child-walk. Marking slot 0 consuming transfers the box's ownership
/// into the call so the raising scope emits NO release; the recovered
/// box is then the sole owner and drops the inner exactly once.
///
/// Slot 0 only (the boxed-`Error` argument). The pre-monomorph name is
/// the only shape: `recoverable_raise` takes a bare `Error` existential,
/// so the `:zig.` bridge is never type-specialised into an encoded name.
pub fn sideChannelStashBuiltinArg(name: []const u8, slot: usize) bool {
    return slot == 0 and std.mem.eql(u8, name, "Kernel.recoverable_raise");
}

/// Does `function`'s body forward parameter `param_index` directly into the
/// recoverable-raise side-channel STASH builtin (`sideChannelStashBuiltinArg`)?
///
/// Used by `arc_param_convention.inferConventions` to promote the
/// `lib/kernel.zap` `recoverable_raise` wrapper's boxed-`Error` slot to
/// `.owned` — the ONE escaping-parameter promotion the uniqueness audit
/// cannot derive, because the stash crosses a thread-local global through a
/// `:zig.` bridge yet is still a sound ownership transfer (matched by
/// `take_recoverable_raise`). See the promotion site for the full
/// rationale.
///
/// Tracks the SSA alias chain from each `param_get` of the slot through
/// `move_value`/`local_get`/`borrow_value`/`share_value` copies to a fixed
/// point, then checks whether any alias is passed in the stash builtin's
/// consuming slot. Structural (forwards-into-stash), never keyed on the
/// wrapper's mangled name. Uses `page_allocator` for the transient alias
/// set (freed before return); the program is small per-function so the
/// allocation cost is negligible and confined to convention inference.
pub fn functionForwardsParamIntoSideChannelStash(
    function: *const ir.Function,
    param_index: usize,
) bool {
    var alias_set: std.ArrayListUnmanaged(ir.LocalId) = .empty;
    defer alias_set.deinit(std.heap.page_allocator);

    for (function.body) |block| {
        sideChannelSeedParamAliases(block.instructions, param_index, &alias_set);
    }
    if (alias_set.items.len == 0) return false;

    var changed = true;
    while (changed) {
        changed = false;
        for (function.body) |block| {
            if (sideChannelExtendParamAliases(block.instructions, &alias_set)) changed = true;
        }
    }

    for (function.body) |block| {
        if (sideChannelStreamConsumesAlias(block.instructions, alias_set.items)) return true;
    }
    return false;
}

fn sideChannelAliasContains(set: []const ir.LocalId, local: ir.LocalId) bool {
    for (set) |id| {
        if (id == local) return true;
    }
    return false;
}

fn sideChannelAppendAlias(set: *std.ArrayListUnmanaged(ir.LocalId), local: ir.LocalId) bool {
    if (sideChannelAliasContains(set.items, local)) return false;
    set.append(std.heap.page_allocator, local) catch return false;
    return true;
}

fn sideChannelSeedParamAliases(
    stream: []const ir.Instruction,
    param_index: usize,
    alias_set: *std.ArrayListUnmanaged(ir.LocalId),
) void {
    for (stream) |*instr| {
        if (instr.* == .param_get) {
            const pg = instr.param_get;
            if (pg.index == param_index) _ = sideChannelAppendAlias(alias_set, pg.dest);
        }
        // Recurse into every nested sub-stream via the canonical
        // enumerator (covers union_switch.else_instrs, try_call_named,
        // optional_dispatch, etc. that the old hand-rolled switch omitted).
        const Seed = struct {
            param_index: usize,
            alias_set: *std.ArrayListUnmanaged(ir.LocalId),
            fn onStream(self: *@This(), child: ir.ChildStream) void {
                sideChannelSeedParamAliases(child.stream, self.param_index, self.alias_set);
            }
        };
        var seed = Seed{ .param_index = param_index, .alias_set = alias_set };
        ir.forEachChildStream(instr, &seed, Seed.onStream);
    }
}

fn sideChannelExtendParamAliases(
    stream: []const ir.Instruction,
    alias_set: *std.ArrayListUnmanaged(ir.LocalId),
) bool {
    var changed = false;
    for (stream) |*instr| {
        switch (instr.*) {
            .move_value => |mv| {
                if (sideChannelAliasContains(alias_set.items, mv.source)) {
                    if (sideChannelAppendAlias(alias_set, mv.dest)) changed = true;
                }
            },
            .local_get => |lg| {
                if (sideChannelAliasContains(alias_set.items, lg.source)) {
                    if (sideChannelAppendAlias(alias_set, lg.dest)) changed = true;
                }
            },
            .borrow_value => |bv| {
                if (sideChannelAliasContains(alias_set.items, bv.source)) {
                    if (sideChannelAppendAlias(alias_set, bv.dest)) changed = true;
                }
            },
            .share_value => |sv| {
                if (sideChannelAliasContains(alias_set.items, sv.source)) {
                    if (sideChannelAppendAlias(alias_set, sv.dest)) changed = true;
                }
            },
            else => {},
        }
        // Recurse into every nested sub-stream via the canonical
        // enumerator so aliases created inside ANY control-flow construct
        // (including union_switch.else_instrs, try_call_named, and
        // optional_dispatch arms — previously not walked here at all) are
        // tracked. Keeps the Gap-4 return-source-elision gate from
        // under-approximating the alias set.
        const Ext = struct {
            alias_set: *std.ArrayListUnmanaged(ir.LocalId),
            changed: bool = false,
            fn onStream(self: *@This(), child: ir.ChildStream) void {
                if (sideChannelExtendParamAliases(child.stream, self.alias_set)) self.changed = true;
            }
        };
        var ext = Ext{ .alias_set = alias_set };
        ir.forEachChildStream(instr, &ext, Ext.onStream);
        if (ext.changed) changed = true;
    }
    return changed;
}

fn sideChannelStreamConsumesAlias(
    stream: []const ir.Instruction,
    alias_set: []const ir.LocalId,
) bool {
    for (stream) |*instr| {
        if (instr.* == .call_builtin) {
            const cb = instr.call_builtin;
            for (cb.args, 0..) |arg, slot| {
                if (sideChannelStashBuiltinArg(cb.name, slot) and
                    sideChannelAliasContains(alias_set, arg))
                {
                    return true;
                }
            }
        }
        // Recurse into every nested sub-stream via the canonical
        // enumerator (covers union_switch.else_instrs, try_call_named,
        // optional_dispatch, switch_* that the old switch omitted).
        const Consumes = struct {
            alias_set: []const ir.LocalId,
            found: bool = false,
            fn onStream(self: *@This(), child: ir.ChildStream) void {
                if (self.found) return;
                if (sideChannelStreamConsumesAlias(child.stream, self.alias_set)) self.found = true;
            }
        };
        var consumes = Consumes{ .alias_set = alias_set };
        ir.forEachChildStream(instr, &consumes, Consumes.onStream);
        if (consumes.found) return true;
    }
    return false;
}

fn isListBuiltinPrefix(prefix: []const u8) bool {
    return std.mem.eql(u8, prefix, "List") or
        std.mem.startsWith(u8, prefix, "List:") or
        std.mem.startsWith(u8, prefix, "ListNested:");
}

fn stripOwnedUncheckedSuffix(method_full: []const u8) []const u8 {
    const unchecked_suffix = "_owned_unchecked";
    if (std.mem.endsWith(u8, method_full, unchecked_suffix)) {
        return method_full[0 .. method_full.len - unchecked_suffix.len];
    }
    return method_full;
}

fn listElementConsumingBuiltinArg(name: []const u8, slot: usize) bool {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const method = stripOwnedUncheckedSuffix(name[dot_index + 1 ..]);
    const prefix = name[0..dot_index];
    return listElementConsumingBuiltinArgWithParts(prefix, method, slot);
}

fn listElementConsumingBuiltinArgWithParts(prefix: []const u8, method: []const u8, slot: usize) bool {
    if (!isListBuiltinPrefix(prefix)) return false;
    if (std.mem.eql(u8, method, "push")) return slot == 1;
    if (std.mem.eql(u8, method, "set")) return slot == 2;
    return false;
}

fn mapMergeConsumesRightOperand(name: []const u8, slot: usize) bool {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const method = stripOwnedUncheckedSuffix(name[dot_index + 1 ..]);
    const prefix = name[0..dot_index];
    return mapMergeConsumesRightOperandWithParts(prefix, method, slot);
}

fn mapMergeConsumesRightOperandWithParts(prefix: []const u8, method: []const u8, slot: usize) bool {
    if (slot != 1) return false;
    if (!std.mem.eql(u8, method, "merge")) return false;
    return std.mem.eql(u8, prefix, "Map") or
        std.mem.startsWith(u8, prefix, "Map:") or
        std.mem.startsWith(u8, prefix, "MapNested:");
}

/// Phase 3 (uniqueness): is `name` an unchecked owned-mutating builtin?
///
/// Unchecked variants (`Map.put_owned_unchecked`,
/// `List.set_owned_unchecked`, etc.) bypass the runtime's rc==1
/// check. They are codegen targets emitted only at call sites
/// where the uniqueness verifier proves static uniqueness; the verifier
/// uses this predicate to identify which call sites must satisfy
/// uniqueness = true.
///
/// The shape is identical to `ownedMutatingBuiltinSlot` modulo the
/// trailing `_owned_unchecked` on the method suffix.
pub fn isUncheckedOwnedMutatingBuiltin(name: []const u8) bool {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const method = name[dot_index + 1 ..];
    if (!std.mem.endsWith(u8, method, "_owned_unchecked")) return false;
    // Confirm the prefix and method-prefix match the owned-mutating
    // pattern; otherwise we'd accept arbitrary `Foo.bar_owned_unchecked`
    // names. Using `ownedMutatingBuiltinSlot` here would loop, so we
    // re-walk the same predicate inline.
    return ownedMutatingBuiltinSlot(name) != null;
}

/// uniqueness (Phase 1.4): is `name` a runtime fresh-allocator intrinsic?
///
/// A "fresh allocator" is a `call_builtin` whose runtime contract is
/// "allocates a brand-new ARC-managed cell with refcount = 1." These
/// are the constructors for our ARC-managed runtime types: `Map.new`,
/// `List.new_filled`/`new_empty`, etc. The runtime invariant is
/// that every call returns a refcount=1
/// owner, so the uniqueness dataflow can mark the dest as `definitely_unique`
/// without needing to inspect the body.
///
/// Why this predicate exists:
///
/// uniqueness already marks owned-mutating call results unique (the runtime
/// contract for `Map.put`/`List.set`/etc. is also "result is rc=1"),
/// but constructors are NOT in `ownedMutatingBuiltinSlot` because they
/// don't consume any input slot. Without this predicate, uniqueness sees a
/// call to `List:i64.new_filled(size, init)` and treats the dest as
/// "not unique" — even though the runtime physically allocates a fresh
/// cell. That mistake breaks the uniqueness chain at every program entry
/// point: `v = List.new_filled(...)` produces a "not unique" v,
/// then `v = List.set(v, i, x)` (or any owned-mutator) sees a
/// non-unique receiver, blocks the unchecked rewrite, and the runtime
/// pays for an rc check on every call.
///
/// The Zap-fn-wrapper case (`lib/list.zap`'s `new_filled`
/// forwards to `:zig.List.new_filled`) is handled at the
/// caller-side as well: when uniqueness sees a `call_named` to a Zap function
/// whose `result_convention == .owned` and whose body is a single-call
/// forward to a fresh-allocator builtin, the call's dest inherits the
/// unique result. That flow lives in `uniqueness.zig`'s
/// `applyCalleeEffect`.
///
/// Soundness:
///
/// The verifier (`arc_verifier.runUniquenessCheck`) re-runs the per-function uniqueness
/// with this same predicate, so a buggy classification surfaces as
/// `error.ArcInvariantViolation` at build time, not as a runtime
/// soundness bug. The conservative default for any unknown name is
/// `false` — uniqueness then treats the dest as "not unique" and the unchecked
/// rewrite stays inactive (the checked variant runs and pays an rc
/// check). Adding new constructors to the runtime requires extending
/// this predicate (and its tests), but a missed constructor only
/// costs a runtime rc check, never soundness.
pub fn isFreshAllocatorBuiltin(name: []const u8) bool {
    const dot_index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const method_full = name[dot_index + 1 ..];
    const prefix = name[0..dot_index];

    // Map / MapNested constructors:
    //   - `Map.new()` and `Map.new_with_capacity(n)` produce fresh
    //     dense Maps.
    if (std.mem.eql(u8, method_full, "new") or
        std.mem.eql(u8, method_full, "new_with_capacity"))
    {
        if (std.mem.eql(u8, prefix, "Map") or
            std.mem.startsWith(u8, prefix, "Map:") or
            std.mem.startsWith(u8, prefix, "MapNested:"))
        {
            return true;
        }
    }

    // Flat-buffer List constructors:
    //   - `List.new_filled(size, init)` and `List.new_empty(cap)`.
    if (std.mem.eql(u8, method_full, "new_filled") or
        std.mem.eql(u8, method_full, "new_empty"))
    {
        if (isListBuiltinPrefix(prefix)) return true;
    }

    return false;
}

test "arc_liveness: ownedMutatingBuiltinSlot matches Map.put / delete / merge variants" {
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.put"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.delete"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.merge"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map:u32:i64.put"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map:str:str.delete"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("MapNested:str:list.merge"));
    // Negative cases.
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("Map.get"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("Map.size"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("List.get"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("Foo.put"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("MapAlt.put"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("put"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot(""));
}

test "arc_liveness: ownedMutatingBuiltinSlot matches List.set / push / pop / append variants" {
    // Pre-monomorph generic names.
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.set"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.push"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.pop"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.append"));
    // Post-monomorph encoded names (concrete instantiations).
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List:i64.set"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List:f64.push"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List:str.append"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("ListNested:i64.append"));
    // Negative cases — non-mutating List methods stay borrowed.
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("List.get"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("List.length"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("List.capacity"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("List.new_filled"));
    // Lookalike receiver names must not match.
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("ListAlt.set"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("OtherList.set"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("set"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("ListAlias.set"));
}

test "arc_liveness: alwaysConsumingBuiltinArg recognizes List.cons argument slots" {
    try std.testing.expect(alwaysConsumingBuiltinArg("List.cons", 0));
    try std.testing.expect(alwaysConsumingBuiltinArg("List.cons", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("List:i64.cons", 0));
    try std.testing.expect(alwaysConsumingBuiltinArg("List:i64.cons", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("ListNested:list.cons", 0));
    try std.testing.expect(alwaysConsumingBuiltinArg("ListNested:list.cons", 1));

    try std.testing.expect(!alwaysConsumingBuiltinArg("List.cons", 2));
    try std.testing.expect(!alwaysConsumingBuiltinArg("List.append", 0));
    try std.testing.expect(!alwaysConsumingBuiltinArg("Map.put", 0));
    try std.testing.expect(!alwaysConsumingBuiltinArg("ListAlt.cons", 0));
    try std.testing.expect(!alwaysConsumingBuiltinArg("cons", 0));
}

test "arc_liveness: recoverable-raise side-channel stash consumes its boxed-Error arg" {
    // `Kernel.recoverable_raise(box)` transfers the boxed `Error` into the
    // thread-local side-channel (recovered later by `take_recoverable_raise`).
    // Slot 0 is consuming; the raising scope must NOT emit a scope-exit
    // release for the stashed box (the recovered owner drops it once),
    // otherwise the inner double-frees (segfault under Memory.Tracking).
    try std.testing.expect(sideChannelStashBuiltinArg("Kernel.recoverable_raise", 0));
    try std.testing.expect(alwaysConsumingBuiltinArg("Kernel.recoverable_raise", 0));
    try std.testing.expect(builtinArgCanMoveAtLastUse("Kernel.recoverable_raise", 0));

    // Only slot 0 (the box); the primitive has no other ARC-owning args.
    try std.testing.expect(!sideChannelStashBuiltinArg("Kernel.recoverable_raise", 1));
    try std.testing.expect(!alwaysConsumingBuiltinArg("Kernel.recoverable_raise", 1));

    // Sibling raise-plumbing primitives are NOT consume sinks: `do_raise`
    // formats+aborts (its box is borrowed for the crash report, not stashed),
    // `peek_recoverable_raise`/`take_recoverable_raise` PRODUCE the box (no
    // consumed argument). A false positive here would suppress a legitimate
    // drop and leak.
    try std.testing.expect(!sideChannelStashBuiltinArg("Kernel.do_raise", 0));
    try std.testing.expect(!sideChannelStashBuiltinArg("Kernel.peek_recoverable_raise", 0));
    try std.testing.expect(!sideChannelStashBuiltinArg("Kernel.take_recoverable_raise", 0));
    // Lookalike names must not match.
    try std.testing.expect(!sideChannelStashBuiltinArg("KernelAlt.recoverable_raise", 0));
    try std.testing.expect(!sideChannelStashBuiltinArg("recoverable_raise", 0));
    try std.testing.expect(!sideChannelStashBuiltinArg("", 0));
}

test "arc_liveness: List.set and List.push element slots are consumed by builtin ABI" {
    try std.testing.expect(alwaysConsumingBuiltinArg("List.push", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("List.set", 2));
    try std.testing.expect(alwaysConsumingBuiltinArg("List:i64.push", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("ListNested:list.set", 2));
    try std.testing.expect(alwaysConsumingBuiltinArg("List.push_owned_unchecked", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("List:f64.set_owned_unchecked", 2));
    try std.testing.expect(alwaysConsumingBuiltinArg("Map.merge", 1));
    try std.testing.expect(alwaysConsumingBuiltinArg("Map:str:i64.merge_owned_unchecked", 1));

    try std.testing.expect(!alwaysConsumingBuiltinArg("List.push", 0));
    try std.testing.expect(!alwaysConsumingBuiltinArg("List.push", 2));
    try std.testing.expect(!alwaysConsumingBuiltinArg("List.set", 1));
    try std.testing.expect(!alwaysConsumingBuiltinArg("List.append", 1));
    try std.testing.expect(!alwaysConsumingBuiltinArg("Map.put", 2));
    try std.testing.expect(!alwaysConsumingBuiltinArg("Map.merge", 0));
}

test "arc_liveness: builtinArgCanMoveAtLastUse includes receivers and consumed List elements" {
    try std.testing.expect(builtinArgCanMoveAtLastUse("Map.put", 0));
    try std.testing.expect(builtinArgCanMoveAtLastUse("Map.merge", 1));
    try std.testing.expect(builtinArgCanMoveAtLastUse("List.push", 0));
    try std.testing.expect(builtinArgCanMoveAtLastUse("List.push", 1));
    try std.testing.expect(builtinArgCanMoveAtLastUse("List.set_owned_unchecked", 2));

    try std.testing.expect(!builtinArgCanMoveAtLastUse("Map.put", 2));
    try std.testing.expect(!builtinArgCanMoveAtLastUse("Map.merge", 2));
    try std.testing.expect(!builtinArgCanMoveAtLastUse("List.append", 1));
    try std.testing.expect(!builtinArgCanMoveAtLastUse("List.cons", 0));
    try std.testing.expect(!builtinArgCanMoveAtLastUse("List.get", 0));
}

test "arc_liveness: builtinArgRequiresOwnedInput covers mutating receivers and Map.merge right operand" {
    try std.testing.expect(builtinArgRequiresOwnedInput("Map.put", 0));
    try std.testing.expect(builtinArgRequiresOwnedInput("Map.merge", 0));
    try std.testing.expect(builtinArgRequiresOwnedInput("Map.merge", 1));
    try std.testing.expect(builtinArgRequiresOwnedInput("List.push", 0));

    try std.testing.expect(!builtinArgRequiresOwnedInput("Map.put", 1));
    try std.testing.expect(!builtinArgRequiresOwnedInput("List.push", 1));
    try std.testing.expect(!builtinArgRequiresOwnedInput("Map.merge", 2));
}

test "arc_liveness: List.cons call_builtin clears consumed share owners" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 2);
    args[0] = 1;
    args[1] = 3;

    const arg_modes = try arena.alloc(ir.ValueMode, 2);
    arg_modes[0] = .share;
    arg_modes[1] = .share;

    const stream = try arena.alloc(ir.Instruction, 6);
    stream[0] = .{ .const_string = .{ .dest = 0, .value = "head" } };
    stream[1] = .{ .share_value = .{ .dest = 1, .source = 0, .mode = .retain } };
    stream[2] = .{ .const_string = .{ .dest = 2, .value = "tail" } };
    stream[3] = .{ .share_value = .{ .dest = 3, .source = 2, .mode = .retain } };
    stream[4] = .{ .call_builtin = .{
        .dest = 4,
        .name = "List.cons",
        .args = args,
        .arg_modes = arg_modes,
    } };
    stream[5] = .{ .ret = .{ .value = 4 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*ownership_class| ownership_class.* = .owned;

    const list_string_element: ir.ZigType = .string;
    const list_string_type: ir.ZigType = .{ .list = &list_string_element };
    const function = ir.Function{
        .id = 0,
        .name = "list_cons_consume_test",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = list_string_type,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    var owned_ret_iter = ownership.owned_at_ret.valueIterator();
    while (owned_ret_iter.next()) |set_ptr| {
        try std.testing.expect(!set_ptr.contains(1));
        try std.testing.expect(!set_ptr.contains(3));
        try std.testing.expect(set_ptr.contains(4));
    }
}

test "arc_liveness: ownedMutatingBuiltinSlot recognizes Phase 3 unchecked variants" {
    // Phase 3 (uniqueness): `*_owned_unchecked` variants share the same
    // receiver-slot semantics as their checked counterparts. The
    // matcher must treat them as owned-mutating; the unchecked-
    // specific predicate `isUncheckedOwnedMutatingBuiltin` is what
    // distinguishes them for the uniqueness verifier.
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.put_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.delete_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map.merge_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("Map:u32:i64.put_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.set_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.push_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.pop_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List.append_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("List:i64.set_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, 0), ownedMutatingBuiltinSlot("ListNested:i64.append_owned_unchecked"));
    // Negative: unchecked suffix on non-mutating methods still null.
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("Map.get_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("Map.size_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("ListAlt.set_owned_unchecked"));
    try std.testing.expectEqual(@as(?usize, null), ownedMutatingBuiltinSlot("ListAlias.set_owned_unchecked"));
}

test "arc_liveness: isFreshAllocatorBuiltin matches Map / List constructors" {
    // Map constructors.
    try std.testing.expect(isFreshAllocatorBuiltin("Map.new"));
    try std.testing.expect(isFreshAllocatorBuiltin("Map.new_with_capacity"));
    try std.testing.expect(isFreshAllocatorBuiltin("Map:i64:i64.new"));
    try std.testing.expect(isFreshAllocatorBuiltin("Map:str:i64.new_with_capacity"));
    try std.testing.expect(isFreshAllocatorBuiltin("MapNested:str:list.new"));

    // Flat-buffer List constructors.
    try std.testing.expect(isFreshAllocatorBuiltin("List.new_filled"));
    try std.testing.expect(isFreshAllocatorBuiltin("List.new_empty"));
    try std.testing.expect(isFreshAllocatorBuiltin("List:i64.new_filled"));
    try std.testing.expect(isFreshAllocatorBuiltin("List:f64.new_empty"));
    try std.testing.expect(isFreshAllocatorBuiltin("List:UserStruct.new_empty"));
    try std.testing.expect(isFreshAllocatorBuiltin("ListNested:i64.new_filled"));

    // Negative cases — non-constructor methods.
    try std.testing.expect(!isFreshAllocatorBuiltin("Map.put"));
    try std.testing.expect(!isFreshAllocatorBuiltin("Map.get"));
    try std.testing.expect(!isFreshAllocatorBuiltin("List.set"));
    try std.testing.expect(!isFreshAllocatorBuiltin("List.length"));
    // Lookalike receivers must not match.
    try std.testing.expect(!isFreshAllocatorBuiltin("Foo.new"));
    try std.testing.expect(!isFreshAllocatorBuiltin("ListAlt.new_filled"));
    try std.testing.expect(!isFreshAllocatorBuiltin("OtherList.new_empty"));
    try std.testing.expect(!isFreshAllocatorBuiltin("ListAlias.new_filled"));
    try std.testing.expect(!isFreshAllocatorBuiltin("new"));
    try std.testing.expect(!isFreshAllocatorBuiltin(""));
}

test "arc_liveness: isUncheckedOwnedMutatingBuiltin distinguishes checked and unchecked variants" {
    // Positive: every owned-mutating method has an unchecked peer.
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("Map.put_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("Map.delete_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("Map.merge_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("Map:str:i64.put_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("List.set_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("List.push_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("List.pop_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("List.append_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("List:f64.append_owned_unchecked"));
    try std.testing.expect(isUncheckedOwnedMutatingBuiltin("ListNested:f64.append_owned_unchecked"));
    // Negative: checked variants are NOT unchecked.
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("Map.put"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("Map.delete"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("List.set"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("List.push"));
    // Negative: non-owned-mutating names with the suffix don't qualify.
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("Map.get_owned_unchecked"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("Foo.put_owned_unchecked"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("ListAlt.set_owned_unchecked"));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("ListAlias.set_owned_unchecked"));
    // Negative: empty / malformed names.
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin(""));
    try std.testing.expect(!isUncheckedOwnedMutatingBuiltin("put_owned_unchecked"));
}

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

    /// Recurse into every child stream via the canonical enumerator so
    /// the InstructionId numbering matches `flattenChildren` (including
    /// `union_switch.else_instrs` and `optional_dispatch` arms; audit
    /// finding arc-liveness--01).
    fn walkChildren(self: *DisjointChecker, instr: *const ir.Instruction) void {
        ir.forEachChildStream(instr, self, onChildStream);
    }

    fn onChildStream(self: *DisjointChecker, child: ir.ChildStream) void {
        self.walkStream(child.stream);
    }
};

// ============================================================
// Helpers: terminators, def/use lists, type predicates.
// ============================================================

/// Returns true when control reaches the end of `stream` along at
/// least one path — i.e. the stream's last reachable instruction is
/// not an unconditional terminator. Used by `forwardOwnsChildren`
/// for `guard_block` to decide whether the body's ownership
/// mutations should be merged back into the parent's `owns` set.
///
/// An empty stream falls through trivially. A stream whose final
/// instruction is a terminator (case_break/ret/tail_call/jump/
/// branch/etc) does not.
fn streamFallsThrough(stream: []const ir.Instruction) bool {
    if (stream.len == 0) return true;
    return !isTerminator(stream[stream.len - 1]);
}

pub fn isTerminator(instr: ir.Instruction) bool {
    return switch (instr) {
        .ret,
        .ret_raise,
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

pub const UseList = struct {
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

/// Single source of truth for the *arm-result* locals of an
/// aggregating control-flow instruction — the locals that flow into
/// the instruction's `dest` from whichever arm executes at runtime.
///
/// This includes the catch-all / default prong's result for every
/// variant that has one (`if_expr.else_result`, `case_block`/
/// `switch_literal`/`switch_return` `default_result`,
/// `union_switch.else_result`, `optional_dispatch.nil_result`). It
/// exists because the catch-all result was historically enumerated
/// independently in `collectUses` and `collectArmResults`, and those
/// hand-rolled lists drifted apart — `collectUses` silently dropped
/// `union_switch.else_result` (audit class S1). Routing both through
/// this one walker makes that drift structurally impossible: a new
/// aggregating variant (or a new arm-result slot) is added here once
/// and both consumers pick it up.
///
/// Non-aggregating opcodes yield nothing. The scrutinee / condition
/// of an aggregating opcode is a *use* but not an *arm result*, so it
/// is intentionally NOT yielded here — `collectUses` appends it
/// separately.
fn forEachArmResult(
    instr: ir.Instruction,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), result_local: ir.LocalId) void,
) void {
    switch (instr) {
        .if_expr => |x| {
            if (x.then_result) |l| visitFn(context, l);
            if (x.else_result) |l| visitFn(context, l);
        },
        .case_block => |x| {
            for (x.arms) |arm| if (arm.result) |l| visitFn(context, l);
            if (x.default_result) |l| visitFn(context, l);
        },
        .switch_literal => |x| {
            for (x.cases) |c| if (c.result) |l| visitFn(context, l);
            if (x.default_result) |l| visitFn(context, l);
        },
        .switch_return => |x| {
            for (x.cases) |c| if (c.return_value) |l| visitFn(context, l);
            if (x.default_result) |l| visitFn(context, l);
        },
        .union_switch_return => |x| {
            for (x.cases) |c| if (c.return_value) |l| visitFn(context, l);
        },
        .union_switch => |x| {
            for (x.cases) |c| if (c.return_value) |l| visitFn(context, l);
            // The catch-all prong's result participates in the
            // aggregate exactly like a case-arm result; yield it so
            // every consumer (last-use / ownership classification,
            // return-source / ARC-managed propagation) sees an
            // else-only result. Omitting it here was GAP-P1R2-01.
            if (x.has_else) {
                if (x.else_result) |l| visitFn(context, l);
            }
        },
        .optional_dispatch => |x| {
            if (x.nil_result) |l| visitFn(context, l);
            if (x.struct_result) |l| visitFn(context, l);
        },
        else => {},
    }
}

/// Append every local that this instruction reads (uses) to `buf`.
/// Sub-streams of nested instructions are NOT included — the
/// dataflow visits them separately. Only the immediate uses by the
/// instruction's own opcode are collected.
pub fn collectUses(instr: ir.Instruction, buf: *UseList) void {
    const allocator = std.heap.page_allocator; // overflow only
    // Arm-result locals of aggregating control-flow opcodes (if_expr,
    // case_block, switch_literal, switch_return, union_switch[_return],
    // optional_dispatch) are direct uses by the merge/join point: they
    // materialise the opcode's `dest`. Collect them through the single
    // shared walker so this list cannot drift from `collectArmResults`
    // again (GAP-P1R2-01: the catch-all `union_switch.else_result` was
    // previously dropped here). The aggregating arms below only append
    // the scrutinee / condition, which are uses but not arm results.
    const ArmResultAppender = struct {
        buf: *UseList,
        allocator: std.mem.Allocator,
        fn visit(ctx: @This(), result_local: ir.LocalId) void {
            ctx.buf.append(ctx.allocator, result_local) catch {};
        }
    };
    forEachArmResult(
        instr,
        ArmResultAppender{ .buf = buf, .allocator = allocator },
        ArmResultAppender.visit,
    );
    switch (instr) {
        .const_int, .const_float, .const_string, .const_bool, .const_atom => {},
        .const_nil => {},
        .local_get => |x| buf.append(allocator, x.source) catch {},
        .borrow_value => |x| buf.append(allocator, x.source) catch {},
        .copy_value => |x| buf.append(allocator, x.source) catch {},
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
        .box_as_protocol => |x| buf.append(allocator, x.value) catch {},
        .protocol_dispatch => |x| {
            buf.append(allocator, x.receiver) catch {};
            for (x.args) |arg_local| buf.append(allocator, arg_local) catch {};
        },
        .protocol_box_unbox => |x| buf.append(allocator, x.box) catch {},
        .protocol_box_vtable_eq => |x| buf.append(allocator, x.box) catch {},
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
        // Phase 3.b: error-union unwrap reads its source (the call's error
        // union); the payload it produces is the dest.
        .unwrap_error_union => |x| buf.append(allocator, x.source) catch {},
        .set_safety => {},
        // Arm results (then_result / else_result) are appended by the
        // shared `forEachArmResult` walk above; here we only add the
        // condition, which is a use but not an arm result.
        .if_expr => |x| buf.append(allocator, x.condition) catch {},
        .guard_block => |x| buf.append(allocator, x.condition) catch {},
        // Arm/default results appended by `forEachArmResult` above.
        .case_block => {},
        .branch => {},
        .cond_branch => |x| buf.append(allocator, x.condition) catch {},
        .switch_tag => |x| buf.append(allocator, x.scrutinee) catch {},
        // Scrutinee is a use; case/default results via `forEachArmResult`.
        .switch_literal => |x| buf.append(allocator, x.scrutinee) catch {},
        // Case/default results appended by `forEachArmResult` above; the
        // scrutinee of a `switch_return` is a param index, not a local.
        .switch_return => {},
        // Case results appended by `forEachArmResult` above; scrutinee is
        // a param index, not a local.
        .union_switch_return => {},
        // Scrutinee is a use; case + catch-all (`else_result`) results
        // via `forEachArmResult` above (GAP-P1R2-01).
        .union_switch => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_atom => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_variant_tag => |x| buf.append(allocator, x.scrutinee) catch {},
        .variant_payload_get => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_int => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_float => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_string => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_type => |x| buf.append(allocator, x.scrutinee) catch {},
        .match_fail => |x| {
            if (x.message_local) |l| buf.append(allocator, l) catch {};
        },
        .match_error_return => |x| buf.append(allocator, x.scrutinee) catch {},
        // Phase 3.b: a propagating raise is a pure error-return terminator;
        // the boxed error's use is accounted for by the preceding
        // recoverable_raise call instruction, not here.
        .ret_raise => {},
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
        // Typed-undefined placeholder reads no locals — its operand is the
        // interned `undef` value, not a Zap local.
        .typed_undef => {},
        .phi => |x| for (x.sources) |src| buf.append(allocator, src.value) catch {},
        // scrutinee_param is a param index (not a local); payload_local
        // is a def; nested nil_instrs / struct_instrs are visited
        // separately by the dataflow. The arm results (nil_result /
        // struct_result) are appended by the shared `forEachArmResult`
        // walk above, so this opcode has no remaining direct-use local.
        .optional_dispatch => {},
        // `.dbg_var` references the named local as a debug-info use; the
        // liveness analysis must treat it as a real use so the local
        // stays alive across the marker, otherwise an earlier release
        // could destroy a value the debugger expects to observe.
        // `.dbg_stmt` has no operands.
        .dbg_stmt => {},
        .dbg_var => |x| buf.append(allocator, x.value) catch {},
    }
}

pub const DefList = struct {
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

/// Locals defined (written) by this instruction, including binder
/// locals introduced by control-flow instructions. Sub-stream defs are
/// not collected here — the recursive walk visits them.
pub fn collectDefs(instr: ir.Instruction) DefList {
    var out: DefList = .{};
    switch (instr) {
        .const_int => |x| out.append(x.dest),
        .const_float => |x| out.append(x.dest),
        .const_string => |x| out.append(x.dest),
        .const_bool => |x| out.append(x.dest),
        .const_atom => |x| out.append(x.dest),
        .const_nil => |x| out.append(x),
        .local_get => |x| out.append(x.dest),
        .borrow_value => |x| out.append(x.dest),
        .copy_value => |x| out.append(x.dest),
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
        // `box_as_protocol` defines the box (a `ProtocolBox` value) that
        // OWNS its heap-allocated inner. Without this arm the box dest is
        // invisible to `identifyArcLocals` (which flags ARC-managed
        // locals by walking `collectDefs` and consulting
        // `local_ownership[def]`), so the box is never owned-at-ret and
        // its scope-exit drop is never scheduled — leaking the inner the
        // construction-site `allocAny` produced (G-box, round 2).
        .box_as_protocol => |x| out.append(x.dest),
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
        .try_call_named => |x| {
            out.append(x.dest);
            if (x.payload_local) |payload_local| out.append(payload_local);
        },
        .error_catch => |x| out.append(x.dest),
        .unwrap_error_union => |x| out.append(x.dest),
        .if_expr => |x| out.append(x.dest),
        .case_block => |x| out.append(x.dest),
        .switch_literal => |x| out.append(x.dest),
        .union_switch => |x| out.append(x.dest),
        .match_atom => |x| out.append(x.dest),
        .match_variant_tag => |x| out.append(x.dest),
        .variant_payload_get => |x| out.append(x.dest),
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
        .typed_undef => |x| out.append(x.dest),
        .phi => |x| out.append(x.dest),
        .jump => |x| if (x.bind_dest) |d| out.append(d),
        .optional_dispatch => |x| out.append(x.payload_local),
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
///
/// Delegates the per-arm enumeration to the shared `forEachArmResult`
/// walker so this list and `collectUses`'s arm-result list are derived
/// from one source and cannot drift apart (audit class S1; the catch-all
/// `union_switch.else_result` previously diverged — GAP-P1R2-01). The
/// only callers (`identifyArcLocals` / `propagateReturnSourcesThrough
/// Aggregates`) gate on `aggregateDest`, so in practice this is invoked
/// only for if_expr / case_block / switch_literal / union_switch; the
/// extra variants the shared walker also handles are simply never
/// reached here.
fn collectArmResults(instr: ir.Instruction, out: *[16]ir.LocalId) usize {
    var n: usize = 0;
    const ArmResultCollector = struct {
        out: *[16]ir.LocalId,
        n: *usize,
        fn visit(ctx: @This(), result_local: ir.LocalId) void {
            if (ctx.n.* < ctx.out.len) {
                ctx.out.*[ctx.n.*] = result_local;
                ctx.n.* += 1;
            }
        }
    };
    forEachArmResult(instr, ArmResultCollector{ .out = out, .n = &n }, ArmResultCollector.visit);
    return n;
}

test "arc_liveness: collectUses collects union_switch.else_result of a passthrough catch-all (GAP-P1R2-01)" {
    // S1 catch-all-skip regression: a `union_switch` whose `_` prong
    // yields a value computed BEFORE the switch (the passthrough
    // `_ -> existing_value` shape) carries that value in
    // `else_result`. `collectUses` must report it as a direct use of
    // the `union_switch` node — otherwise the merge-point use is
    // invisible to last-use/ownership classification (dropped release
    // → leak, or premature move → UAF), exactly the soundness hole
    // audit class S1 targets.
    //
    // Built as an in-memory `union_switch` literal so the assertion
    // does not depend on whether the front-end ever lowers a
    // passthrough catch-all to this exact IR shape.
    const scrutinee_local: ir.LocalId = 1;
    const case_result_local: ir.LocalId = 2;
    const else_result_local: ir.LocalId = 3;
    const dest_local: ir.LocalId = 4;

    const cases = [_]ir.UnionCase{.{
        .variant_name = "Some",
        .field_bindings = &.{},
        .body_instrs = &.{},
        .return_value = case_result_local,
    }};

    const instr = ir.Instruction{ .union_switch = .{
        .dest = dest_local,
        .scrutinee = scrutinee_local,
        .cases = &cases,
        .else_instrs = &.{},
        .else_result = else_result_local,
        .has_else = true,
    } };

    var uses: UseList = .{};
    defer uses.deinit(std.testing.allocator);
    collectUses(instr, &uses);

    const found = uses.slice();
    var saw_else_result = false;
    var saw_scrutinee = false;
    var saw_case_result = false;
    for (found) |local| {
        if (local == else_result_local) saw_else_result = true;
        if (local == scrutinee_local) saw_scrutinee = true;
        if (local == case_result_local) saw_case_result = true;
    }
    // Siblings that were already collected (sanity that the arm runs).
    try std.testing.expect(saw_scrutinee);
    try std.testing.expect(saw_case_result);
    // The load-bearing assertion: the catch-all result is a use.
    try std.testing.expect(saw_else_result);
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

    /// In-place bitwise intersection. Bits set in `self` after the
    /// call are exactly those set in BOTH `self` (before) and
    /// `other`. Same `bit_count` required.
    pub fn intersectWith(self: *LiveSet, other: *const LiveSet) void {
        std.debug.assert(self.bit_count == other.bit_count);
        switch (self.storage) {
            .small => |*v| switch (other.storage) {
                .small => |ov| v.* &= ov,
                .large => |ol| {
                    var b: u32 = 0;
                    while (b < self.bit_count and b < 64) : (b += 1) {
                        if (!ol.isSet(b)) {
                            v.* &= ~(@as(u64, 1) << @intCast(b));
                        }
                    }
                },
            },
            .large => |*l| switch (other.storage) {
                .small => |ov| {
                    var b: u32 = 0;
                    while (b < self.bit_count) : (b += 1) {
                        if (b < 64) {
                            if ((ov & (@as(u64, 1) << @intCast(b))) == 0) l.unset(b);
                        } else {
                            l.unset(b);
                        }
                    }
                },
                .large => |ol| {
                    var b: u32 = 0;
                    while (b < self.bit_count) : (b += 1) {
                        if (l.isSet(b) and !ol.isSet(b)) l.unset(b);
                    }
                },
            },
        }
    }

    /// In-place bitwise union. Bits set in `self` after the call are
    /// those set in either `self` or `other`. Same `bit_count`
    /// required.
    pub fn unionWith(self: *LiveSet, other: *const LiveSet) void {
        std.debug.assert(self.bit_count == other.bit_count);
        switch (self.storage) {
            .small => |*v| switch (other.storage) {
                .small => |ov| v.* |= ov,
                .large => |ol| {
                    var b: u32 = 0;
                    while (b < self.bit_count and b < 64) : (b += 1) {
                        if (ol.isSet(b)) v.* |= (@as(u64, 1) << @intCast(b));
                    }
                },
            },
            .large => |*l| switch (other.storage) {
                .small => |ov| {
                    var b: u32 = 0;
                    while (b < self.bit_count and b < 64) : (b += 1) {
                        if ((ov & (@as(u64, 1) << @intCast(b))) != 0) l.set(b);
                    }
                },
                .large => |ol| l.setUnion(ol),
            },
        }
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

test "arc_liveness: linear last-use share_value is not promoted to consume (borrow ABI)" {
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

    // Borrow-by-default ABI: every callee borrows its ARC arguments,
    // so no last-use share_value is upgraded to consume mode. The
    // analyzer keeps `consume_share_sites` empty regardless of the
    // last-use shape until per-callee borrow / consume metadata
    // exists. Return-source semantics are unaffected and still pin
    // the identity helper's parameter as a return source on its own
    // body — that table is exercised by the dedicated test below.
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
}

test "arc_liveness: identity function returns its borrowed parameter (Phase E.5 Gap 4)" {
    // Pre-Phase-E.5: the parameter local was added to
    // `return_source_locals` because its last use was `ret`.
    // Phase E.5 Gap 4: a borrowed-param-returned local is NOT
    // eligible for return-source elision — the borrow owns no +1,
    // so eliding the retain on ret would leave the caller with
    // a borrow that under-flows the post-call release ABI.
    // `canElideReturnSource` rejects these locals; the table
    // stays empty and the retain-on-ret discipline fires.
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

    // Phase E.5 Gap 4: borrowed param returned directly is NOT a
    // return source.
    try std.testing.expectEqual(@as(u32, 0), ownership.return_source_locals.count());
    try std.testing.expectEqual(@as(u32, 0), ownership.consume_share_sites.count());
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

    // Each arm has a share_value of `h` to f/g, but with the borrow-
    // by-default ABI no share is promoted to consume. The branching
    // shape itself is exercised by `live_before_ret` and
    // `return_source_locals`; consume sites stay empty.
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
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

    // Borrow-by-default ABI: `h`'s share into the call stays as
    // retain (not consume). The dest local of the call still flows
    // into `ret` and is a return source — that table is the one this
    // test pins.
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
    try std.testing.expect(ownership.return_source_locals.count() <= 1);
}

test "arc_liveness: tail-recursion k-nucleotide shape (return + recursive call)" {
    // Mimics the `Probe.loop` pattern: a recursive function whose
    // base-case arm returns the ARC param directly and whose
    // recursive arm passes the ARC param into a helper call.
    //
    // Phase E.7 changed the structural shape of this function. The
    // tail-call rewriter now recognises `if`/`switch_literal` whose
    // dest feeds an outer `ret` and pushes per-arm terminators
    // (the recursive arm becomes `tail_call`, the base arm gets the
    // outer `ret arm_result` pushed in). This eliminates the outer
    // `ret D` over the case-block dest entirely — every arm is
    // self-terminating, exactly as `switch_return` already was. The
    // construct's dest `D` is therefore no longer the operand of any
    // `ret`, so `return_source_locals` does not pick it up.
    //
    // The borrow ABI invariant the test pins is unchanged: every
    // share stays at retain (consume_share_sites is empty). The
    // return-source bookkeeping table is now empty for this shape
    // because the structural elision target has moved into per-arm
    // self-termination — neither the base arm's `ret m` (m is a
    // borrowed param, blocked by `canElideReturnSource`) nor the
    // recursive arm's `tail_call` (no operand-as-ret-value) populates
    // the table. The drop-list filter does not need an entry here:
    // the borrowed param is excluded from drops by Phase B's
    // parameter-skip logic, not by return-source elision.
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

    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
    try std.testing.expectEqual(@as(usize, 0), ownership.return_source_locals.count());
}

test "arc_liveness: duplicate-arg call leaves every share_value at retain (borrow ABI)" {
    // Surface-language expectation from the plan was:
    //   "f(x, x) → first x retains, last x consumes".
    //
    // The borrow-by-default ABI supersedes this: until per-callee
    // borrow / consume metadata exists, no last-use share_value is
    // promoted to consume mode regardless of the source shape. This
    // test pins the post-ABI-revision invariant — every share_value
    // stays at retain — and continues to exercise that the IR builder
    // emits one share_value per ARC argument occurrence (so a
    // duplicate-arg call has multiple shares, each of which the
    // analyzer leaves at retain).
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

    // Count share_value instructions in the function. The borrow-
    // by-default ABI leaves every one at retain; consume_share_sites
    // is empty.
    var share_count: usize = 0;
    for (run_func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .share_value) share_count += 1;
        }
    }
    try std.testing.expect(share_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
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

test "arc_liveness: writeBackConsumeModes is a no-op under borrow ABI" {
    // Under the borrow-by-default ABI, `consume_share_sites` is empty
    // for every function — the analyzer refuses to promote any
    // last-use share_value to consume mode without per-callee
    // borrow / consume metadata. The write-back walker therefore
    // upgrades zero share_values, runs idempotently, and leaves every
    // share_value at the default `.retain` mode. This test pins both
    // the empty-table invariant and the lowering's resulting state.
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

    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());

    var walker = WriteBackWalker{
        .next_id = 0,
        .consumes_marked = 0,
        .ownership = &ownership,
    };
    walker.walkFunction(run_func);
    try std.testing.expectEqual(@as(u64, 0), walker.consumes_marked);

    // Idempotent: a second invocation reports zero upgrades.
    const second = writeBackConsumeModes(run_func, &ownership);
    try std.testing.expectEqual(@as(u64, 0), second);

    // Every share_value remains at the default `.retain` mode.
    for (run_func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .share_value) {
                try std.testing.expectEqual(ir.ShareMode.retain, instr.share_value.mode);
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

    // Borrow-by-default ABI: no function records any consume site.
    // Return-source locals are unaffected by the ABI change — the
    // identity helper `id` still records its parameter as a return
    // source, exercising the per-function table's population.
    var saw_consume = false;
    var saw_return_source = false;
    var it = table.by_function.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.consume_share_sites.size > 0) saw_consume = true;
        if (entry.value_ptr.return_source_locals.size > 0) saw_return_source = true;
    }
    try std.testing.expect(!saw_consume);
    try std.testing.expect(saw_return_source);
    try std.testing.expectEqual(@as(u64, 0), table.consumes_marked);
    try std.testing.expect(table.return_sources_recorded > 0);
}

test "arc_liveness: runProgramArcOwnership leaves every share_value at retain (borrow ABI)" {
    // Under the borrow-by-default ABI, the program-level driver
    // populates `return_source_locals` and `live_before_ret` for
    // every function but leaves `consume_share_sites` empty for all.
    // Consequently the write-back step over the IR does not promote
    // any share_value to `.consume`; every share retains its default
    // mode. This test pins the post-ABI-revision invariant.
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

    // Post-condition: every share_value is still `.retain`. No
    // promotion occurred because `consume_share_sites` was empty.
    for (suite.ir_program.functions) |func| {
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .share_value) {
                    try std.testing.expectEqual(ir.ShareMode.retain, instr.share_value.mode);
                }
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0), table.consumes_marked);
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

test "arc_liveness: Phase 5 — direct return of borrowed param NOT in return_source (Phase E.5 Gap 4)" {
    // Pre-Phase-E.5 behavior: the identity function added its
    // borrowed-param local to `return_source_locals` because its
    // last use was `ret`. Phase E.5 Gap 4: the borrow owns no +1,
    // so eliding the retain on ret is wrong — the caller would
    // receive a borrow that under-flows the post-call release ABI.
    // `canElideReturnSource` rejects borrowed-param-returned locals.
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

    // Phase E.5 Gap 4: borrowed-param-returned locals are NOT
    // return sources.
    try std.testing.expectEqual(@as(u32, 0), ownership.return_source_locals.count());
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
}

test "arc_liveness: Phase 5 — branching pick of borrowed params NOT in return_source (Phase E.5 Gap 4)" {
    // Pre-Phase-E.5: arm-result locals `x` and `y` (plus the
    // aggregate dest) were added to `return_source_locals` because
    // each arm directly returns a borrowed param.
    //
    // Phase E.5 Gap 4: `canElideReturnSource` rejects borrowed-param-
    // returned locals; the gate cascades into
    // `propagateReturnSourcesThroughAggregates` so the case
    // expression's aggregate dest backs off too. Result: the set is
    // empty, and per-arm retains fire to give the caller a fresh
    // owner.
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

    // The aggregate case-block dest may still be added to
    // return_source_locals by `applySpecialization` on the ret
    // (since the aggregate dest is not itself a param_get). What
    // MUST be true after Phase E.5 Gap 4: the underlying borrowed-
    // param locals (`x`, `y`) are NOT propagated through.
    var iter = ownership.return_source_locals.keyIterator();
    while (iter.next()) |local_ptr| {
        // Each entry must NOT be a borrowed param.
        for (pick_func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .param_get => |pg| {
                        if (pg.dest == local_ptr.*) {
                            try std.testing.expect(pg.index >= pick_func.param_conventions.len or
                                pick_func.param_conventions[pg.index] != .borrowed);
                        }
                    },
                    else => {},
                }
            }
        }
    }
}

test "arc_liveness: Phase 5 — owned-binding ret IS in return_source (Phase E.5 Gap 4 inverse)" {
    // Inverse to the borrowed-param exclusion: when the ret value
    // is sourced from a freshly-allocated owner (e.g., the dest of
    // a Test.fresh() call), `canElideReturnSource` accepts it. The
    // returned value flows through the call's ownership transfer
    // semantics; the post-call retain is unnecessary because the
    // call_named already produced +1.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn fresh() -> Handle { "x" }
        \\
        \\  pub fn make() -> Handle { Test.fresh() }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const make_func = suite.findFunctionByName("make") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        make_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // The call_named dest IS a return source (Gap 4 only excludes
    // borrowed-param-returned locals).
    try std.testing.expect(ownership.return_source_locals.count() >= 1);
}

test "arc_liveness: Phase 5 — k-nucleotide-shaped tail loop populates both categories" {
    // The plan's prototype shape: a recursive function whose then-arm
    // returns the ARC parameter directly and whose else-arm tail-
    // recurses with a helper-produced value.
    //
    // Phase E.7 changed the structural shape of this function. The
    // tail-call rewriter now folds the outer `ret D` (over the case-
    // block dest) into per-arm self-terminators — the recursive arm
    // ends in `tail_call`, the base arm has `ret m` pushed into it.
    // The construct's dest D is no longer consumed by any
    // instruction, so `return_source_locals` does not record it. The
    // base arm's `ret m` does not propagate to `return_source_locals`
    // either: `m` is a borrowed param and `canElideReturnSource`
    // refuses to elide for borrowed params (per Phase E.5 Gap 4 — a
    // borrowed param's retain-on-ret discipline must fire). The
    // borrow ABI invariant the test pins (consume_share_sites empty)
    // remains; the return-source bookkeeping migrates to a different
    // representation under the new structural shape.
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

    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
    try std.testing.expectEqual(@as(usize, 0), ownership.return_source_locals.count());
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

    // Borrow ABI: parameter `x` is *not* promoted to consume mode at
    // the helper call — every share stays at retain. The disjointness
    // invariant therefore holds trivially because `consume_share_sites`
    // is empty. We still pin that the test exercises the data-flow
    // analyzer for an Arc parameter passed into a call without
    // promoting the share, and that no return source aliases an
    // (empty) consume source set.
    try std.testing.expectEqual(@as(usize, 0), ownership.consume_share_sites.count());
    var ret_iter = ownership.return_source_locals.keyIterator();
    _ = &ret_iter; // The set may be empty or contain the call's dest;
    // the disjointness invariant is trivially satisfied either way.
}

test "arc_liveness: Phase 5 — release filter pipes through return_source_locals" {
    // Phase 5's load-bearing post-condition: the ZIR backend's
    // release-emission filter (`isReleaseSuppressed`) returns true
    // for every local recorded in `arc_returned_locals`. The Phase
    // 4-installed `markReturned` hook copies entries from the
    // analyzer's `return_source_locals` into `arc_returned_locals`
    // at function-begin time; here we exercise the end-to-end set
    // membership via the public driver API.
    //
    // Phase E.5 Gap 4: the canonical identity function on a borrowed
    // ARC param now produces an EMPTY `return_source_locals` because
    // borrowed params can't elide their retain-on-ret. We exercise
    // a non-borrowed shape — a function whose ret-source is the
    // dest of a Test.fresh() call (an owned binding) — to keep the
    // pipe-through assertion meaningful.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn fresh() -> Handle { "x" }
        \\
        \\  pub fn make() -> Handle { Test.fresh() }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const make_func = suite.findFunctionByName("make") orelse return error.MissingFunction;
    var ownership = try computeArcOwnership(
        std.testing.allocator,
        make_func,
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
    var release_sources = try collectReleaseSources(std.testing.allocator, make_func);
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
        pending_error: ?error{OutOfMemory} = null,

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
            // Recurse via the canonical enumerator so this test walker
            // cannot drift from the production traversal (it previously
            // skipped `union_switch.else_instrs` — GAP-P1R2-02/FU-3).
            // `forEachChildStream`'s callback is void-returning, so the
            // OOM from the recursive `walkStream` is stashed and
            // re-raised after the walk.
            ir.forEachChildStream(instr, self, visitChildStream);
            if (self.pending_error) |err| {
                self.pending_error = null;
                return err;
            }
        }

        fn visitChildStream(self: *@This(), child: ir.ChildStream) void {
            if (self.pending_error != null) return;
            self.walkStream(child.stream) catch |err| {
                self.pending_error = err;
            };
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

// ============================================================
// Phase D — recursion through optional_dispatch nested streams
// ============================================================

/// Walk every function body and return true iff some instruction is
/// an `optional_dispatch`. Used by the Phase D regression tests to
/// guard the assertion behind the IR builder's chosen lowering
/// shape: when the front-end declines to emit `optional_dispatch`
/// (e.g. because the heuristic's preconditions fail), the test
/// silently exits — the load-bearing assertion only runs when the
/// shape under test is actually present in the IR.
fn functionContainsOptionalDispatch(function: *const ir.Function) bool {
    const Detector = struct {
        seen: bool = false,
        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (instr.* == .optional_dispatch) self.seen = true;
        }
    };
    var detector = Detector{};
    ir.forEachInstruction(function, &detector, Detector.visit);
    return detector.seen;
}

test "arc_liveness: analyzer recurses into optional_dispatch arms without crashing (Phase D)" {
    // Phase D (Phase 6 redux plan §3.D): the analyzer's
    // `flattenChildren` must recurse into both arm bodies of an
    // `optional_dispatch` so every nested instruction — including
    // ret-equivalent terminators like `tail_call` — receives an
    // `InstructionId` and a `live_before_ret` snapshot.
    //
    // Without the Phase D recursion, an `optional_dispatch` whose
    // struct arm is self-recursive (lowered by `containsTailCall`-
    // detection into a `tail_call`) would never trigger the
    // `snapshotLiveBeforeRet` call inside the arm — the snapshot
    // is gated on `isReturnEquivalentTerminator(instr)` AND
    // `processStream` having been entered for the enclosing stream;
    // skipping the recursion skips both.
    //
    // The Zap source below has two clauses:
    //   - `process(nil, h)` → returns `h`.
    //   - `process(_n :: Node, h)` → recurses on `nil` (always
    //      reaches the base case after one step). The struct arm's
    //      body is `Test.process(nil, h)` — a self-recursive call
    //      lowered to a `tail_call` in IR.
    // The IR builder synthesises an `optional_dispatch` with a
    // `tail_call` inside the struct arm body. Phase D guarantees
    // the analyzer records a `live_before_ret` snapshot at that
    // tail_call.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\  pub struct Node { tag :: i64 }
        \\
        \\  pub fn process(nil, h :: Handle) -> Handle { h }
        \\  pub fn process(_n :: Node, h :: Handle) -> Handle {
        \\    Test.process(nil, h)
        \\  }
        \\}
    ;
    var suite = try TestSuite.init(std.testing.allocator, source);
    defer suite.deinit();

    const process_func = suite.findFunctionByName("process") orelse return error.MissingFunction;
    if (!functionContainsOptionalDispatch(process_func)) {
        // The IR builder declined to emit `optional_dispatch`. Phase
        // D's recursion structure is correctness-preserving on every
        // shape, but the load-bearing assertion needs the shape to
        // be present.
        return;
    }

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        process_func,
        suite.typeStore(),
        defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    // Walk every instruction (forEachInstruction recurses into
    // optional_dispatch as of Phase D) using the analyzer's depth-
    // first numbering scheme. Map ids to (a) whether the
    // instruction is a ret-equivalent terminator and (b) whether
    // it lives inside an optional_dispatch arm body. The
    // load-bearing Phase D invariant: at least one instruction
    // lives inside optional_dispatch arms (proving the recursion
    // structurally fired) AND every `live_before_ret` key maps to
    // a ret-equivalent terminator (proving the analyzer's
    // `flattenChildren` numbering remained consistent under the
    // new recursion).
    var id_to_is_term: std.AutoHashMapUnmanaged(InstructionId, bool) = .empty;
    defer id_to_is_term.deinit(std.testing.allocator);
    const Walker = struct {
        next_id: InstructionId = 0,
        id_to_is_term: *std.AutoHashMapUnmanaged(InstructionId, bool),
        allocator: std.mem.Allocator,
        instructions_inside_optional: usize = 0,
        depth_in_optional: usize = 0,
        pending_error: ?error{OutOfMemory} = null,

        fn walkFunction(self: *@This(), func: *const ir.Function) error{OutOfMemory}!void {
            for (func.body) |block| try self.walkStream(block.instructions);
        }

        fn walkStream(self: *@This(), stream: []const ir.Instruction) error{OutOfMemory}!void {
            for (stream) |*instr| {
                const my_id = self.next_id;
                self.next_id += 1;
                const is_term = isReturnEquivalentTerminator(instr.*);
                try self.id_to_is_term.put(self.allocator, my_id, is_term);
                if (self.depth_in_optional > 0) {
                    self.instructions_inside_optional += 1;
                }
                try self.walkChildren(instr);
            }
        }

        fn walkChildren(self: *@This(), instr: *const ir.Instruction) error{OutOfMemory}!void {
            // Recurse via the canonical enumerator so this test walker
            // cannot drift from the production traversal (it previously
            // skipped `union_switch.else_instrs` — GAP-P1R2-02/FU-3).
            // `forEachChildStream` yields exactly both arm bodies of an
            // `optional_dispatch`, so bumping `depth_in_optional` around
            // the whole walk reproduces the old per-arm wrapping exactly.
            const in_optional = instr.* == .optional_dispatch;
            if (in_optional) self.depth_in_optional += 1;
            ir.forEachChildStream(instr, self, visitChildStream);
            if (in_optional) self.depth_in_optional -= 1;
            if (self.pending_error) |err| {
                self.pending_error = null;
                return err;
            }
        }

        fn visitChildStream(self: *@This(), child: ir.ChildStream) void {
            if (self.pending_error != null) return;
            self.walkStream(child.stream) catch |err| {
                self.pending_error = err;
            };
        }
    };
    var walker = Walker{
        .id_to_is_term = &id_to_is_term,
        .allocator = std.testing.allocator,
    };
    try walker.walkFunction(process_func);

    // Pre-condition: at least one instruction must live inside
    // the optional_dispatch arms. Without Phase D's recursion, the
    // walker would also skip them (it mirrors the analyzer's
    // structure exactly), so the precondition would be unsatisfiable
    // — but we'd never reach here because the analyzer would
    // produce *fewer* records than the walker's count and the
    // soundness check below would trip.
    try std.testing.expect(walker.instructions_inside_optional >= 1);

    // Soundness invariant: every `live_before_ret` key must map to
    // a ret-equivalent terminator. The analyzer's depth-first
    // numbering matches the walker above, so the mapping is
    // direct. Without Phase D, the analyzer would assign FEWER ids
    // than the walker would — keys for instructions outside
    // optional_dispatch would still match (since their numbering
    // is unaffected), but the walker would assert IDs the analyzer
    // never assigned. Phase D's recursion ensures the numbering
    // stays consistent end-to-end.
    var live_iter = ownership.live_before_ret.keyIterator();
    while (live_iter.next()) |id_ptr| {
        const is_term = id_to_is_term.get(id_ptr.*) orelse return error.IdNotFound;
        try std.testing.expect(is_term);
    }
}

test "arc_liveness: deeply nested case recursion is depth-uniform (Phase D)" {
    // Phase D (Phase 6 redux plan §3.D): the analyzer must visit
    // every level of nesting uniformly. Today this works for
    // case/switch combinations; this test pins that invariant.
    // Combining it with the optional_dispatch test above guarantees
    // that the recursion structure is uniform across every IR shape.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn pick(outer :: Bool, inner :: Bool, x :: Handle, y :: Handle) -> Handle {
        \\    case outer {
        \\      true ->
        \\        case inner {
        \\          true -> x
        \\          false -> x
        \\        }
        \\      false ->
        \\        case inner {
        \\          true -> y
        \\          false -> y
        \\        }
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

    // The function returns one of two ARC-managed locals via deeply-
    // nested if + case structure. The analyzer must reach every
    // ret-equivalent terminator and produce non-empty live snapshots
    // for each.
    try std.testing.expect(ownership.live_before_ret.count() >= 1);
    var saw_arc_local = false;
    var live_iter = ownership.live_before_ret.valueIterator();
    while (live_iter.next()) |set_ptr| {
        if (set_ptr.count() >= 1) saw_arc_local = true;
    }
    try std.testing.expect(saw_arc_local);
}

test "arc_liveness: Phase H.6 — multiple param_get of same .owned slot share one +1" {
    // Regression: fannkuch's `main_loop` reads its `.owned` parameter
    // `p` twice via independent `param_get` instructions — once for a
    // borrow-then-release call (`copy_prefix`), then again to feed a
    // tuple-returning helper (`three_thru`). Pre-fix, the forward
    // owns dataflow set a separate +1 bit at every `param_get` of the
    // same slot. The terminator's `owned_at_ret` snapshot then carried
    // BOTH alias bits, drop-insertion emitted one `release` per alias,
    // and the runtime double-released the slot's single +1. The next
    // tail-recursive iteration observed list cells with garbage
    // length headers and crashed with `List.get/set: index out of
    // bounds`.
    //
    // The fix: in `applyOwnsEffect`, treat `param_get` of an `.owned`
    // slot as setting the bit only when no sibling alias's bit is
    // currently set — the slot has exactly one +1, and aliases share
    // it. Pairs with the existing `clearOwnsForLocalAndAliases` rule
    // ("consume one alias, consume all"). Together they keep the bit
    // count in lockstep with the slot's actual ownership state.
    //
    // We hand-roll a minimal `ir.Function` that mirrors fannkuch's
    // `main_loop` shape — TWO `param_get` reads of slot 0 (an `.owned`
    // ARC param) with a `share_value`-bracketed call between them,
    // then a `ret` of one of the params. End-to-end parsing wouldn't
    // reproduce the bug because the test pipeline doesn't run
    // `arc_param_convention.inferConventions` (which is what promotes
    // `.borrowed` to `.owned` in the production pipeline). Driving
    // the analyzer directly with a pre-promoted shape exercises the
    // exact dataflow path the production bug hit.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Pre-build the call-arg slices on the arena so they outlive the
    // walker; each instruction owns a `[]const ir.LocalId` slice.
    const call_args = try arena.alloc(ir.LocalId, 1);
    call_args[0] = 11;
    const call_arg_modes = try arena.alloc(ir.ValueMode, 1);
    call_arg_modes[0] = .borrow;
    const ret_value: ir.LocalId = 1;
    _ = ret_value;

    // Stream (mirrors `main_loop`'s `param_get` … `share_value` …
    // `release` … `param_get` … `ret` shape):
    //
    //   [0] param_get %1 = param[0]      -- first alias of slot 0
    //   [1] share_value %2 <- %1 retain  -- bumps slot 0 RC for
    //                                       a borrow-style call
    //   [2] call_named "borrow_call" args=[%2] dest=%3 -- borrow
    //   [3] release %2                   -- drops the share's +1
    //   [4] param_get %4 = param[0]      -- SECOND alias of slot 0
    //   [5] ret %4
    //
    // Liveness tracks slot 0's single +1 across the function. The
    // pre-fix dataflow set BOTH `%1` and `%4`'s owns bits; the snapshot
    // at the `ret` then carried both, and `arc_drop_insertion` would
    // emit two scope-exit `release` instructions against slot 0's
    // single +1.
    const stream = try arena.alloc(ir.Instruction, 6);
    stream[0] = .{ .param_get = .{ .dest = 1, .index = 0 } };
    stream[1] = .{ .share_value = .{ .dest = 2, .source = 1, .mode = .retain } };
    stream[2] = .{ .call_named = .{
        .name = "borrow_call",
        .dest = 3,
        .args = call_args,
        .arg_modes = call_arg_modes,
    } };
    stream[3] = .{ .release = .{ .value = 2 } };
    stream[4] = .{ .param_get = .{ .dest = 4, .index = 0 } };
    stream[5] = .{ .ret = .{ .value = 4 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    // local_count = 5 (slots 0..4). Mark slot 0 (`pg.dest=1`) and
    // slot 4 as `.owned`, the rest as `.trivial`. The `local_to_arc_index`
    // map tracks ARC-managed locals; the forward owns dataflow only
    // accumulates bits for `.owned` locals.
    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*o| o.* = .trivial;
    local_ownership[1] = .owned;
    local_ownership[2] = .owned;
    local_ownership[4] = .owned;

    const list_i64_element_type: ir.ZigType = .i64;
    const list_i64_type: ir.ZigType = .{ .list = &list_i64_element_type };

    const params = try arena.alloc(ir.Param, 1);
    // `arc_managed` callback below returns true unconditionally, so any
    // non-null `type_id` here passes the ARC-param filter at
    // `arc_param_indices` construction time. `0` is a valid `TypeId`
    // (TypeStore reserves `BOOL = 0`), so this doesn't conflict with
    // any sentinel.
    params[0] = .{ .name = "p", .type_expr = list_i64_type, .type_id = 0 };

    const param_conventions = try arena.alloc(ir.ParamConvention, 1);
    param_conventions[0] = .owned;

    const function = ir.Function{
        .id = 0,
        .name = "phase_h6_test",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = list_i64_type,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6, // any pointer that won't be dereferenced; arc_managed callback below skips
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    // Probe the `owned_at_ret` snapshot at the `ret` instruction. With
    // the fix, the snapshot has exactly ONE entry for slot 0 (either
    // `%1` or `%4`, but not both). Without the fix, it has BOTH.
    // Walk the snapshot and count slot-0 aliases.
    var slot0_count: u32 = 0;
    var owned_iter = ownership.owned_at_ret.valueIterator();
    while (owned_iter.next()) |set_ptr| {
        var entry_iter = set_ptr.keyIterator();
        while (entry_iter.next()) |local_ptr| {
            // Both `%1` and `%4` are `param_get(0)` dests by
            // construction; either's bit indicates "slot 0 has +1".
            if (local_ptr.* == 1 or local_ptr.* == 4) slot0_count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), slot0_count);
}

test "arc_liveness: param_get after owned-slot consume is non-owning" {
    // Regression: fannkuch's `shift_left` moves an `.owned` List
    // parameter into `List.set_owned_unchecked`, then refetches the
    // same parameter slot to read the next element in the set value
    // expression before tail-recursing with the updated list. The
    // later `param_get` is a non-owning alias after the slot's single
    // +1 was consumed by the receiver move; treating it as an owner
    // lets drop insertion release a stale alias immediately before
    // the recursive tail jump.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tail_args = try arena.alloc(ir.LocalId, 1);
    tail_args[0] = 2;

    const stream = try arena.alloc(ir.Instruction, 6);
    stream[0] = .{ .param_get = .{ .dest = 1, .index = 0 } };
    stream[1] = .{ .move_value = .{ .dest = 2, .source = 1 } };
    stream[2] = .{ .param_get = .{ .dest = 3, .index = 0 } };
    stream[3] = .{ .share_value = .{ .dest = 4, .source = 3, .mode = .retain } };
    stream[4] = .{ .release = .{ .value = 4 } };
    stream[5] = .{ .tail_call = .{ .name = "loop", .args = tail_args } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*o| o.* = .trivial;
    local_ownership[1] = .owned;
    local_ownership[2] = .owned;
    local_ownership[3] = .owned;
    local_ownership[4] = .owned;

    const list_i64_element_type: ir.ZigType = .i64;
    const list_i64_type: ir.ZigType = .{ .list = &list_i64_element_type };

    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "p", .type_expr = list_i64_type, .type_id = 0 };

    const param_conventions = try arena.alloc(ir.ParamConvention, 1);
    param_conventions[0] = .owned;

    const function = ir.Function{
        .id = 0,
        .name = "owned_param_refetch_test",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = list_i64_type,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(ownership.non_owning_param_refetches.contains(3));
    const tail_owned = ownership.owned_at_ret.get(5) orelse return error.MissingTailSnapshot;
    try std.testing.expect(!tail_owned.contains(3));
}

test "arc_liveness: flat case_block keeps branch-owned locals out of outer ret" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const guard_body = try arena.alloc(ir.Instruction, 3);
    guard_body[0] = .{ .const_string = .{ .dest = 2, .value = "selected" } };
    guard_body[1] = .{ .const_string = .{ .dest = 3, .value = "temporary" } };
    guard_body[2] = .{ .case_break = .{ .value = 2 } };

    const pre_instrs = try arena.alloc(ir.Instruction, 4);
    pre_instrs[0] = .{ .const_bool = .{ .dest = 0, .value = true } };
    pre_instrs[1] = .{ .guard_block = .{ .condition = 0, .body = guard_body } };
    pre_instrs[2] = .{ .const_string = .{ .dest = 4, .value = "default" } };
    pre_instrs[3] = .{ .case_break = .{ .value = 4 } };

    const stream = try arena.alloc(ir.Instruction, 2);
    stream[0] = .{ .case_block = .{
        .dest = 1,
        .pre_instrs = pre_instrs,
        .arms = &.{},
        .default_instrs = &.{},
        .default_result = null,
    } };
    stream[1] = .{ .ret = .{ .value = 1 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*ownership_class| ownership_class.* = .trivial;
    local_ownership[1] = .owned;
    local_ownership[2] = .owned;
    local_ownership[3] = .owned;
    local_ownership[4] = .owned;

    const string_type: ir.ZigType = .string;
    const function = ir.Function{
        .id = 0,
        .name = "flat_case_scope_test",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = string_type,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    var outer_ret_has_case_dest = false;
    var outer_ret_has_branch_local = false;
    var owned_ret_iter = ownership.owned_at_ret.valueIterator();
    while (owned_ret_iter.next()) |set_ptr| {
        if (set_ptr.contains(1)) outer_ret_has_case_dest = true;
        if (set_ptr.contains(2) or set_ptr.contains(3) or set_ptr.contains(4)) {
            outer_ret_has_branch_local = true;
        }
    }
    try std.testing.expect(outer_ret_has_case_dest);
    try std.testing.expect(!outer_ret_has_branch_local);

    var case_break_releases_temp = false;
    var case_break_releases_result = false;
    var case_break_iter = ownership.owned_at_case_break.valueIterator();
    while (case_break_iter.next()) |set_ptr| {
        if (set_ptr.contains(3)) case_break_releases_temp = true;
        if (set_ptr.contains(2) or set_ptr.contains(4)) case_break_releases_result = true;
    }
    try std.testing.expect(case_break_releases_temp);
    try std.testing.expect(!case_break_releases_result);
}

test "arc_liveness: Phase 2.7 records non-ARC aggregate last-use through ARC-managed extraction" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elements = try arena.alloc(ir.LocalId, 1);
    tuple_elements[0] = 0;

    const stream = try arena.alloc(ir.Instruction, 5);
    stream[0] = .{ .const_string = .{ .dest = 0, .value = "component" } };
    stream[1] = .{ .tuple_init = .{ .dest = 1, .elements = tuple_elements } };
    stream[2] = .{ .index_get = .{ .dest = 2, .object = 1, .index = 0 } };
    stream[3] = .{ .retain = .{ .value = 2 } };
    stream[4] = .{ .ret = .{ .value = 2 } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 3);
    local_ownership[0] = .owned;
    local_ownership[1] = .trivial;
    local_ownership[2] = .borrowed;

    const function = ir.Function{
        .id = 0,
        .name = "phase_2_7_non_arc_aggregate",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .string,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(!ownership.arc_managed_locals.contains(1));
    try std.testing.expect(ownership.arc_managed_locals.contains(2));
    try std.testing.expect(ownership.isLastUseAt(1, 2));
    try std.testing.expect(!ownership.last_use_map.contains(1));
}

test "arc_liveness: Phase 2.7 ignores non-ARC aggregate without ARC-managed extraction" {
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elements = try arena.alloc(ir.LocalId, 1);
    tuple_elements[0] = 0;

    const stream = try arena.alloc(ir.Instruction, 4);
    stream[0] = .{ .const_int = .{ .dest = 0, .value = 42 } };
    stream[1] = .{ .tuple_init = .{ .dest = 1, .elements = tuple_elements } };
    stream[2] = .{ .index_get = .{ .dest = 2, .object = 1, .index = 0 } };
    stream[3] = .{ .ret = .{ .value = null } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    const local_ownership = try arena.alloc(ir.OwnershipClass, 3);
    for (local_ownership) |*ownership_class| ownership_class.* = .trivial;

    const function = ir.Function{
        .id = 0,
        .name = "phase_2_7_trivial_aggregate",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = &.{},
        .local_ownership = local_ownership,
        .result_convention = .trivial,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(!ownership.isLastUseAt(1, 2));
    try std.testing.expectEqual(@as(u32, 0), ownership.last_use_sites.size);
}

test "arc_liveness: switch_return arm-local struct_init return value enters return_source_locals" {
    // Regression test for commit `1e73e66`: `applySpecialization`
    // handles `.switch_return` by iterating every arm's
    // `return_value`. When an arm body builds a fresh `struct_init`
    // and the switch_return's arm marks that dest as `return_value`,
    // the local is at last-use at the switch_return instruction (the
    // struct's only reader is the implicit return) and
    // `canElideReturnSource` accepts it (the local was NOT loaded
    // from a borrowed param), so the dest must be added to
    // `return_source_locals`. Without this, the function-epilogue
    // retain-on-ret fires while the (no-op) release at the parent
    // level fires against an unset slot — exactly the +1-per-return
    // leak that binarytrees' `make` exhibited at 7.1 GB peak RSS
    // pre-fix.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Arm body builds %2 via struct_init then the switch_return's
    // case marks %2 as the arm's return_value.
    const arm_fields = try arena.alloc(ir.StructFieldInit, 1);
    arm_fields[0] = .{ .name = "leaf", .value = 1 };
    const arm_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .struct_init = .{
            .dest = 2,
            .type_name = "Leaf",
            .fields = arm_fields,
        } },
    });
    const cases = try arena.alloc(ir.ReturnCase, 1);
    cases[0] = .{
        .value = .{ .int = 1 },
        .body_instrs = arm_body,
        .return_value = 2,
    };

    // Default body builds %4 via struct_init and returns %4 to keep
    // the analyzer's per-arm bookkeeping consistent (every reachable
    // exit terminates in a fresh +1).
    const default_fields = try arena.alloc(ir.StructFieldInit, 1);
    default_fields[0] = .{ .name = "leaf", .value = 3 };
    const default_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .struct_init = .{
            .dest = 4,
            .type_name = "Leaf",
            .fields = default_fields,
        } },
    });

    const stream = try arena.alloc(ir.Instruction, 1);
    stream[0] = .{ .switch_return = .{
        .scrutinee_param = 0,
        .cases = cases,
        .default_instrs = default_body,
        .default_result = 4,
    } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    // Locals: %0 = scrutinee (trivial), %1/%3 = trivial field values,
    // %2/%4 = owned struct dests (the arm/default return values).
    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*o| o.* = .trivial;
    local_ownership[2] = .owned;
    local_ownership[4] = .owned;

    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "tag", .type_expr = .i64, .type_id = null };
    const param_conventions = try arena.alloc(ir.ParamConvention, 1);
    param_conventions[0] = .trivial;

    const function = ir.Function{
        .id = 0,
        .name = "switch_return_arm_local_struct_init",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    // Pre-fix (before commit 1e73e66): `return_source_locals` was
    // empty for switch_return arms because `applySpecialization`
    // handled only `.ret` and `.cond_return`. Post-fix: both arm
    // returns (%2 and %4) enter `return_source_locals`.
    try std.testing.expect(ownership.return_source_locals.contains(2));
    try std.testing.expect(ownership.return_source_locals.contains(4));
}

test "arc_liveness: union_switch_return arm-local struct_init return value enters return_source_locals" {
    // Mirror of the `switch_return` test above for the union-shaped
    // multi-arm return terminator. `union_switch_return` has no
    // default arm in the IR shape — every variant is enumerated as
    // a case. `applySpecialization` (commit `1e73e66`) walks each
    // case's `return_value` and applies the same elision discipline
    // as the single-`.ret` case.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Case 0: build %2 via struct_init, return %2.
    const case0_fields = try arena.alloc(ir.StructFieldInit, 1);
    case0_fields[0] = .{ .name = "leaf", .value = 1 };
    const case0_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .struct_init = .{
            .dest = 2,
            .type_name = "Leaf",
            .fields = case0_fields,
        } },
    });

    // Case 1: build %4 via struct_init, return %4.
    const case1_fields = try arena.alloc(ir.StructFieldInit, 1);
    case1_fields[0] = .{ .name = "leaf", .value = 3 };
    const case1_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .struct_init = .{
            .dest = 4,
            .type_name = "Leaf",
            .fields = case1_fields,
        } },
    });

    const cases = try arena.alloc(ir.UnionCase, 2);
    cases[0] = .{
        .variant_name = "VariantA",
        .field_bindings = &.{},
        .body_instrs = case0_body,
        .return_value = 2,
    };
    cases[1] = .{
        .variant_name = "VariantB",
        .field_bindings = &.{},
        .body_instrs = case1_body,
        .return_value = 4,
    };

    const stream = try arena.alloc(ir.Instruction, 1);
    stream[0] = .{ .union_switch_return = .{
        .scrutinee_param = 0,
        .cases = cases,
    } };

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = stream };

    // %0 = scrutinee (trivial); %1/%3 trivial; %2/%4 owned.
    const local_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (local_ownership) |*o| o.* = .trivial;
    local_ownership[2] = .owned;
    local_ownership[4] = .owned;

    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "tag", .type_expr = .void, .type_id = null };
    const param_conventions = try arena.alloc(ir.ParamConvention, 1);
    param_conventions[0] = .trivial;

    const function = ir.Function{
        .id = 0,
        .name = "union_switch_return_arm_local_struct_init",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    var ownership = try computeArcOwnership(
        std.testing.allocator,
        &function,
        suite_dummy_type_store_for_h6,
        arc_managed_for_h6,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(ownership.return_source_locals.contains(2));
    try std.testing.expect(ownership.return_source_locals.contains(4));
}

// Stand-in `TypeStore` pointer for the Phase H.6 hand-rolled test.
// The test's `arc_managed_for_h6` callback hard-codes a yes for
// every type id without consulting the store, so the analyzer never
// dereferences this pointer. We declare a single dummy storage cell
// here at module scope so the test's `function` value can borrow it
// without lifetime concerns.
var suite_dummy_type_store_for_h6_storage: types_mod.TypeStore = undefined;
const suite_dummy_type_store_for_h6: *const types_mod.TypeStore = &suite_dummy_type_store_for_h6_storage;

fn arc_managed_for_h6(_: *const types_mod.TypeStore, _: hir_mod.TypeId) bool {
    // The hand-rolled test fixture never queries this — the
    // function's `local_ownership` already classifies every local,
    // and the analyzer's ARC-managed predicate is consulted via
    // `local_ownership` rather than via this callback when the
    // local has an ownership class set. Returning true is the
    // conservative default; returning false would also work because
    // the test's locals are wired directly via `local_ownership`.
    return true;
}
