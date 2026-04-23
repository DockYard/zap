pub struct Test.ArithmeticTest {
  use Zest.Case

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

    test("integer division") {
      assert(10 / 3 == 3)
    }

    test("integer division exact") {
      assert(12 / 4 == 3)
    }

    test("integer remainder") {
      assert(10 - 10 / 3 * 3 == 1)
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
