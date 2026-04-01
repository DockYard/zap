defmodule PatternMatching do
  def main(_args :: [String]) :: String do
    PatternMatch.describe(:ok)
    |> IO.puts()

    PatternMatch.describe(0)
    |> IO.puts()

    PatternMatch.describe(20)
    |> IO.puts()

    PatternMatch.describe(-100)
    |> IO.puts()
  end
end
