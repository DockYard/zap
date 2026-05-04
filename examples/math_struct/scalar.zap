@doc = """
  A small stand-in for the kind of "module of numeric helpers" most
  projects end up with. Pairs with `MathStruct.main` and shows that a
  user-defined struct can sit alongside the stdlib `Math` namespace
  without colliding.
  """

pub struct Scalar {
  pub fn square(x :: i64) -> i64 {
    x * x
  }

  pub fn cube(x :: i64) -> i64 {
    x * x * x
  }

  pub fn abs(x :: i64) -> i64 {
    if x < 0 {
      -x
    } else {
      x
    }
  }
}
