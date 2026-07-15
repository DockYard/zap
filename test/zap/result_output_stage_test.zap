@doc = """
  Regression tests for the canonical fallible-`Stage` shape: a stage whose
  `output` is a `Result(value, error)`. On failure it emits a
  `Result.Error(...)` output element and returns `:halt`; errors flow as
  ordinary stream elements, never as raises (see `Stage`'s "Fallibility is a
  value" contract).

  A `[Result(t, e) ...]` list literal is a list of GENERIC-UNION values.
  Building it used to fail ZIR emission (`list_init: EmitFailed`) because the
  container-element type-ref path did not resolve a generic-union
  specialization, so a `Result`-*output* stage could not be compiled and the
  fallibility contract had to be exercised with an i64 error-sentinel instead.
  With the union arm in place (and the matching vtable-source rendering plus
  the union-aware default-element builder), the canonical `Result` output
  compiles, drives, and is memory-clean under both the default (ARC) and
  `Memory.Tracking` binaries — the ARC `String` error payloads are released on
  both the natural-end and early-halt paths.
  """

# A fallible stage over i64: passes positive items through as `Result.Ok`,
# and on the first non-positive item emits a `Result.Error` carrying a
# `String` reason and halts. The error is the final element the stream yields.
pub struct DivideStage {
}

pub impl Stage(i64, Result(i64, String)) for DivideStage {
  pub fn step(_stage :: unique DivideStage, item :: i64) -> {Atom, [Result(i64, String)], DivideStage} {
    if item > 0 {
      {:cont, [Result(i64, String).Ok(100 / item)], %DivideStage{}}
    } else {
      {:halt, [Result(i64, String).Error("non-positive divisor")], %DivideStage{}}
    }
  }

  pub fn flush(_stage :: unique DivideStage) -> [Result(i64, String)] {
    ([] :: [Result(i64, String)])
  }
}

pub struct ResultOutputStageTest {
  use Zest.Case

  describe("a Result-output stage carries errors as values") {
    test("emits Result.Ok elements then a terminal Result.Error and halts") {
      result = Enum.to_list(Stream.transform([2, 4, -1, 5], %DivideStage{}))
      assert(List.length(result) == 3)
      first_ok = case List.head(result) {
        Result.Ok(value) -> value == 50
        Result.Error(_) -> false
      }
      second_ok = case List.at(result, 1) {
        Result.Ok(value) -> value == 25
        Result.Error(_) -> false
      }
      last_is_error = case List.last(result) {
        Result.Ok(_) -> false
        Result.Error(reason) -> reason == "non-positive divisor"
      }
      assert(first_ok)
      assert(second_ok)
      assert(last_is_error)
    }

    test("an all-valid source yields only Result.Ok and flushes empty") {
      result = Enum.to_list(Stream.transform([1, 2, 5], %DivideStage{}))
      assert(List.length(result) == 3)
      head_ok = case List.head(result) {
        Result.Ok(value) -> value == 100
        Result.Error(_) -> false
      }
      mid_ok = case List.at(result, 1) {
        Result.Ok(value) -> value == 50
        Result.Error(_) -> false
      }
      last_ok = case List.last(result) {
        Result.Ok(value) -> value == 20
        Result.Error(_) -> false
      }
      assert(head_ok)
      assert(mid_ok)
      assert(last_ok)
    }

    test("an immediate failure yields a single Result.Error") {
      result = Enum.to_list(Stream.transform([0, 1, 2], %DivideStage{}))
      assert(List.length(result) == 1)
      only_error = case List.head(result) {
        Result.Ok(_) -> false
        Result.Error(reason) -> reason == "non-positive divisor"
      }
      assert(only_error)
    }
  }

  describe("Result-output stages are memory-clean under both managers") {
    test("driving a Result stage to its terminal error is fault-free") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.transform([2, 4, -1, 5], %DivideStage{}))
        assert(List.length(result) == 3)
        last_is_error = case List.last(result) {
          Result.Ok(_) -> false
          Result.Error(reason) -> reason == "non-positive divisor"
        }
        assert(last_is_error)
      }
    }

    test("halting a Result stage early releases the buffered error leak-free") {
      assert_no_leaks {
        taken = Enum.take(Stream.transform([3, -1, 4], %DivideStage{}), 2)
        assert(List.length(taken) == 2)
        last_is_error = case List.last(taken) {
          Result.Ok(_) -> false
          Result.Error(reason) -> reason == "non-positive divisor"
        }
        assert(last_is_error)
      }
    }
  }
}
