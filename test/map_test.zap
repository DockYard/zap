pub struct Test.MapTest {
  use Zest.Case

  describe("Integer value maps") {
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
  }

  describe("String value maps") {
    test("create and access") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.get(names, :first, "") == "Alice")
    }

    test("get with missing key returns default") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.get(names, :missing, "unknown") == "unknown")
    }

    test("size") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.size(names) == 2)
    }

    test("has_key?") {
      names = %{first: "Alice", last: "Smith"}
      assert(Map.has_key?(names, :first))
      reject(Map.has_key?(names, :missing))
    }

    test("put") {
      names = %{first: "Alice"}
      result = Map.put(names, :last, "Smith")
      assert(Map.size(result) == 2)
      assert(Map.get(result, :last, "") == "Smith")
    }

    test("delete") {
      names = %{first: "Alice", last: "Smith"}
      result = Map.delete(names, :first)
      assert(Map.size(result) == 1)
      reject(Map.has_key?(result, :first))
    }

    test("merge") {
      result = Map.merge(%{a: "hello"}, %{b: "world"})
      assert(Map.size(result) == 2)
      assert(Map.get(result, :b, "") == "world")
    }

    test("merge overrides") {
      result = Map.merge(%{a: "old"}, %{a: "new"})
      assert(Map.get(result, :a, "") == "new")
    }
  }

  describe("Float value maps") {
    test("create and access") {
      scores = %{math: 95.5, science: 88.0}
      assert(Map.get(scores, :math, 0.0) == 95.5)
    }

    test("get with missing key returns default") {
      scores = %{math: 95.5}
      assert(Map.get(scores, :missing, 0.0) == 0.0)
    }

    test("size") {
      scores = %{math: 95.5, science: 88.0}
      assert(Map.size(scores) == 2)
    }

    test("has_key?") {
      scores = %{math: 95.5}
      assert(Map.has_key?(scores, :math))
      reject(Map.has_key?(scores, :english))
    }

    test("put") {
      scores = %{math: 95.5}
      result = Map.put(scores, :science, 88.0)
      assert(Map.size(result) == 2)
      assert(Map.get(result, :science, 0.0) == 88.0)
    }

    test("delete") {
      scores = %{math: 95.5, science: 88.0}
      result = Map.delete(scores, :math)
      assert(Map.size(result) == 1)
      reject(Map.has_key?(result, :math))
    }

    test("merge") {
      result = Map.merge(%{a: 1.1, b: 2.2}, %{c: 3.3})
      assert(Map.size(result) == 3)
    }
  }

  describe("Bang variants") {
    test("get! on existing key") {
      assert(Map.get!(%{a: 42, b: 99}, :a, 0) == 42)
    }
  }

  describe("Nested maps") {
    test("nested map size") {
      assert(nested_map_size() == 2)
    }

    test("inner map access") {
      assert(inner_map_value() == 42)
    }
  }

  fn nested_map_size() -> i64 {
    nested = %{a: %{x: 1, y: 2}, b: %{x: 3, y: 4}}
    Map.size(nested)
  }

  fn inner_map_value() -> i64 {
    nested = %{settings: %{port: 42, timeout: 30}}
    inner = Map.get(nested, :settings, %{port: 0, timeout: 0})
    Map.get(inner, :port, 0)
  }

  describe("Nested maps") {
    test("nested map size") {
      assert(nested_map_size() == 2)
    }

    test("inner map access") {
      assert(inner_map_value() == 42)
    }
  }

  fn nested_map_size() -> i64 {
    nested = %{a: %{x: 1, y: 2}, b: %{x: 3, y: 4}}
    Map.size(nested)
  }

  fn inner_map_value() -> i64 {
    nested = %{settings: %{port: 42, timeout: 30}}
    inner = Map.get(nested, :settings, %{port: 0, timeout: 0})
    Map.get(inner, :port, 0)
  }

  describe("Bool value maps") {
    test("create and access") {
      flags = %{active: true, admin: false}
      assert(Map.get(flags, :active, false))
    }

    test("get missing returns default") {
      flags = %{active: true}
      reject(Map.get(flags, :missing, false))
    }

    test("size") {
      flags = %{active: true, admin: false, verified: true}
      assert(Map.size(flags) == 3)
    }

    test("has_key?") {
      flags = %{active: true}
      assert(Map.has_key?(flags, :active))
      reject(Map.has_key?(flags, :missing))
    }

    test("put") {
      flags = %{active: true}
      result = Map.put(flags, :admin, true)
      assert(Map.size(result) == 2)
      assert(Map.get(result, :admin, false))
    }
  }

  describe("Map iteration") {
    test("for-comp over map literal yields one element per entry") {
      counts = for _kv <- %{a: 1, b: 2, c: 3} { 1 }
      assert(List.length(counts) == 3)
    }

    test("for-comp over empty map yields empty list") {
      counts = for _kv <- %{} { 1 }
      assert(List.length(counts) == 0)
    }

    test("for-comp over single-entry map") {
      counts = for _kv <- %{single: 42} { 1 }
      assert(List.length(counts) == 1)
    }
  }
}
