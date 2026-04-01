pub module Float {
  pub fn to_string(value :: f64) :: String {
    :zig.f64_to_string(value)
  }
}
