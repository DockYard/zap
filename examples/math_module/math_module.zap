defmodule MathModule do
  def main(_args :: [String]) :: String do
    Math.square(5)
    |> IO.puts()
  end
end
