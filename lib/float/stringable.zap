@doc = "Stringable implementation for `Float`."

pub impl Stringable for Float {
  @doc = """
    Render a float using the runtime's default formatting. Calls the
    concrete runtime helper directly because `Float.to_string`
    resolves back to this impl method.
    """

  pub fn to_string(value :: f16) -> String { :zig.Float.to_string_f16(value) }
  pub fn to_string(value :: f32) -> String { :zig.Float.to_string_f32(value) }
  pub fn to_string(value :: f64) -> String { :zig.Float.to_string_f64(value) }
}
