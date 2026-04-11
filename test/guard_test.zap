pub module Test.GuardTest {
  use Zest.Case

  pub fn run() -> String {
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
}
