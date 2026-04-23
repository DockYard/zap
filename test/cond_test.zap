pub struct Test.CondTest {
  use Zest.Case

  describe("cond") {
    test("boolean true returns yes") {
      assert(check(true) == "yes")
    }

    test("boolean false returns no") {
      assert(check(false) == "no")
    }

    test("comparison matches one") {
      assert(classify(1) == "one")
    }

    test("comparison matches two") {
      assert(classify(2) == "two")
    }

    test("comparison falls through to other") {
      assert(classify(99) == "other")
    }

    test("grade A for 95") {
      assert(grade(95) == "A")
    }

    test("grade B for 85") {
      assert(grade(85) == "B")
    }

    test("grade C for 75") {
      assert(grade(75) == "C")
    }

    test("grade F for 50") {
      assert(grade(50) == "F")
    }

    test("abs_sign negative") {
      assert(abs_sign(-5) == "negative")
    }

    test("abs_sign zero") {
      assert(abs_sign(0) == "zero")
    }

    test("abs_sign positive") {
      assert(abs_sign(3) == "positive")
    }
  }

  fn check(x :: Bool) -> String {
    cond {
      x -> "yes"
      true -> "no"
    }
  }

  fn classify(x :: i64) -> String {
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
