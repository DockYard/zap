@doc = """
  Protocol for types that can be converted to a `String`.

  String interpolation `"hello \#{x}"` desugars to
  `"hello " <> Stringable.to_string(x)`, so any type with a
  `Stringable` impl can appear inside a `\#{}` interpolation. Built-in
  implementations cover `Atom`, `Bool`, `Float`, `Integer`, and
  `String` (the identity case). User types can opt in with
  `pub impl Stringable for MyType { pub fn to_string(...) }`.

  Compared to a single `Kernel.to_string(value :: any)` function with
  runtime type-dispatch, the protocol form lets the compiler pick the
  right implementation at HIR time based on the argument's static type
  — no any-tagging, no runtime branch.

  ## Examples

      "n is \#{42}"        # uses `Integer.to_string`
      "ok is \#{:ok}"      # uses `Atom.to_string`
      "flag is \#{true}"   # uses `Bool.to_string`
  """

pub protocol Stringable {
  fn to_string(value) -> String
}
