pub struct TupleTest {
  use Zest.Case

  describe("tuples") {
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

  describe("tuple patterns with atom literals") {
    test("match :ok atom in tuple") {
      assert(extract_ok({:ok, 42}) == 42)
    }

    test("non-matching atom falls through to wildcard") {
      assert(extract_ok({:error, 0}) == 0 - 1)
    }

    test("unknown atom falls through to wildcard") {
      assert(extract_ok({:unknown, 99}) == 0 - 1)
    }
  }

  fn extract_ok(t :: {Atom, i64}) -> i64 {
    case t {
      {:ok, v} -> v
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
