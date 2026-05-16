pub struct Hello {
  pub fn main(_args :: [String]) -> u8 {
    Runner.hello("World!")
    |> IO.puts()
    0
  }
}
