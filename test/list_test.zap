pub module Test.ListTest {
  use Zest.Case

  describe("List module") {
    test("empty? on empty") {
      assert(List.empty?([]))
    }

    test("empty? on non-empty") {
      reject(List.empty?([1, 2]))
    }

    test("length empty") {
      assert(List.length([]) == 0)
    }

    test("length one") {
      assert(List.length([42]) == 1)
    }

    test("length three") {
      assert(List.length([1, 2, 3]) == 3)
    }

    test("head") {
      assert(List.head([10, 20, 30]) == 10)
    }

    test("head single") {
      assert(List.head([42]) == 42)
    }

    test("tail length") {
      assert(List.length(List.tail([10, 20, 30])) == 2)
    }

    test("tail head") {
      assert(List.head(List.tail([10, 20, 30])) == 20)
    }

    test("at index 0") {
      assert(List.at([10, 20, 30], 0) == 10)
    }

    test("at index 1") {
      assert(List.at([10, 20, 30], 1) == 20)
    }

    test("at index 2") {
      assert(List.at([10, 20, 30], 2) == 30)
    }

    test("last") {
      assert(List.last([1, 2, 3]) == 3)
    }

    test("last single") {
      assert(List.last([42]) == 42)
    }

    test("sum") {
      assert(List.sum([1, 2, 3, 4]) == 10)
    }

    test("sum empty") {
      assert(List.sum([]) == 0)
    }

    test("product") {
      assert(List.product([2, 3, 4]) == 24)
    }

    test("product empty") {
      assert(List.product([]) == 1)
    }

    test("max") {
      assert(List.max([3, 1, 4, 1, 5]) == 5)
    }

    test("max negatives") {
      assert(List.max([-3, -1, -4]) == -1)
    }

    test("min") {
      assert(List.min([3, 1, 4, 1, 5]) == 1)
    }

    test("min negatives") {
      assert(List.min([-3, -1, -4]) == -4)
    }

    test("contains? found") {
      assert(List.contains?([1, 2, 3], 2))
    }

    test("contains? not found") {
      reject(List.contains?([1, 2, 3], 5))
    }

    test("contains? empty") {
      reject(List.contains?([], 1))
    }

    test("reverse head becomes last") {
      assert(List.last(List.reverse([1, 2, 3])) == 1)
    }

    test("reverse last becomes head") {
      assert(List.head(List.reverse([1, 2, 3])) == 3)
    }

    test("reverse preserves length") {
      assert(List.length(List.reverse([1, 2, 3])) == 3)
    }

    test("reverse empty") {
      assert(List.empty?(List.reverse([])))
    }

    test("prepend") {
      assert(List.head(List.prepend([2, 3], 1)) == 1)
    }

    test("prepend length") {
      assert(List.length(List.prepend([2, 3], 1)) == 3)
    }

    test("append last") {
      assert(List.last(List.append([1, 2], 3)) == 3)
    }

    test("append length") {
      assert(List.length(List.append([1, 2], 3)) == 3)
    }

    test("concat length") {
      assert(List.length(List.concat([1, 2], [3, 4])) == 4)
    }

    test("concat head") {
      assert(List.head(List.concat([1, 2], [3, 4])) == 1)
    }

    test("concat last") {
      assert(List.last(List.concat([1, 2], [3, 4])) == 4)
    }

    test("take three") {
      assert(List.length(List.take([1, 2, 3, 4, 5], 3)) == 3)
    }

    test("take last is third") {
      assert(List.last(List.take([1, 2, 3, 4, 5], 3)) == 3)
    }

    test("take more than available") {
      assert(List.length(List.take([1, 2], 5)) == 2)
    }

    test("take zero") {
      assert(List.empty?(List.take([1, 2, 3], 0)))
    }

    test("drop two") {
      assert(List.head(List.drop([1, 2, 3, 4, 5], 2)) == 3)
    }

    test("drop length") {
      assert(List.length(List.drop([1, 2, 3, 4, 5], 2)) == 3)
    }

    test("drop more than available") {
      assert(List.empty?(List.drop([1, 2], 5)))
    }

    test("drop zero") {
      assert(List.length(List.drop([1, 2, 3], 0)) == 3)
    }

    test("uniq removes duplicates") {
      assert(List.length(List.uniq([1, 2, 2, 3, 1])) == 3)
    }

    test("uniq preserves order") {
      assert(List.head(List.uniq([1, 2, 2, 3, 1])) == 1)
    }

    test("uniq all same") {
      assert(List.length(List.uniq([1, 1, 1])) == 1)
    }

    test("uniq no duplicates") {
      assert(List.length(List.uniq([1, 2, 3])) == 3)
    }
  }
}
