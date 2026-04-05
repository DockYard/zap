pub module Test.ImportTest {
  use Zest
  import Test.MultiModuleHelper

  pub fn run() -> String {
    # Imported functions can be called without module prefix
    assert(double(3) == 6)
    assert(greet("World") == "Hello, World!")

    "ImportTest: passed"
  }
}
