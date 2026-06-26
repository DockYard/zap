@doc = """
  Enumerable implementation for `Range`.
  """

pub impl Enumerable(i64) for Range {
  @doc = """
    Returns the next value from a range.

    The Range struct is its own iteration state — `start` tracks
    the current position. Returns `{:cont, current, next_range}`
    or `{:done, 0, range}` when iteration is complete.
    """

  pub fn next(range :: unique Range) -> {Atom, i64, Range} {
    :zig.Range.next(range)
  }

  @doc = """
    Disposes a range iteration state.

    Range states are plain values and own no cursor resources, so disposal
    is a no-op.
    """

  pub fn dispose(_range :: unique Range) -> Nil {
    nil
  }
}
