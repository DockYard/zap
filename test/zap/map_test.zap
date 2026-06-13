pub struct Zap.MapTest {
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

    test("map update syntax preserves unchanged keys") {
      assert(updated_name() == "Bob")
      assert(updated_city() == "Paris")
    }

    test("map pattern matching in function parameters") {
      assert(greet(%{name: "World", greeting: "Hello"}) == "Hello, World!")
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

  fn greet(%{name: name, greeting: greeting} :: %{Atom -> String}) -> String {
    greeting <> ", " <> name <> "!"
  }

  fn updated_name() -> String {
    original = %{name: "Alice", city: "Paris"}
    updated = %{original | name: "Bob"}
    Map.get(updated, :name, "unknown")
  }

  fn updated_city() -> String {
    original = %{name: "Alice", city: "Paris"}
    updated = %{original | name: "Bob"}
    Map.get(updated, :city, "unknown")
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

    test("for-comp over single-entry map") {
      counts = for _kv <- %{single: 42} { 1 }
      assert(List.length(counts) == 1)
    }

    test("for-comp tuple destructure binds key and value") {
      values = for {_k, v} <- %{a: 10, b: 20, c: 30} { v }
      assert(List.length(values) == 3)
    }
  }

  # ----------------------------------------------------------------
  # arc-own-1--02 regression: count-mutating ARC rewrites must not
  # leave the move-vs-copy classifier keying a STALE InstructionId
  # space.
  #
  # `arc_ownership.rewriteOwnedConsumeBuiltinSites` changes the
  # instruction count before classification — it drops the post-call
  # `release` for a consumed `Map.put` receiver and can expand a
  # consumed `borrow_value` into `copy_value` + `retain`. The
  # classifier then reconstructs InstructionIds positionally and gates
  # `move_value` vs `copy_value` on `ArcOwnership.isLastUseAt`. Before
  # the fix (recompute ownership after every count-mutating rewrite),
  # classify consulted the table the analyzer built against the
  # PRE-rewrite IR, mis-keying every gate after the first count change:
  # a conservative `copy_value` (an extra retain → leak under
  # `Memory.Tracking`) at best, an unsound `move_value` at a
  # non-last-use read (premature free / use-after-free) at worst.
  #
  # Each shape mutates an ARC `Map` local with a stream-shrinking
  # `Map.put` (or a recoverable raise, whose side-channel stash is
  # covered by `alwaysConsumingBuiltinArg`), then makes a move/copy
  # decision that depends on path-sensitive last-use — a binding read
  # once per branch arm, whose flat use-count is >1 but whose per-path
  # last-use is 1. The `assert_no_leaks` blocks pin the net
  # live-allocation delta to zero under `Memory.Tracking` (an
  # over-copy leaks, an over-move reclaims a still-referenced cell); a
  # documented no-op under the default `Memory.ARC` corpus manager,
  # where the value assertions still pin correct results through the
  # rewritten IR.
  describe("arc-own-1--02: Map.put shrinks the stream before a per-arm last-use branch") {
    test("conditional map mutation returns the expected size on both arms") {
      # `accumulate_map(true)` re-puts the existing `:base` key (size stays
      # 1); the `false` arm adds `:extra` (size 2). The point is that the
      # values are correct through the count-mutated/reclassified IR.
      assert(Map.size(accumulate_map(true)) == 1)
      assert(Map.size(accumulate_map(false)) == 2)
    }

    test("conditional map mutation is leak-free under Tracking") {
      assert_no_leaks {
        a = accumulate_map(true)
        assert(Map.get(a, :base, 0) == 1)
        b = accumulate_map(false)
        assert(Map.get(b, :extra, 0) == 9)
      }
    }
  }

  describe("arc-own-1--02: recursive Map accumulator fed through a conditional last-use") {
    test("recursive accumulation reaches the loop bound") {
      assert(Map.size(build_then_branch(0)) == 1)
      assert(Map.size(build_then_branch(3)) == 4)
    }

    test("recursive accumulation is leak-free under Tracking") {
      assert_no_leaks {
        result = build_then_branch(4)
        assert(Map.size(result) == 5)
      }
    }
  }

  # `Map.put` drops the post-call release (stream shrinks); the mutated
  # `updated` map is then read once in each `cond` arm — flat use-count
  # 2, per-path last-use 1.
  fn accumulate_map(flag :: Bool) -> %{Atom -> i64} {
    updated = Map.put(%{base: 1}, :base, 1)
    cond {
      flag -> updated
      true -> Map.put(updated, :extra, 9)
    }
  }

  # `seed` is built with a stream-shrinking `Map.put`, then read once in
  # each arm of an `if`: the then-arm forwards it into a recursive
  # accumulator at last use (move), the else-arm returns it directly
  # (also last use). Mirrors the `cleared` / `count_kmers_loop` shape
  # cited in the classifier comments.
  fn build_then_branch(n :: i64) -> %{Atom -> i64} {
    seed = Map.put(%{}, :start, 0)
    if n > 0 {
      accumulate_loop(seed, n)
    } else {
      seed
    }
  }

  fn accumulate_loop(acc :: %{Atom -> i64}, n :: i64) -> %{Atom -> i64} {
    if n <= 0 {
      acc
    } else {
      accumulate_loop(Map.put(acc, key_for(n), n), n - 1)
    }
  }

  fn key_for(n :: i64) -> Atom {
    cond {
      n == 1 -> :k1
      n == 2 -> :k2
      n == 3 -> :k3
      true -> :kx
    }
  }
}
