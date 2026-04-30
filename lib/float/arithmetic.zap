@doc = "Arithmetic implementation for `Float`."

pub impl Arithmetic for Float {
  @doc = "IEEE-754 float addition."

  pub fn +(left :: f64, right :: f64) -> f64 {
    :zig.Kernel.add(left, right)
  }

  @doc = "IEEE-754 float subtraction."

  pub fn -(left :: f64, right :: f64) -> f64 {
    :zig.Kernel.sub(left, right)
  }

  @doc = "IEEE-754 float multiplication."

  pub fn *(left :: f64, right :: f64) -> f64 {
    :zig.Kernel.mul(left, right)
  }

  @doc = "IEEE-754 float division."

  pub fn /(left :: f64, right :: f64) -> f64 {
    :zig.Kernel.divide(left, right)
  }

  @doc = "Float remainder."

  pub fn rem(left :: f64, right :: f64) -> f64 {
    :zig.Kernel.remainder(left, right)
  }
}
