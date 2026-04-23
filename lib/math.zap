@doc = """
  Mathematical functions for floating-point computation.

  Provides trigonometric, exponential, logarithmic, and other
  mathematical operations on `f64` values. All functions delegate
  to Zig's hardware-accelerated builtins for optimal performance.

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

  @doc = """
    Returns the sine of an angle in radians.

    ## Examples

        Math.sin(0.0)          # => 0.0
        Math.sin(Math.pi())    # => ~0.0
    """

  pub fn sin(value :: f64) -> f64 {
    :zig.Math.sin_f64(value)
  }

  @doc = """
    Returns the cosine of an angle in radians.

    ## Examples

        Math.cos(0.0)          # => 1.0
        Math.cos(Math.pi())    # => -1.0
    """

  pub fn cos(value :: f64) -> f64 {
    :zig.Math.cos_f64(value)
  }

  @doc = """
    Returns the tangent of an angle in radians.

    ## Examples

        Math.tan(0.0)   # => 0.0
    """

  pub fn tan(value :: f64) -> f64 {
    :zig.Math.tan_f64(value)
  }

  @doc = """
    Returns e raised to the given power.

    ## Examples

        Math.exp(0.0)   # => 1.0
        Math.exp(1.0)   # => 2.718281828459045
    """

  pub fn exp(value :: f64) -> f64 {
    :zig.Math.exp_f64(value)
  }

  @doc = """
    Returns 2 raised to the given power.

    ## Examples

        Math.exp2(3.0)   # => 8.0
        Math.exp2(0.0)   # => 1.0
    """

  pub fn exp2(value :: f64) -> f64 {
    :zig.Math.exp2_f64(value)
  }

  @doc = """
    Returns the natural logarithm (base e) of a number.

    ## Examples

        Math.log(1.0)         # => 0.0
        Math.log(Math.e())    # => 1.0
    """

  pub fn log(value :: f64) -> f64 {
    :zig.Math.log_f64(value)
  }

  @doc = """
    Returns the base-2 logarithm of a number.

    ## Examples

        Math.log2(8.0)   # => 3.0
        Math.log2(1.0)   # => 0.0
    """

  pub fn log2(value :: f64) -> f64 {
    :zig.Math.log2_f64(value)
  }

  @doc = """
    Returns the base-10 logarithm of a number.

    ## Examples

        Math.log10(1000.0)   # => 3.0
        Math.log10(1.0)      # => 0.0
    """

  pub fn log10(value :: f64) -> f64 {
    :zig.Math.log10_f64(value)
  }
}
