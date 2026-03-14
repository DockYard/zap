defmodule Geometry do
  type Shape = {:circle, f64} | {:rectangle, f64, f64}

  def area({:circle, radius} :: Shape) :: f64 do
    3.14159 * radius * radius
  end

  def area({:rectangle, w, h} :: Shape) :: f64 do
    w * h
  end

  def perimeter({:circle, radius} :: Shape) :: f64 do
    2.0 * 3.14159 * radius
  end

  def perimeter({:rectangle, w, h} :: Shape) :: f64 do
    2.0 * (w + h)
  end
end

def main() do
  Geometry.area({:circle, 5.0})
end
