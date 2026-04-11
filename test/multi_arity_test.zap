pub module Test.MultiArityTest {
  use Zest.Case

  describe("multi arity") {
    test("two-argument add") {
      assert(add(1, 2) == 3)
    }

    test("three-argument add") {
      assert(add3(1, 2, 3) == 6)
    }

    test("multi-parameter string join") {
      assert(join("hello", " ", "world") == "hello world")
    }
  }

  fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }

  fn add3(a :: i64, b :: i64, c :: i64) -> i64 {
    a + b + c
  }

  fn join(a :: String, sep :: String, b :: String) -> String {
    a <> sep <> b
  }
}
