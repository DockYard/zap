pub struct Test.GuardTest {
  use Zest.Case

  describe("guards") {
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
}
