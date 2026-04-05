pub module Test.UnionTest {
  use Zest

  pub union Color {
    Red
    Green
    Blue
  }

  pub fn run() -> String {
    # Unit variant enum
    assert(color_name(Color.Red) == "red")
    assert(color_name(Color.Green) == "green")
    assert(color_name(Color.Blue) == "blue")

    "UnionTest: passed"
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
