pub module Test.StringTest {
  use Zest.Case

  describe("strings") {
    test("string concatenation") {
      assert(("Hello" <> ", " <> "world!") == "Hello, world!")
    }

    test("string function greets correctly") {
      assert(greet("World") == "Hello, World!")
    }
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
