defmodule Guards do
  def classify(n :: i64) :: String if n > 0 do
    "positive"
  end

  def classify(n :: i64) :: String if n < 0 do
    "negative"
  end

  def classify(_ :: i64) :: String do
    "zero"
  end

  def main() :: String do
    Guards.classify(-4)
    |> IO.puts()

    Guards.classify(-7)
    |> IO.puts()

    Guards.classify(0)
    |> IO.puts()
  end
end
