pub module Integer {
  @moduledoc = """
    Functions for working with integers.

    ## Integer Types

    Zap supports the following integer types:

    | Signed  | Unsigned | Bits |
    |---------|----------|------|
    | `i8`    | `u8`     | 8    |
    | `i16`   | `u16`    | 16   |
    | `i32`   | `u32`    | 32   |
    | `i64`   | `u64`    | 64   |

    The default integer type for literals is `i64`.

    ## Implicit Widening

    Zap automatically widens narrower integer types to wider ones at
    function call sites when no data is lost. This means you can pass
    an `i8` value to a function that expects `i64` without an explicit
    cast — the compiler inserts a zero-cost widening instruction.

    **Signed widening:** `i8` \u{2192} `i16` \u{2192} `i32` \u{2192} `i64`

    **Unsigned widening:** `u8` \u{2192} `u16` \u{2192} `u32` \u{2192} `u64`

    **Unsigned to signed:** `u8` \u{2192} `i16`, `u16` \u{2192} `i32`, `u32` \u{2192} `i64`
    (the signed type must have strictly more bits to represent the full
    unsigned range)

    The following conversions are **not** implicit:

    - Signed to unsigned (negative values would be lost)
    - Wider to narrower (data truncation)
    - Integer to float (precision loss for large values)
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

  @doc = """
    Returns the absolute value of an integer.

    ## Examples

        Integer.abs(-42)  # => 42
        Integer.abs(42)   # => 42
        Integer.abs(0)    # => 0
    """

  pub fn abs(value :: i64) -> i64 {
    :zig.Prelude.abs_i64(value)
  }

  @doc = """
    Returns the larger of two integers.

    ## Examples

        Integer.max(3, 7)    # => 7
        Integer.max(10, 2)   # => 10
        Integer.max(5, 5)    # => 5
    """

  pub fn max(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.max_i64(first, second)
  }

  @doc = """
    Returns the smaller of two integers.

    ## Examples

        Integer.min(3, 7)    # => 3
        Integer.min(10, 2)   # => 2
        Integer.min(5, 5)    # => 5
    """

  pub fn min(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.min_i64(first, second)
  }

  @doc = """
    Parses a string into an integer. Returns 0 if the string
    is not a valid integer representation.

    ## Examples

        Integer.parse("42")    # => 42
        Integer.parse("-7")    # => -7
        Integer.parse("hello") # => 0
    """

  pub fn parse(input :: String) -> i64 {
    :zig.Prelude.parse_i64(input)
  }

  @doc = """
    Computes the remainder of integer division.

    ## Examples

        Integer.remainder(10, 3)   # => 1
        Integer.remainder(7, 2)    # => 1
        Integer.remainder(6, 3)    # => 0
    """

  pub fn remainder(dividend :: i64, divisor :: i64) -> i64 {
    dividend - dividend / divisor * divisor
  }

  @doc = """
    Raises `base` to the power of `exponent`. The exponent must
    be non-negative.

    ## Examples

        Integer.pow(2, 10)   # => 1024
        Integer.pow(3, 3)    # => 27
        Integer.pow(5, 0)    # => 1
        Integer.pow(7, 1)    # => 7
    """

  pub fn pow(base :: i64, exponent :: i64) -> i64 {
    case exponent {
      0 -> 1
      _ -> base * pow(base, exponent - 1)
    }
  }

  @doc = """
    Clamps a value to be within the given range.

    ## Examples

        Integer.clamp(15, 0, 10)   # => 10
        Integer.clamp(-5, 0, 10)   # => 0
        Integer.clamp(5, 0, 10)    # => 5
    """

  pub fn clamp(value :: i64, lower :: i64, upper :: i64) -> i64 {
    Integer.min(Integer.max(value, lower), upper)
  }

  @doc = """
    Returns the number of digits in an integer. Negative signs
    are not counted.

    ## Examples

        Integer.digits(42)     # => 2
        Integer.digits(0)      # => 1
        Integer.digits(-123)   # => 3
        Integer.digits(10000)  # => 5
    """

  pub fn digits(value :: i64) -> i64 {
    count_digits(Integer.abs(value))
  }

  pub fn count_digits(value :: i64) -> i64 {
    case value < 10 {
      true -> 1
      _ -> 1 + count_digits(value / 10)
    }
  }

  @doc = """
    Converts an integer to a floating-point number.

    ## Examples

        Integer.to_float(42)   # => 42.0
        Integer.to_float(-7)   # => -7.0
        Integer.to_float(0)    # => 0.0
    """

  pub fn to_float(value :: i64) -> f64 {
    :zig.Prelude.i64_to_f64(value)
  }
}
