pub impl Enumerable for Range {
  @doc = """
    Returns the next value from a range.

    The Range struct is its own iteration state — `start` tracks
    the current position. Returns `{:cont, current, next_range}`
    or `{:done, 0, range}` when iteration is complete.
    """

  pub fn next(range :: Range) -> {Atom, i64, Range} {
    :zig.Range.next(range)
  }
}
