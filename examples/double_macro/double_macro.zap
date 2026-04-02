pub module DoubleMacro {
  pub fn main(_args :: [String]) -> String {
    Math.compute(5)
    |> Integer.to_string()
    |> IO.puts()
  }
}
