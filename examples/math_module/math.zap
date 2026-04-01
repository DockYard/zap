pub module Math {
  pub fn square(x :: i64) :: i64 {
    x * x
  }

  pub fn cube(x :: i64) :: i64 {
    x * x * x
  }

  pub fn abs(x :: i64) :: i64 {
    if x < 0 {
      -x
    } else {
      x
    }
  }
}
