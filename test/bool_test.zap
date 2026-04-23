pub struct Test.BoolTest {
  use Zest.Case

  describe("Bool struct") {
    test("to_string true") {
      assert(Bool.to_string(true) == "true")
    }

    test("to_string false") {
      assert(Bool.to_string(false) == "false")
    }

    test("negate true") {
      reject(Bool.negate(true))
    }

    test("negate false") {
      assert(Bool.negate(false))
    }

    test("double negate") {
      assert(Bool.negate(Bool.negate(true)))
    }
  }
}
