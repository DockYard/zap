pub module Test.GenericsTest {
  use Zest.Case

  describe("generic functions") {
    test("identity with integer") {
      assert(identity(42) == 42)
    }

    test("identity with string") {
      assert(identity("hello") == "hello")
    }

    test("identity with bool") {
      assert(identity(true) == true)
    }

    test("map over strings") {
      result = Enum.map(["hello", "world"], fn(s :: String) -> String { String.upcase(s) })
      assert(List.length(result) == 2)
    }

    test("map over integers") {
      result = Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(result == [2, 4, 6])
    }

    test("filter over strings") {
      result = Enum.filter(["a", "bb", "ccc"], fn(s :: String) -> Bool { String.length(s) > 1 })
      assert(List.length(result) == 2)
    }

    test("list head with string") {
      assert(List.head(["hello", "world"]) == "hello")
    }

    test("list tail with string") {
      result = List.tail(["a", "b", "c"])
      assert(List.length(result) == 2)
    }

    test("list contains? with string") {
      assert(List.contains?(["a", "b", "c"], "b") == true)
      assert(List.contains?(["a", "b", "c"], "d") == false)
    }

    test("list append with string") {
      result = List.append(["a", "b"], "c")
      assert(List.length(result) == 3)
    }
  }

  pub fn identity(x :: a) -> a {
    x
  }
}
