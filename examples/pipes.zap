def double(x :: i64) :: i64 do
  x * 2
end

def add_one(x :: i64) :: i64 do
  x + 1
end

def main() do
  5
  |> double()
  |> add_one()
end
