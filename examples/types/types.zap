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

defmodule Scalars do
  def int() :: i64 do
    42
  end

  def negative() :: i64 do
    -7
  end

  def float() :: f64 do
    3.14
  end

  def string() :: String do
    "hello"
  end

  def boolean_true() :: Bool do
    true
  end

  def boolean_false() :: Bool do
    false
  end

  def hex() :: i64 do
    0xFF
  end
end

defmodule Tuples do
  def pair() :: {i64, String} do
    {1, "one"}
  end

  def triple() :: {String, String, String} do
    {"a", "b", "c"}
  end

  def nested() :: {String, {i64, i64}} do
    {"point", {10, 20}}
  end

  def deep() :: {String, {String, {String, String}}} do
    {"root", {"branch", {"leaf1", "leaf2"}}}
  end
end

defmodule Geometry do
  def area(%{radius: r} :: Circle) :: f64 do
    3.14159 * r * r
  end

  def area(%{width: w, height: h} :: Rectangle) :: f64 do
    w * h
  end
end

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

defmodule Demo do
  def scalars() do
    IO.puts("=== Scalars ===")
    Scalars.int() |> Kernel.inspect()
    Scalars.negative() |> Kernel.inspect()
    Scalars.float() |> Kernel.inspect()
    Scalars.string() |> Kernel.inspect()
    Scalars.boolean_true() |> Kernel.inspect()
    Scalars.boolean_false() |> Kernel.inspect()
    Scalars.hex() |> Kernel.inspect()
  end

  def tuples() do
    IO.puts("=== Tuples ===")
    Tuples.pair() |> Kernel.inspect()
    Tuples.triple() |> Kernel.inspect()
    Tuples.nested() |> Kernel.inspect()
    Tuples.deep() |> Kernel.inspect()
  end

  def structs() do
    p = %{x: 3.0, y: 4.0} :: Point
    Kernel.inspect(p.x)
    Kernel.inspect(p.y)
  end

  def enums() do
    IO.puts("=== Enums ===")
    Kernel.inspect(Color.Red)
    Kernel.inspect(Direction.North)
  end

  def inheritance() do
    IO.puts("=== Inheritance ===")
    Dog.speak() |> IO.puts()
    Dog.breathe() |> IO.puts()
  end
end

defmodule Types do
  def main() do
    Demo.scalars()
    Demo.tuples()
    IO.puts("=== Structs ===")
    Demo.structs()
    Demo.enums()
    Demo.inheritance()
  end
end
