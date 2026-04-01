# Case expression with atom matching
#
# Demonstrates case/switch on atom values.

defmodule CaseExpr do
  def describe(x :: i64) :: String do
    case x do
      0 ->
        "zero"
      1 ->
        "one"
      _ ->
        "other"
    end
  end

  def main(_args :: [String]) :: String do
    CaseExpr.describe(0)
    |> IO.puts()

    CaseExpr.describe(1)
    |> IO.puts()

    CaseExpr.describe(42)
    |> IO.puts()
  end
end
