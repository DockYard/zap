pub module Pipes {
  pub fn double(x :: i64) -> i64 {
    x * 2
  }

  pub fn add_one(x :: i64) -> i64 {
    x + 1
  }

  pub fn main(_args :: [String]) -> String {
    5
    |> Pipes.double()
    |> Pipes.add_one()
    |> Integer.to_string()
    |> IO.puts()
  }
}
