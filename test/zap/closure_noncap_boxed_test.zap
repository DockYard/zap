@doc = """
  FCC Gap 1/2 (project mode). A NON-capturing closure flowing into a boxed-
  `Callable` slot (a `[fn]` list element) must BOX (empty-env `__closure_N` +
  `impl Callable`) so it fits the `ProtocolBox`, exactly as a capturing
  closure does — while a non-capturing closure in a non-escaping / return /
  direct-call position stays the zero-overhead bare fn-ptr. Also pins an
  `if`-body closure element (the synthesized `impl Callable.call` body must
  survive if->case lowering). Producers in `closure_noncap_boxed_factory.zap`.
  """

pub struct Zap.ClosureNoncapBoxedTest {
  use Zest.Case

  describe("non-capturing closure into a boxed Callable slot") {
    test("heterogeneous [fn] list elements box and dispatch") {
      ops = Zap.ClosureNoncapBoxedFactory.list_ops()
      assert(List.get(ops, 0)(10) == 11)
      assert(List.get(ops, 1)(10) == 12)
    }

    test("inline List.get on a [fn] result dispatches") {
      ops = Zap.ClosureNoncapBoxedFactory.list_ops()
      assert(List.get(ops, 1)(100) == 102)
    }

    test("if-body closure elements compile and dispatch") {
      ops = Zap.ClosureNoncapBoxedFactory.if_ops()
      assert(List.get(ops, 0)(5) == 15)
      assert(List.get(ops, 1)(5) == 25)
    }
  }
}
