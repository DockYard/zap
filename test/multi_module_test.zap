pub module Test.MultiModuleTest {
  use Zest.Case

  pub fn run() -> String {
    # Cross-module qualified calls don't survive macro AST round-trip yet
    assert(Test.MultiModuleHelper.double(5) == 10)
    assert(Test.MultiModuleHelper.greet("Zap") == "Hello, Zap!")
    "MultiModuleTest: passed"
  }
}
