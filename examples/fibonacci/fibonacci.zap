pub module Fibonacci {
  pub fn fib(0 :: i64) :: i64 {
    0
  }

  pub fn fib(1 :: i64) :: i64 {
    1
  }

  pub fn fib(n :: i64) :: i64 {
    fib(n - 1) + fib(n - 2)
  }

  pub fn main(_args :: [String]) :: String {
    Fibonacci.fib(20)
    |> Integer.to_string()
    |> IO.puts()
  }
}
