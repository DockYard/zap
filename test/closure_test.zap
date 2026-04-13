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

    test("pass doubler as callback") {
      assert(apply(21, doubler) == 42)
    }

    test("pass add_one as callback") {
      assert(apply(41, add_one) == 42)
    }

    test("apply_twice with callback") {
      assert(apply_twice(10, add_one) == 12)
    }

    test("compose two applies") {
      assert(apply(apply(20, add_one), doubler) == 42)
    }

    test("anonymous function standalone") {
      _f = fn(x) { x * 2 }
      assert(true)
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

  fn apply_twice(value :: i64, callback :: (i64 -> i64)) -> i64 {
    callback(callback(value))
  }
}
