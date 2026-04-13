pub module Float {
  @moduledoc = """
    Functions for working with floating-point numbers.

    ## Float Types

    Zap supports the following floating-point types:

    | Type  | Bits | Precision        |
    |-------|------|------------------|
    | `f16` | 16   | Half precision   |
    | `f32` | 32   | Single precision |
    | `f64` | 64   | Double precision |

    The default float type for literals is `f64`.

    ## Implicit Widening

    Zap automatically widens narrower float types to wider ones at
    function call sites: `f16` \u{2192} `f32` \u{2192} `f64`. This is
    lossless and zero-cost — the compiler inserts the conversion
    automatically.

    Integer-to-float conversion is **not** implicit because large
    integers cannot be represented exactly in floating-point. Use
    `Integer.to_float/1` when needed.
    """

  @doc = """
    Converts a floating-point number to its string representation.

    ## Examples

        Float.to_string(3.14)   # => "3.14"
        Float.to_string(-0.5)   # => "-0.5"
    """

  pub fn to_string(value :: f64) -> String {
    :zig.Prelude.f64_to_string(value)
  }

  @doc = """
    Returns the absolute value of a float.

    ## Examples

        Float.abs(-3.14)  # => 3.14
        Float.abs(2.5)    # => 2.5
        Float.abs(0.0)    # => 0.0
    """

  pub fn abs(value :: f64) -> f64 {
    :zig.Prelude.abs_f64(value)
  }

  @doc = """
    Returns the larger of two floats.

    ## Examples

        Float.max(3.0, 7.0)    # => 7.0
        Float.max(10.5, 2.3)   # => 10.5
    """

  pub fn max(first :: f64, second :: f64) -> f64 {
    :zig.Prelude.max_f64(first, second)
  }

  @doc = """
    Returns the smaller of two floats.

    ## Examples

        Float.min(3.0, 7.0)    # => 3.0
        Float.min(10.5, 2.3)   # => 2.3
    """

  pub fn min(first :: f64, second :: f64) -> f64 {
    :zig.Prelude.min_f64(first, second)
  }

  @doc = """
    Parses a string into a float. Returns 0.0 if the string
    is not a valid float representation.

    ## Examples

        Float.parse("3.14")    # => 3.14
        Float.parse("-0.5")    # => -0.5
        Float.parse("hello")   # => 0.0
    """

  pub fn parse(input :: String) -> f64 {
    :zig.Prelude.parse_f64(input)
  }

  @doc = """
    Rounds a float to the nearest integer value, returned as a float.
    Rounds half-values away from zero.

    ## Examples

        Float.round(3.2)   # => 3.0
        Float.round(3.7)   # => 4.0
        Float.round(-2.5)  # => -3.0
    """

  pub fn round(value :: f64) -> f64 {
    :zig.Prelude.round_f64(value)
  }

  @doc = """
    Returns the largest integer value less than or equal to the
    given float, returned as a float.

    ## Examples

        Float.floor(3.7)   # => 3.0
        Float.floor(3.0)   # => 3.0
        Float.floor(-2.3)  # => -3.0
    """

  pub fn floor(value :: f64) -> f64 {
    :zig.Prelude.floor_f64(value)
  }

  @doc = """
    Returns the smallest integer value greater than or equal to
    the given float, returned as a float.

    ## Examples

        Float.ceil(3.2)   # => 4.0
        Float.ceil(3.0)   # => 3.0
        Float.ceil(-2.7)  # => -2.0
    """

  pub fn ceil(value :: f64) -> f64 {
    :zig.Prelude.ceil_f64(value)
  }

  @doc = """
    Truncates a float toward zero, removing the fractional part.
    Returned as a float.

    ## Examples

        Float.truncate(3.7)   # => 3.0
        Float.truncate(-2.9)  # => -2.0
        Float.truncate(5.0)   # => 5.0
    """

  pub fn truncate(value :: f64) -> f64 {
    :zig.Prelude.trunc_f64(value)
  }

  @doc = """
    Converts a float to an integer by truncating toward zero.

    ## Examples

        Float.to_integer(3.7)   # => 3
        Float.to_integer(-2.9)  # => -2
        Float.to_integer(5.0)   # => 5
    """

  pub fn to_integer(value :: f64) -> i64 {
    :zig.Prelude.f64_to_i64(value)
  }

  @doc = """
    Clamps a float to be within the given range.

    ## Examples

        Float.clamp(15.0, 0.0, 10.0)  # => 10.0
        Float.clamp(-5.0, 0.0, 10.0)  # => 0.0
        Float.clamp(5.0, 0.0, 10.0)   # => 5.0
    """

  pub fn clamp(value :: f64, lower :: f64, upper :: f64) -> f64 {
    Float.min(Float.max(value, lower), upper)
  }
}
