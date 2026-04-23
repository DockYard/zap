pub struct PatternMatching {
  pub fn main(_args :: [String]) -> String {
    PatternMatch.describe(:ok)
    |> IO.puts()

    PatternMatch.describe(0)
    |> IO.puts()

    PatternMatch.describe(20)
    |> IO.puts()

    PatternMatch.describe(-100)
    |> IO.puts()
  }
}
