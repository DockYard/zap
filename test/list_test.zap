pub module Test.ListTest {
  use Zest.Case

  describe("Integer lists") {
    test("empty? on empty") { assert(List.empty?([])) }
    test("empty? on non-empty") { reject(List.empty?([1, 2])) }
    test("length empty") { assert(List.length([]) == 0) }
    test("length three") { assert(List.length([1, 2, 3]) == 3) }
    test("head") { assert(List.head([10, 20, 30]) == 10) }
    test("tail head") { assert(List.head(List.tail([10, 20, 30])) == 20) }
    test("at index") { assert(List.at([10, 20, 30], 1) == 20) }
    test("last") { assert(List.last([1, 2, 3]) == 3) }
    test("contains? found") { assert(List.contains?([1, 2, 3], 2)) }
    test("contains? not found") { reject(List.contains?([1, 2, 3], 5)) }
    test("reverse") { assert(List.head(List.reverse([1, 2, 3])) == 3) }
    test("prepend") { assert(List.head(List.prepend([2, 3], 1)) == 1) }
    test("append") { assert(List.last(List.append([1, 2], 3)) == 3) }
    test("concat") { assert(List.length(List.concat([1, 2], [3, 4])) == 4) }
    test("take") { assert(List.length(List.take([1, 2, 3, 4, 5], 3)) == 3) }
    test("drop") { assert(List.head(List.drop([1, 2, 3, 4, 5], 2)) == 3) }
    test("uniq") { assert(List.length(List.uniq([1, 2, 2, 3, 1])) == 3) }
  }

  describe("String lists") {
    test("length") { assert(List.length(["hello", "world"]) == 2) }
    test("head") { assert(List.head(["hello", "world"]) == "hello") }
    test("last") { assert(List.last(["alpha", "beta", "gamma"]) == "gamma") }
    test("at index") { assert(List.at(["a", "b", "c"], 1) == "b") }
    test("reverse") { assert(List.head(List.reverse(["first", "second", "third"])) == "third") }
    test("contains? found") { assert(List.contains?(["apple", "banana"], "banana")) }
    test("contains? not found") { reject(List.contains?(["apple", "banana"], "mango")) }
    test("concat") { assert(List.length(List.concat(["a", "b"], ["c", "d"])) == 4) }
  }

  describe("Float lists") {
    test("length") { assert(List.length([1.5, 2.7, 3.9]) == 3) }
    test("head") { assert(List.head([1.5, 2.7, 3.9]) == 1.5) }
    test("last") { assert(List.last([1.5, 2.7, 3.9]) == 3.9) }
    test("at index") { assert(List.at([10.0, 20.0, 30.0], 1) == 20.0) }
    test("reverse") { assert(List.head(List.reverse([1.1, 2.2, 3.3])) == 3.3) }
  }

  describe("Bool lists") {
    test("length") { assert(List.length([true, false, true]) == 3) }
    test("head") { assert(List.head([true, false])) }
    test("last") { reject(List.last([true, true, false])) }
  }

  describe("Nested lists") {
    test("list of integer lists length") {
      assert(nested_list_length() == 2)
    }

    test("inner list head") {
      assert(inner_list_head() == 1)
    }
  }

  fn nested_list_length() -> i64 {
    nested = [[1, 2, 3], [4, 5]]
    List.length(nested)
  }

  fn inner_list_head() -> i64 {
    nested = [[1, 2, 3], [4, 5]]
    first = List.head(nested)
    List.head(first)
  }

  describe("Bang variants") {
    test("head! on non-empty") { assert(List.head!([10, 20, 30]) == 10) }
    test("last! on non-empty") { assert(List.last!([1, 2, 3]) == 3) }
    test("at! valid index") { assert(List.at!([10, 20, 30], 1) == 20) }
  }
}
