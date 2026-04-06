pub module Test.IfElseTest {
  use Zest.Case

  pub fn run() -> String {
    describe("if else") {
      test("if true returns yes") {
        assert(check(true) == "yes")
      }

      test("if false returns no") {
        assert(check(false) == "no")
      }

      test("both true returns both") {
        assert(classify(true, true) == "both")
      }

      test("first true only returns first only") {
        assert(classify(true, false) == "first only")
      }

      test("second true only returns second only") {
        assert(classify(false, true) == "second only")
      }

      test("both false returns neither") {
        assert(classify(false, false) == "neither")
      }
    }

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
