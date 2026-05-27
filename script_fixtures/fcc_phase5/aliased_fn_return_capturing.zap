# FCC Phase 5 — Item 2. A `type`-alias-named function type in a RETURN position
# with a CAPTURING closure. The alias `Adder = fn(i64) -> i64` resolves to a
# function type, so the returned capturing closure must box as `Callable`
# (heap-allocated env, ARC-managed) — identically to a literal `fn`-return.
# Without the desugar's alias-aware return-box decision this failed with
# `expected '*const fn (i64) i64', found <closure struct>`.
#
# Expected (both managers): prints `110` (10 + 100), exit 0, leak-free.

type Adder = fn(i64) -> i64

pub struct AliasReturnCap {
  pub fn make(n :: i64) -> Adder {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  f = AliasReturnCap.make(100)
  IO.puts(Integer.to_string(f(10)))
  0
}
