@doc = """
  Protocol for types that support concatenation via the `<>` operator.

  The `<>` macro in Kernel dispatches through `Concatenable.concat/2`,
  so any type that implements this protocol opts in to operator support.
  Built-in implementations cover `String`, `List`, and `Map`. User types
  can implement it the same way (define `pub impl Concatenable for T`
  with a `concat/2` clause).

  ## Examples

      "foo" <> "bar"           # String concat
      [1, 2] <> [3, 4]         # List concat
      %{a: 1} <> %{b: 2}       # Map merge
  """

pub protocol Concatenable {
  fn concat(left, right) -> any
}
