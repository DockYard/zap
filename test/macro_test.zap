pub module Test.MacroTest {
  use Zest.Case

  describe("macros") {
    test("if true returns yes") {
      assert(if_true() == "yes")
    }

    test("if false returns no") {
      assert(if_false() == "no")
    }
  }

  fn if_true() -> String {
    case true {
      true -> "yes"
      false -> "no"
    }
  }

  fn if_false() -> String {
    case false {
      true -> "yes"
      false -> "no"
    }
  }
}
