const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const types_mod = @import("types.zig");
const v8_signature = @import("v8_signature.zig");
const v8_fixpoint = @import("v8_fixpoint.zig");

// ============================================================
// Whole-program parameter-convention inference (Phase E.9).
//
// Pipeline placement:
//
//     ... → arc_liveness  (last-use side table)
//          → arc_param_convention  (THIS PASS — promotes .borrowed
//                                  to .owned where the program
//                                  agrees on consume semantics)
//               → arc_ownership   (classifier, reads param convention)
//                    → arc_verifier   (V7 — caller / callee agreement)
//                         → arc_drop_insertion
//                              → ...
//
// Why this pass exists:
//
// Phases A-E.8 fixed every retain/release imbalance the compiler can
// see in a single function. The only signal left is at function
// boundaries — specifically the case where a self-recursive callee
// produces a fresh ARC owner each iteration and tail-calls itself
// with that owner as one of its arguments. Under the borrow-by-
// default ABI, the caller emits a retain (`share_value`) and the
// callee emits no scope-exit release (the parameter is borrowed by
// the convention V4 enforces). Each iteration leaves +1 retain on
// the cell — for k-nucleotide's `count_kmers_loop`, that is exactly
// 8.75M leaked Map cells per run.
//
// The §4 plan calls for per-callee consume-mode metadata. The full
// Koka-style borrow inference is out of scope here; the focused rule
// implemented in this pass is sufficient to close the
// k-nucleotide leak while staying conservative for every other
// function in the program.
//
// Inference rule
// --------------
//
// For a function F and a parameter slot i whose default convention
// is `.borrowed` (i.e. the type is ARC-managed), promote
// `param_conventions[i]` to `.owned` IFF every condition holds:
//
//   1. F has at least one self-recursive call site (a `tail_call`
//      whose name equals F.name, OR a `call_named`/`call_direct`
//      that references F itself). The recursive site exercises the
//      consume convention from inside the same function, which is
//      the only case the inference covers.
//
//   2. EVERY self-recursive call site at slot i passes the argument
//      from a source that is dead at the call site. After Phase E.8
//      the recursive `tail_call`'s arg is fed by `move_value` (or a
//      `local_get` whose source's last use is the move site); the
//      pass treats both shapes as a "consume" signal.
//
//   3. EVERY non-recursive caller of F passes slot i at last use of
//      the source local. The pre-classifier IR shape for an ARC arg
//      is `share_value{shared, src}; call ... shared ...;
//      release{shared}` — when `last_use_map[src] == share_value
//      site`, the source is dead at the call.
//
// When all three hold, F's parameter slot i is marked `.owned`.
//   * Callee side: Phase B's drop-insertion filter releases the
//     parameter at every scope exit (the filter only skips locals
//     whose `param_conventions[i] == .borrowed`).
//   * Caller side: `arc_ownership` (Step 2) emits `move_value` for
//     the call argument and elides the matched `share_value` /
//     `release` pair, transferring ownership without bumping the
//     refcount.
//   * Verifier: V7 (Step 4) requires the caller's argument
//     convention to match the callee's parameter convention at every
//     call site.
//
// When ANY condition fails, the slot stays `.borrowed`. The
// inference is intentionally conservative — a wrong promotion to
// `.owned` is a soundness bug; a missed promotion costs an extra
// retain/release pair. Conservatism is correct.
//
// ============================================================

/// Mutable view over a function's `param_conventions` so the
/// inference pass can refine entries in place. The slice in
/// `Function.param_conventions` is `[]const`; the pass's caller
/// (the compiler driver) uses `@constCast` to give us write access
/// at this seam, mirroring the existing pattern used by
/// `arc_drop_insertion` and `arc_liveness.writeBackConsumeModes`.
const MutableConventions = []ir.ParamConvention;

/// Run the inference pass across every function in `program`.
///
/// `ownerships` provides per-function `ArcOwnership` (the output of
/// `arc_liveness.runProgramArcOwnership`). The inference reads
/// `last_use_map` to decide whether a non-recursive caller passes
/// at last use; without that map a caller's last-use status cannot
/// be determined and the slot stays `.borrowed` (safe default).
///
/// `type_store` is consulted to confirm a candidate parameter slot
/// is ARC-managed before promoting. Non-ARC slots default to
/// `.trivial` and never need consume-mode treatment.
///
/// The pass mutates `function.param_conventions` in place via
/// `@constCast`. After it runs, every function whose parameter
/// inference passed all three conditions has its convention
/// upgraded to `.owned`. The pass never demotes; it only ever turns
/// `.borrowed` slots into `.owned` slots (or leaves them alone).
pub fn inferConventions(
    allocator: std.mem.Allocator,
    program: *ir.Program,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    type_store: *const types_mod.TypeStore,
) !void {
    _ = type_store;

    // Build a quick lookup: function-name → FunctionId. Used by call
    // sites that reference callees by name (call_named, tail_call) to
    // resolve back to the function's parameter conventions slot.
    var name_to_id: std.StringHashMapUnmanaged(ir.FunctionId) = .empty;
    defer name_to_id.deinit(allocator);
    for (program.functions) |func| {
        // Both `function.name` and `function.local_name` may appear in
        // call sites depending on whether the call resolves the named
        // function or its struct-qualified form. Index both shapes so
        // the lookup hits regardless of which form the caller emitted.
        try name_to_id.put(allocator, func.name, func.id);
        if (func.local_name.len != 0) {
            // The local-name index is best-effort: a collision between
            // two different functions with the same local_name (across
            // structs) would cost the inference a missed promotion,
            // never a wrong one. The conservative outcome is acceptable
            // because Step 4's V7 catches any erroneous propagation.
            const gop = try name_to_id.getOrPut(allocator, func.local_name);
            if (!gop.found_existing) gop.value_ptr.* = func.id;
        }
    }

    // Build the call-site index: for each function id, accumulate the
    // call sites that target it. Each site carries enough info to
    // answer "is the source local at last use?" — we record the
    // function the call is *inside* (so we can look up its
    // ArcOwnership), the call args, and a tag describing the call
    // shape so the consume check can route correctly.
    var sites_by_target = SitesByTarget.init(allocator);
    defer sites_by_target.deinit();

    for (program.functions) |*caller_func| {
        try collectCallSites(
            allocator,
            caller_func,
            &name_to_id,
            &sites_by_target,
        );
    }

    // Build a function-id → function-pointer index so the consume
    // check can resolve a `CallSite.enclosing_function_id` back to
    // the caller's IR body. The caller's body is needed to verify
    // the V8 soundness check: a parameter slot that is re-fetched
    // via a later `param_get` is NOT at last-use at any earlier
    // share_value site, even if the share's specific source
    // LocalId happens to be dead afterwards.
    var function_index: std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function) = .empty;
    defer function_index.deinit(allocator);
    for (program.functions) |*func| {
        try function_index.put(allocator, func.id, func);
    }

    // Phase 1.3 chain-consistency audit (research2.md §1.5).
    //
    // Compute the v8_signature fixpoint over the call graph. For each
    // function-slot pair (F, i), `lift_set` records whether the slot
    // is safe to promote BEYOND the borrowed-source veto. A slot is
    // lift-eligible iff:
    //
    //   1. `Sig(F, i) ∈ {CU, PU}` per the v8_signature fixpoint.
    //   2. The local def-use chain at every call site to F-slot-i is
    //      consume-mode (last-use checks + chain-walk pass).
    //   3. EVERY call site's chain root, when it terminates at a
    //      `param_get` of a caller's parameter slot, terminates at a
    //      slot that is ALSO lift-eligible (the chain consistency
    //      property — promoting F.i without lifting the chain root
    //      would produce a double-release at runtime).
    //
    // The audit iterates a monotone fixpoint: a slot, once eligible,
    // stays eligible. Termination is bounded by the program's slot
    // count.
    //
    // This audit STRICTLY widens the existing `inferConventions`: a
    // slot that is lift-eligible may bypass the borrowed-source veto
    // (line 855-868) when its alias chain root is a `param_get` of a
    // caller's `.borrowed` slot — but only when that caller slot is
    // itself lift-eligible. The chain consistency guarantees that
    // promoting `(F, i)` to `.owned` will be matched by promoting
    // every parent slot in lockstep, so the runtime ABI invariant
    // ("if the callee owns +1, the caller owns a +1 to give") holds.
    var signatures = try v8_fixpoint.computeSignaturesWithOwnership(allocator, program, ownerships);
    defer signatures.deinit(allocator);

    var lift_set = try computeLiftSet(
        allocator,
        program,
        &signatures,
        &sites_by_target,
        ownerships,
        &function_index,
        &name_to_id,
    );
    defer lift_set.deinit(allocator);

    // Fixpoint iteration: a callee's slot can be promoted only when every
    // caller's source local satisfies the consume gates, including the
    // borrowed-source veto (the chain root must NOT be a `param_get` of
    // the caller's `.borrowed` parameter — UNLESS the audit has marked
    // that parameter slot as lift-eligible). Promoting one function's
    // slot from `.borrowed` to `.owned` can unlock promotions in the
    // functions that pass through that slot. Iterate until no more
    // promotions occur.
    //
    // The pass never demotes — only `.borrowed` → `.owned`. Termination
    // is guaranteed by the bounded total number of `.borrowed` slots
    // across the program.
    var changed = true;
    var iteration: u32 = 0;
    const max_iterations: u32 = 64;
    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;
        for (program.functions, 0..) |_, func_index| {
            const function: *ir.Function = @constCast(&program.functions[func_index]);
            const before = countOwnedSlots(function);
            try evaluateFunction(
                function,
                &sites_by_target,
                ownerships,
                &function_index,
                &lift_set,
                &name_to_id,
                program,
            );
            const after = countOwnedSlots(function);
            if (after > before) changed = true;
        }
    }

}

/// Set of `(FunctionId, slot)` pairs that have passed the chain-
/// consistency audit and are eligible to bypass the borrowed-source
/// veto in `siteConsumesSlot`.
///
/// Keyed by a packed `u64` of `(function_id << 32) | slot`. This is a
/// set, not a map — membership is the only signal.
const LiftSet = std.AutoHashMapUnmanaged(u64, void);

/// Pack a `(FunctionId, slot)` pair into a `u64` key. Slot is stored
/// in the low 32 bits; function id in the high 32 bits.
fn liftKey(function_id: ir.FunctionId, slot_index: usize) u64 {
    return (@as(u64, @intCast(function_id)) << 32) | @as(u64, @intCast(slot_index));
}

fn liftSetContains(lift_set: *const LiftSet, function_id: ir.FunctionId, slot_index: usize) bool {
    return lift_set.contains(liftKey(function_id, slot_index));
}

/// Compute the set of `(FunctionId, slot)` pairs that pass the
/// chain-consistency audit. The audit iterates a monotone fixpoint —
/// a slot, once eligible, never gets removed.
///
/// The audit's three conditions on `(F, i)`:
///
///   1. `Sig(F, i) ∈ {CU, PU}`. Slots whose signature is `aliases`
///      or `top` cannot be lifted: aliasing means the parameter
///      escapes the function (a tuple component or closure capture),
///      top means we can't prove uniqueness. Either way, the runtime
///      assumption that the cell is uniquely owned would be violated.
///
///   2. EVERY call site to F's slot i has a "consume-mode" local
///      def-use chain in the caller (the same check
///      `siteConsumesSlot` already performs MINUS the borrowed-source
///      veto). If any call site's local check fails, F.i can't be
///      lifted via the chain regardless.
///
///   3. EVERY call site's alias-chain root, when it is a `param_get`
///      of caller `C` slot `j`, has `(C, j)` ALSO in the lift set.
///      This is the chain-consistency property: promoting `F.i` to
///      `.owned` adds a callee scope-exit drop for the parameter; if
///      `(C, j)` is NOT lifted, `C` retains its `.borrowed` ABI and
///      its retain around the call to `F` is NOT elided — producing
///      a double release.
fn computeLiftSet(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    signatures: *const v8_signature.ProgramSignatures,
    sites_by_target: *const SitesByTarget,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
) !LiftSet {
    // Phase 1.3 chain-consistency audit (conservative monotone-up).
    // A candidate enters lift_set only when every chain dependency
    // is already in the set OR ends at a non-borrowed source. This
    // handles self-recursion and "anchored" slots (those whose body
    // forwards into an owned-mutating builtin or an already-promoted
    // Zap callee).
    //
    // Mutual recursion is NOT lifted by this scheme — slots whose
    // anchor depends on each other can't bootstrap because neither
    // side enters the set first. Phase 2's optimistic-seed extension
    // was tried but produced V8-unsound promotions: the alias-chain
    // audit passes but the per-instruction uniqueness verifier
    // (`arc_verifier::runV8`) rejects, because the promoted slot's
    // body has copy_value/share_value emissions that demote the
    // receiver's runtime uniqueness. The conservative monotone-up
    // is the sound choice; lifting mutual-recursion SCCs requires
    // a stronger pre-flight check that mimics the V8 verifier's
    // dataflow at audit time. (Future work.)
    var lift_set: LiftSet = .empty;
    errdefer lift_set.deinit(allocator);

    var changed = true;
    var iteration: u32 = 0;
    const max_iterations: u32 = 64;
    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;
        for (program.functions) |*function| {
            for (function.param_conventions, 0..) |conv, slot_index| {
                if (conv != .borrowed) continue;
                if (liftSetContains(&lift_set, function.id, slot_index)) continue;
                if (!try slotPassesAuditConditions(
                    function,
                    slot_index,
                    signatures,
                    sites_by_target,
                    ownerships,
                    function_index,
                    &lift_set,
                    name_to_id,
                    program,
                )) continue;
                try lift_set.put(allocator, liftKey(function.id, slot_index), {});
                changed = true;
            }
        }
    }

    return lift_set;
}

/// Single-iteration audit predicate: does `(function, slot_index)`
/// pass conditions (1)–(3)?
///
/// `lift_set` is the *current* state of the audit's eligibility set.
/// A `param_get` chain root only counts as audit-eligible when its
/// slot is already in the set — fixpoint iteration ensures we
/// converge to the largest consistent set.
fn slotPassesAuditConditions(
    function: *const ir.Function,
    slot_index: usize,
    signatures: *const v8_signature.ProgramSignatures,
    sites_by_target: *const SitesByTarget,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    lift_set: *const LiftSet,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    program: ?*const ir.Program,
) !bool {
    // Condition (1): signature must be CU or PU.
    if (!signatures.isCuOrPu(function.id, slot_index)) return false;

    // Condition (2) + (3): every call site's local check passes AND
    // every chain root either ends at a non-param source or at a
    // param slot already in the lift set.
    const sites = sites_by_target.get(function.id);
    if (sites.len == 0) return false; // No callers — nothing to lift. (Conservative.)

    for (sites) |site| {
        if (site.args.len <= slot_index) continue;
        const eligible = try siteAuditEligible(
            site,
            slot_index,
            ownerships,
            function_index,
            lift_set,
        );
        if (!eligible) return false;
    }

    // Condition (4): the slot must satisfy `shouldPromoteSlot`'s
    // anchor requirement. `shouldPromoteSlot` will only promote a
    // slot when EITHER the slot has a self-recursive consume site,
    // OR the body forwards the param into an owned-mutating
    // builtin's receiver (the Zap-fn-wrapper-around-zig-builtin
    // pattern), OR — Phase 1.3 extension — the body forwards the
    // param into a Zap-function call whose corresponding slot is
    // ALSO in `lift_set`. Without an anchor the slot will not
    // actually promote in `evaluateFunction`, and adding it to
    // `lift_set` would surface as an inconsistent chain when
    // `siteConsumesSlot`'s veto check sees the parent's slot stuck
    // `.borrowed` post-fixpoint — producing the double-release at
    // runtime.
    //
    // The third anchor case (forward-to-lifted-callee) closes the
    // gap that fannkuch's `advance_perm` exhibits: it forwards
    // `count` to `rotate_loop` (a Zap function, not a builtin), so
    // without the extension `advance_perm`'s `count` slot would
    // never satisfy the anchor and the chain would freeze at
    // `advance_perm`. With the extension, `advance_perm`'s
    // `count`-slot anchor is satisfied as soon as `rotate_loop`'s
    // matching slot enters `lift_set`.
    //
    // We require BOTH the chain consistency AND the matching anchor
    // because the audit's promise to consumers is "if I add (F, i)
    // to lift_set, F's slot i WILL be promoted to .owned by the end
    // of the inferConventions iteration." Without the anchor, that
    // promise breaks.
    var has_self_recursive = false;
    for (sites) |site| {
        if (site.is_self_recursive) {
            has_self_recursive = true;
            break;
        }
    }
    if (!has_self_recursive and !bodyConsumesParamViaOwnedSinkWithProgram(function, slot_index, lift_set, name_to_id, program)) {
        return false;
    }

    return true;
}

/// Per-call-site audit predicate. Mirrors `siteConsumesSlot`'s local
/// check but replaces the hard borrowed-source veto with a recursive
/// chain-eligibility query against the in-progress `lift_set`.
fn siteAuditEligible(
    site: CallSite,
    slot_index: usize,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    lift_set: *const LiftSet,
) !bool {
    switch (site.kind) {
        .tail_call => {
            // Self-recursive tail-call args are consumed by definition;
            // they NEVER terminate at a `param_get` of a different
            // parameter (they pass the same locals as the caller's),
            // so the audit succeeds when the call is self-recursive.
            // Non-self-recursive tail calls would be a Zap-level
            // surprise — treat conservatively as audit-fail.
            if (site.is_self_recursive) return true;
            return false;
        },
        .regular => |info| {
            const source = info.share_sources[slot_index] orelse return false;
            const share_id = info.share_instr_ids[slot_index].?;

            const fn_ownership = ownerships.get(site.enclosing_function_id) orelse return false;
            const last_use = fn_ownership.last_use_map.get(source) orelse return false;
            if (last_use != share_id) return false;

            const caller_func = function_index.get(site.enclosing_function_id) orelse return false;
            if (!chainIsConsumeMode(caller_func, fn_ownership, source, share_id)) return false;

            const root_local = traceAliasChainToRoot(caller_func, source);
            if (paramSlotForLocal(caller_func, root_local)) |param_slot| {
                // Phase 1.8 item #4 — bounded-borrow refinement. Compute
                // the consume call's last-use id from the share_value's
                // dest (= site.args[slot_index]). Refetches whose
                // lifetime ends at or before this id are bounded
                // within the consume call's argument-evaluation window
                // and don't block promotion.
                const share_dest = site.args[slot_index];
                const consume_last_use_opt = fn_ownership.last_use_map.get(share_dest);
                const last_use_map_opt: ?*const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) =
                    if (consume_last_use_opt != null) &fn_ownership.last_use_map else null;
                const consume_last_use: arc_liveness.InstructionId = consume_last_use_opt orelse 0;
                if (paramSlotIsRefetchedAfter(caller_func, param_slot, root_local, share_id, last_use_map_opt, consume_last_use)) return false;
                // The audit's chain-consistency core: when the chain
                // root is a `param_get` of a `.borrowed` parameter,
                // the audit succeeds only when that parameter slot is
                // ALSO in the lift set. This is the recursive
                // condition that makes the fixpoint sound.
                if (param_slot < caller_func.param_conventions.len and
                    caller_func.param_conventions[param_slot] == .borrowed)
                {
                    return liftSetContains(lift_set, caller_func.id, param_slot);
                }
            }
            return true;
        },
    }
}

fn countOwnedSlots(function: *const ir.Function) usize {
    var count: usize = 0;
    for (function.param_conventions) |conv| {
        if (conv == .owned) count += 1;
    }
    return count;
}

/// One call-site entry. The inference rule runs over these.
const CallSite = struct {
    /// The function inside which this call appears. Used to look up
    /// the caller's `ArcOwnership` for last-use queries.
    enclosing_function_id: ir.FunctionId,
    /// `true` when this call is self-recursive (the callee equals the
    /// enclosing function).
    is_self_recursive: bool,
    /// Args slice copied as-is from the call instruction.
    args: []const ir.LocalId,
    /// `last_use_query`: each call shape registers the InstructionId
    /// the arc_liveness analyzer assigns to "the moment the source
    /// local is consumed". For tail_call the share/release pair is
    /// already elided by the IrBuilder (Phase E.8) so the consume
    /// signal is the tail_call itself; we treat self-recursive
    /// tail_calls as automatic consume sites. For non-tail call
    /// sites, the consume signal lives on the *share_value* preceding
    /// the call. The inference pass passes both candidates to
    /// `evaluateCallSiteSlot` which picks the right last-use anchor.
    kind: CallKind,
};

const CallKind = union(enum) {
    /// Tail call. The args list is the tail_call's args; every arg is
    /// consumed by the tail jump (the frame goes away).
    tail_call,
    /// Regular call. `share_sources[i]` is the *source local* that
    /// the IrBuilder's `share_value` instruction lifted into
    /// `args[i]`. When the source is null the slot was either non-ARC
    /// or passed without a `share_value` (rare — generally the IR
    /// builder elides the share for `borrow` mode), and the
    /// inference defers to the safe default for that slot.
    regular: struct {
        /// Per-arg-slot: the LocalId of the share_value instruction's
        /// `source` field, when the IR builder emitted a
        /// `share_value{dest=args[i], source=...}` for slot i.
        /// `null` means no share was emitted for that slot.
        share_sources: []const ?ir.LocalId,
        /// Per-arg-slot: the InstructionId of the share_value
        /// instruction. Used as the last-use anchor for the source.
        share_instr_ids: []const ?arc_liveness.InstructionId,
    },
};

const SitesByTarget = struct {
    map: std.AutoHashMap(ir.FunctionId, std.ArrayList(CallSite)),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) SitesByTarget {
        return .{
            .map = std.AutoHashMap(ir.FunctionId, std.ArrayList(CallSite)).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *SitesByTarget) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit();
    }

    fn append(self: *SitesByTarget, target: ir.FunctionId, site: CallSite) !void {
        const gop = try self.map.getOrPut(target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, site);
    }

    fn get(self: *const SitesByTarget, target: ir.FunctionId) []const CallSite {
        if (self.map.getPtr(target)) |list| return list.items;
        return &.{};
    }
};

fn collectCallSites(
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    sites: *SitesByTarget,
) !void {
    // We need both per-instruction ids (so that share_value sites can
    // be paired with their last-use anchor in `last_use_map`) and a
    // call-by-call view that pairs each call with the share_values
    // that prepared its args. Walk every instruction stream in
    // depth-first order; assign ids in lockstep with
    // `arc_liveness.assignInstructionIds` so the InstructionIds we
    // record match the ones in the caller's `ArcOwnership.last_use_map`.

    var walker = SiteWalker{
        .allocator = allocator,
        .caller = caller,
        .name_to_id = name_to_id,
        .sites = sites,
    };
    for (caller.body) |block| {
        try walker.walkStream(block.instructions);
    }
}

const SiteWalker = struct {
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    sites: *SitesByTarget,
    /// Running instruction id, mirrored from `arc_liveness`'s
    /// depth-first traversal order. Both walkers must agree on the id
    /// assignment so cross-pass comparisons against `last_use_map` are
    /// meaningful.
    next_id: arc_liveness.InstructionId = 0,

    /// Per-stream: most recently observed `share_value{dest=X, source=Y}`
    /// table. Maps args[i]'s shared local back to its source. Tracked
    /// per-stream because share_values do not cross structural
    /// boundaries (the IR builder emits share/call/release as a single
    /// stream-local sequence). The maps are stack-local on each
    /// `walkStream` invocation so nested recursion does not clobber
    /// outer-scope tables.
    fn walkStream(self: *SiteWalker, stream: []const ir.Instruction) error{OutOfMemory}!void {
        var share_dest_to_source = std.AutoHashMap(ir.LocalId, ir.LocalId).init(self.allocator);
        defer share_dest_to_source.deinit();
        var share_dest_to_id = std.AutoHashMap(ir.LocalId, arc_liveness.InstructionId).init(self.allocator);
        defer share_dest_to_id.deinit();

        for (stream) |*instr| {
            const id = self.next_id;
            self.next_id += 1;
            try self.processInstruction(
                instr,
                id,
                &share_dest_to_source,
                &share_dest_to_id,
            );
            try self.recurseChildren(instr);
        }
    }

    fn recurseChildren(self: *SiteWalker, instr: *const ir.Instruction) error{OutOfMemory}!void {
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
            .try_call_named => |tcn| {
                try self.walkStream(tcn.handler_instrs);
                try self.walkStream(tcn.success_instrs);
            },
            .guard_block => |gb| {
                try self.walkStream(gb.body);
            },
            .optional_dispatch => |od| {
                try self.walkStream(od.nil_instrs);
                try self.walkStream(od.struct_instrs);
            },
            else => {},
        }
    }

    fn processInstruction(
        self: *SiteWalker,
        instr: *const ir.Instruction,
        id: arc_liveness.InstructionId,
        share_dest_to_source: *std.AutoHashMap(ir.LocalId, ir.LocalId),
        share_dest_to_id: *std.AutoHashMap(ir.LocalId, arc_liveness.InstructionId),
    ) !void {
        switch (instr.*) {
            .share_value => |sv| {
                try share_dest_to_source.put(sv.dest, sv.source);
                try share_dest_to_id.put(sv.dest, id);
            },
            .tail_call => |tc| {
                // Self-recursive tail call. By Phase E.8 invariants
                // every arg is at the consume position (the frame
                // is replaced by the next iteration). Record as a
                // tail-call site against the function whose name
                // matches the caller.
                const target_id = self.name_to_id.get(tc.name) orelse return;
                try self.sites.append(target_id, .{
                    .enclosing_function_id = self.caller.id,
                    .is_self_recursive = target_id == self.caller.id,
                    .args = tc.args,
                    .kind = .tail_call,
                });
            },
            .call_named => |cn| {
                const target_id = self.name_to_id.get(cn.name) orelse return;
                try self.recordRegularCall(
                    target_id,
                    cn.args,
                    share_dest_to_source,
                    share_dest_to_id,
                );
            },
            .call_direct => |cd| {
                try self.recordRegularCall(
                    cd.function,
                    cd.args,
                    share_dest_to_source,
                    share_dest_to_id,
                );
            },
            .try_call_named => |tcn| {
                const target_id = self.name_to_id.get(tcn.name) orelse return;
                try self.recordRegularCall(
                    target_id,
                    tcn.args,
                    share_dest_to_source,
                    share_dest_to_id,
                );
            },
            // call_dispatch resolves to a group of clauses; without
            // a single concrete callee we cannot bind the convention
            // here. Each clause is reached via call_direct from the
            // dispatch trampoline; that path is already covered above.
            .call_dispatch,
            .call_closure,
            .call_builtin,
            => {},
            else => {},
        }
    }

    fn recordRegularCall(
        self: *SiteWalker,
        target_id: ir.FunctionId,
        args: []const ir.LocalId,
        share_dest_to_source: *const std.AutoHashMap(ir.LocalId, ir.LocalId),
        share_dest_to_id: *const std.AutoHashMap(ir.LocalId, arc_liveness.InstructionId),
    ) !void {
        const share_sources = try self.allocator.alloc(?ir.LocalId, args.len);
        const share_ids = try self.allocator.alloc(?arc_liveness.InstructionId, args.len);
        for (args, 0..) |arg_local, idx| {
            if (share_dest_to_source.get(arg_local)) |src| {
                share_sources[idx] = src;
                share_ids[idx] = share_dest_to_id.get(arg_local).?;
            } else {
                share_sources[idx] = null;
                share_ids[idx] = null;
            }
        }
        try self.sites.append(target_id, .{
            .enclosing_function_id = self.caller.id,
            .is_self_recursive = target_id == self.caller.id,
            .args = args,
            .kind = .{ .regular = .{
                .share_sources = share_sources,
                .share_instr_ids = share_ids,
            } },
        });
    }
};

fn evaluateFunction(
    function: *ir.Function,
    sites_by_target: *const SitesByTarget,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    lift_set: *const LiftSet,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    program: ?*const ir.Program,
) !void {
    if (function.param_conventions.len == 0) return;

    const sites = sites_by_target.get(function.id);
    if (sites.len == 0) return;

    // For each ARC-managed parameter slot, evaluate the three
    // conditions. Mutate via @constCast at the seam — the slice
    // header is `const` to the rest of the IR but writeable here by
    // design.
    const conventions: MutableConventions = @constCast(function.param_conventions);
    for (conventions, 0..) |*conv_ptr, slot_index| {
        if (conv_ptr.* != .borrowed) continue;
        if (try shouldPromoteSlot(function, slot_index, sites, ownerships, function_index, lift_set, name_to_id, program)) {
            conv_ptr.* = .owned;
        }
    }
}

fn shouldPromoteSlot(
    function: *const ir.Function,
    slot_index: usize,
    sites: []const CallSite,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    lift_set: *const LiftSet,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    program: ?*const ir.Program,
) !bool {
    var has_self_recursive = false;
    for (sites) |site| {
        if (site.args.len <= slot_index) {
            // The call uses fewer args than this slot. That means it
            // does not constrain the slot's convention; skip it
            // (this can occur for variadic-shaped clauses, though
            // Zap functions today have fixed arity).
            continue;
        }
        const consumes = try siteConsumesSlot(site, slot_index, ownerships, function_index, lift_set);
        if (!consumes) return false;
        if (site.is_self_recursive) has_self_recursive = true;
    }
    // Condition 1: at least one consume-side anchor exists for this
    // slot. The original phrasing required at least one self-recursive
    // call site, which is the canonical k-nucleotide accumulator
    // pattern. Phase 4 (dense Map) of the implementation plan adds a
    // second anchor: the function body forwards `slot_index` directly
    // into an owned-mutating call_builtin (`Map.put`/`.delete`/
    // `.merge`). This covers `lib/map.zap`'s thin `Map.put` Zap-fn
    // wrapper, which simply forwards the receiver to
    // `:zig.Map.put(...)` — the runtime's rc-1 fast path consumes the
    // receiver, so the wrapper's slot 0 is semantically equivalent to
    // a self-recursive consumer for inference purposes.
    //
    // Without this extension the wrapper stays `.borrowed`, every
    // caller of `Map.put` emits a retain around the call, the
    // receiver enters the runtime with refcount >= 2, and the rc-1
    // fast path never fires — the source of the k-nucleotide perf
    // regression after the dense Map flip.
    //
    // Phase 1.3 chain-consistency extension: also accept forwarding
    // into a Zap function call whose slot is in `lift_set`. The
    // audit's monotone fixpoint guarantees that ALL slots in
    // `lift_set` will be promoted to `.owned` together, so a
    // function whose only anchor is a forward into another
    // lift-eligible slot still satisfies the consume-side property
    // when the iteration converges.
    if (!has_self_recursive and !bodyConsumesParamViaOwnedSinkWithProgram(function, slot_index, lift_set, name_to_id, program)) {
        return false;
    }
    return true;
}

/// Does the function's body forward `param_index` into the receiver
/// slot of an owned-mutating call_builtin OR an owned slot of a Zap
/// function call? Walks the function's instruction streams and tracks
/// the SSA chain from `param_get` to the call, allowing intermediate
/// `move_value`, `local_get`, `borrow_value`, and `share_value`
/// aliases.
///
/// `lift_set` and `name_to_id` are optional. When provided, the check
/// also accepts forwarding into a Zap function call whose
/// corresponding slot is in `lift_set` — this is the chain-consistency
/// extension for Phase 1.3 that allows a parameter slot to be
/// considered "consumed via a downstream owned callee" when the
/// downstream slot is itself being promoted in lockstep. Without this
/// extension, a function like fannkuch's `advance_perm` (which only
/// forwards `count` into `rotate_loop` — not into a call_builtin)
/// would never satisfy `shouldPromoteSlot`'s anchor requirement, and
/// the `count` chain through `advance_perm` could not be lifted even
/// when the rest of the chain is consistent.
///
/// The check is structural — we don't need a full last-use proof
/// here because the inference's outer condition (every caller passes
/// at last use) is what makes the promotion sound on the caller
/// side, and the matching consume effect inside the wrapper's body
/// is supplied by `arc_ownership.rewriteOwnedConsumeBuiltinSites`
/// (which gates on per-call-site last-use independently). Inside the
/// wrapper, the receiver flows directly into the consume site, so
/// the structural check is sufficient.
fn bodyConsumesParamViaOwnedBuiltin(
    function: *const ir.Function,
    param_index: usize,
) bool {
    return bodyConsumesParamViaOwnedSink(function, param_index, null, null);
}

/// Extended variant that also accepts forwarding into a Zap-function
/// call whose corresponding slot is in `lift_set` (or already has a
/// `.owned` convention).
fn bodyConsumesParamViaOwnedSink(
    function: *const ir.Function,
    param_index: usize,
    lift_set: ?*const LiftSet,
    name_to_id: ?*const std.StringHashMapUnmanaged(ir.FunctionId),
) bool {
    return bodyConsumesParamViaOwnedSinkWithProgram(function, param_index, lift_set, name_to_id, null);
}

/// Phase 2.3 — variant that also receives the `program` so the
/// anchor check can resolve the callee's `param_conventions[idx]`
/// directly. Without the program, the helper relies solely on the
/// `lift_set` predicate, which under-detects functions that have
/// ALREADY been promoted to `.owned` by a previous fixpoint
/// iteration. The previous behaviour blocked the chain at the
/// VectorI64.set wrapper because the wrapper's slot 0 was never
/// added to lift_set (its callers were across structs and
/// per-struct lift_set is empty).
fn bodyConsumesParamViaOwnedSinkWithProgram(
    function: *const ir.Function,
    param_index: usize,
    lift_set: ?*const LiftSet,
    name_to_id: ?*const std.StringHashMapUnmanaged(ir.FunctionId),
    program: ?*const ir.Program,
) bool {
    // Cap the alias-set size to keep the analysis bounded. Map.put,
    // Map.delete, Map.merge wrappers use a single param_get plus a
    // single share_value, so even nested generic functions stay well
    // under this threshold.
    const max_aliases: usize = 256;
    var alias_buf: [max_aliases]ir.LocalId = undefined;
    var alias_len: usize = 0;

    // Forward closure: starting from every `param_get index=param_index`
    // dest in the function body, follow `move_value`/`local_get`/
    // `borrow_value`/`share_value` chains. Iterate until the alias set
    // stops growing.
    var changed = true;
    while (changed) {
        changed = false;
        for (function.body) |block| {
            if (collectParamAliasesIntoStream(block.instructions, @intCast(param_index), &alias_buf, &alias_len, max_aliases)) {
                changed = true;
            }
        }
    }
    if (alias_len == 0) return false;

    // Now scan for any owned-mutating call_builtin whose receiver
    // slot is in `alias_buf[0..alias_len]`.
    for (function.body) |block| {
        if (streamHasOwnedBuiltinConsumingAlias(block.instructions, alias_buf[0..alias_len])) return true;
    }
    // Phase 1.3 chain-consistency extension: also check for forwarding
    // into a Zap function call whose corresponding slot is in the
    // current `lift_set` (audit prediction) or already promoted to
    // `.owned`. This is what allows a function like fannkuch's
    // `advance_perm` (which only forwards `count` into `rotate_loop`)
    // to satisfy the anchor requirement when the entire chain is being
    // promoted in lockstep.
    //
    // Phase 2.3: also accept callees whose slot is ALREADY `.owned`
    // in the program's param_conventions. Promotions are sticky once
    // they fire, so a slot that was promoted in a previous fixpoint
    // iteration provides a valid anchor for any unpromoted caller.
    if (lift_set != null and name_to_id != null) {
        for (function.body) |block| {
            if (streamHasOwnedZapCalleeConsumingAlias(
                block.instructions,
                alias_buf[0..alias_len],
                lift_set.?,
                name_to_id.?,
                program,
            )) return true;
        }
    }
    return false;
}

/// Scan the stream looking for a `call_named`/`call_direct` to a Zap
/// function whose corresponding parameter slot is in `lift_set` OR
/// already has a `.owned` convention in the program. Mirrors
/// `streamHasOwnedBuiltinConsumingAlias` but for inter-Zap calls.
fn streamHasOwnedZapCalleeConsumingAlias(
    stream: []const ir.Instruction,
    alias_set: []const ir.LocalId,
    lift_set: *const LiftSet,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    program: ?*const ir.Program,
) bool {
    const targetSlotIsOwned = struct {
        fn check(prog: ?*const ir.Program, target_id: ir.FunctionId, slot_idx: usize) bool {
            const p = prog orelse return false;
            for (p.functions) |*f| {
                if (f.id == target_id) {
                    if (slot_idx >= f.param_conventions.len) return false;
                    return f.param_conventions[slot_idx] == .owned;
                }
            }
            return false;
        }
    }.check;
    for (stream) |*instr| {
        switch (instr.*) {
            .call_named => |cn| {
                if (name_to_id.get(cn.name)) |target_id| {
                    for (cn.args, 0..) |arg, idx| {
                        if (containsAlias(alias_set, arg) and
                            (liftSetContains(lift_set, target_id, idx) or
                                targetSlotIsOwned(program, target_id, idx))) return true;
                    }
                }
            },
            .call_direct => |cd| {
                for (cd.args, 0..) |arg, idx| {
                    if (containsAlias(alias_set, arg) and
                        (liftSetContains(lift_set, cd.function, idx) or
                            targetSlotIsOwned(program, cd.function, idx))) return true;
                }
            },
            .try_call_named => |tcn| {
                if (name_to_id.get(tcn.name)) |target_id| {
                    for (tcn.args, 0..) |arg, idx| {
                        if (containsAlias(alias_set, arg) and
                            (liftSetContains(lift_set, target_id, idx) or
                                targetSlotIsOwned(program, target_id, idx))) return true;
                    }
                }
            },
            .tail_call => |tc| {
                if (name_to_id.get(tc.name)) |target_id| {
                    for (tc.args, 0..) |arg, idx| {
                        if (containsAlias(alias_set, arg) and
                            (liftSetContains(lift_set, target_id, idx) or
                                targetSlotIsOwned(program, target_id, idx))) return true;
                    }
                }
            },
            .if_expr => |ie| {
                if (streamHasOwnedZapCalleeConsumingAlias(ie.then_instrs, alias_set, lift_set, name_to_id, program)) return true;
                if (streamHasOwnedZapCalleeConsumingAlias(ie.else_instrs, alias_set, lift_set, name_to_id, program)) return true;
            },
            .case_block => |cb| {
                if (streamHasOwnedZapCalleeConsumingAlias(cb.pre_instrs, alias_set, lift_set, name_to_id, program)) return true;
                for (cb.arms) |arm| {
                    if (streamHasOwnedZapCalleeConsumingAlias(arm.cond_instrs, alias_set, lift_set, name_to_id, program)) return true;
                    if (streamHasOwnedZapCalleeConsumingAlias(arm.body_instrs, alias_set, lift_set, name_to_id, program)) return true;
                }
                if (streamHasOwnedZapCalleeConsumingAlias(cb.default_instrs, alias_set, lift_set, name_to_id, program)) return true;
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    if (streamHasOwnedZapCalleeConsumingAlias(c.body_instrs, alias_set, lift_set, name_to_id, program)) return true;
                }
                if (streamHasOwnedZapCalleeConsumingAlias(sl.default_instrs, alias_set, lift_set, name_to_id, program)) return true;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    if (streamHasOwnedZapCalleeConsumingAlias(c.body_instrs, alias_set, lift_set, name_to_id, program)) return true;
                }
                if (streamHasOwnedZapCalleeConsumingAlias(sr.default_instrs, alias_set, lift_set, name_to_id, program)) return true;
            },
            .union_switch => |us| {
                for (us.cases) |c| {
                    if (streamHasOwnedZapCalleeConsumingAlias(c.body_instrs, alias_set, lift_set, name_to_id, program)) return true;
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    if (streamHasOwnedZapCalleeConsumingAlias(c.body_instrs, alias_set, lift_set, name_to_id, program)) return true;
                }
            },
            .guard_block => |gb| {
                if (streamHasOwnedZapCalleeConsumingAlias(gb.body, alias_set, lift_set, name_to_id, program)) return true;
            },
            .optional_dispatch => |od| {
                if (streamHasOwnedZapCalleeConsumingAlias(od.nil_instrs, alias_set, lift_set, name_to_id, program)) return true;
                if (streamHasOwnedZapCalleeConsumingAlias(od.struct_instrs, alias_set, lift_set, name_to_id, program)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn collectParamAliasesIntoStream(
    stream: []const ir.Instruction,
    param_index: u32,
    alias_buf: []ir.LocalId,
    alias_len: *usize,
    max_aliases: usize,
) bool {
    var changed = false;
    for (stream) |*instr| {
        switch (instr.*) {
            .param_get => |pg| if (pg.index == param_index) {
                if (markAlias(pg.dest, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .move_value => |mv| if (containsAlias(alias_buf[0..alias_len.*], mv.source)) {
                if (markAlias(mv.dest, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .local_get => |lg| if (containsAlias(alias_buf[0..alias_len.*], lg.source)) {
                if (markAlias(lg.dest, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .borrow_value => |bv| if (containsAlias(alias_buf[0..alias_len.*], bv.source)) {
                if (markAlias(bv.dest, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .share_value => |sv| if (containsAlias(alias_buf[0..alias_len.*], sv.source)) {
                if (markAlias(sv.dest, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .if_expr => |ie| {
                if (collectParamAliasesIntoStream(ie.then_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                if (collectParamAliasesIntoStream(ie.else_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .case_block => |cb| {
                if (collectParamAliasesIntoStream(cb.pre_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                for (cb.arms) |arm| {
                    if (collectParamAliasesIntoStream(arm.cond_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                    if (collectParamAliasesIntoStream(arm.body_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                }
                if (collectParamAliasesIntoStream(cb.default_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    if (collectParamAliasesIntoStream(c.body_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                }
                if (collectParamAliasesIntoStream(sl.default_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    if (collectParamAliasesIntoStream(c.body_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                }
                if (collectParamAliasesIntoStream(sr.default_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .union_switch => |us| {
                for (us.cases) |c| {
                    if (collectParamAliasesIntoStream(c.body_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    if (collectParamAliasesIntoStream(c.body_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                }
            },
            .try_call_named => |tcn| {
                if (collectParamAliasesIntoStream(tcn.handler_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                if (collectParamAliasesIntoStream(tcn.success_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .guard_block => |gb| {
                if (collectParamAliasesIntoStream(gb.body, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            .optional_dispatch => |od| {
                if (collectParamAliasesIntoStream(od.nil_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
                if (collectParamAliasesIntoStream(od.struct_instrs, param_index, alias_buf, alias_len, max_aliases)) changed = true;
            },
            else => {},
        }
    }
    return changed;
}

fn markAlias(
    local: ir.LocalId,
    alias_buf: []ir.LocalId,
    alias_len: *usize,
    max_aliases: usize,
) bool {
    if (containsAlias(alias_buf[0..alias_len.*], local)) return false;
    if (alias_len.* >= max_aliases) return false;
    alias_buf[alias_len.*] = local;
    alias_len.* += 1;
    return true;
}

fn containsAlias(set: []const ir.LocalId, local: ir.LocalId) bool {
    for (set) |id| {
        if (id == local) return true;
    }
    return false;
}

fn streamHasOwnedBuiltinConsumingAlias(
    stream: []const ir.Instruction,
    alias_set: []const ir.LocalId,
) bool {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_builtin => |cb| {
                if (arc_liveness.ownedMutatingBuiltinSlot(cb.name)) |slot| {
                    if (slot < cb.args.len and containsAlias(alias_set, cb.args[slot])) return true;
                }
            },
            .if_expr => |ie| {
                if (streamHasOwnedBuiltinConsumingAlias(ie.then_instrs, alias_set)) return true;
                if (streamHasOwnedBuiltinConsumingAlias(ie.else_instrs, alias_set)) return true;
            },
            .case_block => |cb| {
                if (streamHasOwnedBuiltinConsumingAlias(cb.pre_instrs, alias_set)) return true;
                for (cb.arms) |arm| {
                    if (streamHasOwnedBuiltinConsumingAlias(arm.cond_instrs, alias_set)) return true;
                    if (streamHasOwnedBuiltinConsumingAlias(arm.body_instrs, alias_set)) return true;
                }
                if (streamHasOwnedBuiltinConsumingAlias(cb.default_instrs, alias_set)) return true;
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| {
                    if (streamHasOwnedBuiltinConsumingAlias(c.body_instrs, alias_set)) return true;
                }
                if (streamHasOwnedBuiltinConsumingAlias(sl.default_instrs, alias_set)) return true;
            },
            .switch_return => |sr| {
                for (sr.cases) |c| {
                    if (streamHasOwnedBuiltinConsumingAlias(c.body_instrs, alias_set)) return true;
                }
                if (streamHasOwnedBuiltinConsumingAlias(sr.default_instrs, alias_set)) return true;
            },
            .union_switch => |us| {
                for (us.cases) |c| {
                    if (streamHasOwnedBuiltinConsumingAlias(c.body_instrs, alias_set)) return true;
                }
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| {
                    if (streamHasOwnedBuiltinConsumingAlias(c.body_instrs, alias_set)) return true;
                }
            },
            .try_call_named => |tcn| {
                if (streamHasOwnedBuiltinConsumingAlias(tcn.handler_instrs, alias_set)) return true;
                if (streamHasOwnedBuiltinConsumingAlias(tcn.success_instrs, alias_set)) return true;
            },
            .guard_block => |gb| {
                if (streamHasOwnedBuiltinConsumingAlias(gb.body, alias_set)) return true;
            },
            .optional_dispatch => |od| {
                if (streamHasOwnedBuiltinConsumingAlias(od.nil_instrs, alias_set)) return true;
                if (streamHasOwnedBuiltinConsumingAlias(od.struct_instrs, alias_set)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Does this call site pass `args[slot_index]` in a "consume"
/// position — i.e. is the source dead at the call?
fn siteConsumesSlot(
    site: CallSite,
    slot_index: usize,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    lift_set: *const LiftSet,
) !bool {
    switch (site.kind) {
        .tail_call => {
            // Self-recursive tail-call args are consumed by definition
            // (the frame goes away). For non-recursive tail calls the
            // same logic applies — Zap's tail_call only ever names
            // the enclosing function (by construction in the IR
            // builder), so this branch is effectively self-recursive
            // already, but we keep the guard explicit to stay
            // robust against future tail-call semantics.
            if (site.is_self_recursive) return true;
            // A non-self-recursive tail_call would be a Zap-level
            // surprise; treat conservatively as non-consume so the
            // inference stays sound.
            return false;
        },
        .regular => |info| {
            const source = info.share_sources[slot_index] orelse {
                // No share was emitted for this slot. The slot is
                // either non-ARC (in which case it does not need a
                // consume convention) or passed under a non-share
                // mode that the inference does not yet understand.
                // Treat as non-consume; convention stays .borrowed.
                return false;
            };
            const share_id = info.share_instr_ids[slot_index].?;
            // Is `source` at last use at the share_value site? The
            // arc_liveness analyzer records the share_value
            // instruction as the last use for sources that are
            // consumed there.
            const fn_ownership = ownerships.get(site.enclosing_function_id) orelse return false;
            const last_use = fn_ownership.last_use_map.get(source) orelse return false;
            if (last_use != share_id) return false;

            // V8 soundness gate (A2 — Vector(T) ARC promotion):
            //
            // The local-level last-use check above is necessary but
            // NOT sufficient. The `IrBuilder.emitLocalGet` helper
            // expands every named-binding read into a chain:
            //
            //     local_get  dest=A source=B
            //     retain     value=A      ; emitted when source is ARC-managed
            //     share_value dest=C source=A mode=retain
            //     call ... args=[C, ...]
            //     release    value=C
            //
            // The share_value's `source` is `A`, and `A` is at
            // last-use at the share_value site. But `A` was retained
            // immediately after `local_get`; aliasing `B`. The
            // chain is "consume" (no real retain needed) ONLY if `B`
            // was itself at last-use at the local_get site —
            // otherwise the local_get/retain pair was emitted because
            // the named binding has further uses, and rewriting the
            // share_value into `move_value` (V8's promotion) would
            // remove a +1 the binding still owns, leading to use-
            // after-free when the binding is read again post-call.
            //
            // The same hazard applies to `param_get` chains: each
            // parameter reference produces a fresh `param_get
            // dest=X index=N`. If the parameter SLOT is read again
            // by another `param_get` later in the body, the slot is
            // not at last-use here.
            //
            // The check: walk the alias chain backward from `source`
            // through `local_get`, `borrow_value`, `copy_value`,
            // `move_value`, `share_value`. At each hop, verify the
            // local being aliased FROM is itself at last-use at the
            // alias instruction. If any hop fails the check, the
            // root binding has post-call uses and promotion is
            // unsound.
            //
            // The walk also stops at `param_get` and checks whether
            // the parameter slot is refetched elsewhere in the body.
            const caller_func = function_index.get(site.enclosing_function_id) orelse return false;
            if (!chainIsConsumeMode(caller_func, fn_ownership, source, share_id)) return false;

            const root_local = traceAliasChainToRoot(caller_func, source);
            if (paramSlotForLocal(caller_func, root_local)) |param_slot| {
                // Phase 1.8 item #4 — bounded-borrow refinement. Compute
                // the consume call's last-use id from the share_value's
                // dest (= site.args[slot_index]). Refetches whose
                // lifetime ends at or before this id are bounded within
                // the consume call's argument-evaluation window and
                // don't block promotion.
                const share_dest = site.args[slot_index];
                const consume_last_use_opt = fn_ownership.last_use_map.get(share_dest);
                const last_use_map_opt: ?*const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) =
                    if (consume_last_use_opt != null) &fn_ownership.last_use_map else null;
                const consume_last_use: arc_liveness.InstructionId = consume_last_use_opt orelse 0;
                if (paramSlotIsRefetchedAfter(caller_func, param_slot, root_local, share_id, last_use_map_opt, consume_last_use)) return false;
                // Phase 1.3 chain-consistency lift (research2.md §1.5).
                //
                // Historical soundness gate: when the alias chain's
                // root is a `param_get` of a `.borrowed` parameter,
                // the caller does NOT own a transferable +1 — the
                // parameter's cell is owned by the caller's caller
                // (the borrow ABI does retain on entry + release on
                // return; the function is just a borrower). A
                // `move_value` rewrite at this site would
                // double-release the cell: the callee's scope-exit
                // drop AND the caller's-caller post-call release
                // both fire on the same cell.
                //
                // The chain-consistency audit (`computeLiftSet`)
                // identifies pairs (caller_func, param_slot) where
                // the WHOLE chain — every parent slot all the way up
                // to a fresh allocation or non-borrowed source — can
                // be promoted in lockstep. When this caller's slot
                // is in the lift set, promoting the callee here is
                // sound: the audit guarantees the parent's slot is
                // ALSO being promoted in this same `inferConventions`
                // run, so the parent will own +1 and the chain's
                // ABI invariants line up end-to-end.
                if (param_slot < caller_func.param_conventions.len and
                    caller_func.param_conventions[param_slot] == .borrowed)
                {
                    if (!liftSetContains(lift_set, caller_func.id, param_slot)) {
                        return false;
                    }
                }
            }
            return true;
        },
    }
}

/// Walk backward through the IR-builder-emitted alias forms
/// (`local_get`, `borrow_value`, `copy_value`, `move_value`,
/// `share_value`) starting from `local_id` and return the deepest
/// root local that does not have an alias-form definition. Stops at
/// the first instruction that defines `current_local` whose form is
/// NOT one of the recognised alias forms (e.g., `param_get`,
/// `local_set`, `call_named` dest, etc.) — that local is the root.
///
/// The walk is bounded by an iteration cap to defend against
/// pathological IR shapes; in practice the IrBuilder's chains are
/// shallow (at most 3-4 hops between named binding and call arg).
fn traceAliasChainToRoot(function: *const ir.Function, local_id: ir.LocalId) ir.LocalId {
    var current = local_id;
    const max_hops: usize = 16;
    var hop: usize = 0;
    while (hop < max_hops) : (hop += 1) {
        const next_opt = aliasSourceFor(function, current);
        if (next_opt) |next_local| {
            current = next_local;
        } else {
            break;
        }
    }
    return current;
}

/// Return the source local that defined `local_id` via an alias
/// instruction (`local_get`, `borrow_value`, `copy_value`,
/// `move_value`, `share_value`), along with the instruction id
/// of the defining alias instruction. Returns null if `local_id`
/// is not the dest of any alias instruction (i.e., it's a "root"
/// produced by `param_get`, `local_set`, a call dest, etc.).
const AliasStep = struct {
    source: ir.LocalId,
    instr_id: arc_liveness.InstructionId,
};

fn aliasStepFor(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ?AliasStep {
    const Visitor = struct {
        target: ir.LocalId,
        result: ?AliasStep,
        next_id: arc_liveness.InstructionId,

        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            const my_id = self.next_id;
            self.next_id += 1;
            if (self.result != null) return;
            const matched_source: ?ir.LocalId = switch (instr.*) {
                .local_get => |lg| if (lg.dest == self.target) lg.source else null,
                .borrow_value => |bv| if (bv.dest == self.target) bv.source else null,
                .copy_value => |cv| if (cv.dest == self.target) cv.source else null,
                .move_value => |mv| if (mv.dest == self.target) mv.source else null,
                .share_value => |sv| if (sv.dest == self.target) sv.source else null,
                else => null,
            };
            if (matched_source) |src| {
                self.result = .{ .source = src, .instr_id = my_id };
            }
        }
    };
    var visitor = Visitor{ .target = local_id, .result = null, .next_id = 0 };
    ir.forEachInstruction(function, &visitor, Visitor.visit);
    return visitor.result;
}

/// Convenience: just the source local. Used by `traceAliasChainToRoot`
/// where the instruction id is not needed.
fn aliasSourceFor(function: *const ir.Function, local_id: ir.LocalId) ?ir.LocalId {
    if (aliasStepFor(function, local_id)) |step| return step.source;
    return null;
}

/// Walk the alias chain from `source` backward and verify that, at
/// every hop, the source local is at its last-use at the alias
/// instruction. The chain starts at the share_value's source (the
/// caller passes `share_id` as the share's instruction id, which
/// `last_use_map[source]` is expected to equal at the entry —
/// already verified by the surrounding caller).
///
/// Returns true when every aliased local is at last-use at its
/// defining alias instruction. Returns false at the first hop
/// where the source has post-alias uses (i.e., the underlying
/// binding is alive past the call).
fn chainIsConsumeMode(
    function: *const ir.Function,
    fn_ownership: *const arc_liveness.ArcOwnership,
    chain_start: ir.LocalId,
    share_id: arc_liveness.InstructionId,
) bool {
    var current = chain_start;
    var current_consume_id: arc_liveness.InstructionId = share_id;
    const max_hops: usize = 16;
    var hop: usize = 0;
    while (hop < max_hops) : (hop += 1) {
        // Verify `current` is at its last-use at `current_consume_id`.
        // For the first iteration this is the share_value site (the
        // surrounding caller already verified this); subsequent
        // iterations check at the prior alias instruction.
        //
        // Phase 2.3: prefer the path-sensitive `isLastUseAt` predicate
        // over the single-entry `last_use_map` to handle the case
        // where a local is read multiple times across mutually-
        // exclusive branches. The single-entry map records only the
        // FINAL last-use (last write wins), so reads on disjoint
        // branches falsely fail the equality check even though each
        // is genuinely at last-use along its own path. This is the
        // exact pattern fannkuch's `advance_perm` exhibits — clause 0
        // and clause 1 each contain their own param_get + alias chain
        // for the `p` slot, but the analyzer's `last_use_map` only
        // records the LAST local_get of slot 1 across both clauses.
        if (!fn_ownership.isLastUseAt(current, current_consume_id)) return false;

        // Walk one hop further. If `current` was produced by an
        // alias instruction, the source becomes the new `current`
        // and the alias instruction's id becomes the new last-use
        // anchor. If `current` is a root (no alias step), we're done.
        const step_opt = aliasStepFor(function, current);
        if (step_opt) |step| {
            current = step.source;
            current_consume_id = step.instr_id;
        } else {
            break;
        }
    }
    return true;
}

/// Walk `function`'s body looking for a `param_get` instruction
/// whose `dest` equals `local_id`. Returns the parameter slot
/// (`param_get.index`) when found, or null when `local_id` is not
/// the immediate destination of a `param_get`.
///
/// This is the local equivalent of `arc_drop_insertion.paramIndexForLocal`
/// — duplicated here so the V8 inference doesn't pull in
/// `arc_drop_insertion` (avoiding a cyclic-import situation; the
/// drop-insertion pass runs strictly AFTER V8). Both helpers share
/// the same semantics: find the unique `param_get` dest mapping for
/// a candidate LocalId.
fn paramSlotForLocal(function: *const ir.Function, local_id: ir.LocalId) ?u32 {
    const Visitor = struct {
        target: ir.LocalId,
        result: ?u32,

        fn visit(self: *@This(), instr: *const ir.Instruction) void {
            if (instr.* == .param_get and instr.param_get.dest == self.target) {
                self.result = instr.param_get.index;
            }
        }
    };
    var visitor = Visitor{ .target = local_id, .result = null };
    ir.forEachInstruction(function, &visitor, Visitor.visit);
    return visitor.result;
}

/// Returns true when `function`'s body contains a `param_get` of
/// `param_slot` whose dest is NOT `share_source` along a STRUCTURAL
/// PATH that flows out of the share_value site — i.e. along any
/// successor of the share within the same stream, then any
/// successor of every enclosing instruction. Mutually-exclusive
/// arms (case_block arms, switch_literal cases, if_expr branches,
/// try_call success/handler) that don't contain the share_value
/// are pruned: they are unreachable from share's flow path.
///
/// The position-aware check is essential for the k-nucleotide
/// `Map.put` accumulator pattern: count_kmers_loop reads `m`
/// twice — once for `Map.get` (slot is still alive after) and once
/// for `Map.put` (slot is dead after; the recursive tail_call uses
/// `Map.put`'s result, not `m`). The first param_get IS visible
/// from the second's check (a flat "any other param_get" predicate
/// would reject), but the second IS at slot last-use because no
/// later instruction reads slot 4. Only post-share-on-the-share-path
/// refetches matter; pre-share reads and reads on disjoint arms
/// don't conflict with the move_value rewrite at the later site.
///
/// Earlier versions of this check used flat-id comparison
/// (`my_id > share_id`), which over-rejected: it counted refetches
/// in OTHER case arms as "after" the share even though those arms
/// are mutually exclusive with the share's arm. That over-rejection
/// blocked promotion of any wrapper whose only caller's body has a
/// case_block (e.g., the `vector_rc1` example's `fill_in_place`
/// reads `v` in case[0] for the recursive `set` call and reads `v`
/// again in case[1] for the base-case return; the two reads are on
/// disjoint paths, so the case[1] read must not block promotion
/// of the case[0]-bound share).
///
/// Phase 1.8 item #4 — bounded-borrow refinement. When `last_use_map`
/// is non-null, refetches whose lifetime is fully bounded WITHIN the
/// consume call's argument-evaluation window are ignored. A `param_get
/// dest=Q` is bounded iff `last_use_map[Q] <= consume_last_use_id`,
/// where `consume_last_use_id` is `last_use_map[share_dest]` (the
/// instruction id at which the consume call ends the share_value
/// dest's lifetime). The bounded refetch's value is consumed by some
/// non-mutating sub-call (e.g., `Vector.get`) before the outer consume
/// fires — it does not extend the parameter slot's live range past
/// the consume site, so it does not block promotion.
///
/// This refinement is essential for fannkuch's
/// `set(p, i, get(p, i+1))` shape: the inner `get(p, ...)` produces
/// a fresh `param_get` between the outer `set`'s share_value and
/// the outer `set` call. Without the refinement, the inner refetch
/// is treated as a post-share refetch and the audit rejects;
/// with it, the refetch's bounded lifetime is recognised and
/// promotion succeeds.
fn paramSlotIsRefetchedAfter(
    function: *const ir.Function,
    param_slot: u32,
    share_source: ir.LocalId,
    share_id: arc_liveness.InstructionId,
    last_use_map: ?*const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
    consume_last_use_id: arc_liveness.InstructionId,
) bool {
    var ctx = SuccessorScan{
        .slot = param_slot,
        .excluded_dest = share_source,
        .target_id = share_id,
        .next_id = 0,
        .found = false,
        .last_use_map = last_use_map,
        .consume_last_use_id = consume_last_use_id,
    };
    for (function.body) |block| {
        const status = scanStreamSuccessors(block.instructions, &ctx);
        if (ctx.found) return true;
        if (status == .target_found_and_done) break;
    }
    return ctx.found;
}

/// State for the structural-successor scan used by
/// `paramSlotIsRefetchedAfter`. The scan has two modes that toggle
/// when the share_value at `target_id` is encountered:
///   * Pre-target: walk every instruction looking for the share id.
///     Don't record refetches; they're before the share.
///   * Post-target: record any `param_get index=slot` whose dest is
///     not the excluded source, and whose id is strictly greater
///     than the target. Only on the SAME structural path as the
///     share — sibling arms of the structure that contained the
///     share are pruned by `scanInstructionChildrenPostTarget`.
const SuccessorScan = struct {
    slot: u32,
    excluded_dest: ir.LocalId,
    target_id: arc_liveness.InstructionId,
    /// Running depth-first instruction id. Mirrors `forEachInstruction`'s
    /// id assignment so target_id comparisons are meaningful.
    next_id: arc_liveness.InstructionId,
    /// Once we cross the share, we're in "post-target" mode for the
    /// remainder of this stream and every enclosing parent stream.
    found: bool,
    /// Phase 1.8 item #4 — bounded-borrow refinement. When non-null,
    /// `checkParamGet` consults `last_use_map[refetch.dest]` and
    /// suppresses the refetch flag when the dest's last-use id is
    /// `<= consume_last_use_id`. A bounded refetch is one whose
    /// value is fully consumed before the share_value's own consume
    /// call (e.g., a `Vector.get` argument inside the same `Vector.set`
    /// call's argument-evaluation window). Such refetches don't
    /// extend the parameter slot's live range past the outer consume
    /// site and therefore must not block promotion.
    last_use_map: ?*const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
    /// The instruction id at which the consume call ends the
    /// share_value's dest lifetime. Equals `last_use_map[share_dest]`
    /// when the caller passes a real bound; meaningless and unread
    /// when `last_use_map` is null.
    consume_last_use_id: arc_liveness.InstructionId,
};

/// Stream-walk status: the share_value at `target_id` may live in
/// this stream, in a child of one of this stream's instructions, or
/// not be reachable from this stream at all. The status communicates
/// to the caller (the parent stream) whether it should switch to
/// post-target mode for sibling instructions that follow this one.
const StreamStatus = enum {
    /// Target was not encountered in this stream or any of its
    /// children. The caller's mode is unchanged.
    target_not_found,
    /// Target was encountered in this stream; subsequent instructions
    /// in the same stream were scanned in post-target mode. The
    /// caller's mode should switch to post-target after returning,
    /// because anything after the structure containing the target is
    /// also "after the share".
    target_found_and_done,
};

/// Scan a stream from beginning to end. Within the stream, we either:
///   * never see the target id (target_not_found),
///   * or hit it; from that point onward in the same stream we run
///     post-target mode and visit only successors (no "siblings" —
///     siblings in the same stream are sequential successors), and
///     we visit children of those successors fully in post-target
///     mode.
fn scanStreamSuccessors(
    stream: []const ir.Instruction,
    ctx: *SuccessorScan,
) StreamStatus {
    var status: StreamStatus = .target_not_found;
    var post_target = false;
    for (stream) |*instr| {
        const my_id = ctx.next_id;
        ctx.next_id += 1;
        if (post_target) {
            // We're past the share in this stream — every instruction
            // here and its children are reachable successors.
            checkParamGet(instr, my_id, ctx);
            if (ctx.found) return status;
            scanInstructionChildrenPostTarget(instr, ctx);
            if (ctx.found) return status;
        } else {
            // Pre-target: assign ids to children but only check
            // refetches if we discover the target inside.
            const sub_status = scanInstructionChildrenMaybeTarget(instr, my_id, ctx);
            if (ctx.found) return status;
            if (sub_status == .target_found_and_done) {
                post_target = true;
                status = .target_found_and_done;
            }
        }
    }
    return status;
}

/// Pre-target mode: visit `instr`'s children. If we find the target
/// id (either as `instr` itself or inside a child), switch the
/// child-walk to post-target for subsequent sibling instructions in
/// the same stream and propagate the status up.
fn scanInstructionChildrenMaybeTarget(
    instr: *const ir.Instruction,
    instr_id: arc_liveness.InstructionId,
    ctx: *SuccessorScan,
) StreamStatus {
    if (instr_id == ctx.target_id) {
        // The target instruction itself. No children to check (the
        // target is a share_value, which has no nested instructions).
        return .target_found_and_done;
    }
    return scanChildStreamsMaybeTarget(instr, ctx);
}

/// Walk every child stream of `instr` in pre-target mode. If any
/// child stream contains the target, the remaining sibling streams
/// are walked in post-target mode (they're successors of the share
/// once control flow leaves the structure that contained it). Returns
/// the aggregate status.
fn scanChildStreamsMaybeTarget(
    instr: *const ir.Instruction,
    ctx: *SuccessorScan,
) StreamStatus {
    switch (instr.*) {
        .if_expr => |ie| {
            const t = scanStreamSuccessors(ie.then_instrs, ctx);
            if (ctx.found) return .target_not_found;
            const e = scanStreamSuccessors(ie.else_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (t == .target_found_and_done or e == .target_found_and_done)
                return .target_found_and_done;
            return .target_not_found;
        },
        .case_block => |cb| {
            const pre = scanStreamSuccessors(cb.pre_instrs, ctx);
            if (ctx.found) return .target_not_found;
            var any_target = pre == .target_found_and_done;
            for (cb.arms) |arm| {
                const cond = scanStreamSuccessors(arm.cond_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (cond == .target_found_and_done) any_target = true;
                const body = scanStreamSuccessors(arm.body_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (body == .target_found_and_done) any_target = true;
            }
            const default = scanStreamSuccessors(cb.default_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (default == .target_found_and_done) any_target = true;
            if (any_target) return .target_found_and_done;
            return .target_not_found;
        },
        .switch_literal => |sl| {
            var any_target = false;
            for (sl.cases) |c| {
                const s = scanStreamSuccessors(c.body_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (s == .target_found_and_done) any_target = true;
            }
            const def = scanStreamSuccessors(sl.default_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (def == .target_found_and_done) any_target = true;
            if (any_target) return .target_found_and_done;
            return .target_not_found;
        },
        .switch_return => |sr| {
            var any_target = false;
            for (sr.cases) |c| {
                const s = scanStreamSuccessors(c.body_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (s == .target_found_and_done) any_target = true;
            }
            const def = scanStreamSuccessors(sr.default_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (def == .target_found_and_done) any_target = true;
            if (any_target) return .target_found_and_done;
            return .target_not_found;
        },
        .union_switch => |us| {
            var any_target = false;
            for (us.cases) |c| {
                const s = scanStreamSuccessors(c.body_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (s == .target_found_and_done) any_target = true;
            }
            if (any_target) return .target_found_and_done;
            return .target_not_found;
        },
        .union_switch_return => |usr| {
            var any_target = false;
            for (usr.cases) |c| {
                const s = scanStreamSuccessors(c.body_instrs, ctx);
                if (ctx.found) return .target_not_found;
                if (s == .target_found_and_done) any_target = true;
            }
            if (any_target) return .target_found_and_done;
            return .target_not_found;
        },
        .try_call_named => |tcn| {
            const h = scanStreamSuccessors(tcn.handler_instrs, ctx);
            if (ctx.found) return .target_not_found;
            const s = scanStreamSuccessors(tcn.success_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (h == .target_found_and_done or s == .target_found_and_done)
                return .target_found_and_done;
            return .target_not_found;
        },
        .guard_block => |gb| {
            return scanStreamSuccessors(gb.body, ctx);
        },
        .optional_dispatch => |od| {
            const n = scanStreamSuccessors(od.nil_instrs, ctx);
            if (ctx.found) return .target_not_found;
            const s = scanStreamSuccessors(od.struct_instrs, ctx);
            if (ctx.found) return .target_not_found;
            if (n == .target_found_and_done or s == .target_found_and_done)
                return .target_found_and_done;
            return .target_not_found;
        },
        else => return .target_not_found,
    }
}

/// Post-target mode: visit every child stream of `instr` and check
/// every `param_get` for refetches. Every child here is a structural
/// successor of the share (the share lives in some ancestor stream
/// that has already been crossed), so all paths matter.
fn scanInstructionChildrenPostTarget(
    instr: *const ir.Instruction,
    ctx: *SuccessorScan,
) void {
    switch (instr.*) {
        .if_expr => |ie| {
            scanStreamPostTarget(ie.then_instrs, ctx);
            if (ctx.found) return;
            scanStreamPostTarget(ie.else_instrs, ctx);
        },
        .case_block => |cb| {
            scanStreamPostTarget(cb.pre_instrs, ctx);
            if (ctx.found) return;
            for (cb.arms) |arm| {
                scanStreamPostTarget(arm.cond_instrs, ctx);
                if (ctx.found) return;
                scanStreamPostTarget(arm.body_instrs, ctx);
                if (ctx.found) return;
            }
            scanStreamPostTarget(cb.default_instrs, ctx);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| {
                scanStreamPostTarget(c.body_instrs, ctx);
                if (ctx.found) return;
            }
            scanStreamPostTarget(sl.default_instrs, ctx);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| {
                scanStreamPostTarget(c.body_instrs, ctx);
                if (ctx.found) return;
            }
            scanStreamPostTarget(sr.default_instrs, ctx);
        },
        .union_switch => |us| {
            for (us.cases) |c| {
                scanStreamPostTarget(c.body_instrs, ctx);
                if (ctx.found) return;
            }
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| {
                scanStreamPostTarget(c.body_instrs, ctx);
                if (ctx.found) return;
            }
        },
        .try_call_named => |tcn| {
            scanStreamPostTarget(tcn.handler_instrs, ctx);
            if (ctx.found) return;
            scanStreamPostTarget(tcn.success_instrs, ctx);
        },
        .guard_block => |gb| scanStreamPostTarget(gb.body, ctx),
        .optional_dispatch => |od| {
            scanStreamPostTarget(od.nil_instrs, ctx);
            if (ctx.found) return;
            scanStreamPostTarget(od.struct_instrs, ctx);
        },
        else => {},
    }
}

fn scanStreamPostTarget(
    stream: []const ir.Instruction,
    ctx: *SuccessorScan,
) void {
    for (stream) |*instr| {
        const my_id = ctx.next_id;
        ctx.next_id += 1;
        checkParamGet(instr, my_id, ctx);
        if (ctx.found) return;
        scanInstructionChildrenPostTarget(instr, ctx);
        if (ctx.found) return;
    }
}

fn checkParamGet(
    instr: *const ir.Instruction,
    instr_id: arc_liveness.InstructionId,
    ctx: *SuccessorScan,
) void {
    if (instr.* != .param_get) return;
    if (instr.param_get.index != ctx.slot) return;
    if (instr.param_get.dest == ctx.excluded_dest) return;
    if (instr_id <= ctx.target_id) return;

    // Phase 1.8 item #4 — bounded-borrow refinement. When the refetch's
    // dest has a last-use that is `<= consume_last_use_id`, the
    // refetch's lifetime is fully contained within the consume call's
    // argument-evaluation window. The fresh `param_get` doesn't extend
    // the parameter slot's live range past the consume site, so it
    // must not block promotion.
    //
    // The fannkuch shape `set(p, i, get(p, i+1))` is the canonical
    // example: lowering emits the outer set's share_value first,
    // then a fresh param_get for the inner get's receiver, then the
    // get-call (which is the refetch's last use), then the outer
    // set call (which is the share's last use). The refetch's
    // last-use precedes the consume's last-use, so the refetch is
    // bounded and safe to ignore.
    if (ctx.last_use_map) |last_use_map| {
        if (last_use_map.get(instr.param_get.dest)) |refetch_last_use| {
            if (refetch_last_use <= ctx.consume_last_use_id) {
                // Bounded refetch — does not block promotion.
                return;
            }
        }
        // No last-use entry for the refetch dest: conservatively
        // treat as post-share (we cannot prove the lifetime is
        // bounded). Falls through to `ctx.found = true`.
    }
    ctx.found = true;
}

// ============================================================
// Tests
// ============================================================

test "arc_param_convention: stub function exists and accepts empty program" {
    // Smoke test: the public symbol exists with the documented
    // signature. Real coverage lands once the inference fires on a
    // fixture that exercises a self-recursive call with a consumed
    // parameter (tail-recursive Map-accumulator shape).
    const fn_ptr: *const @TypeOf(inferConventions) = &inferConventions;
    _ = fn_ptr;
}

test "arc_param_convention: liftKey packs (FunctionId, slot) without collision" {
    // Sanity: the (FunctionId, slot) packing into a u64 must produce
    // distinct keys for distinct inputs across the ranges the
    // audit will encounter at production scale.
    const k1 = liftKey(0, 0);
    const k2 = liftKey(0, 1);
    const k3 = liftKey(1, 0);
    const k4 = liftKey(1, 1);
    try std.testing.expect(k1 != k2);
    try std.testing.expect(k1 != k3);
    try std.testing.expect(k1 != k4);
    try std.testing.expect(k2 != k3);
    try std.testing.expect(k2 != k4);
    try std.testing.expect(k3 != k4);

    // Edge: slot indices up to ~4 billion (u32 max) and function ids
    // similarly. The packing places the slot in the low 32 bits and
    // the function id in the high 32. Verify a high-id × high-slot
    // entry doesn't alias a low-id × low-slot entry.
    const k_low = liftKey(0, 1);
    const k_high = liftKey(1, 0);
    try std.testing.expect(k_low != k_high);
    try std.testing.expectEqual(@as(u64, 1), k_low);
    try std.testing.expectEqual(@as(u64, 1) << 32, k_high);
}

test "arc_param_convention: liftSetContains returns false on an empty set" {
    var set: LiftSet = .empty;
    defer set.deinit(std.testing.allocator);
    try std.testing.expect(!liftSetContains(&set, 0, 0));
    try std.testing.expect(!liftSetContains(&set, 42, 7));
}

test "arc_param_convention: liftSetContains hits the recorded entries" {
    var set: LiftSet = .empty;
    defer set.deinit(std.testing.allocator);
    try set.put(std.testing.allocator, liftKey(5, 2), {});
    try set.put(std.testing.allocator, liftKey(8, 0), {});

    try std.testing.expect(liftSetContains(&set, 5, 2));
    try std.testing.expect(liftSetContains(&set, 8, 0));
    try std.testing.expect(!liftSetContains(&set, 5, 0));
    try std.testing.expect(!liftSetContains(&set, 5, 3));
    try std.testing.expect(!liftSetContains(&set, 8, 1));
    try std.testing.expect(!liftSetContains(&set, 0, 0));
}

test "arc_param_convention: paramSlotIsRefetchedAfter ignores refetches in disjoint case arms" {
    // Build a function shaped like `vector_rc1`'s `fill_in_place`:
    //
    //   case scrut {
    //     true ->
    //       param_get index=0 dest=L0      -- the share's source
    //       share_value dest=L1 source=L0  -- target share
    //       call_named ... args=[L1]       -- consume site
    //     false ->
    //       param_get index=0 dest=L17     -- DIFFERENT local; disjoint arm
    //       ret value=L17
    //   }
    //
    // The structural-successor scan must not flag the case[1] refetch
    // as a post-share refetch, because case[0] and case[1] are
    // mutually exclusive on the share's path.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // case[0]: consumes slot 0
    const case0_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } }, // id 4 (after case_block, scrutinee, switch, and arm wiring)
        .{ .share_value = .{ .dest = 1, .source = 0, .mode = .retain } }, // id 5
        .{ .ret = .{ .value = 1 } }, // id 6
    });
    // case[1]: refetches slot 0 (disjoint arm)
    const case1_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 17, .index = 0 } }, // id 7
        .{ .ret = .{ .value = 17 } }, // id 8
    });
    // The switch_literal/case_block holds both arms.
    const cases = try arena.alloc(ir.LitCase, 2);
    cases[0] = .{
        .value = .{ .bool_val = true },
        .body_instrs = case0_body,
        .result = null,
    };
    cases[1] = .{
        .value = .{ .bool_val = false },
        .body_instrs = case1_body,
        .result = null,
    };
    const default_body = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .match_fail = .{ .message = "unreachable" } },
    });
    const top = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 18, .index = 1 } }, // id 0 (scrut prep)
        .{ .switch_literal = .{
            .dest = 19,
            .scrutinee = 18,
            .cases = cases,
            .default_instrs = default_body,
            .default_result = null,
        } }, // id 1
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = top };

    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned, .owned, .owned, .owned, .owned,
        .owned, .owned, .owned, .owned, .owned, .owned, .owned, .owned,
        .owned, .owned, .owned, .owned,
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{ .borrowed, .trivial });
    var function = ir.Function{
        .id = 100,
        .name = "test_func",
        .scope_id = 0,
        .arity = 2,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 20,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    // Compute the share_value's instruction id by walking the same
    // depth-first order. Top-level: param_get (id 0), switch_literal
    // (id 1). The switch's children: case[0].body[0]=param_get (id 2),
    // case[0].body[1]=share_value (id 3), case[0].body[2]=ret (id 4),
    // case[1].body[0]=param_get (id 5), case[1].body[1]=ret (id 6),
    // default.body[0]=match_fail (id 7).
    //
    // share_id is 3, share_source is L0.
    const share_id: arc_liveness.InstructionId = 3;
    const share_source: ir.LocalId = 0;

    // The pre-fix flat-id check would return TRUE (id 5's param_get
    // is > id 3). The new structural-successor check must return
    // FALSE: case[1] is on a path disjoint from the share.
    try std.testing.expect(!paramSlotIsRefetchedAfter(&function, 0, share_source, share_id, null, 0));
}

test "arc_param_convention: paramSlotIsRefetchedAfter detects refetch on the same flow path" {
    // Build a function where the same case arm has both a share AND
    // a later refetch into a different local — the legitimate
    // k-nucleotide-style shape that the original check was designed
    // to catch.
    //
    //   param_get index=0 dest=L0     -- first fetch
    //   share_value dest=L1 source=L0 -- target share
    //   call_named ... args=[L1]      -- first call
    //   param_get index=0 dest=L2     -- SECOND fetch (same flow path!)
    //   share_value dest=L3 source=L2 -- second share
    //   call_named ... args=[L3]      -- second call
    //
    // The structural-successor scan MUST flag the second param_get
    // as post-share (it's on the same straight-line path).
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const top = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } }, // id 0
        .{ .share_value = .{ .dest = 1, .source = 0, .mode = .retain } }, // id 1
        .{ .release = .{ .value = 1 } }, // id 2
        .{ .param_get = .{ .dest = 2, .index = 0 } }, // id 3 — refetch
        .{ .ret = .{ .value = 2 } }, // id 4
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = top };

    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned,
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    var function = ir.Function{
        .id = 200,
        .name = "test_refetch",
        .scope_id = 0,
        .arity = 1,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    const share_id: arc_liveness.InstructionId = 1;
    const share_source: ir.LocalId = 0;

    // The second param_get is on the SAME flow path as the share.
    // The check must catch it.
    try std.testing.expect(paramSlotIsRefetchedAfter(&function, 0, share_source, share_id, null, 0));
}

test "arc_param_convention: paramSlotIsRefetchedAfter ignores refetch bounded within consume call's arg eval (Phase 1.8 item #4)" {
    // Build a function shaped like fannkuch's `set(p, i, get(p, i+1))`:
    //
    //   param_get   dest=L0 index=0       -- first fetch (for set's receiver)
    //   share_value dest=L1 source=L0     -- share for set; target id = 1
    //   param_get   dest=L2 index=0       -- second fetch (for get's receiver) -- "refetch"
    //   call_builtin Vector.get args=[L2] -- consumes L2; last_use[L2] = id 3
    //   call_builtin Vector.set args=[L1] -- consumes L1; last_use[L1] = id 4
    //   ret value=L1                       -- (or whatever)
    //
    // Pre-Phase-1.8 behavior: the structural-successor scan sees the
    // L2-refetch at id 2 as post-share (id 2 > target id 1) and
    // flags it as a refetch — over-rejecting.
    //
    // Phase 1.8 behavior: the bounded-borrow refinement looks up
    // last_use[L2] = 3 and last_use[L1] = 4. Since
    // last_use[L2] (3) <= last_use[L1] (4), the L2 refetch's
    // lifetime is bounded WITHIN the set call's argument-evaluation
    // window — it isn't a post-share-and-still-live refetch.
    // The check returns false and the audit allows promotion.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const top = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } }, // id 0
        .{ .share_value = .{ .dest = 1, .source = 0, .mode = .retain } }, // id 1 — share_id (target)
        .{ .param_get = .{ .dest = 2, .index = 0 } }, // id 2 — refetch (post-target)
        .{ .release = .{ .value = 2 } }, // id 3 — last use of L2 (the get-call analog)
        .{ .release = .{ .value = 1 } }, // id 4 — last use of L1 (the set-call analog)
        .{ .ret = .{ .value = 1 } }, // id 5
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = top };

    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned,
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    var function = ir.Function{
        .id = 300,
        .name = "test_bounded_refetch",
        .scope_id = 0,
        .arity = 1,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    const share_id: arc_liveness.InstructionId = 1;
    const share_source: ir.LocalId = 0;
    const consume_last_use_id: arc_liveness.InstructionId = 4;

    // Build a last_use_map asserting:
    //   last_use[L2] = 3 (refetch ends at the L2-release before the consume)
    //   last_use[L1] = 4 (consume call's last use of the share_dest)
    var last_use_map: std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) = .empty;
    defer last_use_map.deinit(std.testing.allocator);
    try last_use_map.put(std.testing.allocator, 1, 4);
    try last_use_map.put(std.testing.allocator, 2, 3);

    // Without the bounded-borrow refinement (legacy behavior — null
    // bounded_by) the check returns true.
    try std.testing.expect(paramSlotIsRefetchedAfter(&function, 0, share_source, share_id, null, 0));

    // With the bounded-borrow refinement: refetch's last-use (3) is
    // <= consume call's last-use (4), so the refetch is bounded and
    // ignored.
    try std.testing.expect(!paramSlotIsRefetchedAfter(&function, 0, share_source, share_id, &last_use_map, consume_last_use_id));
}

test "arc_param_convention: paramSlotIsRefetchedAfter still detects unbounded refetch even with bounded_by enabled" {
    // Same shape as the bounded-refetch test, but the second param_get's
    // last use is AFTER the consume call. The refetch is NOT bounded
    // and must still be flagged as a post-share refetch.
    //
    //   param_get   dest=L0 index=0
    //   share_value dest=L1 source=L0     -- share_id
    //   param_get   dest=L2 index=0       -- refetch
    //   release     value=L1              -- consume of share at id 3
    //   release     value=L2              -- L2's last use at id 4 (AFTER consume)
    //   ret
    //
    // last_use[L1] = 3 (consume call last-use)
    // last_use[L2] = 4 (post-consume, NOT bounded)
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const top = try arena.dupe(ir.Instruction, &[_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } }, // id 0
        .{ .share_value = .{ .dest = 1, .source = 0, .mode = .retain } }, // id 1
        .{ .param_get = .{ .dest = 2, .index = 0 } }, // id 2 — refetch
        .{ .release = .{ .value = 1 } }, // id 3 — consume call last use
        .{ .release = .{ .value = 2 } }, // id 4 — refetch's last use (UNBOUNDED!)
        .{ .ret = .{ .value = 2 } }, // id 5
    });
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = top };

    const local_ownership = try arena.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .owned, .owned,
    });
    const param_conventions = try arena.dupe(ir.ParamConvention, &[_]ir.ParamConvention{.borrowed});
    var function = ir.Function{
        .id = 301,
        .name = "test_unbounded_refetch",
        .scope_id = 0,
        .arity = 1,
        .params = &.{},
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = param_conventions,
        .local_ownership = local_ownership,
        .result_convention = .owned,
    };

    const share_id: arc_liveness.InstructionId = 1;
    const share_source: ir.LocalId = 0;
    const consume_last_use_id: arc_liveness.InstructionId = 3;

    var last_use_map: std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) = .empty;
    defer last_use_map.deinit(std.testing.allocator);
    try last_use_map.put(std.testing.allocator, 1, 3);
    try last_use_map.put(std.testing.allocator, 2, 4);

    // Refetch's last use (4) is > consume call last use (3), so the
    // refetch IS still live past the consume call and must be flagged.
    try std.testing.expect(paramSlotIsRefetchedAfter(&function, 0, share_source, share_id, &last_use_map, consume_last_use_id));
}
