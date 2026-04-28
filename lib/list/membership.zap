pub impl Membership for List {
  @doc = """
    Linear scan for `value` in `list`. O(n).
    """

  pub fn member?(list :: [element], value :: element) -> Bool {
    :zig.List.contains(list, value)
  }
}
