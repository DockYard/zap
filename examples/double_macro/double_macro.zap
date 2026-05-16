pub struct DoubleMacro {
  pub fn main(_args :: [String]) -> u8 {
    Doubler.compute(5)
    |> Integer.to_string()
    |> IO.puts()
    0
  }
}
