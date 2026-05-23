# Phase 4.e acceptance — `assert_no_cycles { <block> }` Zest primitive driven
# directly from a script `main/1` under `-Dmemory=Memory.Tracking`.
#
# `assert_no_cycles` runs a block, drives the runtime Bacon–Rajan trial-deletion
# cycle detector over the allocations the block left live, and asserts none are
# held alive only by a reference cycle.
#
# Phase-5 caveat (see lib/zest/assertion.zap + src/memory/cycle_detector.zig):
# a reference cycle is NOT constructible from today's fully immutable Zap
# surface — every `%Node{next: Some(other)}` requires `other` to already exist,
# so allocations only ever point at strictly-older allocations and the loop can
# never close. So on real Zap code this assertion ALWAYS passes. The
# detect-and-fail path is unit-verified at the runtime level instead (it drives
# a hand-built cyclic ArcHeader graph through the engine and confirms the
# white-set is non-empty — see the `scanLiveCyclesAndReport` / cycle-detector
# host tests). This fixture pins the clean-block PASS behavior on real code,
# including a block that DOES allocate a non-cyclic linked structure.
#
# Expected (under -Dmemory=Memory.Tracking):
#   * "acyclic-empty: PASS"  — a block with no allocation has no cycle
#   * "acyclic-box: PASS"    — a block that heap-allocates an acyclic boxed
#     value (strictly-older-pointing) has no cycle
#   * the Zest summary reports 0 assertion failures.

@code Z9301
pub error Leaf {}

@code Z9302
pub error Branch {}

pub struct Test.AssertNoCycles {
  use Zest.Case

  test("assert_no_cycles") {
    case("empty block has no cycle") {
      assert_no_cycles {
        product = 6 * 7
        assert(product == 42)
      }
    }

    case("block that allocates an acyclic boxed value has no cycle") {
      assert_no_cycles {
        # Allocates a heap box (the auto-injected `cause` of a `pub error`
        # boxed into another), but the reference graph is strictly acyclic:
        # `branch` points at the older `leaf`, never back. No cycle.
        leaf = %Leaf{}
        branch = %Branch{cause: Option.Some(leaf)}
        assert(true)
      }
    }
  }
}

# Detect-and-FAIL path note.
#
# Cycles are not user-constructible from today's immutable Zap (the Phase-5
# caveat), so the runtime detector cannot be driven to find a REAL cycle from a
# `.zap` source. The detect-and-fail path is therefore unit-verified at the
# runtime level instead: `src/memory/cycle_detector.zig` exhaustively tests the
# trial-deletion engine (the 2-node mutual cycle returns a white-set of 2;
# self-cycle, 3-ring, and false-positive controls pin the algorithm), and
# `tools/cycle_detector_drift_test.zig` byte-locks the runtime mirror
# (`scanLiveCyclesAndReport` / `renderCycleReport`) to that reference. The
# assertion's decision polarity (a positive detected-object count fails, zero
# passes) is exercised end-to-end here: the clean blocks above PASS (count == 0)
# and the leaking-block assertion in `phase_4e_assert_no_leaks.zap` proves the
# positive-delta FAIL branch.

fn main(_args :: [String]) -> u8 {
  Test.AssertNoCycles.run()
  failures = :zig.Zest.summary()
  if failures == 0 {
    0
  } else {
    1
  }
}
