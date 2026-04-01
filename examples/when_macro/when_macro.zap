# When/guard macro demonstration
#
# Run with:
#   zap run when_macro

pub module WhenMacro {
  pub fn main(_args :: [String]) :: String {
    Guards.check(10)
    |> IO.puts()

    Guards.check(-5)
    |> IO.puts()
  }
}
