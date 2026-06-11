pub struct Zap.ListTest {
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
    test("push") { assert(List.last(List.push([1, 2], 3)) == 3) }
    test("concat") { assert(List.length(List.concat([1, 2], [3, 4])) == 4) }
    test("take") { assert(List.length(List.take([1, 2, 3, 4, 5], 3)) == 3) }
    test("drop") { assert(List.head(List.drop([1, 2, 3, 4, 5], 2)) == 3) }
    test("uniq") { assert(List.length(List.uniq([1, 2, 2, 3, 1])) == 3) }
    test("fixed-length pattern sums list") { assert(sum_three([10, 20, 12]) == 42) }
    test("recursive sum with cons pattern") { assert(sum_all([10, 20, 12]) == 42) }
    test("recursive length with cons pattern") { assert(length_recursive([1, 2, 3, 4, 5]) == 5) }
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

  describe("multi-head rest patterns") {
    test("binds indexed heads and rest") {
      assert(score_three_head_rest([1, 2, 3, 4, 5]) == 125)
    }

    test("does not match when there are fewer heads than requested") {
      assert(score_three_head_rest([1, 2]) == -1)
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

  fn score_three_head_rest([a, b, c | rest] :: [i64]) -> i64 {
    (a * 100) + (b * 10) + c + List.length(rest)
  }

  fn score_three_head_rest(_ :: [i64]) -> i64 {
    -1
  }

  fn sum_three(values :: [i64]) -> i64 {
    case values {
      [a, b, c] -> a + b + c
      _ -> 0
    }
  }

  fn sum_all([] :: [i64]) -> i64 {
    0
  }

  fn sum_all([head | tail] :: [i64]) -> i64 {
    head + sum_all(tail)
  }

  fn length_recursive([] :: [i64]) -> i64 {
    0
  }

  fn length_recursive([_ | tail] :: [i64]) -> i64 {
    1 + length_recursive(tail)
  }

  describe("Keyword list sugar") {
    test("single keyword pattern extracts value") {
      assert(get_name([name: "Brian"]) == "Brian")
    }

    test("multiple keyword pattern extracts later key") {
      assert(get_age([name: "Brian", age: 42]) == 42)
    }

    test("assigned keyword list matches in case") {
      options = [greeting: "Hello", name: "World"]

      assert(greeting(options) == "Hello, World!")
    }
  }

  fn get_name(options :: [{Atom, String}]) -> String {
    case options {
      [name: name] -> name
      _ -> "unknown"
    }
  }

  fn get_age(options :: [{Atom, i64}]) -> i64 {
    case options {
      [name: _, age: age] -> age
      _ -> 0
    }
  }

  fn greeting(options :: [{Atom, String}]) -> String {
    case options {
      [greeting: greeting, name: name] -> greeting <> ", " <> name <> "!"
      _ -> "no match"
    }
  }

  describe("Bang variants") {
    test("head! on non-empty") { assert(List.head!([10, 20, 30]) == 10) }
    test("last! on non-empty") { assert(List.last!([1, 2, 3]) == 3) }
    test("at! valid index") { assert(List.at!([10, 20, 30], 1) == 20) }
  }
}
