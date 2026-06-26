@doc = """
  Protocol for types that can be iterated.

  Any type implementing Enumerable can be used with `for`
  comprehensions and `Enum` functions.

  Implementors provide `next/1` which consumes an iteration state and
  returns `{:cont, value, next_state}` to yield a value, or
  `{:done, ignored_value, state}` when iteration is complete.

  The returned `next_state` is the value to pass to the next
  `Enumerable.next/1` call. Implementations may use cursor-backed state
  internally, but the state must continue to satisfy the same public
  collection contract as the implementation's declared return type.

  Implementors also provide `dispose/1` so callers that intentionally
  stop early can release any resources owned by an unconsumed iteration
  state without walking the rest of the collection.
  """

pub protocol Enumerable(element) {
  fn next(state :: unique Enumerable(element)) -> {Atom, element, Enumerable(element)}
  fn dispose(state :: unique Enumerable(element)) -> Nil
}
