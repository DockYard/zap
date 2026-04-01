defmodule Factorial do
  def factorial(0 :: i64) :: i64 do
    1
  end

  def factorial(n :: i64) :: i64 do
    n * factorial(n - 1)
  end

  def main(_args :: [String]) :: String do
    Factorial.factorial(10)
    |> Integer.to_string()
    |> IO.puts()
  end
end
