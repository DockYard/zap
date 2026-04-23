pub struct App {
  pub fn main(_args :: [String]) -> String {
    MathLib.add(1, 2)
    |> Integer.to_string()
    |> IO.puts()
  }
}
