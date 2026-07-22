@doc = """
  A `Stage` that pairs every item with its zero-based position, emitting
  `{item, index}` tuples.

  `Stage.WithIndex(element)` is the stage behind `Stream.with_index/1`. It
  carries the next index as explicit scalar state.
  """

pub struct Stage.WithIndex(element) {
  index :: i64
}

@doc = """
  The indexing `Stage` behaviour: emit each item paired with an incrementing
  index.
  """

pub impl Stage(element, {element, i64}) for Stage.WithIndex(element) {
  @doc = """
    Emits `{item, index}` and advances the index by one.
    """

  pub fn step(stage :: unique Stage.WithIndex(element), item :: element) -> {Atom, [{element, i64}], Stage.WithIndex(element)} {
    Stage.WithIndex.emit_indexed(stage.index, item)
  }

  @doc = """
    Emits nothing on flush — indexing buffers no state.
    """

  pub fn flush(_stage :: unique Stage.WithIndex(element)) -> [{element, i64}] {
    ([] :: [{element, i64}])
  }

  fn emit_indexed(index :: i64, item :: element) -> {Atom, [{element, i64}], Stage.WithIndex(element)} {
    {:cont, [{item, index}], %Stage.WithIndex(element){index: index + 1}}
  }
}
