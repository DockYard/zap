pub module Test.ClosureTest {
  use Zest.Case

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn multiply(x :: i64, y :: i64) -> i64 {
    x * y
  }

  describe("closures and functions") {
    test("function call with one arg") {
      assert(add_one(41) == 42)
    }

    test("function call with two args") {
      assert(multiply(6, 7) == 42)
    }

    test("function result in arithmetic") {
      assert(add_one(20) + add_one(20) == 42)
    }
  }
}
