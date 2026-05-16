pub struct App {
  pub fn main(_args :: [String]) -> u8 {
    MathLib.add(1, 2)
    |> Integer.to_string()
    |> IO.puts()
    0
  }
}
