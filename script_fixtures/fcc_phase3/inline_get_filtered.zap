# FCC Phase 3 — inline `List.get(filtered)(v)` edge.
#
# An INLINE call on a `List.get` result over a freshly-monomorphized (filtered)
# `[Callable]` list. The `List.get` result is a boxed `Callable` and is invoked
# inline (no intermediate binding).
#
# Expected (both managers): make_adder(2) kept by the filter, applied to 10 => 12.
#
# This fixture pins the codegen edge that previously failed in BOTH modes with
# `use of undeclared identifier 'List__get__2'`: the monomorphizer did not scan
# OR rewrite the callee of an implicit value-call (a `.closure`-target call), so
# the inner `List.get(filtered, 0)` over a freshly-monomorphized `[Callable]`
# list never specialized and the callee referenced an un-produced generic
# specialization. Fixed in src/monomorphize.zig (scanExpr + rewriteExpr now
# descend into `call.target.closure`).
#
# NOTE: kept as a `zap run` fixture (NOT corpus-promoted) because BINDING the
# boxed-`Callable` value-call RESULT and then comparing it
# (`r = List.get(ops, 0)(v); assert(r == N)`) fails in PROJECT mode (`zap test`)
# with `comparison of comptime_int with null` — the daemon does not resolve a
# bound boxed-`Callable` value-call result to its concrete `result` type. That
# is the SAME pre-existing project-mode value-call-result-type-flow gap that
# keeps `map_of_fns.zap` (the `Map(_, Callable)` RETURN type) a `zap run`
# fixture; the `zap run` script pipeline resolves the value-call result type,
# the project-mode daemon does not yet. (A Phase-5 daemon value-call-result
# resolution effort, shared with the Map-return gap.)

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [AdderMaker.make_adder(1), AdderMaker.make_adder(2)]
  }
}

fn main(args :: [String]) -> u8 {
  ops = AdderMaker.ops()
  kept = Enum.filter(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
  # Inline call on the List.get result over the freshly-monomorphized filtered list.
  result = List.get(kept, 0)(10)
  IO.puts(Integer.to_string(result))
  0
}
