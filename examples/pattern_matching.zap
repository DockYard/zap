def describe(:ok) :: String do
  "success"
end

def describe(:error) :: String do
  "failure"
end

def describe(_) :: String do
  "unknown"
end

def classify(0 :: i64) :: String do
  "zero"
end

def classify(n :: i64) :: String do
  if n > 0 do
    "positive"
  else
    "negative"
  end
end

def main() do
  describe(:ok)
end
