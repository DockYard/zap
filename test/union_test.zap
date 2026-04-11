pub module Test.UnionTest {
  use Zest.Case

  pub union Color {
    Red
    Green
    Blue
  }

  describe("unions") {
    test("Red variant name") {
      assert(color_name(Color.Red) == "red")
    }

    test("Green variant name") {
      assert(color_name(Color.Green) == "green")
    }

    test("Blue variant name") {
      assert(color_name(Color.Blue) == "blue")
    }
  }

  fn color_name(Color.Red :: Color) -> String {
    "red"
  }

  fn color_name(Color.Green :: Color) -> String {
    "green"
  }

  fn color_name(Color.Blue :: Color) -> String {
    "blue"
  }
}
