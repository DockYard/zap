# When/guard macro demonstration
#
# Run with:
#   zap run when_macro

defmodule WhenMacro do
  def main(_args :: [String]) :: String do
    Guards.check(10)
    |> IO.puts()

    Guards.check(-5)
    |> IO.puts()
  end
end
