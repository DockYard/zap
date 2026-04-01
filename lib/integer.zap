pub module Integer {
  pub fn to_string(value :: i64) :: String {
    :zig.i64_to_string(value)
  }
}
