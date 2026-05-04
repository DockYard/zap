@doc = """
  Circle inherits `color` from `Shape` and adds `radius`. Pairs with
  `Rectangle` to demonstrate cross-file struct families that
  `Geometry.area/1` dispatches over.
  """

pub struct Circle extends Shape {
  radius :: f64
}
