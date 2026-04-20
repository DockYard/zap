pub struct Point {
  x :: i64
  y :: i64
}

pub module Test.ProtocolTest {
  use Zest.Case

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
