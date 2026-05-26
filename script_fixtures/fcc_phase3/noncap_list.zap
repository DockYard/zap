# FCC Phase 3 — Gap 1. A heterogeneous list of PURELY non-capturing
# closures. `[fn(x){x+1}, fn(x){x+2}]` — neither element captures, so each
# desugars to a bare fn-ptr on the direct path; but a list needs ONE uniform
# element representation, the boxed `Callable({i64}, i64)`. Escape analysis
# must box each non-capturing element so `List.get` returns a dispatchable
# `Callable` and `f(10)` routes through the box `call` slot.
#
# The list is built in a factory method (the idiomatic FCC form, matching
# every committed boxed-closure fixture): a Zest test file declares exactly
# one struct, and a method-level `[fn(i64) -> i64]` return type drives the
# `Callable` element-type flow + `List.get` specialization.
#
# Expected (both managers): prints `11`, `12`, exit 0, leak-free.

pub struct NonCapBuilder {
  pub fn ops() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, fn(x :: i64) -> i64 { x + 2 }]
  }
}

fn main(_args :: [String]) -> u8 {
  ops = NonCapBuilder.ops()
  first = List.get(ops, 0)
  second = List.get(ops, 1)
  IO.puts(Integer.to_string(first(10)))
  IO.puts(Integer.to_string(second(10)))
  0
}
