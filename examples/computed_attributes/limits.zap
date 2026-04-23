pub struct Limits {
  @effective_timeout :: i64 = 5000
  pub fn effective_timeout() -> i64 {
    @effective_timeout
  }

  @max_payload :: i64 = 65536
  pub fn max_payload() -> i64 {
    @max_payload
  }
}
