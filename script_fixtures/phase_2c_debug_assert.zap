# Phase 2.c acceptance: `debug_assert(false)` is the debug-only tier.
#
#   * Debug:        CHECKED — aborts with `** (assertion_error) ...`.
#   * ReleaseSafe:  ELIDED  — the program runs past it and returns 0.
#   * ReleaseFast:  ELIDED  — runs past it, returns 0.
#   * ReleaseSmall: ELIDED  — runs past it, returns 0.
#
# So:
#   zap run -Doptimize=Debug ...         -> aborts (assertion_error)
#   zap run -Doptimize=ReleaseSafe ...  -> prints "survived" exit 0
#   zap run -Doptimize=ReleaseFast ...  -> prints "survived" exit 0
#   zap run -Doptimize=ReleaseSmall ... -> prints "survived" exit 0

pub struct DebugAssertCrash {
  pub fn check() -> Nil {
    debug_assert(false)
  }
}

fn main(_args :: [String]) -> u8 {
  DebugAssertCrash.check()
  IO.puts("survived")
  0
}
