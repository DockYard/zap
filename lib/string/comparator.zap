pub impl Comparator for String {
  @doc = "Byte-equal string equality."

  pub fn ==(left :: String, right :: String) -> Bool {
    :zig.Kernel.eq(left, right)
  }

  @doc = "Byte-equal string inequality."

  pub fn !=(left :: String, right :: String) -> Bool {
    :zig.Kernel.neq(left, right)
  }

  @doc = "Lexicographic string less-than."

  pub fn <(left :: String, right :: String) -> Bool {
    :zig.Kernel.lt(left, right)
  }

  @doc = "Lexicographic string greater-than."

  pub fn >(left :: String, right :: String) -> Bool {
    :zig.Kernel.gt(left, right)
  }

  @doc = "Lexicographic string less-than-or-equal."

  pub fn <=(left :: String, right :: String) -> Bool {
    :zig.Kernel.lte(left, right)
  }

  @doc = "Lexicographic string greater-than-or-equal."

  pub fn >=(left :: String, right :: String) -> Bool {
    :zig.Kernel.gte(left, right)
  }
}
