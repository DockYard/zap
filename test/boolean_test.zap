pub struct BooleanTest {
  use Zest.Case

  describe("booleans") {
    test("true equals true") {
      assert(true == true)
    }

    test("false does not equal true") {
      reject(false == true)
    }

    test("false equals false") {
      assert(false == false)
    }

    test("greater than produces true") {
      assert((5 > 3) == true)
    }

    test("less than produces false") {
      assert((3 > 5) == false)
    }

    test("equality produces true") {
      assert((5 == 5) == true)
    }

    test("inequality produces true") {
      assert((5 != 3) == true)
    }

    test("and with both true") {
      assert(true and true)
    }

    test("and with true and false") {
      reject(true and false)
    }

    test("and with false and true") {
      reject(false and true)
    }

    test("or with true and false") {
      assert(true or false)
    }

    test("or with false and true") {
      assert(false or true)
    }

    test("or with both false") {
      reject(false or false)
    }

    test("check_positive with positive number") {
      assert(check_positive(5) == "positive")
    }

    test("check_positive with negative number") {
      assert(check_positive(-3) == "not positive")
    }
  }

  fn check_positive(x :: i64) -> String {
    case x > 0 {
      true -> "positive"
      false -> "not positive"
    }
  }
}
