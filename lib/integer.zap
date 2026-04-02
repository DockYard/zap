pub module Integer {
  pub fn to_string(_value :: i64) -> String {
    :zig.i64_to_string(_value)
  }
}
