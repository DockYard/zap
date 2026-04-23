# Geometry struct --- uses types from types.zap via cross-file resolution.
# Demonstrates automatic union synthesis across file boundaries.

pub struct Geometry {
  pub fn area(%{radius: r} :: Circle) -> f64 {
    3.14159 * r * r
  }

  pub fn area(%{width: w, height: h} :: Rectangle) -> f64 {
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
