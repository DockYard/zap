@doc = """
  A `Stage` that emits at most `count` items and then halts.

  `Stage.Take(element)` is the stage behind `Stream.take/2`. It carries a
  running countdown as explicit scalar state and reconstructs a fresh stage on
  every step (a scalar-only boxed struct must never return `self`). Halting on
  the final item lets the pull driver dispose the source without pulling one
  element too many.
  """

pub struct Stage.Take(element) {
  count :: i64
}

@doc = """
  The taking `Stage` behaviour: pass items through while the countdown lasts,
  halting on the last one.
  """

pub impl Stage(element, element) for Stage.Take(element) {
  @doc = """
    Emits the item; halts (with the item) when only one remains, or when the
    count was already exhausted (emitting nothing in that case).
    """

  pub fn step(stage :: unique Stage.Take(element), item :: element) -> {Atom, [element], Stage.Take(element)} {
    Stage.Take.decide(stage.count, item)
  }

  @doc = """
    Emits nothing on flush — a take buffers no state.
    """

  pub fn flush(_stage :: unique Stage.Take(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(count :: i64, item :: element) -> {Atom, [element], Stage.Take(element)} {
    if count <= 0 {
      {:halt, ([] :: [element]), %Stage.Take(element){count: 0}}
    } else {
      if count == 1 {
        {:halt, [item], %Stage.Take(element){count: 0}}
      } else {
        {:cont, [item], %Stage.Take(element){count: count - 1}}
      }
    }
  }
}
