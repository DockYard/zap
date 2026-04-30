@doc = "Comparator implementation for `Integer`."

pub impl Comparator for Integer {
  @doc = "Integer equality."

  pub fn ==(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.eq(left, right)
  }

  @doc = "Integer inequality."

  pub fn !=(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.neq(left, right)
  }

  @doc = "Integer less-than."

  pub fn <(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.lt(left, right)
  }

  @doc = "Integer greater-than."

  pub fn >(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.gt(left, right)
  }

  @doc = "Integer less-than-or-equal."

  pub fn <=(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.lte(left, right)
  }

  @doc = "Integer greater-than-or-equal."

  pub fn >=(left :: i64, right :: i64) -> Bool {
    :zig.Kernel.gte(left, right)
  }
}
