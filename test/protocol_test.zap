pub struct Point {
  x :: i64
  y :: i64
}

pub struct ProtocolTest {
  use Zest.Case

  describe("Map enumeration") {
    test("sum map values via reduce") {
      total = sum_map_values(%{a: 10, b: 20, c: 30})
      assert(total == 60)
    }
  }

  fn sum_map_values(map :: %{Atom => i64}) -> i64 {
    Enum.reduce_map(map, 0, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value })
  }

  describe("Closures with Enum functions") {
    test("capturing closure with Enum.reduce") {
      multiplier = 3
      result = Enum.reduce([1, 2, 3], 0, fn(accumulator :: i64, element :: i64) -> i64 { accumulator + element * multiplier })
      assert(result == 18)
    }

    test("capturing closure with Enum.map") {
      offset = 10
      result = Enum.map([1, 2, 3], fn(element :: i64) -> i64 { element + offset })
      assert(List.at(result, 0) == 11)
      assert(List.at(result, 1) == 12)
      assert(List.at(result, 2) == 13)
    }

    test("capturing closure with Enum.filter") {
      threshold = 2
      result = Enum.filter([1, 2, 3, 4], fn(element :: i64) -> Bool { element > threshold })
      assert(List.length(result) == 2)
    }

    test("capturing closure with Enum.count") {
      min_val = 3
      result = Enum.count([1, 2, 3, 4, 5], fn(element :: i64) -> Bool { element >= min_val })
      assert(result == 3)
    }
  }

  describe("Protocol dispatch via Enum") {
    test("Enum.each iterates list for side effects") {
      Enum.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(true)
    }
  }

  describe("Capturing closures") {
    test("closure captures local variable") {
      multiplier = 3
      result = apply_fn(7, fn(x :: i64) -> i64 { x * multiplier })
      assert(result == 21)
    }
  }

  describe("Struct return types") {
    test("function creates and returns a struct") {
      point = make_point(3, 4)
      assert(point.x == 3)
      assert(point.y == 4)
    }
  }

  describe("Tuple return types") {
    test("function returns a tuple and passes to another function") {
      result = extract_first(make_pair(5))
      assert(result == 5)
    }

    test("function returns a tuple and passes second element") {
      result = extract_second(make_pair(7))
      assert(result == 1)
    }

    test("case matching on returned tuple") {
      pair = make_pair(10)
      value = extract_first(pair)
      assert(value == 10)
    }

    test("function returns tuple with string element") {
      result = wrap_message("hello")
      assert(extract_message(result) == "hello")
    }
  }

  fn apply_fn(value :: i64, callback :: (i64 -> i64)) -> i64 {
    callback(value)
  }

  fn make_pair(input :: i64) -> {i64, i64} {
    {input, 1}
  }

  fn extract_first(pair :: {i64, i64}) -> i64 {
    case pair {
      {first, _second} -> first
    }
  }

  fn extract_second(pair :: {i64, i64}) -> i64 {
    case pair {
      {_first, second} -> second
    }
  }

  fn wrap_message(message :: String) -> {Atom, String} {
    {:ok, message}
  }

  fn extract_message(pair :: {Atom, String}) -> String {
    case pair {
      {_status, message} -> message
    }
  }

  fn make_point(x_val :: i64, y_val :: i64) -> Point {
    %Point{x: x_val, y: y_val}
  }
}
