pub module Float {
  pub fn to_string(_value :: f64) -> String {
    :zig.f64_to_string(_value)
  }
}
