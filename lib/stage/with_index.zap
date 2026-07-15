@doc = """
  A `Stage` that pairs every item with its zero-based position, emitting
  `{item, index}` tuples.

  `WithIndexStage(element)` is the stage behind `Stream.with_index/1`. It
  carries the next index as explicit scalar state.
  """

pub struct WithIndexStage(element) {
  index :: i64
}

@doc = """
  The indexing `Stage` behaviour: emit each item paired with an incrementing
  index.
  """

pub impl Stage(element, {element, i64}) for WithIndexStage(element) {
  @doc = """
    Emits `{item, index}` and advances the index by one.
    """

  pub fn step(stage :: unique WithIndexStage(element), item :: element) -> {Atom, [{element, i64}], WithIndexStage(element)} {
    WithIndexStage.emit_indexed(stage.index, item)
  }

  @doc = """
    Emits nothing on flush — indexing buffers no state.
    """

  pub fn flush(_stage :: unique WithIndexStage(element)) -> [{element, i64}] {
    ([] :: [{element, i64}])
  }

  fn emit_indexed(index :: i64, item :: element) -> {Atom, [{element, i64}], WithIndexStage(element)} {
    {:cont, [{item, index}], %WithIndexStage(element){index: index + 1}}
  }
}
