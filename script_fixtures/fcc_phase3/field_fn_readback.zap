# FCC Phase 3 — Residual 2. A capturing closure stored in a `fn`-typed
# struct field, read back into a local, then invoked.
#
# `%Holder{op: fn(x){x+n}}` then `f = h.op; f(10)`. The field type is
# `fn(i64) -> i64` = boxed `Callable({i64}, i64)`; reading it back yields a
# boxed value invoked through the box `call` slot.
#
# Expected (both managers): prints `13`, exit 0.

pub struct Holder {
  op :: fn(i64) -> i64
}

pub struct Maker {
  pub fn make(n :: i64) -> Holder {
    %Holder{op: fn(x :: i64) -> i64 { x + n }}
  }
}

fn main(_args :: [String]) -> u8 {
  h = Maker.make(3)
  f = h.op
  IO.puts(Integer.to_string(f(10)))
  0
}
