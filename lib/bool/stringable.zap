pub impl Stringable for Bool {
  @doc = """
    Render a boolean as `"true"` or `"false"`. Calls the runtime
    helper directly because `Bool.to_string` resolves back to this
    impl method — using the Zap-level dispatch would loop forever.
    """

  pub fn to_string(value :: Bool) -> String {
    :zig.Bool.to_string(value)
  }
}
