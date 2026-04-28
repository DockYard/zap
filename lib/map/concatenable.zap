pub impl Concatenable for Map(K, V) {
  @doc = """
    Map concatenation, equivalent to `Map.merge/2`. Entries from
    `right` overwrite entries in `left` when keys collide.
    """

  pub fn concat(left :: %{K => V}, right :: %{K => V}) -> %{K => V} {
    :zig.Map.merge(left, right)
  }
}
