defmodule Pipes do
  def double(x :: i64) :: i64 do
    x * 2
  end

  def add_one(x :: i64) :: i64 do
    x + 1
  end
end

def main() do
  5
  |> Pipes.double()
  |> Pipes.add_one()
end
