pub struct DupPair {
  first :: i64
  second :: i64
}

pub struct TupleTest {
  use Zest.Case

  describe("tuples") {
    test("construct and read compile-time-indexed slots") {
      tuple = {1, "two", true}

      assert(tuple.0 == 1)
      assert(tuple.1 == "two")
      assert(tuple.2 == true)
    }

    test("Tuple.size returns the fixed arity") {
      assert(Tuple.size({1, "two", true}) == 3)
      assert(Tuple.size({:ok, 42}) == 2)
    }

    test("assignment destructuring extracts tuple slots") {
      {left, right} = make_pair(20, 22)

      assert(left + right == 42)
    }

    test("multi-return tuple preserves element types") {
      {value, ok?} = status(41)

      assert(value == 42)
      assert(ok? == true)
    }

    test("nested tuple preserves nested element types") {
      nested = nested_tuple()
      inner = nested.1

      assert(nested.0 == 7)
      assert(inner.0 == "zap")
      assert(inner.1 == true)
      assert(Tuple.size(inner) == 2)
    }

    test("extract first element") {
      assert(first({1, 2}) == 1)
    }

    test("extract second element") {
      assert(second({10, 20}) == 20)
    }

    test("sum tuple elements") {
      assert(sum_tuple({3, 4}) == 7)
    }

    test("second with wildcard first") {
      assert(second_wild({10, 20}) == 20)
    }

    test("first with wildcard second") {
      assert(first_wild({10, 20}) == 10)
    }

    test("double second element") {
      assert(double_second({5, 7}) == 14)
    }
  }

  fn first(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> a
    }
  }

  fn second(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> b
    }
  }

  fn sum_tuple(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> a + b
    }
  }

  fn second_wild(t :: {i64, i64}) -> i64 {
    case t {
      {_, b} -> b
    }
  }

  fn first_wild(t :: {i64, i64}) -> i64 {
    case t {
      {a, _} -> a
    }
  }

  fn double_second(t :: {i64, i64}) -> i64 {
    case t {
      {_, b} -> b + b
    }
  }

  fn make_pair(left :: i64, right :: i64) -> {i64, i64} {
    {left, right}
  }

  fn status(value :: i64) -> {i64, Bool} {
    {value + 1, true}
  }

  fn nested_tuple() -> {i64, {String, Bool}} {
    {7, {"zap", true}}
  }

  describe("tuple patterns with atom literals") {
    test("match :ready atom in tuple") {
      assert(extract_ready({:ready, 42}) == 42)
    }

    test("non-matching atom falls through to wildcard") {
      assert(extract_ready({:waiting, 0}) == 0 - 1)
    }

    test("unknown atom falls through to wildcard") {
      assert(extract_ready({:unknown, 99}) == 0 - 1)
    }
  }

  fn extract_ready(t :: {Atom, i64}) -> i64 {
    case t {
      {:ready, value} -> value
      {_, _} -> 0 - 1
    }
  }

  describe("tuple-destructured parameters preserve element types") {
    test("destructured String element flows into `<>` Concatenable dispatch") {
      assert(greet({"hello", 42 :: i64}) == "hello world")
    }

    test("destructured String element flows into `<=` Comparable dispatch") {
      assert(string_le({"abc", 1 :: i64}, "abd") == true)
      assert(string_le({"abd", 1 :: i64}, "abc") == false)
    }

    test("destructured `i64` element preserves type for arithmetic") {
      assert(double_count({"x", 21 :: i64}) == 42)
    }
  }

  # Regression for audit finding hir-1--02 / TY-07: variable unification
  # (pin conversion) must detect a DUPLICATE bind of the same variable
  # anywhere in a pattern and convert the 2nd+ occurrences into an equality
  # check against the 1st. Pre-fix, `{x, x}` compiled both occurrences as
  # fresh binds, so the pattern matched ANY pair (with `x` bound to the
  # first element) instead of only equal pairs.
  describe("duplicate-variable unification") {
    test("a tuple pattern with a repeated variable matches only equal pairs") {
      assert(both_equal({7, 7}) == :equal)
      assert(both_equal({7, 8}) == :different)
    }

    test("a function head with a repeated parameter matches only equal arguments") {
      assert(same_pair(5, 5) == :same)
      assert(same_pair(5, 6) == :different)
    }

    test("a repeated variable across struct sub-pattern fields matches only equal fields") {
      ## Both struct fields bind the same name `v` in a single case-arm
      ## pattern: the 2nd occurrence must become an equality check, so the
      ## arm matches only when both fields are equal. This also exercises
      ## duplicate unification inside a `case` arm (its own binding scope).
      assert(struct_equal(%DupPair{first: 3, second: 3}) == :equal)
      assert(struct_equal(%DupPair{first: 3, second: 4}) == :different)
    }

    test("a variable bound in a struct sub-pattern unifies with a later parameter") {
      ## The bind `x` lives inside the struct destructure of the first
      ## parameter; the second parameter `x` must become an equality check
      ## against it, not an independent fresh binding.
      assert(field_matches_arg(%DupPair{first: 9, second: 0}, 9) == :match)
      assert(field_matches_arg(%DupPair{first: 9, second: 0}, 4) == :nomatch)
    }
  }

  fn both_equal(t :: {i64, i64}) -> Atom {
    case t {
      {x, x} -> :equal
      _ -> :different
    }
  }

  fn same_pair(x :: i64, x :: i64) -> Atom {
    :same
  }

  fn same_pair(_ :: i64, _ :: i64) -> Atom {
    :different
  }

  fn struct_equal(p :: DupPair) -> Atom {
    case p {
      %DupPair{first: v, second: v} -> :equal
      _ -> :different
    }
  }

  fn field_matches_arg(%{first: x} :: DupPair, x :: i64) -> Atom {
    :match
  }

  fn field_matches_arg(_ :: DupPair, _ :: i64) -> Atom {
    :nomatch
  }

  # Parameter-level tuple destructure: the `{name, _}` pattern lives on the
  # function-clause boundary so the destructured locals must be registered
  # in the IR's `known_local_types` map for downstream protocol dispatch
  # (`<>`, `<=`) to resolve `String` correctly.
  fn greet({name, _} :: {String, i64}) -> String {
    name <> " world"
  }

  fn string_le({kmer, _} :: {String, i64}, other :: String) -> Bool {
    kmer <= other
  }

  fn double_count({_, n} :: {String, i64}) -> i64 {
    n + n
  }
}
