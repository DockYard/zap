@doc = """
  Geometry helpers that pattern-dispatch over `Circle`, `Rectangle`,
  and `Color`. Demonstrates that Zap can resolve cross-file types
  without explicit imports — every sibling `*.zap` is part of the
  project graph.
  """

pub struct Geometry {
  pub fn circle_area(circle :: Circle) -> f64 {
    r = circle.radius
    Math.pi() * r * r
  }

  pub fn rectangle_area(rectangle :: Rectangle) -> f64 {
    w = rectangle.width
    h = rectangle.height
    w * h
  }

  pub fn describe_color(color :: Color) -> String {
    case color {
      Color.Red -> "red"
      Color.Green -> "green"
      Color.Blue -> "blue"
    }
  }
}
