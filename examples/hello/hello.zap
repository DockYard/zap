pub struct Hello {
  pub fn main(_args :: [String]) -> String {
    Runner.hello("World!")
    |> IO.puts()
  }
}
