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

  # End-to-end witness for audit finding types-2--02 / TY-04: a logical
  # function's clauses are spread across several single-clause declarations
  # sharing a `<Struct>.<name>/<arity>` key. The type checker's inferred
  # `raises` row for that key must be the UNION of every clause's raised
  # errors. The defect overwrote the row per-clause, so only the LAST clause's
  # row survived. When an EARLY clause could raise but the LAST clause was pure
  # (empty row), the function lowered WITHOUT an error union and the early
  # clause's `raise` took the uncatchable top-level `do_raise` abort path
  # instead of `ret_raise`: an enclosing `try ... rescue` silently failed to
  # catch it and the process aborted. These exercise the rescue surface, which
  # depends on the corrected error-union ABI flowing from the unioned row.
  # (The companion type-soundness finding types-2--03 / TY-05 — preserving the
  # enclosing function's `raises` accumulator across a nested closure check — is
  # witnessed deterministically in `src/types.zig`'s type-checker unit tests.)
  describe("multi-clause function raises union (TY-04)") {
    test("early raising clause stays catchable when the last clause is pure") {
      # The raising clause (0) is declared BEFORE the pure catch-all clause.
      # Pre-fix the pure clause's empty row overwrote AlphaError and
      # `maybe_fail(0)` aborted uncatchably instead of returning through rescue.
      assert(call_maybe_fail(0) == 1)
    }

    test("the pure clause still returns its own value") {
      assert(call_maybe_fail(7) == 7)
    }

    test("every clause of a many-clause function keeps its own error in the union") {
      # classify_raise/1 raises a DIFFERENT concrete error per clause; both
      # must be in the union so both are reachable through rescue.
      assert(call_classify_raise(0) == 1)
      assert(call_classify_raise(1) == 2)
    }

    test("Callable return keying survives mixed raising and pure i64 closures") {
      mapped = Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })

      assert(List.length(mapped) == 3)
      assert(List.head(mapped) == 2)
      assert(List.last(mapped) == 6)
      assert(call_callable_key_collision(2) == 12)
      assert(call_callable_key_collision(0) == -30)
    }
  }

  # End-to-end witnesses for audit finding ir-1--04: the IR builder's
  # raise-effect context flags (`current_function_raises` / `in_try_body`)
  # were clobbered across nested closure/function-group builds and never
  # initialized for typed-clause entrypoints. The unwrap-mode selector
  # (`if in_try_body -> route_to_handler else if current_function_raises ->
  # propagate else abort_unhandled`) consults these flags at every raising
  # call site, so a clobbered/uninitialized flag lowered a recoverable raise
  # as the uncatchable top-level `abort_unhandled` path — an enclosing
  # `try ... rescue` silently failed to catch it and the process aborted.
  describe("raise-effect context across closures and typed clauses (ir-1--04)") {
    test("type-only overload clause that raises stays catchable") {
      # `typed_overload/1` has two clauses dispatched purely by parameter
      # type (i64 vs String); the String clause raises. Pre-fix, the
      # typed-clause entrypoint emitted `Function.raises = false` (it never
      # initialized the flag from the type store), so the raise took the
      # uncatchable abort path instead of returning an error union through
      # this rescue.
      assert(call_typed_overload_string() == 1)
    }

    test("the non-raising type-only overload clause still returns its value") {
      # The i64 clause of the raising overload family returns its value through
      # the (now uniform) error-union ABI; observed via a `try` so the success
      # payload flows out cleanly.
      assert(call_typed_overload_int(42) == 42)
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

  # ---- TY-04 multi-clause raises-union fixtures ----

  # Multi-clause function: the RAISING clause (0) is declared BEFORE the pure
  # catch-all clause. The pure clause must NOT erase the raising clause's
  # AlphaError from the function's inferred `raises` row, or `maybe_fail(0)`
  # would abort uncatchably.
  fn maybe_fail(0 :: i64) -> i64 {
    raise %AlphaError{message: "boom"}
  }

  fn maybe_fail(n :: i64) -> i64 {
    n
  }

  fn call_maybe_fail(n :: i64) -> i64 {
    try { maybe_fail(n) } rescue {
      e :: AlphaError -> 1
    }
  }

  # Two clauses raising two DIFFERENT concrete errors. The union must carry
  # both so each is reachable from the rescue site.
  fn classify_raise(0 :: i64) -> i64 {
    raise %AlphaError{message: "a"}
  }

  fn classify_raise(n :: i64) -> i64 {
    raise %BetaError{message: "b"}
  }

  fn call_classify_raise(n :: i64) -> i64 {
    try { classify_raise(n) } rescue {
      e :: AlphaError -> 1
      e :: BetaError -> 2
    }
  }

  # FU-30 / GAP-P3-03: a multi-clause function whose first clause raises and
  # whose second clause constructs a `fn(i64) -> i64` closure must not collide
  # with other same-signature callbacks when the runtime derives
  # `CallableReturn(@TypeOf(callback))`.
  fn callable_key_collision(0 :: i64) -> i64 {
    raise %AlphaError{message: "fu30"}
  }

  fn callable_key_collision(n :: i64) -> i64 {
    callback = fn(value :: i64) -> i64 { value + n }
    invoke_i64_callback(callback, 10)
  }

  fn invoke_i64_callback(callback :: fn(i64) -> i64, value :: i64) -> i64 {
    callback(value)
  }

  fn call_callable_key_collision(n :: i64) -> i64 {
    try { callable_key_collision(n) } rescue {
      e :: AlphaError -> -30
    }
  }

  # ---- ir-1--04 raise-effect context fixtures ----

  # A type-only overload group: clauses dispatched purely by parameter type
  # (no guards, bind/wildcard patterns, differing types). The String clause
  # raises; its typed-clause entrypoint must lower with the raise effect so
  # the raise is catchable.
  fn typed_overload(value :: i64) -> i64 {
    value
  }

  fn typed_overload(_ :: String) -> i64 {
    raise %AlphaError{message: "typed overload"}
  }

  fn call_typed_overload_string() -> i64 {
    try { typed_overload("boom") } rescue {
      e :: AlphaError -> 1
    }
  }

  fn call_typed_overload_int(n :: i64) -> i64 {
    try { typed_overload(n) } rescue {
      e :: AlphaError -> 0
    }
  }
}
