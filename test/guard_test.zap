pub struct GuardTest {
  use Zest.Case

  describe("basic guards") {
    test("positive number classified as positive") {
      assert(classify(5) == "positive")
    }

    test("negative number classified as negative") {
      assert(classify(-3) == "negative")
    }

    test("zero classified as zero") {
      assert(classify(0) == "zero")
    }

    test("small range check") {
      assert(range_check(5) == "small")
    }

    test("medium range check") {
      assert(range_check(50) == "medium")
    }

    test("large range check") {
      assert(range_check(500) == "large")
    }
  }

  fn classify(n :: i64) -> String if n > 0 {
    "positive"
  }

  fn classify(n :: i64) -> String if n < 0 {
    "negative"
  }

  fn classify(_ :: i64) -> String {
    "zero"
  }

  fn range_check(n :: i64) -> String if n < 10 {
    "small"
  }

  fn range_check(n :: i64) -> String if n < 100 {
    "medium"
  }

  fn range_check(_ :: i64) -> String {
    "large"
  }

  describe("multi-line guards") {
    test("multi-line and guard matches") {
      assert(both_positive(3, 5) == "both positive")
    }

    test("multi-line and guard falls through") {
      assert(both_positive(-1, 5) == "not both")
    }

    test("multi-line or guard first branch") {
      assert(either_big(200, 1) == "at least one big")
    }

    test("multi-line or guard second branch") {
      assert(either_big(1, 200) == "at least one big")
    }

    test("multi-line or guard falls through") {
      assert(either_big(1, 2) == "both small")
    }
  }

  describe("multi-clause dispatch fast paths honor guards and multi-literal patterns (ir-1--05)") {
    # Regression for audit finding ir-1--05: the integer-literal switch_return
    # fast path picked the LAST literal param as the sole scrutinee and never
    # checked earlier literal params, so a clause that should match on BOTH
    # params was taken on the strength of the second alone.
    test("two-literal-param clause requires BOTH params to match") {
      # `combo(9, 1)` must NOT match `combo(0, 1)`; only the second param is 1,
      # the first is 9. Pre-fix the dispatch switched only on param 1, so this
      # returned 10 (the [0,1] clause) instead of falling through to 30.
      assert(combo(9, 1) == 30)
    }

    test("two-literal-param clause matches when both params match (first clause)") {
      assert(combo(0, 1) == 10)
    }

    test("two-literal-param clause matches when both params match (second clause)") {
      assert(combo(2, 3) == 20)
    }

    test("a non-matching second param also falls through to the catch-all") {
      assert(combo(0, 9) == 30)
    }

    # Guard on the LAST clause of an otherwise switch-eligible group: pre-fix
    # the guard was DROPPED, so a value failing it silently took that clause.
    # With the guard honored, the literal-match and guard-satisfied paths
    # select the right clause; an input that matches neither correctly raises a
    # match error (an abort, not a catchable raise — see the Zig unit test
    # `canSwitchDispatch bails for a guarded last clause` for the bail itself).
    test("guard on the last switch clause is honored when satisfied") {
      assert(guarded_tail(200) == 2)
    }

    test("guard on the last switch clause still matches the leading literal") {
      assert(guarded_tail(0) == 1)
    }
  }

  # Two-literal-param clauses: the dispatch must check BOTH params, not just
  # the last one.
  fn combo(0 :: i64, 1 :: i64) -> i64 {
    10
  }

  fn combo(2 :: i64, 3 :: i64) -> i64 {
    20
  }

  fn combo(_ :: i64, _ :: i64) -> i64 {
    30
  }

  # A literal clause followed by a GUARDED last clause (no plain catch-all).
  # `guarded_tail(5)` matches neither and correctly raises a match error.
  fn guarded_tail(0 :: i64) -> i64 {
    1
  }

  fn guarded_tail(n :: i64) -> i64 if n > 100 {
    2
  }

  fn both_positive(a :: i64, b :: i64) -> String
    if a > 0
    and b > 0 {
    "both positive"
  }

  fn both_positive(_ :: i64, _ :: i64) -> String {
    "not both"
  }

  fn either_big(a :: i64, b :: i64) -> String
    if a > 100
    or b > 100 {
    "at least one big"
  }

  fn either_big(_ :: i64, _ :: i64) -> String {
    "both small"
  }

  describe("not operator in guards") {
    test("not negates condition") {
      assert(not_positive(-5) == "not positive")
    }

    test("not with positive falls through") {
      assert(not_positive(5) == "positive")
    }

    test("not with and") {
      assert(neither_big(1, 2) == "neither big")
    }

    test("not with and falls through") {
      assert(neither_big(200, 1) == "at least one big")
    }
  }

  fn not_positive(n :: i64) -> String if not (n > 0) {
    "not positive"
  }

  fn not_positive(_ :: i64) -> String {
    "positive"
  }

  fn neither_big(a :: i64, b :: i64) -> String
    if not (a > 100)
    and not (b > 100) {
    "neither big"
  }

  fn neither_big(_ :: i64, _ :: i64) -> String {
    "at least one big"
  }

  describe("in operator") {
    test("value in list is true") {
      assert(is_primary(2) == true)
    }

    test("value not in list is false") {
      assert(is_primary(4) == false)
    }

    test("in operator in guard") {
      assert(classify_day(1) == "weekday")
    }

    test("in operator guard fallthrough") {
      assert(classify_day(7) == "other")
    }

    test("not in operator in guard") {
      assert(classify_non_primary(4) == "other")
    }

    test("not in operator guard fallthrough") {
      assert(classify_non_primary(2) == "primary")
    }
  }

  fn is_primary(n :: i64) -> Bool {
    n in [1, 2, 3]
  }

  fn classify_day(n :: i64) -> String if n in [1, 2, 3, 4, 5] {
    "weekday"
  }

  fn classify_day(_ :: i64) -> String {
    "other"
  }

  fn classify_non_primary(n :: i64) -> String if n not in [1, 2, 3] {
    "other"
  }

  fn classify_non_primary(_ :: i64) -> String {
    "primary"
  }

  describe("type check functions") {
    test("is_integer? with integer") {
      assert(check_is_integer(42) == true)
    }

    test("is_float? with float") {
      assert(check_is_float(3.14) == true)
    }

    test("is_number? with integer") {
      assert(check_is_number_int(42) == true)
    }

    test("is_number? with float") {
      assert(check_is_number_float(3.14) == true)
    }

    test("is_boolean? with bool") {
      assert(check_is_boolean(true) == true)
    }

    test("is_string? with string") {
      assert(check_is_string("hello") == true)
    }

    test("is_atom? with atom") {
      assert(check_is_atom(:hello) == true)
    }

    test("is_nil? with nil") {
      assert(check_is_nil(nil) == true)
    }
  }

  fn check_is_integer(value :: i64) -> Bool {
    is_integer?(value)
  }

  fn check_is_float(value :: f64) -> Bool {
    is_float?(value)
  }

  fn check_is_number_int(value :: i64) -> Bool {
    is_number?(value)
  }

  fn check_is_number_float(value :: f64) -> Bool {
    is_number?(value)
  }

  fn check_is_boolean(value :: Bool) -> Bool {
    is_boolean?(value)
  }

  fn check_is_string(value :: String) -> Bool {
    is_string?(value)
  }

  fn check_is_atom(value :: Atom) -> Bool {
    is_atom?(value)
  }

  fn check_is_nil(value :: Nil) -> Bool {
    is_nil?(value)
  }

  describe("function calls in guards") {
    test("local function in guard") {
      assert(guard_with_local_fn(5) == "positive")
    }

    test("local function in guard fallthrough") {
      assert(guard_with_local_fn(-1) == "other")
    }

    test("is_integer? in guard") {
      assert(guard_with_is_integer(42) == "it is an integer")
    }

    test("String.length in guard") {
      assert(classify_str("hello") == "non-empty")
    }

    test("String.length guard fallthrough") {
      assert(classify_str("") == "empty")
    }
  }

  fn is_pos(n :: i64) -> Bool {
    n > 0
  }

  fn guard_with_local_fn(n :: i64) -> String if is_pos(n) {
    "positive"
  }

  fn guard_with_local_fn(_ :: i64) -> String {
    "other"
  }

  fn guard_with_is_integer(n :: i64) -> String if is_integer?(n) {
    "it is an integer"
  }

  fn guard_with_is_integer(_ :: i64) -> String {
    "unknown"
  }

  fn classify_str(s :: String) -> String if String.length(s) > 0 {
    "non-empty"
  }

  fn classify_str(_ :: String) -> String {
    "empty"
  }
}
