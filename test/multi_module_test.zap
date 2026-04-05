pub module Test.MultiModuleTest {
  use Zest

  pub fn run() -> String {
    # Cross-module function calls
    assert(Test.MultiModuleHelper.double(5) == 10)
    assert(Test.MultiModuleHelper.greet("Zap") == "Hello, Zap!")

    "MultiModuleTest: passed"
  }
}
