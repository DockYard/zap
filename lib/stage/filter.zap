@doc = """
  A `Stage` that keeps only the items for which a predicate returns `true`.

  `Stage.Filter(element)` is the stage behind `Stream.filter/2`. Rejected items
  emit an empty output list, which the pull driver treats as demand for the
  next source item.
  """

pub struct Stage.Filter(element) {
  predicate :: Callable({element}, Bool)
}

@doc = """
  The filtering `Stage` behaviour: emit the item when the predicate holds,
  otherwise emit nothing.
  """

pub impl Stage(element, element) for Stage.Filter(element) {
  @doc = """
    Emits `[item]` when the predicate returns `true`, otherwise `[]`.
    """

  pub fn step(stage :: unique Stage.Filter(element), item :: element) -> {Atom, [element], Stage.Filter(element)} {
    Stage.Filter.decide(stage.predicate, item)
  }

  @doc = """
    Emits nothing on flush — a filter buffers no state.
    """

  pub fn flush(_stage :: unique Stage.Filter(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), item :: element) -> {Atom, [element], Stage.Filter(element)} {
    if Callable.call(predicate, {item}) {
      {:cont, [item], %Stage.Filter(element){predicate: predicate}}
    } else {
      {:cont, ([] :: [element]), %Stage.Filter(element){predicate: predicate}}
    }
  }
}
