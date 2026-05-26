# FCC Phase 3 — residual 3 (the inline-temp leak). An inline boxed-`Callable`
# invocation owns the box it dispatches on; that owner must be released at
# scope exit (no leak under `Memory.Tracking`).
#
# Two inline shapes, both producing a FRESH owned `ProtocolBox` that is
# immediately dispatched on (the dispatch receiver is a borrow, so the
# producing temp is the sole owner):
#
#   1. A DIRECT call producing a box: `make_adder(5)(10)` — the callee
#      `make_adder(5)` is a `call` whose result is a boxed capturing closure.
#   2. An indexed read producing a box: `List.get(ops, i)(10)` — `List.get`
#      CLONES the boxed element (`ownElement`), an owned single-use box.
#
# A NAMED binding (`f = List.get(ops, 0); f(10)`) already balanced before this
# fix; the inline temps did not get a scope-exit `.protocol_box_drop` and so
# leaked under `Memory.Tracking`. Both shapes must now be leak-free.
#
# Expected (both managers): prints 15, 11, 15 and exits 0 with ZERO leaks.

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, AdderMaker.make_adder(5)]
  }
}

fn main(_args :: [String]) -> u8 {
  # Shape 1: direct inline call on a box-returning call.
  IO.puts(Integer.to_string(AdderMaker.make_adder(5)(10)))

  # Shape 2: inline-indexed calls over a boxed-element list.
  ops = AdderMaker.ops()
  IO.puts(Integer.to_string(List.get(ops, 0)(10)))
  IO.puts(Integer.to_string(List.get(ops, 1)(10)))
  0
}
