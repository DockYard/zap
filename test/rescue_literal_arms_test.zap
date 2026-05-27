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

    test("differing-but-peer-coercible numeric arms — i32-typed arm widens to i64") {
      assert(classify_widen(0) == 7)
    }

    test("differing-but-peer-coercible numeric arms — bare-literal sibling arm") {
      assert(classify_widen(1) == 99)
    }

    test("after block runs and the rescued bare-literal value is returned") {
      assert(after_with_literal_arms(0) == 1)
    }

    test("nested rescue — inner bare-literal arms, outer bare-literal arms") {
      assert(nested_literal_rescue(0) == 100)
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

  # An i32-returning helper so one rescue arm has a narrower-but-peer-
  # coercible numeric type than the i64 body/result. The arm's i32 value
  # must widen to the i64 join via the same `@as` coercion as a literal.
  fn small_i32() -> i32 {
    7
  }

  # Differing-but-peer-coercible numeric arms: arm A yields i32 (widened),
  # arm B yields a bare literal. The whole rescue result is i64 (body type).
  fn classify_widen(n :: i64) -> i64 {
    try { risky_pair(n) } rescue {
      e :: AlphaError -> small_i32()
      e :: BetaError -> 99
    }
  }

  # `after` (finally) block present alongside bare-literal arms: the
  # cleanup runs on the value-yielding rescue fall-through, and the
  # coerced literal arm value is still what flows out.
  fn after_with_literal_arms(n :: i64) -> i64 {
    try { risky_pair(n) } rescue {
      e :: AlphaError -> 1
      e :: BetaError -> 2
    } after {
      IO.puts("cleanup ran")
    }
  }

  # Nested `try`/`rescue`: the inner rescue has bare-literal arms and is
  # the tail of the outer try body; the outer rescue also has bare-literal
  # arms. Both merges must concretize their literals. The inner rescues
  # AlphaError -> 100, so no error escapes to the outer rescue.
  fn nested_literal_rescue(n :: i64) -> i64 {
    try {
      try { risky_pair(n) } rescue {
        e :: AlphaError -> 100
        e :: BetaError -> 200
      }
    } rescue {
      e :: AlphaError -> 1
      e :: BetaError -> 2
    }
  }
}
