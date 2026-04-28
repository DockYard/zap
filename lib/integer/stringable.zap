pub impl Stringable for Integer {
  @doc = """
    Render an i64 as its decimal representation. Calls the runtime
    helper directly because `Integer.to_string` resolves back to this
    impl method — using the Zap-level dispatch would loop forever.
    """

  pub fn to_string(value :: i64) -> String {
    :zig.Integer.to_string(value)
  }
}
