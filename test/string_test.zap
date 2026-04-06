pub module Test.StringTest {
  use Zest.Case

  pub fn run() -> String {
    describe("strings") {
      test("string concatenation") {
        assert(("Hello" <> ", " <> "world!") == "Hello, world!")
      }

      test("string function greets correctly") {
        assert(greet("World") == "Hello, World!")
      }
    }

    "StringTest: passed"
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
