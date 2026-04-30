@doc = "Arithmetic implementation for `Integer`."

pub impl Arithmetic for Integer {
  @doc = "Integer addition. Wrapping on overflow."

  pub fn +(left :: i64, right :: i64) -> i64 {
    :zig.Kernel.add(left, right)
  }

  @doc = "Integer subtraction. Wrapping on underflow."

  pub fn -(left :: i64, right :: i64) -> i64 {
    :zig.Kernel.sub(left, right)
  }

  @doc = "Integer multiplication. Wrapping on overflow."

  pub fn *(left :: i64, right :: i64) -> i64 {
    :zig.Kernel.mul(left, right)
  }

  @doc = "Integer truncating division."

  pub fn /(left :: i64, right :: i64) -> i64 {
    :zig.Kernel.divide(left, right)
  }

  @doc = "Integer remainder."

  pub fn rem(left :: i64, right :: i64) -> i64 {
    :zig.Kernel.remainder(left, right)
  }
}
