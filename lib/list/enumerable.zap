pub impl Enumerable for List {
  @doc = """
    Returns the next element from a list.

    The list itself is the iteration state.
    Returns `{:cont, head, tail}` for non-empty lists,
    or `{:done, 0, []}` for empty lists.
    """

  pub fn next(list :: [member]) -> {Atom, member, [member]} {
    :zig.List.next(list)
  }
}
