pub module Integer {
  @moduledoc = """
    Functions for working with integers.
    """

  @doc = """
    Converts an integer to its string representation.

    ## Examples

        Integer.to_string(42)    # => "42"
        Integer.to_string(-7)    # => "-7"
        Integer.to_string(0)     # => "0"
    """

  pub fn to_string(value :: i64) -> String {
    :zig.Prelude.i64_to_string(value)
  }
}
