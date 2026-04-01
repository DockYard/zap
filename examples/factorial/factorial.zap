pub module Factorial {
  pub fn factorial(0 :: i64) :: i64 {
    1
  }

  pub fn factorial(n :: i64) :: i64 {
    n * factorial(n - 1)
  }

  pub fn main(_args :: [String]) :: String {
    Factorial.factorial(10)
    |> Integer.to_string()
    |> IO.puts()
  }
}
