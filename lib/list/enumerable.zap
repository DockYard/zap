@doc = """
  Enumerable implementation for `List`.
  """

pub impl Enumerable(member) for List(member) {
  @doc = """
    Returns the next element from a list.

    The list itself is the iteration state. Returns `{:cont, head, tail}`
    for non-empty lists, or `{:done, default, []}` for empty lists.
    """

  pub fn next(list :: List(member)) -> {Atom, member, List(member)} {
    :zig.List.next(list)
  }
}
