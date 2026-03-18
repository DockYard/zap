# unless is now a Kernel macro — no need to define it yourself

defmodule UnlessExample do
  def check(x :: i64) :: String | nil do
    unless(x > 10, "small number")
  end
end

def main() do
  UnlessExample.check(5)!
  |> IO.puts()
end
