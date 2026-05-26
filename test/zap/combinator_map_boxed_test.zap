@doc = """
  First-class boxed-`Callable` combinator corpus coverage (FCC Phase 3
  project-mode parity): the combinators that INVOKE the boxed element through
  the callback (`Enum.map`/`Enum.each`/`Enum.reduce` and the `for`-comprehension
  over a `[fn(i64) -> i64]` = `[Callable]`), exercised in PROJECT mode
  (`zap test`, the daemon/Zest pipeline).

  These differ from `Zap.CombinatorBoxedTest` (filter/reject, which build the
  result via `List.prepend`): here the callback body `f(10)` dispatches the
  boxed `Callable` element through its `call` slot — the project-mode
  higher-order closure bridge that previously diverged from the script-mode
  `protocol_dispatch` path.

  The factory lives in `Zap.CombinatorFactory`
  (test/zap/combinator_factory.zap) because a Zest test file must contain
  exactly one struct declaration.
  """

pub struct Zap.CombinatorMapBoxedTest {
  use Zest.Case

  describe("boxed Callable combinators (map/each/reduce/for)") {
    test("Enum.map invokes each boxed element and collects the body type") {
      ops = Zap.CombinatorFactory.ops()
      results = Enum.map(ops, fn(f :: fn(i64) -> i64) -> i64 { f(10) })
      assert(List.get(results, 0) == 11)
      assert(List.get(results, 1) == 12)
    }

    test("Enum.each invokes each boxed element for side effects") {
      ops = Zap.CombinatorFactory.ops()
      total = Enum.reduce(ops, 0, fn(acc :: i64, f :: fn(i64) -> i64) -> i64 { acc + f(10) })
      assert(total == 23)
    }

    test("for-comprehension over a [fn] list invokes each element") {
      ops = Zap.CombinatorFactory.ops()
      results = for f <- ops { f(100) }
      assert(List.get(results, 0) == 101)
      assert(List.get(results, 1) == 102)
    }
  }
}
