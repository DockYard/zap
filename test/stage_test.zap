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

# A fallible stage: passes positive items through as `Result.Ok`, and on the
# first non-positive item emits a `Result.Error(...)` carrying a `String`
# reason and halts. This is the canonical fallibility shape `Stage` documents
# ("Fallibility is a value, never a raise"): the `output` is a `Result`,
# errors flow as ordinary emitted output elements — never as raises — and the
# error is the final element the stream yields.
pub struct FallibleStage {
}

pub impl Stage(i64, Result(i64, String)) for FallibleStage {
  pub fn step(_stage :: unique FallibleStage, item :: i64) -> {Atom, [Result(i64, String)], FallibleStage} {
    if item > 0 {
      FallibleStage.emit_ok(item)
    } else {
      FallibleStage.emit_error()
    }
  }

  pub fn flush(_stage :: unique FallibleStage) -> [Result(i64, String)] {
    ([] :: [Result(i64, String)])
  }

  fn emit_ok(item :: i64) -> {Atom, [Result(i64, String)], FallibleStage} {
    {:cont, [Result(i64, String).Ok(item)], %FallibleStage{}}
  }

  fn emit_error() -> {Atom, [Result(i64, String)], FallibleStage} {
    {:halt, [Result(i64, String).Error("non-positive item")], %FallibleStage{}}
  }
}

# A stage that PANICS if the driver ever calls `step` after it returned
# `:halt`, or calls `flush` more than once. Threaded through the pull driver on
# both the natural-end and early-consumer paths, it turns the "no step after
# halt, exactly one flush" contract into a checkable runtime property.
pub struct ContractStage {
  halted :: Bool
  flushed :: Bool
  limit :: i64
  seen :: i64
}

pub impl Stage(i64, i64) for ContractStage {
  pub fn step(stage :: unique ContractStage, item :: i64) -> {Atom, [i64], ContractStage} {
    ContractStage.decide(stage.halted, stage.flushed, stage.limit, stage.seen, item)
  }

  pub fn flush(stage :: unique ContractStage) -> [i64] {
    if stage.flushed {
      panic("ContractStage flushed twice")
    } else {
      ([] :: [i64])
    }
  }

  fn decide(halted :: Bool, flushed :: Bool, limit :: i64, seen :: i64, item :: i64) -> {Atom, [i64], ContractStage} {
    if halted {
      panic("ContractStage stepped after halt")
    } else {
      if seen + 1 >= limit {
        {:halt, [item], %ContractStage{halted: true, flushed: flushed, limit: limit, seen: seen + 1}}
      } else {
        {:cont, [item], %ContractStage{halted: false, flushed: flushed, limit: limit, seen: seen + 1}}
      }
    }
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
      head_ok = case List.head(result) {
        Result.Ok(value) -> value == 1
        Result.Error(_) -> false
      }
      second_ok = case List.at(result, 1) {
        Result.Ok(value) -> value == 2
        Result.Error(_) -> false
      }
      last_is_error = case List.last(result) {
        Result.Ok(_) -> false
        Result.Error(reason) -> reason == "non-positive item"
      }
      assert(head_ok)
      assert(second_ok)
      assert(last_is_error)
    }
  }

  describe("driver honours the stage contract") {
    test("no step after halt and exactly one flush on the natural drive") {
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], %ContractStage{halted: false, flushed: false, limit: 3, seen: 0}))
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }

    test("no step after halt when an early consumer stops the drive") {
      result = Enum.take(Stream.transform([1, 2, 3, 4, 5], %ContractStage{halted: false, flushed: false, limit: 10, seen: 0}), 2)
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
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

  describe("Stream.compose fuses two stages") {
    test("compose(map, filter) equals filter after map") {
      composed = Stream.compose(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value * value }}, %FilterStage(i64){predicate: fn(value :: i64) -> Bool { value > 4 }})
      result = Enum.to_list(Stream.transform([1, 2, 3, 4], composed))
      assert(List.length(result) == 2)
      assert(List.head(result) == 9)
      assert(List.last(result) == 16)
    }

    test("compose drains a buffering first (chunk_every) into second on flush") {
      composed = Stream.compose(%ChunkEveryStage(i64){count: 2, buffer: ([] :: [i64])}, %MapStage([i64], i64){callback: fn(chunk :: [i64]) -> i64 { List.length(chunk) }})
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], composed))
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
      assert(List.last(result) == 1)
    }

    test("compose a length-prefixed framer with a decoder stage") {
      decoder = %MapStage(Result(String, FramingError), i64){callback: fn(frame :: Result(String, FramingError)) -> i64 { StageTest.decode_frame_length(frame) }}
      composed = Stream.compose(Framer.length_prefixed(2, 1024), decoder)
      wire = length_prefixed_frame("abc") <> length_prefixed_frame("de")
      result = Enum.to_list(Stream.transform([wire], composed))
      assert(List.length(result) == 2)
      assert(List.head(result) == 3)
      assert(List.last(result) == 2)
    }

    test("a halt in the first stage propagates through the composite") {
      composed = Stream.compose(%TakeStage(i64){count: 2}, %MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value + 100 }})
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], composed))
      assert(List.length(result) == 2)
      assert(List.head(result) == 101)
      assert(List.last(result) == 102)
    }

    test("a halt in the second stage propagates through the composite") {
      composed = Stream.compose(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value + 100 }}, %TakeStage(i64){count: 2})
      result = Enum.to_list(Stream.transform([1, 2, 3, 4, 5], composed))
      assert(List.length(result) == 2)
      assert(List.head(result) == 101)
      assert(List.last(result) == 102)
    }

    test("compose is associative on a three-stage pipeline") {
      left_nested = Stream.compose(Stream.compose(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value + 1 }}, %MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value * 2 }}), %MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value - 3 }})
      right_nested = Stream.compose(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value + 1 }}, Stream.compose(%MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value * 2 }}, %MapStage(i64, i64){callback: fn(value :: i64) -> i64 { value - 3 }}))
      result_left = Enum.to_list(Stream.transform([1, 2, 3], left_nested))
      result_right = Enum.to_list(Stream.transform([1, 2, 3], right_nested))
      assert(List.length(result_left) == 3)
      assert(List.length(result_right) == 3)
      assert(List.head(result_left) == 1)
      assert(List.head(result_right) == 1)
      assert(List.last(result_left) == 5)
      assert(List.last(result_right) == 5)
    }

    test("a composed String pipeline halted early is leak-free") {
      assert_no_leaks {
        composed = Stream.compose(%MapStage(String, String){callback: fn(value :: String) -> String { value <> "!" }}, %TakeStage(String){count: 2})
        result = Enum.to_list(Stream.transform(["a", "b", "c", "d"], composed))
        assert(List.length(result) == 2)
        assert(List.head(result) == "a!")
        assert(List.last(result) == "b!")
      }
    }
  }

  # Build a 2-byte big-endian length-prefixed frame for the framer-compose test.
  fn length_prefixed_frame(payload :: String) -> String {
    length = String.length(payload)
    String.from_byte(length / 256) <> String.from_byte(length) <> payload
  }

  # Decode a framed Result into its payload length, or -1 on a framing error.
  fn decode_frame_length(frame :: Result(String, FramingError)) -> i64 {
    case frame {
      Result.Ok(payload) -> String.length(payload)
      Result.Error(_error) -> -1
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
