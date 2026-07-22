@doc = """
  A `Stage` that threads an accumulator through the stream, emitting the
  running accumulator after each item.

  `Stage.Scan(input, accumulator)` is the stage behind `Stream.scan/3`. The
  reducer receives `(accumulator, item)` — the same argument order as
  `Enum.reduce/3` — and returns the next accumulator, which is both emitted
  and carried into the next step.
  """

pub struct Stage.Scan(input, accumulator) {
  state :: accumulator
  reducer :: Callable({accumulator, input}, accumulator)
}

@doc = """
  The scanning `Stage` behaviour: fold the item into the accumulator and emit
  the new accumulator.
  """

pub impl Stage(input, accumulator) for Stage.Scan(input, accumulator) {
  @doc = """
    Computes the next accumulator from `(state, item)`, emits it, and carries
    it forward as the new state.
    """

  pub fn step(stage :: unique Stage.Scan(input, accumulator), item :: input) -> {Atom, [accumulator], Stage.Scan(input, accumulator)} {
    Stage.Scan.advance(stage.state, stage.reducer, item)
  }

  @doc = """
    Emits nothing on flush — every accumulator is emitted eagerly at step
    time.
    """

  pub fn flush(_stage :: unique Stage.Scan(input, accumulator)) -> [accumulator] {
    ([] :: [accumulator])
  }

  fn advance(state :: accumulator, reducer :: Callable({accumulator, input}, accumulator), item :: input) -> {Atom, [accumulator], Stage.Scan(input, accumulator)} {
    next_state = Callable.call(reducer, {state, item})
    {:cont, [next_state], %Stage.Scan(input, accumulator){state: next_state, reducer: reducer}}
  }
}
