# FCC Phase 3 — Item 2: Residual 4 — a Map of boxed closures
# `%{Atom => fn(i64) -> i64}` = `%{Atom => Callable({i64}, i64)}`.
#
# Each value is a boxed `Callable` existential. `Map.get(handlers, :inc)`
# extracts a boxed value that must be recognized as a boxed `Callable` and
# dispatch through the box `call` slot (mirroring how `List.get` returns a
# `Callable` element). Today this reports `dynamic Function dispatch is not
# supported` because the Map value type does not flow to `Callable`.
#
# Two pieces (mirroring List): a `Map` type-flow analog of List's
# `substituteReturnTypeFromArgs`/`typeMentionsCallable` so `Map(K, fn(A)->R)` is
# expressible and `Map.get`/`Map.fetch` return a dispatchable `Callable`; and
# `map_init` consuming its box values (like `list_init`) so an inline `%{...}` of
# boxes does not double-free (the clone-on-share is already wired in `map_init`
# lowering for `value_type == .protocol_box`).
#
# Expected (both managers):
#   handlers[:inc](10) -> 11, handlers[:dec](10) -> 9
#   prints 11, 9, exit 0, ZERO leaks, NO double-free.

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(args :: [String]) -> u8 {
  handlers = %{:inc => AdderMaker.make_adder(1), :dec => AdderMaker.make_adder(-1)}
  inc = Map.get(handlers, :inc)
  dec = Map.get(handlers, :dec)
  IO.puts(Integer.to_string(inc(10)))
  IO.puts(Integer.to_string(dec(10)))
  0
}
