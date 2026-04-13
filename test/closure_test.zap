pub module Test.ClosureTest {
  use Zest.Case

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

    test("pass named function as callback") {
      assert(apply(21, doubler) == 42)
    }
  }

  fn add_one(x :: i64) -> i64 {
    x + 1
  }

  fn doubler(x :: i64) -> i64 {
    x * 2
  }

  fn multiply(x :: i64, y :: i64) -> i64 {
    x * y
  }

  fn apply(value :: i64, callback :: (i64 -> i64)) -> i64 {
    callback(value)
  }
}
