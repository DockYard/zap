# FCC Phase 3 — Gap 1. A NON-capturing closure stored in a `fn`-typed
# struct field. A non-capturing closure desugars to a bare fn-ptr on the
# direct (#201/Gap E) path, but a `fn(i64) -> i64` struct field is the
# boxed `Callable({i64}, i64)` representation — a bare fn-ptr cannot fit
# the `ProtocolBox` slot. Escape analysis must box even a non-capturing
# closure when it flows into this boxed slot (empty-env `__closure_N` +
# `impl Callable`, a `ProtocolBox` whose `call` slot is the code and whose
# `data_ptr` is null/empty), exactly as a collection element boxes.
#
# Expected (both managers): prints `43`, exit 0, leak-free (empty env →
# trivial drop).

pub struct Holder {
  op :: fn(i64) -> i64
}

pub struct Maker {
  pub fn make() -> Holder {
    %Holder{op: fn(x :: i64) -> i64 { x + 1 }}
  }
}

fn main(_args :: [String]) -> u8 {
  h = Maker.make()
  f = h.op
  IO.puts(Integer.to_string(f(42)))
  0
}
