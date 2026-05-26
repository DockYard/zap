# FCC Phase 3 — Edge 3. A NESTED closure that captures the OUTER closure's
# capture, both constructed INLINE in the top-level script `main` body.
#
# `outer = fn(x) { adder = fn(y) { y + n }; adder(x) }` where `n` is the
# OUTER closure's capture (a script-`main` local). The inner `adder` closure
# transitively captures `n` through the outer closure's environment.
#
# Expected (both managers): prints `13` (x=10, n=3, adder(10) = 10+3), exit 0.

fn main(_args :: [String]) -> u8 {
  n = 3
  outer = fn(x :: i64) -> i64 {
    adder = fn(y :: i64) -> i64 { y + n }
    adder(x)
  }
  IO.puts(Integer.to_string(outer(10)))
  0
}
