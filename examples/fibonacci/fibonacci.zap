defmodule Fibonacci do
  def fib(0 :: i64) :: i64 do
    0
  end

  def fib(1 :: i64) :: i64 do
    1
  end

  def fib(n :: i64) :: i64 do
    fib(n - 1) + fib(n - 2)
  end

  def main() do
    Fibonacci.fib(20)
  end
end
