pub struct Point {
  x :: i64
  y :: i64
}

pub struct Config {
  name :: String
  count :: i64 = 0
  enabled :: Bool = true
}

pub struct Shape {
  sides :: i64
}

pub struct Rectangle extends Shape {
  width :: i64
  height :: i64
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

    test("struct created directly in test body") {
      point = %Point{x: 99, y: 88}
      assert(point.x == 99)
      assert(point.y == 88)
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

  describe("Struct pattern matching") {
    test("destructure struct in function parameter") {
      point = make_point(8, 13)
      result = extract_x(point)
      assert(result == 8)
    }

    test("destructure multiple fields") {
      point = make_point(5, 12)
      result = add_fields(point)
      assert(result == 17)
    }
  }

  fn extract_x(%{x: x_val} :: Point) -> i64 {
    x_val
  }

  fn add_fields(%{x: x_val, y: y_val} :: Point) -> i64 {
    x_val + y_val
  }

  describe("Struct field defaults") {
    test("uses default value when field omitted") {
      config = make_config("test")
      assert(config.count == 0)
      assert(config.enabled == true)
    }

    test("overrides default when field provided") {
      config = make_config_full("prod", 5, false)
      assert(config.count == 5)
      assert(config.enabled == false)
    }
  }

  fn make_config(config_name :: String) -> Config {
    %Config{name: config_name}
  }

  fn make_config_full(config_name :: String, config_count :: i64, is_enabled :: Bool) -> Config {
    %Config{name: config_name, count: config_count, enabled: is_enabled}
  }

  describe("Struct update syntax") {
    test("updates a single field") {
      original = make_point(3, 4)
      updated = update_x(original, 10)
      assert(updated.x == 10)
      assert(updated.y == 4)
    }

    test("updates multiple fields") {
      original = make_point(1, 2)
      updated = update_both(original, 10, 20)
      assert(updated.x == 10)
      assert(updated.y == 20)
    }

    test("original is unchanged after update") {
      original = make_point(5, 6)
      _updated = update_x(original, 99)
      assert(original.x == 5)
    }
  }

  fn update_x(point :: Point, new_x :: i64) -> Point {
    %Point{point | x: new_x}
  }

  fn update_both(point :: Point, new_x :: i64, new_y :: i64) -> Point {
    %Point{point | x: new_x, y: new_y}
  }

  describe("Struct inheritance") {
    test("child struct has parent fields") {
      rect = make_rectangle(4, 10, 5)
      assert(rect.sides == 4)
      assert(rect.width == 10)
      assert(rect.height == 5)
    }

    test("child struct update via function") {
      rect = make_rectangle(4, 10, 5)
      wider = widen_rectangle(rect, 20)
      assert(wider.sides == 4)
      assert(wider.width == 20)
      assert(wider.height == 5)
    }

    test("child struct update inline in test") {
      rect = make_rectangle(4, 10, 5)
      wider = %Rectangle{rect | width: 20}
      assert(wider.width == 20)
      assert(wider.sides == 4)
    }
  }

  fn widen_rectangle(rect :: Rectangle, new_width :: i64) -> Rectangle {
    %Rectangle{rect | width: new_width}
  }

  fn make_rectangle(num_sides :: i64, rect_width :: i64, rect_height :: i64) -> Rectangle {
    %Rectangle{sides: num_sides, width: rect_width, height: rect_height}
  }

  fn get_x_from_inline() -> i64 {
    point = %Point{x: 42, y: 99}
    point.x
  }

  fn get_x_from_inline() -> i64 {
    point = %Point{x: 42, y: 99}
    point.x
  }

  describe("Lists of structs") {
    test("list of points length") {
      assert(point_list_length() == 2)
    }

    test("head of point list") {
      assert(first_point_x() == 1)
    }

    test("last of point list") {
      assert(last_point_y() == 4)
    }
  }

  fn point_list_length() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    List.length(points)
  }

  fn first_point_x() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    first = List.head(points)
    first.x
  }

  fn last_point_y() -> i64 {
    points = [%Point{x: 1, y: 2}, %Point{x: 3, y: 4}]
    last = List.last(points)
    last.y
  }
}
