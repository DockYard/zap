@doc = """
  First-class boxed-closure corpus coverage (FCC Phase 1).

  Exercises capturing closures that escape their defining frame and are
  therefore boxed as `Callable` existentials (`ProtocolBox`): returned
  across a call boundary, collected in a heterogeneous list mixing
  capturing and non-capturing closures, invoked both as indexed reads and
  bound locals, and the zero-argument arity (`Callable({}, R)`). This gates
  the boxed-`Callable` path in PROJECT mode (`zap test`), which lowers
  through the daemon/Zest pipeline rather than the `zap run` script
  pipeline — the synthesized `__closure_N` structs and their
  `impl Callable` must be registered as types in both modes.

  The closure factory lives in `ClosureFactory` (test/zap/closure_factory.zap)
  because a Zest test file must contain exactly one struct declaration.
  """

pub struct Zap.ClosureBoxedTest {
  use Zest.Case

  describe("boxed Callable closures") {
    test("capturing closure returned across a call boundary") {
      add5 = Zap.ClosureFactory.make_adder(5)
      assert(add5(10) == 15)
      assert(add5(0) == 5)
    }

    test("two-argument capturing closure") {
      combine = Zap.ClosureFactory.make_combiner(100)
      assert(combine(10, 20) == 130)
    }

    test("zero-argument capturing closure (empty-tuple arity)") {
      get42 = Zap.ClosureFactory.make_constant(42)
      assert(get42() == 42)
    }

    test("heterogeneous list: bound-local calls") {
      ops = Zap.ClosureFactory.adders()
      f0 = List.get(ops, 0)
      f1 = List.get(ops, 1)
      assert(f0(10) == 11)
      assert(f1(10) == 15)
    }
  }
}
