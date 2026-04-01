defmodule Hello do
  def main(_args :: [String]) :: String do
    Runner.hello("World!")
    |> IO.puts()
  end
end
