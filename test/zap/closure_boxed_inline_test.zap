@doc = """
  FCC Phase 3 — boxed-`Callable` inline value-call result, COMPARED (project
  mode). The previously-deferred gap: binding a boxed-`Callable` value-call
  result and comparing it (`r = List.get(ops, i)(v); assert(r == N)`) failed in
  PROJECT mode with `comparison of comptime_int with null` — the daemon did not
  resolve the bound boxed-`Callable` value-call result to its concrete `result`
  type. The `List.get(ops, i)` result is a boxed `Callable`; invoking it inline
  dispatches through the box `call` vtable slot.

  Resolved by the nested-value-call decoder fix (ast_data.zig) +
  `buildCallableNonVarRefCall`'s `result` type-arg stamping. This pins both the
  inline-and-compared form and the bound-then-compared form, under both
  managers.
  """

pub struct Zap.ClosureBoxedInlineTest {
  use Zest.Case

  describe("boxed Callable inline value-call result, compared") {
    test("inline List.get(ops, i)(v) compared directly") {
      ops = Zap.ClosureBoxedInlineFactory.ops()
      assert(List.get(ops, 0)(10) == 11)
      assert(List.get(ops, 1)(10) == 12)
    }

    test("bound boxed value-call result, then compared") {
      ops = Zap.ClosureBoxedInlineFactory.ops()
      r = List.get(ops, 1)(100)
      assert(r == 102)
    }

    test("boxed value-call result over a filtered list, compared") {
      ops = Zap.ClosureBoxedInlineFactory.ops()
      kept = Enum.filter(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
      assert(List.get(kept, 0)(10) == 12)
    }
  }
}
