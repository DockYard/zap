pub module Test.CondTest {
  use Zest

  pub fn run() -> String {
    # Cond with boolean
    assert(check(true) == "yes")
    assert(check(false) == "no")

    # Cond with comparison
    assert(describe(1) == "one")
    assert(describe(2) == "two")
    assert(describe(99) == "other")

    # Cond with many arms
    assert(grade(95) == "A")
    assert(grade(85) == "B")
    assert(grade(75) == "C")
    assert(grade(50) == "F")

    # Nested cond (cond returning values used in comparisons)
    assert(abs_sign(-5) == "negative")
    assert(abs_sign(0) == "zero")
    assert(abs_sign(3) == "positive")

    "CondTest: passed"
  }

  fn check(x :: Bool) -> String {
    cond {
      x -> "yes"
      true -> "no"
    }
  }

  fn describe(x :: i64) -> String {
    cond {
      x == 1 -> "one"
      x == 2 -> "two"
      true -> "other"
    }
  }

  fn grade(score :: i64) -> String {
    cond {
      score >= 90 -> "A"
      score >= 80 -> "B"
      score >= 70 -> "C"
      true -> "F"
    }
  }

  fn abs_sign(x :: i64) -> String {
    cond {
      x < 0 -> "negative"
      x == 0 -> "zero"
      true -> "positive"
    }
  }
}
