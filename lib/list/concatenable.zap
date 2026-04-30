@doc = "Concatenable implementation for `List`."

pub impl Concatenable for List {
  @doc = """
    List concatenation. The result reuses the tail's spine; the head
    list's cells are copied so the original lists remain unchanged.
    """

  pub fn concat(left :: [element], right :: [element]) -> [element] {
    :zig.List.concat(left, right)
  }
}
