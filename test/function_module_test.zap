pub module Test.FunctionModuleTest {
  use Zest.Case

  pub fn run() -> String {
    describe("Function module") {
      test("identity returns the input value") {
        assert(Function.identity(42) == 42)
      }

      test("identity preserves string expressions") {
        assert(Function.identity("zap") == "zap")
      }
    }
  }

}
