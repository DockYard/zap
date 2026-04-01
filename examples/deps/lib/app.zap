defmodule App do
  def main(_args :: [String]) :: String do
    MathLib.add(1, 2)
    |> Integer.to_string()
    |> IO.puts()
  end
end
