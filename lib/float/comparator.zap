pub impl Comparator for Float {
  @doc = "IEEE-754 float equality."

  pub fn ==(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.eq(left, right)
  }

  @doc = "IEEE-754 float inequality."

  pub fn !=(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.neq(left, right)
  }

  @doc = "IEEE-754 float less-than."

  pub fn <(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.lt(left, right)
  }

  @doc = "IEEE-754 float greater-than."

  pub fn >(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.gt(left, right)
  }

  @doc = "IEEE-754 float less-than-or-equal."

  pub fn <=(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.lte(left, right)
  }

  @doc = "IEEE-754 float greater-than-or-equal."

  pub fn >=(left :: f64, right :: f64) -> Bool {
    :zig.Kernel.gte(left, right)
  }
}
