pub module System {
  pub fn arg_count() -> i64 {
    :zig.arg_count()
  }

  pub fn arg_at(_index :: i64) -> String {
    :zig.arg_at(_index)
  }

  pub fn get_env(_name :: String) -> String {
    :zig.get_env(_name)
  }

  pub fn get_build_opt(_name :: String) -> String {
    :zig.get_build_opt(_name)
  }
}
