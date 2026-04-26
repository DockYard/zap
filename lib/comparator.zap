@doc = """
  Protocol for types that support comparison.

  Any type implementing `Comparator` participates in `==`, `!=`, `<`,
  `>`, `<=`, and `>=`. The compiler dispatches each operator to the
  matching impl based on the left operand's type at compile time.

  Built-in implementations exist for `Integer` (i64), `Float` (f64),
  and `String`. Define `impl Comparator for MyType { ... }` to add
  support for user-defined comparable types.
  """

pub protocol Comparator {
  fn ==(left, right) -> Bool
  fn !=(left, right) -> Bool
  fn <(left, right) -> Bool
  fn >(left, right) -> Bool
  fn <=(left, right) -> Bool
  fn >=(left, right) -> Bool
}
