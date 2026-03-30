defmodule Geometry do
  def area(%{radius: r} :: Circle) :: f64 do
    3.14159 * r * r
  end

  def area(%{width: w, height: h} :: Rectangle) :: f64 do
    w * h
  end
end
