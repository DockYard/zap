pub module Test.RecursionTest {
  use Zest.Case

  pub fn run() -> String {
    describe("recursion") {
      test("factorial of 0") {
        assert(factorial(0) == 1)
      }

      test("factorial of 1") {
        assert(factorial(1) == 1)
      }

      test("factorial of 5") {
        assert(factorial(5) == 120)
      }

      test("factorial of 10") {
        assert(factorial(10) == 3628800)
      }

      test("fibonacci of 0") {
        assert(fib(0) == 0)
      }

      test("fibonacci of 1") {
        assert(fib(1) == 1)
      }

      test("fibonacci of 6") {
        assert(fib(6) == 8)
      }

      test("sum of 0") {
        assert(sum(0) == 0)
      }

      test("sum of 5") {
        assert(sum(5) == 15)
      }
    }

    "RecursionTest: passed"
  }

  fn factorial(0 :: i64) -> i64 {
    1
  }

  fn factorial(n :: i64) -> i64 {
    n * factorial(n - 1)
  }

  fn fib(0 :: i64) -> i64 {
    0
  }

  fn fib(1 :: i64) -> i64 {
    1
  }

  fn fib(n :: i64) -> i64 {
    fib(n - 1) + fib(n - 2)
  }

  fn sum(0 :: i64) -> i64 {
    0
  }

  fn sum(n :: i64) -> i64 {
    n + sum(n - 1)
  }
}
