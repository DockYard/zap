pub module Test.GuardTest {
  use Zest

  pub fn run() -> String {
    # Guards on function clauses
    assert(classify(5) == "positive")
    assert(classify(-3) == "negative")
    assert(classify(0) == "zero")

    # Guards with multiple conditions
    assert(range_check(5) == "small")
    assert(range_check(50) == "medium")
    assert(range_check(500) == "large")

    "GuardTest: passed"
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
