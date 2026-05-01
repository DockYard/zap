@doc = "Comparator implementation for `Integer`."

pub impl Comparator for Integer {
  @doc = "Integer equality."

  pub fn ==(left :: i8, right :: i8) -> Bool { :zig.Kernel.eq_i8(left, right) }
  pub fn ==(left :: i16, right :: i16) -> Bool { :zig.Kernel.eq_i16(left, right) }
  pub fn ==(left :: i32, right :: i32) -> Bool { :zig.Kernel.eq_i32(left, right) }
  pub fn ==(left :: i64, right :: i64) -> Bool { :zig.Kernel.eq_i64(left, right) }
  pub fn ==(left :: i128, right :: i128) -> Bool { :zig.Kernel.eq_i128(left, right) }
  pub fn ==(left :: u8, right :: u8) -> Bool { :zig.Kernel.eq_u8(left, right) }
  pub fn ==(left :: u16, right :: u16) -> Bool { :zig.Kernel.eq_u16(left, right) }
  pub fn ==(left :: u32, right :: u32) -> Bool { :zig.Kernel.eq_u32(left, right) }
  pub fn ==(left :: u64, right :: u64) -> Bool { :zig.Kernel.eq_u64(left, right) }
  pub fn ==(left :: u128, right :: u128) -> Bool { :zig.Kernel.eq_u128(left, right) }

  @doc = "Integer inequality."

  pub fn !=(left :: i8, right :: i8) -> Bool { :zig.Kernel.neq_i8(left, right) }
  pub fn !=(left :: i16, right :: i16) -> Bool { :zig.Kernel.neq_i16(left, right) }
  pub fn !=(left :: i32, right :: i32) -> Bool { :zig.Kernel.neq_i32(left, right) }
  pub fn !=(left :: i64, right :: i64) -> Bool { :zig.Kernel.neq_i64(left, right) }
  pub fn !=(left :: i128, right :: i128) -> Bool { :zig.Kernel.neq_i128(left, right) }
  pub fn !=(left :: u8, right :: u8) -> Bool { :zig.Kernel.neq_u8(left, right) }
  pub fn !=(left :: u16, right :: u16) -> Bool { :zig.Kernel.neq_u16(left, right) }
  pub fn !=(left :: u32, right :: u32) -> Bool { :zig.Kernel.neq_u32(left, right) }
  pub fn !=(left :: u64, right :: u64) -> Bool { :zig.Kernel.neq_u64(left, right) }
  pub fn !=(left :: u128, right :: u128) -> Bool { :zig.Kernel.neq_u128(left, right) }

  @doc = "Integer less-than."

  pub fn <(left :: i8, right :: i8) -> Bool { :zig.Kernel.lt_i8(left, right) }
  pub fn <(left :: i16, right :: i16) -> Bool { :zig.Kernel.lt_i16(left, right) }
  pub fn <(left :: i32, right :: i32) -> Bool { :zig.Kernel.lt_i32(left, right) }
  pub fn <(left :: i64, right :: i64) -> Bool { :zig.Kernel.lt_i64(left, right) }
  pub fn <(left :: i128, right :: i128) -> Bool { :zig.Kernel.lt_i128(left, right) }
  pub fn <(left :: u8, right :: u8) -> Bool { :zig.Kernel.lt_u8(left, right) }
  pub fn <(left :: u16, right :: u16) -> Bool { :zig.Kernel.lt_u16(left, right) }
  pub fn <(left :: u32, right :: u32) -> Bool { :zig.Kernel.lt_u32(left, right) }
  pub fn <(left :: u64, right :: u64) -> Bool { :zig.Kernel.lt_u64(left, right) }
  pub fn <(left :: u128, right :: u128) -> Bool { :zig.Kernel.lt_u128(left, right) }

  @doc = "Integer greater-than."

  pub fn >(left :: i8, right :: i8) -> Bool { :zig.Kernel.gt_i8(left, right) }
  pub fn >(left :: i16, right :: i16) -> Bool { :zig.Kernel.gt_i16(left, right) }
  pub fn >(left :: i32, right :: i32) -> Bool { :zig.Kernel.gt_i32(left, right) }
  pub fn >(left :: i64, right :: i64) -> Bool { :zig.Kernel.gt_i64(left, right) }
  pub fn >(left :: i128, right :: i128) -> Bool { :zig.Kernel.gt_i128(left, right) }
  pub fn >(left :: u8, right :: u8) -> Bool { :zig.Kernel.gt_u8(left, right) }
  pub fn >(left :: u16, right :: u16) -> Bool { :zig.Kernel.gt_u16(left, right) }
  pub fn >(left :: u32, right :: u32) -> Bool { :zig.Kernel.gt_u32(left, right) }
  pub fn >(left :: u64, right :: u64) -> Bool { :zig.Kernel.gt_u64(left, right) }
  pub fn >(left :: u128, right :: u128) -> Bool { :zig.Kernel.gt_u128(left, right) }

  @doc = "Integer less-than-or-equal."

  pub fn <=(left :: i8, right :: i8) -> Bool { :zig.Kernel.lte_i8(left, right) }
  pub fn <=(left :: i16, right :: i16) -> Bool { :zig.Kernel.lte_i16(left, right) }
  pub fn <=(left :: i32, right :: i32) -> Bool { :zig.Kernel.lte_i32(left, right) }
  pub fn <=(left :: i64, right :: i64) -> Bool { :zig.Kernel.lte_i64(left, right) }
  pub fn <=(left :: i128, right :: i128) -> Bool { :zig.Kernel.lte_i128(left, right) }
  pub fn <=(left :: u8, right :: u8) -> Bool { :zig.Kernel.lte_u8(left, right) }
  pub fn <=(left :: u16, right :: u16) -> Bool { :zig.Kernel.lte_u16(left, right) }
  pub fn <=(left :: u32, right :: u32) -> Bool { :zig.Kernel.lte_u32(left, right) }
  pub fn <=(left :: u64, right :: u64) -> Bool { :zig.Kernel.lte_u64(left, right) }
  pub fn <=(left :: u128, right :: u128) -> Bool { :zig.Kernel.lte_u128(left, right) }

  @doc = "Integer greater-than-or-equal."

  pub fn >=(left :: i8, right :: i8) -> Bool { :zig.Kernel.gte_i8(left, right) }
  pub fn >=(left :: i16, right :: i16) -> Bool { :zig.Kernel.gte_i16(left, right) }
  pub fn >=(left :: i32, right :: i32) -> Bool { :zig.Kernel.gte_i32(left, right) }
  pub fn >=(left :: i64, right :: i64) -> Bool { :zig.Kernel.gte_i64(left, right) }
  pub fn >=(left :: i128, right :: i128) -> Bool { :zig.Kernel.gte_i128(left, right) }
  pub fn >=(left :: u8, right :: u8) -> Bool { :zig.Kernel.gte_u8(left, right) }
  pub fn >=(left :: u16, right :: u16) -> Bool { :zig.Kernel.gte_u16(left, right) }
  pub fn >=(left :: u32, right :: u32) -> Bool { :zig.Kernel.gte_u32(left, right) }
  pub fn >=(left :: u64, right :: u64) -> Bool { :zig.Kernel.gte_u64(left, right) }
  pub fn >=(left :: u128, right :: u128) -> Bool { :zig.Kernel.gte_u128(left, right) }
}
