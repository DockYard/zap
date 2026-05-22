# Phase 2.c acceptance: `precondition(false)` is the API-contract tier —
# checked in Debug + ReleaseSafe, dropped in optimized prod builds.
#
#   * Debug:        CHECKED — aborts with `** (assertion_error) ...`.
#   * ReleaseSafe:  CHECKED — aborts with `** (assertion_error) ...`.
#   * ReleaseFast:  ELIDED  — runs past it, prints "survived", exit 0.
#   * ReleaseSmall: ELIDED  — runs past it, prints "survived", exit 0.
#
# So:
#   zap run -Doptimize=Debug ...         -> aborts (assertion_error)
#   zap run -Doptimize=ReleaseSafe ...  -> aborts (assertion_error)
#   zap run -Doptimize=ReleaseFast ...  -> prints "survived" exit 0
#   zap run -Doptimize=ReleaseSmall ... -> prints "survived" exit 0

pub struct PreconditionCrash {
  pub fn check() -> Nil {
    precondition(false)
  }
}

fn main(_args :: [String]) -> u8 {
  PreconditionCrash.check()
  IO.puts("survived")
  0
}
