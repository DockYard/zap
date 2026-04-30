pub struct Zap.FunctionStructTest {
  use Zest.Case

  describe("Function struct") {
    test("identity returns the input value") {
      assert(Function.identity(42) == 42)
    }

    test("identity preserves string expressions") {
      assert(Function.identity("zap") == "zap")
    }
  }
}
