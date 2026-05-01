@doc = "Arithmetic implementation for `Integer`."

pub impl Arithmetic for Integer {
  @doc = "Integer addition. Wrapping on overflow."

  pub fn +(left :: i8, right :: i8) -> i8 { :zig.Kernel.add_i8(left, right) }
  pub fn +(left :: i16, right :: i16) -> i16 { :zig.Kernel.add_i16(left, right) }
  pub fn +(left :: i32, right :: i32) -> i32 { :zig.Kernel.add_i32(left, right) }
  pub fn +(left :: i64, right :: i64) -> i64 { :zig.Kernel.add_i64(left, right) }
  pub fn +(left :: i128, right :: i128) -> i128 { :zig.Kernel.add_i128(left, right) }
  pub fn +(left :: u8, right :: u8) -> u8 { :zig.Kernel.add_u8(left, right) }
  pub fn +(left :: u16, right :: u16) -> u16 { :zig.Kernel.add_u16(left, right) }
  pub fn +(left :: u32, right :: u32) -> u32 { :zig.Kernel.add_u32(left, right) }
  pub fn +(left :: u64, right :: u64) -> u64 { :zig.Kernel.add_u64(left, right) }
  pub fn +(left :: u128, right :: u128) -> u128 { :zig.Kernel.add_u128(left, right) }

  @doc = "Integer subtraction. Wrapping on underflow."

  pub fn -(left :: i8, right :: i8) -> i8 { :zig.Kernel.sub_i8(left, right) }
  pub fn -(left :: i16, right :: i16) -> i16 { :zig.Kernel.sub_i16(left, right) }
  pub fn -(left :: i32, right :: i32) -> i32 { :zig.Kernel.sub_i32(left, right) }
  pub fn -(left :: i64, right :: i64) -> i64 { :zig.Kernel.sub_i64(left, right) }
  pub fn -(left :: i128, right :: i128) -> i128 { :zig.Kernel.sub_i128(left, right) }
  pub fn -(left :: u8, right :: u8) -> u8 { :zig.Kernel.sub_u8(left, right) }
  pub fn -(left :: u16, right :: u16) -> u16 { :zig.Kernel.sub_u16(left, right) }
  pub fn -(left :: u32, right :: u32) -> u32 { :zig.Kernel.sub_u32(left, right) }
  pub fn -(left :: u64, right :: u64) -> u64 { :zig.Kernel.sub_u64(left, right) }
  pub fn -(left :: u128, right :: u128) -> u128 { :zig.Kernel.sub_u128(left, right) }

  @doc = "Integer multiplication. Wrapping on overflow."

  pub fn *(left :: i8, right :: i8) -> i8 { :zig.Kernel.mul_i8(left, right) }
  pub fn *(left :: i16, right :: i16) -> i16 { :zig.Kernel.mul_i16(left, right) }
  pub fn *(left :: i32, right :: i32) -> i32 { :zig.Kernel.mul_i32(left, right) }
  pub fn *(left :: i64, right :: i64) -> i64 { :zig.Kernel.mul_i64(left, right) }
  pub fn *(left :: i128, right :: i128) -> i128 { :zig.Kernel.mul_i128(left, right) }
  pub fn *(left :: u8, right :: u8) -> u8 { :zig.Kernel.mul_u8(left, right) }
  pub fn *(left :: u16, right :: u16) -> u16 { :zig.Kernel.mul_u16(left, right) }
  pub fn *(left :: u32, right :: u32) -> u32 { :zig.Kernel.mul_u32(left, right) }
  pub fn *(left :: u64, right :: u64) -> u64 { :zig.Kernel.mul_u64(left, right) }
  pub fn *(left :: u128, right :: u128) -> u128 { :zig.Kernel.mul_u128(left, right) }

  @doc = "Integer truncating division."

  pub fn /(left :: i8, right :: i8) -> i8 { :zig.Kernel.divide_i8(left, right) }
  pub fn /(left :: i16, right :: i16) -> i16 { :zig.Kernel.divide_i16(left, right) }
  pub fn /(left :: i32, right :: i32) -> i32 { :zig.Kernel.divide_i32(left, right) }
  pub fn /(left :: i64, right :: i64) -> i64 { :zig.Kernel.divide_i64(left, right) }
  pub fn /(left :: i128, right :: i128) -> i128 { :zig.Kernel.divide_i128(left, right) }
  pub fn /(left :: u8, right :: u8) -> u8 { :zig.Kernel.divide_u8(left, right) }
  pub fn /(left :: u16, right :: u16) -> u16 { :zig.Kernel.divide_u16(left, right) }
  pub fn /(left :: u32, right :: u32) -> u32 { :zig.Kernel.divide_u32(left, right) }
  pub fn /(left :: u64, right :: u64) -> u64 { :zig.Kernel.divide_u64(left, right) }
  pub fn /(left :: u128, right :: u128) -> u128 { :zig.Kernel.divide_u128(left, right) }

  @doc = "Integer remainder."

  pub fn rem(left :: i8, right :: i8) -> i8 { :zig.Kernel.remainder_i8(left, right) }
  pub fn rem(left :: i16, right :: i16) -> i16 { :zig.Kernel.remainder_i16(left, right) }
  pub fn rem(left :: i32, right :: i32) -> i32 { :zig.Kernel.remainder_i32(left, right) }
  pub fn rem(left :: i64, right :: i64) -> i64 { :zig.Kernel.remainder_i64(left, right) }
  pub fn rem(left :: i128, right :: i128) -> i128 { :zig.Kernel.remainder_i128(left, right) }
  pub fn rem(left :: u8, right :: u8) -> u8 { :zig.Kernel.remainder_u8(left, right) }
  pub fn rem(left :: u16, right :: u16) -> u16 { :zig.Kernel.remainder_u16(left, right) }
  pub fn rem(left :: u32, right :: u32) -> u32 { :zig.Kernel.remainder_u32(left, right) }
  pub fn rem(left :: u64, right :: u64) -> u64 { :zig.Kernel.remainder_u64(left, right) }
  pub fn rem(left :: u128, right :: u128) -> u128 { :zig.Kernel.remainder_u128(left, right) }
}
