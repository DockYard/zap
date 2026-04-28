@doc = """
  Protocol for types that can answer "is value in this collection?".

  The `in` operator desugars to `Membership.member?/2`, so any type
  with a `Membership` impl supports `value in collection`. Built-in
  implementations cover `List`, `String`, `Map`, and `Range`. User
  types can implement it the same way.

  ## Examples

      2 in [1, 2, 3]            # true
      "el" in "hello"           # true (substring check)
      :foo in %{foo: 1}         # true (key membership)
      5 in 1..10                # true (numeric range)
  """

pub protocol Membership {
  fn member?(collection, value) -> Bool
}
