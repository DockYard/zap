@doc = """
  A `Stage` that discards the first `count` items and passes the rest through.

  `Stage.Drop(element)` is the stage behind `Stream.drop/2`. It carries the
  remaining drop count as explicit scalar state and reconstructs a fresh stage
  on every step (a scalar-only boxed struct must never return `self`).
  """

pub struct Stage.Drop(element) {
  count :: i64
}

@doc = """
  The dropping `Stage` behaviour: swallow items until the count is exhausted,
  then pass everything through.
  """

pub impl Stage(element, element) for Stage.Drop(element) {
  @doc = """
    Emits nothing while the count remains, decrementing it; once exhausted,
    emits every item.
    """

  pub fn step(stage :: unique Stage.Drop(element), item :: element) -> {Atom, [element], Stage.Drop(element)} {
    Stage.Drop.decide(stage.count, item)
  }

  @doc = """
    Emits nothing on flush — a drop buffers no state.
    """

  pub fn flush(_stage :: unique Stage.Drop(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(count :: i64, item :: element) -> {Atom, [element], Stage.Drop(element)} {
    if count <= 0 {
      {:cont, [item], %Stage.Drop(element){count: 0}}
    } else {
      {:cont, ([] :: [element]), %Stage.Drop(element){count: count - 1}}
    }
  }
}
