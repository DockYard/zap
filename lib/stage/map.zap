@doc = """
  A `Stage` that applies a callback to every item, emitting exactly one
  transformed output per input.

  `Stage.Map(input, output)` is the stage behind `Stream.map/2`. Its callback
  is stored as a `Callable` existential so a capturing closure survives being
  threaded through the stage state.
  """

pub struct Stage.Map(input, output) {
  callback :: Callable({input}, output)
}

@doc = """
  The mapping `Stage` behaviour: one output per input, never halting on its
  own, nothing buffered to flush.
  """

pub impl Stage(input, output) for Stage.Map(input, output) {
  @doc = """
    Applies the callback to `item` and emits the single result, continuing.
    """

  pub fn step(stage :: unique Stage.Map(input, output), item :: input) -> {Atom, [output], Stage.Map(input, output)} {
    Stage.Map.apply(stage.callback, item)
  }

  @doc = """
    Emits nothing on flush — a map buffers no state.
    """

  pub fn flush(_stage :: unique Stage.Map(input, output)) -> [output] {
    ([] :: [output])
  }

  fn apply(callback :: Callable({input}, output), item :: input) -> {Atom, [output], Stage.Map(input, output)} {
    {:cont, [Callable.call(callback, {item})], %Stage.Map(input, output){callback: callback}}
  }
}
