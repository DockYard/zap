pub module Test.FunctionTest {
  use Zest.Case

  describe("functions") {
    test("multi-clause dispatch matches zero") {
      assert(classify(0) == "zero")
    }

    test("multi-clause dispatch matches one") {
      assert(classify(1) == "one")
    }

    test("multi-clause dispatch falls through to other") {
      assert(classify(42) == "other")
    }

    test("string function greets correctly") {
      assert(greet("World") == "Hello, World!")
    }
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
