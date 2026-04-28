pub impl Stringable for String {
  @doc = """
    Identity: a string is already a string. Provided so generic code
    that calls `Stringable.to_string` doesn't need to special-case
    strings.
    """

  pub fn to_string(value :: String) -> String {
    value
  }
}
