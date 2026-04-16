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

  # --- Bit operations ---

  @doc = """
    Returns the number of leading zeros in the binary representation.

    ## Examples

        Integer.count_leading_zeros(1)   # => 63
        Integer.count_leading_zeros(0)   # => 64
    """

  pub fn count_leading_zeros(value :: i64) -> i64 {
    :zig.Prelude.clz_i64(value)
  }

  @doc = """
    Returns the number of trailing zeros in the binary representation.

    ## Examples

        Integer.count_trailing_zeros(8)   # => 3
        Integer.count_trailing_zeros(1)   # => 0
    """

  pub fn count_trailing_zeros(value :: i64) -> i64 {
    :zig.Prelude.ctz_i64(value)
  }

  @doc = """
    Returns the number of set bits (ones) in the binary representation.

    ## Examples

        Integer.popcount(7)    # => 3
        Integer.popcount(255)  # => 8
        Integer.popcount(0)    # => 0
    """

  pub fn popcount(value :: i64) -> i64 {
    :zig.Prelude.popcount_i64(value)
  }

  @doc = """
    Reverses the byte order of an integer. Useful for converting
    between big-endian and little-endian representations.

    ## Examples

        Integer.byte_swap(1)  # => 72057594037927936
    """

  pub fn byte_swap(value :: i64) -> i64 {
    :zig.Prelude.byte_swap_i64(value)
  }

  @doc = """
    Reverses all bits in the binary representation.

    ## Examples

        Integer.bit_reverse(1)  # => -9223372036854775808
    """

  pub fn bit_reverse(value :: i64) -> i64 {
    :zig.Prelude.bit_reverse_i64(value)
  }

  # --- Saturating arithmetic ---

  @doc = """
    Adds two integers with saturation. If the result would overflow,
    it clamps to the maximum (or minimum) representable value instead.

    ## Examples

        Integer.add_sat(9223372036854775807, 1)  # => 9223372036854775807
        Integer.add_sat(3, 4)                     # => 7
    """

  pub fn add_sat(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.add_sat_i64(first, second)
  }

  @doc = """
    Subtracts two integers with saturation. If the result would
    underflow, it clamps to the minimum representable value instead.

    ## Examples

        Integer.sub_sat(-9223372036854775808, 1)  # => -9223372036854775808
        Integer.sub_sat(10, 3)                     # => 7
    """

  pub fn sub_sat(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.sub_sat_i64(first, second)
  }

  @doc = """
    Multiplies two integers with saturation. If the result would
    overflow, it clamps to the maximum (or minimum) representable
    value instead.

    ## Examples

        Integer.mul_sat(9223372036854775807, 2)  # => 9223372036854775807
        Integer.mul_sat(3, 4)                     # => 12
    """

  pub fn mul_sat(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.mul_sat_i64(first, second)
  }

  # --- Bitwise operations ---

  @doc = """
    Bitwise AND of two integers.

    ## Examples

        Integer.band(7, 5)    # => 5
        Integer.band(255, 15) # => 15
        Integer.band(0, 42)   # => 0
    """

  pub fn band(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.band_i64(first, second)
  }

  @doc = """
    Bitwise OR of two integers.

    ## Examples

        Integer.bor(5, 3)    # => 7
        Integer.bor(0, 42)   # => 42
        Integer.bor(255, 0)  # => 255
    """

  pub fn bor(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.bor_i64(first, second)
  }

  @doc = """
    Bitwise XOR (exclusive OR) of two integers.

    ## Examples

        Integer.bxor(7, 5)    # => 2
        Integer.bxor(255, 255) # => 0
        Integer.bxor(0, 42)   # => 42
    """

  pub fn bxor(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.bxor_i64(first, second)
  }

  @doc = """
    Bitwise NOT (complement) of an integer.

    Flips all bits in the binary representation.

    ## Examples

        Integer.bnot(0)    # => -1
        Integer.bnot(-1)   # => 0
    """

  pub fn bnot(value :: i64) -> i64 {
    :zig.Prelude.bnot_i64(value)
  }

  @doc = """
    Bitwise shift left. Shifts the bits of the first argument
    left by the number of positions given in the second argument.

    ## Examples

        Integer.bsl(1, 3)    # => 8
        Integer.bsl(5, 1)    # => 10
    """

  pub fn bsl(value :: i64, amount :: i64) -> i64 {
    :zig.Prelude.bsl_i64(value, amount)
  }

  @doc = """
    Bitwise shift right (arithmetic). Shifts the bits of the first
    argument right by the number of positions given in the second
    argument. Preserves the sign bit.

    ## Examples

        Integer.bsr(8, 3)    # => 1
        Integer.bsr(10, 1)   # => 5
    """

  pub fn bsr(value :: i64, amount :: i64) -> i64 {
    :zig.Prelude.bsr_i64(value, amount)
  }

  # --- Predicates (pure Zap) ---

  @doc = """
    Returns the sign of an integer: -1 for negative, 0 for zero,
    1 for positive.

    ## Examples

        Integer.sign(42)   # => 1
        Integer.sign(0)    # => 0
        Integer.sign(-7)   # => -1
    """

  pub fn sign(value :: i64) -> i64 {
    :zig.Prelude.sign_i64(value)
  }

  @doc = """
    Returns true if the integer is even.

    ## Examples

        Integer.even?(4)   # => true
        Integer.even?(3)   # => false
        Integer.even?(0)   # => true
    """

  pub fn even?(value :: i64) -> Bool {
    :zig.Prelude.even_i64(value)
  }

  @doc = """
    Returns true if the integer is odd.

    ## Examples

        Integer.odd?(3)   # => true
        Integer.odd?(4)   # => false
        Integer.odd?(0)   # => false
    """

  pub fn odd?(value :: i64) -> Bool {
    :zig.Prelude.odd_i64(value)
  }

  @doc = """
    Computes the greatest common divisor of two integers
    using the Euclidean algorithm.

    ## Examples

        Integer.gcd(12, 8)   # => 4
        Integer.gcd(54, 24)  # => 6
        Integer.gcd(7, 5)    # => 1
    """

  pub fn gcd(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.gcd_i64(first, second)
  }

  @doc = """
    Computes the least common multiple of two integers.

    ## Examples

        Integer.lcm(4, 6)   # => 12
        Integer.lcm(3, 5)   # => 15
        Integer.lcm(7, 7)   # => 7
    """

  pub fn lcm(first :: i64, second :: i64) -> i64 {
    :zig.Prelude.lcm_i64(first, second)
  }
}
