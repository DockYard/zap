pub struct Zap.ArithmeticTest {
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

    test("exact numeric overload beats widening fallback") {
      assert(classify_exact(1 :: i32) == "i32")
      assert(classify_exact(1 :: u32) == "u32")
      assert(classify_exact(1) == "i64")
    }

    test("numeric widening is fallback after exact overload search") {
      assert(classify_widening(1 :: i32) == "i64")
      assert(classify_widening(1 :: u32) == "u64")
      assert(classify_widening(1.5 :: f32) == "f64")
    }

    test("128-bit integers and extended floats resolve within their families") {
      assert(classify_extended(1 :: i64) == "i128")
      assert(classify_extended(1 :: u64) == "u128")
      assert(classify_extended(1.5 :: f64) == "f80")
      assert(classify_extended(2.5 :: f128) == "f128")
    }
  }

  describe("float arithmetic") {
    test("float addition") {
      assert(1.5 + 2.5 == 4.0)
    }

    test("float subtraction") {
      assert(5.0 - 0.25 == 4.75)
    }

    test("float multiplication") {
      assert(2.0 * 1.5 == 3.0)
    }

    test("float comparison") {
      assert(1.5 < 2.0)
      assert(2.0 > 1.5)
      reject(2.0 < 1.0)
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

  fn classify_exact(value :: i64) -> String {
    "i64"
  }

  fn classify_exact(value :: i32) -> String {
    "i32"
  }

  fn classify_exact(value :: u32) -> String {
    "u32"
  }

  fn classify_widening(value :: i64) -> String {
    "i64"
  }

  fn classify_widening(value :: u64) -> String {
    "u64"
  }

  fn classify_widening(value :: f64) -> String {
    "f64"
  }

  fn classify_extended(value :: i128) -> String {
    "i128"
  }

  fn classify_extended(value :: u128) -> String {
    "u128"
  }

  fn classify_extended(value :: f80) -> String {
    "f80"
  }

  fn classify_extended(value :: f128) -> String {
    "f128"
  }
}
