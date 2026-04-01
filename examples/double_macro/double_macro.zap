defmodule DoubleMacro do
  def main(_args :: [String]) :: String do
    Math.compute(5)
    |> Integer.to_string()
    |> IO.puts()
  end
end
