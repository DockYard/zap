def classify(n :: i64) :: String if n > 0 do
  "positive"
end

def classify(n :: i64) :: String if n < 0 do
  "negative"
end

def classify(_ :: i64) :: String do
  "zero"
end

def main() do
  classify(42)
  |> IO.puts()

  classify(-7)
  |> IO.puts()

  classify(0)
  |> IO.puts()
end
