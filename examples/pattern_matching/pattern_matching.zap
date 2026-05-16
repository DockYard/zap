pub struct PatternMatching {
  pub fn main(_args :: [String]) -> u8 {
    PatternMatch.describe(:ok)
    |> IO.puts()

    PatternMatch.describe(0)
    |> IO.puts()

    PatternMatch.describe(20)
    |> IO.puts()

    PatternMatch.describe(-100)
    |> IO.puts()
    0
  }
}
