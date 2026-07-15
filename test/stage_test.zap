@doc = """
  Behavioural tests for the `Stage` protocol and the built-in stages,
  exercised both directly (`Stage.step`/`Stage.flush`) and through the pull
  driver (`Stream.transform`). Covers the protocol contract points: output
  ordering, empty-output normalcy, exactly-once flush on both the natural-end
  and early-halt paths, halt-after-emit ordering, the terminal `EmptyStage`
  sentinel, and errors-as-values carried by `:halt`.
  """

# A stage that passes items through and emits a distinctive marker exactly
# once on flush — proves flush runs exactly once at natural end.
pub struct FlushMarkerStage {
}

pub impl Stage(i64, i64) for FlushMarkerStage {
  pub fn step(_stage :: unique FlushMarkerStage, item :: i64) -> {Atom, [i64], FlushMarkerStage} {
    {:cont, [item], %FlushMarkerStage{}}
  }

  pub fn flush(_stage :: unique FlushMarkerStage) -> [i64] {
    [-999]
  }
}

# A stage that halts after emitting the second item, then emits a marker on
# flush — proves flush runs exactly once on the halt path and that halt
# outputs precede flush outputs.
pub struct HaltMarkerStage {
  seen :: i64
}

pub impl Stage(i64, i64) for HaltMarkerStage {
  pub fn step(stage :: unique HaltMarkerStage, item :: i64) -> {Atom, [i64], HaltMarkerStage} {
    HaltMarkerStage.decide(stage.seen, item)
  }

  pub fn flush(_stage :: unique HaltMarkerStage) -> [i64] {
    [-999]
  }

  fn decide(seen :: i64, item :: i64) -> {Atom, [i64], HaltMarkerStage} {
    if seen >= 1 {
      {:halt, [item], %HaltMarkerStage{seen: seen + 1}}
    } else {
      {:cont, [item], %HaltMarkerStage{seen: seen + 1}}
    }
  }
}

# A fallible stage: passes positive items through, and on the first
# non-positive item emits a distinguished error value and halts. Errors flow
# as ordinary emitted output elements, never as raises, and the error is the
# final element the stream yields.
#
# NOTE: the canonical fallible shape makes `output` a `Result` and emits
# `Result.Error(...)`. A `Result`-*output* stage cannot currently be compiled
# because a list literal of a generic-union value (`[Result(i64, String).Ok(x)]`)
# fails ZIR emit — see the campaign report. This stage therefore uses an i64
# error-sentinel to exercise the same errors-as-values + `:halt`-final-element
# contract with an output type the code generator supports.
pub struct FallibleStage {
}

pub impl Stage(i64, i64) for FallibleStage {
  pub fn step(_stage :: unique FallibleStage, item :: i64) -> {Atom, [i64], FallibleStage} {
    if item > 0 {
      FallibleStage.emit_ok(item)
    } else {
      FallibleStage.emit_error()
    }
  }

  pub fn flush(_stage :: unique FallibleStage) -> [i64] {
    ([] :: [i64])
  }

  fn emit_ok(item :: i64) -> {Atom, [i64], FallibleStage} {
    {:cont, [item], %FallibleStage{}}
  }

  fn emit_error() -> {Atom, [i64], FallibleStage} {
    {:halt, [-777], %FallibleStage{}}
  }
}

pub struct StageTest {
  use Zest.Case

  describe("built-in stages through the pull driver") {
    test("map applies the callback to every item") {
      result = Enum.to_list(Stream.transform([1, 2, 3], %MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value + 100 }}))
      assert(List.length(result) == 3)
      assert(List.head(result) == 101)
      assert(List.last(result) == 103)
    }

    test("filter keeps matching items, emitting empty for the rest") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %FilterStage(i64){predicate: fn(value :: i64) -> Bool { value > 3 }}))
      assert(List.length(result) == 2)
      assert(List.head(result) == 4)
      assert(List.last(result) == 5)
    }

    test("reject drops matching items") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4], %RejectStage(i64){predicate: fn(value :: i64) -> Bool { value > 2 }}))
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
    }

    test("take halts after the requested count") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %TakeStage(i64){count: 3}))
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }

    test("drop discards the leading count") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %DropStage(i64){count: 2}))
      assert(List.length(result) == 3)
      assert(List.head(result) == 3)
    }

    test("scan emits the running accumulator") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4], %ScanStage(i64, i64){state: 0, reducer: fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value }}))
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 10)
    }
  }

  describe("flush contract") {
    test("flush runs exactly once at natural end, after all step outputs") {
      result = Enum.to_list(Stream.transform([1, 2, 3], %FlushMarkerStage{}))
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == -999)
      assert(count_marker(result, -999) == 1)
    }

    test("flush runs exactly once on the halt path") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %HaltMarkerStage{seen: 0}))
      assert(count_marker(result, -999) == 1)
    }

    test("halt outputs precede flush outputs (ordering)") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %HaltMarkerStage{seen: 0}))
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
      assert(List.at(result, 1) == 2)
      assert(List.last(result) == -999)
    }
  }

  describe("errors are values") {
    test("a fallible stage emits an error element and halts as the final element") {
      result = Enum.to_list(Stream.transform([1, 2, -1, 3], %FallibleStage{}))
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
      assert(List.at(result, 1) == 2)
      assert(List.last(result) == -777)
    }
  }

  describe("EmptyStage terminal sentinel") {
    test("step halts emitting nothing and flush is empty") {
      case Stage.step(%EmptyStage(i64, i64){}, 42) {
        {decision, outs, next_stage} -> assert(empty_stage_ok(decision, outs, next_stage))
      }
    }
  }

  describe("stages exercised directly via Stage.step") {
    test("map step yields one output and continues") {
      case Stage.step(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value * 2 }}, 21) {
        {decision, outs, _next} -> assert(decision == :cont and List.head(outs) == 42)
      }
    }

    test("take step halts on the final item") {
      case Stage.step(%TakeStage(i64){count: 1}, 7) {
        {decision, outs, _next} -> assert(decision == :halt and List.head(outs) == 7)
      }
    }

    test("filter step emits empty for a non-match") {
      case Stage.step(%FilterStage(i64){predicate: fn(value :: i64) -> Bool { value > 100 }}, 5) {
        {decision, outs, _next} -> assert(decision == :cont and List.length(outs) == 0)
      }
    }
  }

  fn count_marker(values :: [i64], marker :: i64) -> i64 {
    List.reduce(values, 0, fn(total :: i64, value :: i64) -> i64 {
      if value == marker { total + 1 } else { total }
    })
  }

  fn empty_stage_ok(decision :: Atom, outs :: [i64], next_stage :: unique Stage(i64, i64)) -> Bool {
    flushed = Stage.flush(next_stage)
    (decision == :halt) and (List.length(outs) == 0) and (List.length(flushed) == 0)
  }
}
