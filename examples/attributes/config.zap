pub struct Config {
  @timeout :: i64 = 5000
  pub fn timeout() -> i64 {
    @timeout
  }

  @max_retries :: i64 = 3
  pub fn max_retries() -> i64 {
    @max_retries
  }

  @app_name :: String = "my_app"
  pub fn app_name() -> String {
    @app_name
  }
}
