# FCC Phase 5 — Item 3(b). A CAPTURING returned raising closure invoked WITHOUT
# a `rescue` in a `raises ()` function MUST be COMPILE-FLAGGED (not runtime-
# abort), exactly like the bare-fn-ptr (non-capturing) case
# (`return_undischarged_flagged.zap`). The capturing closure boxes as a
# `Callable` existential, so the `raises_row` cannot ride the `.function`
# return type — the boxed instantiation's row is recorded against the shared
# `Callable` constraint TypeId (`recordBoxedCallableRaisesRow`) and folded at
# the value-call site for the undischarged-discharge check.
#
# Expected: COMPILE ERROR ("add `BoomError` to the `raises` row, or stop
# propagating it with `?`") — this fixture is gated by run_compile_error, NOT a
# clean run.

@code Z9610
pub error BoomError {}

pub struct Maker {
  pub fn make(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 {
      if x > n {
        raise %BoomError{message: "leaked from returned capturing closure"}
      }
      x + n
    }
  }

  # Declares it raises nothing, yet invokes a returned CAPTURING raising
  # closure without rescuing. The instantiated effect (BoomError) must be
  # flagged against the declared empty row.
  pub fn runner() -> i64 raises () {
    action = Maker.make(5)
    action(100)
  }
}

fn main(_args :: [String]) -> u8 {
  result = try {
    Maker.runner()
  } rescue {
    e :: BoomError -> 0
  }
  IO.puts(Integer.to_string(result))
  0
}
