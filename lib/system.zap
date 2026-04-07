pub module System {
  pub fn arg_count() -> i64 {
    :zig.Prelude.arg_count()
  }

  pub fn arg_at(index :: i64) -> String {
    :zig.Prelude.arg_at(index)
  }

  pub fn get_env(name :: String) -> String {
    :zig.Prelude.get_env(name)
  }

  pub fn get_build_opt(name :: String) -> String {
    :zig.Prelude.get_build_opt(name)
  }
}
