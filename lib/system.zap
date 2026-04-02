pub module System {
  pub fn arg_count() -> i64 {
    :zig.arg_count()
  }

  pub fn arg_at(index :: i64) -> String {
    :zig.arg_at(index)
  }

  pub fn get_env(name :: String) -> String {
    :zig.get_env(name)
  }

  pub fn get_build_opt(name :: String) -> String {
    :zig.get_build_opt(name)
  }
}
