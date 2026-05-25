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

    test("partially-consumed list of boxed closures is leak-free") {
      # FCC Phase 2 gap — the canonical leaking case. A three-element
      # `[fn(i64) -> i64]` list is built; only the first element is extracted
      # and invoked. The list then drops with elements 1 and 2 un-extracted.
      # Before the box-in-container deep-release fix those two boxed
      # environments leaked under `Memory.Tracking` (List release never
      # deep-released its box elements; only extracted owners freed them). Now
      # the list-drop deep-releases the un-extracted boxes while the extracted
      # first element is freed by its clone-on-share owner — net delta zero.
      assert_no_leaks {
        ops = Zap.ClosureFactory.triple_adders()
        first = List.get(ops, 0)
        assert(first(10) == 11)
      }
    }

    test("list of boxed closures dropped with NO extraction is leak-free") {
      # The list is built and never read, then dropped. Every boxed
      # environment must be reclaimed by the list-drop.
      assert_no_leaks {
        ops = Zap.ClosureFactory.triple_adders()
        assert(List.length(ops) == 3)
      }
    }

    test("re-extracted element clones independently (no double-free)") {
      # Extracting the SAME index twice yields two independent owners; the
      # list keeps its own original. Three drops (two clones + the list-owned
      # original of index 0, plus the two un-extracted originals) each free
      # exactly one inner.
      assert_no_leaks {
        ops = Zap.ClosureFactory.triple_adders()
        a = List.get(ops, 0)
        b = List.get(ops, 0)
        assert(a(10) == 11)
        assert(b(20) == 21)
      }
    }

    test("dropped list of String-capturing closures deep-releases captures") {
      # A `[fn(String) -> String]` list of closures each capturing a `String`.
      # Partially consumed, then dropped: each un-extracted boxed environment
      # AND its captured value are reclaimed by the list-drop.
      assert_no_leaks {
        gs = Zap.ClosureFactory.greeters()
        hi = List.get(gs, 0)
        assert(hi("hi") == "hi alice")
      }
    }
  }
}
