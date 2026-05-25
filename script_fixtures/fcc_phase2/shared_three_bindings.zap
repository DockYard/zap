# FCC Phase 2 — Shared boxed closure via THREE bindings (chained aliases).
# `a` is bound, `b = a`, `c = b`; all three are invoked. Each chained alias
# is an independent owner: under a no-refcount manager each share clones the
# inner so all three drops free distinct inners exactly once; under a
# refcount manager each share bumps the shared inner's refcount.
#
# Exercises the alias-chain depth beyond two owners (gap-loop "3+ owners").
#
# Expected under BOTH managers: prints `15` three times, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  a = Maker.make_adder(5)
  b = a
  c = b
  IO.puts(Integer.to_string(a(10)))
  IO.puts(Integer.to_string(b(10)))
  IO.puts(Integer.to_string(c(10)))
  0
}
