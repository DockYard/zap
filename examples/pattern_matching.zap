def describe(:ok) :: String do
  "success"
end

def describe(:error) :: String do
  "failure"
end

def describe(0 :: i64) :: String do
  "zero"
end

def describe(n :: i64) :: String do
  if n > 0 do
    "positive"
  else
    "negative"
  end
end

def describe(_) :: String do
  "unknown"
end

def main() do
  describe(:ok)
  |> IO.puts()

  describe(0)
  |> IO.puts()

  describe(20)
  |> IO.puts()

  describe(-100)
  |> IO.puts()
end
