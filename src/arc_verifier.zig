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
// In Phase A this pass is a stub: it accepts every IR program. The
// metadata it will eventually consume (`Function.param_conventions`,
// `Function.local_ownership`, `Function.result_convention`) is
// populated by the IR builder with safe defaults; subsequent phases
// refine the classification before this verifier runs.
//
// Phase E activates the actual invariant checks (per §2.2 / §3 /
// §1.6 of the plan):
//   - Owned values are destroyed exactly once on every CFG path.
//   - Borrowed values are never destroyed.
//   - Borrows do not escape their region.
//   - Function parameters of borrowed convention are not destroyed.
//   - Return values match the function's `result_convention`.
// Verifier failures emit a Swift-OSSA-style diagnostic with the
// offending instruction, ownership class, and a description of the
// violated rule.
//
// Phase G will additionally fuzz this verifier under ASan/LSan to
// surface gaps the static checks miss.
// ============================================================

/// Verify ownership invariants on `function`. Phase A: stub.
/// Accepts every IR shape unchanged; performs no allocations and
/// returns success unconditionally. Subsequent phases will populate
/// this with the actual invariant checks.
pub fn verify(
    allocator: std.mem.Allocator,
    function: *const ir.Function,
) !void {
    _ = allocator;
    _ = function;
}

test "arc_verifier: stub function signature compiles" {
    // Phase A's stub must not error and must not require any
    // particular function shape. Phase E will replace this with
    // negative tests (one per invariant) and positive tests on every
    // currently-shipping IR program.
    const fn_ptr: *const @TypeOf(verify) = &verify;
    _ = fn_ptr;
}
