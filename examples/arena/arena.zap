@doc = """
  Demonstrates building a Zap binary with the arena memory manager.

  The manifest selects `Memory.Arena`, so the same adapter protocol used
  by third-party managers binds the binary to the arena backend.
  """

pub struct Arena {
  fn factorial(0) -> i64 {
    1
  }

  fn factorial(value :: i64) -> i64 {
    value * factorial(value - 1)
  }

  fn sum_to(0) -> i64 {
    0
  }

  fn sum_to(value :: i64) -> i64 {
    value + sum_to(value - 1)
  }

  pub fn main(_args :: [String]) -> String {
    total = factorial(7) + sum_to(100)
    "arena_total=#{total}" |> IO.puts()
  }
}
