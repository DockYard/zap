pub module Test.MultiModuleTest {
  use Zest.Case

  pub fn run() -> String {
    describe("multi module") {
      test("cross-module call in comparison") {
        assert(Test.MultiModuleHelper.double(5) == 10)
      }

      test("cross-module call in string comparison") {
        assert(Test.MultiModuleHelper.greet("Zap") == "Hello, Zap!")
      }

      test("stdlib qualified call in comparison") {
        assert(String.length("hello") == 5)
      }
    }

    "MultiModuleTest: passed"
  }
}
