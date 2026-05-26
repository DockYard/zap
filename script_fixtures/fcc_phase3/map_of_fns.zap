# FCC Phase 3 — Item 2: Residual 4 — a Map of boxed closures
# `%{Atom => fn(i64) -> i64}` = `%{Atom => Callable({i64}, i64)}`.
#
# Each value is a boxed `Callable` existential. `Map.get(handlers, :inc, fallback)`
# extracts a boxed value that is recognized as a boxed `Callable` and dispatches
# through the box `call` slot (mirroring how `List.get` returns a `Callable`
# element). Before residual-4 this reported `dynamic Function dispatch is not
# supported` because the Map value type did not flow to `Callable`.
#
# Three pieces (all landed): a `Map` type-flow analog of List's
# `substituteReturnTypeFromArgs`/`typeMentionsCallable` (the generic
# `resolveClauseCallInfo` substitution + `typeArgIsMonomorphizationReady`'s `.map`
# arm already cover it) so `Map(K, fn(A)->R)` is expressible and `Map.get`
# returns a dispatchable `Callable`; `map_init` CONSUMING its boxed `Callable`
# values like `list_init` (the clone-on-share is already wired in `map_init`
# lowering); and the runtime `Map.release` deep-release + `Map.get` `ownEntryValue`
# clone-on-extract under no-REFCOUNT_V1 (the `List.release`/`ownElement` analog).
#
# NOTE: `Map.get` is a 3-arg function (`map`, `key`, `default`) — the `default`
# fallback closure is mandatory in Zap. (The 2-arg `Map.get(m, k)` form is a
# SEPARATE pre-existing gap that fails `Map__get__3` for EVERY value type,
# including scalar maps — not an FCC concern.) The fallback here captures, so it
# boxes; a NON-capturing fallback would devirtualize to a bare fn-ptr and
# mismatch the boxed map values.
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
  inc = Map.get(handlers, :inc, AdderMaker.make_adder(0))
  dec = Map.get(handlers, :dec, AdderMaker.make_adder(0))
  IO.puts(Integer.to_string(inc(10)))
  IO.puts(Integer.to_string(dec(10)))
  0
}
