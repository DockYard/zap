@doc = """
  First-class boxed-`Callable` combinator corpus coverage (FCC Phase 3 item 1).
  Exercises, in PROJECT mode (`zap test`, the daemon/Zest pipeline), the
  combinators that RETURN the boxed elements (`Enum.filter`/`Enum.reject` over a
  `[fn(i64) -> i64]` = `[Callable]`), which build the result via
  `List.prepend` -> `:zig.List.cons` and so consume the boxed element into the
  cons cell.

  The factory lives in `Zap.CombinatorFactory` (test/zap/combinator_factory.zap)
  because a Zest test file must contain exactly one struct declaration.

  NOTE: the Map-of-boxes case (`%{Atom => fn(i64) -> i64}`, residual 4) is
  exercised as a `zap run` fixture (script_fixtures/fcc_phase3/map_of_fns.zap)
  rather than here — its `Map(_, Callable)` RETURN type is unexpressible in
  PROJECT mode (`expected %{Atom => (i64 -> i64)}, got %{Atom => Callable}`), the
  same project-mode-parity unification gap the combinator `callBare1` bridge sits
  behind (a separate Phase-5 effort). The `zap run` script pipeline resolves it.
  """

pub struct Zap.CombinatorBoxedTest {
  use Zest.Case

  describe("boxed Callable combinators (filter/reject)") {
    test("Enum.filter returns the boxed elements, leak-free") {
      # `filter_next` builds the result via `List.prepend(accumulator, value)`
      # -> `:zig.List.cons`, which CONSUMES the boxed head. The head is the
      # residual-3 destructured element (its own scope-exit drop), so the cons
      # element is clone-on-shared into an independent owner the cell consumes.
      assert_no_leaks {
        ops = Zap.CombinatorFactory.ops()
        kept = Enum.filter(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
        keeper = List.get(kept, 0)
        assert(keeper(10) == 12)
      }
    }

    test("Enum.reject returns the boxed elements, leak-free") {
      assert_no_leaks {
        ops = Zap.CombinatorFactory.ops()
        kept = Enum.reject(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
        keeper = List.get(kept, 0)
        assert(keeper(10) == 11)
      }
    }
  }
}
