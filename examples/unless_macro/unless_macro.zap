# unless is now a Kernel macro — no need to define it yourself

defmodule UnlessMacro do
  def check(x :: i64) :: String | nil do
    unless(x > 10, "small number")
  end

  def main() do
    UnlessMacro.check(5)!
    |> IO.puts()
  end
end
