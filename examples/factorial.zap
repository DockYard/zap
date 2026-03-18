def factorial(0 :: i64) :: i64 do
  1
end

def factorial(n :: i64) :: i64 do
  n * factorial(n - 1)
end

def main() do
  factorial(10)
end
