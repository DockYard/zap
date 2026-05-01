@doc = """
  Mathematical functions for numeric computation.

  Provides trigonometric, exponential, logarithmic, and other
  mathematical operations on numeric values. Functions with numeric
  arguments define exact clauses for `i8`, `i16`, `i32`, `i64`,
  `i128`, `u8`, `u16`, `u32`, `u64`, `u128`, `f16`, `f32`, `f64`,
  `f80`, and `f128` instead of relying on widening.

  Float inputs preserve the caller's concrete float type. Integer
  inputs return `f64`, except `i128` and `u128` inputs which return
  `f128` to avoid forcing 128-bit values through a narrower result
  type.

  ## Constants

  Use `Math.pi()` and `Math.e()` for the standard mathematical
  constants.

  ## Examples

      Math.sqrt(9.0)      # => 3.0
      Math.sin(Math.pi()) # => ~0.0
      Math.log(Math.e())  # => 1.0
  """

pub struct Math {
  @doc = """
    Returns the ratio of a circle's circumference to its diameter.

    ## Examples

        Math.pi()  # => 3.141592653589793
    """

  pub fn pi() -> f64 {
    3.141592653589793
  }

  @doc = """
    Returns Euler's number, the base of natural logarithms.

    ## Examples

        Math.e()  # => 2.718281828459045
    """

  pub fn e() -> f64 {
    2.718281828459045
  }

  @doc = """
    Returns the square root of a number.

    ## Examples

        Math.sqrt(9.0)   # => 3.0
        Math.sqrt(2.0)   # => 1.4142135623730951
        Math.sqrt(0.0)   # => 0.0
    """

  pub fn sqrt(value :: f64) -> f64 {
    :zig.Math.sqrt_f64(value)
  }

  pub fn sqrt(value :: i8) -> f64 { :zig.Math.sqrt_i8(value) }
  pub fn sqrt(value :: i16) -> f64 { :zig.Math.sqrt_i16(value) }
  pub fn sqrt(value :: i32) -> f64 { :zig.Math.sqrt_i32(value) }
  pub fn sqrt(value :: i64) -> f64 { :zig.Math.sqrt_i64(value) }
  pub fn sqrt(value :: i128) -> f128 { :zig.Math.sqrt_i128(value) }
  pub fn sqrt(value :: u8) -> f64 { :zig.Math.sqrt_u8(value) }
  pub fn sqrt(value :: u16) -> f64 { :zig.Math.sqrt_u16(value) }
  pub fn sqrt(value :: u32) -> f64 { :zig.Math.sqrt_u32(value) }
  pub fn sqrt(value :: u64) -> f64 { :zig.Math.sqrt_u64(value) }
  pub fn sqrt(value :: u128) -> f128 { :zig.Math.sqrt_u128(value) }
  pub fn sqrt(value :: f16) -> f16 { :zig.Math.sqrt_f16(value) }
  pub fn sqrt(value :: f32) -> f32 { :zig.Math.sqrt_f32(value) }
  pub fn sqrt(value :: f80) -> f80 { :zig.Math.sqrt_f80(value) }
  pub fn sqrt(value :: f128) -> f128 { :zig.Math.sqrt_f128(value) }

  @doc = """
    Returns the sine of an angle in radians.

    ## Examples

        Math.sin(0.0)          # => 0.0
        Math.sin(Math.pi())    # => ~0.0
    """

  pub fn sin(value :: f64) -> f64 {
    :zig.Math.sin_f64(value)
  }

  pub fn sin(value :: i8) -> f64 { :zig.Math.sin_i8(value) }
  pub fn sin(value :: i16) -> f64 { :zig.Math.sin_i16(value) }
  pub fn sin(value :: i32) -> f64 { :zig.Math.sin_i32(value) }
  pub fn sin(value :: i64) -> f64 { :zig.Math.sin_i64(value) }
  pub fn sin(value :: i128) -> f128 { :zig.Math.sin_i128(value) }
  pub fn sin(value :: u8) -> f64 { :zig.Math.sin_u8(value) }
  pub fn sin(value :: u16) -> f64 { :zig.Math.sin_u16(value) }
  pub fn sin(value :: u32) -> f64 { :zig.Math.sin_u32(value) }
  pub fn sin(value :: u64) -> f64 { :zig.Math.sin_u64(value) }
  pub fn sin(value :: u128) -> f128 { :zig.Math.sin_u128(value) }
  pub fn sin(value :: f16) -> f16 { :zig.Math.sin_f16(value) }
  pub fn sin(value :: f32) -> f32 { :zig.Math.sin_f32(value) }
  pub fn sin(value :: f80) -> f80 { :zig.Math.sin_f80(value) }
  pub fn sin(value :: f128) -> f128 { :zig.Math.sin_f128(value) }

  @doc = """
    Returns the cosine of an angle in radians.

    ## Examples

        Math.cos(0.0)          # => 1.0
        Math.cos(Math.pi())    # => -1.0
    """

  pub fn cos(value :: f64) -> f64 {
    :zig.Math.cos_f64(value)
  }

  pub fn cos(value :: i8) -> f64 { :zig.Math.cos_i8(value) }
  pub fn cos(value :: i16) -> f64 { :zig.Math.cos_i16(value) }
  pub fn cos(value :: i32) -> f64 { :zig.Math.cos_i32(value) }
  pub fn cos(value :: i64) -> f64 { :zig.Math.cos_i64(value) }
  pub fn cos(value :: i128) -> f128 { :zig.Math.cos_i128(value) }
  pub fn cos(value :: u8) -> f64 { :zig.Math.cos_u8(value) }
  pub fn cos(value :: u16) -> f64 { :zig.Math.cos_u16(value) }
  pub fn cos(value :: u32) -> f64 { :zig.Math.cos_u32(value) }
  pub fn cos(value :: u64) -> f64 { :zig.Math.cos_u64(value) }
  pub fn cos(value :: u128) -> f128 { :zig.Math.cos_u128(value) }
  pub fn cos(value :: f16) -> f16 { :zig.Math.cos_f16(value) }
  pub fn cos(value :: f32) -> f32 { :zig.Math.cos_f32(value) }
  pub fn cos(value :: f80) -> f80 { :zig.Math.cos_f80(value) }
  pub fn cos(value :: f128) -> f128 { :zig.Math.cos_f128(value) }

  @doc = """
    Returns the tangent of an angle in radians.

    ## Examples

        Math.tan(0.0)   # => 0.0
    """

  pub fn tan(value :: f64) -> f64 {
    :zig.Math.tan_f64(value)
  }

  pub fn tan(value :: i8) -> f64 { :zig.Math.tan_i8(value) }
  pub fn tan(value :: i16) -> f64 { :zig.Math.tan_i16(value) }
  pub fn tan(value :: i32) -> f64 { :zig.Math.tan_i32(value) }
  pub fn tan(value :: i64) -> f64 { :zig.Math.tan_i64(value) }
  pub fn tan(value :: i128) -> f128 { :zig.Math.tan_i128(value) }
  pub fn tan(value :: u8) -> f64 { :zig.Math.tan_u8(value) }
  pub fn tan(value :: u16) -> f64 { :zig.Math.tan_u16(value) }
  pub fn tan(value :: u32) -> f64 { :zig.Math.tan_u32(value) }
  pub fn tan(value :: u64) -> f64 { :zig.Math.tan_u64(value) }
  pub fn tan(value :: u128) -> f128 { :zig.Math.tan_u128(value) }
  pub fn tan(value :: f16) -> f16 { :zig.Math.tan_f16(value) }
  pub fn tan(value :: f32) -> f32 { :zig.Math.tan_f32(value) }
  pub fn tan(value :: f80) -> f80 { :zig.Math.tan_f80(value) }
  pub fn tan(value :: f128) -> f128 { :zig.Math.tan_f128(value) }

  @doc = """
    Returns e raised to the given power.

    ## Examples

        Math.exp(0.0)   # => 1.0
        Math.exp(1.0)   # => 2.718281828459045
    """

  pub fn exp(value :: f64) -> f64 {
    :zig.Math.exp_f64(value)
  }

  pub fn exp(value :: i8) -> f64 { :zig.Math.exp_i8(value) }
  pub fn exp(value :: i16) -> f64 { :zig.Math.exp_i16(value) }
  pub fn exp(value :: i32) -> f64 { :zig.Math.exp_i32(value) }
  pub fn exp(value :: i64) -> f64 { :zig.Math.exp_i64(value) }
  pub fn exp(value :: i128) -> f128 { :zig.Math.exp_i128(value) }
  pub fn exp(value :: u8) -> f64 { :zig.Math.exp_u8(value) }
  pub fn exp(value :: u16) -> f64 { :zig.Math.exp_u16(value) }
  pub fn exp(value :: u32) -> f64 { :zig.Math.exp_u32(value) }
  pub fn exp(value :: u64) -> f64 { :zig.Math.exp_u64(value) }
  pub fn exp(value :: u128) -> f128 { :zig.Math.exp_u128(value) }
  pub fn exp(value :: f16) -> f16 { :zig.Math.exp_f16(value) }
  pub fn exp(value :: f32) -> f32 { :zig.Math.exp_f32(value) }
  pub fn exp(value :: f80) -> f80 { :zig.Math.exp_f80(value) }
  pub fn exp(value :: f128) -> f128 { :zig.Math.exp_f128(value) }

  @doc = """
    Returns 2 raised to the given power.

    ## Examples

        Math.exp2(3.0)   # => 8.0
        Math.exp2(0.0)   # => 1.0
    """

  pub fn exp2(value :: f64) -> f64 {
    :zig.Math.exp2_f64(value)
  }

  pub fn exp2(value :: i8) -> f64 { :zig.Math.exp2_i8(value) }
  pub fn exp2(value :: i16) -> f64 { :zig.Math.exp2_i16(value) }
  pub fn exp2(value :: i32) -> f64 { :zig.Math.exp2_i32(value) }
  pub fn exp2(value :: i64) -> f64 { :zig.Math.exp2_i64(value) }
  pub fn exp2(value :: i128) -> f128 { :zig.Math.exp2_i128(value) }
  pub fn exp2(value :: u8) -> f64 { :zig.Math.exp2_u8(value) }
  pub fn exp2(value :: u16) -> f64 { :zig.Math.exp2_u16(value) }
  pub fn exp2(value :: u32) -> f64 { :zig.Math.exp2_u32(value) }
  pub fn exp2(value :: u64) -> f64 { :zig.Math.exp2_u64(value) }
  pub fn exp2(value :: u128) -> f128 { :zig.Math.exp2_u128(value) }
  pub fn exp2(value :: f16) -> f16 { :zig.Math.exp2_f16(value) }
  pub fn exp2(value :: f32) -> f32 { :zig.Math.exp2_f32(value) }
  pub fn exp2(value :: f80) -> f80 { :zig.Math.exp2_f80(value) }
  pub fn exp2(value :: f128) -> f128 { :zig.Math.exp2_f128(value) }

  @doc = """
    Returns the natural logarithm (base e) of a number.

    ## Examples

        Math.log(1.0)         # => 0.0
        Math.log(Math.e())    # => 1.0
    """

  pub fn log(value :: f64) -> f64 {
    :zig.Math.log_f64(value)
  }

  pub fn log(value :: i8) -> f64 { :zig.Math.log_i8(value) }
  pub fn log(value :: i16) -> f64 { :zig.Math.log_i16(value) }
  pub fn log(value :: i32) -> f64 { :zig.Math.log_i32(value) }
  pub fn log(value :: i64) -> f64 { :zig.Math.log_i64(value) }
  pub fn log(value :: i128) -> f128 { :zig.Math.log_i128(value) }
  pub fn log(value :: u8) -> f64 { :zig.Math.log_u8(value) }
  pub fn log(value :: u16) -> f64 { :zig.Math.log_u16(value) }
  pub fn log(value :: u32) -> f64 { :zig.Math.log_u32(value) }
  pub fn log(value :: u64) -> f64 { :zig.Math.log_u64(value) }
  pub fn log(value :: u128) -> f128 { :zig.Math.log_u128(value) }
  pub fn log(value :: f16) -> f16 { :zig.Math.log_f16(value) }
  pub fn log(value :: f32) -> f32 { :zig.Math.log_f32(value) }
  pub fn log(value :: f80) -> f80 { :zig.Math.log_f80(value) }
  pub fn log(value :: f128) -> f128 { :zig.Math.log_f128(value) }

  @doc = """
    Returns the base-2 logarithm of a number.

    ## Examples

        Math.log2(8.0)   # => 3.0
        Math.log2(1.0)   # => 0.0
    """

  pub fn log2(value :: f64) -> f64 {
    :zig.Math.log2_f64(value)
  }

  pub fn log2(value :: i8) -> f64 { :zig.Math.log2_i8(value) }
  pub fn log2(value :: i16) -> f64 { :zig.Math.log2_i16(value) }
  pub fn log2(value :: i32) -> f64 { :zig.Math.log2_i32(value) }
  pub fn log2(value :: i64) -> f64 { :zig.Math.log2_i64(value) }
  pub fn log2(value :: i128) -> f128 { :zig.Math.log2_i128(value) }
  pub fn log2(value :: u8) -> f64 { :zig.Math.log2_u8(value) }
  pub fn log2(value :: u16) -> f64 { :zig.Math.log2_u16(value) }
  pub fn log2(value :: u32) -> f64 { :zig.Math.log2_u32(value) }
  pub fn log2(value :: u64) -> f64 { :zig.Math.log2_u64(value) }
  pub fn log2(value :: u128) -> f128 { :zig.Math.log2_u128(value) }
  pub fn log2(value :: f16) -> f16 { :zig.Math.log2_f16(value) }
  pub fn log2(value :: f32) -> f32 { :zig.Math.log2_f32(value) }
  pub fn log2(value :: f80) -> f80 { :zig.Math.log2_f80(value) }
  pub fn log2(value :: f128) -> f128 { :zig.Math.log2_f128(value) }

  @doc = """
    Returns the base-10 logarithm of a number.

    ## Examples

        Math.log10(1000.0)   # => 3.0
        Math.log10(1.0)      # => 0.0
    """

  pub fn log10(value :: f64) -> f64 {
    :zig.Math.log10_f64(value)
  }

  pub fn log10(value :: i8) -> f64 { :zig.Math.log10_i8(value) }
  pub fn log10(value :: i16) -> f64 { :zig.Math.log10_i16(value) }
  pub fn log10(value :: i32) -> f64 { :zig.Math.log10_i32(value) }
  pub fn log10(value :: i64) -> f64 { :zig.Math.log10_i64(value) }
  pub fn log10(value :: i128) -> f128 { :zig.Math.log10_i128(value) }
  pub fn log10(value :: u8) -> f64 { :zig.Math.log10_u8(value) }
  pub fn log10(value :: u16) -> f64 { :zig.Math.log10_u16(value) }
  pub fn log10(value :: u32) -> f64 { :zig.Math.log10_u32(value) }
  pub fn log10(value :: u64) -> f64 { :zig.Math.log10_u64(value) }
  pub fn log10(value :: u128) -> f128 { :zig.Math.log10_u128(value) }
  pub fn log10(value :: f16) -> f16 { :zig.Math.log10_f16(value) }
  pub fn log10(value :: f32) -> f32 { :zig.Math.log10_f32(value) }
  pub fn log10(value :: f80) -> f80 { :zig.Math.log10_f80(value) }
  pub fn log10(value :: f128) -> f128 { :zig.Math.log10_f128(value) }
}
