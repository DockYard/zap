const std = @import("std");
const ir = @import("ir.zig");
const arc_liveness = @import("arc_liveness.zig");
const types_mod = @import("types.zig");

// ============================================================
// ARC ownership classification and normalization pass.
//
// Phase A of the Phase 6 redux plan introduces this module as a
// scaffold. The pass slots into the compilation pipeline between
// `arc_liveness` (last-use analysis) and `arc_drop_insertion`
// (scope-exit `release` emission), per §2.2 of the plan:
//
//     ... → arc_liveness
//             → arc_ownership   (THIS PASS — normalization)
//                  → arc_verifier (invariants — Phase E)
//                       → arc_drop_insertion
//                            → ...
//
// In Phase A this pass is a stub: it accepts every function and
// performs no IR mutation. The metadata it will eventually consume
// (`Function.param_conventions`, `Function.local_ownership`,
// `Function.result_convention`) is already populated by the IR
// builder with safe defaults — ARC-managed parameters classified as
// `.borrowed`, ARC-managed locals classified as `.owned`, and ARC-
// managed return types classified as `.owned`.
//
// Phase C will implement the borrow/copy decision logic. Walking
// each function body, the pass replaces overloaded `local_get`
// instructions with explicit `borrow_value` or `copy_value` forms
// based on the destination's eventual usage:
//   - dest is a call argument to a borrowing-convention parameter
//     -> `borrow_value` (no retain, no scope-exit destroy)
//   - dest is stored into another owned aggregate
//     -> `copy_value` (retain, scope-exit destroy)
//   - dest flows into a `ret` whose source is a parameter
//     -> `copy_value` (promote borrow to owned for return)
//   - default -> `copy_value` (conservative; Phase E verifier
//     prompts refinement when conservative classification is wrong)
//
// Phase E activates the verifier on the post-normalization IR and
// uses ownership classes to enforce single-destroy / no-leak / no-
// borrow-escape invariants.
// ============================================================

/// Classify and normalize ownership for `function`. Phase A: stub.
/// Accepts every IR shape unchanged; performs no allocations beyond
/// what callers expect from the function-pass interface. Subsequent
/// phases will populate this with the actual normalization logic.
pub fn classifyAndNormalize(
    allocator: std.mem.Allocator,
    function: *ir.Function,
    ownership: *const arc_liveness.ArcOwnership,
    type_store: *const types_mod.TypeStore,
) !void {
    _ = allocator;
    _ = function;
    _ = ownership;
    _ = type_store;
}

test "arc_ownership: stub function signature compiles" {
    // Phase A's stub must not error and must not require any
    // particular function shape. The integration test in compiler.zig
    // exercises the wired pipeline; this unit test pins the stub's
    // contract: the symbol exists with the right signature so
    // downstream wiring lights up. Phase C will replace this with
    // real classifier coverage.
    const fn_ptr: *const @TypeOf(classifyAndNormalize) = &classifyAndNormalize;
    _ = fn_ptr;
}
