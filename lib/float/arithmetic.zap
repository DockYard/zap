@doc = "Arithmetic implementation for `Float`."

pub impl Arithmetic for Float {
  @doc = "IEEE-754 float addition."

  pub fn +(left :: f16, right :: f16) -> f16 { :zig.Kernel.add_f16(left, right) }
  pub fn +(left :: f32, right :: f32) -> f32 { :zig.Kernel.add_f32(left, right) }
  pub fn +(left :: f64, right :: f64) -> f64 { :zig.Kernel.add_f64(left, right) }
  pub fn +(left :: f80, right :: f80) -> f80 { :zig.Kernel.add_f80(left, right) }
  pub fn +(left :: f128, right :: f128) -> f128 { :zig.Kernel.add_f128(left, right) }

  @doc = "IEEE-754 float subtraction."

  pub fn -(left :: f16, right :: f16) -> f16 { :zig.Kernel.sub_f16(left, right) }
  pub fn -(left :: f32, right :: f32) -> f32 { :zig.Kernel.sub_f32(left, right) }
  pub fn -(left :: f64, right :: f64) -> f64 { :zig.Kernel.sub_f64(left, right) }
  pub fn -(left :: f80, right :: f80) -> f80 { :zig.Kernel.sub_f80(left, right) }
  pub fn -(left :: f128, right :: f128) -> f128 { :zig.Kernel.sub_f128(left, right) }

  @doc = "IEEE-754 float multiplication."

  pub fn *(left :: f16, right :: f16) -> f16 { :zig.Kernel.mul_f16(left, right) }
  pub fn *(left :: f32, right :: f32) -> f32 { :zig.Kernel.mul_f32(left, right) }
  pub fn *(left :: f64, right :: f64) -> f64 { :zig.Kernel.mul_f64(left, right) }
  pub fn *(left :: f80, right :: f80) -> f80 { :zig.Kernel.mul_f80(left, right) }
  pub fn *(left :: f128, right :: f128) -> f128 { :zig.Kernel.mul_f128(left, right) }

  @doc = "IEEE-754 float division."

  pub fn /(left :: f16, right :: f16) -> f16 { :zig.Kernel.divide_f16(left, right) }
  pub fn /(left :: f32, right :: f32) -> f32 { :zig.Kernel.divide_f32(left, right) }
  pub fn /(left :: f64, right :: f64) -> f64 { :zig.Kernel.divide_f64(left, right) }
  pub fn /(left :: f80, right :: f80) -> f80 { :zig.Kernel.divide_f80(left, right) }
  pub fn /(left :: f128, right :: f128) -> f128 { :zig.Kernel.divide_f128(left, right) }

  @doc = "Float remainder."

  pub fn rem(left :: f16, right :: f16) -> f16 { :zig.Kernel.remainder_f16(left, right) }
  pub fn rem(left :: f32, right :: f32) -> f32 { :zig.Kernel.remainder_f32(left, right) }
  pub fn rem(left :: f64, right :: f64) -> f64 { :zig.Kernel.remainder_f64(left, right) }
  pub fn rem(left :: f80, right :: f80) -> f80 { :zig.Kernel.remainder_f80(left, right) }
  pub fn rem(left :: f128, right :: f128) -> f128 { :zig.Kernel.remainder_f128(left, right) }
}
