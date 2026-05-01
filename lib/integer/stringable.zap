@doc = "Stringable implementation for `Integer`."

pub impl Stringable for Integer {
  @doc = """
    Render an integer as its decimal representation. Calls the
    concrete runtime helper directly because `Integer.to_string`
    resolves back to this impl method.
    """

  pub fn to_string(value :: i8) -> String { :zig.Integer.to_string_i8(value) }
  pub fn to_string(value :: i16) -> String { :zig.Integer.to_string_i16(value) }
  pub fn to_string(value :: i32) -> String { :zig.Integer.to_string_i32(value) }
  pub fn to_string(value :: i64) -> String { :zig.Integer.to_string_i64(value) }
  pub fn to_string(value :: i128) -> String { :zig.Integer.to_string_i128(value) }
  pub fn to_string(value :: u8) -> String { :zig.Integer.to_string_u8(value) }
  pub fn to_string(value :: u16) -> String { :zig.Integer.to_string_u16(value) }
  pub fn to_string(value :: u32) -> String { :zig.Integer.to_string_u32(value) }
  pub fn to_string(value :: u64) -> String { :zig.Integer.to_string_u64(value) }
  pub fn to_string(value :: u128) -> String { :zig.Integer.to_string_u128(value) }
}
