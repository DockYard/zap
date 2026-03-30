# Type system examples
#
# Demonstrates all supported types: scalars, compound types,
# structs, enums, and module inheritance.

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

defmodule Types do
  def main() :: String do
    Demo.scalars()
    Demo.tuples()
    IO.puts("=== Structs ===")
    Demo.structs()
    Demo.enums()
    Demo.inheritance()
  end
end
