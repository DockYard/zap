pub module Test.StringTest {
  use Zest
  pub fn run() -> String {
    # String concatenation
    assert(("Hello" <> ", " <> "world!") == "Hello, world!")

    # String in function
    assert(greet("World") == "Hello, World!")

    "StringTest: passed"
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
