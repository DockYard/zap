@doc = """
  FCC Phase 3 — a function RETURNING a CONTAINER of boxed `Callable`s
  (`[fn(i64) -> i64]` and `%{Atom => fn(i64) -> i64}`) in project mode. The
  previously-deferred gap: the `Map(_, Callable)` / `[Callable]` RETURN type was
  unexpressible in project mode (`expected %{Atom => (i64 -> i64)}, got
  %{Atom => Callable}`). Resolving a `fn`-typed container element/value to its
  boxed `Callable` existential in BOTH the TypeChecker and HIR resolvers
  (`resolveCollectionElementType` / `callableConstraintFromFunctionTypeId`),
  plus `typeEqualsModuloCallable` for the return-type check, lets these flow.
  Read an element back and invoke it; both managers.
  """

pub struct Zap.ClosureContainerReturnTest {
  use Zest.Case

  describe("container-of-Callable return types") {
    test("[fn] return — element read back and invoked") {
      ops = Zap.ClosureContainerReturnFactory.op_list()
      f = List.get(ops, 0)
      assert(f(5) == 15)
      assert(List.get(ops, 1)(5) == 25)
    }

    test("Map(Atom, fn) return — value read back and invoked") {
      handlers = Zap.ClosureContainerReturnFactory.op_map()
      inc = Map.get(handlers, :inc, Zap.ClosureContainerReturnFactory.make_adder(0))
      assert(inc(10) == 11)
      dec = Map.get(handlers, :dec, Zap.ClosureContainerReturnFactory.make_adder(0))
      assert(dec(10) == 9)
    }
  }
}
