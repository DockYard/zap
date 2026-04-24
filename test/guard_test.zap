pub struct Test.GuardTest {
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
