@doc = """
  A `Stage` that emits at most `count` items and then halts.

  `TakeStage(element)` is the stage behind `Stream.take/2`. It carries a
  running countdown as explicit scalar state and reconstructs a fresh stage on
  every step (a scalar-only boxed struct must never return `self`). Halting on
  the final item lets the pull driver dispose the source without pulling one
  element too many.
  """

pub struct TakeStage(element) {
  count :: i64
}

@doc = """
  The taking `Stage` behaviour: pass items through while the countdown lasts,
  halting on the last one.
  """

pub impl Stage(element, element) for TakeStage(element) {
  @doc = """
    Emits the item; halts (with the item) when only one remains, or when the
    count was already exhausted (emitting nothing in that case).
    """

  pub fn step(stage :: unique TakeStage(element), item :: element) -> {Atom, [element], TakeStage(element)} {
    TakeStage.decide(stage.count, item)
  }

  @doc = """
    Emits nothing on flush — a take buffers no state.
    """

  pub fn flush(_stage :: unique TakeStage(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(count :: i64, item :: element) -> {Atom, [element], TakeStage(element)} {
    if count <= 0 {
      {:halt, ([] :: [element]), %TakeStage(element){count: 0}}
    } else {
      if count == 1 {
        {:halt, [item], %TakeStage(element){count: 0}}
      } else {
        {:cont, [item], %TakeStage(element){count: count - 1}}
      }
    }
  }
}
