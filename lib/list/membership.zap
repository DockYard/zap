@doc = "Membership implementation for `List`."

pub impl Membership for List {
  @fndoc = """
  Linear scan for `value` in `list`.
  """

  pub fn member?(list :: List(element), value :: element) -> Bool {
    :zig.List.contains(list, value)
  }
}
