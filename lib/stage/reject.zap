@doc = """
  A `Stage` that drops the items for which a predicate returns `true` — the
  complement of `Stage.Filter`.

  `Stage.Reject(element)` is the stage behind `Stream.reject/2`.
  """

pub struct Stage.Reject(element) {
  predicate :: Callable({element}, Bool)
}

@doc = """
  The rejecting `Stage` behaviour: emit the item when the predicate is
  `false`, otherwise emit nothing.
  """

pub impl Stage(element, element) for Stage.Reject(element) {
  @doc = """
    Emits `[item]` when the predicate returns `false`, otherwise `[]`.
    """

  pub fn step(stage :: unique Stage.Reject(element), item :: element) -> {Atom, [element], Stage.Reject(element)} {
    Stage.Reject.decide(stage.predicate, item)
  }

  @doc = """
    Emits nothing on flush — a reject buffers no state.
    """

  pub fn flush(_stage :: unique Stage.Reject(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), item :: element) -> {Atom, [element], Stage.Reject(element)} {
    if Callable.call(predicate, {item}) {
      {:cont, ([] :: [element]), %Stage.Reject(element){predicate: predicate}}
    } else {
      {:cont, [item], %Stage.Reject(element){predicate: predicate}}
    }
  }
}
