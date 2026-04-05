pub module Test.ArithmeticTest {
  use Zest

  pub fn run() -> String {
    # Basic arithmetic
    assert(2 + 3 == 5)
    assert(10 - 4 == 6)
    assert(3 * 7 == 21)

    # Functions with arithmetic
    assert(add(3, 4) == 7)
    assert(square(5) == 25)
    assert(cube(3) == 27)

    "ArithmeticTest: passed"
  }

  fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }

  fn square(x :: i64) -> i64 {
    x * x
  }

  fn cube(x :: i64) -> i64 {
    x * x * x
  }
}
