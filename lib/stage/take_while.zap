@doc = """
  A `Stage` that emits items while a predicate holds, halting on the first
  item that fails it (the failing item is not emitted).

  `Stage.TakeWhile(element)` is the stage behind `Stream.take_while/2`.
  """

pub struct Stage.TakeWhile(element) {
  predicate :: Callable({element}, Bool)
}

@doc = """
  The take-while `Stage` behaviour: pass items through until the predicate
  first fails, then halt.
  """

pub impl Stage(element, element) for Stage.TakeWhile(element) {
  @doc = """
    Emits `[item]` and continues while the predicate holds; on the first
    failing item, halts emitting nothing.
    """

  pub fn step(stage :: unique Stage.TakeWhile(element), item :: element) -> {Atom, [element], Stage.TakeWhile(element)} {
    Stage.TakeWhile.decide(stage.predicate, item)
  }

  @doc = """
    Emits nothing on flush — a take-while buffers no state.
    """

  pub fn flush(_stage :: unique Stage.TakeWhile(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), item :: element) -> {Atom, [element], Stage.TakeWhile(element)} {
    if Callable.call(predicate, {item}) {
      {:cont, [item], %Stage.TakeWhile(element){predicate: predicate}}
    } else {
      {:halt, ([] :: [element]), %Stage.TakeWhile(element){predicate: predicate}}
    }
  }
}
