pub struct Higher {
  # Same higher-order function, but invoked with a PURE (non-raising)
  # closure. apply's effect is polymorphic, NOT blanket-assumed: a pure
  # closure contributes no `raises`, so apply is not forced to raise and
  # the call site needs no `rescue`. No spurious raises requirement.
  pub fn apply(f :: fn() -> i64) -> i64 {
    f()
  }
}

fn main(args :: [String]) -> u8 {
  result = Higher.apply(fn() -> i64 { 21 + 21 })
  IO.puts(Integer.to_string(result))
  0
}
