pub module Test.RecursionTest {
  use Zest

  pub fn run() -> String {
    # Factorial via multi-clause recursion
    assert(factorial(0) == 1)
    assert(factorial(1) == 1)
    assert(factorial(5) == 120)
    assert(factorial(10) == 3628800)

    # Fibonacci via multi-clause recursion
    assert(fib(0) == 0)
    assert(fib(1) == 1)
    assert(fib(6) == 8)

    # Recursive sum
    assert(sum(0) == 0)
    assert(sum(5) == 15)

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
