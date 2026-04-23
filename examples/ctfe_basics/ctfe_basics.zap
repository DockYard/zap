# Compile-Time Function Execution (CTFE) basics
#
# Zap's IR interpreter can evaluate functions at compile time.
# The build manifest (build.zap) is itself executed via CTFE ---
# struct construction, case expressions, and string operations
# all run inside the compiler's abstract machine.
#
# This example shows how struct attributes store compile-time values.
#
# Run with:
#   zap run ctfe_basics

pub struct CtfeBasics {
  pub fn main(_args :: [String]) -> String {
    Greeter.greet("World")
    |> IO.puts()
  }
}
