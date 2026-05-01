@doc = """
  Protocol for types that can be iterated.

  Any type implementing Enumerable can be used with `for`
  comprehensions and `Enum` functions.

  Implementors provide `next/1` which takes an iteration state
  and returns `{:cont, value, next_state}` to yield a value,
  or `{:done, ignored_value, state}` when iteration is complete.

  For lists, the list itself is the state.
  For ranges, the Range struct is the initial state.
  """

pub protocol Enumerable {
  fn next(state) -> {Atom, any, any}
}
