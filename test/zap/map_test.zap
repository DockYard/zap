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

  describe("FU-38: owned-mutating Map receivers remain usable after calls") {
    test("Map.put keeps the original receiver available after the call") {
      original = %{first: "Ada"}
      updated = Map.put(original, :last, "Lovelace")

      assert(Map.get(original, :first, "") == "Ada")
      reject(Map.has_key?(original, :last))
      assert(Map.get(updated, :first, "") == "Ada")
      assert(Map.get(updated, :last, "") == "Lovelace")
    }

    test("Map.delete keeps the original receiver available after the call") {
      original = %{first: "Ada", last: "Lovelace"}
      updated = Map.delete(original, :last)

      assert(Map.get(original, :last, "") == "Lovelace")
      assert(Map.has_key?(original, :last))
      reject(Map.has_key?(updated, :last))
      assert(Map.get(updated, :first, "") == "Ada")
    }

    test("Map.merge keeps the left receiver available after the call") {
      left = %{first: "Ada"}
      right = %{last: "Lovelace"}
      merged = Map.merge(left, right)

      assert(Map.get(left, :first, "") == "Ada")
      reject(Map.has_key?(left, :last))
      assert(Map.get(merged, :first, "") == "Ada")
      assert(Map.get(merged, :last, "") == "Lovelace")
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

  # ----------------------------------------------------------------
  # runtime-3--01 (RT-18): every Map path that hands a VALUE (or KEY) to a
  # NEW owner WHILE THE MAP KEEPS ITS OWN (a value-semantic SHARE) must
  # clone-on-share (`ownEntryValue`/`ownEntryKey`), NOT bare-retain
  # (`retainEntryValue`/`retainEntryKey`).
  #
  # Under `Memory.Tracking` (INDIVIDUAL_NO_REFCOUNT + CLONE_ON_SHARE) a
  # bare retain is a no-op — it does NOT clone — so the new owner ALIASES
  # the map's eagerly-freed boxed-`Callable` inner. When BOTH the map and
  # the new owner drop, each deep-frees the SAME inner: a use-after-free /
  # double-free (`INVALID FREE` under Tracking; a genuine heap double-free
  # under any other caps-0x2 manager). The found / absent-key arms of
  # `Map.get` were corrected in f893af9; this fix corrects the remaining
  # SHARE hand-out sites left bare-retaining — the null-map `Map.get`
  # default arm (the named defect), `Map.keys` / `Map.values`, and the
  # `Map.next` iteration cursor — the exact `List.ownElement` analog that
  # `List` already applies at every element hand-out.
  #
  # NOTE — the `Map.put` / `Map.delete` shared-receiver clone
  # (`cloneBufferRetainingChildren`) is NOT a share: it clones for a
  # CONSUMED receiver (slot 0 is `.owned`), so the original is abandoned
  # and the clone is the sole surviving owner — a single retain is correct
  # there (deep-cloning would orphan the consumed inners into a leak). The
  # `Map.put`/`Map.delete` tests below are regression guards for that
  # (correct) consume path, not for the share fix.
  #
  # The closures CAPTURE (`make_handler(n)` closes over `n`), so each
  # boxed environment is an eagerly-freed inner whose mis-management is
  # observable: a missing clone-on-share leaves the surviving owner
  # invoking a freed environment (a use-after-free that corrupts the
  # captured value the value-equality assertions check) and double-frees
  # at scope exit.
  fn make_handler(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  # A two-entry `Map(Atom, fn(i64) -> i64)` of capturing closures, each
  # boxed as `Callable({i64}, i64)`.
  fn handler_map() -> %{Atom -> fn(i64) -> i64} {
    %{inc: Zap.MapTest.make_handler(1), dec: Zap.MapTest.make_handler(-1)}
  }

  # A second, disjoint-key two-entry `Map(Atom, fn(i64) -> i64)` of
  # capturing closures, used as the right-hand operand of `Map.merge`
  # so the merge result owns boxed values drawn from BOTH operands.
  fn other_handler_map() -> %{Atom -> fn(i64) -> i64} {
    %{double: Zap.MapTest.make_handler(100), triple: Zap.MapTest.make_handler(200)}
  }

  # A `Map(Atom, fn(i64) -> i64)` that is NULL at runtime when `populate`
  # is false (the empty `%{}` literal lowers to `Map.empty()` -> `null`)
  # but carries the concrete boxed-Callable value type via the populated
  # branch. Used to drive `Map.merge` with a null/empty operand — the
  # `merge(null, boxed_b)` and `merge(boxed_a, null)` arms — without the
  # compiler folding the branch away.
  fn handler_map_or_empty_double(populate :: Bool) -> %{Atom -> fn(i64) -> i64} {
    if populate {
      %{double: Zap.MapTest.make_handler(100), triple: Zap.MapTest.make_handler(200)}
    } else {
      %{}
    }
  }

  # A `Map(Atom, fn(i64) -> i64)` that is NULL at runtime when `populate` is
  # false: typed as boxed-Callable-valued but null, so `Map.get` on it takes
  # the null-map default arm — the precise runtime-3--01 defect site (`map
  # orelse { retainEntryValue(default); return default; }`). An empty `%{}`
  # literal lowers to `Map.empty()`, which returns `null`; the populated
  # branch (forced by the runtime `populate` parameter so the compiler cannot
  # fold the branch away, and never taken when the caller passes `false`)
  # gives the empty literal the concrete boxed-Callable value type. A map
  # emptied via `Map.delete` would NOT reach here: under Tracking
  # `Map.delete` returns a non-null empty buffer, so `Map.get` would take the
  # already-fixed absent-key arm.
  fn handler_map_or_empty(populate :: Bool) -> %{Atom -> fn(i64) -> i64} {
    if populate {
      %{seed: Zap.MapTest.make_handler(0)}
    } else {
      %{}
    }
  }

  describe("runtime-3--01: Map value hand-out clones boxed values (no double-free)") {
    test("found-path Map.get returns an independently-owned closure") {
      handlers = Zap.MapTest.handler_map()
      inc = Map.get(handlers, :inc, Zap.MapTest.make_handler(0))
      dec = Map.get(handlers, :dec, Zap.MapTest.make_handler(0))
      assert(inc(10) == 11)
      assert(dec(10) == 9)
    }

    test("Map.put on a boxed-value map is fault-free and correct") {
      # Regression guard for the consumed-receiver clone path. Every checked
      # `Map.put` flows through `cloneBufferRetainingChildren` under Tracking
      # (the rc==1 fast path is unreachable because the empty
      # `ArcHeader.count()` is a 0-byte no-op returning 0). That clone
      # bare-RETAINS its K/V, which is CORRECT here: `Map.put` consumes its
      # receiver (`.owned` slot 0), so the fresh buffer is the sole surviving
      # owner of each entry — the original is abandoned, never separately
      # released, so a single retain hands the inners to exactly one owner
      # (NOT the clone-on-share SHARE case, where both source and clone
      # survive and `cloneForShare` must deep-clone). This pins boxed-value
      # `Map.put` fault-free + correct so a future change to that clone
      # discipline cannot silently introduce a double-free or a leak.
      assert_no_memory_faults {
        assert_no_leaks {
          handlers = Zap.MapTest.handler_map()
          grown = Map.put(handlers, :id, Zap.MapTest.make_handler(0))
          assert(Map.size(grown) == 3)
          again = Map.get(grown, :inc, Zap.MapTest.make_handler(0))
          assert(again(10) == 11)
        }
      }
    }

    test("Map.delete on a boxed-value map is fault-free and correct") {
      # `Map.delete` shares the same consumed-receiver clone path as
      # `Map.put` (`cloneBufferRetainingChildren` at the shared arm); pinned
      # fault-free + correct as a regression guard for the same discipline.
      assert_no_memory_faults {
        assert_no_leaks {
          handlers = Zap.MapTest.handler_map()
          smaller = Map.delete(handlers, :dec)
          assert(Map.size(smaller) == 1)
          still = Map.get(smaller, :inc, Zap.MapTest.make_handler(0))
          assert(still(10) == 11)
        }
      }
    }

    test("null-map Map.get returns the boxed default without double-free") {
      # The named runtime-3--01 arm: `Map.get(<null map>, key, boxed_default)`
      # routed the default through `retainEntryValue` (bare retain) instead
      # of `ownEntryValue` (clone-on-share). Under Tracking the returned
      # `fallback` then aliased the caller's `default` inner; both dropped,
      # double-freeing it. The result must be the default closure invoked
      # correctly, with no reported fault and no leak.
      assert_no_memory_faults {
        assert_no_leaks {
          empty = Zap.MapTest.handler_map_or_empty(false)
          fallback = Map.get(empty, :missing, Zap.MapTest.make_handler(100))
          assert(fallback(10) == 110)
        }
      }
    }

    test("absent-key Map.get on a populated map returns the boxed default cleanly") {
      assert_no_memory_faults {
        assert_no_leaks {
          handlers = Zap.MapTest.handler_map()
          fallback = Map.get(handlers, :missing, Zap.MapTest.make_handler(7))
          assert(fallback(10) == 17)
        }
      }
    }

    test("Map.values hands out independently-owned closures (no double-free)") {
      # `Map.values` pushes each entry value into a fresh List; a bare
      # `retainEntryValue` before the push aliased the map's inner with the
      # List element. Dropping both the map and the List deep-frees the same
      # inner twice.
      assert_no_memory_faults {
        assert_no_leaks {
          handlers = Zap.MapTest.handler_map()
          vals = Map.values(handlers)
          assert(List.length(vals) == 2)
          f = List.get(vals, 0)
          assert(f(10) == 11)
        }
      }
    }

    # ----------------------------------------------------------------
    # FU-31 (audit RT-18 systemic sibling): `Map.merge` folds a BORROWED
    # right operand into a CONSUMED left operand. Under `Memory.Tracking`
    # (INDIVIDUAL_NO_REFCOUNT + CLONE_ON_SHARE) the pre-fix merge
    # `retain`ed `map_a` (a no-op alias, not an independent owner) and
    # folded each `b` entry via `put` (whose `putInPlaceInsert` bare-
    # retained the value), so the result ALIASED the boxed inners of `b`
    # and the intermediate `release` deep-freed the just-cloned-from
    # buffer mid-fold — an `invalid free` (a SEGFAULT under a non-tracking
    # caps-0x2 manager). The fix makes merge an owned fold: `map_a`'s
    # ownership flows into the result (reused/moved when uniquely owned —
    # which a consumed receiver always is under CLONE_ON_SHARE) and each
    # borrowed `b` entry is cloned-on-share (`ownEntryKey`/`ownEntryValue`)
    # into it, deep-releasing a displaced value exactly once on overlap.
    #
    # These exercise the merge of FRESH (at-last-use, consumed) boxed-value
    # operands — the exact A/B from the audit FU-31 finding — asserting the
    # merged result's closures are invoked correctly with no fault or leak.
    test("Map.merge of two boxed-value maps is fault-free and correct") {
      assert_no_memory_faults {
        assert_no_leaks {
          merged = Map.merge(Zap.MapTest.handler_map(), Zap.MapTest.other_handler_map())
          assert(Map.size(merged) == 4)
          # The merged result owns independent copies of inners drawn from
          # BOTH operands.
          merged_inc = Map.get(merged, :inc, Zap.MapTest.make_handler(0))
          assert(merged_inc(10) == 11)
          merged_dec = Map.get(merged, :dec, Zap.MapTest.make_handler(0))
          assert(merged_dec(10) == 9)
          merged_double = Map.get(merged, :double, Zap.MapTest.make_handler(0))
          assert(merged_double(10) == 110)
          merged_triple = Map.get(merged, :triple, Zap.MapTest.make_handler(0))
          assert(merged_triple(10) == 210)
        }
      }
    }

    test("Map.merge with an empty left operand is fault-free and correct") {
      # The `merge(null, boxed_b)` arm: pre-fix it returned `retain(map_b)`
      # (an alias of the borrowed `map_b`), so the caller's `map_b` drop and
      # the result drop double-freed `map_b`'s boxed inners. The fix returns
      # an independently-owned clone-on-share copy of `map_b`.
      assert_no_memory_faults {
        assert_no_leaks {
          merged = Map.merge(Zap.MapTest.handler_map_or_empty_double(false), Zap.MapTest.other_handler_map())
          assert(Map.size(merged) == 2)
          merged_double = Map.get(merged, :double, Zap.MapTest.make_handler(0))
          assert(merged_double(10) == 110)
          merged_triple = Map.get(merged, :triple, Zap.MapTest.make_handler(0))
          assert(merged_triple(10) == 210)
        }
      }
    }

    test("Map.merge with an empty right operand is fault-free and correct") {
      # The `merge(boxed_a, null)` arm: the consumed `map_a` flows directly
      # into the result. Pre-fix the borrowed-operand aliasing class showed
      # the same double-free; pinned fault-free + leak-free here.
      assert_no_memory_faults {
        assert_no_leaks {
          merged = Map.merge(Zap.MapTest.handler_map(), Zap.MapTest.handler_map_or_empty_double(false))
          assert(Map.size(merged) == 2)
          merged_inc = Map.get(merged, :inc, Zap.MapTest.make_handler(0))
          assert(merged_inc(10) == 11)
          merged_dec = Map.get(merged, :dec, Zap.MapTest.make_handler(0))
          assert(merged_dec(10) == 9)
        }
      }
    }

    test("Map.merge with overlapping keys takes the right value, fault-free") {
      # When a key appears in both operands, `merge` must take `b`'s value
      # (and own an independent copy of it); the displaced `a` value inner
      # must be freed exactly once by the result owner, never aliased.
      assert_no_memory_faults {
        assert_no_leaks {
          base = %{inc: Zap.MapTest.make_handler(1), dec: Zap.MapTest.make_handler(-1)}
          overlay = %{inc: Zap.MapTest.make_handler(5), gain: Zap.MapTest.make_handler(9)}
          merged = Map.merge(base, overlay)
          assert(Map.size(merged) == 3)
          # `:inc` resolves to overlay's (+5), not base's (+1).
          merged_inc = Map.get(merged, :inc, Zap.MapTest.make_handler(0))
          assert(merged_inc(10) == 15)
          merged_dec = Map.get(merged, :dec, Zap.MapTest.make_handler(0))
          assert(merged_dec(10) == 9)
          merged_gain = Map.get(merged, :gain, Zap.MapTest.make_handler(0))
          assert(merged_gain(10) == 19)
        }
      }
    }
  }

  # ----------------------------------------------------------------
  # runtime-3--02 (RT-19): Term.from must represent List/Map/tuple
  # values LOSSLESSLY when they are stored into a heterogeneous
  # collection.
  #
  # A collection literal whose values mix an aggregate (List/Map) and a
  # scalar forces the value element type to the heterogeneous `Term`
  # carrier (`unifyForCollection` collapses the value axis to TERM). Each
  # value element then lowers through `Term.from` (`emitTermWrap` ->
  # `:zig.Term.from`). Before the fix `Term.from` had no `.list`/`.map`/
  # `.tuple` arm: a `?*const List(_)` / `?*const Map(_,_)` unwrapped
  # through the generic `.optional`/`.pointer` arms to a size==.one
  # pointer-to-struct and fell through to `.nil`, silently destroying the
  # stored collection. A later `Map.get`/`List.at` then observed nil
  # instead of the value — a silent miscompilation reachable from benign
  # source. These tests pin the round-trip (the value comes back EQUAL to
  # what was stored, never nil) for each aggregate kind.
  #
  # The default `Memory.ARC` corpus manager exercises the REFCOUNTED
  # boxing path (the stored cell is retained through the box vtable on
  # store and released on the container's drop); the `assert_no_leaks`
  # blocks additionally pin the net live-allocation delta to zero under
  # `Memory.Tracking` (where a boxed cell needs clone-on-share on extract
  # and a deep-free on the container drop) — proving the new box vtable
  # neither leaks the cell nor double-frees it.
  describe("runtime-3--02: aggregate values round-trip through a heterogeneous Map") {
    test("a List value stored beside a scalar comes back intact, not nil") {
      hetero = %{items: [10, 20, 30], count: 3}
      items = Map.get(hetero, :items, [0])
      # PRE-FIX: `items` is the `[0]` default (the stored list was dropped
      # as nil). POST-FIX: the original three-element list.
      assert(List.length(items) == 3)
      assert(List.at(items, 0) == 10)
      assert(List.at(items, 1) == 20)
      assert(List.at(items, 2) == 30)
      # The scalar value in the same heterogeneous map is unaffected.
      assert(Map.get(hetero, :count, 0) == 3)
    }

    test("a Map value stored beside a scalar comes back intact, not nil") {
      hetero = %{inner: %{port: 8080, timeout: 30}, version: 1}
      inner = Map.get(hetero, :inner, %{port: 0, timeout: 0})
      # PRE-FIX: `inner` is the empty default. POST-FIX: the stored map.
      assert(Map.get(inner, :port, 0) == 8080)
      assert(Map.get(inner, :timeout, 0) == 30)
      assert(Map.get(hetero, :version, 0) == 1)
    }

    test("aggregate-in-heterogeneous-Map round-trip is leak-free under Tracking") {
      # Store a List and a Map value (each beside a scalar) into a
      # heterogeneous map, read both back, and assert the net live
      # allocation delta is zero. A pre-fix `.nil` store would have leaked
      # the producer's cell (never owned by the map); an over-retain on
      # the new box vtable would leak, an over-release would reclaim a
      # still-referenced cell (invalid-free under Tracking).
      assert_no_leaks {
        list_holder = %{vals: [7, 8, 9], n: 3}
        vals = Map.get(list_holder, :vals, [0])
        assert(List.length(vals) == 3)
        assert(List.at(vals, 2) == 9)

        map_holder = %{cfg: %{a: 1, b: 2}, tag: 5}
        cfg = Map.get(map_holder, :cfg, %{a: 0, b: 0})
        assert(Map.get(cfg, :b, 0) == 2)
      }
    }
  }
}
