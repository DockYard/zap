pub module Test.ArithmeticTest {
  use Zest.Case

  pub fn run() -> String {
    describe("arithmetic") {
      test("addition") {
        assert(2 + 3 == 5)
      }

      test("subtraction") {
        assert(10 - 4 == 6)
      }

      test("multiplication") {
        assert(3 * 7 == 21)
      }

      test("add function") {
        assert(add(3, 4) == 7)
      }

      test("square function") {
        assert(square(5) == 25)
      }

      test("cube function") {
        assert(cube(3) == 27)
      }
    }
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
