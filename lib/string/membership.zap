pub impl Membership for String {
  @doc = """
    Substring check — true when `needle` appears anywhere in `haystack`.
    Empty needle is always a member.
    """

  pub fn member?(haystack :: String, needle :: String) -> Bool {
    :zig.String.contains(haystack, needle)
  }
}
