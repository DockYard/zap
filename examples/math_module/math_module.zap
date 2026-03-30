defmodule MathModule do
  def main() :: String do
    Math.square(5)
    |> IO.puts()
  end
end
