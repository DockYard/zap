# Tail call optimization example
#
# This function counts down from N to 0 using recursion.
# Without TCO, large values of N will overflow the stack.
# With TCO, it runs in constant stack space.

defmodule Counter do
  def countdown(0 :: i64) :: i64 do
    0
  end

  def countdown(n :: i64) :: i64 do
    countdown(n - 1)
  end
end

defmodule TailCall do
  def main() :: String do
    Counter.countdown(100_000_000)
    |> Kernel.inspect()
  end
end
