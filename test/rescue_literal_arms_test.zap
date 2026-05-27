## Regression tests for the multi-arm `rescue` bare-literal coercion bug.
##
## A `try`/`rescue` whose arms return bare integer literals (`-> 1`, `-> 2`)
## must coerce each arm's tail to the rescue's concrete result type (here
## `i64`) BEFORE the multi-arm catch-basin branch merge. Without that
## coercion the bare `comptime_int` literals flow across the runtime
## `if`/`condbr` arm-vs-arm merge and Zig rejects them:
## "value with comptime-only type 'comptime_int' depends on runtime
## control flow". Single-arm rescue and typed-expression arms already
## worked; only the multi-arm bare-literal merge was broken.

@code Z7301
pub error AlphaError {}

@code Z7302
pub error BetaError {}

@code Z7303
pub error GammaError {}

pub struct RescueLiteralArmsTest {
  use Zest.Case

  describe("multi-arm rescue with bare literal arms") {
    test("two arms, both bare int literals — matches first") {
      assert(classify_int(0) == 1)
    }

    test("two arms, both bare int literals — matches second") {
      assert(classify_int(1) == 2)
    }

    test("three arms, bare int literals — matches first") {
      assert(classify_three(0) == 10)
    }

    test("three arms, bare int literals — matches middle") {
      assert(classify_three(1) == 20)
    }

    test("three arms, bare int literals — matches last") {
      assert(classify_three(2) == 30)
    }

    test("mixed: one bare-literal arm, one typed-expression arm — literal arm") {
      assert(classify_mixed(0) == 7)
    }

    test("mixed: one bare-literal arm, one typed-expression arm — typed arm") {
      assert(classify_mixed(1) == compute_typed())
    }

    test("try body is a bare literal + arms bare literals — body wins (no raise)") {
      assert(body_literal_no_raise() == 99)
    }

    test("try body is a bare literal + arms bare literals — arm wins (raise)") {
      assert(body_literal_with_raise() == 5)
    }

    test("string-literal arms still work (non-numeric peer, no regression)") {
      assert(classify_string(0) == "alpha")
    }

    test("string-literal arms still work — second arm") {
      assert(classify_string(1) == "beta")
    }
  }

  # Raises one of two/three concrete error types selected at runtime, so
  # the rescue arms exercise genuine runtime type discrimination (not a
  # first-arm-always shortcut).
  fn risky_pair(n :: i64) -> i64 {
    if n == 0 { raise %AlphaError{message: "a"} } else { raise %BetaError{message: "b"} }
  }

  fn risky_triple(n :: i64) -> i64 {
    if n == 0 {
      raise %AlphaError{message: "a"}
    } else {
      if n == 1 { raise %BetaError{message: "b"} } else { raise %GammaError{message: "g"} }
    }
  }

  # A String-returning raising helper so the String-arm regression guard
  # has a String body tail (clean String peer, not an i64/String conflict).
  fn risky_pair_string(n :: i64) -> String {
    if n == 0 { raise %AlphaError{message: "a"} } else { raise %BetaError{message: "b"} }
  }

  # Two arms, both bare integer literals — the reported repro shape.
  fn classify_int(n :: i64) -> i64 {
    try { risky_pair(n) } rescue {
      e :: AlphaError -> 1
      e :: BetaError -> 2
    }
  }

  # Three arms, all bare integer literals.
  fn classify_three(n :: i64) -> i64 {
    try { risky_triple(n) } rescue {
      e :: AlphaError -> 10
      e :: BetaError -> 20
      e :: GammaError -> 30
    }
  }

  # Mixed: a bare-literal arm and a typed-expression arm. Both must peer
  # to i64 across the branch merge.
  fn classify_mixed(n :: i64) -> i64 {
    try { risky_pair(n) } rescue {
      e :: AlphaError -> 7
      e :: BetaError -> compute_typed()
    }
  }

  fn compute_typed() -> i64 {
    3 + 4
  }

  # The try BODY itself is a bare integer literal (no raise): the body's
  # value flows out, but the arms are also bare literals.
  fn body_literal_no_raise() -> i64 {
    try { 99 } rescue {
      e :: AlphaError -> 1
      e :: BetaError -> 2
    }
  }

  # The try body raises so an arm value is observed; arms are bare literals.
  fn body_literal_with_raise() -> i64 {
    try { raise_then_literal() } rescue {
      e :: AlphaError -> 5
      e :: BetaError -> 6
    }
  }

  fn raise_then_literal() -> i64 {
    raise %AlphaError{message: "boom"}
  }

  # Non-numeric peer regression guard: String-literal arms.
  fn classify_string(n :: i64) -> String {
    try { risky_pair_string(n) } rescue {
      e :: AlphaError -> "alpha"
      e :: BetaError -> "beta"
    }
  }
}
