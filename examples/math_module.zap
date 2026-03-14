defmodule Math do
  def square(x :: i64) :: i64 do
    x * x
  end

  def cube(x :: i64) :: i64 do
    x * x * x
  end

  def abs(x :: i64) :: i64 do
    if x < 0 do
      -x
    else
      x
    end
  end
end

def main() :: String do
  Math.square(5)
  |> IO.puts()
end
