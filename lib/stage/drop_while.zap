@doc = """
  A `Stage` that discards items while a predicate holds, then passes every
  subsequent item through — including the first item that failed the
  predicate.

  `Stage.DropWhile(element)` is the stage behind `Stream.drop_while/2`. It
  tracks whether it is still in the dropping phase as an explicit boolean and
  reconstructs a fresh stage each step.
  """

pub struct Stage.DropWhile(element) {
  predicate :: Callable({element}, Bool)
  dropping :: Bool
}

@doc = """
  The drop-while `Stage` behaviour: swallow the leading run of items that
  satisfy the predicate, then pass everything through.
  """

pub impl Stage(element, element) for Stage.DropWhile(element) {
  @doc = """
    While still dropping, emits nothing for items that satisfy the predicate;
    the first item that fails it flips the stage out of the dropping phase and
    is emitted, as is every item thereafter.
    """

  pub fn step(stage :: unique Stage.DropWhile(element), item :: element) -> {Atom, [element], Stage.DropWhile(element)} {
    Stage.DropWhile.decide(stage.predicate, stage.dropping, item)
  }

  @doc = """
    Emits nothing on flush — a drop-while buffers no state.
    """

  pub fn flush(_stage :: unique Stage.DropWhile(element)) -> [element] {
    ([] :: [element])
  }

  fn decide(predicate :: Callable({element}, Bool), dropping :: Bool, item :: element) -> {Atom, [element], Stage.DropWhile(element)} {
    if dropping {
      if Callable.call(predicate, {item}) {
        {:cont, ([] :: [element]), %Stage.DropWhile(element){predicate: predicate, dropping: true}}
      } else {
        {:cont, [item], %Stage.DropWhile(element){predicate: predicate, dropping: false}}
      }
    } else {
      {:cont, [item], %Stage.DropWhile(element){predicate: predicate, dropping: false}}
    }
  }
}
