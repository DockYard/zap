@doc = """
  FCC Phase 3 dispatch-coverage corpus (project/`zap test` mode).

  Locks in the THREE DEVIRTUALIZED (non-boxed) closure-dispatch representations
  the `call_closure` lowering keeps after the unification — the patterns the
  rest of the corpus did not exercise, surfaced by the Phase-3 dispatch
  reachability audit. Each is a distinct reachable branch of the dispatch:

    - Gap E (`callee_is_bare_fn_value`): a NON-capturing closure read back from a
      call result (a bare `*const fn(..)`), invoked via a direct `call_ref` —
      both bound AND INLINE (`f()(x)`), the latter exercising the daemon
      value-call-result-type resolution through a quoted (Zest) macro body.
    - `closure_function_map`: a 0-capture closure bound to a LOCAL and called via
      that local, resolved to a direct named call.
    - `{call_fn, env}` destructure: a CAPTURING closure bound to a local and
      called via the local — the zero-overhead non-escaping stack-env path.

  None of these boxes; boxing is reserved for escaping / heterogeneous / stored
  closures (a separate intercepted `protocol_dispatch` path). Both managers.
  """

pub struct Zap.ClosureDevirtTest {
  use Zest.Case

  describe("devirtualized closure dispatch (no box)") {
    test("Gap E — non-capturing returned closure, bound then called") {
      op = Zap.ClosureFactoryMaker.non_capturing_op()
      assert(op(7) == 21)
    }

    test("Gap E — non-capturing returned closure, called inline") {
      assert(Zap.ClosureFactoryMaker.non_capturing_op()(10) == 30)
    }

    test("closure_function_map — 0-capture closure bound to a local") {
      f = fn(x :: i64) -> i64 { x + 1 }
      assert(f(10) == 11)
    }

    test("closure_function_map — 0-capture two-arg closure bound to a local") {
      g = fn(x :: i64, y :: i64) -> i64 { x + y }
      assert(g(3, 4) == 7)
    }

    test("{call_fn, env} — capturing closure bound to a local, called via local") {
      n = 5
      f = fn(x :: i64) -> i64 { x + n }
      assert(f(10) == 15)
    }

    test("{call_fn, env} — capturing closure over two bindings") {
      a = 2
      b = 100
      f = fn(x :: i64) -> i64 { (x * a) + b }
      assert(f(10) == 120)
    }
  }
}
