const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const uniqueness_analysis = @import("uniqueness.zig");
const uniqueness_interprocedural = @import("uniqueness_interprocedural.zig");

// ============================================================
// ARC ownership verifier.
//
// Phase A of the Phase 6 redux plan introduced this module as a
// scaffold. Phase D wired the recursion structure through every
// nested instruction stream. Phase E (this commit) activates the
// invariant rules.
//
// Pipeline placement (per §2.2 of the plan):
//
//     ... → arc_ownership          (normalization)
//             → arc_verifier       (THIS PASS — invariant checks)
//                  → arc_drop_insertion
//                       → ...
//
// The verifier runs BEFORE drop insertion. At this pipeline
// position, the only `.release` instructions present are the
// post-call cleanup releases emitted by `IrBuilder` for
// `share_value`-driven calls. Scope-exit destroys (one per owned
// local at every ret-equivalent terminator) have not been
// inserted yet. Phase E's invariants are therefore framed around
// the IR shape AS IT EXISTS at this position:
//
//   V1. `.release{value=v}` MUST NOT target a local whose
//       `local_ownership` is `.borrowed`. A `.borrow_value`
//       does not bump the source cell; releasing it would
//       underflow the source's owner reference.
//   V2. `.release{value=v}` MUST NOT target a local whose
//       `local_ownership` is `.trivial`. Releasing a non-ARC
//       local is a refcount bug — there is no ARC cell to
//       decrement. (A `.trivial` local cannot be the source of
//       a `share_value` so this case represents a pass bug.)
//   V3. Borrowed values MUST NOT escape into aggregate storage.
//       For every `.struct_init`, `.list_init`, `.map_init`,
//       `.tuple_init`, `.list_cons`, and `.union_init`, every
//       operand local's `local_ownership` MUST NOT be `.borrowed`.
//       Storing a borrow into owned aggregate data would dangle
//       once the borrow scope ends.
//
//       Phase E.10 sharpens the rationale for the non-`.map_init`
//       aggregates: list, tuple, struct, and union cells are bump-
//       allocated and never call retain on their stored elements.
//       The classifier therefore upgrades `.local_get` whose dest's
//       only use is one of these slots from `.copy_value` to
//       `.move_value`, transferring the source's `+1` into the
//       aggregate's implicit ownership; the matching liveness rule
//       in `arc_liveness.applyOwnsEffect` clears the operand's
//       owns bit at the aggregate-init so no scope-exit destroy
//       fires on the cell whose live pointer the aggregate now
//       holds. V3's borrowed-rejection is the static counterpart of
//       that liveness contract: a `.borrowed` operand has no `+1`
//       to transfer in the first place.
//
//       Limitation: the contract is correct for comptime-baked or
//       single-owner aggregates (every macro-emitted manifest
//       function in the standard library; the canonical doc-runner
//       reproducer). For runtime-built aggregates that hold ARC
//       values across many transformations (e.g. `List.append`
//       chains), the consumed cell stays alive forever via the
//       bump-allocated aggregate even after the user-visible
//       aggregate goes out of scope. That is an acceptable leak
//       compared to the previous use-after-free, and the long-term
//       remedy is making `List(T)` ARC-managed (Phase H+).
//   V4. Function parameters of `.borrowed` convention MUST NOT
//       be released within the function body. Subsumed by V1
//       when Phase C correctly classifies the param-bound local
//       as `.borrowed`; verifier double-checks against
//       `param_conventions` directly to catch any pass that
//       updates `param_conventions` without updating
//       `local_ownership`.
//   V5. When `result_convention == .owned`, every ret-equivalent
//       value local MUST NOT be `.borrowed`. The caller's
//       post-call discipline assumes the returned value carries
//       a +1 retain that the caller is responsible for releasing;
//       returning a borrow would let the caller release a value
//       the callee was lending out.
//   V6. `.move_value{source=s}` MUST consume an `.owned` source.
//       Moving from a borrowed local is a pass bug: borrowed aliases
//       do not carry a +1 reference to transfer, and treating them as
//       consumable lets aggregate-store rewrites park dangling
//       pointers while the real owner is still released later.
//
// On any violation, `verify` emits a Swift-OSSA-style diagnostic
// via `std.log.err` and returns `error.ArcInvariantViolation`. The
// compiler propagates this as a hard build error — any pass that
// produces verifier-rejected IR has a bug to fix. The plan is
// emphatic (§3.E):
//
//   "The verifier must accept all currently-shipping IR. If it
//    rejects something, fix the upstream pass, don't disable the
//    rule."
//
// The verifier is bitset-light: every check is a per-instruction
// O(1) lookup against `function.local_ownership` and
// `function.param_conventions`. There is no CFG walk, no
// dataflow, no fixed-point iteration. The cost is proportional to
// the size of the function's instruction streams.
// ============================================================

/// Errors `verify` can return.
///
/// `ArcInvariantViolation` indicates the IR violated one of the
/// Phase E invariants. The offending site is reported via
/// `std.log.err` before the error is returned, with enough context
/// to localise the bug to a specific pass.
pub const VerifyError = error{
    OutOfMemory,
    ArcInvariantViolation,
};

/// Verify ownership invariants on `function`. Walks every
/// instruction stream (top-level body and every nested sub-stream)
/// and applies the per-instruction invariant checks in
/// `verifyInstruction`. Returns `error.ArcInvariantViolation` on
/// the first violation; subsequent violations would still be
/// reported via the diagnostic emission inside the check itself
/// but the function exits at the first failure to keep the
/// compile path predictable.
///
/// `program` is the IR program in scope. Phase E.9 V7 reads each
/// callee's `param_conventions` through this pointer to confirm
/// caller and callee agree on the consume/borrow convention at
/// every ARC-managed call argument.
pub fn verify(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
) VerifyError!void {
    return verifyWithFixpoint(allocator, function, program, null);
}

/// Variant of `verify` that consults a whole-program uniqueness
/// fixpoint when running uniqueness. The fixpoint feeds through to the
/// per-function uniqueness analysis so `param_get` for slots proven
/// unique-on-entry is treated as definitely unique. Required when
/// the codegen used the same fixpoint to emit `*_owned_unchecked`
/// calls — the verifier must agree on which sites pass uniqueness or it
/// will reject codegen's output.
pub fn verifyWithFixpoint(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
) VerifyError!void {
    var ctx = VerifyContext{ .function = function, .program = program };
    for (function.body) |block| {
        try verifyStream(&ctx, block.instructions);
    }
    try runUniquenessCheck(allocator, function, program, fixpoint);
}

/// Per-verification context. Phase E.9 V7 added the `program`
/// pointer so call-site invariants can resolve the callee's
/// `param_conventions`. A future tightening (per-CFG-path bitset
/// dataflow for the "destroyed exactly once" invariant) would
/// extend this struct with `live_owned` / `live_borrowed` bitsets.
const VerifyContext = struct {
    function: *const ir.Function,
    program: *const ir.Program,
};

/// Visit every instruction in `stream` (and recursively in every
/// nested sub-stream). Each instruction is handed to
/// `verifyInstruction`. The recursion structure here mirrors
/// `arc_liveness.flattenChildren` and
/// `arc_drop_insertion.rebuildChildren` exactly; all three
/// traversals must agree on which streams contain checkable IR.
fn verifyStream(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) VerifyError!void {
    // Phase E.6: scan the stream for tail-position self-recursive
    // calls that the IrBuilder's tail-call rewriter could not
    // eliminate. V6 is a stream-level invariant (it depends on the
    // sequence of instructions, not just one) so it runs before the
    // per-instruction checks.
    try verifyTailCallRewritability(ctx, stream);

    // Phase E.9 V7: every call site's argument convention agrees
    // with the callee's parameter convention. V7 is also a stream-
    // level invariant — the caller's preparation for a call (a
    // share_value retain or a move_value transfer) lives earlier in
    // the same stream. The check resolves each call's args back to
    // the producing instruction and confirms the caller emitted the
    // right shape for the callee's declared convention.
    try verifyCallSiteConventions(ctx, stream);

    for (stream) |*instr| {
        try verifyInstruction(ctx, instr);
        try verifyChildren(ctx, instr);
    }
}

/// V6: every self-recursive `.call_named` whose result feeds directly
/// into a `.ret` (i.e., it stands in tail position) MUST be reachable
/// to the IrBuilder's tail-call rewriter. The rewriter walks past
/// trailing tail-mappable instructions (releases, retains,
/// borrow_value, copy_value, move_value) — anything else between the
/// call and the return blocks the rewrite, leaving a regular
/// `call_named + ret` pair that the runtime would execute as an
/// unbounded stack-growing recursion. This invariant catches the
/// regression at compile time so future ownership-pass changes that
/// introduce non-tail-mappable instructions in the trailing path
/// surface here instead of as a stack overflow on a deep workload
/// (e.g., k-nucleotide's `count_kmers_loop`).
///
/// The check is scoped to a single instruction stream. Walk forward;
/// when we observe a `.call_named` to self, remember its dest. If a
/// `.ret` whose value matches that dest appears later in the same
/// stream, every instruction strictly between the call and the ret
/// must be in the tail-mappable set. The first non-tail-mappable
/// instruction triggers a V6 diagnostic naming the offending
/// instruction tag.
///
/// Calls in non-tail position (where the call's dest is not the
/// stream's eventual return value) are silently ignored — V6 is not
/// trying to mandate that every recursive call be a tail call, only
/// that every call SOMEONE wrote in tail position remain rewritable.
fn verifyTailCallRewritability(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) VerifyError!void {
    const function = ctx.function;
    var index: usize = 0;
    while (index < stream.len) : (index += 1) {
        const call_instr = stream[index];
        const call_dest: ir.LocalId, const call_name: []const u8 = switch (call_instr) {
            .call_named => |cn| .{ cn.dest, cn.name },
            else => continue,
        };
        if (!std.mem.eql(u8, call_name, function.name)) continue;

        // Look forward for a `.ret` whose value is the call's dest.
        // Any instruction strictly between the call and that `ret`
        // must be tail-mappable; otherwise V6 fails. We only flag a
        // violation when a matching `.ret` is found — if the call's
        // dest never feeds a `.ret` in this stream, the call is not
        // in tail position and V6 is silent.
        var probe: usize = index + 1;
        while (probe < stream.len) : (probe += 1) {
            const next = stream[probe];
            if (next == .ret) {
                const ret_value = next.ret.value orelse break;
                if (ret_value != call_dest) break;
                // Tail position confirmed. Verify every instruction
                // between `call_instr` (exclusive) and `next`
                // (exclusive) is tail-mappable.
                var between_index: usize = index + 1;
                while (between_index < probe) : (between_index += 1) {
                    const between = stream[between_index];
                    if (!isTailMappableTrailingInstr(between)) {
                        emitTailCallRewritabilityDiagnostic(
                            function,
                            index,
                            between_index,
                            probe,
                            between,
                        );
                        return error.ArcInvariantViolation;
                    }
                }
                break;
            }
            // A non-ret instruction along the way is fine on its own
            // (it might itself be tail-mappable or might break tail
            // position). The decision waits until we either hit the
            // matching ret (above) or a non-matching terminator
            // (below).
            if (terminatesStream(next)) break;
        }
    }

    // Phase E.7: structural V6 — catch self-recursive `call_named`
    // sites buried inside an `if_expr` / `switch_literal` arm whose
    // arm-result is the call's dest, with the enclosing branch's
    // dest feeding the function's `ret`. This is the structural
    // analogue of the linear case above; the IrBuilder's
    // `tryRewriteTailThroughBranch` exists specifically to catch
    // this shape and rewrite it to per-arm `tail_call`. If V6 sees
    // a non-rewritten residue (because some pass introduced a non-
    // tail-mappable instruction in the arm body, blocking the
    // rewriter, or because the rewriter's gate did not fire for
    // some reason), the runtime would execute it as unbounded
    // stack-growing recursion. Surface that at compile time.
    //
    // The walk pattern: for each `(if_expr | switch_literal)`
    // followed by `ret`, where the construct's dest matches the
    // ret's value, descend into each arm and check whether any arm
    // body has the call+arm-result-feed shape that the rewriter
    // would have transformed.
    var struct_index: usize = 0;
    while (struct_index < stream.len) : (struct_index += 1) {
        const branch = stream[struct_index];
        const branch_dest: ir.LocalId = switch (branch) {
            .if_expr => |ie| ie.dest,
            .switch_literal => |sl| sl.dest,
            else => continue,
        };
        // Must be immediately followed by a matching ret. The
        // rewriter's strict gate checks the same; a non-strict
        // gap (an intervening tail-mappable instruction) is V6's
        // job for the linear path above, not the structural one.
        if (struct_index + 1 >= stream.len) continue;
        const successor = stream[struct_index + 1];
        if (successor != .ret) continue;
        const ret_value = successor.ret.value orelse continue;
        if (ret_value != branch_dest) continue;

        // Each arm is in tail position. Check each arm's body for
        // an unrewritten self-recursive tail-position call.
        switch (branch) {
            .if_expr => |ie| {
                try verifyArmTailCallRewritten(function, struct_index, ie.then_instrs, ie.then_result);
                try verifyArmTailCallRewritten(function, struct_index, ie.else_instrs, ie.else_result);
            },
            .switch_literal => |sl| {
                for (sl.cases) |case| {
                    try verifyArmTailCallRewritten(function, struct_index, case.body_instrs, case.result);
                }
                try verifyArmTailCallRewritten(function, struct_index, sl.default_instrs, sl.default_result);
            },
            else => unreachable,
        }
    }
}

/// Phase E.9 V7: caller-callee convention agreement at every call
/// site. For each `.call_named` / `.call_direct` / `.try_call_named`
/// in the stream, look up the callee's `param_conventions` and walk
/// the caller's prelude to confirm:
///
///   * For each `.owned` parameter slot: the matching arg must
///     have been produced by `.move_value` (the only caller-side
///     shape that transfers ownership without a retain). A
///     `.share_value` would imply the caller still holds the
///     refcount unit and Step 2's rewrite did not fire — the
///     callee's scope-exit drop would underflow.
///
///   * For each `.borrowed` parameter slot: the matching arg must
///     NOT have been produced by `.move_value` for a non-tail call.
///     `share_value`, `borrow_value`, `copy_value`, or a direct
///     local pass are all valid. A `move_value` here would have
///     consumed the source without a callee-side release — leaking
///     the cell.
///
///   * `.trivial` slots are not checked: their args are non-ARC
///     values; convention does not apply.
///
/// Tail calls (`.tail_call`) and call-shape variants without a
/// fixed concrete callee (`.call_dispatch`, `.call_closure`,
/// `.call_builtin`) are not subject to V7. Tail calls are a
/// special-case consume convention enforced by Phase E.8's
/// rewriter; the other variants resolve their convention only at
/// trampoline / runtime / builtin lowering time.
fn verifyCallSiteConventions(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) VerifyError!void {
    const program = ctx.program;
    var index: usize = 0;
    while (index < stream.len) : (index += 1) {
        const instr = stream[index];
        const callee_conv: []const ir.ParamConvention = switch (instr) {
            .call_named => |cn| lookupConventionByName(program, cn.name) orelse continue,
            .call_direct => |cd| lookupConventionById(program, cd.function) orelse continue,
            .try_call_named => |tcn| lookupConventionByName(program, tcn.name) orelse continue,
            else => continue,
        };
        const args: []const ir.LocalId = switch (instr) {
            .call_named => |cn| cn.args,
            .call_direct => |cd| cd.args,
            .try_call_named => |tcn| tcn.args,
            else => unreachable,
        };
        // Iterate slot-by-slot. Argument counts can in principle
        // differ from `param_conventions.len` for default-arg or
        // synthesised-prelude shapes; bound the iteration by the
        // smaller of the two so we never read past either slice.
        const slot_count = @min(callee_conv.len, args.len);
        var slot: usize = 0;
        while (slot < slot_count) : (slot += 1) {
            const conv = callee_conv[slot];
            if (conv == .trivial) continue;
            const arg_local = args[slot];
            const producer_kind = findArgProducerKind(stream, index, arg_local);
            switch (conv) {
                .owned => {
                    if (producer_kind != .move) {
                        emitV7Diagnostic(ctx.function, index, slot, conv, producer_kind);
                        return error.ArcInvariantViolation;
                    }
                },
                .borrowed => {
                    if (producer_kind == .move) {
                        emitV7Diagnostic(ctx.function, index, slot, conv, producer_kind);
                        return error.ArcInvariantViolation;
                    }
                },
                .trivial => unreachable,
            }
        }
    }
}

/// Categorisation of the instruction that defines a call-arg local
/// in the same stream. The verifier does not need a full mapping;
/// the four cases below are sufficient to enforce V7.
const ArgProducerKind = enum {
    /// `.move_value{dest=arg, ...}` — caller transferred ownership.
    move,
    /// `.share_value{dest=arg, ...}` — caller retained.
    share,
    /// Anything else — `.copy_value`, `.borrow_value`, a direct
    /// `param_get`, a `local_set`, or no producing instruction at
    /// all (the local was passed without preparation, e.g. a
    /// non-ARC arg or a fresh call result reused inline).
    other,
    /// The arg local was not produced earlier in the same stream.
    /// Rare — generally happens for non-share-shaped passes (the
    /// IR builder elides preparation for `.borrow` and `.move`
    /// modes when the source is already a usable local). V7 treats
    /// this as `.other` for invariant purposes.
    none,
};

fn findArgProducerKind(
    stream: []const ir.Instruction,
    call_index: usize,
    arg_local: ir.LocalId,
) ArgProducerKind {
    var probe: usize = call_index;
    while (probe > 0) {
        probe -= 1;
        const candidate = stream[probe];
        switch (candidate) {
            .move_value => |mv| if (mv.dest == arg_local) return .move,
            .share_value => |sv| if (sv.dest == arg_local) return .share,
            .copy_value => |cv| if (cv.dest == arg_local) return .other,
            .borrow_value => |bv| if (bv.dest == arg_local) return .other,
            .local_get => |lg| if (lg.dest == arg_local) return .other,
            .local_set => |ls| if (ls.dest == arg_local) return .other,
            .param_get => |pg| if (pg.dest == arg_local) return .other,
            else => {},
        }
    }
    return .none;
}

fn lookupConventionByName(
    program: *const ir.Program,
    name: []const u8,
) ?[]const ir.ParamConvention {
    // Last-wins for `func.name`: the per-struct → merged compilation
    // pipeline (`compileStructByStruct`) registers the same function
    // multiple times — once per per-struct compilation, once for the
    // merged whole-program IR. Both `arc_param_convention.inferConventions`
    // and `arc_ownership.ConventionIndex.build` use `put` (last-wins) on
    // a `StringHashMap` keyed by `func.name`, so the post-merge
    // `param_conventions` slice is the LATEST registration. The verifier
    // must agree, otherwise it reads a STALE per-struct convention while
    // the rewriter applied promotions from the MERGED convention,
    // surfacing as spurious V7 violations whenever the merged inference
    // upgrades a slot that the per-struct inference left `.borrowed`.
    //
    // First-wins for `local_name` (matching `arc_param_convention` /
    // `arc_ownership`'s `getOrPut`): a colliding `local_name` between
    // sibling functions would cost a missed conventional check, never
    // a wrong one — V7's job here is to validate, not to disambiguate
    // ambiguous identifiers.
    var by_name_match: ?[]const ir.ParamConvention = null;
    var by_local_name_match: ?[]const ir.ParamConvention = null;
    for (program.functions) |func| {
        if (std.mem.eql(u8, func.name, name)) {
            // Last-wins: keep overwriting so the final iteration's
            // registration wins.
            by_name_match = func.param_conventions;
        }
        if (func.local_name.len != 0 and std.mem.eql(u8, func.local_name, name)) {
            // First-wins: only set the local-name match once.
            if (by_local_name_match == null) {
                by_local_name_match = func.param_conventions;
            }
        }
    }
    if (by_name_match) |conv| return conv;
    return by_local_name_match;
}

fn lookupConventionById(
    program: *const ir.Program,
    function_id: ir.FunctionId,
) ?[]const ir.ParamConvention {
    for (program.functions) |func| {
        if (func.id == function_id) return func.param_conventions;
    }
    return null;
}

fn emitV7Diagnostic(
    function: *const ir.Function,
    call_index: usize,
    slot: usize,
    callee_conv: ir.ParamConvention,
    producer_kind: ArgProducerKind,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates V7:\n" ++
            "  call site at instruction {d}\n" ++
            "  arg slot {d}: callee convention is .{s}, caller's producer is {s}\n" ++
            "  V7 requires .owned slots to be filled by .move_value (no retain)\n" ++
            "  and .borrowed slots to be filled by anything BUT .move_value\n",
        .{
            function.name,
            call_index,
            slot,
            @tagName(callee_conv),
            @tagName(producer_kind),
        },
    );
}

/// Phase E.7 helper: assert that an arm in tail position does NOT
/// contain an unrewritten self-recursive call_named at its tail.
/// The arm is in tail position when the enclosing if_expr /
/// switch_literal's `dest` feeds the function's `ret`. The arm
/// itself is "the tail" when its `arm_result` is the local consumed
/// by the merge — which is precisely the IR shape the rewriter's
/// `rewriteTailCallsInBody` recognises.
///
/// The check walks backward from the arm body's tail, skipping past
/// tail-mappable trailing instructions, and verifies the resulting
/// position is NOT a self-recursive `call_named` whose dest equals
/// `arm_result`. Such a residue means the rewriter could not (or
/// did not) fire on this arm; deep recursion through this code path
/// will blow the stack at runtime.
fn verifyArmTailCallRewritten(
    function: *const ir.Function,
    enclosing_branch_index: usize,
    body: []const ir.Instruction,
    arm_result: ?ir.LocalId,
) VerifyError!void {
    const expected_dest = arm_result orelse return;
    if (body.len == 0) return;
    var probe: usize = body.len;
    while (probe > 0 and isTailMappableTrailingInstr(body[probe - 1])) : (probe -= 1) {}
    if (probe == 0) return;
    const candidate = body[probe - 1];
    switch (candidate) {
        .call_named => |cn| {
            if (cn.dest != expected_dest) return;
            if (!std.mem.eql(u8, cn.name, function.name)) return;
            // V6 structural violation: the arm's tail is a self-
            // recursive call_named whose result is the arm's merge
            // value, but the rewriter did not collapse it into a
            // tail_call. Diagnose with enough context to localise.
            emitStructuralTailCallDiagnostic(function, enclosing_branch_index, probe - 1);
            return error.ArcInvariantViolation;
        },
        else => return,
    }
}

/// Emit a V6 diagnostic for the structural shape — a self-recursive
/// `call_named` at the tail of an `if_expr` / `switch_literal` arm
/// that the IrBuilder's `tryRewriteTailThroughBranch` did not lower
/// to a `tail_call`.
fn emitStructuralTailCallDiagnostic(
    function: *const ir.Function,
    branch_index: usize,
    arm_call_index: usize,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates V6 (structural):\n" ++
            "  self-recursive call at arm-internal index {d}, inside if_expr/switch_literal at stream index {d}\n" ++
            "  the construct's dest feeds the function's ret, so the arm is in tail position;\n" ++
            "  the IrBuilder's tryRewriteTailThroughBranch should have collapsed it into `tail_call`.\n" ++
            "  Deep recursion through this code path will blow the stack.\n",
        .{ function.name, arm_call_index, branch_index },
    );
}

/// Phase E.6: classify whether `instr` is a tail-mappable trailing
/// instruction — i.e., one the IrBuilder's tail-call rewriter walks
/// past when matching the call+ret pattern. The set must stay in
/// lockstep with `IrBuilder.isTailMappableTrailingInstr` in
/// `src/ir.zig`. Drift between the two is a correctness bug: V6
/// would either falsely accept IR the rewriter can't actually rewrite
/// or falsely reject IR the rewriter handles cleanly.
fn isTailMappableTrailingInstr(instr: ir.Instruction) bool {
    return switch (instr) {
        .release, .retain, .borrow_value, .copy_value, .move_value => true,
        else => false,
    };
}

/// True for instructions that terminate the surrounding stream's
/// linear control flow (any subsequent instruction in the same slice
/// would be unreachable). The V6 forward scan stops at a terminator
/// that is not the matching `.ret` because nothing past a terminator
/// can reach a tail-position `ret`.
fn terminatesStream(instr: ir.Instruction) bool {
    return switch (instr) {
        .ret,
        .cond_return,
        .tail_call,
        .jump,
        .switch_return,
        .union_switch_return,
        .branch,
        .match_fail,
        .match_error_return,
        => true,
        else => false,
    };
}

/// Emit a V6 diagnostic naming the function, the call instruction
/// index, the offending non-tail-mappable instruction tag, and the
/// surrounding ret index — enough context for a developer to find
/// the exact site without instrumenting the verifier further.
fn emitTailCallRewritabilityDiagnostic(
    function: *const ir.Function,
    call_index: usize,
    offending_index: usize,
    ret_index: usize,
    offending: ir.Instruction,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates V6:\n" ++
            "  self-recursive call at instruction {d} followed by non-tail-mappable instruction {d} (.{s})\n" ++
            "  the tail-call rewriter cannot eliminate this call; deep recursion will blow the stack\n" ++
            "  matching ret is at instruction {d}\n",
        .{
            function.name,
            call_index,
            offending_index,
            @tagName(offending),
            ret_index,
        },
    );
}

/// Recurse into every nested instruction stream owned by `instr`.
fn verifyChildren(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) VerifyError!void {
    switch (instr.*) {
        .if_expr => |ie| {
            try verifyStream(ctx, ie.then_instrs);
            try verifyStream(ctx, ie.else_instrs);
        },
        .case_block => |cb| {
            try verifyStream(ctx, cb.pre_instrs);
            for (cb.arms) |arm| {
                try verifyStream(ctx, arm.cond_instrs);
                try verifyStream(ctx, arm.body_instrs);
            }
            try verifyStream(ctx, cb.default_instrs);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| try verifyStream(ctx, c.body_instrs);
            try verifyStream(ctx, sl.default_instrs);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| try verifyStream(ctx, c.body_instrs);
            try verifyStream(ctx, sr.default_instrs);
        },
        .union_switch => |us| {
            for (us.cases) |c| try verifyStream(ctx, c.body_instrs);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| try verifyStream(ctx, c.body_instrs);
        },
        .try_call_named => |tc| {
            try verifyStream(ctx, tc.handler_instrs);
            try verifyStream(ctx, tc.success_instrs);
        },
        .guard_block => |gb| {
            try verifyStream(ctx, gb.body);
        },
        .optional_dispatch => |od| {
            try verifyStream(ctx, od.nil_instrs);
            try verifyStream(ctx, od.struct_instrs);
        },
        else => {},
    }
}

/// Look up `local_id`'s ownership class. Returns `.trivial` for
/// any local id past the table's length — the table is sized to
/// `local_count` so every legitimate local has an entry; the
/// fallback exists for defensive robustness only (a misnumbered
/// LocalId would otherwise crash the verifier with an out-of-
/// bounds read instead of producing a clean diagnostic).
fn ownershipOf(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ir.OwnershipClass {
    if (local_id >= function.local_ownership.len) return .trivial;
    return function.local_ownership[local_id];
}

/// Look up `local_id`'s parameter convention if the local is the
/// destination of a `param_get` instruction, otherwise `null`.
///
/// Phase H.1 fix: previously this routine treated `local_id <
/// param_conventions.len` as "is parameter local," but that
/// assumption only holds when the IR builder happens to emit
/// param_get destinations in slots `0..arity-1`. Multi-clause
/// dispatch and pattern-bound clauses pre-reserve binding locals
/// before allocating param locals, so a "small" local id can
/// belong to a non-parameter binding (e.g. a `share_value` dest
/// allocated immediately after a `param_get`). Looking up
/// `param_conventions[local_id]` in that case returns the wrong
/// convention and trips V4 spuriously.
///
/// The reliable mapping is "scan the function body for the
/// `.param_get` whose `dest == local_id` and return the convention
/// for `param_conventions[index]`." Scanning is O(local_count) per
/// call; verifier work is already O(local_count) overall, so this
/// stays linear in function size.
fn paramConventionOf(
    function: *const ir.Function,
    local_id: ir.LocalId,
) ?ir.ParamConvention {
    var ctx = ParamGetWalker{ .target = local_id };
    ir.forEachInstruction(function, &ctx, ParamGetWalker.visit);
    const idx = ctx.found_index orelse return null;
    if (idx >= function.param_conventions.len) return null;
    return function.param_conventions[idx];
}

const ParamGetWalker = struct {
    target: ir.LocalId,
    found_index: ?u32 = null,

    fn visit(self: *@This(), instr: *const ir.Instruction) void {
        if (self.found_index != null) return;
        switch (instr.*) {
            .param_get => |pg| {
                if (pg.dest == self.target) self.found_index = pg.index;
            },
            else => {},
        }
    }
};

/// Test-mode flag suppressing diagnostic output. Negative tests
/// expect a violation and don't need the verifier to spam the
/// test runner's stderr; setting this to `true` for the duration
/// of the call keeps logs clean. Production code paths leave it
/// at its default `false` so user-facing compiler errors get
/// surfaced via `std.debug.print` to stderr.
threadlocal var suppress_diagnostics: bool = false;

/// Emit a Swift-OSSA-style diagnostic for an ARC invariant
/// violation. The diagnostic identifies the function, the rule
/// that was violated, the offending local id, and the
/// instruction tag. The caller returns
/// `error.ArcInvariantViolation` after this helper. Output goes
/// to stderr via `std.debug.print` to match the rest of the
/// compiler's diagnostic surface (other passes use the same
/// channel for stage-progress output, and the Zig test runner
/// treats `std.log.err` as a failure even when the test expects
/// the error path — `std.debug.print` does not).
fn emitDiagnostic(
    function: *const ir.Function,
    rule: []const u8,
    detail: []const u8,
    local_id: ir.LocalId,
    instr_tag: []const u8,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates ARC invariant {s}: {s} (local %{d}, instruction .{s})\n",
        .{ function.name, rule, detail, local_id, instr_tag },
    );
}

/// V11 — every local appearing as source or dest of an ARC-affecting
/// IR instruction must have `local_ownership[L] != .trivial`. Catches
/// the seeding-miss class of bug that produced the binarytrees leak
/// (commit 122bf73): when a local's `local_ownership` is misclassified
/// as `.trivial` despite the local participating in retain/release/
/// share_value/copy_value/move_value/borrow_value, the seed walk in
/// `arc_liveness.identifyArcLocals` skips it (Phase E.5 Gap 5 only
/// seeds locals with `local_ownership != .trivial`), `arc_managed_locals`
/// is incomplete, and `arc_drop_insertion` never emits the matching
/// scope-exit `.release` — leaking the cell.
///
/// V11 is the static counterpart of the V10 ZIR-direct-emission audit:
/// V10 catches new ZIR-side ARC emissions, V11 catches new IR-side
/// classification gaps.
fn checkLocalIsArcManaged(
    function: *const ir.Function,
    local_id: ir.LocalId,
    instr_tag: []const u8,
    role: []const u8,
) VerifyError!void {
    if (local_id >= function.local_ownership.len) return;
    if (function.local_ownership[local_id] == .trivial) {
        if (suppress_diagnostics) return error.ArcInvariantViolation;
        std.debug.print(
            "arc_verifier: function '{s}' violates ARC invariant V11: local %{d} appears as {s} of `.{s}` but `local_ownership` classifies it as .trivial — the seed walk in arc_liveness.identifyArcLocals will skip this local, breaking arc_managed_locals completeness and risking the binarytrees-class leak\n",
            .{ function.name, local_id, role, instr_tag },
        );
        return error.ArcInvariantViolation;
    }
}

/// Per-instruction invariant check.
fn verifyInstruction(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) VerifyError!void {
    const function = ctx.function;
    switch (instr.*) {
        // V11 — ARC-affecting alias and dataflow instructions: source
        // and dest LocalIds must have non-trivial ownership classes.
        .retain => |r| {
            try checkLocalIsArcManaged(function, r.value, "retain", "source");
        },
        .copy_value => |cv| {
            try checkLocalIsArcManaged(function, cv.source, "copy_value", "source");
            try checkLocalIsArcManaged(function, cv.dest, "copy_value", "dest");
        },
        .move_value => |mv| {
            // V6 already checks that .move_value source is .owned;
            // V11 ensures dest is also non-trivial.
            try checkLocalIsArcManaged(function, mv.dest, "move_value", "dest");
        },
        .share_value => |sv| {
            try checkLocalIsArcManaged(function, sv.source, "share_value", "source");
            try checkLocalIsArcManaged(function, sv.dest, "share_value", "dest");
        },
        // `.borrow_value` has no refcount effect — it's a pure
        // dataflow alias. The classifier may legitimately emit
        // `.borrow_value` for `.local_get`s whose source is non-ARC
        // (e.g., a `.trivial`-classified local that flows into a
        // borrowing position by virtue of its only use being a
        // borrow); the borrow is then a no-op marker. V11 must not
        // flag these. The refcount-bumping alias instructions
        // (.copy_value, .move_value, .share_value) above DO require
        // ARC-managed sources/dests.
        .borrow_value => {},
        else => {},
    }
    // V1-V7 follow on the same instruction. Re-dispatch on a separate
    // switch so the V11 check above doesn't interfere with the existing
    // semantics of V1-V7 (each set their own short-circuit returns).
    switch (instr.*) {
        // V1 + V2 + V4: `.release` semantics.
        .release => |r| {
            const class = ownershipOf(function, r.value);
            switch (class) {
                .borrowed => {
                    emitDiagnostic(
                        function,
                        "V1",
                        "borrowed local must not be released within its borrow scope",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                },
                .trivial => {
                    emitDiagnostic(
                        function,
                        "V2",
                        "release targets a non-ARC (trivial) local — refcount bookkeeping bug",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                },
                .owned => {},
            }
            // V4 — defensive double-check: even if `local_ownership`
            // somehow drifted to `.owned` for a parameter local, the
            // parameter's calling convention is the source of truth
            // for "who owns this value." A borrowed-convention param
            // is owned by the caller; releasing it on the callee
            // side would double-free.
            if (paramConventionOf(function, r.value)) |conv| {
                if (conv == .borrowed) {
                    emitDiagnostic(
                        function,
                        "V4",
                        "borrowed-convention parameter must not be released by callee",
                        r.value,
                        "release",
                    );
                    return error.ArcInvariantViolation;
                }
            }
        },

        // V6: move_value transfers an existing +1 from source to dest.
        .move_value => |mv| {
            if (ownershipOf(function, mv.source) != .owned) {
                emitDiagnostic(
                    function,
                    "V6",
                    "move_value source must be .owned; borrowed/trivial locals have no ownership unit to transfer",
                    mv.source,
                    "move_value",
                );
                return error.ArcInvariantViolation;
            }
        },

        // V3: borrows must not escape into aggregate storage.
        .struct_init => |si| {
            for (si.fields) |field| {
                try checkAggregateOperand(function, field.value, "struct_init");
            }
        },
        .list_init => |li| {
            for (li.elements) |elem| {
                try checkAggregateOperand(function, elem, "list_init");
            }
        },
        .list_cons => |lc| {
            try checkAggregateOperand(function, lc.head, "list_cons");
            try checkAggregateOperand(function, lc.tail, "list_cons");
        },
        .map_init => |mi| {
            for (mi.entries) |entry| {
                try checkAggregateOperand(function, entry.key, "map_init");
                try checkAggregateOperand(function, entry.value, "map_init");
            }
        },
        .tuple_init => |ti| {
            for (ti.elements) |elem| {
                try checkAggregateOperand(function, elem, "tuple_init");
            }
        },
        .union_init => |ui| {
            try checkAggregateOperand(function, ui.value, "union_init");
        },

        // V5: returned values must match the function's result
        // convention.
        .ret => |r| {
            if (r.value) |v| try checkReturnValue(function, v, "ret");
        },
        .cond_return => |cr| {
            if (cr.value) |v| try checkReturnValue(function, v, "cond_return");
        },
        // Multi-arm terminators carry per-arm return values.
        .switch_return => |sr| {
            for (sr.cases) |c| {
                if (c.return_value) |v| try checkReturnValue(function, v, "switch_return");
            }
            if (sr.default_result) |v| try checkReturnValue(function, v, "switch_return");
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| {
                if (c.return_value) |v| try checkReturnValue(function, v, "union_switch_return");
            }
        },

        else => {},
    }
}

/// V3 helper: assert `operand` is not a borrowed local.
fn checkAggregateOperand(
    function: *const ir.Function,
    operand: ir.LocalId,
    instr_tag: []const u8,
) VerifyError!void {
    if (ownershipOf(function, operand) == .borrowed) {
        emitDiagnostic(
            function,
            "V3",
            "borrowed local must not escape into aggregate storage; promote via copy_value first",
            operand,
            instr_tag,
        );
        return error.ArcInvariantViolation;
    }
}

/// V5 helper: assert `value` matches `function.result_convention`.
fn checkReturnValue(
    function: *const ir.Function,
    value: ir.LocalId,
    instr_tag: []const u8,
) VerifyError!void {
    if (function.result_convention != .owned) return;
    // For `.owned` result convention, the returned local must NOT
    // carry `.borrowed` ownership. `.owned` and `.trivial` are both
    // accepted — `.trivial` covers the rare path where a non-ARC
    // local flows into an ARC-typed return slot (the caller will
    // wrap it in the appropriate `Term` shape; ARC-cell semantics
    // do not apply). The plan's load-bearing constraint is the
    // borrow-promotion: a borrow returned without a matching
    // `copy_value` would let the caller release a value the
    // callee is lending out.
    if (ownershipOf(function, value) == .borrowed) {
        emitDiagnostic(
            function,
            "V5",
            "result_convention is .owned but the returned local is .borrowed; promote via copy_value at the return site",
            value,
            instr_tag,
        );
        return error.ArcInvariantViolation;
    }
}

// ============================================================
// uniqueness — alias safety on owned update.
// ============================================================
//
// uniqueness is the verifier-side defence for the unchecked-mutator
// codegen path introduced in Phase 3 of the dense-map plan. Every
// `*_owned_unchecked` runtime call (`Map.put_owned_unchecked`,
// `List.set_owned_unchecked`, etc. — see `runtime.zig`) assumes
// the caller has proven the receiver is statically uniquely owned
// (refcount == 1 by construction). The codegen emits these calls
// only at sites where the uniqueness static-uniqueness analysis
// (`uniqueness.zig`) reports `definitely_unique = true`. uniqueness
// here verifies the inverse: every unchecked call site MUST have
// uniqueness = true. Any unchecked call where uniqueness was NOT proven is
// a codegen bug that would produce undefined behavior at runtime.
//
// The check is per-function. We run the analysis and walk the IR;
// for every call instruction whose name is an unchecked owned-
// mutating builtin (per `arc_liveness.isUncheckedOwnedMutatingBuiltin`),
// we look up the analysis result for that instruction's id and
// emit a uniqueness violation if uniqueness was not proven.
//
// The walk uses the same depth-first instruction-id assignment
// `arc_liveness` and `uniqueness` use, so the per-instruction
// queries align across passes.
//
// Diagnostic shape: identifies the function, the unchecked call's
// instruction id, the receiver LocalId, and the reason — closely
// mirroring V1-V7's diagnostic surface.

/// Run the uniqueness invariant on `function`. Walks every owned-mutating
/// call site that targets an unchecked variant; for each, asserts
/// the uniqueness static-uniqueness analysis reports the receiver is
/// `definitely_unique`. Returns `error.ArcInvariantViolation` on
/// the first violation.
fn runUniquenessCheck(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
    fixpoint: ?*const uniqueness_interprocedural.ProgramUniqueness,
) VerifyError!void {
    // Fast path: scan the function for any unchecked call before
    // running the analysis. Most functions have no unchecked sites
    // (Phase 3 codegen hasn't landed yet); skipping the analysis on
    // those keeps verifier overhead minimal.
    if (!hasUncheckedCallSite(function)) return;

    var uniqueness = uniqueness_analysis.analyzeUniquenessWithFixpoint(allocator, function, program, fixpoint) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer uniqueness.deinit(allocator);

    var walker = UniquenessCheckWalker{
        .function = function,
        .uniqueness = &uniqueness,
        .next_id = 0,
        .err = null,
    };
    for (function.body) |block| {
        try walker.walkStream(block.instructions);
        if (walker.err) |e| return e;
    }
}

/// Quick per-function pre-check: does the function contain ANY
/// owned-mutating call site to an unchecked variant? Returns
/// without running the (more expensive) uniqueness analysis when there
/// are no unchecked sites.
fn hasUncheckedCallSite(function: *const ir.Function) bool {
    var checker = UncheckedCallScanner{ .found = false };
    ir.forEachInstruction(function, &checker, UncheckedCallScanner.visit);
    return checker.found;
}

const UncheckedCallScanner = struct {
    found: bool,

    fn visit(self: *@This(), instr: *const ir.Instruction) void {
        if (self.found) return;
        const name: []const u8 = switch (instr.*) {
            .call_builtin => |cb| cb.name,
            .call_named => |cn| cn.name,
            .try_call_named => |tcn| tcn.name,
            .list_tail => |lt| {
                if (lt.consume_source) self.found = true;
                return;
            },
            .call_direct => return,
            else => return,
        };
        if (arc_liveness.isUncheckedOwnedMutatingBuiltin(name)) {
            self.found = true;
        }
    }
};

const UniquenessCheckWalker = struct {
    function: *const ir.Function,
    uniqueness: *const uniqueness_analysis.Uniqueness,
    next_id: arc_liveness.InstructionId,
    err: ?VerifyError,

    fn walkStream(
        self: *UniquenessCheckWalker,
        stream: []const ir.Instruction,
    ) error{OutOfMemory}!void {
        for (stream) |*instr| {
            const my_id = self.next_id;
            self.next_id += 1;
            if (self.err != null) return;
            self.checkUncheckedCallSite(instr, my_id);
            if (self.err != null) return;
            try self.walkChildren(instr);
        }
    }

    fn walkChildren(
        self: *UniquenessCheckWalker,
        instr: *const ir.Instruction,
    ) error{OutOfMemory}!void {
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

    fn checkUncheckedCallSite(
        self: *UniquenessCheckWalker,
        instr: *const ir.Instruction,
        my_id: arc_liveness.InstructionId,
    ) void {
        const info = uncheckedCallReceiver(instr) orelse return;
        if (self.uniqueness.isUnique(my_id)) return;
        emitUniquenessDiagnostic(self.function, my_id, info.name, info.receiver);
        self.err = error.ArcInvariantViolation;
    }
};

const UncheckedCallInfo = struct {
    name: []const u8,
    receiver: ir.LocalId,
};

fn uncheckedCallReceiver(instr: *const ir.Instruction) ?UncheckedCallInfo {
    switch (instr.*) {
        .call_builtin => |cb| {
            if (!arc_liveness.isUncheckedOwnedMutatingBuiltin(cb.name)) return null;
            const slot = arc_liveness.ownedMutatingBuiltinSlot(cb.name) orelse return null;
            if (slot >= cb.args.len) return null;
            return .{ .name = cb.name, .receiver = cb.args[slot] };
        },
        .call_named => |cn| {
            if (!arc_liveness.isUncheckedOwnedMutatingBuiltin(cn.name)) return null;
            const slot = arc_liveness.ownedMutatingBuiltinSlot(cn.name) orelse return null;
            if (slot >= cn.args.len) return null;
            return .{ .name = cn.name, .receiver = cn.args[slot] };
        },
        .try_call_named => |tcn| {
            if (!arc_liveness.isUncheckedOwnedMutatingBuiltin(tcn.name)) return null;
            const slot = arc_liveness.ownedMutatingBuiltinSlot(tcn.name) orelse return null;
            if (slot >= tcn.args.len) return null;
            return .{ .name = tcn.name, .receiver = tcn.args[slot] };
        },
        .list_tail => |lt| {
            if (!lt.consume_source) return null;
            return .{ .name = "List.slice_owned_unchecked", .receiver = lt.list };
        },
        else => return null,
    }
}

fn emitUniquenessDiagnostic(
    function: *const ir.Function,
    instr_id: arc_liveness.InstructionId,
    callee_name: []const u8,
    receiver: ir.LocalId,
) void {
    if (suppress_diagnostics) return;
    std.debug.print(
        "arc_verifier: function '{s}' violates uniqueness:\n" ++
            "  unchecked owned-mutating call '{s}' at instruction {d}\n" ++
            "  receiver local %{d} is NOT statically proven to be uniquely owned\n" ++
            "  (uniqueness = false)\n" ++
            "  the codegen must not emit `*_owned_unchecked` at this site;\n" ++
            "  routing through the checked variant is the correct fix.\n",
        .{ function.name, callee_name, instr_id, receiver },
    );
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Build a minimal `ir.Function` for hand-crafted verifier tests.
/// Caller owns the slices and is responsible for freeing them with
/// the same allocator after the test concludes.
fn buildTestFunction(
    allocator: std.mem.Allocator,
    name: []const u8,
    instructions: []const ir.Instruction,
    local_ownership: []const ir.OwnershipClass,
    param_conventions: []const ir.ParamConvention,
    result_convention: ir.ResultConvention,
) !ir.Function {
    const blocks = try allocator.alloc(ir.Block, 1);
    blocks[0] = .{
        .label = 0,
        .instructions = try allocator.dupe(ir.Instruction, instructions),
    };
    const ownership_copy = try allocator.dupe(ir.OwnershipClass, local_ownership);
    const conventions_copy = try allocator.dupe(ir.ParamConvention, param_conventions);
    const params = try allocator.alloc(ir.Param, param_conventions.len);
    for (params) |*p| p.* = .{ .name = "p", .type_expr = .void, .type_id = null };
    return ir.Function{
        .id = 0,
        .name = name,
        .scope_id = 0,
        .arity = @intCast(param_conventions.len),
        .params = params,
        .return_type = .void,
        .body = blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = @intCast(local_ownership.len),
        .param_conventions = conventions_copy,
        .local_ownership = ownership_copy,
        .result_convention = result_convention,
    };
}

fn freeTestFunction(allocator: std.mem.Allocator, function: *ir.Function) void {
    allocator.free(function.body[0].instructions);
    allocator.free(function.body);
    allocator.free(function.local_ownership);
    allocator.free(function.param_conventions);
    allocator.free(function.params);
}

/// Test-only adapter that wraps a single hand-rolled `function` in a
/// minimal `Program` and invokes the public `verify`. Existing tests
/// (V1-V6) construct an isolated function and have no need for a
/// program-wide call-site survey; V7 tests build their own multi-
/// function programs and call `verify` directly.
fn verifyFunctionStandalone(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) VerifyError!void {
    const functions = [_]ir.Function{function.*};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };
    return verify(allocator, function, &program);
}

/// RAII guard that suppresses verifier diagnostics for the
/// duration of a negative test, then restores the previous
/// setting on scope exit. Each negative test instantiates one
/// before invoking `verify`.
const SuppressDiagnostics = struct {
    prev: bool,

    fn init() SuppressDiagnostics {
        const prev = suppress_diagnostics;
        suppress_diagnostics = true;
        return .{ .prev = prev };
    }

    fn deinit(self: *SuppressDiagnostics) void {
        suppress_diagnostics = self.prev;
    }
};

test "arc_verifier: rejects release of borrowed local (V1)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V1: a `.release` targeting a local whose `local_ownership` is
    // `.borrowed` is a refcount bug. The borrow does not bump the
    // source cell, so releasing it would underflow the source's
    // owner reference.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .borrowed };
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v1",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects release of trivial local (V2)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V2: a `.release` targeting a trivial local cannot represent a
    // legitimate refcount decrement — there is no ARC cell to
    // decrement. The verifier reports this as a pass bug.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.trivial};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v2",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects release of borrowed-convention parameter (V4)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V4: a parameter local whose `param_conventions` is `.borrowed`
    // is owned by the caller. Releasing it on the callee side would
    // double-free against the caller's post-call release. The check
    // is defensive: even if `local_ownership` drifted to `.owned`,
    // the parameter convention is the source of truth.
    const allocator = testing.allocator;
    // Phase H.1: V4's parameter detection now scans `.param_get`
    // instructions to map local ids to parameter indices (the prior
    // "first arity slots are params" heuristic broke once binding
    // pre-allocation pushed param locals past arity-1). The test IR
    // therefore needs an explicit `.param_get` to declare local 0 as
    // parameter index 0.
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v4",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed local stored into struct_init (V3)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V3: a `.borrow_value` dest stored into a struct field would
    // dangle once the borrow scope ends. The classifier must
    // promote the borrow via `.copy_value` first; the verifier
    // rejects any IR where this promotion was missed.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 1, .type_name = "T", .fields = &fields } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v3",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects move_value from borrowed local (V6)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();

    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .move_value = .{ .dest = 1, .source = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_move_from_borrow",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed local stored into list_init (V3)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const elements = [_]ir.LocalId{0};
    const instrs = [_]ir.Instruction{
        .{ .list_init = .{ .dest = 1, .elements = &elements, .element_type = .any } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v3_list",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects borrowed return when result_convention is owned (V5)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V5: a function declared to return `.owned` must promote any
    // borrowed return value via `.copy_value` at the return site.
    // Returning a borrow as-is would let the caller release a value
    // the callee was lending out.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.borrowed};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v5",
        &instrs,
        &ownership,
        &conventions,
        .owned,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: accepts release of owned local" {
    // Positive control for V1/V2: an `.owned` local is the legitimate
    // target of a `.release`.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_release",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: accepts owned local stored into struct_init" {
    // Positive control for V3: an `.owned` local in a struct_init
    // operand is the legitimate aggregate-init shape.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .struct_init = .{ .dest = 1, .type_name = "T", .fields = &fields } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_struct",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: accepts owned return with owned result_convention" {
    // Positive control for V5: an `.owned` local returned under
    // `.owned` result convention is the canonical case.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.owned};
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_ret",
        &instrs,
        &ownership,
        &conventions,
        .owned,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: trivial result_convention skips V5 entirely" {
    // V5 only fires under `.owned` result_convention. A function
    // returning a trivial value has no borrow-promotion obligation
    // because the caller does not perform a post-call release on a
    // trivial result.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{.borrowed};
    const conventions = [_]ir.ParamConvention{.borrowed};
    const instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_pos_trivial_ret",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: recurses into optional_dispatch arms" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // Phase D's recursion structure is exercised via Phase E's
    // invariants: a violation buried inside an optional_dispatch arm
    // body must still be reported. The negative payload local 0 is
    // borrowed; releasing it inside the struct arm violates V1.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .borrowed, .owned };
    const conventions = [_]ir.ParamConvention{};
    const arm_instrs = [_]ir.Instruction{
        .{ .release = .{ .value = 0 } },
    };
    const instrs = [_]ir.Instruction{
        .{ .optional_dispatch = .{
            .scrutinee_param = 0,
            .payload_local = 1,
            .nil_instrs = &.{},
            .nil_result = null,
            .struct_instrs = &arm_instrs,
            .struct_result = null,
        } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_recursion",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects self-recursive call followed by non-tail-mappable instruction (V6)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V6: a self-recursive `.call_named` whose result feeds a `.ret`
    // is in tail position. The IrBuilder's tail-call rewriter walks
    // past releases / retains / borrow_value / copy_value /
    // move_value when matching the call+ret pattern; any other
    // instruction between them blocks the rewrite. V6 catches that
    // regression at compile time. Here a `.struct_init` between the
    // call and the ret is the offending non-tail-mappable
    // instruction.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6", .args = &.{}, .arg_modes = &.{} } },
        .{ .struct_init = .{ .dest = 2, .type_name = "T", .fields = &fields } },
        .{ .ret = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: accepts self-recursive call followed only by tail-mappable instructions (V6)" {
    // Positive control for V6: when every instruction between a
    // self-recursive `.call_named` and its `.ret` is tail-mappable
    // (releases, retains, borrow_value, copy_value, move_value), the
    // rewriter could have rewritten the call into `.tail_call`. In
    // practice this exact shape only appears if the rewriter chose
    // not to fire (e.g., because a future refinement gates rewrites
    // on additional criteria); V6's job is solely to verify that the
    // trailing instructions are within the rewriter's whitelist, not
    // to mandate the rewrite ran.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6_pos", .args = &.{}, .arg_modes = &.{} } },
        .{ .borrow_value = .{ .dest = 2, .source = 1 } },
        .{ .copy_value = .{ .dest = 3, .source = 1 } },
        .{ .retain = .{ .value = 1 } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_pos",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: V6 silent on non-self-recursive call_named" {
    // V6 only fires for SELF-recursive calls. A `.call_named` whose
    // name does not match the enclosing function's name is unrelated
    // to the tail-call rewriter's invariant.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "OtherFunction", .args = &.{}, .arg_modes = &.{} } },
        .{ .struct_init = .{ .dest = 2, .type_name = "T", .fields = &fields } },
        .{ .ret = .{ .value = 1 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_silent",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: V6 silent when self-recursive call is not in tail position" {
    // V6 only fires for self-recursive calls in TAIL position — i.e.,
    // the call's dest feeds the function's `.ret`. A self-recursive
    // call whose dest is consumed by intermediate computation before
    // a non-matching `.ret` is genuinely non-tail and the rewriter
    // legitimately cannot rewrite it. V6 must remain silent here so
    // legal non-tail-recursive Zap programs continue to verify clean.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 1 },
    };
    const instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6_nontail", .args = &.{}, .arg_modes = &.{} } },
        .{ .struct_init = .{ .dest = 2, .type_name = "T", .fields = &fields } },
        // Note: ret value is %2 (the struct), NOT %1 (the call dest).
        // The call is therefore not in tail position.
        .{ .ret = .{ .value = 2 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_nontail",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: V6 walks into nested switch_return arms" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // V6 must inspect every nested instruction stream — the tail-call
    // rewriter handles `switch_return` cases (see
    // `IrBuilder.rewriteTailCallsInBody`). A V6 violation buried in a
    // case body must still surface at compile time.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const fields = [_]ir.StructFieldInit{
        .{ .name = "f", .value = 0 },
    };
    const arm_instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6_nested", .args = &.{}, .arg_modes = &.{} } },
        .{ .struct_init = .{ .dest = 2, .type_name = "T", .fields = &fields } },
        .{ .ret = .{ .value = 1 } },
    };
    const cases = [_]ir.ReturnCase{
        .{ .value = .{ .int = 0 }, .body_instrs = &arm_instrs, .return_value = null },
    };
    const instrs = [_]ir.Instruction{
        .{ .switch_return = .{
            .scrutinee_param = 0,
            .cases = &cases,
            .default_instrs = &.{},
            .default_result = null,
        } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_nested",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: rejects unrewritten structural tail-call inside switch_literal arm (V6 Phase E.7)" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    // Phase E.7 structural V6: a self-recursive `.call_named` whose
    // dest is its arm's `result`, sitting inside an `if_expr` /
    // `switch_literal` whose own `dest` feeds the function's `ret`,
    // is in tail position even though the call is one structural
    // level deep. The IrBuilder's `tryRewriteTailThroughBranch`
    // collapses this shape into `tail_call`. If V6 sees a
    // residue, the rewriter missed it — flag at compile time.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const true_arm_instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6_struct", .args = &.{}, .arg_modes = &.{} } },
    };
    const cases = [_]ir.LitCase{
        .{ .value = .{ .bool_val = true }, .body_instrs = &true_arm_instrs, .result = 1 },
    };
    const false_arm_instrs = [_]ir.Instruction{};
    const instrs = [_]ir.Instruction{
        .{ .switch_literal = .{
            .dest = 2,
            .scrutinee = 0,
            .cases = &cases,
            .default_instrs = &false_arm_instrs,
            .default_result = 0,
        } },
        .{ .ret = .{ .value = 2 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_struct",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    const result = verifyFunctionStandalone(allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: structural V6 silent when branch dest does not feed ret" {
    // Negative control: when the if/switch's dest is NOT the operand
    // of the immediately-following `ret`, the arms are NOT in tail
    // position. Even a self-recursive call inside an arm whose
    // result is the arm's merge value is genuinely non-tail (the
    // construct's value flows somewhere else first), so V6 must
    // remain silent.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const true_arm_instrs = [_]ir.Instruction{
        .{ .call_named = .{ .dest = 1, .name = "test_v6_nontail", .args = &.{}, .arg_modes = &.{} } },
    };
    const cases = [_]ir.LitCase{
        .{ .value = .{ .bool_val = true }, .body_instrs = &true_arm_instrs, .result = 1 },
    };
    const false_arm_instrs = [_]ir.Instruction{};
    const instrs = [_]ir.Instruction{
        .{ .switch_literal = .{
            .dest = 2,
            .scrutinee = 0,
            .cases = &cases,
            .default_instrs = &false_arm_instrs,
            .default_result = 0,
        } },
        // The construct's dest %2 is not consumed by the ret; the
        // ret returns %3 instead. The arm's call is therefore not
        // in tail position.
        .{ .ret = .{ .value = 3 } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_nontail",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: structural V6 silent when arm tail call already rewritten to tail_call" {
    // Positive control: after `tryRewriteTailThroughBranch` runs,
    // the arm body ends in `tail_call` (not `call_named`), the arm
    // result is `null`, and the outer `ret` has been dropped. V6
    // must accept this shape — it is exactly what the rewriter
    // produces.
    const allocator = testing.allocator;
    const ownership = [_]ir.OwnershipClass{ .owned, .owned, .owned };
    const conventions = [_]ir.ParamConvention{};
    const true_arm_instrs = [_]ir.Instruction{
        .{ .tail_call = .{ .name = "test_v6_rewritten", .args = &.{} } },
    };
    const cases = [_]ir.LitCase{
        .{ .value = .{ .bool_val = true }, .body_instrs = &true_arm_instrs, .result = null },
    };
    const false_arm_instrs = [_]ir.Instruction{
        .{ .ret = .{ .value = 0 } },
    };
    // No outer ret — the rewriter dropped it.
    const instrs = [_]ir.Instruction{
        .{ .switch_literal = .{
            .dest = 2,
            .scrutinee = 0,
            .cases = &cases,
            .default_instrs = &false_arm_instrs,
            .default_result = null,
        } },
    };
    var function = try buildTestFunction(
        allocator,
        "test_v6_rewritten",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(allocator, &function);

    try verifyFunctionStandalone(allocator, &function);
}

test "arc_verifier: stub function signature compiles" {
    // Pin the exported symbol so accidental signature drift surfaces
    // at compile time instead of as a downstream wiring failure.
    const fn_ptr: *const @TypeOf(verify) = &verify;
    _ = fn_ptr;
}

// ============================================================
// Phase E.9 V7 — caller-callee convention agreement
// ============================================================

/// Build a 2-function `Program` for V7 tests: a target with one
/// parameter declared at convention `target_conv`, and a caller
/// whose body is `caller_instrs`.
fn buildV7Program(
    allocator: std.mem.Allocator,
    target_conv: ir.ParamConvention,
    caller_instrs: []const ir.Instruction,
) !struct { program: ir.Program, functions: []ir.Function } {
    const target_param_conv = try allocator.alloc(ir.ParamConvention, 1);
    target_param_conv[0] = target_conv;
    const target_params = try allocator.alloc(ir.Param, 1);
    target_params[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const target_blocks = try allocator.alloc(ir.Block, 1);
    target_blocks[0] = .{
        .label = 0,
        .instructions = try allocator.dupe(ir.Instruction, &[_]ir.Instruction{
            .{ .ret = .{ .value = null } },
        }),
    };
    const target_local_ownership = try allocator.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        switch (target_conv) {
            .owned, .borrowed => .owned,
            .trivial => .trivial,
        },
    });
    const target = ir.Function{
        .id = 100,
        .name = "Mod__target__1",
        .scope_id = 0,
        .arity = 1,
        .params = target_params,
        .return_type = .void,
        .body = target_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = target_param_conv,
        .local_ownership = target_local_ownership,
        .result_convention = .trivial,
    };

    const caller_blocks = try allocator.alloc(ir.Block, 1);
    caller_blocks[0] = .{ .label = 0, .instructions = try allocator.dupe(ir.Instruction, caller_instrs) };
    const caller_param_conv = try allocator.alloc(ir.ParamConvention, 0);
    const caller_local_ownership = try allocator.dupe(ir.OwnershipClass, &[_]ir.OwnershipClass{
        .owned, .owned, .trivial,
    });
    const caller = ir.Function{
        .id = 200,
        .name = "Mod__caller__0",
        .scope_id = 0,
        .arity = 0,
        .params = &.{},
        .return_type = .void,
        .body = caller_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 3,
        .param_conventions = caller_param_conv,
        .local_ownership = caller_local_ownership,
        .result_convention = .trivial,
    };

    const functions = try allocator.alloc(ir.Function, 2);
    functions[0] = target;
    functions[1] = caller;
    const program = ir.Program{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };
    return .{ .program = program, .functions = functions };
}

test "arc_verifier: V7 rejects share_value into owned-convention slot" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    const allocator = testing.allocator;

    const args = try allocator.alloc(ir.LocalId, 1);
    defer allocator.free(args);
    args[0] = 1;
    const arg_modes = try allocator.alloc(ir.ValueMode, 1);
    defer allocator.free(arg_modes);
    arg_modes[0] = .share;

    const caller_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        // share_value into a slot the callee declares .owned —
        // V7 rejects this. Step 2's rewrite is supposed to have
        // converted this into a move_value; if a share_value
        // survives, an upstream pass missed the rewrite.
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    };

    var built = try buildV7Program(allocator, .owned, &caller_instrs);
    defer {
        allocator.free(built.functions[0].param_conventions);
        allocator.free(built.functions[0].params);
        allocator.free(built.functions[0].body[0].instructions);
        allocator.free(built.functions[0].body);
        allocator.free(built.functions[0].local_ownership);
        allocator.free(built.functions[1].param_conventions);
        allocator.free(built.functions[1].body[0].instructions);
        allocator.free(built.functions[1].body);
        allocator.free(built.functions[1].local_ownership);
        allocator.free(built.functions);
    }

    const result = verify(allocator, &built.functions[1], &built.program);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: V7 accepts move_value into owned-convention slot" {
    const allocator = testing.allocator;

    const args = try allocator.alloc(ir.LocalId, 1);
    defer allocator.free(args);
    args[0] = 1;
    const arg_modes = try allocator.alloc(ir.ValueMode, 1);
    defer allocator.free(arg_modes);
    arg_modes[0] = .share;

    const caller_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        // move_value into an owned slot — V7's positive shape.
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .ret = .{ .value = null } },
    };

    var built = try buildV7Program(allocator, .owned, &caller_instrs);
    defer {
        allocator.free(built.functions[0].param_conventions);
        allocator.free(built.functions[0].params);
        allocator.free(built.functions[0].body[0].instructions);
        allocator.free(built.functions[0].body);
        allocator.free(built.functions[0].local_ownership);
        allocator.free(built.functions[1].param_conventions);
        allocator.free(built.functions[1].body[0].instructions);
        allocator.free(built.functions[1].body);
        allocator.free(built.functions[1].local_ownership);
        allocator.free(built.functions);
    }

    try verify(allocator, &built.functions[1], &built.program);
}

test "arc_verifier: V7 rejects move_value into borrowed-convention slot" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    const allocator = testing.allocator;

    const args = try allocator.alloc(ir.LocalId, 1);
    defer allocator.free(args);
    args[0] = 1;
    const arg_modes = try allocator.alloc(ir.ValueMode, 1);
    defer allocator.free(arg_modes);
    arg_modes[0] = .share;

    const caller_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        // move_value into a borrowed slot — V7 rejects: the callee
        // borrows under the caller's retain, but a move_value
        // emitted no retain. Without the matching retain, the
        // post-call release the caller still emits would underflow.
        .{ .move_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    };

    var built = try buildV7Program(allocator, .borrowed, &caller_instrs);
    defer {
        allocator.free(built.functions[0].param_conventions);
        allocator.free(built.functions[0].params);
        allocator.free(built.functions[0].body[0].instructions);
        allocator.free(built.functions[0].body);
        allocator.free(built.functions[0].local_ownership);
        allocator.free(built.functions[1].param_conventions);
        allocator.free(built.functions[1].body[0].instructions);
        allocator.free(built.functions[1].body);
        allocator.free(built.functions[1].local_ownership);
        allocator.free(built.functions);
    }

    const result = verify(allocator, &built.functions[1], &built.program);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: V7 accepts share_value into borrowed-convention slot" {
    const allocator = testing.allocator;

    const args = try allocator.alloc(ir.LocalId, 1);
    defer allocator.free(args);
    args[0] = 1;
    const arg_modes = try allocator.alloc(ir.ValueMode, 1);
    defer allocator.free(arg_modes);
    arg_modes[0] = .share;

    const caller_instrs = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 0, .type_hint = null } },
        .{ .share_value = .{ .dest = 1, .source = 0 } },
        .{ .call_named = .{
            .dest = 2,
            .name = "Mod__target__1",
            .args = args,
            .arg_modes = arg_modes,
        } },
        .{ .release = .{ .value = 1 } },
        .{ .ret = .{ .value = null } },
    };

    var built = try buildV7Program(allocator, .borrowed, &caller_instrs);
    defer {
        allocator.free(built.functions[0].param_conventions);
        allocator.free(built.functions[0].params);
        allocator.free(built.functions[0].body[0].instructions);
        allocator.free(built.functions[0].body);
        allocator.free(built.functions[0].local_ownership);
        allocator.free(built.functions[1].param_conventions);
        allocator.free(built.functions[1].body[0].instructions);
        allocator.free(built.functions[1].body);
        allocator.free(built.functions[1].local_ownership);
        allocator.free(built.functions);
    }

    try verify(allocator, &built.functions[1], &built.program);
}

// ============================================================
// uniqueness — alias safety on owned update
// ============================================================
//
// uniqueness verifies that every `*_owned_unchecked` call site has the uniqueness
// static-uniqueness analysis (see `uniqueness.zig`) reporting
// `definitely_unique = true` for the receiver. The negative tests
// hand-roll IR shapes where the codegen incorrectly emitted an
// unchecked variant at a site without proven uniqueness — uniqueness must
// reject. The positive tests confirm uniqueness accepts well-formed IR.

test "arc_verifier: uniqueness accepts unchecked Map.put at fresh-alloc receiver" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}                    -- fresh, unique
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0                  -- transfers uniqueness
    //   [4] call_builtin "Map.put_owned_unchecked" args=[%3, %1, %2] dest=%4
    //
    // Expected: uniqueness = true at id 4 because %3 was sourced from a
    // fresh-alloc and move_value preserves uniqueness.
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 3;
    args[1] = 1;
    args[2] = 2;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    };
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_pos_fresh",
        &instrs,
        &ownership,
        &.{},
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    try verifyFunctionStandalone(testing.allocator, &function);
}

test "arc_verifier: uniqueness rejects unchecked Map.put with parameter receiver" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] param_get %0 = param[0]              -- parameter, NOT unique
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0                  -- move from non-unique source
    //   [4] call_builtin "Map.put_owned_unchecked" args=[%3, %1, %2] dest=%4
    //
    // Expected: uniqueness rejects — receiver's source is a parameter; the
    // caller controls the refcount and uniqueness cannot be proven.
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
            .name = "Map.put_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    };
    const conventions = [_]ir.ParamConvention{.owned};
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_neg_param",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    const result = verifyFunctionStandalone(testing.allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: uniqueness rejects unchecked Map.put on parked receiver" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}             -- fresh, unique
    //   [1] const_nil %1
    //   [2] list_cons %2 = [%0 | %1]    -- parks %0; %0 no longer unique
    //   [3] const_int %3 = 0
    //   [4] const_int %4 = 0
    //   [5] move_value %5 <- %0
    //   [6] call_builtin "Map.put_owned_unchecked" args=[%5, %3, %4] dest=%6
    const args = try arena.alloc(ir.LocalId, 3);
    args[0] = 5;
    args[1] = 3;
    args[2] = 4;
    const arg_modes = try arena.alloc(ir.ValueMode, 3);
    arg_modes[0] = .move;
    arg_modes[1] = .borrow;
    arg_modes[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_nil = 1 },
        .{ .list_cons = .{ .dest = 2, .head = 0, .tail = 1 } },
        .{ .const_int = .{ .dest = 3, .value = 0 } },
        .{ .const_int = .{ .dest = 4, .value = 0 } },
        .{ .move_value = .{ .dest = 5, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 6,
            .name = "Map.put_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .owned, .trivial, .trivial, .owned, .owned,
    };
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_neg_parked",
        &instrs,
        &ownership,
        &.{},
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    const result = verifyFunctionStandalone(testing.allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: uniqueness accepts chained unchecked calls (owned-mutating result is unique)" {
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream:
    //   [0] map_init %0 = {}
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 0
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "Map.put_owned_unchecked" args=[%3, %1, %2] dest=%4
    //   [5] const_int %5 = 1
    //   [6] const_int %6 = 1
    //   [7] move_value %7 <- %4
    //   [8] call_builtin "Map.put_owned_unchecked" args=[%7, %5, %6] dest=%8
    //
    // Expected: uniqueness holds at BOTH calls. The second call's receiver
    // is the result of the first owned-mutating call, which is
    // unique by runtime contract.
    const args1 = try arena.alloc(ir.LocalId, 3);
    args1[0] = 3;
    args1[1] = 1;
    args1[2] = 2;
    const arg_modes1 = try arena.alloc(ir.ValueMode, 3);
    arg_modes1[0] = .move;
    arg_modes1[1] = .borrow;
    arg_modes1[2] = .borrow;
    const args2 = try arena.alloc(ir.LocalId, 3);
    args2[0] = 7;
    args2[1] = 5;
    args2[2] = 6;
    const arg_modes2 = try arena.alloc(ir.ValueMode, 3);
    arg_modes2[0] = .move;
    arg_modes2[1] = .borrow;
    arg_modes2[2] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .const_int = .{ .dest = 1, .value = 0 } },
        .{ .const_int = .{ .dest = 2, .value = 0 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "Map.put_owned_unchecked",
            .args = args1,
            .arg_modes = arg_modes1,
        } },
        .{ .const_int = .{ .dest = 5, .value = 1 } },
        .{ .const_int = .{ .dest = 6, .value = 1 } },
        .{ .move_value = .{ .dest = 7, .source = 4 } },
        .{ .call_builtin = .{
            .dest = 8,
            .name = "Map.put_owned_unchecked",
            .args = args2,
            .arg_modes = arg_modes2,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned, .trivial, .trivial, .owned, .owned,
    };
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_pos_chain",
        &instrs,
        &ownership,
        &.{},
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    try verifyFunctionStandalone(testing.allocator, &function);
}

test "arc_verifier: uniqueness silent on functions with no unchecked call sites" {
    // uniqueness must not crash or false-positive on any function whose
    // body contains zero unchecked call sites — that includes the
    // entire pre-Phase-3 corpus.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    const args = try arena.alloc(ir.LocalId, 1);
    args[0] = 0;
    const arg_modes = try arena.alloc(ir.ValueMode, 1);
    arg_modes[0] = .borrow;
    const instrs = [_]ir.Instruction{
        .{ .map_init = .{ .dest = 0, .entries = &.{} } },
        .{ .call_builtin = .{
            .dest = 1,
            .name = "Map.size",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .trivial };
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_silent",
        &instrs,
        &ownership,
        &.{},
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    try verifyFunctionStandalone(testing.allocator, &function);
}

test "arc_verifier: uniqueness rejects unchecked List.set on parameter receiver" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Stream simulating the body of `List.set`:
    //   [0] param_get %0 = param[0]              -- vec parameter
    //   [1] const_int %1 = 0
    //   [2] const_int %2 = 42
    //   [3] move_value %3 <- %0
    //   [4] call_builtin "List.set_owned_unchecked" args=[%3, %1, %2] dest=%4
    //
    // uniqueness must reject — parameter source means uniqueness cannot be
    // proven from inside the callee.
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
        .{ .const_int = .{ .dest = 2, .value = 42 } },
        .{ .move_value = .{ .dest = 3, .source = 0 } },
        .{ .call_builtin = .{
            .dest = 4,
            .name = "List.set_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    };
    const conventions = [_]ir.ParamConvention{.owned};
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_neg_list_param",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    const result = verifyFunctionStandalone(testing.allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: uniqueness accepts consuming list_tail at fresh unique source" {
    const instrs = [_]ir.Instruction{
        .{ .list_init = .{ .dest = 0, .elements = &.{} } },
        .{ .list_tail = .{ .dest = 1, .list = 0, .element_type = .i64, .consume_source = true } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_pos_list_tail",
        &instrs,
        &ownership,
        &.{},
        .owned,
    );
    defer freeTestFunction(testing.allocator, &function);

    try verifyFunctionStandalone(testing.allocator, &function);
}

test "arc_verifier: uniqueness rejects consuming list_tail on parameter receiver" {
    var guard = SuppressDiagnostics.init();
    defer guard.deinit();

    const instrs = [_]ir.Instruction{
        .{ .param_get = .{ .dest = 0, .index = 0 } },
        .{ .list_tail = .{ .dest = 1, .list = 0, .element_type = .i64, .consume_source = true } },
    };
    const ownership = [_]ir.OwnershipClass{ .owned, .owned };
    const conventions = [_]ir.ParamConvention{.owned};
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_neg_list_tail_param",
        &instrs,
        &ownership,
        &conventions,
        .owned,
    );
    defer freeTestFunction(testing.allocator, &function);

    const result = verifyFunctionStandalone(testing.allocator, &function);
    try testing.expectError(error.ArcInvariantViolation, result);
}

test "arc_verifier: uniqueness accepts unchecked Map.put with fixpoint-proven unique parameter" {
    // Companion to "uniqueness rejects unchecked Map.put with parameter receiver":
    // when the interprocedural uniqueness fixpoint proves the parameter slot is
    // unique-on-entry, the verifier accepts the unchecked call site.
    // This is the integration seam that activates uniqueness on accumulator-
    // recursion patterns where the receiver is a parameter.
    var arena_obj = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_obj.deinit();
    const arena = arena_obj.allocator();

    // Same shape as the negative test, but with a fixpoint indicating
    // slot 0 is unique-on-entry.
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
            .name = "Map.put_owned_unchecked",
            .args = args,
            .arg_modes = arg_modes,
        } },
    };
    const ownership = [_]ir.OwnershipClass{
        .owned, .trivial, .trivial, .owned, .owned,
    };
    const conventions = [_]ir.ParamConvention{.owned};
    var function = try buildTestFunction(
        testing.allocator,
        "test_uniqueness_pos_param_with_fixpoint",
        &instrs,
        &ownership,
        &conventions,
        .trivial,
    );
    defer freeTestFunction(testing.allocator, &function);

    const functions = [_]ir.Function{function};
    const program = ir.Program{
        .functions = &functions,
        .type_defs = &.{},
        .entry = null,
    };

    // Build a fixpoint that says slot 0 is unique-on-entry.
    var fixpoint: uniqueness_interprocedural.ProgramUniqueness = .{};
    defer fixpoint.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(bool, 1);
    slots[0] = true;
    try fixpoint.by_function.put(testing.allocator, function.id, slots);

    try verifyWithFixpoint(testing.allocator, &functions[0], &program, &fixpoint);
}

test "arc_verifier: lookupConventionByName is last-wins for duplicate names" {
    // Regression: the per-struct → merged compilation pipeline can
    // register the same function name twice (once per per-struct
    // pipeline run, once for the merged whole-program IR). The
    // rewriter (`arc_ownership.ConventionIndex`) and the convention
    // inference (`arc_param_convention.inferConventions`) both use
    // last-wins semantics on `func.name`. The verifier MUST agree —
    // otherwise it reads a STALE per-struct convention while the
    // rewriter applied promotions from the merged convention,
    // surfacing as spurious V7 violations whenever the merged
    // inference upgrades a slot.
    const allocator = testing.allocator;

    // Two functions with the same `name`. The first registers a
    // `.borrowed` convention (the pre-merge inference state); the
    // second registers `.owned` (the post-merge promotion). The
    // verifier MUST return the second slice's `.owned` convention,
    // matching the rewriter's view of the world.
    const stale_convs = try allocator.alloc(ir.ParamConvention, 1);
    defer allocator.free(stale_convs);
    stale_convs[0] = .borrowed;
    const fresh_convs = try allocator.alloc(ir.ParamConvention, 1);
    defer allocator.free(fresh_convs);
    fresh_convs[0] = .owned;

    const empty_blocks = try allocator.alloc(ir.Block, 1);
    defer allocator.free(empty_blocks);
    const empty_instrs = try allocator.alloc(ir.Instruction, 0);
    defer allocator.free(empty_instrs);
    empty_blocks[0] = .{ .label = 0, .instructions = empty_instrs };
    const empty_ownership = try allocator.alloc(ir.OwnershipClass, 1);
    defer allocator.free(empty_ownership);
    empty_ownership[0] = .owned;
    const params_a = try allocator.alloc(ir.Param, 1);
    defer allocator.free(params_a);
    params_a[0] = .{ .name = "x", .type_expr = .void, .type_id = null };
    const params_b = try allocator.alloc(ir.Param, 1);
    defer allocator.free(params_b);
    params_b[0] = .{ .name = "x", .type_expr = .void, .type_id = null };

    const functions = try allocator.alloc(ir.Function, 2);
    defer allocator.free(functions);
    functions[0] = ir.Function{
        .id = 1,
        .name = "Mod__shared_name__1",
        .scope_id = 0,
        .arity = 1,
        .params = params_a,
        .return_type = .void,
        .body = empty_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = stale_convs,
        .local_ownership = empty_ownership,
        .result_convention = .trivial,
    };
    functions[1] = ir.Function{
        .id = 2,
        .name = "Mod__shared_name__1",
        .scope_id = 0,
        .arity = 1,
        .params = params_b,
        .return_type = .void,
        .body = empty_blocks,
        .is_closure = false,
        .captures = &.{},
        .local_count = 1,
        .param_conventions = fresh_convs,
        .local_ownership = empty_ownership,
        .result_convention = .trivial,
    };
    const program = ir.Program{
        .functions = functions,
        .type_defs = &.{},
        .entry = null,
    };

    const looked_up = lookupConventionByName(&program, "Mod__shared_name__1") orelse {
        try testing.expect(false);
        return;
    };
    try testing.expectEqual(@as(usize, 1), looked_up.len);
    try testing.expectEqual(ir.ParamConvention.owned, looked_up[0]);
}

// ============================================================
// V8 — forward retain→release reachability dataflow.
//
// For every `.retain { value: X }` IR instruction, every forward
// path through the function must reach a balancing operation: a
// `.release { value: X }`, a consume site (share_value mode=consume,
// move_value source, tail_call argument), or X being the function's
// return value (return-source elision).
//
// V8 is the dynamic counterpart of V10's static audit. V10 catches
// new ZIR-direct ARC emissions; V8 catches IR-level imbalance —
// retains that lack matching releases, which is the runtime symptom
// the binarytrees ~12 GB leak exhibited (916M leaked retains).
//
// Pipeline placement: V8 runs AFTER `arc_drop_insertion` because
// that's where most `.release` IR appears. The pre-drop verifier
// (V1-V7, V11) doesn't run V8 — at that pipeline position, only the
// post-call cleanup releases exist; scope-exit destroys haven't been
// inserted yet. V8 is invoked from `verifyPostDropInsertion` (a
// new public entry point in this module) which the compiler driver
// calls from `compiler.zig:2307` after `insertScopeExitDrops`.
//
// This implementation handles linear streams precisely. Nested
// control flow (if_expr, case_block, switch_return, optional_dispatch,
// union_switch_return, try_call_named, guard_block) is handled by
// recursing into each arm with a cloned state and merging at the
// rejoin point. The merge rule is permissive: parent state inherits
// the maximum of any arm's outstanding count for each local, which
// catches "retain in one arm, release in all arms" but allows the
// parent to continue (subsequent code can drain remaining counts).
// Strict per-arm-equality merge is deferred — it would false-positive
// on legitimate patterns like `if cond { retain(x); use(x); release(x) }`
// where the retain/release pair is contained within one arm.
//
// `.owned`-convention parameters carry an implicit +1 from the
// caller's `share_value(retain)` site. V8 seeds the entry state
// with +1 for each `.owned`-convention param's dest local (resolved
// via the function's first `.param_get` instructions). Without this
// seed, V8 false-positives on every `.owned`-convention function:
// the callee's matching scope-exit `.release` would have nothing to
// match.
// ============================================================

const V8State = struct {
    allocator: std.mem.Allocator,
    /// Per-local outstanding retain count. A non-zero entry means
    /// the local has been retained (or owns an implicit +1 from
    /// `.owned`-convention parameter inheritance) without yet being
    /// matched by a release / consume / return-source elision.
    counts: std.AutoHashMapUnmanaged(ir.LocalId, u32) = .empty,
    /// Set to true once any V8 violation is reported. Subsequent
    /// terminator checks short-circuit so a single function doesn't
    /// produce a flood of cascade diagnostics.
    failed: bool = false,

    fn deinit(self: *V8State) void {
        self.counts.deinit(self.allocator);
    }

    fn retain(self: *V8State, value: ir.LocalId) !void {
        const gop = try self.counts.getOrPut(self.allocator, value);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    fn consumeOne(self: *V8State, value: ir.LocalId) void {
        if (self.counts.getPtr(value)) |entry| {
            if (entry.* > 0) entry.* -= 1;
        }
    }

    fn copy(self: *const V8State) !V8State {
        var dup: V8State = .{ .allocator = self.allocator };
        try dup.counts.ensureTotalCapacity(self.allocator, self.counts.count());
        var iter = self.counts.iterator();
        while (iter.next()) |entry| {
            try dup.counts.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        return dup;
    }

    fn mergeMax(self: *V8State, other: *const V8State) !void {
        var iter = other.counts.iterator();
        while (iter.next()) |entry| {
            const cur = self.counts.get(entry.key_ptr.*) orelse 0;
            if (entry.value_ptr.* > cur) {
                try self.counts.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    /// Returns the LocalId of any unbalanced retain count, or null
    /// when every count is zero (or the only non-zero is the
    /// return-source local with count 1).
    fn unbalancedLocal(self: *const V8State, return_value: ?ir.LocalId) ?ir.LocalId {
        var iter = self.counts.iterator();
        while (iter.next()) |entry| {
            const v = entry.value_ptr.*;
            if (v == 0) continue;
            // Return-source elision: a single retain on the return
            // value transfers ownership to the caller's return slot.
            if (return_value) |rv| {
                if (entry.key_ptr.* == rv and v == 1) continue;
            }
            return entry.key_ptr.*;
        }
        return null;
    }
};

/// Seed V8's entry state with +1 for each `.owned`-convention
/// parameter, resolved via the first `.param_get` with matching
/// index encountered in a recursive walk over every nested
/// instruction stream. `.owned` convention guarantees the caller
/// retained the param via `share_value(retain)` and the callee
/// owns the +1 — V8 must model this implicit retain or every
/// function with `.owned` params produces a false-positive at its
/// matching scope-exit `.release`.
fn v8SeedOwnedParams(state: *V8State, function: *const ir.Function) error{OutOfMemory}!void {
    if (function.param_conventions.len == 0) return;
    var resolved: std.AutoHashMapUnmanaged(u32, ir.LocalId) = .empty;
    defer resolved.deinit(state.allocator);
    for (function.body) |block| {
        try v8SeedFromStream(state.allocator, block.instructions, &resolved);
    }
    for (function.param_conventions, 0..) |conv, i| {
        if (conv != .owned) continue;
        const param_index: u32 = @intCast(i);
        if (resolved.get(param_index)) |dest_local| {
            try state.retain(dest_local);
        }
        // If no param_get was ever emitted for this index, the
        // param is unused inside the function body — no implicit
        // retain to seed.
    }
}

fn v8SeedFromStream(
    allocator: std.mem.Allocator,
    stream: []const ir.Instruction,
    resolved: *std.AutoHashMapUnmanaged(u32, ir.LocalId),
) error{OutOfMemory}!void {
    for (stream) |instr| {
        switch (instr) {
            .param_get => |pg| {
                const gop = try resolved.getOrPut(allocator, pg.index);
                if (!gop.found_existing) gop.value_ptr.* = pg.dest;
            },
            .if_expr => |ie| {
                try v8SeedFromStream(allocator, ie.then_instrs, resolved);
                try v8SeedFromStream(allocator, ie.else_instrs, resolved);
            },
            .case_block => |cb| {
                try v8SeedFromStream(allocator, cb.pre_instrs, resolved);
                for (cb.arms) |arm| {
                    try v8SeedFromStream(allocator, arm.cond_instrs, resolved);
                    try v8SeedFromStream(allocator, arm.body_instrs, resolved);
                }
                try v8SeedFromStream(allocator, cb.default_instrs, resolved);
            },
            .switch_literal => |sl| {
                for (sl.cases) |c| try v8SeedFromStream(allocator, c.body_instrs, resolved);
                try v8SeedFromStream(allocator, sl.default_instrs, resolved);
            },
            .switch_return => |sr| {
                for (sr.cases) |c| try v8SeedFromStream(allocator, c.body_instrs, resolved);
                try v8SeedFromStream(allocator, sr.default_instrs, resolved);
            },
            .union_switch => |us| {
                for (us.cases) |c| try v8SeedFromStream(allocator, c.body_instrs, resolved);
            },
            .union_switch_return => |usr| {
                for (usr.cases) |c| try v8SeedFromStream(allocator, c.body_instrs, resolved);
            },
            .try_call_named => |tc| {
                try v8SeedFromStream(allocator, tc.success_instrs, resolved);
                try v8SeedFromStream(allocator, tc.handler_instrs, resolved);
            },
            .guard_block => |gb| {
                try v8SeedFromStream(allocator, gb.body, resolved);
            },
            .optional_dispatch => |od| {
                try v8SeedFromStream(allocator, od.nil_instrs, resolved);
                try v8SeedFromStream(allocator, od.struct_instrs, resolved);
            },
            else => {},
        }
    }
}

/// V8 forward dataflow walker. Processes instructions linearly,
/// updating `state` in place. Recursion into nested streams
/// (if_expr, case_block, etc.) computes per-arm states and merges
/// them via maximum-count union back into the parent state.
fn v8VerifyStream(
    function: *const ir.Function,
    state: *V8State,
    stream: []const ir.Instruction,
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        try v8VerifyInstruction(function, state, instr);
    }
}

fn v8VerifyInstruction(
    function: *const ir.Function,
    state: *V8State,
    instr: *const ir.Instruction,
) error{OutOfMemory}!void {
    switch (instr.*) {
        .retain => |r| try state.retain(r.value),
        .release => |r| state.consumeOne(r.value),
        .move_value => |mv| {
            // Move transfers ownership: source consumed, dest inherits.
            state.consumeOne(mv.source);
            try state.retain(mv.dest);
        },
        .share_value => |sv| {
            if (sv.mode == .consume) state.consumeOne(sv.source);
            // Mode=retain: the corresponding `.retain` IR is emitted
            // separately by the IR builder (Phase 1 Class A item 2);
            // V8 accounts for it when it processes that `.retain`.
        },
        .tail_call => |tc| {
            // Tail call consumes its args.
            for (tc.args) |arg| state.consumeOne(arg);
            v8CheckTerminator(function, state, "tail_call", null);
        },
        .ret => |r| v8CheckTerminator(function, state, "ret", r.value),
        .cond_return => |cr| v8CheckTerminator(function, state, "cond_return", cr.value),
        .switch_return => |sr| {
            for (sr.cases) |c| {
                var arm = try state.copy();
                defer arm.deinit();
                try v8VerifyStream(function, &arm, c.body_instrs);
                v8CheckTerminator(function, &arm, "switch_return", c.return_value);
                try state.mergeMax(&arm);
            }
            if (sr.default_instrs.len > 0) {
                var arm = try state.copy();
                defer arm.deinit();
                try v8VerifyStream(function, &arm, sr.default_instrs);
                v8CheckTerminator(function, &arm, "switch_return.default", sr.default_result);
                try state.mergeMax(&arm);
            }
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| {
                var arm = try state.copy();
                defer arm.deinit();
                try v8VerifyStream(function, &arm, c.body_instrs);
                v8CheckTerminator(function, &arm, "union_switch_return", c.return_value);
                try state.mergeMax(&arm);
            }
        },
        .if_expr => |ie| {
            var then_state = try state.copy();
            defer then_state.deinit();
            try v8VerifyStream(function, &then_state, ie.then_instrs);
            var else_state = try state.copy();
            defer else_state.deinit();
            try v8VerifyStream(function, &else_state, ie.else_instrs);
            try state.mergeMax(&then_state);
            try state.mergeMax(&else_state);
        },
        .case_block => |cb| {
            try v8VerifyStream(function, state, cb.pre_instrs);
            for (cb.arms) |arm| {
                var s = try state.copy();
                defer s.deinit();
                try v8VerifyStream(function, &s, arm.cond_instrs);
                try v8VerifyStream(function, &s, arm.body_instrs);
                try state.mergeMax(&s);
            }
            if (cb.default_instrs.len > 0) {
                var s = try state.copy();
                defer s.deinit();
                try v8VerifyStream(function, &s, cb.default_instrs);
                try state.mergeMax(&s);
            }
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| {
                var s = try state.copy();
                defer s.deinit();
                try v8VerifyStream(function, &s, c.body_instrs);
                try state.mergeMax(&s);
            }
            if (sl.default_instrs.len > 0) {
                var s = try state.copy();
                defer s.deinit();
                try v8VerifyStream(function, &s, sl.default_instrs);
                try state.mergeMax(&s);
            }
        },
        .union_switch => |us| {
            for (us.cases) |c| {
                var s = try state.copy();
                defer s.deinit();
                try v8VerifyStream(function, &s, c.body_instrs);
                try state.mergeMax(&s);
            }
        },
        .try_call_named => |tc| {
            var success_state = try state.copy();
            defer success_state.deinit();
            try v8VerifyStream(function, &success_state, tc.success_instrs);
            var handler_state = try state.copy();
            defer handler_state.deinit();
            try v8VerifyStream(function, &handler_state, tc.handler_instrs);
            try state.mergeMax(&success_state);
            try state.mergeMax(&handler_state);
        },
        .guard_block => |gb| {
            try v8VerifyStream(function, state, gb.body);
        },
        .optional_dispatch => |od| {
            var nil_state = try state.copy();
            defer nil_state.deinit();
            try v8VerifyStream(function, &nil_state, od.nil_instrs);
            v8CheckTerminator(function, &nil_state, "optional_dispatch.nil", od.nil_result);
            var struct_state = try state.copy();
            defer struct_state.deinit();
            try v8VerifyStream(function, &struct_state, od.struct_instrs);
            v8CheckTerminator(function, &struct_state, "optional_dispatch.struct", od.struct_result);
            try state.mergeMax(&nil_state);
            try state.mergeMax(&struct_state);
        },
        else => {},
    }
}

fn v8CheckTerminator(
    function: *const ir.Function,
    state: *V8State,
    site: []const u8,
    return_value: ?ir.LocalId,
) void {
    if (state.failed) return;
    if (state.unbalancedLocal(return_value)) |bad_local| {
        state.failed = true;
        if (suppress_diagnostics) return;
        // V8 is in opt-in warning mode while the implementation is
        // being refined. Several common ARC patterns (post-call
        // release of share_value dest, .borrowed-convention params
        // whose retains aren't seen because the param_get's source
        // is a different local than V8 expects, complex tail-call
        // arg consumption) currently false-positive. Set
        // `ZAP_DEBUG_V8=1` to see V8's warnings during investigation;
        // otherwise stay quiet so the build output isn't flooded.
        // The check infrastructure is fully in place — when V8's
        // model is refined to eliminate the false-positive classes,
        // this gate flips off and V8 becomes a permanent tripwire
        // alongside V1-V7, V10, V11.
        if (std.c.getenv("ZAP_DEBUG_V8") == null) return;
        const count = state.counts.get(bad_local) orelse 0;
        std.debug.print(
            "arc_verifier: function '{s}' violates ARC invariant V8: local %{d} has {d} unbalanced retain(s) at {s} terminator — every `.retain` must be matched on every forward path by a `.release`, a consume site, or being the function's return value (return-source elision)\n",
            .{ function.name, bad_local, count, site },
        );
    }
}

/// Public entry point for V8 post-drop-insertion verification.
/// Called from `compiler.zig` after
/// `arc_drop_insertion.insertScopeExitDrops`. Currently runs in
/// warning-only mode — V8 violations print to stderr but do not
/// halt compilation. Once the existing IR passes V8 cleanly across
/// the test suite and benchmark corpus, the warning can be flipped
/// to a hard error by changing `v8CheckTerminator` to return
/// `error.ArcInvariantViolation` from this function.
pub fn verifyPostDropInsertion(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
    program: *const ir.Program,
) VerifyError!void {
    _ = program;
    if (function.body.len == 0) return;
    var state: V8State = .{ .allocator = allocator };
    defer state.deinit();
    try v8SeedOwnedParams(&state, function);
    for (function.body) |block| {
        try v8VerifyStream(function, &state, block.instructions);
    }
    // Warning-only: do not propagate violations as errors. The
    // diagnostic messages emitted from `v8CheckTerminator` give
    // developers actionable feedback without breaking the build
    // until V8 has been validated against the full corpus.
}

// ============================================================
// V10 — static "no ZIR-direct ARC emission" audit.
//
// Phase 0 of the ARC IR-source-of-truth refactor (see
// `docs/arc-emission-architecture-research-brief.md`). The architectural
// invariant being pinned:
//
//     Every retain or release runtime call the compiled Zap program
//     executes corresponds 1:1 to the lowering of a `.retain` or
//     `.release` IR instruction.
//
// Concretely: the only call sites in `src/zir_builder.zig` that may
// emit `retainAny*` / `releaseAny*` / `freeAny` / `resetAny` /
// `reuseAllocByType` runtime calls are the IR-instruction handlers
// for `.retain`, `.release`, `.reset`, and (when introduced) `.reuse_alloc`.
//
// V10 is a *source-level* audit: it scans `zir_builder.zig` line by
// line, counts each forbidden-pattern occurrence, and asserts the
// count exactly equals an allowlist of currently-known sites. New
// violations introduced after this test was written (i.e., a future
// PR adds a `retainAnyOpt` outside a canonical handler) cause the
// test to fail with a precise location. Existing violations stay
// allowlisted until the relevant phase removes them; the allowlist
// shrinks across Phase 1 / Phase 2 / Phase 3 commits.
//
// The audit operates on the *embedded* source text — not on the IR
// the compiler currently emits — so it runs at `zig build test` time
// without requiring a built compiler binary. Mode: warning (non-fail)
// for now via the diagnostic-only path. The matching strict-mode
// gate flips on once Phase 1/2/3 reduce the allowlist to its known-
// canonical targets.
// ============================================================

const v10_zir_builder_source = @embedFile("zir_builder.zig");

const V10ForbiddenPattern = struct {
    /// Substring scanned for. Matches any token contained within
    /// (so `retainAny` matches `retainAny`, `retainAnyPersistent`,
    /// `retainAnyOpt`, `retainChildrenAny`).
    needle: []const u8,
    /// Human-readable description used in diagnostics.
    label: []const u8,
};

const v10_forbidden_patterns: []const V10ForbiddenPattern = &.{
    .{ .needle = "\"retainAny\"", .label = "ArcRuntime.retainAny" },
    .{ .needle = "\"retainAnyPersistent\"", .label = "ArcRuntime.retainAnyPersistent" },
    .{ .needle = "\"retainAnyOpt\"", .label = "ArcRuntime.retainAnyOpt" },
    .{ .needle = "\"retainChildrenAny\"", .label = "ArcRuntime.retainChildrenAny" },
    .{ .needle = "\"releaseAny\"", .label = "ArcRuntime.releaseAny" },
    .{ .needle = "\"releaseChildrenAny\"", .label = "ArcRuntime.releaseChildrenAny" },
    .{ .needle = "\"freeAny\"", .label = "ArcRuntime.freeAny" },
    .{ .needle = "\"resetAny\"", .label = "ArcRuntime.resetAny" },
    .{ .needle = "\"reuseAllocByType\"", .label = "ArcRuntime.reuseAllocByType" },
};

/// Scan `source` for occurrences of each forbidden pattern. Returns
/// the total number of hits. Each hit is also surfaced via
/// `std.debug.print` when `verbose` is true so a failing assertion
/// has actionable context.
fn v10CountForbiddenEmissions(source: []const u8, verbose: bool) usize {
    var count: usize = 0;
    var line_no: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            const line = source[line_start..i];
            for (v10_forbidden_patterns) |pat| {
                if (std.mem.indexOf(u8, line, pat.needle) != null) {
                    count += 1;
                    if (verbose) {
                        std.debug.print(
                            "[arc_verifier V10] zir_builder.zig:{d}: {s} emission outside canonical handler\n  {s}\n",
                            .{ line_no, pat.label, std.mem.trim(u8, line, " \t") },
                        );
                    }
                }
            }
            line_no += 1;
            line_start = i + 1;
        }
    }
    // Trailing line without newline.
    if (line_start < source.len) {
        const line = source[line_start..];
        for (v10_forbidden_patterns) |pat| {
            if (std.mem.indexOf(u8, line, pat.needle) != null) {
                count += 1;
                if (verbose) {
                    std.debug.print(
                        "[arc_verifier V10] zir_builder.zig:{d}: {s} emission outside canonical handler\n  {s}\n",
                        .{ line_no, pat.label, std.mem.trim(u8, line, " \t") },
                    );
                }
            }
        }
    }
    return count;
}

/// Allowlisted total of forbidden-pattern occurrences as of the most
/// recent ARC refactor commit. Each entry below corresponds to a
/// specific known emission site in `zir_builder.zig`.
///
/// Increase this number ONLY when a new canonical handler is added
/// (e.g., the `.reuse_alloc` IR-instruction handler in Phase 3). To
/// remove a known violation, decrement this number AND the violation
/// catalogue below in the same commit. A drift between the audit and
/// the catalogue is a bug.
///
/// Catalogue (audit baseline post Phase 1 Class A items 1+2 — the
/// `.copy_value` and `.share_value` mode=retain implicit-retain
/// emissions have moved into IR-level `.retain { kind }` instructions
/// emitted by `arc_ownership.zig`):
///
///   Canonical IR-handler sites — these MUST be in the count,
///   removing them from `zir_builder.zig` means the IR-level
///   retain/release primitive itself is broken:
///
///     1. `.retain` IR handler `retainAny` branch (kind=.normal):
///        1 × "retainAny" (zir_builder.zig)
///     2. `.retain` IR handler `retainAnyPersistent` branch
///        (kind=.persistent): 1 × "retainAnyPersistent"
///        (zir_builder.zig — added in Phase 1 Class A item 1)
///     3. `.release` IR handler: 1 × "releaseAny" emission
///        (zir_builder.zig)
///     4. `.reset` IR handler: 1 × "resetAny" emission
///        (zir_builder.zig)
///
///   Class B violations (Phase 2):
///     5. `emitAnalysisArcOps` retain branch: 1 × "retainAny"
///        (zir_builder.zig:3907)
///     6. `emitAnalysisArcOps` release branch: 1 × "releaseAny"
///        (zir_builder.zig:3922)
///     7. `emitDropSpecializationsForCurrentInstr` deep arm:
///        1 × "releaseAny" (zir_builder.zig:3962)
///     8. `emitDropSpecializationsForCurrentInstr` shallow arm:
///        1 × "freeAny" (zir_builder.zig:3963)
///     9. `emitPerceusResetForCase`: 1 × "resetAny"
///        (zir_builder.zig:3984)
///
///   Class C violations (Phase 3):
///    10. early `.struct_init` reuse path: 1 × "reuseAllocByType"
///        (zir_builder.zig:5336)
///    11. `.struct_init` reuse-pair: 1 × "reuseAllocByType"
///        (zir_builder.zig:5573)
///    12. `.union_init` reuse-pair: 1 × "reuseAllocByType"
///        (zir_builder.zig:5917)
///    13. an additional `reuseAllocByType` emission at line 6804
///        — provisional categorisation (likely the same Perceus
///        reuse class). Verify during Phase 3 implementation.
///
///   `.release` IR handler also emits `noteReturnElision` (a counter
///   bump), but that is not a forbidden ARC runtime call — pure
///   bookkeeping, no refcount effect.
///
/// Total expected: 13. Pre-Phase-1-Class-A baseline was 14
/// (original `.copy_value` had retainAnyPersistent + `.share_value`
/// mode=retain had retainAny; both moved to canonical `.retain`
/// handler dispatch on kind, net -1 because both formerly-violation
/// sites collapsed into one already-canonical handler that now
/// dispatches on a kind enum). Phase 2 reduces to 8. Phase 3
/// reduces to 4 (only canonical handlers remain, including a
/// fourth for `.reuse_alloc` once introduced).
const v10_expected_total: usize = 13;

test "V10: zir_builder.zig forbidden ARC emissions match phase-tracked allowlist" {
    const observed = v10CountForbiddenEmissions(v10_zir_builder_source, false);
    if (observed != v10_expected_total) {
        // Re-scan with verbose output to surface every site for
        // anyone investigating the failure.
        std.debug.print(
            "\n[arc_verifier V10] zir_builder.zig forbidden-pattern audit drifted: observed {d}, expected {d}\n" ++
                "Phase advance: update v10_expected_total AND the catalogue comment in arc_verifier.zig.\n" ++
                "All current sites:\n",
            .{ observed, v10_expected_total },
        );
        _ = v10CountForbiddenEmissions(v10_zir_builder_source, true);
    }
    try testing.expectEqual(v10_expected_total, observed);
}

test "V10: forbidden-pattern scanner correctly identifies a hit" {
    const sample =
        \\fn legit_handler() void {
        \\    const fn = zir_builder_emit_field_val(handle, arc_runtime, "retainAny", 9);
        \\}
    ;
    try testing.expectEqual(@as(usize, 1), v10CountForbiddenEmissions(sample, false));
}

test "V10: forbidden-pattern scanner correctly ignores unrelated text" {
    const sample =
        \\fn unrelated() void {
        \\    const x: i64 = 0;
        \\    // a comment mentioning retainAny without quoting
        \\    var y = x + 1;
        \\}
    ;
    // No occurrence of `"retainAny"` (note quotes); just a bare
    // identifier in a comment — should not match.
    try testing.expectEqual(@as(usize, 0), v10CountForbiddenEmissions(sample, false));
}
