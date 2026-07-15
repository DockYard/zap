@doc = """
  A `Stage` that discards the first `count` items and passes the rest through.

  `DropStage(element)` is the stage behind `Stream.drop/2`. It carries the
  remaining drop count as explicit scalar state and reconstructs a fresh stage
  on every step (a scalar-only boxed struct must never return `self`).
  """

pub struct DropStage(element) {
  count :: i64
}

@doc = """
  The dropping `Stage` behaviour: swallow items until the count is exhausted,
  then pass everything through.
  """

pub impl Stage(element, element) for DropStage(element) {
  @doc = """
    Emits nothing while the count remains, decrementing it; once exhausted,
    emits every item.
    """

  pub fn step(stage :: unique DropStage(element), item :: element) -> {Atom, [element], DropStage(element)} {
    DropStage.decide(stage.count, item)
  }

  @doc = """
    Emits nothing on flush — a drop buffers no state.
    """

  pub fn flush(_stage :: unique DropStage(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(count :: i64, item :: element) -> {Atom, [element], DropStage(element)} {
    if count <= 0 {
      {:cont, [item], %DropStage(element){count: 0}}
    } else {
      {:cont, ([] :: [element]), %DropStage(element){count: count - 1}}
    }
  }
}
