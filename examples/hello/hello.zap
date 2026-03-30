defmodule Hello do
  def main() :: String do
    Runner.hello("World!")
    |> IO.puts()
  end
end
