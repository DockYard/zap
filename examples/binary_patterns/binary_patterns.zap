# Binary patterns example
#
# Demonstrates string operations.
#
# Run with:
#   zap run binary_patterns

defmodule BinaryPatterns do
  def main(_args :: [String]) :: String do
    MarkupParser.greet("Zap")
    |> IO.puts()
  end
end
