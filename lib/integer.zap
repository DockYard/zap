@doc = """
  Functions for working with integers.

  ## Integer Types

  Zap supports the following integer types:

  | Signed  | Unsigned | Bits |
  |---------|----------|------|
  | `i8`    | `u8`     | 8    |
  | `i16`   | `u16`    | 16   |
  | `i32`   | `u32`    | 32   |
  | `i64`   | `u64`    | 64   |
  | `i128`  | `u128`   | 128  |

  The default integer type for literals is `i64`.

  ## Call Resolution

  Zap first looks for an exact typed function clause. If no exact
  clause exists, it may widen within the same integer family:

  - Signed widening: `i8` -> `i16` -> `i32` -> `i64` -> `i128`
  - Unsigned widening: `u8` -> `u16` -> `u32` -> `u64` -> `u128`

  Signed integers do not implicitly widen to unsigned integers, and
  unsigned integers do not implicitly widen to signed integers.
  """

pub struct Integer {
  @doc = """
    Converts an integer to its string representation.

    ## Examples

        Integer.to_string(42)    # => "42"
        Integer.to_string(-7)    # => "-7"
        Integer.to_string(0)     # => "0"
    """

  pub fn to_string(value :: i8) -> String { :zig.Integer.to_string_i8(value) }
  pub fn to_string(value :: i16) -> String { :zig.Integer.to_string_i16(value) }
  pub fn to_string(value :: i32) -> String { :zig.Integer.to_string_i32(value) }
  pub fn to_string(value :: i64) -> String { :zig.Integer.to_string_i64(value) }
  pub fn to_string(value :: i128) -> String { :zig.Integer.to_string_i128(value) }
  pub fn to_string(value :: u8) -> String { :zig.Integer.to_string_u8(value) }
  pub fn to_string(value :: u16) -> String { :zig.Integer.to_string_u16(value) }
  pub fn to_string(value :: u32) -> String { :zig.Integer.to_string_u32(value) }
  pub fn to_string(value :: u64) -> String { :zig.Integer.to_string_u64(value) }
  pub fn to_string(value :: u128) -> String { :zig.Integer.to_string_u128(value) }

  @doc = """
    Returns the absolute value of an integer.

    Unsigned integers are already non-negative, so their absolute
    value is the original value.
    """

  pub fn abs(value :: i8) -> i8 { :zig.Integer.abs_i8(value) }
  pub fn abs(value :: i16) -> i16 { :zig.Integer.abs_i16(value) }
  pub fn abs(value :: i32) -> i32 { :zig.Integer.abs_i32(value) }
  pub fn abs(value :: i64) -> i64 { :zig.Integer.abs_i64(value) }
  pub fn abs(value :: i128) -> i128 { :zig.Integer.abs_i128(value) }
  pub fn abs(value :: u8) -> u8 { :zig.Integer.abs_u8(value) }
  pub fn abs(value :: u16) -> u16 { :zig.Integer.abs_u16(value) }
  pub fn abs(value :: u32) -> u32 { :zig.Integer.abs_u32(value) }
  pub fn abs(value :: u64) -> u64 { :zig.Integer.abs_u64(value) }
  pub fn abs(value :: u128) -> u128 { :zig.Integer.abs_u128(value) }

  @doc = "Returns the larger of two integers."

  pub fn max(first :: i8, second :: i8) -> i8 { :zig.Integer.max_i8(first, second) }
  pub fn max(first :: i16, second :: i16) -> i16 { :zig.Integer.max_i16(first, second) }
  pub fn max(first :: i32, second :: i32) -> i32 { :zig.Integer.max_i32(first, second) }
  pub fn max(first :: i64, second :: i64) -> i64 { :zig.Integer.max_i64(first, second) }
  pub fn max(first :: i128, second :: i128) -> i128 { :zig.Integer.max_i128(first, second) }
  pub fn max(first :: u8, second :: u8) -> u8 { :zig.Integer.max_u8(first, second) }
  pub fn max(first :: u16, second :: u16) -> u16 { :zig.Integer.max_u16(first, second) }
  pub fn max(first :: u32, second :: u32) -> u32 { :zig.Integer.max_u32(first, second) }
  pub fn max(first :: u64, second :: u64) -> u64 { :zig.Integer.max_u64(first, second) }
  pub fn max(first :: u128, second :: u128) -> u128 { :zig.Integer.max_u128(first, second) }

  @doc = "Returns the smaller of two integers."

  pub fn min(first :: i8, second :: i8) -> i8 { :zig.Integer.min_i8(first, second) }
  pub fn min(first :: i16, second :: i16) -> i16 { :zig.Integer.min_i16(first, second) }
  pub fn min(first :: i32, second :: i32) -> i32 { :zig.Integer.min_i32(first, second) }
  pub fn min(first :: i64, second :: i64) -> i64 { :zig.Integer.min_i64(first, second) }
  pub fn min(first :: i128, second :: i128) -> i128 { :zig.Integer.min_i128(first, second) }
  pub fn min(first :: u8, second :: u8) -> u8 { :zig.Integer.min_u8(first, second) }
  pub fn min(first :: u16, second :: u16) -> u16 { :zig.Integer.min_u16(first, second) }
  pub fn min(first :: u32, second :: u32) -> u32 { :zig.Integer.min_u32(first, second) }
  pub fn min(first :: u64, second :: u64) -> u64 { :zig.Integer.min_u64(first, second) }
  pub fn min(first :: u128, second :: u128) -> u128 { :zig.Integer.min_u128(first, second) }

  @doc = """
    Parses a string into an integer. Returns 0 if the string is not
    a valid integer representation.
    """

  pub fn parse(input :: String) -> i64 {
    :zig.Integer.parse(input)
  }

  @doc = "Computes the remainder of integer division."

  pub fn remainder(dividend :: i8, divisor :: i8) -> i8 { :zig.Integer.rem_i8(dividend, divisor) }
  pub fn remainder(dividend :: i16, divisor :: i16) -> i16 { :zig.Integer.rem_i16(dividend, divisor) }
  pub fn remainder(dividend :: i32, divisor :: i32) -> i32 { :zig.Integer.rem_i32(dividend, divisor) }
  pub fn remainder(dividend :: i64, divisor :: i64) -> i64 { :zig.Integer.rem_i64(dividend, divisor) }
  pub fn remainder(dividend :: i128, divisor :: i128) -> i128 { :zig.Integer.rem_i128(dividend, divisor) }
  pub fn remainder(dividend :: u8, divisor :: u8) -> u8 { :zig.Integer.rem_u8(dividend, divisor) }
  pub fn remainder(dividend :: u16, divisor :: u16) -> u16 { :zig.Integer.rem_u16(dividend, divisor) }
  pub fn remainder(dividend :: u32, divisor :: u32) -> u32 { :zig.Integer.rem_u32(dividend, divisor) }
  pub fn remainder(dividend :: u64, divisor :: u64) -> u64 { :zig.Integer.rem_u64(dividend, divisor) }
  pub fn remainder(dividend :: u128, divisor :: u128) -> u128 { :zig.Integer.rem_u128(dividend, divisor) }

  @doc = "Raises `base` to the power of `exponent`."

  pub fn pow(base :: i8, exponent :: i8) -> i8 { :zig.Integer.pow_i8(base, exponent) }
  pub fn pow(base :: i16, exponent :: i16) -> i16 { :zig.Integer.pow_i16(base, exponent) }
  pub fn pow(base :: i32, exponent :: i32) -> i32 { :zig.Integer.pow_i32(base, exponent) }
  pub fn pow(base :: i64, exponent :: i64) -> i64 { :zig.Integer.pow_i64(base, exponent) }
  pub fn pow(base :: i128, exponent :: i128) -> i128 { :zig.Integer.pow_i128(base, exponent) }
  pub fn pow(base :: u8, exponent :: u8) -> u8 { :zig.Integer.pow_u8(base, exponent) }
  pub fn pow(base :: u16, exponent :: u16) -> u16 { :zig.Integer.pow_u16(base, exponent) }
  pub fn pow(base :: u32, exponent :: u32) -> u32 { :zig.Integer.pow_u32(base, exponent) }
  pub fn pow(base :: u64, exponent :: u64) -> u64 { :zig.Integer.pow_u64(base, exponent) }
  pub fn pow(base :: u128, exponent :: u128) -> u128 { :zig.Integer.pow_u128(base, exponent) }

  @doc = "Clamps a value to be within the given range."

  pub fn clamp(value :: i8, lower :: i8, upper :: i8) -> i8 { :zig.Integer.clamp_i8(value, lower, upper) }
  pub fn clamp(value :: i16, lower :: i16, upper :: i16) -> i16 { :zig.Integer.clamp_i16(value, lower, upper) }
  pub fn clamp(value :: i32, lower :: i32, upper :: i32) -> i32 { :zig.Integer.clamp_i32(value, lower, upper) }
  pub fn clamp(value :: i64, lower :: i64, upper :: i64) -> i64 { :zig.Integer.clamp_i64(value, lower, upper) }
  pub fn clamp(value :: i128, lower :: i128, upper :: i128) -> i128 { :zig.Integer.clamp_i128(value, lower, upper) }
  pub fn clamp(value :: u8, lower :: u8, upper :: u8) -> u8 { :zig.Integer.clamp_u8(value, lower, upper) }
  pub fn clamp(value :: u16, lower :: u16, upper :: u16) -> u16 { :zig.Integer.clamp_u16(value, lower, upper) }
  pub fn clamp(value :: u32, lower :: u32, upper :: u32) -> u32 { :zig.Integer.clamp_u32(value, lower, upper) }
  pub fn clamp(value :: u64, lower :: u64, upper :: u64) -> u64 { :zig.Integer.clamp_u64(value, lower, upper) }
  pub fn clamp(value :: u128, lower :: u128, upper :: u128) -> u128 { :zig.Integer.clamp_u128(value, lower, upper) }

  @doc = "Returns the number of decimal digits in an integer."

  pub fn digits(value :: i8) -> i64 { :zig.Integer.digits_i8(value) }
  pub fn digits(value :: i16) -> i64 { :zig.Integer.digits_i16(value) }
  pub fn digits(value :: i32) -> i64 { :zig.Integer.digits_i32(value) }
  pub fn digits(value :: i64) -> i64 { :zig.Integer.digits_i64(value) }
  pub fn digits(value :: i128) -> i64 { :zig.Integer.digits_i128(value) }
  pub fn digits(value :: u8) -> i64 { :zig.Integer.digits_u8(value) }
  pub fn digits(value :: u16) -> i64 { :zig.Integer.digits_u16(value) }
  pub fn digits(value :: u32) -> i64 { :zig.Integer.digits_u32(value) }
  pub fn digits(value :: u64) -> i64 { :zig.Integer.digits_u64(value) }
  pub fn digits(value :: u128) -> i64 { :zig.Integer.digits_u128(value) }

  @doc = "Converts an integer to a 64-bit floating-point number."

  pub fn to_float(value :: i8) -> f64 { :zig.Integer.to_f64_i8(value) }
  pub fn to_float(value :: i16) -> f64 { :zig.Integer.to_f64_i16(value) }
  pub fn to_float(value :: i32) -> f64 { :zig.Integer.to_f64_i32(value) }
  pub fn to_float(value :: i64) -> f64 { :zig.Integer.to_f64_i64(value) }
  pub fn to_float(value :: i128) -> f64 { :zig.Integer.to_f64_i128(value) }
  pub fn to_float(value :: u8) -> f64 { :zig.Integer.to_f64_u8(value) }
  pub fn to_float(value :: u16) -> f64 { :zig.Integer.to_f64_u16(value) }
  pub fn to_float(value :: u32) -> f64 { :zig.Integer.to_f64_u32(value) }
  pub fn to_float(value :: u64) -> f64 { :zig.Integer.to_f64_u64(value) }
  pub fn to_float(value :: u128) -> f64 { :zig.Integer.to_f64_u128(value) }

  @doc = "Returns the number of leading zeros in the binary representation."

  pub fn count_leading_zeros(value :: i8) -> i64 { :zig.Integer.clz_i8(value) }
  pub fn count_leading_zeros(value :: i16) -> i64 { :zig.Integer.clz_i16(value) }
  pub fn count_leading_zeros(value :: i32) -> i64 { :zig.Integer.clz_i32(value) }
  pub fn count_leading_zeros(value :: i64) -> i64 { :zig.Integer.clz_i64(value) }
  pub fn count_leading_zeros(value :: i128) -> i64 { :zig.Integer.clz_i128(value) }
  pub fn count_leading_zeros(value :: u8) -> i64 { :zig.Integer.clz_u8(value) }
  pub fn count_leading_zeros(value :: u16) -> i64 { :zig.Integer.clz_u16(value) }
  pub fn count_leading_zeros(value :: u32) -> i64 { :zig.Integer.clz_u32(value) }
  pub fn count_leading_zeros(value :: u64) -> i64 { :zig.Integer.clz_u64(value) }
  pub fn count_leading_zeros(value :: u128) -> i64 { :zig.Integer.clz_u128(value) }

  @doc = "Returns the number of trailing zeros in the binary representation."

  pub fn count_trailing_zeros(value :: i8) -> i64 { :zig.Integer.ctz_i8(value) }
  pub fn count_trailing_zeros(value :: i16) -> i64 { :zig.Integer.ctz_i16(value) }
  pub fn count_trailing_zeros(value :: i32) -> i64 { :zig.Integer.ctz_i32(value) }
  pub fn count_trailing_zeros(value :: i64) -> i64 { :zig.Integer.ctz_i64(value) }
  pub fn count_trailing_zeros(value :: i128) -> i64 { :zig.Integer.ctz_i128(value) }
  pub fn count_trailing_zeros(value :: u8) -> i64 { :zig.Integer.ctz_u8(value) }
  pub fn count_trailing_zeros(value :: u16) -> i64 { :zig.Integer.ctz_u16(value) }
  pub fn count_trailing_zeros(value :: u32) -> i64 { :zig.Integer.ctz_u32(value) }
  pub fn count_trailing_zeros(value :: u64) -> i64 { :zig.Integer.ctz_u64(value) }
  pub fn count_trailing_zeros(value :: u128) -> i64 { :zig.Integer.ctz_u128(value) }

  @doc = "Returns the number of set bits in the binary representation."

  pub fn popcount(value :: i8) -> i64 { :zig.Integer.popcount_i8(value) }
  pub fn popcount(value :: i16) -> i64 { :zig.Integer.popcount_i16(value) }
  pub fn popcount(value :: i32) -> i64 { :zig.Integer.popcount_i32(value) }
  pub fn popcount(value :: i64) -> i64 { :zig.Integer.popcount_i64(value) }
  pub fn popcount(value :: i128) -> i64 { :zig.Integer.popcount_i128(value) }
  pub fn popcount(value :: u8) -> i64 { :zig.Integer.popcount_u8(value) }
  pub fn popcount(value :: u16) -> i64 { :zig.Integer.popcount_u16(value) }
  pub fn popcount(value :: u32) -> i64 { :zig.Integer.popcount_u32(value) }
  pub fn popcount(value :: u64) -> i64 { :zig.Integer.popcount_u64(value) }
  pub fn popcount(value :: u128) -> i64 { :zig.Integer.popcount_u128(value) }

  @doc = "Reverses the byte order of an integer."

  pub fn byte_swap(value :: i8) -> i8 { :zig.Integer.byte_swap_i8(value) }
  pub fn byte_swap(value :: i16) -> i16 { :zig.Integer.byte_swap_i16(value) }
  pub fn byte_swap(value :: i32) -> i32 { :zig.Integer.byte_swap_i32(value) }
  pub fn byte_swap(value :: i64) -> i64 { :zig.Integer.byte_swap_i64(value) }
  pub fn byte_swap(value :: i128) -> i128 { :zig.Integer.byte_swap_i128(value) }
  pub fn byte_swap(value :: u8) -> u8 { :zig.Integer.byte_swap_u8(value) }
  pub fn byte_swap(value :: u16) -> u16 { :zig.Integer.byte_swap_u16(value) }
  pub fn byte_swap(value :: u32) -> u32 { :zig.Integer.byte_swap_u32(value) }
  pub fn byte_swap(value :: u64) -> u64 { :zig.Integer.byte_swap_u64(value) }
  pub fn byte_swap(value :: u128) -> u128 { :zig.Integer.byte_swap_u128(value) }

  @doc = "Reverses all bits in the binary representation."

  pub fn bit_reverse(value :: i8) -> i8 { :zig.Integer.bit_reverse_i8(value) }
  pub fn bit_reverse(value :: i16) -> i16 { :zig.Integer.bit_reverse_i16(value) }
  pub fn bit_reverse(value :: i32) -> i32 { :zig.Integer.bit_reverse_i32(value) }
  pub fn bit_reverse(value :: i64) -> i64 { :zig.Integer.bit_reverse_i64(value) }
  pub fn bit_reverse(value :: i128) -> i128 { :zig.Integer.bit_reverse_i128(value) }
  pub fn bit_reverse(value :: u8) -> u8 { :zig.Integer.bit_reverse_u8(value) }
  pub fn bit_reverse(value :: u16) -> u16 { :zig.Integer.bit_reverse_u16(value) }
  pub fn bit_reverse(value :: u32) -> u32 { :zig.Integer.bit_reverse_u32(value) }
  pub fn bit_reverse(value :: u64) -> u64 { :zig.Integer.bit_reverse_u64(value) }
  pub fn bit_reverse(value :: u128) -> u128 { :zig.Integer.bit_reverse_u128(value) }

  @doc = "Adds two integers with saturation."

  pub fn add_sat(first :: i8, second :: i8) -> i8 { :zig.Integer.add_sat_i8(first, second) }
  pub fn add_sat(first :: i16, second :: i16) -> i16 { :zig.Integer.add_sat_i16(first, second) }
  pub fn add_sat(first :: i32, second :: i32) -> i32 { :zig.Integer.add_sat_i32(first, second) }
  pub fn add_sat(first :: i64, second :: i64) -> i64 { :zig.Integer.add_sat_i64(first, second) }
  pub fn add_sat(first :: i128, second :: i128) -> i128 { :zig.Integer.add_sat_i128(first, second) }
  pub fn add_sat(first :: u8, second :: u8) -> u8 { :zig.Integer.add_sat_u8(first, second) }
  pub fn add_sat(first :: u16, second :: u16) -> u16 { :zig.Integer.add_sat_u16(first, second) }
  pub fn add_sat(first :: u32, second :: u32) -> u32 { :zig.Integer.add_sat_u32(first, second) }
  pub fn add_sat(first :: u64, second :: u64) -> u64 { :zig.Integer.add_sat_u64(first, second) }
  pub fn add_sat(first :: u128, second :: u128) -> u128 { :zig.Integer.add_sat_u128(first, second) }

  @doc = "Subtracts two integers with saturation."

  pub fn sub_sat(first :: i8, second :: i8) -> i8 { :zig.Integer.sub_sat_i8(first, second) }
  pub fn sub_sat(first :: i16, second :: i16) -> i16 { :zig.Integer.sub_sat_i16(first, second) }
  pub fn sub_sat(first :: i32, second :: i32) -> i32 { :zig.Integer.sub_sat_i32(first, second) }
  pub fn sub_sat(first :: i64, second :: i64) -> i64 { :zig.Integer.sub_sat_i64(first, second) }
  pub fn sub_sat(first :: i128, second :: i128) -> i128 { :zig.Integer.sub_sat_i128(first, second) }
  pub fn sub_sat(first :: u8, second :: u8) -> u8 { :zig.Integer.sub_sat_u8(first, second) }
  pub fn sub_sat(first :: u16, second :: u16) -> u16 { :zig.Integer.sub_sat_u16(first, second) }
  pub fn sub_sat(first :: u32, second :: u32) -> u32 { :zig.Integer.sub_sat_u32(first, second) }
  pub fn sub_sat(first :: u64, second :: u64) -> u64 { :zig.Integer.sub_sat_u64(first, second) }
  pub fn sub_sat(first :: u128, second :: u128) -> u128 { :zig.Integer.sub_sat_u128(first, second) }

  @doc = "Multiplies two integers with saturation."

  pub fn mul_sat(first :: i8, second :: i8) -> i8 { :zig.Integer.mul_sat_i8(first, second) }
  pub fn mul_sat(first :: i16, second :: i16) -> i16 { :zig.Integer.mul_sat_i16(first, second) }
  pub fn mul_sat(first :: i32, second :: i32) -> i32 { :zig.Integer.mul_sat_i32(first, second) }
  pub fn mul_sat(first :: i64, second :: i64) -> i64 { :zig.Integer.mul_sat_i64(first, second) }
  pub fn mul_sat(first :: i128, second :: i128) -> i128 { :zig.Integer.mul_sat_i128(first, second) }
  pub fn mul_sat(first :: u8, second :: u8) -> u8 { :zig.Integer.mul_sat_u8(first, second) }
  pub fn mul_sat(first :: u16, second :: u16) -> u16 { :zig.Integer.mul_sat_u16(first, second) }
  pub fn mul_sat(first :: u32, second :: u32) -> u32 { :zig.Integer.mul_sat_u32(first, second) }
  pub fn mul_sat(first :: u64, second :: u64) -> u64 { :zig.Integer.mul_sat_u64(first, second) }
  pub fn mul_sat(first :: u128, second :: u128) -> u128 { :zig.Integer.mul_sat_u128(first, second) }

  @doc = "Bitwise AND of two integers."

  pub fn band(first :: i8, second :: i8) -> i8 { :zig.Integer.band_i8(first, second) }
  pub fn band(first :: i16, second :: i16) -> i16 { :zig.Integer.band_i16(first, second) }
  pub fn band(first :: i32, second :: i32) -> i32 { :zig.Integer.band_i32(first, second) }
  pub fn band(first :: i64, second :: i64) -> i64 { :zig.Integer.band_i64(first, second) }
  pub fn band(first :: i128, second :: i128) -> i128 { :zig.Integer.band_i128(first, second) }
  pub fn band(first :: u8, second :: u8) -> u8 { :zig.Integer.band_u8(first, second) }
  pub fn band(first :: u16, second :: u16) -> u16 { :zig.Integer.band_u16(first, second) }
  pub fn band(first :: u32, second :: u32) -> u32 { :zig.Integer.band_u32(first, second) }
  pub fn band(first :: u64, second :: u64) -> u64 { :zig.Integer.band_u64(first, second) }
  pub fn band(first :: u128, second :: u128) -> u128 { :zig.Integer.band_u128(first, second) }

  @doc = "Bitwise OR of two integers."

  pub fn bor(first :: i8, second :: i8) -> i8 { :zig.Integer.bor_i8(first, second) }
  pub fn bor(first :: i16, second :: i16) -> i16 { :zig.Integer.bor_i16(first, second) }
  pub fn bor(first :: i32, second :: i32) -> i32 { :zig.Integer.bor_i32(first, second) }
  pub fn bor(first :: i64, second :: i64) -> i64 { :zig.Integer.bor_i64(first, second) }
  pub fn bor(first :: i128, second :: i128) -> i128 { :zig.Integer.bor_i128(first, second) }
  pub fn bor(first :: u8, second :: u8) -> u8 { :zig.Integer.bor_u8(first, second) }
  pub fn bor(first :: u16, second :: u16) -> u16 { :zig.Integer.bor_u16(first, second) }
  pub fn bor(first :: u32, second :: u32) -> u32 { :zig.Integer.bor_u32(first, second) }
  pub fn bor(first :: u64, second :: u64) -> u64 { :zig.Integer.bor_u64(first, second) }
  pub fn bor(first :: u128, second :: u128) -> u128 { :zig.Integer.bor_u128(first, second) }

  @doc = "Bitwise XOR of two integers."

  pub fn bxor(first :: i8, second :: i8) -> i8 { :zig.Integer.bxor_i8(first, second) }
  pub fn bxor(first :: i16, second :: i16) -> i16 { :zig.Integer.bxor_i16(first, second) }
  pub fn bxor(first :: i32, second :: i32) -> i32 { :zig.Integer.bxor_i32(first, second) }
  pub fn bxor(first :: i64, second :: i64) -> i64 { :zig.Integer.bxor_i64(first, second) }
  pub fn bxor(first :: i128, second :: i128) -> i128 { :zig.Integer.bxor_i128(first, second) }
  pub fn bxor(first :: u8, second :: u8) -> u8 { :zig.Integer.bxor_u8(first, second) }
  pub fn bxor(first :: u16, second :: u16) -> u16 { :zig.Integer.bxor_u16(first, second) }
  pub fn bxor(first :: u32, second :: u32) -> u32 { :zig.Integer.bxor_u32(first, second) }
  pub fn bxor(first :: u64, second :: u64) -> u64 { :zig.Integer.bxor_u64(first, second) }
  pub fn bxor(first :: u128, second :: u128) -> u128 { :zig.Integer.bxor_u128(first, second) }

  @doc = "Bitwise NOT of an integer."

  pub fn bnot(value :: i8) -> i8 { :zig.Integer.bnot_i8(value) }
  pub fn bnot(value :: i16) -> i16 { :zig.Integer.bnot_i16(value) }
  pub fn bnot(value :: i32) -> i32 { :zig.Integer.bnot_i32(value) }
  pub fn bnot(value :: i64) -> i64 { :zig.Integer.bnot_i64(value) }
  pub fn bnot(value :: i128) -> i128 { :zig.Integer.bnot_i128(value) }
  pub fn bnot(value :: u8) -> u8 { :zig.Integer.bnot_u8(value) }
  pub fn bnot(value :: u16) -> u16 { :zig.Integer.bnot_u16(value) }
  pub fn bnot(value :: u32) -> u32 { :zig.Integer.bnot_u32(value) }
  pub fn bnot(value :: u64) -> u64 { :zig.Integer.bnot_u64(value) }
  pub fn bnot(value :: u128) -> u128 { :zig.Integer.bnot_u128(value) }

  @doc = "Bitwise shift left."

  pub fn bsl(value :: i8, amount :: i8) -> i8 { :zig.Integer.bsl_i8(value, amount) }
  pub fn bsl(value :: i16, amount :: i16) -> i16 { :zig.Integer.bsl_i16(value, amount) }
  pub fn bsl(value :: i32, amount :: i32) -> i32 { :zig.Integer.bsl_i32(value, amount) }
  pub fn bsl(value :: i64, amount :: i64) -> i64 { :zig.Integer.bsl_i64(value, amount) }
  pub fn bsl(value :: i128, amount :: i128) -> i128 { :zig.Integer.bsl_i128(value, amount) }
  pub fn bsl(value :: u8, amount :: u8) -> u8 { :zig.Integer.bsl_u8(value, amount) }
  pub fn bsl(value :: u16, amount :: u16) -> u16 { :zig.Integer.bsl_u16(value, amount) }
  pub fn bsl(value :: u32, amount :: u32) -> u32 { :zig.Integer.bsl_u32(value, amount) }
  pub fn bsl(value :: u64, amount :: u64) -> u64 { :zig.Integer.bsl_u64(value, amount) }
  pub fn bsl(value :: u128, amount :: u128) -> u128 { :zig.Integer.bsl_u128(value, amount) }

  @doc = "Bitwise shift right."

  pub fn bsr(value :: i8, amount :: i8) -> i8 { :zig.Integer.bsr_i8(value, amount) }
  pub fn bsr(value :: i16, amount :: i16) -> i16 { :zig.Integer.bsr_i16(value, amount) }
  pub fn bsr(value :: i32, amount :: i32) -> i32 { :zig.Integer.bsr_i32(value, amount) }
  pub fn bsr(value :: i64, amount :: i64) -> i64 { :zig.Integer.bsr_i64(value, amount) }
  pub fn bsr(value :: i128, amount :: i128) -> i128 { :zig.Integer.bsr_i128(value, amount) }
  pub fn bsr(value :: u8, amount :: u8) -> u8 { :zig.Integer.bsr_u8(value, amount) }
  pub fn bsr(value :: u16, amount :: u16) -> u16 { :zig.Integer.bsr_u16(value, amount) }
  pub fn bsr(value :: u32, amount :: u32) -> u32 { :zig.Integer.bsr_u32(value, amount) }
  pub fn bsr(value :: u64, amount :: u64) -> u64 { :zig.Integer.bsr_u64(value, amount) }
  pub fn bsr(value :: u128, amount :: u128) -> u128 { :zig.Integer.bsr_u128(value, amount) }

  @doc = "Returns the sign of an integer."

  pub fn sign(value :: i8) -> i8 { :zig.Integer.sign_i8(value) }
  pub fn sign(value :: i16) -> i16 { :zig.Integer.sign_i16(value) }
  pub fn sign(value :: i32) -> i32 { :zig.Integer.sign_i32(value) }
  pub fn sign(value :: i64) -> i64 { :zig.Integer.sign_i64(value) }
  pub fn sign(value :: i128) -> i128 { :zig.Integer.sign_i128(value) }
  pub fn sign(value :: u8) -> u8 { :zig.Integer.sign_u8(value) }
  pub fn sign(value :: u16) -> u16 { :zig.Integer.sign_u16(value) }
  pub fn sign(value :: u32) -> u32 { :zig.Integer.sign_u32(value) }
  pub fn sign(value :: u64) -> u64 { :zig.Integer.sign_u64(value) }
  pub fn sign(value :: u128) -> u128 { :zig.Integer.sign_u128(value) }

  @doc = "Returns true if the integer is even."

  pub fn even?(value :: i8) -> Bool { :zig.Integer.is_even_i8(value) }
  pub fn even?(value :: i16) -> Bool { :zig.Integer.is_even_i16(value) }
  pub fn even?(value :: i32) -> Bool { :zig.Integer.is_even_i32(value) }
  pub fn even?(value :: i64) -> Bool { :zig.Integer.is_even_i64(value) }
  pub fn even?(value :: i128) -> Bool { :zig.Integer.is_even_i128(value) }
  pub fn even?(value :: u8) -> Bool { :zig.Integer.is_even_u8(value) }
  pub fn even?(value :: u16) -> Bool { :zig.Integer.is_even_u16(value) }
  pub fn even?(value :: u32) -> Bool { :zig.Integer.is_even_u32(value) }
  pub fn even?(value :: u64) -> Bool { :zig.Integer.is_even_u64(value) }
  pub fn even?(value :: u128) -> Bool { :zig.Integer.is_even_u128(value) }

  @doc = "Returns true if the integer is odd."

  pub fn odd?(value :: i8) -> Bool { :zig.Integer.is_odd_i8(value) }
  pub fn odd?(value :: i16) -> Bool { :zig.Integer.is_odd_i16(value) }
  pub fn odd?(value :: i32) -> Bool { :zig.Integer.is_odd_i32(value) }
  pub fn odd?(value :: i64) -> Bool { :zig.Integer.is_odd_i64(value) }
  pub fn odd?(value :: i128) -> Bool { :zig.Integer.is_odd_i128(value) }
  pub fn odd?(value :: u8) -> Bool { :zig.Integer.is_odd_u8(value) }
  pub fn odd?(value :: u16) -> Bool { :zig.Integer.is_odd_u16(value) }
  pub fn odd?(value :: u32) -> Bool { :zig.Integer.is_odd_u32(value) }
  pub fn odd?(value :: u64) -> Bool { :zig.Integer.is_odd_u64(value) }
  pub fn odd?(value :: u128) -> Bool { :zig.Integer.is_odd_u128(value) }

  @doc = "Computes the greatest common divisor of two integers."

  pub fn gcd(first :: i8, second :: i8) -> i8 { :zig.Integer.gcd_i8(first, second) }
  pub fn gcd(first :: i16, second :: i16) -> i16 { :zig.Integer.gcd_i16(first, second) }
  pub fn gcd(first :: i32, second :: i32) -> i32 { :zig.Integer.gcd_i32(first, second) }
  pub fn gcd(first :: i64, second :: i64) -> i64 { :zig.Integer.gcd_i64(first, second) }
  pub fn gcd(first :: i128, second :: i128) -> i128 { :zig.Integer.gcd_i128(first, second) }
  pub fn gcd(first :: u8, second :: u8) -> u8 { :zig.Integer.gcd_u8(first, second) }
  pub fn gcd(first :: u16, second :: u16) -> u16 { :zig.Integer.gcd_u16(first, second) }
  pub fn gcd(first :: u32, second :: u32) -> u32 { :zig.Integer.gcd_u32(first, second) }
  pub fn gcd(first :: u64, second :: u64) -> u64 { :zig.Integer.gcd_u64(first, second) }
  pub fn gcd(first :: u128, second :: u128) -> u128 { :zig.Integer.gcd_u128(first, second) }

  @doc = "Computes the least common multiple of two integers."

  pub fn lcm(first :: i8, second :: i8) -> i8 { :zig.Integer.lcm_i8(first, second) }
  pub fn lcm(first :: i16, second :: i16) -> i16 { :zig.Integer.lcm_i16(first, second) }
  pub fn lcm(first :: i32, second :: i32) -> i32 { :zig.Integer.lcm_i32(first, second) }
  pub fn lcm(first :: i64, second :: i64) -> i64 { :zig.Integer.lcm_i64(first, second) }
  pub fn lcm(first :: i128, second :: i128) -> i128 { :zig.Integer.lcm_i128(first, second) }
  pub fn lcm(first :: u8, second :: u8) -> u8 { :zig.Integer.lcm_u8(first, second) }
  pub fn lcm(first :: u16, second :: u16) -> u16 { :zig.Integer.lcm_u16(first, second) }
  pub fn lcm(first :: u32, second :: u32) -> u32 { :zig.Integer.lcm_u32(first, second) }
  pub fn lcm(first :: u64, second :: u64) -> u64 { :zig.Integer.lcm_u64(first, second) }
  pub fn lcm(first :: u128, second :: u128) -> u128 { :zig.Integer.lcm_u128(first, second) }
}
