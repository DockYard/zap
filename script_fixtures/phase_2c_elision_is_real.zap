# Phase 2.c acceptance: ELISION IS REAL — in an elided mode the
# condition expression is NOT evaluated (no side effects, no cost).
#
# `noisy_true/0` prints "evaluated" and returns true. We pass it as the
# `debug_assert` condition. Because the condition is TRUE, the assertion
# never fails in any mode — so the ONLY observable difference between
# modes is whether "evaluated" is printed, i.e. whether the condition
# expression ran at all.
#
#   * Debug:        condition evaluated -> prints "evaluated" then "done".
#   * ReleaseSafe:  debug_assert elided -> condition NOT evaluated ->
#                   prints ONLY "done" (no "evaluated").
#   * ReleaseFast:  elided -> ONLY "done".
#   * ReleaseSmall: elided -> ONLY "done".
#
# If "evaluated" prints in a release mode, elision is fake (the condition
# was lowered and executed) and this fixture FAILS the acceptance bar.

pub struct ElisionProof {
  pub fn noisy_true() -> Bool {
    IO.puts("evaluated")
    true
  }

  pub fn run() -> Nil {
    debug_assert(ElisionProof.noisy_true())
  }
}

fn main(_args :: [String]) -> u8 {
  ElisionProof.run()
  IO.puts("done")
  0
}
