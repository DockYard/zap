pub module Test.MultiModuleTest {
  use Zest.Case

  pub fn run() -> String {
    describe("multi module") {
      test("cross-module double function") {
        assert(Test.MultiModuleHelper.double(5) == 10)
      }

      test("cross-module greet function") {
        assert(Test.MultiModuleHelper.greet("Zap") == "Hello, Zap!")
      }
    }

    "MultiModuleTest: passed"
  }
}
