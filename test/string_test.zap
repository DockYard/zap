pub module Test.StringTest {
  use Zest.Case

  describe("strings") {
    test("string concatenation") {
      assert(("Hello" <> ", " <> "world!") == "Hello, world!")
    }

    test("string function greets correctly") {
      assert(greet("World") == "Hello, World!")
    }

    test("String.slice returns substring") {
      assert(String.slice("hello", 0, 3) == "hel")
    }

    test("String.length returns byte count") {
      assert(String.length("hello") == 5)
    }

    test("String.contains checks substring") {
      assert(String.contains("hello world", "world") == true)
    }
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }
}
