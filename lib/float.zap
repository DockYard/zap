@doc = """
  Functions for working with floating-point numbers.

  ## Float Types

  Zap supports the following floating-point types:

  | Type  | Bits | Precision        |
  |-------|------|------------------|
  | `f16` | 16   | Half precision   |
  | `f32` | 32   | Single precision |
  | `f64` | 64   | Double precision |
  | `f80` | 80   | Extended precision |
  | `f128` | 128 | Quad precision   |

  The default float type for literals is `f64`.

  ## Call Resolution

  Zap first looks for an exact typed function clause. If no exact
  clause exists, it may widen within the float family:

  `f16` -> `f32` -> `f64` -> `f80` -> `f128`

  Integer-to-float conversion is not implicit because large integers
  cannot always be represented exactly in floating-point. Use
  `Integer.to_float/1` when needed.
  """

pub struct Float {
  @doc = "Converts a floating-point number to its string representation."

  pub fn to_string(value :: f16) -> String { :zig.Float.to_string_f16(value) }
  pub fn to_string(value :: f32) -> String { :zig.Float.to_string_f32(value) }
  pub fn to_string(value :: f64) -> String { :zig.Float.to_string_f64(value) }
  pub fn to_string(value :: f80) -> String { :zig.Float.to_string_f80(value) }
  pub fn to_string(value :: f128) -> String { :zig.Float.to_string_f128(value) }

  @doc = "Returns the absolute value of a float."

  pub fn abs(value :: f16) -> f16 { :zig.Float.abs_f16(value) }
  pub fn abs(value :: f32) -> f32 { :zig.Float.abs_f32(value) }
  pub fn abs(value :: f64) -> f64 { :zig.Float.abs_f64(value) }
  pub fn abs(value :: f80) -> f80 { :zig.Float.abs_f80(value) }
  pub fn abs(value :: f128) -> f128 { :zig.Float.abs_f128(value) }

  @doc = "Returns the larger of two floats."

  pub fn max(first :: f16, second :: f16) -> f16 { :zig.Float.max_f16(first, second) }
  pub fn max(first :: f32, second :: f32) -> f32 { :zig.Float.max_f32(first, second) }
  pub fn max(first :: f64, second :: f64) -> f64 { :zig.Float.max_f64(first, second) }
  pub fn max(first :: f80, second :: f80) -> f80 { :zig.Float.max_f80(first, second) }
  pub fn max(first :: f128, second :: f128) -> f128 { :zig.Float.max_f128(first, second) }

  @doc = "Returns the smaller of two floats."

  pub fn min(first :: f16, second :: f16) -> f16 { :zig.Float.min_f16(first, second) }
  pub fn min(first :: f32, second :: f32) -> f32 { :zig.Float.min_f32(first, second) }
  pub fn min(first :: f64, second :: f64) -> f64 { :zig.Float.min_f64(first, second) }
  pub fn min(first :: f80, second :: f80) -> f80 { :zig.Float.min_f80(first, second) }
  pub fn min(first :: f128, second :: f128) -> f128 { :zig.Float.min_f128(first, second) }

  @doc = """
    Parses a string into a float. Returns 0.0 if the string is not
    a valid float representation.
    """

  pub fn parse(input :: String) -> f64 {
    :zig.Float.parse(input)
  }

  @doc = "Rounds a float to the nearest integer value, returned as a float."

  pub fn round(value :: f16) -> f16 { :zig.Float.round_f16(value) }
  pub fn round(value :: f32) -> f32 { :zig.Float.round_f32(value) }
  pub fn round(value :: f64) -> f64 { :zig.Float.round_f64(value) }
  pub fn round(value :: f80) -> f80 { :zig.Float.round_f80(value) }
  pub fn round(value :: f128) -> f128 { :zig.Float.round_f128(value) }

  @doc = "Returns the largest integer value less than or equal to the given float."

  pub fn floor(value :: f16) -> f16 { :zig.Float.floor_f16(value) }
  pub fn floor(value :: f32) -> f32 { :zig.Float.floor_f32(value) }
  pub fn floor(value :: f64) -> f64 { :zig.Float.floor_f64(value) }
  pub fn floor(value :: f80) -> f80 { :zig.Float.floor_f80(value) }
  pub fn floor(value :: f128) -> f128 { :zig.Float.floor_f128(value) }

  @doc = "Returns the smallest integer value greater than or equal to the given float."

  pub fn ceil(value :: f16) -> f16 { :zig.Float.ceil_f16(value) }
  pub fn ceil(value :: f32) -> f32 { :zig.Float.ceil_f32(value) }
  pub fn ceil(value :: f64) -> f64 { :zig.Float.ceil_f64(value) }
  pub fn ceil(value :: f80) -> f80 { :zig.Float.ceil_f80(value) }
  pub fn ceil(value :: f128) -> f128 { :zig.Float.ceil_f128(value) }

  @doc = "Truncates a float toward zero, removing the fractional part."

  pub fn truncate(value :: f16) -> f16 { :zig.Float.trunc_f16(value) }
  pub fn truncate(value :: f32) -> f32 { :zig.Float.trunc_f32(value) }
  pub fn truncate(value :: f64) -> f64 { :zig.Float.trunc_f64(value) }
  pub fn truncate(value :: f80) -> f80 { :zig.Float.trunc_f80(value) }
  pub fn truncate(value :: f128) -> f128 { :zig.Float.trunc_f128(value) }

  @doc = "Converts a float to an integer by truncating toward zero."

  pub fn to_integer(value :: f16) -> i64 { :zig.Float.to_i64_f16(value) }
  pub fn to_integer(value :: f32) -> i64 { :zig.Float.to_i64_f32(value) }
  pub fn to_integer(value :: f64) -> i64 { :zig.Float.to_i64_f64(value) }
  pub fn to_integer(value :: f80) -> i64 { :zig.Float.to_i64_f80(value) }
  pub fn to_integer(value :: f128) -> i64 { :zig.Float.to_i64_f128(value) }

  @doc = "Clamps a float to be within the given range."

  pub fn clamp(value :: f16, lower :: f16, upper :: f16) -> f16 { :zig.Float.clamp_f16(value, lower, upper) }
  pub fn clamp(value :: f32, lower :: f32, upper :: f32) -> f32 { :zig.Float.clamp_f32(value, lower, upper) }
  pub fn clamp(value :: f64, lower :: f64, upper :: f64) -> f64 { :zig.Float.clamp_f64(value, lower, upper) }
  pub fn clamp(value :: f80, lower :: f80, upper :: f80) -> f80 { :zig.Float.clamp_f80(value, lower, upper) }
  pub fn clamp(value :: f128, lower :: f128, upper :: f128) -> f128 { :zig.Float.clamp_f128(value, lower, upper) }

  @doc = """
    Floors a float and converts directly to an integer in one step.
    More efficient than `Float.to_integer(Float.floor(x))`.
    """

  pub fn floor_to_integer(value :: f16) -> i64 { :zig.Math.floor_to_i64_f16(value) }
  pub fn floor_to_integer(value :: f32) -> i64 { :zig.Math.floor_to_i64_f32(value) }
  pub fn floor_to_integer(value :: f64) -> i64 { :zig.Math.floor_to_i64_f64(value) }
  pub fn floor_to_integer(value :: f80) -> i64 { :zig.Math.floor_to_i64_f80(value) }
  pub fn floor_to_integer(value :: f128) -> i64 { :zig.Math.floor_to_i64_f128(value) }

  @doc = """
    Ceils a float and converts directly to an integer in one step.
    More efficient than `Float.to_integer(Float.ceil(x))`.
    """

  pub fn ceil_to_integer(value :: f16) -> i64 { :zig.Math.ceil_to_i64_f16(value) }
  pub fn ceil_to_integer(value :: f32) -> i64 { :zig.Math.ceil_to_i64_f32(value) }
  pub fn ceil_to_integer(value :: f64) -> i64 { :zig.Math.ceil_to_i64_f64(value) }
  pub fn ceil_to_integer(value :: f80) -> i64 { :zig.Math.ceil_to_i64_f80(value) }
  pub fn ceil_to_integer(value :: f128) -> i64 { :zig.Math.ceil_to_i64_f128(value) }

  @doc = """
    Rounds a float and converts directly to an integer in one step.
    More efficient than `Float.to_integer(Float.round(x))`.
    """

  pub fn round_to_integer(value :: f16) -> i64 { :zig.Math.round_to_i64_f16(value) }
  pub fn round_to_integer(value :: f32) -> i64 { :zig.Math.round_to_i64_f32(value) }
  pub fn round_to_integer(value :: f64) -> i64 { :zig.Math.round_to_i64_f64(value) }
  pub fn round_to_integer(value :: f80) -> i64 { :zig.Math.round_to_i64_f80(value) }
  pub fn round_to_integer(value :: f128) -> i64 { :zig.Math.round_to_i64_f128(value) }
}
