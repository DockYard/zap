pub module Counter {
  pub fn countdown(0 :: i64) -> i64 {
    0
  }

  pub fn countdown(n :: i64) -> i64 {
    countdown(n - 1)
  }
}
