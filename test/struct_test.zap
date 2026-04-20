pub struct Point {
  x :: i64
  y :: i64
}


pub module Test.StructTest {
  use Zest.Case

  describe("Struct creation") {
    test("struct created in helper function") {
      result = get_x_from_inline()
      assert(result == 42)
    }

    test("struct created inline in test via helper") {
      result = sum_point(make_point(3, 4))
      assert(result == 7)
    }
  }

  describe("Struct return types") {
    test("function returns a struct") {
      point = make_point(5, 7)
      assert(point.x == 5)
      assert(point.y == 7)
    }

    test("returned struct fields can be used in expressions") {
      point = make_point(3, 4)
      sum = point.x + point.y
      assert(sum == 7)
    }
  }

  describe("Struct as function parameter") {
    test("function accepts struct from another function") {
      point = make_point(3, 4)
      result = sum_point(point)
      assert(result == 7)
    }

    test("struct created and accessed inline") {
      point = make_point(10, 20)
      assert(point.x == 10)
      assert(point.y == 20)
    }
  }

  fn make_point(x_val :: i64, y_val :: i64) -> Point {
    %Point{x: x_val, y: y_val}
  }

  fn sum_point(point :: Point) -> i64 {
    point.x + point.y
  }

  fn get_x_from_inline() -> i64 {
    point = %Point{x: 42, y: 99}
    point.x
  }
}
