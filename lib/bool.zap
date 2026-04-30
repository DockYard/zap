@doc = """
  Functions for working with boolean values.

  Zap has two boolean values: `true` and `false`. Booleans are
  used in conditionals, guards, and logical expressions.

  The Kernel struct provides `and`, `or`, and `not` macros for
  use in expressions. This struct provides functional equivalents
  that can be passed as values or used in pipes.
  """

pub struct Bool {
  @doc = """
    Converts a boolean to its string representation.

    ## Examples

        Bool.to_string(true)   # => "true"
        Bool.to_string(false)  # => "false"
    """

  pub fn to_string(value :: Bool) -> String {
    :zig.Bool.to_string(value)
  }

  @doc = """
    Returns the logical negation of a boolean.

    ## Examples

        Bool.negate(true)   # => false
        Bool.negate(false)  # => true
    """

  pub fn negate(value :: Bool) -> Bool {
    if value {
      false
    } else {
      true
    }
  }
}
