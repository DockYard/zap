@doc = """
  STEP-0 integration probe for the Stage/Stream campaign. Exercises every
  compiler shape the real implementation depends on that was NOT already
  covered by a committed regression probe:

  1. A 2-type-parameter struct (`ProbeTransform(input, output)`) implementing
     a 1-type-parameter protocol (`Enumerable(output)`), genuinely boxed and
     driven to `:done` AND early-disposed.
  2. The empty-list type-variable sentinel `([] :: [T])` boxed as
     `Enumerable(T)` — returns `:done` and manufactures the ignored element.
  3. The zero-field `ProbeEmpty(input, output)` sentinel boxed as a 2-param
     protocol, moved through reconstructs, step/flush returning fresh values.
  4. A 1-type-parameter struct (`ProbeTake(element)`) implementing a 2-param
     protocol (`ProbeStage(element, element)`), boxed.
  5. String (ARC) payloads through the full transform, to `:done` AND
     early-halt+dispose.

  All memory-sensitive operations are wrapped in `assert_no_leaks` /
  `assert_no_memory_faults` so a single file verifies cleanliness under both
  the default (ARC) and `Memory.Tracking` binaries.
  """

pub protocol ProbeStage(input, output) {
  fn step(stage :: unique ProbeStage(input, output), item :: input) -> {Atom, [output], ProbeStage(input, output)}
  fn flush(stage :: unique ProbeStage(input, output)) -> [output]
}

# 2-param struct -> 2-param protocol (stateless, ARC closure field): may return self.
pub struct ProbeMap(input, output) {
  callback :: fn(input) -> output
}

pub impl ProbeStage(input, output) for ProbeMap(input, output) {
  pub fn step(stage :: unique ProbeMap(input, output), item :: input) -> {Atom, [output], ProbeMap(input, output)} {
    {:cont, [stage.callback(item)], stage}
  }

  pub fn flush(stage :: unique ProbeMap(input, output)) -> [output] {
    ProbeMap.drop_callback(stage)
    ([] :: [output])
  }

  fn drop_callback(_stage :: unique ProbeMap(input, output)) -> Nil {
    nil
  }
}

# 1-param struct -> 2-param protocol Stage(element, element) (stateful scalar): reconstruct, never self.
pub struct ProbeTake(element) {
  count :: i64
}

pub impl ProbeStage(element, element) for ProbeTake(element) {
  pub fn step(stage :: unique ProbeTake(element), item :: element) -> {Atom, [element], ProbeTake(element)} {
    if stage.count <= 1 {
      {:halt, [item], %ProbeTake(element){count: 0}}
    } else {
      {:cont, [item], %ProbeTake(element){count: stage.count - 1}}
    }
  }

  pub fn flush(_stage :: unique ProbeTake(element)) -> [element] {
    ([] :: [element])
  }
}

# Zero-field sentinel stage: step/flush return FRESH values, never self.
pub struct ProbeEmpty(input, output) {
}

pub impl ProbeStage(input, output) for ProbeEmpty(input, output) {
  pub fn step(_stage :: unique ProbeEmpty(input, output), _item :: input) -> {Atom, [output], ProbeEmpty(input, output)} {
    {:halt, ([] :: [output]), %ProbeEmpty(input, output){}}
  }

  pub fn flush(_stage :: unique ProbeEmpty(input, output)) -> [output] {
    ([] :: [output])
  }
}

# The demand-driven adapter: 2-param struct boxed as 1-param Enumerable(output).
pub struct ProbeTransform(input, output) {
  source :: Enumerable(input)
  stage :: ProbeStage(input, output)
  pending :: [output]
}

pub impl Enumerable(output) for ProbeTransform(input, output) {
  pub fn next(self :: unique ProbeTransform(input, output)) -> {Atom, output, ProbeTransform(input, output)} {
    case self.pending {
      [head | rest] -> {:cont, head, %ProbeTransform(input, output){source: self.source, stage: self.stage, pending: rest}}
      [] -> ProbeTransform.pull(self.source, self.stage)
    }
  }

  pub fn dispose(self :: unique ProbeTransform(input, output)) -> Nil {
    ProbeTransform.dispose_parts(self.source, self.stage, self.pending)
  }

  fn dispose_parts(source :: unique Enumerable(input), stage :: unique ProbeStage(input, output), pending :: [output]) -> Nil {
    Enumerable.dispose(source)
    ProbeTransform.drop_stage(stage)
    ProbeTransform.drop_pending(pending)
    nil
  }

  fn drop_stage(_stage :: unique ProbeStage(input, output)) -> Nil {
    nil
  }

  fn drop_pending(_pending :: [output]) -> Nil {
    nil
  }

  fn pull(source :: unique Enumerable(input), stage :: unique ProbeStage(input, output)) -> {Atom, output, ProbeTransform(input, output)} {
    case Enumerable.next(source) {
      {:done, _, exhausted} -> ProbeTransform.on_source_done(exhausted, stage)
      {:cont, item, next_source} -> ProbeTransform.on_item(next_source, stage, item)
    }
  }

  fn on_source_done(exhausted :: unique Enumerable(input), stage :: unique ProbeStage(input, output)) -> {Atom, output, ProbeTransform(input, output)} {
    Enumerable.dispose(exhausted)
    flushed = ProbeStage.flush(stage)
    ProbeTransform.enter_terminal(flushed)
  }

  fn on_item(next_source :: unique Enumerable(input), stage :: unique ProbeStage(input, output), item :: input) -> {Atom, output, ProbeTransform(input, output)} {
    case ProbeStage.step(stage, item) {
      {:cont, outs, next_stage} -> ProbeTransform.after_cont(next_source, next_stage, outs)
      {:halt, outs, next_stage} -> ProbeTransform.after_halt(next_source, next_stage, outs)
    }
  }

  fn after_cont(next_source :: unique Enumerable(input), next_stage :: unique ProbeStage(input, output), outs :: [output]) -> {Atom, output, ProbeTransform(input, output)} {
    case outs {
      [] -> ProbeTransform.pull(next_source, next_stage)
      [head | rest] -> {:cont, head, %ProbeTransform(input, output){source: next_source, stage: next_stage, pending: rest}}
    }
  }

  fn after_halt(next_source :: unique Enumerable(input), next_stage :: unique ProbeStage(input, output), outs :: [output]) -> {Atom, output, ProbeTransform(input, output)} {
    Enumerable.dispose(next_source)
    flushed = ProbeStage.flush(next_stage)
    ProbeTransform.enter_terminal(List.concat(outs, flushed))
  }

  fn enter_terminal(remaining :: [output]) -> {Atom, output, ProbeTransform(input, output)} {
    case remaining {
      [] -> ProbeTransform.emit_done()
      [head | rest] -> {:cont, head, ProbeTransform.terminal_state(rest)}
    }
  }

  fn terminal_state(pending :: [output]) -> ProbeTransform(input, output) {
    %ProbeTransform(input, output){source: ([] :: [input]), stage: %ProbeEmpty(input, output){}, pending: pending}
  }

  fn emit_done() -> {Atom, output, ProbeTransform(input, output)} {
    case Enumerable.next(([] :: [output])) {
      {_atom, manufactured, spent} -> ProbeTransform.finish_done(manufactured, spent)
    }
  }

  fn finish_done(manufactured :: output, spent :: unique Enumerable(output)) -> {Atom, output, ProbeTransform(input, output)} {
    Enumerable.dispose(spent)
    {:done, manufactured, ProbeTransform.terminal_state(([] :: [output]))}
  }
}

# A source that panics if pulled more than `budget` times — proves exact pull count.
pub struct FuseSource {
  next_value :: i64
  budget :: i64
}

pub impl Enumerable(i64) for FuseSource {
  pub fn next(self :: unique FuseSource) -> {Atom, i64, FuseSource} {
    if self.budget <= 0 {
      panic("FuseSource over-pulled")
    } else {
      {:cont, self.next_value, %FuseSource{next_value: self.next_value + 1, budget: self.budget - 1}}
    }
  }

  pub fn dispose(_self :: unique FuseSource) -> Nil {
    nil
  }
}

pub struct Zap.StreamStep0ProbeTest {
  use Zest.Case

  describe("2-param struct boxed as 1-param Enumerable, driven to :done") {
    test("map stage over an integer list") {
      transform = build_int(%ProbeMap(i64, i64){callback: fn(value :: i64) -> i64 { value * 10 }})
      result = Enum.to_list(transform)
      assert(List.length(result) == 3)
      assert(List.head(result) == 10)
      assert(List.last(result) == 30)
    }

    test("map stage producing String (ARC) payloads to :done") {
      assert_no_memory_faults {
        transform = build_int_to_string(%ProbeMap(i64, String){callback: fn(value :: i64) -> String { Integer.to_string(value) <> "!" }})
        result = Enum.to_list(transform)
        assert(List.length(result) == 3)
        assert(List.head(result) == "1!")
        assert(List.last(result) == "3!")
      }
    }
  }

  describe("1-param stage boxed as 2-param protocol, :halt path + terminal") {
    test("take stage halts and enters terminal") {
      transform = build_int_take(%ProbeTake(i64){count: 2})
      result = Enum.to_list(transform)
      assert(List.length(result) == 2)
      assert(List.head(result) == 1)
      assert(List.last(result) == 2)
    }

    test("take over a fuse source pulls exactly the budget (no over-pull)") {
      transform = build_fuse_take(%FuseSource{next_value: 1, budget: 2}, %ProbeTake(i64){count: 2})
      result = Enum.to_list(transform)
      assert(List.length(result) == 2)
      assert(List.head(result) == 1)
      assert(List.last(result) == 2)
    }
  }

  describe("early dispose (partial consumption) is clean") {
    test("integer transform disposed after a partial take") {
      assert_no_memory_faults {
        transform = build_int(%ProbeMap(i64, i64){callback: fn(value :: i64) -> i64 { value * 10 }})
        taken = Enum.take(transform, 1)
        assert(List.length(taken) == 1)
        assert(List.head(taken) == 10)
      }
    }

    test("String transform disposed after a partial take (ARC payloads)") {
      assert_no_memory_faults {
        transform = build_string_source(%ProbeMap(String, String){callback: fn(value :: String) -> String { value <> "?" }})
        taken = Enum.take(transform, 2)
        assert(List.length(taken) == 2)
        assert(List.head(taken) == "a?")
      }
    }
  }

  fn build_int(stage :: unique ProbeStage(i64, i64)) -> Enumerable(i64) {
    %ProbeTransform(i64, i64){source: [1, 2, 3], stage: stage, pending: ([] :: [i64])}
  }

  fn build_int_to_string(stage :: unique ProbeStage(i64, String)) -> Enumerable(String) {
    %ProbeTransform(i64, String){source: [1, 2, 3], stage: stage, pending: ([] :: [String])}
  }

  fn build_int_take(stage :: unique ProbeStage(i64, i64)) -> Enumerable(i64) {
    %ProbeTransform(i64, i64){source: [1, 2, 3, 4, 5], stage: stage, pending: ([] :: [i64])}
  }

  fn build_fuse_take(source :: unique Enumerable(i64), stage :: unique ProbeStage(i64, i64)) -> Enumerable(i64) {
    %ProbeTransform(i64, i64){source: source, stage: stage, pending: ([] :: [i64])}
  }

  fn build_string_source(stage :: unique ProbeStage(String, String)) -> Enumerable(String) {
    %ProbeTransform(String, String){source: ["a", "b", "c"], stage: stage, pending: ([] :: [String])}
  }

  describe("empty-list type-variable sentinel") {
    test("integer empty list boxed as Enumerable returns :done") {
      assert(probe_empty_returns_done(([] :: [i64])))
    }

    test("String empty list boxed as Enumerable returns :done with a droppable element") {
      assert_no_memory_faults {
        assert(probe_empty_returns_done(([] :: [String])))
      }
    }
  }

  describe("zero-field Stage.Empty sentinel") {
    test("step returns fresh sentinel + halt, flush returns empty") {
      assert_no_memory_faults {
        assert(probe_empty_stage_ok())
      }
    }
  }

  fn probe_empty_returns_done(source :: unique Enumerable(element)) -> Bool {
    case Enumerable.next(source) {
      {:done, _, spent} -> dispose_and_true(spent)
      {:cont, _, spent} -> dispose_and_false(spent)
    }
  }

  fn dispose_and_true(state :: unique Enumerable(element)) -> Bool {
    Enumerable.dispose(state)
    true
  }

  fn dispose_and_false(state :: unique Enumerable(element)) -> Bool {
    Enumerable.dispose(state)
    false
  }

  fn probe_empty_stage_ok() -> Bool {
    stage = %ProbeEmpty(i64, i64){}
    case ProbeStage.step(stage, 99) {
      {halt_atom, outs, next_stage} -> finish_empty_stage(halt_atom, outs, next_stage)
    }
  }

  fn finish_empty_stage(halt_atom :: Atom, outs :: [i64], next_stage :: unique ProbeStage(i64, i64)) -> Bool {
    flushed = ProbeStage.flush(next_stage)
    (halt_atom == :halt) and (List.length(outs) == 0) and (List.length(flushed) == 0)
  }
}
