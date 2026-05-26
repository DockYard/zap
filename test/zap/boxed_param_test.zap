@doc = """
  First-class boxed-`Callable` PARAMETER corpus coverage (FCC Phase 3
  project-mode parity): a method whose parameter is a boxed `Callable`
  (`fn(i64) -> i64`), called CROSS-STRUCT in PROJECT mode (`zap test`, the
  daemon/Zest pipeline), with a boxed closure manufactured in a different
  struct.

  The closure factory lives in `Zap.BoxedParamMaker`
  (test/zap/boxed_param_maker.zap) and the higher-order helper in
  `Zap.BoxedParamHigher` (test/zap/boxed_param_higher.zap) because a Zest test
  file must declare exactly one struct.
  """

pub struct Zap.BoxedParamTest {
  use Zest.Case

  describe("cross-struct boxed Callable parameter") {
    test("Higher.apply invokes a boxed Callable param passed cross-struct") {
      adder = Zap.BoxedParamMaker.make_adder(5)
      assert(Zap.BoxedParamHigher.apply(adder, 10) == 15)
    }

    test("Higher.apply_twice dispatches the boxed param twice") {
      adder = Zap.BoxedParamMaker.make_adder(3)
      assert(Zap.BoxedParamHigher.apply_twice(adder, 10) == 16)
    }

    test("a fresh boxed Callable passed inline cross-struct") {
      assert(Zap.BoxedParamHigher.apply(Zap.BoxedParamMaker.make_adder(7), 100) == 107)
    }
  }
}
