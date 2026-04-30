pub struct OperatorNameTest {
  use Zest.Case

  describe("operator-named functions") {
    test("user pub fn <> shadows the Kernel macro") {
      # Our user-defined <> reverses operands; if the Kernel macro had won
      # the result would be "hello world".
      result = "hello " <> "world"
      assert(result == "worldhello ")
    }

    test("chained <> all dispatch through user fn") {
      # ("a" <> "b") <> "c" with reversed-operand <> => "ba" <> "c" => "cba"
      result = "a" <> "b" <> "c"
      assert(result == "cba")
    }
  }

  pub fn <>(left :: String, right :: String) -> String {
    :zig.String.concat(right, left)
  }
}
