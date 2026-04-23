# Tail call optimization example
#
# This function counts down from N to 0 using recursion.
# Without TCO, large values of N will overflow the stack.
# With TCO, it runs in constant stack space.

pub struct TailCall {
  pub fn main(_args :: [String]) -> String {
    Counter.countdown(100_000_000)
    |> Integer.to_string()
    |> IO.puts()
  }
}
