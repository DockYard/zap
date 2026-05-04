pub struct DoubleMacro {
  pub fn main(_args :: [String]) -> String {
    Doubler.compute(5)
    |> Integer.to_string()
    |> IO.puts()
  }
}
