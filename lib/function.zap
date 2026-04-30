@doc = """
  Utilities for working with first-class function values.

  Zap function values can come from explicit function references such as
  `&Struct.name/arity` or from anonymous closures written with
  `fn(...) -> ... { ... }`.

  This struct currently exposes the smallest Elixir-inspired function
  helper that Zap can support cleanly today without runtime metadata or
  broader higher-order standard-library infrastructure.

  Zap already has direct invocation syntax for callable values, so this
  struct does not try to wrap ordinary function calls. It also does not
  provide Elixir-style introspection helpers such as `info/1` yet because
  Zap does not currently expose stable runtime metadata for function values.
  """

pub struct Function {
  @doc = """
    Returns the value unchanged.

    Useful as the default callback when an API accepts a function but no
    transformation is needed.

    ## Examples

        Function.identity(42)      # => 42
        Function.identity("zap")   # => "zap"
    """

  pub macro identity(value_expression :: Expr) -> Expr {
    quote { unquote(value_expression) }
  }

}
