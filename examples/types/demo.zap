defmodule Demo do
  def scalars() :: String do
    IO.puts("=== Scalars ===")
    Scalars.int() |> Kernel.inspect()
    Scalars.negative() |> Kernel.inspect()
    Scalars.float() |> Kernel.inspect()
    Scalars.string() |> Kernel.inspect()
    Scalars.boolean_true() |> Kernel.inspect()
    Scalars.boolean_false() |> Kernel.inspect()
    Scalars.hex() |> Kernel.inspect()
  end

  def tuples() :: String do
    IO.puts("=== Tuples ===")
    Tuples.pair() |> Kernel.inspect()
    Tuples.triple() |> Kernel.inspect()
    Tuples.nested() |> Kernel.inspect()
    Tuples.deep() |> Kernel.inspect()
  end

  def structs() :: String do
    p = %{x: 3.0, y: 4.0} :: Point
    Kernel.inspect(p.x)
    Kernel.inspect(p.y)
  end

  def enums() :: String do
    IO.puts("=== Enums ===")
    Kernel.inspect(Color.Red)
    Kernel.inspect(Direction.North)
  end

  def inheritance() :: String do
    IO.puts("=== Inheritance ===")
    Dog.speak() |> IO.puts()
    Dog.breathe() |> IO.puts()
  end
end
