@doc = "Stringable implementation for `Float`."

pub impl Stringable for Float {
  @doc = """
    Render a 64-bit float using the runtime's default formatting.
    Calls the runtime helper directly because `Float.to_string`
    resolves back to this impl method — using the Zap-level
    dispatch would loop forever.
    """

  pub fn to_string(value :: f64) -> String {
    :zig.Float.to_string(value)
  }
}
