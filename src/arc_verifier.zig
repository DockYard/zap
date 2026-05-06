const std = @import("std");
const ir = @import("ir.zig");

// ============================================================
// ARC ownership verifier.
//
// Phase A of the Phase 6 redux plan introduces this module as a
// scaffold. The pass slots into the compilation pipeline between
// `arc_ownership` (normalization) and `arc_drop_insertion`
// (scope-exit `release` emission), per §2.2 of the plan:
//
//     ... → arc_ownership
//             → arc_verifier   (THIS PASS — invariant checking)
//                  → arc_drop_insertion
//                       → ...
//
// Phase D (this commit) extends the recursion structure so the
// verifier walks every nested instruction stream — `if_expr`,
// `case_block`, `switch_literal`, `switch_return`, `union_switch`,
// `union_switch_return`, `try_call_named.handler_instrs` /
// `success_instrs`, `guard_block.body`, and
// `optional_dispatch.nil_instrs` / `struct_instrs`. Each stream is
// visited via `verifyStream`; per-instruction invariants are
// applied via `verifyInstruction`. Today both helpers are no-ops
// — Phase E activates the actual checks (per §2.2 / §3 / §1.6 of
// the plan):
//   - Owned values are destroyed exactly once on every CFG path.
//   - Borrowed values are never destroyed.
//   - Borrows do not escape their region.
//   - Function parameters of borrowed convention are not destroyed.
//   - Return values match the function's `result_convention`.
// Verifier failures will emit a Swift-OSSA-style diagnostic with
// the offending instruction, ownership class, and a description of
// the violated rule.
//
// The recursion structure is landed ahead of Phase E so that
// activating an invariant only requires populating the per-
// instruction body of `verifyInstruction` — no traversal logic
// has to be revisited.
//
// Phase G will additionally fuzz this verifier under ASan/LSan to
// surface gaps the static checks miss.
// ============================================================

/// Verify ownership invariants on `function`. Phase D structural
/// scaffold: walks every nested instruction stream and visits every
/// instruction, but performs no per-instruction or per-stream
/// checks yet. Phase E populates `verifyInstruction` (and
/// optionally `verifyStream`) with the actual invariant logic.
///
/// Allocator is reserved for Phase E's per-CFG-path bitset tracking
/// (`live_owned`, `live_borrowed`); Phase D needs no allocations.
pub fn verify(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) !void {
    _ = allocator;
    var ctx = VerifyContext{ .function = function };
    for (function.body) |block| {
        try verifyStream(&ctx, block.instructions);
    }
}

/// Per-verification context. Phase D: only the function pointer.
/// Phase E will add per-CFG-path state (e.g. `live_owned` /
/// `live_borrowed` bitsets) reset on each region entry/exit.
const VerifyContext = struct {
    function: *const ir.Function,
};

/// Visit every instruction in `stream` (and recursively in every
/// nested sub-stream). Each instruction is handed to
/// `verifyInstruction` — Phase D's no-op stub. This helper is the
/// single point where the recursion structure is defined; Phase E's
/// invariant logic lives entirely inside `verifyInstruction`
/// (or sibling per-region helpers introduced as needed).
fn verifyStream(
    ctx: *VerifyContext,
    stream: []const ir.Instruction,
) error{OutOfMemory}!void {
    for (stream) |*instr| {
        try verifyInstruction(ctx, instr);
        try verifyChildren(ctx, instr);
    }
}

/// Recurse into every nested instruction stream owned by `instr`.
/// Mirrors `arc_liveness.flattenChildren` and
/// `arc_drop_insertion.rebuildChildren` — the three traversals must
/// agree on which streams contain checkable IR. Phase E invariants
/// (no-destroy-of-borrowed, exactly-one-destroy-of-owned, no-borrow-
/// escape) all operate per stream, so a missing recursion here would
/// translate directly to an under-checked region at Phase E.
fn verifyChildren(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) error{OutOfMemory}!void {
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
            // Phase D (Phase 6 redux plan §3.D): recurse into both
            // arm bodies so Phase E invariants apply uniformly to
            // every borrow/copy and every destroy regardless of
            // nesting depth. Order is consistent with the analyzer
            // and drop-insertion rebuilder (nil first, then struct).
            try verifyStream(ctx, od.nil_instrs);
            try verifyStream(ctx, od.struct_instrs);
        },
        else => {},
    }
}

/// Per-instruction invariant check. Phase D: no-op. Phase E populates
/// this with the ownership invariants:
///
///   1. `.destroy_value` (or today's `.release` proxy) targets a
///      local whose ownership class is `.owned` — never `.borrowed`
///      and never `.trivial`.
///   2. `.borrow_value` produces a `.borrowed` dest whose every use
///      is consumed before any region exit.
///   3. `.copy_value` produces an `.owned` dest paired with exactly
///      one destroy on every CFG path that reaches a function exit.
///   4. Function parameters with `.borrowed` convention are never
///      destroyed.
///   5. `ret`/`tail_call`/`switch_return.cases[].return_value` of a
///      function with `.owned` `result_convention` carry an `.owned`
///      local (promoted from a borrow via `.copy_value` if needed).
///
/// Each violation produces a Swift-OSSA-style diagnostic with the
/// instruction tag, the offending local's ownership class, and the
/// human-readable rule label.
fn verifyInstruction(
    ctx: *VerifyContext,
    instr: *const ir.Instruction,
) error{OutOfMemory}!void {
    _ = ctx;
    _ = instr;
    // TODO(Phase E): populate. Leave the structural recursion in
    // `verifyChildren` untouched.
}

test "arc_verifier: stub function signature compiles" {
    // Phase A's stub must not error and must not require any
    // particular function shape. Phase E will replace this with
    // negative tests (one per invariant) and positive tests on every
    // currently-shipping IR program.
    const fn_ptr: *const @TypeOf(verify) = &verify;
    _ = fn_ptr;
}
