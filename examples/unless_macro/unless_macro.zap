# Guard-based conditional dispatch
#
# Run with:
#   zap run unless_macro

defmodule UnlessMacro do
  def check(x :: i64) :: String if x > 10 do
    "big number"
  end

  def check(_ :: i64) :: String do
    "small number"
  end

  def main(_args :: [String]) :: String do
    UnlessMacro.check(5)
    |> IO.puts()

    UnlessMacro.check(20)
    |> IO.puts()
  end
end
