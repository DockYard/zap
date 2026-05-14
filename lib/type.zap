@doc = """
  A first-class reference to a Zap type.

  Type values are produced by using a real type name in expression position,
  such as `String`, `Atom`, or a user-defined struct name.
  """

pub struct Type {
  name :: Atom
}
