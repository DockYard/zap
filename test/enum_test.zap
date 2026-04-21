pub module Test.EnumTest {
  use Zest.Case

  describe("Enum module") {
    test("map doubles values") {
      result = Enum.map([1, 2, 3], double)
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
      assert(List.length(result) == 3)
    }

    test("map empty list") {
      assert(List.empty?(Enum.map([], double)))
    }

    test("filter keeps matching") {
      result = Enum.filter([1, 2, 3, 4, 5], greater_than_three)
      assert(List.length(result) == 2)
      assert(List.head(result) == 4)
    }

    test("filter none match") {
      assert(List.empty?(Enum.filter([1, 2, 3], greater_than_ten)))
    }

    test("reject removes matching") {
      result = Enum.reject([1, 2, 3, 4, 5], greater_than_three)
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }

    test("reduce sum") {
      assert(Enum.reduce([1, 2, 3, 4], 0, add) == 10)
    }

    test("reduce product") {
      assert(Enum.reduce([2, 3, 4], 1, mul) == 24)
    }

    test("reduce empty") {
      assert(Enum.reduce([], 42, add) == 42)
    }

    test("reduce strings via concat") {
      assert(Enum.reduce(["a", "b", "c"], "", concat_str) == "abc")
    }

    test("sort strings by length") {
      result = Enum.sort(["ccc", "a", "bb"], str_less_than)
      assert(List.head(result) == "a")
      assert(List.last(result) == "ccc")
    }

    test("flat_map strings") {
      result = Enum.flat_map(["hi", "yo"], double_str)
      assert(List.length(result) == 4)
      assert(List.head(result) == "hi")
    }

    test("find first match") {
      assert(Enum.find([1, 2, 3, 4], 0, greater_than_two) == 3)
    }

    test("find no match returns default") {
      assert(Enum.find([1, 2], 99, greater_than_ten) == 99)
    }

    test("any? with match") {
      assert(Enum.any?([1, 2, 3], greater_than_two))
    }

    test("any? without match") {
      reject(Enum.any?([1, 2, 3], greater_than_ten))
    }

    test("all? true") {
      assert(Enum.all?([2, 4, 6], is_positive))
    }

    test("all? false") {
      reject(Enum.all?([2, 4, 6], greater_than_three))
    }

    test("count matching") {
      assert(Enum.count([1, 2, 3, 4, 5], greater_than_two) == 3)
    }

    test("count none") {
      assert(Enum.count([1, 2, 3], greater_than_ten) == 0)
    }

    test("sum") {
      assert(Enum.sum([1, 2, 3, 4]) == 10)
    }

    test("sum empty") {
      assert(Enum.sum([]) == 0)
    }

    test("product") {
      assert(Enum.product([2, 3, 4]) == 24)
    }

    test("product empty") {
      assert(Enum.product([]) == 1)
    }

    test("max") {
      assert(Enum.max([3, 1, 4, 1, 5]) == 5)
    }

    test("min") {
      assert(Enum.min([3, 1, 4, 1, 5]) == 1)
    }

    test("sort ascending") {
      result = Enum.sort([3, 1, 4, 1, 5], less_than)
      assert(List.head(result) == 1)
      assert(List.last(result) == 5)
    }

    test("sort descending") {
      result = Enum.sort([3, 1, 4, 1, 5], greater_than)
      assert(List.head(result) == 5)
      assert(List.last(result) == 1)
    }

    test("map with anonymous function") {
      result = Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
    }

    test("filter with anonymous function") {
      result = Enum.filter([1, 2, 3, 4, 5], fn(x :: i64) -> Bool { x > 3 })
      assert(List.length(result) == 2)
    }

    test("reduce with anonymous function") {
      assert(Enum.reduce([1, 2, 3, 4], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x }) == 10)
    }

    test("sort with anonymous comparator") {
      result = Enum.sort([3, 1, 2], fn(a :: i64, b :: i64) -> Bool { a < b })
      assert(List.head(result) == 1)
      assert(List.last(result) == 3)
    }

    test("take first three") {
      result = Enum.take([1, 2, 3, 4, 5], 3)
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
      assert(List.last(result) == 3)
    }

    test("take more than available") {
      result = Enum.take([1, 2], 5)
      assert(List.length(result) == 2)
    }

    test("take zero") {
      assert(List.empty?(Enum.take([1, 2, 3], 0)))
    }

    test("drop two") {
      result = Enum.drop([1, 2, 3, 4, 5], 2)
      assert(List.length(result) == 3)
      assert(List.head(result) == 3)
    }

    test("drop more than available") {
      assert(List.empty?(Enum.drop([1, 2], 5)))
    }

    test("drop zero") {
      assert(List.length(Enum.drop([1, 2, 3], 0)) == 3)
    }

    test("reverse") {
      result = Enum.reverse([1, 2, 3])
      assert(List.head(result) == 3)
      assert(List.last(result) == 1)
      assert(List.length(result) == 3)
    }

    test("reverse empty") {
      assert(List.empty?(Enum.reverse([])))
    }

    test("member? found") {
      assert(Enum.member?([1, 2, 3], 2))
    }

    test("member? not found") {
      reject(Enum.member?([1, 2, 3], 5))
    }

    test("member? empty") {
      reject(Enum.member?([], 1))
    }

    test("at index") {
      assert(Enum.at([10, 20, 30], 1) == 20)
    }

    test("at first") {
      assert(Enum.at([10, 20, 30], 0) == 10)
    }

    test("at last") {
      assert(Enum.at([10, 20, 30], 2) == 30)
    }

    test("concat two lists") {
      result = Enum.concat([1, 2], [3, 4])
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 4)
    }

    test("concat with empty first") {
      result = Enum.concat([], [1, 2])
      assert(List.length(result) == 2)
      assert(List.head(result) == 1)
    }

    test("concat with empty second") {
      result = Enum.concat([1, 2], [])
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
    }

    test("uniq removes duplicates") {
      result = Enum.uniq([1, 2, 2, 3, 1])
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
    }

    test("uniq all same") {
      assert(List.length(Enum.uniq([1, 1, 1])) == 1)
    }

    test("uniq no duplicates") {
      assert(List.length(Enum.uniq([1, 2, 3])) == 3)
    }

    test("empty? on empty") {
      assert(Enum.empty?([]))
    }

    test("empty? on non-empty") {
      reject(Enum.empty?([1, 2, 3]))
    }
  }

  fn double(x :: i64) -> i64 {
    x * 2
  }

  fn add(acc :: i64, x :: i64) -> i64 {
    acc + x
  }

  fn mul(acc :: i64, x :: i64) -> i64 {
    acc * x
  }

  fn greater_than_two(x :: i64) -> Bool {
    x > 2
  }

  fn greater_than_three(x :: i64) -> Bool {
    x > 3
  }

  fn greater_than_ten(x :: i64) -> Bool {
    x > 10
  }

  fn is_positive(x :: i64) -> Bool {
    x > 0
  }

  fn less_than(a :: i64, b :: i64) -> Bool {
    a < b
  }

  fn greater_than(a :: i64, b :: i64) -> Bool {
    a > b
  }

  fn concat_str(acc :: String, x :: String) -> String {
    acc <> x
  }

  fn str_less_than(a :: String, b :: String) -> Bool {
    String.length(a) < String.length(b)
  }

  fn double_str(s :: String) -> [String] {
    [s, s]
  }
}
