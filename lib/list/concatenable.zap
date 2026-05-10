@doc = "Concatenable implementation for `List`."

pub impl Concatenable for List {
  @fndoc = """
  Concatenates two lists.
  """

  pub fn concat(left :: List(element), right :: List(element)) -> List(element) {
    :zig.List.append(left, right)
  }
}
