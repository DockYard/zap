@doc = """
  Regression coverage for a generic `pub union` specialized over a TUPLE /
  composite payload. Two facets of one root gap were fixed here:

    * Facet A — a bare `Option.Some({1, 2})` (no explicit type-args, no
      expected-type context) used to fall to the union's bare declaration
      TypeId, so no per-instantiation `union(enum)` was emitted; construction
      lowered to an anonymous struct and a subsequent `case` failed AstGen with
      `switch on struct with auto layout`. The type checker now recovers the
      instantiation from the ARGUMENT's own type.

    * Facet B — a parametric union whose variant payload resolves to a tuple
      rendered the payload as `anytype` in the synthetic `union(enum)` file
      (`error: expected type expression, found 'anytype'`). The payload renderer
      now lowers tuple / list / map / nested composites structurally.

  Both facets are exercised for `Option` and `Result` over tuple payloads,
  including nested composites, plus structural equality over tuples (which the
  dedupe-over-tuples stream path relies on). The `assert_no_leaks` blocks pin
  the construction/match ownership so the suite catches regressions under both
  the default (ARC) and `Memory.Tracking` binaries.
  """

pub struct Zap.UnionTuplePayloadTest {
  use Zest.Case

  describe("Option over a tuple payload") {
    test("bare Some infers the tuple instantiation from its argument") {
      value = Option.Some({1, 2})
      total = case value {
        Option.Some(pair) -> case pair { {x, y} -> x + y }
        Option.None -> 0 - 1
      }
      assert(total == 3)
    }

    test("explicit tuple type-args construct and match") {
      value = Option({i64, i64}).Some({4, 5})
      total = case value {
        Option.Some(pair) -> case pair { {x, y} -> x + y }
        Option.None -> 0 - 1
      }
      assert(total == 9)
    }

    test("None arm of a tuple-payload Option") {
      value = Option({i64, i64}).None
      label = case value {
        Option.Some(_pair) -> "some"
        Option.None -> "none"
      }
      assert(label == "none")
    }

    test("nested composite payload {list, scalar}") {
      value = Option.Some({[1, 2, 3], 9})
      total = case value {
        Option.Some(pair) -> case pair { {items, n} -> n + List.length(items) }
        Option.None -> 0 - 1
      }
      assert(total == 12)
    }

    test("string-bearing tuple payload") {
      value = Option.Some({"hi", 7})
      matched = case value {
        Option.Some(pair) -> case pair { {label, n} -> label == "hi" and n == 7 }
        Option.None -> false
      }
      assert(matched)
    }

    test("tuple-payload Option construct and match is leak-free") {
      assert_no_leaks {
        value = Option.Some({7, 8})
        total = case value {
          Option.Some(pair) -> case pair { {x, y} -> x + y }
          Option.None -> 0 - 1
        }
        assert(total == 15)
      }
    }
  }

  describe("Result over a tuple payload") {
    test("Ok carrying a tuple constructs and matches") {
      outcome = Result({i64, i64}, String).Ok({3, 4})
      total = case outcome {
        Result.Ok(pair) -> case pair { {x, y} -> x + y }
        Result.Error(_message) -> 0 - 1
      }
      assert(total == 7)
    }

    test("Error arm with a tuple Ok payload") {
      outcome = Result({i64, i64}, String).Error("boom")
      message = case outcome {
        Result.Ok(_pair) -> "ok"
        Result.Error(reason) -> reason
      }
      assert(message == "boom")
    }

    test("tuple-payload Result is leak-free") {
      assert_no_leaks {
        outcome = Result({i64, i64}, String).Ok({10, 20})
        total = case outcome {
          Result.Ok(pair) -> case pair { {x, y} -> x + y }
          Result.Error(_message) -> 0 - 1
        }
        assert(total == 30)
      }
    }
  }

  describe("structural equality over tuple values") {
    test("equal integer tuples compare equal") {
      assert({1, 2} == {1, 2})
    }

    test("unequal integer tuples compare unequal") {
      reject({1, 2} == {1, 3})
    }

    test("string-bearing tuples compare by content") {
      assert({"ab", 1} == {"ab", 1})
      reject({"ab", 1} == {"ac", 1})
    }

    test("runtime tuples compare by value not identity") {
      left = {String.concat("a", "b"), 1}
      right = {String.concat("a", "b"), 1}
      other = {String.concat("a", "c"), 1}
      assert(left == right)
      reject(left == other)
    }
  }
}
