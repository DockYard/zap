@doc = "Comparator implementation for `Float`."

pub impl Comparator for Float {
  @doc = "IEEE-754 float equality."

  pub fn ==(left :: f16, right :: f16) -> Bool { :zig.Kernel.eq_f16(left, right) }
  pub fn ==(left :: f32, right :: f32) -> Bool { :zig.Kernel.eq_f32(left, right) }
  pub fn ==(left :: f64, right :: f64) -> Bool { :zig.Kernel.eq_f64(left, right) }

  @doc = "IEEE-754 float inequality."

  pub fn !=(left :: f16, right :: f16) -> Bool { :zig.Kernel.neq_f16(left, right) }
  pub fn !=(left :: f32, right :: f32) -> Bool { :zig.Kernel.neq_f32(left, right) }
  pub fn !=(left :: f64, right :: f64) -> Bool { :zig.Kernel.neq_f64(left, right) }

  @doc = "IEEE-754 float less-than."

  pub fn <(left :: f16, right :: f16) -> Bool { :zig.Kernel.lt_f16(left, right) }
  pub fn <(left :: f32, right :: f32) -> Bool { :zig.Kernel.lt_f32(left, right) }
  pub fn <(left :: f64, right :: f64) -> Bool { :zig.Kernel.lt_f64(left, right) }

  @doc = "IEEE-754 float greater-than."

  pub fn >(left :: f16, right :: f16) -> Bool { :zig.Kernel.gt_f16(left, right) }
  pub fn >(left :: f32, right :: f32) -> Bool { :zig.Kernel.gt_f32(left, right) }
  pub fn >(left :: f64, right :: f64) -> Bool { :zig.Kernel.gt_f64(left, right) }

  @doc = "IEEE-754 float less-than-or-equal."

  pub fn <=(left :: f16, right :: f16) -> Bool { :zig.Kernel.lte_f16(left, right) }
  pub fn <=(left :: f32, right :: f32) -> Bool { :zig.Kernel.lte_f32(left, right) }
  pub fn <=(left :: f64, right :: f64) -> Bool { :zig.Kernel.lte_f64(left, right) }

  @doc = "IEEE-754 float greater-than-or-equal."

  pub fn >=(left :: f16, right :: f16) -> Bool { :zig.Kernel.gte_f16(left, right) }
  pub fn >=(left :: f32, right :: f32) -> Bool { :zig.Kernel.gte_f32(left, right) }
  pub fn >=(left :: f64, right :: f64) -> Bool { :zig.Kernel.gte_f64(left, right) }
}
