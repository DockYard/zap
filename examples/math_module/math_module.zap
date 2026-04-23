pub struct MathModule {
  pub fn main(_args :: [String]) -> String {
    Math.square(5)
    |> IO.puts()
  }
}
