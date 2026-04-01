pub module Math {
  pub macro double(value :: i64) :: i64 {
    quote {
      unquote(value) + unquote(value)
    }
  }

  pub fn compute(x :: i64) :: i64 {
    double(x * 3)
  }
}
