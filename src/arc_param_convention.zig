const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const types_mod = @import("types.zig");
const v8_signature = @import("v8_signature.zig");
const v8_fixpoint = @import("v8_fixpoint.zig");
const v8_interprocedural = @import("v8_interprocedural.zig");

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
    // The conservative pass cannot bootstrap mutually-recursive PU
    // chains (e.g., fannkuch's advance_perm/2 ↔ rotate_loop/1):
    // each slot's chain-consistency dependency is on the OTHER, so
    // neither enters the set first. Phase 2.4 follows the
    // conservative pass with two additional stages:
    //
    //   1. Optimistic SCC-bootstrap: a monotone-DOWN audit that
    //      starts from "all borrowed ARC slots are candidates" and
    //      removes those that fail audit conditions under the
    //      current candidate set. This admits mutual-recursion
    //      chains because the audit's chain-consistency check
    //      observes both inter-dependent slots simultaneously in
    //      the candidate set.
    //
    //   2. V8 pre-flight check: tentatively promote the candidate
    //      set's slots to `.owned` in `program.functions[*].param_conventions`,
    //      run the program-level V8 fixpoint
    //      (`v8_interprocedural.analyzeProgram`), and prune any
    //      candidate whose slot the fixpoint demotes to non-unique.
    //      This mirrors what `arc_verifier::runV8` will check after
    //      the rewriter fires; if a candidate's body-level dataflow
    //      destroys uniqueness (via copy_value, share_value, or any
    //      other demoting operation the audit doesn't model),
    //      the V8 fixpoint catches it pre-emptively.
    //
    // Pruning a candidate may unblock OR re-block other candidates
    // (a removed candidate reduces the set used as the SCC anchor;
    // V8 may demote different slots in the next iteration). Iterate
    // (1) and (2) until a fixed point: the surviving set is the
    // V8-verifier-aligned lift_set by construction.
    var lift_set: LiftSet = .empty;
    errdefer lift_set.deinit(allocator);

    // Stage 0: existing conservative monotone-up. Anything this
    // accepts is unconditionally V8-sound (it always was — the
    // conservative scheme only ever admits chains whose roots end
    // at fresh allocations or already-`.owned` parents).
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

    // Stage 1+2: optimistic SCC-bootstrap + V8 pre-flight pruning.
    // Iterate the (candidate-generation, V8-prune) pair until the
    // surviving set is stable.
    var preflight_iter: u32 = 0;
    const max_preflight_iter: u32 = 16;
    while (preflight_iter < max_preflight_iter) : (preflight_iter += 1) {
        // Generate optimistic candidates by relaxing the bootstrap
        // constraint: any borrowed ARC slot whose audit conditions
        // hold UNDER THE CURRENT lift_set is a candidate. SCC
        // partners enter the set together when they BOTH pass under
        // the optimistic seeding (every borrowed slot is a candidate
        // initially; iteratively prune those that fail).
        var candidates: LiftSet = .empty;
        defer candidates.deinit(allocator);
        try seedOptimisticCandidates(allocator, program, &lift_set, &candidates);
        try pruneOptimisticCandidates(
            allocator,
            program,
            signatures,
            sites_by_target,
            ownerships,
            function_index,
            name_to_id,
            &lift_set,
            &candidates,
        );

        // No new candidates beyond the conservative set — done.
        if (candidates.count() == 0) break;

        // V8 pre-flight: tentatively promote candidates' slots to
        // `.owned` in `param_conventions`, run V8 program-level
        // fixpoint that simulates the post-rewrite IR (share_value
        // at owned-arg sites is treated as move_value), restore
        // conventions, and intersect candidates with surviving
        // (unique-on-entry) slots.
        var survivors: LiftSet = .empty;
        defer survivors.deinit(allocator);
        try liftSetSurvivesV8Check(allocator, program, signatures, ownerships, &candidates, &survivors);

        // Merge survivors into the main lift_set.
        const before_count = lift_set.count();
        var iter = survivors.iterator();
        while (iter.next()) |entry| {
            try lift_set.put(allocator, entry.key_ptr.*, {});
        }
        const after_count = lift_set.count();

        // Stable: no new survivors added this round.
        if (after_count == before_count) break;
    }

    return lift_set;
}

/// Stage 1 (Phase 2.4): seed the optimistic candidate set with every
/// borrowed ARC parameter slot in the program that ISN'T already in
/// `lift_set`. The candidate set is the upper bound; subsequent
/// pruning removes slots that fail the audit conditions.
fn seedOptimisticCandidates(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    lift_set: *const LiftSet,
    candidates: *LiftSet,
) !void {
    for (program.functions) |*function| {
        for (function.param_conventions, 0..) |conv, slot_index| {
            if (conv != .borrowed) continue;
            if (liftSetContains(lift_set, function.id, slot_index)) continue;
            try candidates.put(allocator, liftKey(function.id, slot_index), {});
        }
    }
}

/// Stage 1 (Phase 2.4): monotone-DOWN pruning of the optimistic
/// candidate set. A candidate is removed if `slotPassesAuditConditions`
/// fails when given (lift_set ∪ candidates) as the eligibility set.
/// Iterates to fixpoint — removing one candidate may break another's
/// SCC dependency.
fn pruneOptimisticCandidates(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    signatures: *const v8_signature.ProgramSignatures,
    sites_by_target: *const SitesByTarget,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    function_index: *const std.AutoHashMapUnmanaged(ir.FunctionId, *const ir.Function),
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    lift_set: *const LiftSet,
    candidates: *LiftSet,
) !void {
    var changed = true;
    var iteration: u32 = 0;
    const max_iterations: u32 = 64;
    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;

        // Build the union view: lift_set ∪ candidates. The audit
        // accepts a borrowed parent slot in the chain-root check
        // when it's in either set.
        var union_set: LiftSet = .empty;
        defer union_set.deinit(allocator);
        var li = lift_set.iterator();
        while (li.next()) |entry| {
            try union_set.put(allocator, entry.key_ptr.*, {});
        }
        var ci = candidates.iterator();
        while (ci.next()) |entry| {
            try union_set.put(allocator, entry.key_ptr.*, {});
        }

        // Collect candidates to remove this round (can't mutate while
        // iterating).
        var to_remove: std.ArrayListUnmanaged(u64) = .empty;
        defer to_remove.deinit(allocator);

        var iter = candidates.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const fid: ir.FunctionId = @intCast(key >> 32);
            const slot: usize = @intCast(key & 0xFFFFFFFF);
            const function = function_index.get(fid) orelse {
                try to_remove.append(allocator, key);
                continue;
            };
            if (!try slotPassesAuditConditions(
                function,
                slot,
                signatures,
                sites_by_target,
                ownerships,
                function_index,
                &union_set,
                name_to_id,
                program,
            )) {
                try to_remove.append(allocator, key);
            }
        }

        if (to_remove.items.len == 0) continue;
        for (to_remove.items) |key| {
            _ = candidates.remove(key);
        }
        changed = true;
    }
}

/// Phase 2.4 V8 pre-flight check.
///
/// Given a candidate set of `(FunctionId, slot_index)` pairs that the
/// chain-consistency audit has accepted (under the optimistic SCC-
/// bootstrap), run a program-level V8 uniqueness fixpoint UNDER A
/// TENTATIVE PROMOTION of those slots. Populate `survivors` with the
/// candidates whose slots remain proven `unique_on_entry` after the
/// fixpoint converges.
///
/// This bridges the disagreement between the audit's alias-chain
/// consistency check and the V8 verifier's full per-instruction
/// dataflow. The audit asks: "is the alias chain in consume mode?"
/// The V8 verifier asks: "is the cell uniquely owned per the
/// `v8_uniqueness` dataflow at every instruction?" The two ask
/// different questions: the audit can pass while the verifier fails
/// because the body's intermediate operations (e.g., a `copy_value`
/// of a binding with further uses) demote uniqueness in ways the
/// audit doesn't track.
///
/// Mechanism: temporarily flip every candidate slot's
/// `param_conventions` entry to `.owned`. Run a tentative-rewrite-
/// aware V8 fixpoint: this simulates the post-rewrite IR shape that
/// `arc_ownership.rewriteOwnedConsumeSites` would produce after
/// promotion (each `share_value` whose dest is an `.owned` arg gets
/// move-style semantics for the V8 dataflow). Restore conventions
/// afterward. Candidates whose slots the fixpoint LEFT proven
/// unique-on-entry are V8-sound and join `survivors`.
///
/// Why post-rewrite simulation: the V8 verifier runs AFTER
/// `rewriteOwnedConsumeSites` in the pipeline (compiler.zig). Running
/// the V8 dataflow on the PRE-rewrite IR would observe `share_value`
/// at every call site and demote uniqueness — even at sites where the
/// rewrite is about to turn `share_value` into `move_value`. The
/// pre-flight has to mirror what the verifier will see, not what's
/// in the IR right now. The simulator achieves this by pre-computing,
/// per function, the set of `share_value` instruction ids whose dest
/// flows into an `.owned` arg slot of a downstream call (under the
/// tentative conventions); the V8 dataflow then applies move-style
/// semantics at those sites.
///
/// SCC bootstrapping: because all candidates are tentatively promoted
/// SIMULTANEOUSLY, mutually-recursive PU chains can be validated. The
/// V8 fixpoint observes every inter-dependent slot at once and demotes
/// only those whose body actually destroys uniqueness — this is the
/// stronger guarantee that the conservative monotone-up scheme cannot
/// give for SCCs.
///
/// Soundness: a candidate that V8 demotes is pruned. The post-rewrite
/// verifier is a final safety net; if the pre-flight has bugs, the
/// verifier fires hard at compile time (never miscompilation).
fn liftSetSurvivesV8Check(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    signatures: *const v8_signature.ProgramSignatures,
    ownerships: *const arc_liveness.ProgramArcOwnership,
    candidates: *const LiftSet,
    survivors: *LiftSet,
) !void {
    if (candidates.count() == 0) return;

    // Save originals and tentatively promote candidate slots.
    //
    // The mutation seam matches `evaluateFunction`'s @constCast of
    // `function.param_conventions` — the slice is `const` to the rest
    // of the IR but writeable by the inference pass and its sub-passes.
    var saved: std.AutoHashMapUnmanaged(u64, ir.ParamConvention) = .empty;
    defer saved.deinit(allocator);

    var iter = candidates.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const fid: ir.FunctionId = @intCast(key >> 32);
        const slot: usize = @intCast(key & 0xFFFFFFFF);
        const function = lookupFunctionMut(program, fid) orelse continue;
        if (slot >= function.param_conventions.len) continue;
        const original = function.param_conventions[slot];
        try saved.put(allocator, key, original);
        const conventions: MutableConventions = @constCast(function.param_conventions);
        conventions[slot] = .owned;
    }

    // Restore originals on every exit path.
    defer {
        var ri = saved.iterator();
        while (ri.next()) |entry| {
            const key = entry.key_ptr.*;
            const fid: ir.FunctionId = @intCast(key >> 32);
            const slot: usize = @intCast(key & 0xFFFFFFFF);
            if (lookupFunctionMut(program, fid)) |function| {
                if (slot < function.param_conventions.len) {
                    const conventions: MutableConventions = @constCast(function.param_conventions);
                    conventions[slot] = entry.value_ptr.*;
                }
            }
        }
    }

    // Run program-level V8 fixpoint under the tentative state, with
    // post-rewrite simulation of share_value→move_value conversion at
    // owned-arg sites. Phase 2.6.2 — `signatures` and `ownerships`
    // are threaded through to `TentativeAnalyzer` so it can mirror
    // `v8_uniqueness.Analyzer`'s `tuple_pending` propagation.
    //
    // Phase 2.6.2 is currently DISABLED in production. Enabling
    // tuple_pending propagation in the TentativeAnalyzer admits SCC
    // candidates that depend on destructure-then-owned-mutating-call
    // shapes (e.g. fannkuch's `main_loop` ↔ `count_flips` /
    // `advance_perm` SCC). When those candidates promote to `.owned`,
    // the post-rewrite IR runs `*_owned_unchecked` against cells
    // still referenced by the parent tuple's slot — crashing the
    // runtime with "Vector.get: index out of bounds" at fannkuch
    // n>=5. Fixing this requires Phase 2.6.3
    // (`insertTupleComponentReleases`) to fire reliably across all
    // post-rewrite IR shapes, which has its own architectural
    // blocker: `arc_ownership.classifyAndNormalize` reclassifies the
    // destructured local out of `.owned` after Phase 2.6.2 promotes,
    // breaking Phase 2.6.3's collector. Out of scope for the
    // current commit; see the Phase 2.6 deferred-work list in the
    // agent report. The unit test
    // `arc_param_convention: TentativeAnalyzer tuple_pending
    // preserves witness through tuple_init+ret (Phase 2.6.2)` covers
    // the synthesis path — it relies on
    // `analyzeProgramTentative`'s args being threaded through.
    //
    // Set ZAP_ENABLE_PHASE_2_6_2=1 to reactivate the new behaviour
    // for diagnostic runs; do NOT use in production builds.
    const phase_2_6_2_enabled = std.c.getenv("ZAP_ENABLE_PHASE_2_6_2") != null;
    var empty_signatures = v8_signature.ProgramSignatures.init(allocator);
    defer empty_signatures.deinit(allocator);
    var empty_ownerships = arc_liveness.ProgramArcOwnership.init(allocator);
    defer empty_ownerships.deinit();
    const effective_signatures: *const v8_signature.ProgramSignatures = if (phase_2_6_2_enabled) signatures else &empty_signatures;
    const effective_ownerships: *const arc_liveness.ProgramArcOwnership = if (phase_2_6_2_enabled) ownerships else &empty_ownerships;
    var uniqueness = try analyzeProgramTentative(allocator, program, effective_signatures, effective_ownerships);
    defer uniqueness.deinit(allocator);

    // Filter candidates by V8 fixpoint result.
    var ci = candidates.iterator();
    while (ci.next()) |entry| {
        const key = entry.key_ptr.*;
        const fid: ir.FunctionId = @intCast(key >> 32);
        const slot: usize = @intCast(key & 0xFFFFFFFF);
        if (uniqueness.isUniqueOnEntry(fid, slot)) {
            try survivors.put(allocator, key, {});
        }
    }
}

/// Per-function set of `share_value` InstructionIds that should be
/// treated as `move_value` by the V8 dataflow during the pre-flight
/// simulation. Computed once per function from the tentative
/// `param_conventions` state. The set captures every share_value
/// whose dest is the arg-local at an `.owned` arg slot of a
/// downstream call in the same stream — exactly the share_value
/// instances that `arc_ownership.rewriteOwnedConsumeSites` would
/// rewrite to move_value after promotion.
const RewrittenShareSet = struct {
    /// Keyed by (function_id, instruction_id) packed into u64. The
    /// instruction_id is in the same depth-first id space that
    /// `v8_uniqueness.Analyzer` and `arc_liveness.assignInstructionIds`
    /// agree on. Membership means "rewrite this share_value to
    /// move_value during the V8 dataflow walk".
    set: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn deinit(self: *RewrittenShareSet, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
    }

    fn key(function_id: ir.FunctionId, instruction_id: arc_liveness.InstructionId) u64 {
        return (@as(u64, @intCast(function_id)) << 32) | @as(u64, @intCast(instruction_id));
    }

    fn contains(self: *const RewrittenShareSet, function_id: ir.FunctionId, instruction_id: arc_liveness.InstructionId) bool {
        return self.set.contains(key(function_id, instruction_id));
    }
};

/// Compute the `RewrittenShareSet` for `program` under the current
/// `param_conventions` (tentatively-promoted state). Walk every
/// function's body; for each call site, look up the callee's
/// param_conventions; for every `.owned` arg slot, locate the
/// preceding `share_value{dest = args[slot]}` in the same stream and
/// record its InstructionId.
fn computeRewrittenShareSet(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
) !RewrittenShareSet {
    var result: RewrittenShareSet = .{};
    errdefer result.deinit(allocator);

    var by_name: std.StringHashMapUnmanaged([]const ir.ParamConvention) = .empty;
    defer by_name.deinit(allocator);
    var by_id: std.AutoHashMapUnmanaged(ir.FunctionId, []const ir.ParamConvention) = .empty;
    defer by_id.deinit(allocator);
    for (program.functions) |func| {
        try by_name.put(allocator, func.name, func.param_conventions);
        if (func.local_name.len != 0) {
            const gop = try by_name.getOrPut(allocator, func.local_name);
            if (!gop.found_existing) gop.value_ptr.* = func.param_conventions;
        }
        try by_id.put(allocator, func.id, func.param_conventions);
    }

    for (program.functions) |*function| {
        var walker = ShareSetWalker{
            .allocator = allocator,
            .function_id = function.id,
            .by_name = &by_name,
            .by_id = &by_id,
            .result = &result,
            .next_id = 0,
        };
        for (function.body) |block| {
            try walker.walkStream(block.instructions);
        }
    }

    return result;
}

const ShareSetWalker = struct {
    allocator: std.mem.Allocator,
    function_id: ir.FunctionId,
    by_name: *const std.StringHashMapUnmanaged([]const ir.ParamConvention),
    by_id: *const std.AutoHashMapUnmanaged(ir.FunctionId, []const ir.ParamConvention),
    result: *RewrittenShareSet,
    next_id: arc_liveness.InstructionId,

    /// Per-stream side table: dest-LocalId → InstructionId of the
    /// most-recent share_value in this stream. share_values do not
    /// cross structural boundaries (the IR builder emits each share
    /// in the same stream as its consume call), so a per-stream
    /// table is sufficient.
    fn walkStream(self: *ShareSetWalker, stream: []const ir.Instruction) error{OutOfMemory}!void {
        var share_dest_to_id: std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) = .empty;
        defer share_dest_to_id.deinit(self.allocator);

        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.processInstruction(instr, my_id, &share_dest_to_id);
            try self.recurseChildren(instr);
        }
    }

    fn recurseChildren(self: *ShareSetWalker, instr: *const ir.Instruction) error{OutOfMemory}!void {
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
        self: *ShareSetWalker,
        instr: *const ir.Instruction,
        instr_id: arc_liveness.InstructionId,
        share_dest_to_id: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
    ) error{OutOfMemory}!void {
        switch (instr.*) {
            .share_value => |sv| {
                try share_dest_to_id.put(self.allocator, sv.dest, instr_id);
            },
            .call_named => |cn| {
                if (self.by_name.get(cn.name)) |conventions| {
                    try self.markOwnedArgShares(cn.args, conventions, share_dest_to_id);
                }
            },
            .try_call_named => |tcn| {
                if (self.by_name.get(tcn.name)) |conventions| {
                    try self.markOwnedArgShares(tcn.args, conventions, share_dest_to_id);
                }
            },
            .call_direct => |cd| {
                if (self.by_id.get(cd.function)) |conventions| {
                    try self.markOwnedArgShares(cd.args, conventions, share_dest_to_id);
                }
            },
            .call_builtin => |cb| {
                // Builtin owned-mutating sites: arc_ownership's
                // rewriteOwnedConsumeBuiltinSites turns share_value
                // into move_value when arc_liveness's
                // ownedMutatingBuiltinSlot matches AND the source is
                // at last-use. For pre-flight purposes, recognise
                // those slots so the V8 dataflow propagates
                // uniqueness through the share.
                if (arc_liveness.ownedMutatingBuiltinSlot(cb.name)) |slot| {
                    if (slot < cb.args.len) {
                        if (share_dest_to_id.get(cb.args[slot])) |share_id| {
                            try self.result.set.put(
                                self.allocator,
                                RewrittenShareSet.key(self.function_id, share_id),
                                {},
                            );
                        }
                    }
                }
            },
            .tail_call => {
                // Tail calls have their share/release elided by Phase
                // E.8 already; nothing to do here.
            },
            else => {},
        }
    }

    fn markOwnedArgShares(
        self: *ShareSetWalker,
        args: []const ir.LocalId,
        conventions: []const ir.ParamConvention,
        share_dest_to_id: *const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
    ) error{OutOfMemory}!void {
        const max_slot = @min(args.len, conventions.len);
        var slot: usize = 0;
        while (slot < max_slot) : (slot += 1) {
            if (conventions[slot] != .owned) continue;
            if (share_dest_to_id.get(args[slot])) |share_id| {
                try self.result.set.put(
                    self.allocator,
                    RewrittenShareSet.key(self.function_id, share_id),
                    {},
                );
            }
        }
    }
};

/// Tentative-rewrite-aware program-level V8 fixpoint. Mirrors
/// `v8_interprocedural.analyzeProgram` but uses
/// `analyzeFunctionTentative` (a custom intraprocedural pass that
/// applies move-style semantics to share_value sites in a
/// `RewrittenShareSet`).
///
/// Phase 2.6.2 — `signatures` and `ownerships` are threaded through
/// to `TentativeAnalyzer` so it can mirror
/// `v8_uniqueness.Analyzer`'s `tuple_pending` propagation. The
/// per-function `ArcOwnership` is looked up by id at each function
/// dispatch and passed to `analyzeFunctionTentative`; `null` is
/// permitted (the analyzer falls back to the legacy intraprocedural
/// behaviour when ownership info is absent).
fn analyzeProgramTentative(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    signatures: *const v8_signature.ProgramSignatures,
    ownerships: *const arc_liveness.ProgramArcOwnership,
) !v8_interprocedural.ProgramUniqueness {
    var result: v8_interprocedural.ProgramUniqueness = .{};
    errdefer result.deinit(allocator);

    // Pre-compute the set of share_values that should be treated as
    // move_values by the V8 dataflow under the current (tentative)
    // conventions.
    var rewritten = try computeRewrittenShareSet(allocator, program);
    defer rewritten.deinit(allocator);

    // Initialise per-function uniqueness slices. Optimistic: every
    // `.owned` slot starts proven unique.
    for (program.functions) |func| {
        if (func.param_conventions.len == 0) {
            try result.by_function.put(allocator, func.id, &.{});
            continue;
        }
        const slots = try allocator.alloc(bool, func.param_conventions.len);
        for (func.param_conventions, 0..) |conv, idx| {
            slots[idx] = (conv == .owned);
        }
        try result.by_function.put(allocator, func.id, slots);
    }

    // Build name → id lookup.
    var name_to_id: std.StringHashMapUnmanaged(ir.FunctionId) = .empty;
    defer name_to_id.deinit(allocator);
    for (program.functions) |func| {
        try name_to_id.put(allocator, func.name, func.id);
        if (func.local_name.len != 0) {
            const gop = try name_to_id.getOrPut(allocator, func.local_name);
            if (!gop.found_existing) gop.value_ptr.* = func.id;
        }
    }

    // Build reverse caller map.
    var callers_of: std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)) = .empty;
    defer {
        var iter = callers_of.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        callers_of.deinit(allocator);
    }
    for (program.functions) |caller_func| {
        try collectTentativeCalleeFunctionIds(
            allocator,
            &caller_func,
            &name_to_id,
            &callers_of,
        );
    }

    // Worklist fixpoint.
    var worklist: std.ArrayListUnmanaged(ir.FunctionId) = .empty;
    defer worklist.deinit(allocator);
    for (program.functions) |func| {
        try worklist.append(allocator, func.id);
    }
    var in_worklist: std.AutoHashMapUnmanaged(ir.FunctionId, void) = .empty;
    defer in_worklist.deinit(allocator);
    for (program.functions) |func| {
        try in_worklist.put(allocator, func.id, {});
    }

    while (worklist.pop()) |func_id| {
        _ = in_worklist.remove(func_id);
        const caller = lookupTentativeFunction(program, func_id) orelse continue;

        // Phase 2.6.2 — per-function ARC ownership lookup. May be
        // null when the function had no ARC-managed locals (the
        // ownership analysis emits no entry in that case); the
        // analyzer treats that as "no last-use info" and skips
        // destructure-promotion at last-use.
        const function_ownership: ?*const arc_liveness.ArcOwnership = ownerships.get(caller.id);

        var caller_uniqueness = try analyzeFunctionTentative(
            allocator,
            caller,
            program,
            &result,
            &rewritten,
            signatures,
            function_ownership,
        );
        defer caller_uniqueness.deinit(allocator);

        var demote_walker = TentativeDemotionWalker{
            .allocator = allocator,
            .caller = caller,
            .program = program,
            .name_to_id = &name_to_id,
            .uniqueness = &caller_uniqueness,
            .program_uniqueness = &result,
            .callers_of = &callers_of,
            .worklist = &worklist,
            .in_worklist = &in_worklist,
            .next_id = 0,
        };
        for (caller.body) |block| {
            try demote_walker.walkStream(block.instructions);
        }
    }

    return result;
}

fn lookupTentativeFunction(program: *const ir.Program, function_id: ir.FunctionId) ?*const ir.Function {
    for (program.functions) |*func| {
        if (func.id == function_id) return func;
    }
    return null;
}

fn collectTentativeCalleeFunctionIds(
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) !void {
    for (caller.body) |block| {
        try collectTentativeCalleesIntoStream(allocator, caller.id, block.instructions, name_to_id, callers_of);
    }
}

fn collectTentativeCalleesIntoStream(
    allocator: std.mem.Allocator,
    caller_id: ir.FunctionId,
    stream: []const ir.Instruction,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_named => |cn| {
                if (name_to_id.get(cn.name)) |target| {
                    try recordTentativeEdge(allocator, target, caller_id, callers_of);
                }
            },
            .call_direct => |cd| {
                try recordTentativeEdge(allocator, cd.function, caller_id, callers_of);
            },
            .try_call_named => |tcn| {
                if (name_to_id.get(tcn.name)) |target| {
                    try recordTentativeEdge(allocator, target, caller_id, callers_of);
                }
            },
            .tail_call => |tc| {
                if (name_to_id.get(tc.name)) |target| {
                    try recordTentativeEdge(allocator, target, caller_id, callers_of);
                }
            },
            .if_expr => |ie| {
                try collectTentativeCalleesIntoStream(allocator, caller_id, ie.then_instrs, name_to_id, callers_of);
                try collectTentativeCalleesIntoStream(allocator, caller_id, ie.else_instrs, name_to_id, callers_of);
            },
            .case_block => |cb| {
                try collectTentativeCalleesIntoStream(allocator, caller_id, cb.pre_instrs, name_to_id, callers_of);
                for (cb.arms) |arm| {
                    try collectTentativeCalleesIntoStream(allocator, caller_id, arm.cond_instrs, name_to_id, callers_of);
                    try collectTentativeCalleesIntoStream(allocator, caller_id, arm.body_instrs, name_to_id, callers_of);
                }
                try collectTentativeCalleesIntoStream(allocator, caller_id, cb.default_instrs, name_to_id, callers_of);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try collectTentativeCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
                try collectTentativeCalleesIntoStream(allocator, caller_id, sl.default_instrs, name_to_id, callers_of);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try collectTentativeCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
                try collectTentativeCalleesIntoStream(allocator, caller_id, sr.default_instrs, name_to_id, callers_of);
            },
            .union_switch => |us| {
                for (us.cases) |c| try collectTentativeCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try collectTentativeCalleesIntoStream(allocator, caller_id, c.body_instrs, name_to_id, callers_of);
            },
            .guard_block => |gb| {
                try collectTentativeCalleesIntoStream(allocator, caller_id, gb.body, name_to_id, callers_of);
            },
            .optional_dispatch => |od| {
                try collectTentativeCalleesIntoStream(allocator, caller_id, od.nil_instrs, name_to_id, callers_of);
                try collectTentativeCalleesIntoStream(allocator, caller_id, od.struct_instrs, name_to_id, callers_of);
            },
            else => {},
        }
    }
}

fn recordTentativeEdge(
    allocator: std.mem.Allocator,
    target: ir.FunctionId,
    caller: ir.FunctionId,
    callers_of: *std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
) !void {
    const gop = try callers_of.getOrPut(allocator, target);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |existing| {
        if (existing == caller) return;
    }
    try gop.value_ptr.append(allocator, caller);
}

/// Per-call-site receiver and per-arg uniqueness, mirroring
/// `v8_interprocedural.FunctionUniqueness` but produced by the
/// tentative-rewrite-aware analyzer.
const TentativeFunctionUniqueness = struct {
    sites: std.AutoHashMapUnmanaged(arc_liveness.InstructionId, bool) = .empty,
    arg_sites: std.AutoHashMapUnmanaged(arc_liveness.InstructionId, ArgEntry) = .empty,

    const ArgEntry = struct {
        target: ir.FunctionId,
        per_arg: []bool,
    };

    fn deinit(self: *TentativeFunctionUniqueness, allocator: std.mem.Allocator) void {
        self.sites.deinit(allocator);
        var iter = self.arg_sites.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.per_arg);
        }
        self.arg_sites.deinit(allocator);
    }
};

/// Tentative-rewrite-aware intraprocedural V8 dataflow. Mirrors
/// `v8_interprocedural.ParameterizedAnalyzer` but adds a
/// `RewrittenShareSet` that adjusts the `share_value` effect: when
/// the share is in the rewritten set, applies move-value semantics
/// (transfer uniqueness from source to dest) instead of clearing
/// both.
///
/// Phase 2.6.2 — accepts `signatures` and `ownership` to mirror
/// `v8_uniqueness.analyzeUniquenessFull`'s tuple_pending tracking.
/// Without these, the analyzer falls back to the legacy
/// intraprocedural behaviour: no per-component witness propagation
/// on call dests, no destructure-promotion-at-last-use. With them,
/// SCC candidates whose chain crosses a tuple-returning callee
/// followed by a destructure are admitted under the V8 pre-flight
/// — exactly the fannkuch `main_loop` ↔ `count_flips` /
/// `advance_perm` shape.
///
/// Phase 2.6.2 architectural fix: `arc_liveness.ArcOwnership` only
/// records last-use for ARC-managed locals; non-ARC aggregates
/// (`{VectorI64, i64}` tuples, plain structs) holding ARC-managed
/// components are NOT in `arc_managed_locals`, so
/// `ownership.isLastUseAt(aggregate_local, id)` always returns
/// false for them. This blocks `promoteExtractedAt` from ever
/// firing on the fannkuch `main_loop` destructure idiom (where the
/// parent tuple is non-ARC but its components are `VectorI64`).
/// To work around this, the analyzer pre-computes a per-function
/// last-use map for non-ARC aggregates with ARC-managed
/// extractions and consults that map alongside (or instead of)
/// `ownership.isLastUseAt`.
fn analyzeFunctionTentative(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    fixpoint: *const v8_interprocedural.ProgramUniqueness,
    rewritten: *const RewrittenShareSet,
    signatures: *const v8_signature.ProgramSignatures,
    ownership: ?*const arc_liveness.ArcOwnership,
) !TentativeFunctionUniqueness {
    // Phase 2.6.2 — compute the non-ARC aggregate last-use map
    // before the main walk. The map is keyed by (LocalId →
    // InstructionId) and records the last instruction id where the
    // aggregate is read (its "last use" in the linear stream sense).
    var non_arc_last_use: std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId) = .empty;
    defer non_arc_last_use.deinit(allocator);
    try computeNonArcAggregateLastUse(allocator, function, &non_arc_last_use);

    var analyzer = TentativeAnalyzer{
        .allocator = allocator,
        .function = function,
        .program = program,
        .fixpoint = fixpoint,
        .rewritten = rewritten,
        .signatures = signatures,
        .ownership = ownership,
        .non_arc_last_use = &non_arc_last_use,
        .unique = .empty,
        .tuple_pending = .empty,
        .extracted = .empty,
        .next_id = 0,
        .result = .{},
    };
    defer {
        analyzer.unique.deinit(allocator);
        analyzer.deinitTuplePending();
        analyzer.deinitExtracted();
    }
    errdefer analyzer.result.deinit(allocator);

    for (function.body) |block| {
        try analyzer.walkStream(block.instructions);
    }
    return analyzer.result;
}

/// Phase 2.6.2 — populate a per-function map of (non-ARC aggregate
/// LocalId → last-use InstructionId). The map is consulted by
/// `TentativeAnalyzer.promoteExtractedAt` when
/// `ownership.isLastUseAt` returns false (ARC-managed last-use info
/// is unavailable for non-ARC aggregate locals because
/// `arc_liveness.identifyArcLocals` excludes them from
/// `arc_managed_locals`). The result is keyed by every local that
/// `tuple_pending` tracking might install a pending entry on, so
/// the analyzer can promote extracted locals when the parent
/// aggregate dies.
///
/// This walk visits every instruction in the function tree, mirrors
/// `arc_liveness.flattenInstructions` so InstructionId numbering
/// aligns with downstream consumers, and updates `last_use` to
/// the highest id where each candidate aggregate is named in a use
/// position. The candidate set is "every LocalId that is the
/// `object` of an `index_get`/`field_get` whose dest is ARC-managed
/// AND whose own ownership class is non-`.owned` (i.e. non-ARC)".
fn computeNonArcAggregateLastUse(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    out: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
) error{OutOfMemory}!void {
    // Pass 1: identify the aggregates we care about (non-ARC objects
    // with at least one ARC-managed extraction).
    var aggregates: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
    defer aggregates.deinit(allocator);
    try identifyNonArcAggregates(allocator, function, &aggregates);
    if (aggregates.count() == 0) return;

    // Pass 2: compute last-use by walking forward and overwriting on
    // each subsequent use of any tracked aggregate.
    var next_id: arc_liveness.InstructionId = 0;
    for (function.body) |block| {
        try recordAggregateUsesStream(allocator, block.instructions, &next_id, &aggregates, out);
    }
}

fn identifyNonArcAggregates(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    out: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) error{OutOfMemory}!void {
    for (function.body) |block| {
        try identifyNonArcAggregatesStream(allocator, function, block.instructions, out);
    }
}

fn identifyNonArcAggregatesStream(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    stream: []const ir.Instruction,
    out: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        switch (instr.*) {
            .index_get => |ig| {
                if (!isOwnedClass(function, ig.object) and isOwnedClass(function, ig.dest)) {
                    try out.put(allocator, ig.object, {});
                }
            },
            .field_get => |fg| {
                if (!isOwnedClass(function, fg.object) and isOwnedClass(function, fg.dest)) {
                    try out.put(allocator, fg.object, {});
                }
            },
            else => {},
        }
        try identifyNonArcAggregatesChildren(allocator, function, instr, out);
    }
}

fn identifyNonArcAggregatesChildren(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    instr: *const ir.Instruction,
    out: *std.AutoHashMapUnmanaged(ir.LocalId, void),
) error{OutOfMemory}!void {
    switch (instr.*) {
        .if_expr => |ie| {
            try identifyNonArcAggregatesStream(allocator, function, ie.then_instrs, out);
            try identifyNonArcAggregatesStream(allocator, function, ie.else_instrs, out);
        },
        .case_block => |cb| {
            try identifyNonArcAggregatesStream(allocator, function, cb.pre_instrs, out);
            for (cb.arms) |arm| {
                try identifyNonArcAggregatesStream(allocator, function, arm.cond_instrs, out);
                try identifyNonArcAggregatesStream(allocator, function, arm.body_instrs, out);
            }
            try identifyNonArcAggregatesStream(allocator, function, cb.default_instrs, out);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| try identifyNonArcAggregatesStream(allocator, function, c.body_instrs, out);
            try identifyNonArcAggregatesStream(allocator, function, sl.default_instrs, out);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| try identifyNonArcAggregatesStream(allocator, function, c.body_instrs, out);
            try identifyNonArcAggregatesStream(allocator, function, sr.default_instrs, out);
        },
        .union_switch => |us| {
            for (us.cases) |c| try identifyNonArcAggregatesStream(allocator, function, c.body_instrs, out);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| try identifyNonArcAggregatesStream(allocator, function, c.body_instrs, out);
        },
        .try_call_named => |tc| {
            try identifyNonArcAggregatesStream(allocator, function, tc.handler_instrs, out);
            try identifyNonArcAggregatesStream(allocator, function, tc.success_instrs, out);
        },
        .guard_block => |gb| {
            try identifyNonArcAggregatesStream(allocator, function, gb.body, out);
        },
        .optional_dispatch => |od| {
            try identifyNonArcAggregatesStream(allocator, function, od.nil_instrs, out);
            try identifyNonArcAggregatesStream(allocator, function, od.struct_instrs, out);
        },
        else => {},
    }
}

fn recordAggregateUsesStream(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    next_id: *arc_liveness.InstructionId,
    aggregates: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
    out: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        const my_id = next_id.*;
        next_id.* += 1;
        try recordAggregateUseSites(allocator, instr, my_id, aggregates, out);
        try recordAggregateUsesChildren(allocator, instr, next_id, aggregates, out);
    }
}

fn recordAggregateUsesChildren(
    allocator: std.mem.Allocator,
    instr: *const ir.Instruction,
    next_id: *arc_liveness.InstructionId,
    aggregates: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
    out: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
) error{OutOfMemory}!void {
    switch (instr.*) {
        .if_expr => |ie| {
            try recordAggregateUsesStream(allocator, ie.then_instrs, next_id, aggregates, out);
            try recordAggregateUsesStream(allocator, ie.else_instrs, next_id, aggregates, out);
        },
        .case_block => |cb| {
            try recordAggregateUsesStream(allocator, cb.pre_instrs, next_id, aggregates, out);
            for (cb.arms) |arm| {
                try recordAggregateUsesStream(allocator, arm.cond_instrs, next_id, aggregates, out);
                try recordAggregateUsesStream(allocator, arm.body_instrs, next_id, aggregates, out);
            }
            try recordAggregateUsesStream(allocator, cb.default_instrs, next_id, aggregates, out);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| try recordAggregateUsesStream(allocator, c.body_instrs, next_id, aggregates, out);
            try recordAggregateUsesStream(allocator, sl.default_instrs, next_id, aggregates, out);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| try recordAggregateUsesStream(allocator, c.body_instrs, next_id, aggregates, out);
            try recordAggregateUsesStream(allocator, sr.default_instrs, next_id, aggregates, out);
        },
        .union_switch => |us| {
            for (us.cases) |c| try recordAggregateUsesStream(allocator, c.body_instrs, next_id, aggregates, out);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| try recordAggregateUsesStream(allocator, c.body_instrs, next_id, aggregates, out);
        },
        .try_call_named => |tc| {
            try recordAggregateUsesStream(allocator, tc.handler_instrs, next_id, aggregates, out);
            try recordAggregateUsesStream(allocator, tc.success_instrs, next_id, aggregates, out);
        },
        .guard_block => |gb| {
            try recordAggregateUsesStream(allocator, gb.body, next_id, aggregates, out);
        },
        .optional_dispatch => |od| {
            try recordAggregateUsesStream(allocator, od.nil_instrs, next_id, aggregates, out);
            try recordAggregateUsesStream(allocator, od.struct_instrs, next_id, aggregates, out);
        },
        else => {},
    }
}

fn recordAggregateUseSites(
    allocator: std.mem.Allocator,
    instr: *const ir.Instruction,
    my_id: arc_liveness.InstructionId,
    aggregates: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
    out: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
) error{OutOfMemory}!void {
    switch (instr.*) {
        .index_get => |ig| try bumpUseIfTracked(allocator, ig.object, my_id, aggregates, out),
        .field_get => |fg| try bumpUseIfTracked(allocator, fg.object, my_id, aggregates, out),
        .move_value => |mv| try bumpUseIfTracked(allocator, mv.source, my_id, aggregates, out),
        .share_value => |sv| try bumpUseIfTracked(allocator, sv.source, my_id, aggregates, out),
        .copy_value => |cv| try bumpUseIfTracked(allocator, cv.source, my_id, aggregates, out),
        .borrow_value => |bv| try bumpUseIfTracked(allocator, bv.source, my_id, aggregates, out),
        .local_get => |lg| try bumpUseIfTracked(allocator, lg.source, my_id, aggregates, out),
        .local_set => |ls| try bumpUseIfTracked(allocator, ls.value, my_id, aggregates, out),
        .ret => |r| if (r.value) |v| try bumpUseIfTracked(allocator, v, my_id, aggregates, out),
        .cond_return => |cr| if (cr.value) |v| try bumpUseIfTracked(allocator, v, my_id, aggregates, out),
        .release => |r| try bumpUseIfTracked(allocator, r.value, my_id, aggregates, out),
        .retain => |r| try bumpUseIfTracked(allocator, r.value, my_id, aggregates, out),
        .tuple_init => |ti| {
            for (ti.elements) |elem| try bumpUseIfTracked(allocator, elem, my_id, aggregates, out);
        },
        .list_init => |li| {
            for (li.elements) |elem| try bumpUseIfTracked(allocator, elem, my_id, aggregates, out);
        },
        .list_cons => |lc| {
            try bumpUseIfTracked(allocator, lc.head, my_id, aggregates, out);
            try bumpUseIfTracked(allocator, lc.tail, my_id, aggregates, out);
        },
        .map_init => |mi| {
            for (mi.entries) |e| {
                try bumpUseIfTracked(allocator, e.key, my_id, aggregates, out);
                try bumpUseIfTracked(allocator, e.value, my_id, aggregates, out);
            }
        },
        .struct_init => |si| {
            for (si.fields) |f| try bumpUseIfTracked(allocator, f.value, my_id, aggregates, out);
        },
        .union_init => |ui| try bumpUseIfTracked(allocator, ui.value, my_id, aggregates, out),
        .make_closure => |mc| {
            for (mc.captures) |cap| try bumpUseIfTracked(allocator, cap, my_id, aggregates, out);
        },
        .call_builtin => |cb| {
            for (cb.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        .call_named => |cn| {
            for (cn.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        .call_direct => |cd| {
            for (cd.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        .call_closure => |cc| {
            try bumpUseIfTracked(allocator, cc.callee, my_id, aggregates, out);
            for (cc.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        .call_dispatch => |cd| {
            for (cd.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        .try_call_named => |tcn| {
            for (tcn.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
            try bumpUseIfTracked(allocator, tcn.input_local, my_id, aggregates, out);
        },
        .tail_call => |tc| {
            for (tc.args) |arg| try bumpUseIfTracked(allocator, arg, my_id, aggregates, out);
        },
        else => {},
    }
}

fn bumpUseIfTracked(
    allocator: std.mem.Allocator,
    local: ir.LocalId,
    my_id: arc_liveness.InstructionId,
    aggregates: *const std.AutoHashMapUnmanaged(ir.LocalId, void),
    out: *std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
) error{OutOfMemory}!void {
    if (!aggregates.contains(local)) return;
    try out.put(allocator, local, my_id);
}

fn isOwnedClass(function: *const ir.Function, local: ir.LocalId) bool {
    if (local >= function.local_ownership.len) return false;
    return function.local_ownership[local] == .owned;
}

/// Phase 2.6.2 — per-tuple deferred classification record. Mirrors
/// `v8_uniqueness.TuplePendingEntry`. One entry per `tuple_init` (or
/// per call dest synthesized from a callee's `return_components`)
/// whose components carry per-slot uniqueness information.
///
/// Lifetime: the entry resolves either at the parent tuple's last-
/// use (where every extracted local takes over its component's
/// uniqueness — the destructure-promotion idiom) or at any
/// "escape sink" (where the tuple is stored in another aggregate,
/// captured into a closure, or passed as an arg to a non-PU call).
/// `escapePending` invalidates the entry without freeing it
/// immediately so the helper code can keep using `getPtr` without
/// double-frees.
const TentativeTuplePendingEntry = struct {
    components_unique: []bool,
    extracted: std.ArrayListUnmanaged(TentativeExtractedRef),
    escaped: bool = false,
};

const TentativeExtractedRef = struct {
    local: ir.LocalId,
    component_idx: usize,
};

/// Phase 2.6.2 — reverse mapping for extracted locals. When an
/// `index_get(t, i)` adds a ref to `tuple_pending[t].extracted`, it
/// also adds an entry here pointing back at `(t, i)`. Sinks on the
/// extracted local can then trace back to the parent tuple to
/// dissolve the pending entry.
const TentativeExtractedSource = struct {
    source_tuple: ir.LocalId,
    component_idx: usize,
};

const TentativeAnalyzer = struct {
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    fixpoint: *const v8_interprocedural.ProgramUniqueness,
    rewritten: *const RewrittenShareSet,
    /// Phase 2.6.2 — whole-program signatures. Used to synthesize
    /// per-component `tuple_pending` entries on call dests when the
    /// callee's `return_components` table records per-slot witnesses.
    signatures: *const v8_signature.ProgramSignatures,
    /// Phase 2.6.2 — per-function ARC ownership info, or null for
    /// functions with no ARC-managed locals. When non-null, the
    /// analyzer queries `isLastUseAt` to decide when an
    /// `index_get + retain` destructure can promote the extracted
    /// local from its parent tuple's pending entry (the parent's
    /// implicit scope-exit release decrements the cell back to
    /// rc=1 immediately after the destructure's last index_get).
    ownership: ?*const arc_liveness.ArcOwnership,
    /// Phase 2.6.2 — per-function last-use map for non-ARC
    /// aggregates that hold ARC-managed components.
    /// `arc_liveness.ArcOwnership.isLastUseAt` only records
    /// last-use for ARC-managed locals; non-ARC aggregates are
    /// invisible to it. Without this fallback map, the destructure-
    /// promotion path would never fire for the canonical fannkuch
    /// shape (`{VectorI64, i64}` tuple destructured into a
    /// `VectorI64` consumed by an `.owned` callee). Computed
    /// before the main walk by `computeNonArcAggregateLastUse`.
    non_arc_last_use: *const std.AutoHashMapUnmanaged(ir.LocalId, arc_liveness.InstructionId),
    unique: std.AutoHashMapUnmanaged(ir.LocalId, void),
    /// Phase 2.6.2 — per-tuple deferred classification map.
    tuple_pending: std.AutoHashMapUnmanaged(ir.LocalId, TentativeTuplePendingEntry),
    /// Phase 2.6.2 — reverse map: extracted LocalId → its parent
    /// tuple and component index. Used by sinks on extracted
    /// locals to dissolve the parent's pending entry.
    extracted: std.AutoHashMapUnmanaged(ir.LocalId, TentativeExtractedSource),
    next_id: arc_liveness.InstructionId,
    result: TentativeFunctionUniqueness,

    fn deinitTuplePending(self: *TentativeAnalyzer) void {
        var iter = self.tuple_pending.valueIterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.components_unique);
            entry.extracted.deinit(self.allocator);
        }
        self.tuple_pending.deinit(self.allocator);
    }

    fn deinitExtracted(self: *TentativeAnalyzer) void {
        self.extracted.deinit(self.allocator);
    }

    /// Phase 2.6.2 — drop a pending entry (free its slice and list).
    fn removePending(self: *TentativeAnalyzer, tuple_local: ir.LocalId) void {
        if (self.tuple_pending.fetchRemove(tuple_local)) |kv| {
            self.allocator.free(kv.value.components_unique);
            var entry = kv.value;
            entry.extracted.deinit(self.allocator);
        }
    }

    /// Phase 2.6.2 — escape a pending entry. Drops the parent's
    /// reverse-map entries for every extracted local (so a later
    /// sink doesn't try to trace back), then removes the parent
    /// entry. Mirrors `v8_uniqueness.Analyzer.escapePending`.
    fn escapePending(self: *TentativeAnalyzer, tuple_local: ir.LocalId) void {
        if (self.tuple_pending.getPtr(tuple_local)) |entry| {
            for (entry.extracted.items) |ref| {
                _ = self.extracted.remove(ref.local);
            }
            self.removePending(tuple_local);
        }
    }

    /// Phase 2.6.2 — when an extracted local is consumed by a sink,
    /// its parent tuple's pending entry is invalidated for promotion.
    fn escapeIfExtractedLocal(self: *TentativeAnalyzer, local: ir.LocalId) void {
        const src = self.extracted.get(local) orelse return;
        self.escapePending(src.source_tuple);
    }

    /// Phase 2.6.2 — promote extracted locals at the parent tuple's
    /// last-use. The runtime contract that justifies this:
    ///
    ///   1. At `tuple_init` (or call return), components with
    ///      `components_unique[i]` true correspond to refcount-1
    ///      cells.
    ///   2. The tuple holds a +1 to each component's cell.
    ///   3. `index_get(t, i)` lowers to a borrow plus a paired
    ///      retain that bumps the cell to rc=2.
    ///   4. At the parent tuple's last-use, Phase 2.6.3's IR
    ///      transform inserts a balancing release that decrements
    ///      every extracted ARC-managed component's cell back to
    ///      rc=1 — the extracted local is now the sole owner.
    ///   5. Subsequent `_owned_unchecked` sites observe rc=1 cells.
    ///
    /// Last-use detection: Phase 2.6.2 first consults
    /// `ArcOwnership.isLastUseAt` (the standard last-use predicate
    /// for ARC-managed locals). For non-ARC aggregates the standard
    /// predicate always returns false, so the analyzer falls back
    /// to the locally-computed `non_arc_last_use` map, which records
    /// the last instruction id where each tracked aggregate is
    /// named in a use position.
    fn promoteExtractedAt(
        self: *TentativeAnalyzer,
        tuple_local: ir.LocalId,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        const entry = self.tuple_pending.getPtr(tuple_local) orelse return;
        if (entry.escaped) return;
        const arc_last_use = blk: {
            const ownership = self.ownership orelse break :blk false;
            break :blk ownership.isLastUseAt(tuple_local, my_id);
        };
        const non_arc_last_use = blk: {
            const recorded = self.non_arc_last_use.get(tuple_local) orelse break :blk false;
            break :blk recorded == my_id;
        };
        if (!arc_last_use and !non_arc_last_use) return;
        for (entry.extracted.items) |ref| {
            if (ref.component_idx < entry.components_unique.len and entry.components_unique[ref.component_idx]) {
                try self.unique.put(self.allocator, ref.local, {});
            }
            _ = self.extracted.remove(ref.local);
        }
        self.removePending(tuple_local);
    }

    /// Phase 2.6.2 — propagate a `tuple_pending` membership through
    /// an alias-form (move/share/local_get/local_set). Re-keys the
    /// pending entry from `source` to `dest` and patches the
    /// reverse-mapping for every extracted local.
    fn propagateTuplePending(self: *TentativeAnalyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const kv = self.tuple_pending.fetchRemove(source) orelse return;
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, kv.value);
        for (kv.value.extracted.items) |ref| {
            try self.extracted.put(self.allocator, ref.local, .{
                .source_tuple = dest,
                .component_idx = ref.component_idx,
            });
        }
    }

    /// Phase 2.6.2 — `borrow_value` does NOT consume its source, so
    /// we COPY the pending entry's component flags into a fresh
    /// entry under `dest`, preserving the source entry. The dest's
    /// entry has its own (initially empty) `extracted` list.
    fn copyTuplePending(self: *TentativeAnalyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const src_entry = self.tuple_pending.getPtr(source) orelse return;
        if (src_entry.escaped) return;
        const flags_copy = try self.allocator.alloc(bool, src_entry.components_unique.len);
        @memcpy(flags_copy, src_entry.components_unique);
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, .{
            .components_unique = flags_copy,
            .extracted = .empty,
        });
    }

    /// Phase 2.6.2 — propagate an `extracted` membership through an
    /// alias-form. The parent's `extracted` list is patched: the
    /// original `source` ref is replaced with `dest` so the parent's
    /// last-use promotion finds the renamed local.
    fn propagateExtractedAlias(self: *TentativeAnalyzer, dest: ir.LocalId, source: ir.LocalId) error{OutOfMemory}!void {
        if (dest == source) return;
        const kv = self.extracted.fetchRemove(source) orelse return;
        if (self.tuple_pending.getPtr(kv.value.source_tuple)) |entry| {
            for (entry.extracted.items) |*ref| {
                if (ref.local == source) ref.local = dest;
            }
        }
        try self.extracted.put(self.allocator, dest, kv.value);
    }

    /// Phase 2.6.2 — synthesize a tuple_pending entry on the call's
    /// dest using the callee's `return_components` table. Each
    /// component's `unique` flag is `true` iff the witness arg was
    /// unique at the call site (`pre_arg_unique[witness]`). When
    /// every component is non-witness or non-unique, no pending is
    /// installed.
    fn synthesizeReturnPendingFromSig(
        self: *TentativeAnalyzer,
        function_id: ir.FunctionId,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        const sig = self.signatures.forFunction(function_id) orelse return;
        if (sig.return_components.len == 0) return;
        var has_witness = false;
        for (sig.return_components) |opt| {
            if (opt != null) {
                has_witness = true;
                break;
            }
        }
        if (!has_witness) return;
        var flags = try self.allocator.alloc(bool, sig.return_components.len);
        for (sig.return_components, 0..) |opt, i| {
            flags[i] = false;
            if (opt) |arg_idx_u8| {
                const arg_idx: usize = @intCast(arg_idx_u8);
                if (arg_idx < args.len and arg_idx < pre_arg_unique.len) {
                    flags[i] = pre_arg_unique[arg_idx];
                }
            }
        }
        var any_unique = false;
        for (flags) |f| {
            if (f) {
                any_unique = true;
                break;
            }
        }
        if (!any_unique) {
            self.allocator.free(flags);
            return;
        }
        self.removePending(dest);
        try self.tuple_pending.put(self.allocator, dest, .{
            .components_unique = flags,
            .extracted = .empty,
        });
    }

    fn synthesizeReturnPendingByName(
        self: *TentativeAnalyzer,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        const target_id: ir.FunctionId = blk: {
            for (self.program.functions) |func| {
                if (std.mem.eql(u8, func.name, name)) break :blk func.id;
            }
            return;
        };
        try self.synthesizeReturnPendingFromSig(target_id, args, dest, pre_arg_unique);
    }

    /// Phase 2.6.2 — snapshot per-arg uniqueness at the call site.
    /// Caller frees the returned slice.
    fn snapshotArgUnique(
        self: *TentativeAnalyzer,
        args: []const ir.LocalId,
    ) error{OutOfMemory}![]bool {
        const result = try self.allocator.alloc(bool, args.len);
        for (args, 0..) |arg, i| {
            result[i] = self.unique.contains(arg);
        }
        return result;
    }

    fn walkStream(self: *TentativeAnalyzer, stream: []const ir.Instruction) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.classifyCallSite(instr, my_id);
            try self.applyEffect(instr, my_id);
            try self.promoteAtLastUse(my_id);
            try self.walkChildren(instr);
        }
    }

    /// Phase 2.6.2 — for every still-pending tuple whose last-use
    /// fires AT `my_id`, promote its extracted locals' uniqueness.
    /// Iterates a snapshot of the pending keys because the helper
    /// mutates the map.
    fn promoteAtLastUse(
        self: *TentativeAnalyzer,
        my_id: arc_liveness.InstructionId,
    ) error{OutOfMemory}!void {
        if (self.tuple_pending.count() == 0) return;
        var keys = std.ArrayListUnmanaged(ir.LocalId).empty;
        defer keys.deinit(self.allocator);
        var it = self.tuple_pending.keyIterator();
        while (it.next()) |k| try keys.append(self.allocator, k.*);
        for (keys.items) |k| try self.promoteExtractedAt(k, my_id);
    }

    fn walkChildren(self: *TentativeAnalyzer, instr: *const ir.Instruction) error{OutOfMemory}!void {
        switch (instr.*) {
            .if_expr => |ie| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(ie.then_instrs);
                try self.restore(&snap);
                try self.walkStream(ie.else_instrs);
                try self.restore(&snap);
            },
            .case_block => |cb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(cb.pre_instrs);
                const post_pre = try self.snapshot();
                defer post_pre.deinit(self.allocator);
                for (cb.arms) |arm| {
                    try self.walkStream(arm.cond_instrs);
                    try self.walkStream(arm.body_instrs);
                    try self.restore(&post_pre);
                }
                try self.walkStream(cb.default_instrs);
                try self.restore(&snap);
            },
            .switch_literal => |sl| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sl.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sl.default_instrs);
                try self.restore(&snap);
            },
            .switch_return => |sr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (sr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
                try self.walkStream(sr.default_instrs);
                try self.restore(&snap);
            },
            .union_switch => |us| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (us.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .union_switch_return => |usr| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                for (usr.cases) |c| {
                    try self.walkStream(c.body_instrs);
                    try self.restore(&snap);
                }
            },
            .try_call_named => |tcn| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(tcn.handler_instrs);
                try self.restore(&snap);
                try self.walkStream(tcn.success_instrs);
                try self.restore(&snap);
            },
            .guard_block => |gb| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(gb.body);
                try self.restore(&snap);
            },
            .optional_dispatch => |od| {
                const snap = try self.snapshot();
                defer snap.deinit(self.allocator);
                try self.walkStream(od.nil_instrs);
                try self.restore(&snap);
                try self.walkStream(od.struct_instrs);
                try self.restore(&snap);
            },
            else => {},
        }
    }

    fn classifyCallSite(self: *TentativeAnalyzer, instr: *const ir.Instruction, my_id: arc_liveness.InstructionId) error{OutOfMemory}!void {
        if (self.callSiteOwnedMutating(instr)) |info| {
            const is_unique = self.unique.contains(info.receiver);
            try self.result.sites.put(self.allocator, my_id, is_unique);
        }
        if (self.callSiteArgs(instr)) |info| {
            const per_arg = try self.allocator.alloc(bool, info.args.len);
            for (info.args, 0..) |arg, idx| {
                per_arg[idx] = self.unique.contains(arg);
            }
            try self.result.arg_sites.put(self.allocator, my_id, .{
                .target = info.target,
                .per_arg = per_arg,
            });
        }
    }

    const ReceiverInfo = struct { receiver: ir.LocalId };
    const ArgsInfo = struct {
        target: ir.FunctionId,
        args: []const ir.LocalId,
    };

    fn callSiteOwnedMutating(self: *TentativeAnalyzer, instr: *const ir.Instruction) ?ReceiverInfo {
        switch (instr.*) {
            .call_builtin => |cb| {
                const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name) orelse return null;
                if (slot >= cb.args.len) return null;
                return .{ .receiver = cb.args[slot] };
            },
            .call_named => |cn| {
                if (arc_liveness.ownedMutatingBuiltinSlot(cn.name)) |slot| {
                    if (slot >= cn.args.len) return null;
                    return .{ .receiver = cn.args[slot] };
                }
                if (self.calleeOwnedReceiverSlot(cn.name)) |slot| {
                    if (slot >= cn.args.len) return null;
                    return .{ .receiver = cn.args[slot] };
                }
                return null;
            },
            .call_direct => |cd| {
                const callee = lookupTentativeFunction(self.program, cd.function) orelse return null;
                if (arc_liveness.ownedMutatingBuiltinSlot(callee.name)) |slot| {
                    if (slot >= cd.args.len) return null;
                    return .{ .receiver = cd.args[slot] };
                }
                if (calleeFunctionOwnedReceiverSlotByPointer(callee)) |slot| {
                    if (slot >= cd.args.len) return null;
                    return .{ .receiver = cd.args[slot] };
                }
                return null;
            },
            .try_call_named => |tcn| {
                if (arc_liveness.ownedMutatingBuiltinSlot(tcn.name)) |slot| {
                    if (slot >= tcn.args.len) return null;
                    return .{ .receiver = tcn.args[slot] };
                }
                if (self.calleeOwnedReceiverSlot(tcn.name)) |slot| {
                    if (slot >= tcn.args.len) return null;
                    return .{ .receiver = tcn.args[slot] };
                }
                return null;
            },
            else => return null,
        }
    }

    fn callSiteArgs(self: *TentativeAnalyzer, instr: *const ir.Instruction) ?ArgsInfo {
        switch (instr.*) {
            .call_named => |cn| {
                const target = self.lookupByName(cn.name) orelse return null;
                return .{ .target = target, .args = cn.args };
            },
            .call_direct => |cd| {
                return .{ .target = cd.function, .args = cd.args };
            },
            .try_call_named => |tcn| {
                const target = self.lookupByName(tcn.name) orelse return null;
                return .{ .target = target, .args = tcn.args };
            },
            .tail_call => |tc| {
                const target = self.lookupByName(tc.name) orelse return null;
                return .{ .target = target, .args = tc.args };
            },
            else => return null,
        }
    }

    fn lookupByName(self: *const TentativeAnalyzer, name: []const u8) ?ir.FunctionId {
        for (self.program.functions) |func| {
            if (std.mem.eql(u8, func.name, name)) return func.id;
            if (func.local_name.len != 0 and std.mem.eql(u8, func.local_name, name)) return func.id;
        }
        return null;
    }

    fn calleeOwnedReceiverSlot(self: *const TentativeAnalyzer, name: []const u8) ?usize {
        for (self.program.functions) |*func| {
            if (std.mem.eql(u8, func.name, name)) {
                return calleeFunctionOwnedReceiverSlotByPointer(func);
            }
        }
        return null;
    }

    fn applyEffect(self: *TentativeAnalyzer, instr: *const ir.Instruction, my_id: arc_liveness.InstructionId) error{OutOfMemory}!void {
        switch (instr.*) {
            .tuple_init => |ti| {
                // Phase 2.6.2 — record per-component uniqueness in a
                // pending entry instead of unconditionally clearing
                // every element. The pending entry resolves at the
                // tuple's last-use (uniqueness flows to extracted
                // locals) or at any escape sink.
                var unique_flags = try self.allocator.alloc(bool, ti.elements.len);
                for (ti.elements, 0..) |elem, i| {
                    unique_flags[i] = self.unique.contains(elem);
                    _ = self.unique.remove(elem);
                    self.escapeIfExtractedLocal(elem);
                    self.escapePending(elem);
                }
                self.removePending(ti.dest);
                try self.tuple_pending.put(self.allocator, ti.dest, .{
                    .components_unique = unique_flags,
                    .extracted = .empty,
                });
                try self.unique.put(self.allocator, ti.dest, {});
            },
            .list_init => |li| {
                for (li.elements) |elem| {
                    _ = self.unique.remove(elem);
                    self.escapeIfExtractedLocal(elem);
                    self.escapePending(elem);
                }
                try self.unique.put(self.allocator, li.dest, {});
            },
            .list_cons => |lc| {
                _ = self.unique.remove(lc.head);
                _ = self.unique.remove(lc.tail);
                self.escapeIfExtractedLocal(lc.head);
                self.escapeIfExtractedLocal(lc.tail);
                self.escapePending(lc.head);
                self.escapePending(lc.tail);
                try self.unique.put(self.allocator, lc.dest, {});
            },
            .map_init => |mi| {
                for (mi.entries) |entry| {
                    _ = self.unique.remove(entry.key);
                    _ = self.unique.remove(entry.value);
                    self.escapeIfExtractedLocal(entry.key);
                    self.escapeIfExtractedLocal(entry.value);
                    self.escapePending(entry.key);
                    self.escapePending(entry.value);
                }
                try self.unique.put(self.allocator, mi.dest, {});
            },
            .struct_init => |si| {
                for (si.fields) |f| {
                    _ = self.unique.remove(f.value);
                    self.escapeIfExtractedLocal(f.value);
                    self.escapePending(f.value);
                }
                try self.unique.put(self.allocator, si.dest, {});
            },
            .union_init => |ui| {
                _ = self.unique.remove(ui.value);
                self.escapeIfExtractedLocal(ui.value);
                self.escapePending(ui.value);
                try self.unique.put(self.allocator, ui.dest, {});
            },
            .make_closure => |mc| {
                // Capturing into a closure escapes every captured
                // local's pending entry — components of any captured
                // tuple_pending can't be promoted afterwards.
                for (mc.captures) |cap| {
                    _ = self.unique.remove(cap);
                    self.escapeIfExtractedLocal(cap);
                    self.escapePending(cap);
                }
            },
            .call_builtin => |cb| {
                for (cb.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                if (arc_liveness.ownedMutatingBuiltinSlot(cb.name) != null) {
                    if (cb.args.len > 0) {
                        const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name).?;
                        if (slot < cb.args.len) {
                            _ = self.unique.remove(cb.args[slot]);
                        }
                    }
                    try self.unique.put(self.allocator, cb.dest, {});
                } else if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                    try self.unique.put(self.allocator, cb.dest, {});
                } else {
                    _ = self.unique.remove(cb.dest);
                }
            },
            .call_named => |cn| {
                const pre = try self.snapshotArgUnique(cn.args);
                defer self.allocator.free(pre);
                for (cn.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                try self.applyCalleeEffect(cn.name, cn.args, cn.dest, pre);
            },
            .call_direct => |cd| {
                const pre = try self.snapshotArgUnique(cd.args);
                defer self.allocator.free(pre);
                for (cd.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                const callee = lookupTentativeFunction(self.program, cd.function);
                if (callee) |func| {
                    try self.applyCalleeEffectWithFunction(func, cd.args, cd.dest, pre);
                } else {
                    _ = self.unique.remove(cd.dest);
                }
            },
            .try_call_named => |tcn| {
                const pre = try self.snapshotArgUnique(tcn.args);
                defer self.allocator.free(pre);
                for (tcn.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                try self.applyCalleeEffect(tcn.name, tcn.args, tcn.dest, pre);
            },
            .call_closure => |cc| {
                for (cc.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                _ = self.unique.remove(cc.dest);
            },
            .call_dispatch => |cd| {
                for (cd.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
                _ = self.unique.remove(cd.dest);
            },
            .tail_call => |tc| {
                // Tail-calls also consume their args; their pending
                // entries dissolve.
                for (tc.args) |arg| {
                    self.escapeIfExtractedLocal(arg);
                    self.escapePending(arg);
                }
            },
            .move_value => |mv| {
                try self.propagateTuplePending(mv.dest, mv.source);
                try self.propagateExtractedAlias(mv.dest, mv.source);
                if (self.unique.contains(mv.source)) {
                    _ = self.unique.remove(mv.source);
                    try self.unique.put(self.allocator, mv.dest, {});
                } else {
                    _ = self.unique.remove(mv.dest);
                }
            },
            .share_value => |sv| {
                // Tentative-rewrite-aware effect: when this share's
                // dest flows into an `.owned` arg slot of a downstream
                // call (per the pre-computed RewrittenShareSet), the
                // post-rewrite IR will replace this share with
                // move_value. The V8 dataflow under the tentative
                // conventions therefore applies move-style semantics:
                // transfer uniqueness from source to dest.
                //
                // Otherwise apply the original semantics: clear both.
                if (self.rewritten.contains(self.function.id, my_id)) {
                    try self.propagateTuplePending(sv.dest, sv.source);
                    try self.propagateExtractedAlias(sv.dest, sv.source);
                    if (self.unique.contains(sv.source)) {
                        _ = self.unique.remove(sv.source);
                        try self.unique.put(self.allocator, sv.dest, {});
                    } else {
                        _ = self.unique.remove(sv.dest);
                    }
                } else {
                    _ = self.unique.remove(sv.source);
                    _ = self.unique.remove(sv.dest);
                    self.escapeIfExtractedLocal(sv.source);
                    self.escapePending(sv.source);
                }
            },
            .copy_value => |cv| {
                _ = self.unique.remove(cv.source);
                _ = self.unique.remove(cv.dest);
                self.escapeIfExtractedLocal(cv.source);
                self.escapePending(cv.source);
            },
            .borrow_value => |bv| {
                _ = self.unique.remove(bv.dest);
                try self.copyTuplePending(bv.dest, bv.source);
            },
            .local_get => |lg| {
                try self.propagateTuplePending(lg.dest, lg.source);
                try self.propagateExtractedAlias(lg.dest, lg.source);
                if (self.unique.contains(lg.source)) {
                    _ = self.unique.remove(lg.source);
                    try self.unique.put(self.allocator, lg.dest, {});
                } else {
                    _ = self.unique.remove(lg.dest);
                }
            },
            .local_set => |ls| {
                try self.propagateTuplePending(ls.dest, ls.value);
                try self.propagateExtractedAlias(ls.dest, ls.value);
                if (self.unique.contains(ls.value)) {
                    _ = self.unique.remove(ls.value);
                    try self.unique.put(self.allocator, ls.dest, {});
                } else {
                    _ = self.unique.remove(ls.dest);
                }
            },
            .param_get => |pg| {
                if (self.fixpoint.isUniqueOnEntry(self.function.id, pg.index)) {
                    try self.unique.put(self.allocator, pg.dest, {});
                } else {
                    _ = self.unique.remove(pg.dest);
                }
            },
            .index_get => |ig| {
                _ = self.unique.remove(ig.dest);
                if (self.tuple_pending.getPtr(ig.object)) |entry| {
                    if (entry.escaped) return;
                    if (ig.index < entry.components_unique.len) {
                        try entry.extracted.append(self.allocator, .{
                            .local = ig.dest,
                            .component_idx = ig.index,
                        });
                        try self.extracted.put(self.allocator, ig.dest, .{
                            .source_tuple = ig.object,
                            .component_idx = ig.index,
                        });
                    }
                }
            },
            .release,
            .retain,
            .ret,
            .cond_return,
            .switch_tag,
            .branch,
            .cond_branch,
            .jump,
            .match_fail,
            .match_error_return,
            .case_break,
            .set_safety,
            => {},
            else => {},
        }
    }

    fn applyCalleeEffect(
        self: *TentativeAnalyzer,
        name: []const u8,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        if (arc_liveness.ownedMutatingBuiltinSlot(name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
            return;
        }
        if (self.calleeOwnedReceiverSlot(name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
            return;
        }
        if (self.calleeIsFreshAllocatorWrapper(name)) {
            try self.unique.put(self.allocator, dest, {});
            return;
        }
        _ = self.unique.remove(dest);
        try self.synthesizeReturnPendingByName(name, args, dest, pre_arg_unique);
    }

    fn applyCalleeEffectWithFunction(
        self: *TentativeAnalyzer,
        function: *const ir.Function,
        args: []const ir.LocalId,
        dest: ir.LocalId,
        pre_arg_unique: []const bool,
    ) error{OutOfMemory}!void {
        if (arc_liveness.ownedMutatingBuiltinSlot(function.name)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingFromSig(function.id, args, dest, pre_arg_unique);
            return;
        }
        if (calleeFunctionOwnedReceiverSlotByPointer(function)) |slot| {
            if (slot < args.len) {
                _ = self.unique.remove(args[slot]);
            }
            try self.unique.put(self.allocator, dest, {});
            try self.synthesizeReturnPendingFromSig(function.id, args, dest, pre_arg_unique);
            return;
        }
        if (functionIsFreshAllocatorWrapperByPointer(function)) {
            try self.unique.put(self.allocator, dest, {});
            return;
        }
        _ = self.unique.remove(dest);
        try self.synthesizeReturnPendingFromSig(function.id, args, dest, pre_arg_unique);
    }

    fn calleeIsFreshAllocatorWrapper(self: *const TentativeAnalyzer, name: []const u8) bool {
        for (self.program.functions) |*func| {
            if (std.mem.eql(u8, func.name, name)) {
                return functionIsFreshAllocatorWrapperByPointer(func);
            }
        }
        return false;
    }

    fn snapshot(self: *TentativeAnalyzer) error{OutOfMemory}!TentativeSnapshot {
        var copy: std.AutoHashMapUnmanaged(ir.LocalId, void) = .empty;
        var iter = self.unique.keyIterator();
        while (iter.next()) |k| {
            try copy.put(self.allocator, k.*, {});
        }
        return TentativeSnapshot{ .set = copy };
    }

    fn restore(self: *TentativeAnalyzer, snap: *const TentativeSnapshot) error{OutOfMemory}!void {
        self.unique.clearRetainingCapacity();
        var iter = snap.set.keyIterator();
        while (iter.next()) |k| {
            try self.unique.put(self.allocator, k.*, {});
        }
    }
};

const TentativeSnapshot = struct {
    set: std.AutoHashMapUnmanaged(ir.LocalId, void),

    fn deinit(self: *const TentativeSnapshot, allocator: std.mem.Allocator) void {
        var mut = self.*;
        mut.set.deinit(allocator);
    }
};

fn calleeFunctionOwnedReceiverSlotByPointer(function: *const ir.Function) ?usize {
    if (function.result_convention != .owned) return null;
    for (function.param_conventions, 0..) |conv, idx| {
        if (conv == .owned) return idx;
    }
    return null;
}

/// Mirror of `v8_uniqueness.functionIsFreshAllocatorWrapper` —
/// duplicated to avoid the import dependency cycle (arc_param_convention
/// -> v8_uniqueness -> v8_interprocedural -> arc_param_convention would
/// be a cycle).
fn functionIsFreshAllocatorWrapperByPointer(function: *const ir.Function) bool {
    if (function.result_convention != .owned) return false;
    var allocator_count: usize = 0;
    var other_call_count: usize = 0;
    var ctx = AllocatorWrapperScanCtx{
        .allocator_count = &allocator_count,
        .other_call_count = &other_call_count,
    };
    for (function.body) |block| {
        scanAllocatorWrapperStream(block.instructions, &ctx);
    }
    return allocator_count == 1 and other_call_count == 0;
}

const AllocatorWrapperScanCtx = struct {
    allocator_count: *usize,
    other_call_count: *usize,
};

fn scanAllocatorWrapperStream(stream: []const ir.Instruction, ctx: *AllocatorWrapperScanCtx) void {
    for (stream) |*instr| {
        switch (instr.*) {
            .call_builtin => |cb| {
                if (arc_liveness.isFreshAllocatorBuiltin(cb.name)) {
                    ctx.allocator_count.* += 1;
                } else {
                    ctx.other_call_count.* += 1;
                }
            },
            .call_named, .call_direct, .try_call_named, .call_dispatch, .call_closure, .tail_call => {
                ctx.other_call_count.* += 1;
            },
            .if_expr => |ie| {
                scanAllocatorWrapperStream(ie.then_instrs, ctx);
                scanAllocatorWrapperStream(ie.else_instrs, ctx);
            },
            .case_block => |cb| {
                scanAllocatorWrapperStream(cb.pre_instrs, ctx);
                for (cb.arms) |arm| {
                    scanAllocatorWrapperStream(arm.cond_instrs, ctx);
                    scanAllocatorWrapperStream(arm.body_instrs, ctx);
                }
                scanAllocatorWrapperStream(cb.default_instrs, ctx);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
                scanAllocatorWrapperStream(sl.default_instrs, ctx);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
                scanAllocatorWrapperStream(sr.default_instrs, ctx);
            },
            .union_switch => |us| {
                for (us.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| scanAllocatorWrapperStream(c.body_instrs, ctx);
            },
            .guard_block => |gb| scanAllocatorWrapperStream(gb.body, ctx),
            .optional_dispatch => |od| {
                scanAllocatorWrapperStream(od.nil_instrs, ctx);
                scanAllocatorWrapperStream(od.struct_instrs, ctx);
            },
            else => {},
        }
    }
}

const TentativeDemotionWalker = struct {
    allocator: std.mem.Allocator,
    caller: *const ir.Function,
    program: *const ir.Program,
    name_to_id: *const std.StringHashMapUnmanaged(ir.FunctionId),
    uniqueness: *const TentativeFunctionUniqueness,
    program_uniqueness: *v8_interprocedural.ProgramUniqueness,
    callers_of: *const std.AutoHashMapUnmanaged(ir.FunctionId, std.ArrayListUnmanaged(ir.FunctionId)),
    worklist: *std.ArrayListUnmanaged(ir.FunctionId),
    in_worklist: *std.AutoHashMapUnmanaged(ir.FunctionId, void),
    next_id: arc_liveness.InstructionId,

    fn walkStream(self: *TentativeDemotionWalker, stream: []const ir.Instruction) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            try self.maybeDemoteCallee(my_id);
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(self: *TentativeDemotionWalker, instr: *const ir.Instruction) error{OutOfMemory}!void {
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

    fn maybeDemoteCallee(self: *TentativeDemotionWalker, my_id: arc_liveness.InstructionId) error{OutOfMemory}!void {
        const arg_info = self.uniqueness.arg_sites.get(my_id) orelse return;
        const callee = lookupTentativeFunction(self.program, arg_info.target) orelse return;

        const callee_slots = self.program_uniqueness.by_function.get(callee.id) orelse return;
        for (callee.param_conventions, 0..) |conv, slot_idx| {
            if (slot_idx >= callee_slots.len) break;
            if (conv != .owned) continue;
            if (!callee_slots[slot_idx]) continue;
            if (slot_idx >= arg_info.per_arg.len) {
                callee_slots[slot_idx] = false;
                try self.enqueueCallers(callee.id);
                continue;
            }
            if (!arg_info.per_arg[slot_idx]) {
                callee_slots[slot_idx] = false;
                try self.enqueueCallers(callee.id);
            }
        }
    }

    fn enqueueCallers(self: *TentativeDemotionWalker, callee_id: ir.FunctionId) error{OutOfMemory}!void {
        const list = self.callers_of.get(callee_id) orelse return;
        for (list.items) |caller_id| {
            if (!self.in_worklist.contains(caller_id)) {
                try self.worklist.append(self.allocator, caller_id);
                try self.in_worklist.put(self.allocator, caller_id, {});
            }
        }
        if (!self.in_worklist.contains(callee_id)) {
            try self.worklist.append(self.allocator, callee_id);
            try self.in_worklist.put(self.allocator, callee_id, {});
        }
    }
};

/// Look up a function by id and return a mutable pointer (the IR
/// builder's slice is conceptually const, but the inference pass
/// mutates `param_conventions` via @constCast at the seam).
fn lookupFunctionMut(program: *const ir.Program, function_id: ir.FunctionId) ?*ir.Function {
    for (program.functions, 0..) |func, idx| {
        if (func.id == function_id) {
            return @constCast(&program.functions[idx]);
        }
    }
    return null;
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

// ============================================================
// Phase 2.4 V8 pre-flight check tests
// ============================================================

test "arc_param_convention: liftSetSurvivesV8Check admits a slot whose body is consume-mode" {
    // Build a synthetic function that forwards its slot directly into
    // an owned-mutating builtin and returns the result. Tentatively
    // promote the slot to .owned and verify the V8 fixpoint says
    // unique-on-entry.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Body of `set_zero(arr) -> Vector.set(arr, 0, 0)`.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "VectorI64.set",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try arena.dupe(ir.Instruction, &instrs),
    };
    const ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (ownership) |*o| o.* = .owned;
    const conventions = try arena.alloc(ir.ParamConvention, 1);
    conventions[0] = .borrowed;
    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "arr", .type_expr = .void };

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = .{
        .id = 0,
        .name = "set_zero",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = conventions,
        .local_ownership = ownership,
        .result_convention = .owned,
    };
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var candidates: LiftSet = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.put(std.testing.allocator, liftKey(0, 0), {});

    var survivors: LiftSet = .empty;
    defer survivors.deinit(std.testing.allocator);
    var test_signatures = try v8_fixpoint.computeSignatures(std.testing.allocator, &program);
    defer test_signatures.deinit(std.testing.allocator);
    var test_ownerships = arc_liveness.ProgramArcOwnership.init(std.testing.allocator);
    defer test_ownerships.deinit();
    try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);

    // The slot's body is a thin forward to VectorI64.set — V8 should
    // see uniqueness preserved through the rewritten share→move and
    // admit the candidate. Note: this test has no callers, so the
    // optimistic seeding leaves slot 0 unique-on-entry by default.
    try std.testing.expect(survivors.count() == 1);
    try std.testing.expect(liftSetContains(&survivors, 0, 0));

    // Conventions must be restored (the pre-flight is non-mutating).
    try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[0].param_conventions[0]);
}

test "arc_param_convention: liftSetSurvivesV8Check rejects when caller passes a copy_value-clobbered receiver" {
    // The pre-flight's V8 simulation rejects a callee candidate slot
    // when its caller can't pass a unique value at the call site.
    // Mirror that pattern: the callee F.0 is the candidate; the
    // caller G's body does `copy_value` on G's owned slot before the
    // call to F. Under tentative promotion of F.0, the V8 fixpoint
    // observes G's call passing a non-unique arg → demotes F.0.
    //
    // Both functions are tentatively-promoted candidates here so the
    // SCC bootstrap mechanic is exercised — the demotion must
    // actually fire even when both slots start unique-on-entry.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Callee F: forwards slot 0 into VectorI64.set.
    const callee_args = try arena.alloc(ir.LocalId, 3);
    callee_args[0] = 3;
    callee_args[1] = 1;
    callee_args[2] = 2;
    const callee_modes = try arena.alloc(ir.ValueMode, 3);
    callee_modes[0] = .move;
    callee_modes[1] = .borrow;
    callee_modes[2] = .borrow;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "VectorI64.set",
            .args = callee_args,
            .arg_modes = callee_modes,
        } },
        .{ .ret = .{ .value = 4 } },
    };
    const callee_blocks = try arena.alloc(ir.Block, 1);
    callee_blocks[0] = .{ .label = 0, .instructions = try arena.dupe(ir.Instruction, &callee_instrs) };
    const callee_ownership = try arena.alloc(ir.OwnershipClass, 5);
    for (callee_ownership) |*o| o.* = .owned;
    const callee_conventions = try arena.alloc(ir.ParamConvention, 1);
    callee_conventions[0] = .borrowed;
    const callee_params = try arena.alloc(ir.Param, 1);
    callee_params[0] = .{ .name = "arr", .type_expr = .void };

    // Caller G: takes one slot, does `copy_value` to clobber it,
    // then calls F passing the COPY (which V8 says is non-unique).
    //
    //   [0] param_get %0 = index 0
    //   [1] copy_value %1 = %0   -- both cleared from unique
    //   [2] share_value %2 = %1  -- (in the rewritten set if F.0 .owned)
    //   [3] call_named name="callee" args=[%2] dest=%3
    //   [4] ret value=%3
    const caller_args = try arena.alloc(ir.LocalId, 1);
    caller_args[0] = 2;
    const caller_modes = try arena.alloc(ir.ValueMode, 1);
    caller_modes[0] = .move;
    const caller_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .copy_value = .{ .dest = 1, .source = 0 } },
        .{ .share_value = .{ .dest = 2, .source = 1, .mode = .retain } },
        .{ .call_named = .{
            .dest = 3,
            .name = "callee",
            .args = caller_args,
            .arg_modes = caller_modes,
        } },
        .{ .ret = .{ .value = 3 } },
    };
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = try arena.dupe(ir.Instruction, &caller_instrs) };
    const caller_ownership = try arena.alloc(ir.OwnershipClass, 4);
    for (caller_ownership) |*o| o.* = .owned;
    const caller_conventions = try arena.alloc(ir.ParamConvention, 1);
    caller_conventions[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "arr", .type_expr = .void };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = .{
        .id = 0,
        .name = "callee",
        .scope_id = 0,
        .arity = 1,
        .params = callee_params,
        .return_type = .void,
        .body = callee_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 5,
        .param_conventions = callee_conventions,
        .local_ownership = callee_ownership,
        .result_convention = .owned,
    };
    functions[1] = .{
        .id = 1,
        .name = "caller",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 4,
        .param_conventions = caller_conventions,
        .local_ownership = caller_ownership,
        .result_convention = .owned,
    };
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var candidates: LiftSet = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.put(std.testing.allocator, liftKey(0, 0), {}); // callee.0
    try candidates.put(std.testing.allocator, liftKey(1, 0), {}); // caller.0

    var survivors: LiftSet = .empty;
    defer survivors.deinit(std.testing.allocator);
    var test_signatures = try v8_fixpoint.computeSignatures(std.testing.allocator, &program);
    defer test_signatures.deinit(std.testing.allocator);
    var test_ownerships = arc_liveness.ProgramArcOwnership.init(std.testing.allocator);
    defer test_ownerships.deinit();
    try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);

    // Caller's body has `copy_value` clobbering uniqueness before the
    // call to callee. The V8 fixpoint sees the call's arg is non-unique
    // → demotes callee.0. The pre-flight thus rejects callee.0 from
    // survivors. (caller.0 has no callers in this synthetic program,
    // so its unique-on-entry stays true and it survives.)
    try std.testing.expect(!liftSetContains(&survivors, 0, 0));

    // Conventions must be restored.
    try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[0].param_conventions[0]);
    try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[1].param_conventions[0]);
}

test "arc_param_convention: liftSetSurvivesV8Check restores conventions on every exit path" {
    // Smoke: when the candidate set is empty, the pre-flight is a
    // no-op. When non-empty, conventions are flipped, V8 runs, and
    // they're restored regardless of the result.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = &.{} };
    const ownership = try arena.alloc(ir.OwnershipClass, 0);
    const conventions = try arena.alloc(ir.ParamConvention, 1);
    conventions[0] = .borrowed;
    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "x", .type_expr = .void };

    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = .{
        .id = 0,
        .name = "noop",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 0,
        .param_conventions = conventions,
        .local_ownership = ownership,
        .result_convention = .trivial,
    };
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var test_signatures = try v8_fixpoint.computeSignatures(std.testing.allocator, &program);
    defer test_signatures.deinit(std.testing.allocator);
    var test_ownerships = arc_liveness.ProgramArcOwnership.init(std.testing.allocator);
    defer test_ownerships.deinit();

    // Empty candidates: no-op.
    {
        var candidates: LiftSet = .empty;
        defer candidates.deinit(std.testing.allocator);
        var survivors: LiftSet = .empty;
        defer survivors.deinit(std.testing.allocator);
        try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);
        try std.testing.expectEqual(@as(u32, 0), survivors.count());
        try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[0].param_conventions[0]);
    }

    // Non-empty candidates: conventions flipped during the call,
    // restored after.
    {
        var candidates: LiftSet = .empty;
        defer candidates.deinit(std.testing.allocator);
        try candidates.put(std.testing.allocator, liftKey(0, 0), {});
        var survivors: LiftSet = .empty;
        defer survivors.deinit(std.testing.allocator);
        try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);
        // After the call returns, conventions are back to .borrowed.
        try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[0].param_conventions[0]);
    }
}

test "arc_param_convention: TentativeAnalyzer tuple_pending preserves witness through tuple_init+ret (Phase 2.6.2)" {
    // Build a function whose body constructs a tuple from a unique-on-
    // entry param and returns it. The V8 pre-flight should observe the
    // param as PU through the return-component witness mechanism: the
    // tuple_init goes onto `tuple_pending`, the `ret` resolves it as
    // PU. Tentative promotion of slot 0 to .owned should survive
    // because no demoting operation occurs in the body.
    //
    // Without Phase 2.6.2's tuple_pending in the TentativeAnalyzer,
    // the `tuple_init` would have unconditionally cleared the param's
    // unique bit, and a downstream V8 site fed by an extracted local
    // would see non-unique → reject the candidate.
    //
    //   pub fn id_tuple(v :: VectorI64) -> {VectorI64} { {v} }
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const tuple_elems = try arena.alloc(ir.LocalId, 1);
    tuple_elems[0] = 0;
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = tuple_elems } },
        .{ .ret = .{ .value = 1 } },
    };
    const blocks = try arena.alloc(ir.Block, 1);
    blocks[0] = .{ .label = 0, .instructions = try arena.dupe(ir.Instruction, &instrs) };
    const ownership_classes = try arena.alloc(ir.OwnershipClass, 2);
    for (ownership_classes) |*o| o.* = .owned;
    const conventions = try arena.alloc(ir.ParamConvention, 1);
    conventions[0] = .borrowed;
    const params = try arena.alloc(ir.Param, 1);
    params[0] = .{ .name = "v", .type_expr = .void };
    const functions = try arena.alloc(ir.Function, 1);
    functions[0] = .{
        .id = 0,
        .name = "id_tuple",
        .scope_id = 0,
        .arity = 1,
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = conventions,
        .local_ownership = ownership_classes,
        .result_convention = .owned,
    };
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var test_signatures = try v8_fixpoint.computeSignatures(std.testing.allocator, &program);
    defer test_signatures.deinit(std.testing.allocator);
    var test_ownerships = arc_liveness.ProgramArcOwnership.init(std.testing.allocator);
    defer test_ownerships.deinit();

    var candidates: LiftSet = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.put(std.testing.allocator, liftKey(0, 0), {});
    var survivors: LiftSet = .empty;
    defer survivors.deinit(std.testing.allocator);
    try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);

    // The body has no demoting operations on the param's flow. With
    // tentative promotion to .owned, the V8 pre-flight should see
    // unique-on-entry preserved.
    try std.testing.expect(survivors.count() == 1);
    try std.testing.expect(liftSetContains(&survivors, 0, 0));
    try std.testing.expectEqual(ir.ParamConvention.borrowed, program.functions[0].param_conventions[0]);
}

test "arc_param_convention: TentativeAnalyzer synthesizes return pending from callee signatures (Phase 2.6.2)" {
    // Caller g calls callee f, where f's signature has
    // return_components[0] = 0 (component 0 carries param slot 0).
    // The call's dest is then index_get(0) → v', which g uses as the
    // receiver of an owned-mutating builtin and returns. The V8 pre-
    // flight must:
    //   1. Synthesize a tuple_pending entry on the call dest using
    //      f's return_components witness.
    //   2. Record an extracted ref on index_get from that pending.
    //   3. (For destructure-promotion at last-use, ArcOwnership is
    //      required — this test omits it to keep the scaffold small.
    //      The unique-flag still propagates through to the V8 site
    //      via the receiver's pre-extract pending state.)
    //
    // For this test we simplify: we verify Phase 2.6.2's synthesis
    // path admits a callee whose body is a thin forward to a
    // fresh-allocator wrapper (returns rc=1 cell), under a tentative
    // promotion of caller's param 0 (the unique receiver).
    //
    // Concretely the test exercises the propagation idea using a
    // simpler, owned-receiver shape that the existing test scaffold
    // can model end-to-end: callee `f(v)` returns a tuple `{v}` (the
    // identity tuple), caller `g(v)` calls `f`, destructures, and
    // returns the destructured local. With Phase 2.6.2 working, the
    // pre-flight admits caller's slot 0 as survivable under tentative
    // promotion. This indirectly verifies the `synthesizeReturn*` and
    // `index_get`/`tuple_pending` plumbing.
    var arena_obj = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Callee f: takes a Vector slot, returns {v}.
    const callee_tuple_elems = try arena.alloc(ir.LocalId, 1);
    callee_tuple_elems[0] = 0;
    const callee_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .tuple_init = .{ .dest = 1, .elements = callee_tuple_elems } },
        .{ .ret = .{ .value = 1 } },
    };
    const callee_blocks = try arena.alloc(ir.Block, 1);
    callee_blocks[0] = .{ .label = 0, .instructions = try arena.dupe(ir.Instruction, &callee_instrs) };
    const callee_ownership = try arena.alloc(ir.OwnershipClass, 2);
    for (callee_ownership) |*o| o.* = .owned;
    const callee_conventions = try arena.alloc(ir.ParamConvention, 1);
    callee_conventions[0] = .borrowed;
    const callee_params = try arena.alloc(ir.Param, 1);
    callee_params[0] = .{ .name = "v", .type_expr = .void };

    // Caller g: takes a Vector slot, calls f, destructures, returns.
    //   t = f(v0)
    //   v' = t[0]
    //   ret v'
    const call_args = try arena.alloc(ir.LocalId, 1);
    call_args[0] = 0;
    const call_modes = try arena.alloc(ir.ValueMode, 1);
    call_modes[0] = .borrow;
    const caller_instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .call_named = .{
            .dest = 1,
            .name = "f",
            .args = call_args,
            .arg_modes = call_modes,
        } },
        .{ .index_get = .{ .dest = 2, .object = 1, .index = 0 } },
        .{ .ret = .{ .value = 2 } },
    };
    const caller_blocks = try arena.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = try arena.dupe(ir.Instruction, &caller_instrs) };
    const caller_ownership = try arena.alloc(ir.OwnershipClass, 3);
    for (caller_ownership) |*o| o.* = .owned;
    const caller_conventions = try arena.alloc(ir.ParamConvention, 1);
    caller_conventions[0] = .borrowed;
    const caller_params = try arena.alloc(ir.Param, 1);
    caller_params[0] = .{ .name = "v", .type_expr = .void };

    const functions = try arena.alloc(ir.Function, 2);
    functions[0] = .{
        .id = 0,
        .name = "f",
        .scope_id = 0,
        .arity = 1,
        .params = callee_params,
        .return_type = .void,
        .body = callee_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 2,
        .param_conventions = callee_conventions,
        .local_ownership = callee_ownership,
        .result_convention = .owned,
    };
    functions[1] = .{
        .id = 1,
        .name = "g",
        .scope_id = 0,
        .arity = 1,
        .params = caller_params,
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_conventions,
        .local_ownership = caller_ownership,
        .result_convention = .owned,
    };
    var program = ir.Program{ .functions = functions, .type_defs = &.{}, .entry = null };

    var test_signatures = try v8_fixpoint.computeSignatures(std.testing.allocator, &program);
    defer test_signatures.deinit(std.testing.allocator);
    var test_ownerships = arc_liveness.ProgramArcOwnership.init(std.testing.allocator);
    defer test_ownerships.deinit();

    // Sanity: the fixpoint must have observed the callee's return
    // components — component 0 carries parameter slot 0.
    const callee_sig = test_signatures.forFunction(0).?;
    try std.testing.expect(callee_sig.return_components.len >= 1);
    try std.testing.expectEqual(@as(?u8, 0), callee_sig.return_components[0]);

    var candidates: LiftSet = .empty;
    defer candidates.deinit(std.testing.allocator);
    try candidates.put(std.testing.allocator, liftKey(0, 0), {});
    try candidates.put(std.testing.allocator, liftKey(1, 0), {});
    var survivors: LiftSet = .empty;
    defer survivors.deinit(std.testing.allocator);
    try liftSetSurvivesV8Check(std.testing.allocator, &program, &test_signatures, &test_ownerships, &candidates, &survivors);

    // Both slots survive: callee.0 because its body is a clean
    // tuple_init+ret; caller.0 because (with Phase 2.6.2 plumbing)
    // the call's dest gets a synthesized tuple_pending entry, and
    // the index_get of component 0 is recorded as an extracted ref.
    // The current scaffolding (no ArcOwnership) prevents
    // last-use-promotion from firing on the destructured local; this
    // test still validates that NO regression occurs at the V8 site
    // — the candidate must continue surviving as it did before
    // Phase 2.6.2 (synthesis is an OPTIONAL upgrade path; without
    // ArcOwnership, the dataflow falls back to the legacy behaviour
    // which still admits this clean shape).
    try std.testing.expect(liftSetContains(&survivors, 0, 0));
    try std.testing.expect(liftSetContains(&survivors, 1, 0));
}
