# FCC Phase 3 — Edge 1. A CAPTURING closure constructed INLINE in the
# top-level script `main` body, stored into a `fn`-typed (boxed `Callable`)
# struct field, then invoked through the field.
#
# The same closure capturing a METHOD PARAM (factory form) already works;
# capturing a SCRIPT-`main` LOCAL into a stored/boxed closure env is the gap.
#
# Expected (both managers): prints `15` (10 + 5), exit 0, leak-free.

pub struct Box {
  f :: fn(i64) -> i64
}

fn main(_args :: [String]) -> u8 {
  n = 5
  b = %Box{f: fn(x :: i64) -> i64 { x + n }}
  IO.puts(Integer.to_string(b.f(10)))
  0
}
