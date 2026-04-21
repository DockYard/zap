pub module Test.ClosureTest {
  use Zest.Case

  describe("closures") {
    test("apply doubles value") {
      assert(apply(21, doubler) == 42)
    }

    test("apply with add_one") {
      assert(apply(41, add_one) == 42)
    }

    test("apply_twice") {
      assert(apply_twice(10, add_one) == 12)
    }

    test("apply_twice with doubler") {
      assert(apply_twice(10, doubler) == 40)
    }

    test("chain via apply") {
      assert(apply(apply(20, add_one), doubler) == 42)
    }

    test("anonymous function as callback") {
      assert(apply(21, fn(x :: i64) -> i64 { x * 2 }) == 42)
    }

    test("anonymous function addition") {
      assert(apply(40, fn(x :: i64) -> i64 { x + 2 }) == 42)
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

  fn test_anon_fn() -> i64 {
    apply(21, fn(x :: i64) -> i64 { x * 2 })
  }

  describe("IO.mode/2 callback") {
    test("mode with callback returns result") {
      assert(mode_test() == 42)
    }
  }

  fn mode_test() -> i64 {
    IO.mode(0, fn() -> i64 { 42 })
  }
}
