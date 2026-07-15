@doc = """
  A `Stage` that emits items while a predicate holds, halting on the first
  item that fails it (the failing item is not emitted).

  `TakeWhileStage(element)` is the stage behind `Stream.take_while/2`.
  """

pub struct TakeWhileStage(element) {
  predicate :: Callable({element}, Bool)
}

@doc = """
  The take-while `Stage` behaviour: pass items through until the predicate
  first fails, then halt.
  """

pub impl Stage(element, element) for TakeWhileStage(element) {
  @doc = """
    Emits `[item]` and continues while the predicate holds; on the first
    failing item, halts emitting nothing.
    """

  pub fn step(stage :: unique TakeWhileStage(element), item :: element) -> {Atom, [element], TakeWhileStage(element)} {
    TakeWhileStage.decide(stage.predicate, item)
  }

  @doc = """
    Emits nothing on flush — a take-while buffers no state.
    """

  pub fn flush(_stage :: unique TakeWhileStage(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), item :: element) -> {Atom, [element], TakeWhileStage(element)} {
    if Callable.call(predicate, {item}) {
      {:cont, [item], %TakeWhileStage(element){predicate: predicate}}
    } else {
      {:halt, ([] :: [element]), %TakeWhileStage(element){predicate: predicate}}
    }
  }
}
