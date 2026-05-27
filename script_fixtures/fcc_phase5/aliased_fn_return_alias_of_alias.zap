# FCC Phase 5 — Item 2. A chain of `type` aliases (`type Outer = Inner`,
# `type Inner = fn(i64) -> i64`) in a RETURN position with a CAPTURING closure.
# The desugar's alias-aware return-box decision follows the alias chain
# transitively to the underlying `fn` type, so the returned capturing closure
# boxes correctly through two levels of aliasing.
#
# Expected (both managers): prints `57` (7 + 50), exit 0, leak-free.

type Inner = fn(i64) -> i64
type Outer = Inner

pub struct AliasOfAlias {
  pub fn make(n :: i64) -> Outer {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  f = AliasOfAlias.make(50)
  IO.puts(Integer.to_string(f(7)))
  0
}
