@doc = """
  Enumerable implementation for `List`.
  """

pub impl Enumerable(member) for List(member) {
  @doc = """
    Returns the next element from a list.

    The list itself is the iteration state. Each call consumes the current
    state and returns `{:cont, head, next_state}` for non-empty lists, or
    `{:done, default, []}` for empty lists. The returned next state may be
    cursor-backed by the runtime, but it satisfies the public `List(member)`
    contract.
    """

  pub fn next(list :: unique List(member)) -> {Atom, member, List(member)} {
    :zig.List.next(list)
  }

  @doc = """
    Releases an unconsumed list iteration state.

    Cursor-backed list states own runtime resources when iteration stops
    before reaching `:done`; disposing the state releases that cursor
    directly without walking the remaining elements.
    """

  pub fn dispose(list :: unique List(member)) -> Nil {
    :zig.List.release(list)
    nil
  }
}
