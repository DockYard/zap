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
# RESOLVED (FCC Phase 3 close-out): BINDING a boxed-`Callable` value-call RESULT
# and comparing it (`r = List.get(ops, 0)(v); assert(r == N)`) now works in
# PROJECT mode. The daemon value-call-result-type gap (`comparison of
# comptime_int with null`) was rooted in the quoted-AST decoder
# (`src/ast_data.zig` `ctValueToExpr`) collapsing a NESTED value-call callee to
# `nil` inside a Zest macro body; the general nested-call-callee decode arm +
# the `.closure`-target return-type resolution (`src/hir.zig`) fixed it. The
# COMPARED form is now corpus-promoted as `test/zap/closure_boxed_inline_test.zap`
# (both the inline `List.get(ops, i)(v) == N` and the bound `r = ...; r == N`
# forms). The `Map(_, Callable)` / `[Callable]` RETURN type (the shared
# sibling gap) is likewise resolved and corpus-promoted as
# `test/zap/closure_container_return_test.zap` (fn->`Callable` container-element
# redirect + `typeEqualsModuloCallable`). This fixture stays a `zap run`
# fixture to keep the script-mode path covered too.

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
