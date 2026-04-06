pub module Test.ImportTest {
  use Zest.Case
  import Test.MultiModuleHelper

  pub fn run() -> String {
    describe("imports") {
      test("imported double function works") {
        assert(double(3) == 6)
      }

      test("imported greet function works") {
        assert(greet("World") == "Hello, World!")
      }
    }

    "ImportTest: passed"
  }
}
