@doc = """
  The terminal `Stage` sentinel: a zero-field stage that emits nothing and
  halts on any input.

  `EmptyStage(input, output)` is the internal marker `Stream.transform`
  installs once a pipeline has been drained — after the real stage has been
  flushed and the source disposed, the reconstructed terminal `Transform`
  carries an `EmptyStage` so its type stays well-formed while it only ever
  reports completion. It is never handed to user code.

  Its `step` and `flush` return freshly constructed values rather than
  returning `self`: a zero-field boxed struct returning itself unchanged
  exercises a narrow lowering edge, so the sentinel always reconstructs.
  """

pub struct EmptyStage(input, output) {
}

@doc = """
  The terminal-sentinel `Stage` behaviour: halt immediately, emit nothing.
  """

pub impl Stage(input, output) for EmptyStage(input, output) {
  @doc = """
    Halts immediately and emits no output, ignoring the item. Returns a
    fresh `EmptyStage` rather than `self`.
    """

  pub fn step(_stage :: unique EmptyStage(input, output), _item :: input) -> {Atom, [output], EmptyStage(input, output)} {
    {:halt, ([] :: [output]), %EmptyStage(input, output){}}
  }

  @doc = """
    Emits nothing on flush.
    """

  pub fn flush(_stage :: unique EmptyStage(input, output)) -> [output] {
    ([] :: [output])
  }
}
