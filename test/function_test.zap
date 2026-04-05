pub module Test.FunctionTest {
  use Zest
  pub fn run() -> String {
    # Multi-clause dispatch
    assert(classify(0) == "zero")
    assert(classify(1) == "one")
    assert(classify(42) == "other")

    # String function
    assert(greet("World") == "Hello, World!")

    "FunctionTest: passed"
  }

  fn classify(0 :: i64) -> String {
    "zero"
  }

  fn classify(1 :: i64) -> String {
    "one"
  }

  fn classify(_ :: i64) -> String {
    "other"
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
