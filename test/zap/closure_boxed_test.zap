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

    test("boxed closure environment is released exactly once (no leak)") {
      # FCC Phase 2 — proves the leak subsystem now covers boxed `Callable`
      # closures: a capturing closure (its boxed environment) and a
      # heterogeneous list of boxed closures are constructed and invoked
      # inside the block, then go out of scope. The net live-allocation
      # delta must be zero — the boxed environments are reclaimed by the
      # scope-exit `__box_header__.drop`. Active under `Memory.Tracking`
      # (where the live-allocation checkpoint is observable); a documented
      # no-op pass under the default `Memory.ARC` corpus manager.
      assert_no_leaks {
        add5 = Zap.ClosureFactory.make_adder(5)
        assert(add5(10) == 15)
        ops = Zap.ClosureFactory.adders()
        first = List.get(ops, 0)
        assert(first(10) == 11)
      }
    }

    test("SHARED boxed closure is balanced (no leak, no double-free)") {
      # FCC Phase 2 gap — a boxed `Callable` closure shared across multiple
      # owners. `add5` is aliased into `also` and `again` (two more
      # independent owners) and ALSO stored into a heterogeneous list that is
      # itself extracted from. Before the fix this double-freed under
      # `Memory.Tracking` (two owners eagerly freeing one shared env). Each
      # owning path must now drop exactly once: under a no-refcount manager
      # each alias is an independent CLONE of the env; under a refcount
      # manager each alias bumps the env's refcount. The net live-allocation
      # delta is zero.
      assert_no_leaks {
        add5 = Zap.ClosureFactory.make_adder(5)
        also = add5
        again = also
        assert(add5(10) == 15)
        assert(also(10) == 15)
        assert(again(10) == 15)
        held = [add5, Zap.ClosureFactory.make_adder(0)]
        picked = List.get(held, 0)
        assert(picked(10) == 15)
      }
    }
  }
}
