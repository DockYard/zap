defmodule WhenMacro do
  def main() :: String do
    Guards.check(10)!
    |> IO.puts()
  end
end
