pub module Test.ClosureTest {
  use Zest.Case

  pub fn run() -> String {
    add_one = fn(x :: i64) -> i64 {
      x + 1
    }

    multiply = fn(x :: i64, y :: i64) -> i64 {
      x * y
    }

    describe("anonymous closures") {
      test("closure call with one arg") {
        assert(add_one(41) == 42)
      }

      test("closure call with two args") {
        assert(multiply(6, 7) == 42)
      }

      test("closure result in arithmetic") {
        assert(add_one(20) + add_one(20) == 42)
      }
    }

    "ClosureTest: passed"
  }
}
