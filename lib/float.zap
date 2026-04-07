pub module Float {
  @moduledoc = """
    Functions for working with floating-point numbers.
    """

  @doc = """
    Converts a floating-point number to its string representation.

    ## Examples

        Float.to_string(3.14)   # => "3.14"
        Float.to_string(-0.5)   # => "-0.5"
        Float.to_string(1.0)    # => "1.0"
    """

  pub fn to_string(value :: f64) -> String {
    :zig.Prelude.f64_to_string(value)
  }
}
