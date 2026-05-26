# FCC Phase 3 — Gap 1. A heterogeneous list of PURELY non-capturing
# closures. `[fn(x){x+1}, fn(x){x+2}]` — neither element captures, so each
# desugars to a bare fn-ptr on the direct path; but a list needs ONE uniform
# element representation, the boxed `Callable({i64}, i64)`. Escape analysis
# must box each non-capturing element so `List.get` returns a dispatchable
# `Callable` and `f(10)` routes through the box `call` slot.
#
# Expected (both managers): prints `11`, `12`, exit 0, leak-free.

fn main(_args :: [String]) -> u8 {
  ops = [fn(x :: i64) -> i64 { x + 1 }, fn(x :: i64) -> i64 { x + 2 }]
  first = List.get(ops, 0)
  second = List.get(ops, 1)
  IO.puts(Integer.to_string(first(10)))
  IO.puts(Integer.to_string(second(10)))
  0
}
