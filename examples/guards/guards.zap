pub struct Guards {
  pub fn classify(n :: i64) -> String if n > 0 {
    "positive"
  }

  pub fn classify(n :: i64) -> String if n < 0 {
    "negative"
  }

  pub fn classify(_ :: i64) -> String {
    "zero"
  }

  pub fn main(_args :: [String]) -> String {
    Guards.classify(-4)
    |> IO.puts()

    Guards.classify(-7)
    |> IO.puts()

    Guards.classify(0)
    |> IO.puts()
  }
}
