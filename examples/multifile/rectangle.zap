@doc = """
  Rectangle inherits `color` from `Shape` and adds `width` and
  `height`. Sits alongside `Circle` so `Geometry.area/1` can resolve
  both shapes via cross-file pattern dispatch.
  """

pub struct Rectangle extends Shape {
  width :: f64
  height :: f64
}
