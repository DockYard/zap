@doc = """
  A first-class reference to a statically-known Zap function.

  Function values are produced by function references such as
  `&Struct.name/arity` and can be called only while the target is still
  statically visible to the compiler.
  """

pub struct Function {
  struct :: Type
  name :: Atom
  arity :: u8

  @doc = """
    Returns the value unchanged.

    Useful as a generic helper where the original value should flow through
    without transformation.

    ## Examples

        Function.identity(42)      # => 42
        Function.identity("zap")   # => "zap"
    """

  pub fn identity(value :: t) -> t {
    value
  }
}
