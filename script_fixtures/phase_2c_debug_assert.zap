# Phase 2.c acceptance: `debug_assert(false)` is the debug-only tier.
#
#   * Debug:        CHECKED — aborts with `** (assertion_error) ...`.
#   * ReleaseSafe:  ELIDED  — the program runs past it and returns 0.
#   * ReleaseFast:  ELIDED  — runs past it, returns 0.
#   * ReleaseSmall: ELIDED  — runs past it, returns 0.
#
# So:
#   zap run  ... -Doptimize=debug         -> aborts (assertion_error)
#   zap run  ... -Doptimize=release_safe  -> prints "survived" exit 0
#   zap run  ... -Doptimize=release_fast  -> prints "survived" exit 0
#   zap run  ... -Doptimize=release_small -> prints "survived" exit 0

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
