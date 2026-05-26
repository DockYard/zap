@doc = """
  Factory for `closure_noncap_boxed_test.zap` (FCC Gap 1/2). A Zest test file
  declares exactly one struct, so the boxed-`Callable` producers live here.

  These closures DO NOT capture — a non-capturing closure desugars to a bare
  fn-ptr on the #201/Gap E direct path. When one flows into a `[fn]` list
  element (a boxed-`Callable` slot), a bare fn-ptr cannot fit the
  `ProtocolBox`, so it must box (an empty-env `__closure_N` + `impl Callable`,
  trivial drop) — exactly as a capturing element does — so the list element
  type is the uniform `Callable` and `List.get` returns a dispatchable value.
  `if_ops/0` additionally exercises a closure whose body is an `if`-expression
  (the synthesized `impl Callable.call` body must survive if->case lowering).
  """

pub struct Zap.ClosureNoncapBoxedFactory {
  @doc = """
    A `[fn(i64) -> i64]` of purely non-capturing closures (boxed elements).
    """

  pub fn list_ops() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, fn(x :: i64) -> i64 { x + 2 }]
  }

  @doc = """
    A `[fn(i64) -> i64]` whose elements have `if`-expression bodies.
    """

  pub fn if_ops() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { if x > 0 { x + 10 } else { 0 } }, fn(x :: i64) -> i64 { x + 20 }]
  }
}
