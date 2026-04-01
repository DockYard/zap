defmodule Pipes do
  def double(x :: i64) :: i64 do
    x * 2
  end

  def add_one(x :: i64) :: i64 do
    x + 1
  end

  def main(_args :: [String]) :: String do
    5
    |> Pipes.double()
    |> Pipes.add_one()
    |> Integer.to_string()
    |> IO.puts()
  end
end
