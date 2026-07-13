## Regression tests for the `switch_literal` fast-path diverging-arm bug.
##
## A `case`/`if` whose arms are homogeneous integer/bool literals lowers
## through the `switch_literal` fast path (`lowerCaseExprBody`). An arm whose
## body ends in a cross-function propagating `raise` (lowered to the
## operand-less `ret_raise` terminator) yields NO value to the branch merge —
## but the fast path recorded the raise expression's dest local as the arm's
## `result`. That local is a phantom: no instruction ever assigns it (the
## `.ret_raise` lowering emits only the side-channel stash call, which has its
## own dest, plus the terminator). ZIR emission then failed hard resolving it:
## "ZIR emit failed resolving switch_literal case result local N".
##
## The fix records `result = null` for an arm/default whose lowered body ends
## in an unconditional noreturn terminator, matching the IR convention the
## Phase E.7 tail-call rewriter established (diverging arm => `result == null`,
## which the ZIR emitter resolves to `unreachable_value` at the merge).
##
## Companion coverage: `rescue_literal_arms_test.zap` pins the `if` (bool
## switch) both-branches-raise shape via `risky_pair`/`risky_triple`, and
## `pub_error_test.zap` pins the one-branch-raises shape via `risky_double`.
## This file pins the two remaining seams: an INT-literal case arm that
## raises beside a value-yielding wildcard default (per-case `result`), and a
## raising wildcard DEFAULT beside value-yielding literal arms
## (`default_result`).

@code Z9801
pub error SwitchArmError {}

@code Z9802
pub error SwitchDefaultError {}

pub struct CaseLiteralRaiseArmsTest {
  use Zest.Case

  describe("int-literal switch arms that raise") {
    test("literal arm raises — rescued value flows out") {
      assert(pick_or_rescue(0) == -1)
    }

    test("literal arm raises — value default still yields") {
      assert(pick_or_rescue(7) == 7)
    }

    test("wildcard default raises — literal arms still yield") {
      assert(named_or_rescue(0) == 100)
      assert(named_or_rescue(1) == 200)
    }

    test("wildcard default raises — rescued value flows out") {
      assert(named_or_rescue(9) == -1)
    }
  }

  # Typed helper so the value arms carry a concrete i64 (not a bare
  # comptime literal) across the runtime branch merge.
  fn value_for(n :: i64) -> i64 {
    n * 100
  }

  # Int-literal arm raises (propagating `ret_raise`); the wildcard default
  # yields a value. Exercises the per-case `result` nulling.
  fn risky_pick(n :: i64) -> i64 {
    case n {
      0 -> raise %SwitchArmError{message: "zero"}
      _ -> n
    }
  }

  fn pick_or_rescue(n :: i64) -> i64 {
    try { risky_pick(n) } rescue {
      e :: SwitchArmError -> -1
    }
  }

  # Wildcard DEFAULT raises (propagating `ret_raise`); the int-literal arms
  # yield values. Exercises the `default_result` nulling.
  fn risky_named(n :: i64) -> i64 {
    case n {
      0 -> value_for(1)
      1 -> value_for(2)
      _ -> raise %SwitchDefaultError{message: "other"}
    }
  }

  fn named_or_rescue(n :: i64) -> i64 {
    try { risky_named(n) } rescue {
      e :: SwitchDefaultError -> -1
    }
  }
}
