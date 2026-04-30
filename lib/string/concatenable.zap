@doc = "Concatenable implementation for `String`."

pub impl Concatenable for String {
  @doc = """
    String concatenation. Allocates a fresh string in the runtime
    bump allocator containing `left ++ right`.
    """

  pub fn concat(left :: String, right :: String) -> String {
    :zig.String.concat(left, right)
  }
}
