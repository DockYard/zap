# Type system examples

# --- Struct definitions ---

defstruct Point do
  x :: f64
  y :: f64
end

defstruct Shape do
  color :: String = "black"
  opacity :: f64 = 1.0
end

defstruct Circle extends Shape do
  radius :: f64
end

defstruct Rectangle extends Shape do
  width :: f64
  height :: f64
end

# --- Enum definitions ---

defenum Color do
  Red
  Green
  Blue
end

defenum Direction do
  North
  South
  East
  West
end

# --- Modules with behavior ---

defmodule Geometry do
  def area(%{radius: r} :: Circle) :: f64 do
    3.14159 * r * r
  end

  def area(%{width: w, height: h} :: Rectangle) :: f64 do
    w * h
  end
end

# --- Module inheritance ---

defmodule Animal do
  def speak() :: String do
    "..."
  end

  def breathe() :: String do
    "inhale, exhale"
  end
end

defmodule Dog extends Animal do
  def speak() :: String do
    "woof"
  end
end

# --- Main ---

def main() do
  p = %{x: 1.0, y: 2.0} :: Point
  IO.puts(p.x)
end
