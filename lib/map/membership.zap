pub impl Membership for Map(K, V) {
  @doc = """
    Key membership — true when `key` exists in `map`. Mirrors
    `Map.has_key?/2`.
    """

  pub fn member?(map :: %{K => V}, key :: K) -> Bool {
    :zig.Map.has_key(map, key)
  }
}
