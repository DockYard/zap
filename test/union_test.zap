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

  describe("Lists of enums") {
    test("list of colors length") {
      assert(color_list_length() == 3)
    }
  }

  fn color_list_length() -> i64 {
    colors = [Color.Red, Color.Green, Color.Blue]
    List.length(colors)
  }

  describe("Maps of enums") {
    test("map with enum values size") {
      assert(color_map_size() == 2)
    }
  }

  fn color_map_size() -> i64 {
    favorites = %{first: Color.Red, second: Color.Blue}
    Map.size(favorites)
  }

}
