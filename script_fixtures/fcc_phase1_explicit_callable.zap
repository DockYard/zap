# FCC Phase 1 — a hand-written `impl Callable` boxed as a parametric
# protocol existential, dispatched through the explicit `Callable.call`.
#
# `Maker.make()` constructs `%Adder{amount: 5}` (which implements
# `Callable({i64}, i64)`) in a position whose declared type is the
# `Callable({i64}, i64)` existential, so it auto-boxes
# (`maybeBoxAsProtocol`). `Maker.run` invokes it with the explicit
# `Callable.call(f, {v})` — the boxed-receiver protocol-dispatch path,
# distinct from the implicit `f(v)` call-site rewrite. Confirms a
# parameterized protocol works as a first-class boxed existential
# end-to-end (type-arg substitution of `result` to `i64`,
# per-instantiation vtable, tuple-typed `call` slot).
#
# Expected (Memory.ARC, the default): prints `15`, exit 0.

pub struct Adder {
  amount :: i64
}

pub impl Callable({i64}, i64) for Adder {
  pub fn call(self :: Adder, arguments :: {i64}) -> i64 {
    arguments.0 + self.amount
  }
}

pub struct Maker {
  pub fn make() -> Callable({i64}, i64) {
    %Adder{amount: 5}
  }

  pub fn run(f :: Callable({i64}, i64), v :: i64) -> i64 {
    Callable.call(f, {v})
  }
}

fn main(args :: [String]) -> u8 {
  f = Maker.make()
  IO.puts(Integer.to_string(Maker.run(f, 10)))
  0
}
