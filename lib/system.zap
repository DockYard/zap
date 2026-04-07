pub module System {
  @native = "Prelude.arg_count"
  pub fn arg_count() -> i64

  @native = "Prelude.arg_at"
  pub fn arg_at(_index :: i64) -> String

  @native = "Prelude.get_env"
  pub fn get_env(_name :: String) -> String

  @native = "Prelude.get_build_opt"
  pub fn get_build_opt(_name :: String) -> String
}
