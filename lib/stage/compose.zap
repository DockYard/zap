@doc = """
  A `Stage` that fuses two stages into one: it feeds every output of `first`
  through `second`, so `ComposeStage(a, b, c)` behaves as a single
  `Stage(a, c)`.

  `ComposeStage(a, b, c)` is the stage behind `Stream.compose/2`. It holds the
  two inner stages as boxed `Stage` fields plus a flag recording whether
  `second` has already halted (so its `flush` — required exactly once by the
  `Stage` contract — is honoured without ever stepping it again).

  ## Threading and halt propagation

  `step(item)` runs `first.step(item)`, then threads each intermediate `b`
  output through `second.step` in order, concatenating the `c` outputs and
  carrying `second`'s state forward. The composite halts if EITHER inner halts:
  when `second` halts partway through `first`'s outputs, the remaining outputs
  are dropped and the composite halts after emitting what `second` produced.

  ## Flush ordering (pipeline flush)

  `flush` runs `first.flush` to drain any state buffered in `first` (e.g. a
  `ChunkEvery`'s final partial group), threads those final outputs through
  `second.step`, and only THEN runs `second.flush` — so a buffering `first`
  correctly flushes into `second` before `second` itself completes.
  """

pub struct ComposeStage(a, b, c) {
  first :: Stage(a, b)
  second :: Stage(b, c)
  second_halted :: Bool
}

@doc = """
  The composed `Stage` behaviour: thread `first`'s outputs through `second`,
  propagating an early halt from either inner stage and draining `first` into
  `second` on flush before `second` completes.
  """

pub impl Stage(a, c) for ComposeStage(a, b, c) {
  @doc = """
    Runs `first.step(item)`, threads each intermediate output through
    `second.step`, and returns the concatenated `c` outputs. Halts when either
    inner stage halts.
    """

  pub fn step(stage :: unique ComposeStage(a, b, c), item :: a) -> {Atom, [c], ComposeStage(a, b, c)} {
    ComposeStage.step_parts(stage.first, stage.second, stage.second_halted, item)
  }

  @doc = """
    Drains `first.flush` into `second.step`, then runs `second.flush`, and
    concatenates all resulting `c` outputs — the pipeline-flush ordering.
    """

  pub fn flush(stage :: unique ComposeStage(a, b, c)) -> [c] {
    ComposeStage.flush_parts(stage.first, stage.second, stage.second_halted)
  }

  fn step_parts(first :: unique Stage(a, b), second :: unique Stage(b, c), _second_halted :: Bool, item :: a) -> {Atom, [c], ComposeStage(a, b, c)} {
    case Stage.step(first, item) {
      {first_decision, intermediate_outputs, first_next} -> ComposeStage.after_first(first_decision, first_next, second, intermediate_outputs)
    }
  }

  fn after_first(first_decision :: Atom, first_next :: unique Stage(a, b), second :: unique Stage(b, c), intermediate_outputs :: [b]) -> {Atom, [c], ComposeStage(a, b, c)} {
    case ComposeStage.feed(second, intermediate_outputs, ([] :: [c])) {
      {outputs, second_next, second_halted} -> ComposeStage.assemble(first_decision, second_halted, outputs, first_next, second_next)
    }
  }

  fn assemble(first_decision :: Atom, second_halted :: Bool, outputs :: [c], first_next :: unique Stage(a, b), second_next :: unique Stage(b, c)) -> {Atom, [c], ComposeStage(a, b, c)} {
    if second_halted {
      {:halt, outputs, %ComposeStage(a, b, c){first: first_next, second: second_next, second_halted: true}}
    } else {
      {first_decision, outputs, %ComposeStage(a, b, c){first: first_next, second: second_next, second_halted: false}}
    }
  }

  fn flush_parts(first :: unique Stage(a, b), second :: unique Stage(b, c), second_halted :: Bool) -> [c] {
    intermediate_leftover = Stage.flush(first)
    if second_halted {
      ComposeStage.drop_intermediate(intermediate_leftover)
      Stage.flush(second)
    } else {
      ComposeStage.flush_through(second, intermediate_leftover)
    }
  }

  fn flush_through(second :: unique Stage(b, c), intermediate_leftover :: [b]) -> [c] {
    case ComposeStage.feed(second, intermediate_leftover, ([] :: [c])) {
      {outputs, second_next, _second_halted} -> ComposeStage.finish_flush(second_next, outputs)
    }
  }

  # `second_next` binds through a typed parameter so its `Stage(b, c)` protocol
  # type is recovered from the tuple destructuring before it is dispatched on
  # (a protocol-existential drawn straight out of a tuple pattern otherwise
  # loses its constraint — the same reason `after_first` threads `first_next`
  # through `assemble`).
  fn finish_flush(second :: unique Stage(b, c), outputs :: [c]) -> [c] {
    List.concat(outputs, Stage.flush(second))
  }

  fn feed(second :: unique Stage(b, c), items :: [b], accumulator :: [c]) -> {[c], Stage(b, c), Bool} {
    case items {
      [] -> {accumulator, second, false}
      [head | rest] -> ComposeStage.feed_one(second, head, rest, accumulator)
    }
  }

  fn feed_one(second :: unique Stage(b, c), head :: b, rest :: [b], accumulator :: [c]) -> {[c], Stage(b, c), Bool} {
    case Stage.step(second, head) {
      {:cont, outputs, second_next} -> ComposeStage.feed(second_next, rest, List.concat(accumulator, outputs))
      {:halt, outputs, second_next} -> ComposeStage.feed_halted(second_next, rest, List.concat(accumulator, outputs))
    }
  }

  fn feed_halted(second :: unique Stage(b, c), rest :: [b], accumulator :: [c]) -> {[c], Stage(b, c), Bool} {
    ComposeStage.drop_intermediate(rest)
    {accumulator, second, true}
  }

  fn drop_intermediate(_items :: [b]) -> Nil {
    nil
  }
}
