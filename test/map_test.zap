pub module Test.MapTest {
  use Zest.Case

  describe("Map module") {
    test("size of map") {
      assert(Map.size(%{a: 1, b: 2, c: 3}) == 3)
    }

    test("size of empty map") {
      assert(Map.size(%{}) == 0)
    }

    test("empty? on empty") {
      assert(Map.empty?(%{}))
    }

    test("empty? on non-empty") {
      reject(Map.empty?(%{a: 1}))
    }

    test("has_key? finds key") {
      assert(Map.has_key?(%{a: 1, b: 2}, :a))
    }

    test("has_key? missing key") {
      reject(Map.has_key?(%{a: 1}, :z))
    }

    test("get with existing key") {
      assert(Map.get(%{a: 42, b: 99}, :a, 0) == 42)
    }

    test("get with missing key returns default") {
      assert(Map.get(%{a: 1}, :z, 99) == 99)
    }

    test("put adds new key") {
      result = Map.put(%{a: 1}, :b, 2)
      assert(Map.size(result) == 2)
      assert(Map.get(result, :b, 0) == 2)
    }

    test("put updates existing key") {
      result = Map.put(%{a: 1}, :a, 99)
      assert(Map.size(result) == 1)
      assert(Map.get(result, :a, 0) == 99)
    }

    test("delete removes key") {
      result = Map.delete(%{a: 1, b: 2}, :a)
      assert(Map.size(result) == 1)
      reject(Map.has_key?(result, :a))
    }

    test("delete missing key unchanged") {
      result = Map.delete(%{a: 1}, :z)
      assert(Map.size(result) == 1)
    }

    test("merge combines maps") {
      result = Map.merge(%{a: 1, b: 2}, %{c: 3})
      assert(Map.size(result) == 3)
    }

    test("merge overrides existing") {
      result = Map.merge(%{a: 1, b: 2}, %{b: 99})
      assert(Map.get(result, :b, 0) == 99)
    }

    test("keys returns list") {
      assert(List.length(Map.keys(%{a: 1, b: 2})) == 2)
    }

    test("values returns list") {
      assert(List.length(Map.values(%{a: 1, b: 2})) == 2)
    }
  }

  describe("String value maps") {
    test("create and access string value map") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.get(names, :first, "") == "Alice")
    }

    test("get with missing key returns default") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.get(names, :missing, "unknown") == "unknown")
    }

    test("size of string value map") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.size(names) == 2)
    }

    test("has_key? on string value map") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.has_key?(names, :first))
      reject(Map.has_key?(names, :missing))
    }

    test("put on string value map") {
      names = %{first: "Alice"}
      result = Map.put(names, :last, "Smith")
      assert(Map.size(result) == 2)
      assert(Map.get(result, :last, "") == "Smith")
    }
  }
}
