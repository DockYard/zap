# FCC Phase 3 — Edge 2. A NON-capturing closure passed as the generic-type-var
# `default` of `Map.get(map, key, default :: value)`, where `value` unifies to
# `Callable({i64}, i64)` (the map's value type is `fn(i64) -> i64`).
#
# The box decision happens at desugar, BEFORE unification resolves
# `value = Callable`, so a closure-literal `default` is NOT boxed into the
# `ProtocolBox` value slot. A concrete `fn`-typed param already boxes via the
# crux/monomorphizer (`boxedCallableRepresentationForParam`); the generic-default
# case must too — the box decision is deferred/re-applied post-unification at the
# call site / monomorphizer.
#
# Expected (both managers): the key is MISSING, so the default closure is
# returned and invoked → prints `100` (5 * 20). exit 0, leak-free.

fn main(_args :: [String]) -> u8 {
  m = %{1 => fn(x :: i64) -> i64 { x * 2 }}
  chosen = Map.get(m, 99, fn(x :: i64) -> i64 { x * 20 })
  IO.puts(Integer.to_string(chosen(5)))
  0
}
