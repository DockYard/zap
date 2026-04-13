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
}
