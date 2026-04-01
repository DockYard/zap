# Guard-based conditional dispatch
#
# Run with:
#   zap run unless_macro

pub module UnlessMacro {
  pub fn check(x :: i64) :: String if x > 10 {
    "big number"
  }

  pub fn check(_ :: i64) :: String {
    "small number"
  }

  pub fn main(_args :: [String]) :: String {
    UnlessMacro.check(5)
    |> IO.puts()

    UnlessMacro.check(20)
    |> IO.puts()
  }
}
