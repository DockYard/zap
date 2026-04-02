pub module Guards {
  pub fn check(n :: i64) -> String if n > 0 {
    "positive"
  }

  pub fn check(_ :: i64) -> String {
    "not positive"
  }
}
