pub module Test.IfElseTest {
  use Zest

  pub fn run() -> String {
    # If-else as expression
    assert(check(true) == "yes")
    assert(check(false) == "no")

    # Nested if-else
    assert(classify(true, true) == "both")
    assert(classify(true, false) == "first only")
    assert(classify(false, true) == "second only")
    assert(classify(false, false) == "neither")

    "IfElseTest: passed"
  }

  fn check(x :: Bool) -> String {
    if x {
      "yes"
    } else {
      "no"
    }
  }

  fn classify(a :: Bool, b :: Bool) -> String {
    if a {
      if b {
        "both"
      } else {
        "first only"
      }
    } else {
      if b {
        "second only"
      } else {
        "neither"
      }
    }
  }
}
