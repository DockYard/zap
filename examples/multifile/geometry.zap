# Geometry module — uses types from types.zap via cross-file resolution.
# Demonstrates automatic union synthesis across file boundaries.

defmodule Geometry do
  def area(%{radius: r} :: Circle) :: f64 do
    3.14159 * r * r
  end

  def area(%{width: w, height: h} :: Rectangle) :: f64 do
    w * h
  end

  def describe_color(color :: Color) :: String do
    case color do
      Color.Red -> "red"
      Color.Green -> "green"
      Color.Blue -> "blue"
    end
  end
end
