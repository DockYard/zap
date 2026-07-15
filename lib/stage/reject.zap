@doc = """
  A `Stage` that drops the items for which a predicate returns `true` — the
  complement of `FilterStage`.

  `RejectStage(element)` is the stage behind `Stream.reject/2`.
  """

pub struct RejectStage(element) {
  predicate :: Callable({element}, Bool)
}

@doc = """
  The rejecting `Stage` behaviour: emit the item when the predicate is
  `false`, otherwise emit nothing.
  """

pub impl Stage(element, element) for RejectStage(element) {
  @doc = """
    Emits `[item]` when the predicate returns `false`, otherwise `[]`.
    """

  pub fn step(stage :: unique RejectStage(element), item :: element) -> {Atom, [element], RejectStage(element)} {
    RejectStage.decide(stage.predicate, item)
  }

  @doc = """
    Emits nothing on flush — a reject buffers no state.
    """

  pub fn flush(_stage :: unique RejectStage(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), item :: element) -> {Atom, [element], RejectStage(element)} {
    if Callable.call(predicate, {item}) {
      {:cont, ([] :: [element]), %RejectStage(element){predicate: predicate}}
    } else {
      {:cont, [item], %RejectStage(element){predicate: predicate}}
    }
  }
}
